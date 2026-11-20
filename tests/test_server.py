import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest import mock

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bridge"))
import server


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.support = Path(self.tmp.name) / "support"
        self.work_dir = Path(self.tmp.name) / "project"
        self.work_dir.mkdir()
        self.patch_support = mock.patch.object(server, "SUPPORT", self.support)
        self.patch_support.start()

    def tearDown(self):
        self.patch_support.stop()
        self.tmp.cleanup()

    def test_dispatch_allows_null_params_and_rejects_non_dict(self):
        result, error = server.dispatch({"method": "tools/list", "params": None})
        self.assertIsNone(error)
        self.assertIn("tools", result)

        result, error = server.dispatch({"method": "tools/list", "params": ["bad"]})
        self.assertIsNone(result)
        self.assertEqual(error["code"], -32602)

    def test_null_health_arguments_and_lock_independence(self):
        with mock.patch.object(server, "invoke", return_value={"status": "ready"}) as helper:
            with server.journal():
                result, error = server.dispatch({
                    "method": "tools/call", "params": {"name": "gemini_health", "arguments": None}
                })
                self.assertIsNone(error)
                self.assertFalse(result["isError"])
                helper.assert_called_once_with("health", 5)
        result, _ = server.dispatch({
            "method": "tools/call", "params": {"name": "gemini_health", "arguments": []}
        })
        self.assertTrue(result["isError"])

    def test_foreground_recovery_only_retries_known_pre_submit_failure(self):
        for armed in (True, False, None):
            with self.subTest(may_have_submitted=armed):
                initial = {"status": "gemini_not_frontmost", "may_have_submitted": armed}
                with mock.patch.object(server, "invoke", side_effect=[initial, {"status": "running"}]) as invoke, \
                     mock.patch.object(server.subprocess, "run", return_value=mock.Mock(returncode=0)) as launch:
                    result = server.invoke_with_foreground_recovery("submit", 10)
                self.assertEqual(invoke.call_count, 2 if armed is False else 1)
                self.assertEqual(launch.call_count, 1 if armed is False else 0)
                self.assertEqual(result["status"], "running" if armed is False else initial["status"])

    def test_validation_checks_message_and_timeout_boundaries(self):
        tool = next(tool for tool in server.TOOLS if tool["name"] == "gemini_submit_chat")
        good = {"task_id": "chat_1", "message": "a" * 16000, "timeout_seconds": 30}
        server.validate(tool, good)
        for bad in ({"timeout_seconds": True}, {"timeout_seconds": 29}, {"timeout_seconds": 3601},
                    {"message": "a" * 16001}, {"message": "a\0b"}, {"task_id": "bad id"}):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    server.validate(tool, good | bad)

    def test_active_task_blocks_second_submission_and_release(self):
        with mock.patch.object(server, "invoke_with_foreground_recovery", return_value={"status": "running"}) as helper:
            server.call("gemini_submit_chat", {"task_id": "first", "message": "hi"})
            result = server.call("gemini_submit_chat", {"task_id": "second", "message": "hi"})
            self.assertEqual(result["status"], "busy")
            self.assertEqual(result["active_task_id"], "first")
            self.assertEqual(helper.call_count, 1)
        for state in ("running", "completed"):
            with self.subTest(state=state):
                if state == "completed":
                    with mock.patch.object(server, "invoke", return_value={"status": state, "reply": "ok"}):
                        server.call("gemini_get_result", {"task_id": "first"})
                with self.assertRaises(ValueError):
                    server.call("gemini_release", {"task_id": "first", "confirmed": True})

    def test_timeout_preserves_armed_file_until_exit_and_never_resubmits(self):
        helper = Path(self.tmp.name) / "fake.app"
        helper.mkdir()
        worker_code = """
from pathlib import Path
import subprocess
import sys
import time
sys.path.insert(0, str(Path(sys.argv[1]).parent))
import server
folder = Path(sys.argv[2])
def fake_open(*args, **kwargs):
    assert "-W" in args[0]
    (folder / "armed").touch()
    limit = time.monotonic() + 8
    while not (folder.parent / "helper-can-exit").exists() and time.monotonic() < limit:
        time.sleep(0.01)
    assert (folder / "armed").is_file()
    assert (folder / "request.json").is_file()
    (folder.parent / "helper-saw-armed").touch()
    return subprocess.CompletedProcess(args[0], 0, "", "")
server.subprocess.run = fake_open
server.run_helper(folder, Path(sys.argv[3]))
"""
        real_popen = subprocess.Popen
        real_invoke = server.invoke
        workers = []

        def launch_worker(command, **kwargs):
            worker = real_popen(
                [command[0], "-c", worker_code, command[1], command[3], command[4]], **kwargs
            )
            workers.append(worker)
            return worker

        def wait_for(path):
            limit = time.monotonic() + 4
            while not path.exists() and time.monotonic() < limit:
                time.sleep(0.01)
            self.assertTrue(path.exists(), str(path))

        args = {"task_id": "timeout-armed", "message": "hello"}
        try:
            with mock.patch.object(server, "HELPER", helper), \
                 mock.patch.object(server.subprocess, "Popen", side_effect=launch_worker), \
                 mock.patch.object(server, "invoke", side_effect=lambda action, _, **kw: real_invoke(action, -1.7, **kw)):
                first = server.call("gemini_submit_chat", args)
                self.assertEqual(first["code"], "helper_timeout")
                self.assertEqual(first["status"], "submission_unknown")
                folder, = self.support.glob("call-*")
                wait_for(folder / "armed")
                self.assertTrue((folder / "request.json").is_file())
                repeated = server.call("gemini_submit_chat", args)
                self.assertEqual(repeated["status"], "submission_unknown")
                self.assertEqual(len(workers), 1)
                self.assertIsNone(workers[0].poll())
        finally:
            (self.support / "helper-can-exit").touch()
            for worker in workers:
                worker.wait(timeout=10)
        wait_for(self.support / "helper-saw-armed")
        self.assertFalse(folder.exists())
        self.assertEqual(server.call("gemini_submit_chat", args)["status"], "submission_unknown")

    def test_swift_quota_parser_keeps_matching_percentages(self):
        project = Path(__file__).resolve().parents[1]
        source = (project / "bridge/GeminiDesktopBridge.swift").read_text(encoding="utf-8")
        fixture = (project / "tests/quota/main.swift").read_text(encoding="utf-8")
        subprocess.run(
            ["/usr/bin/swift", "-D", "BRIDGE_PARSER_TEST", "-"],
            input=source + "\n" + fixture, text=True, check=True, timeout=30,
        )

    def test_helper_exit_without_response_is_not_timeout(self):
        helper = Path(self.tmp.name) / "fake.app"
        helper.mkdir()

        for armed in (False, True):
            with self.subTest(armed=armed):
                def write_exit(command, **kwargs):
                    folder = Path(command[3])
                    if armed:
                        (folder / "armed").touch()
                    (folder / "exit.json").write_text(json.dumps({"returncode": 0, "detail": ""}))
                    return mock.Mock()

                with mock.patch.object(server, "HELPER", helper), \
                     mock.patch.object(server.subprocess, "Popen", side_effect=write_exit):
                    result = server.invoke("submit", 5)
                self.assertEqual(result["status"], "helper_exited_without_response")
                self.assertIs(result["may_have_submitted"], armed)

    def test_submit_normalizes_directory_fingerprint(self):
        with mock.patch.object(server, "invoke_with_foreground_recovery", return_value={"status": "running"}) as mocked:
            first = server.call("gemini_submit_task", {
                "task_id": "task-1",
                "message": "hello",
                "directory": str(self.work_dir) + "/",
            })
            second = server.call("gemini_submit_task", {
                "task_id": "task-1",
                "message": "hello",
                "directory": str(self.work_dir),
            })
        self.assertEqual(first["status"], "running")
        self.assertEqual(second["status"], "running")
        self.assertEqual(mocked.call_count, 1)

    def test_transient_query_error_preserves_submission_unknown(self):
        with mock.patch.object(
            server,
            "invoke_with_foreground_recovery",
            return_value={"status": "helper_timeout", "may_have_submitted": True},
        ):
            submitted = server.call("gemini_submit_chat", {"task_id": "chat-1", "message": "hi"})
        self.assertEqual(submitted["status"], "submission_unknown")

        with mock.patch.object(
            server,
            "invoke",
            return_value={"status": "window_unavailable", "detail": "Unlock Mac"},
        ):
            diag = server.call("gemini_get_result", {"task_id": "chat-1"})
        self.assertEqual(diag["status"], "submission_unknown")
        self.assertEqual(diag["code"], "window_unavailable")
        self.assertEqual(diag["detail"], "Unlock Mac")

        # Transient error without detail must not leak stale detail from the persisted state.
        with mock.patch.object(server, "invoke", return_value={"status": "helper_busy"}):
            no_detail = server.call("gemini_get_result", {"task_id": "chat-1"})
        self.assertEqual(no_detail["status"], "submission_unknown")
        self.assertEqual(no_detail["code"], "helper_busy")
        self.assertNotIn("detail", no_detail)

        # Subsequent conversation_not_found must still preserve submission_unknown.
        with mock.patch.object(
            server,
            "invoke",
            return_value={"status": "conversation_not_found", "detail": "Not visible"},
        ):
            after = server.call("gemini_get_result", {"task_id": "chat-1"})
        self.assertEqual(after["status"], "submission_unknown")

    def test_release_allows_attention_required(self):
        with mock.patch.object(server, "invoke_with_foreground_recovery", return_value={"status": "running"}):
            server.call("gemini_submit_chat", {"task_id": "chat-2", "message": "hi"})
        with mock.patch.object(
            server,
            "invoke",
            return_value={"status": "attention_required", "detail": "Confirm dialog"},
        ):
            observed = server.call("gemini_get_result", {"task_id": "chat-2"})
        self.assertEqual(observed["status"], "attention_required")

        released = server.call("gemini_release", {"task_id": "chat-2", "confirmed": True})
        self.assertEqual(released["status"], "released")

    def test_expired_transient_error_transitions_to_timed_out(self):
        with mock.patch.object(server, "invoke_with_foreground_recovery", return_value={"status": "running"}):
            server.call("gemini_submit_chat", {"task_id": "chat-3", "message": "hi", "timeout_seconds": 30})
        with mock.patch.object(server, "invoke", return_value={"status": "helper_busy", "detail": "Busy"}), \
             mock.patch.object(time, "time", return_value=time.time() + 100):
            timed_out = server.call("gemini_get_result", {"task_id": "chat-3"})
        self.assertEqual(timed_out["status"], "timed_out")
        self.assertEqual(timed_out["code"], "helper_busy")

        with mock.patch.object(server, "invoke", return_value={"status": "completed", "reply": "late"}):
            result = server.call("gemini_get_result", {"task_id": "chat-3"})
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["reply"], "late")


if __name__ == "__main__":
    unittest.main()

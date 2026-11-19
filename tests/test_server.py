import json
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()

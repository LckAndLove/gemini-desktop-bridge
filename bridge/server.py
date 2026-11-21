#!/usr/bin/env python3
"""Local MCP stdio transport and durable Gemini submission journal."""

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

SUPPORT = Path.home() / "Library/Application Support/Gemini Desktop Bridge"
HELPER = Path.home() / "Applications/Gemini Desktop Bridge.app"
TERMINAL = {"completed", "task_failed", "not_submitted", "released"}
OBSERVED = {"running", "completed", "task_failed", "conversation_not_found", "result_unavailable", "attention_required"}
TASK_ID = re.compile(r"[A-Za-z0-9_-]{1,80}\Z")
PROTOCOLS = {"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"}


def schema(properties, required=()):
    return {
        "type": "object",
        "properties": properties,
        "required": list(required),
        "additionalProperties": False,
    }


ID = {"type": "string", "description": "Unique caller-provided ID. Reuse it for retries of the same request."}
MESSAGE = {"type": "string", "description": "Message or task for the signed-in Gemini Desktop app."}
TIMEOUT = {"type": "integer", "minimum": 30, "maximum": 3600, "default": 300}
MODEL = {
    "type": "string",
    "description": "Optional exact model label returned by gemini_list_models for the same mode. Use the entire label.",
}
CONTINUE_FROM = {
    "type": "string",
    "description": "Optional prior task_id to continue in the same Gemini conversation instead of starting a new one.",
}
TOOLS = [
    {
        "name": "gemini_submit_task",
        "description": "Start a fresh Gemini Desktop Task with a user-authorized local directory, or continue an existing task conversation via continue_from_task_id. Submit once and return a task ID. Poll gemini_get_result for completion.",
        "inputSchema": schema({
            "task_id": ID, "message": MESSAGE,
            "directory": {"type": "string", "description": "Absolute path of a directory the user authorized Gemini to access. Required for a new task; optional when continuing."},
            "timeout_seconds": TIMEOUT, "model": MODEL, "continue_from_task_id": CONTINUE_FROM,
        }, ["task_id", "message"]),
    },
    {
        "name": "gemini_submit_chat",
        "description": "Start a fresh regular Gemini Desktop conversation, or continue an existing chat conversation via continue_from_task_id, and submit one message. Poll gemini_get_result for the reply.",
        "inputSchema": schema({"task_id": ID, "message": MESSAGE, "timeout_seconds": TIMEOUT, "model": MODEL, "continue_from_task_id": CONTINUE_FROM}, ["task_id", "message"]),
    },
    {
        "name": "gemini_list_models",
        "description": "List only models available to the signed-in account in the specified Gemini Desktop mode. Use while the bridge is idle.",
        "inputSchema": schema({"mode": {"type": "string", "enum": ["chat", "task"]}}, ["mode"]),
    },
    {
        "name": "gemini_get_result",
        "description": "Read progress or the full reply for a task or chat ID. This never sends the message again. Poll every few seconds while active.",
        "inputSchema": schema({"task_id": ID}, ["task_id"]),
    },
    {
        "name": "gemini_get_weekly_quota",
        "description": "Read the signed-in Gemini Desktop account’s five-hour and weekly quota. Returns usage, remaining percentage, and reset text where available. Existing top-level fields describe the weekly quota.",
        "inputSchema": schema({}),
    },
    {
        "name": "gemini_health",
        "description": "Check whether the installed helper has macOS Accessibility and keyboard event permissions. Does not open Gemini.",
        "inputSchema": schema({}),
    },
    {
        "name": "gemini_release",
        "description": "After the user checks Gemini and confirms the old conversation is no longer running, release an uncertain or timed-out ID to allow a new task. Does not cancel or retry the Gemini operation.",
        "inputSchema": schema({
            "task_id": ID, "confirmed": {"type": "boolean", "description": "True only after the user has checked the old conversation."},
        }, ["task_id", "confirmed"]),
    },
]


def run_helper(folder, helper):
    """Own the request directory until both the app and its caller finish."""
    with (folder / "caller.lock").open("r+") as caller:
        try:
            launch = subprocess.run(
                ["/usr/bin/open", "-W", "-g", "-n", str(helper), "--args",
                 "--request", str(folder / "request.json")],
                capture_output=True, text=True,
            )
            result = {"returncode": launch.returncode, "detail": launch.stderr.strip()}
        except OSError as error:
            result = {"returncode": -1, "detail": str(error)}
        try:
            pending = folder / "exit.tmp"
            pending.write_text(json.dumps(result), encoding="utf-8")
            pending.replace(folder / "exit.json")
        finally:
            # open -W has finished. The lock also survives a caller timeout or exit.
            fcntl.flock(caller, fcntl.LOCK_EX)
            shutil.rmtree(folder)


def invoke(action, budget, **request):
    if not HELPER.is_dir():
        return {"status": "helper_missing", "detail": f"Install the helper at {HELPER}.", "may_have_submitted": False}
    SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
    deadline = time.time() + budget
    folder = Path(tempfile.mkdtemp(prefix="call-", dir=SUPPORT))
    worker = None
    try:
        with (folder / "caller.lock").open("w") as caller:
            fcntl.flock(caller, fcntl.LOCK_EX)
            (folder / "request.json").write_text(
                json.dumps(dict(request, action=action, deadline=deadline)), encoding="utf-8"
            )
            try:
                worker = subprocess.Popen(
                    [sys.executable, str(Path(__file__).resolve()), "--run-helper", str(folder), str(HELPER)],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except OSError as error:
                return {"status": "helper_launch_uncertain", "detail": str(error), "may_have_submitted": action == "submit"}
            threading.Thread(target=worker.wait, daemon=True).start()
            response = folder / "response.json"
            exit_status = folder / "exit.json"
            while time.time() < deadline + 2:
                if response.is_file():
                    return json.loads(response.read_text(encoding="utf-8"))
                if exit_status.is_file():
                    # The response can appear between the first check and the exit record.
                    if response.is_file():
                        return json.loads(response.read_text(encoding="utf-8"))
                    exit_result = json.loads(exit_status.read_text(encoding="utf-8"))
                    if exit_result["returncode"]:
                        return {
                            "status": "helper_launch_failed", "detail": exit_result["detail"],
                            "may_have_submitted": action == "submit",
                        }
                    return {
                        "status": "helper_exited_without_response",
                        "detail": "The Accessibility helper exited without writing a response.",
                        "may_have_submitted": action == "submit" and (folder / "armed").is_file(),
                    }
                time.sleep(0.12)
        return {
            "status": "helper_timeout",
            "detail": (
                "No response from the Accessibility helper. Query the same task ID before attempting any new submission."
                if action == "submit"
                else "No response from the Accessibility helper. Check that the Mac is unlocked before retrying."
            ),
            "may_have_submitted": action == "submit",
        }
    finally:
        if worker is None:
            shutil.rmtree(folder)


def invoke_with_foreground_recovery(action, budget, **request):
    started = time.monotonic()
    result = invoke(action, budget, **request)
    if result.get("status") != "gemini_not_frontmost" or result.get("may_have_submitted") is not False:
        return result
    # Launch Services can activate an app when a background helper's activation
    # request is ignored. Retry only a failure proven to precede submission.
    try:
        opened = subprocess.run(
            ["/usr/bin/open", "-b", "com.google.GeminiMacOS"],
            capture_output=True, text=True, timeout=4,
        )
    except (OSError, subprocess.TimeoutExpired):
        return result
    if opened.returncode == 0:
        remaining = max(1.0, budget - (time.monotonic() - started))
        return invoke(action, remaining, **request)
    return result


@contextlib.contextmanager
def journal():
    SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (SUPPORT / "server.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("The bridge is busy. Retry the same operation and task ID shortly.") from error
        with contextlib.closing(sqlite3.connect(SUPPORT / "tasks.sqlite3")) as db:
            db.execute("PRAGMA synchronous=FULL")
            db.execute("CREATE TABLE IF NOT EXISTS task (id TEXT PRIMARY KEY, item TEXT NOT NULL, active INTEGER NOT NULL)")
            db.execute("CREATE UNIQUE INDEX IF NOT EXISTS one_active ON task(active) WHERE active = 1")
            yield db


def save(db, item):
    with db:
        db.execute(
            "INSERT INTO task VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET item=excluded.item, active=excluded.active",
            (item["task_id"], json.dumps(item, ensure_ascii=False), item["status"] not in TERMINAL),
        )


def expose(item):
    return {key: val for key, val in item.items() if key not in {"fingerprint", "marker", "window_title", "expires_at"}}


def validate(tool, args):
    if not isinstance(args, dict):
        raise ValueError("arguments must be an object")
    spec = tool["inputSchema"]
    if not set(spec["required"]) <= args.keys() or not args.keys() <= spec["properties"].keys():
        raise ValueError("Missing or unexpected tool arguments")
    types = {"string": str, "integer": int, "boolean": bool}
    for key, val in args.items():
        prop = spec["properties"][key]
        if type(val) is not types[prop["type"]]:
            raise ValueError(f"Invalid type for {key}")
        if "enum" in prop and val not in prop["enum"]:
            raise ValueError(f"Invalid value for {key}: choose from {', '.join(prop['enum'])}")
    if "task_id" in args and not TASK_ID.fullmatch(args["task_id"]):
        raise ValueError("task_id must contain 1–80 ASCII letters, numbers, hyphens or underscores")
    if "continue_from_task_id" in args:
        if not TASK_ID.fullmatch(args["continue_from_task_id"]):
            raise ValueError("continue_from_task_id must contain 1–80 ASCII letters, numbers, hyphens or underscores")
        if args["continue_from_task_id"] == args.get("task_id"):
            raise ValueError("continue_from_task_id must differ from task_id")
    if tool["name"] == "gemini_submit_task" and "continue_from_task_id" not in args and "directory" not in args:
        raise ValueError("directory is required when starting a new task")
    if "message" in args and (not args["message"].strip() or len(args["message"]) > 16000 or "\0" in args["message"]):
        raise ValueError("message must contain 1–16000 valid characters")
    if "model" in args and (not args["model"].strip() or len(args["model"]) > 512 or "\0" in args["model"]):
        raise ValueError("model must be an exact label returned by gemini_list_models")
    if "timeout_seconds" in args and not 30 <= args["timeout_seconds"] <= 3600:
        raise ValueError("timeout_seconds must be between 30 and 3600")


def submit(db, mode, args, existing):
    raw_directory = args.get("directory")
    normalized_directory = None
    if raw_directory is not None:
        if not Path(raw_directory).is_absolute():
            raise ValueError("directory must be an absolute path")
        normalized_directory = str(Path(raw_directory).resolve(strict=False))
    identity = [mode, args["message"], normalized_directory, args.get("timeout_seconds", 300)]
    model = args.get("model")
    if model is not None:
        identity.append(model)
    continue_from = args.get("continue_from_task_id")
    if continue_from is not None:
        identity.append({"continue_from_task_id": continue_from})
    fingerprint = hashlib.sha256(json.dumps(identity).encode()).hexdigest()
    if existing:
        if existing["fingerprint"] != fingerprint:
            raise ValueError("This task_id already identifies a different request")
        return expose(existing)
    directory = None
    if normalized_directory is not None:
        directory = str(Path(raw_directory).resolve(strict=True))
        if not Path(directory).is_dir() or directory == "/":
            raise ValueError("directory must identify a local folder other than the root")
    active = db.execute("SELECT id FROM task WHERE active=1").fetchone()
    if active:
        return {"status": "busy", "active_task_id": active[0], "detail": "Query the active task before submitting another."}
    parent = None
    if continue_from is not None:
        parent_row = db.execute("SELECT item FROM task WHERE id=?", (continue_from,)).fetchone()
        if parent_row is None:
            raise ValueError("continue_from_task_id does not match a known task")
        parent = json.loads(parent_row[0])
        if parent["mode"] != mode:
            raise ValueError(f"continue_from_task_id belongs to a {parent['mode']} conversation, not {mode}")
        if parent["status"] == "not_submitted":
            raise ValueError("Cannot continue from a task that was not submitted")
        if mode == "task":
            if directory is None:
                directory = parent.get("directory")
            elif directory != parent.get("directory"):
                raise ValueError("Cannot change directory when continuing an existing task")
    task_id = args["task_id"]
    marker = "[Gemini Bridge " + hashlib.sha256(task_id.encode()).hexdigest()[:20] + "]"
    item = {
        "task_id": task_id,
        "mode": mode,
        "directory": directory,
        "fingerprint": fingerprint,
        "marker": marker,
        "status": "submission_unknown",
        "expires_at": time.time() + args.get("timeout_seconds", 300),
    }
    if model is not None:
        item["model"] = model
    if parent is not None:
        item["continue_from_task_id"] = continue_from
        if parent.get("window_title"):
            item["window_title"] = parent["window_title"]
    save(db, item)
    result = invoke_with_foreground_recovery(
        "submit", 38, mode=mode, model=model, directory=directory,
        message=args["message"], marker=marker,
        continueMarker=parent["marker"] if parent else None,
        windowTitle=parent.get("window_title") if parent else None,
    )
    submitted = result.pop("may_have_submitted", None)
    if submitted is not None:
        result["code"] = result["status"]
        result["status"] = "submission_unknown" if submitted else "not_submitted"
    item.update(result)
    save(db, item)
    return expose(item)


def get_result(db, item):
    if item["status"] in TERMINAL:
        return expose(item)
    observed = invoke("query", 20, mode=item["mode"], marker=item["marker"], windowTitle=item.get("window_title"))
    observed.pop("may_have_submitted", None)
    status = observed.get("status")
    expired = time.time() >= item["expires_at"]
    if status not in OBSERVED:
        if expired:
            item.pop("phase", None)
            item.update(
                status="timed_out",
                code=status,
                detail=observed.get("detail") or "The task exceeded its polling deadline. It may still be running. You can keep querying the same task ID.",
            )
            save(db, item)
            return expose(item)
        # Report transient helper/UI diagnostic errors without overwriting the persisted task state.
        response = expose(item)
        response.pop("detail", None)
        response["code"] = status
        if "detail" in observed:
            response["detail"] = observed["detail"]
        return response
    item.pop("detail", None)
    item.pop("phase", None)
    item.pop("code", None)
    if item["status"] == "submission_unknown" and status == "conversation_not_found":
        observed["status"] = "submission_unknown"
    if expired and observed["status"] not in TERMINAL:
        observed.update(code=observed["status"], status="timed_out")
        observed.setdefault("detail", "The task exceeded its polling deadline. It may still be running. You can keep querying the same task ID.")
    item.update(observed)
    save(db, item)
    return expose(item)


def call(name, args):
    tool = next((entry for entry in TOOLS if entry["name"] == name), None)
    if not tool:
        raise ValueError("Unknown tool")
    validate(tool, args)
    if name == "gemini_health":
        result = invoke("health", 5)
        result.pop("may_have_submitted", None)
        return result
    with journal() as db:
        if name in {"gemini_list_models", "gemini_get_weekly_quota"}:
            active = db.execute("SELECT id FROM task WHERE active=1").fetchone()
            if active:
                return {"status": "busy", "active_task_id": active[0], "detail": "Query the active task first."}
            action = "models" if name == "gemini_list_models" else "quota"
            result = invoke_with_foreground_recovery(action, 28, mode=args.get("mode"))
            result.pop("may_have_submitted", None)
            return result
        task_id = args["task_id"]
        row = db.execute("SELECT item FROM task WHERE id=?", (task_id,)).fetchone()
        item = json.loads(row[0]) if row else None
        if name.startswith("gemini_submit_"):
            return submit(db, name.removeprefix("gemini_submit_"), args, item)
        if item is None:
            return {"task_id": task_id, "status": "unknown_task"}
        if name == "gemini_get_result":
            return get_result(db, item)
        if not args["confirmed"] or item["status"] not in {
            "timed_out", "submission_unknown", "conversation_not_found", "result_unavailable", "attention_required"
        }:
            raise ValueError("Release requires user confirmation and an uncertain or timed-out task")
        item.update(status="released", detail="Tracking released at the user's request.")
        save(db, item)
        return expose(item)


def dispatch(msg):
    method = msg.get("method")
    raw_params = msg.get("params")
    if raw_params is not None and not isinstance(raw_params, dict):
        return None, {"code": -32602, "message": "Invalid params"}
    params = raw_params or {}
    if method == "initialize":
        version = params.get("protocolVersion")
        return {
            "protocolVersion": version if version in PROTOCOLS else "2025-11-25",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "gemini-desktop", "version": "1.0.0"},
        }, None
    if method == "tools/list":
        return {"tools": TOOLS}, None
    if method == "ping":
        return {}, None
    if method == "tools/call":
        try:
            args = params.get("arguments")
            result = call(params.get("name"), {} if args is None else args)
            is_error = False
        except (ValueError, RuntimeError, OSError, sqlite3.Error) as error:
            result = {"status": "bridge_error", "detail": str(error)}
            is_error = True
        return {
            "content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}],
            "isError": is_error,
        }, None
    return None, {"code": -32601, "message": "Method not found"}


def send(response):
    print(json.dumps(response, ensure_ascii=False), flush=True)


def run():
    os.umask(0o077)
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except (ValueError, UnicodeError):
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            continue
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or not isinstance(msg.get("method"), str):
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid request"}})
            continue
        if "id" not in msg:
            continue
        reply = {"jsonrpc": "2.0", "id": msg["id"]}
        try:
            result, error = dispatch(msg)
            reply.update({"error": error} if error else {"result": result})
        except Exception:
            reply["error"] = {"code": -32603, "message": "Internal bridge error. Query the same task ID."}
        send(reply)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--run-helper":
        folder = Path(sys.argv[2])
        if folder.parent != SUPPORT or not folder.name.startswith("call-") or folder.is_symlink():
            sys.exit("Invalid helper request directory")
        run_helper(folder, Path(sys.argv[3]))
    else:
        run()

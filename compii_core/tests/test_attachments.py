"""Attachments: files the app sends to Core, and what the model is told about them."""

import time
from pathlib import Path

from fastapi.testclient import TestClient

from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401 - fixtures


def _app(home, brain):
    return build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                     keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))


def _done_task(client, h, task_id):
    for _ in range(100):
        task = next(t for t in client.get("/tasks", headers=h).json() if t["id"] == task_id)
        if task["status"] != "running":
            return task
        time.sleep(0.05)
    raise AssertionError("the task never finished")


def test_an_upload_lands_in_compii_with_its_name_and_no_path_tricks(home):
    app = _app(home, ScriptBrain([], final="ok"))
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok", "X-Compii-Filename": "..%2F..%2FQuarterly%20report%20%3A%20final.pdf"}
        got = client.post("/uploads", content=b"hello, this is a report", headers=h).json()
        p = Path(got["path"])
        assert p.exists() and p.parent.parent == home["workspace"] / "uploads"
        assert p.name == "Quarterly report  final.pdf"  # separators and colons cannot make a path
        assert got["size"] == 23 and got["kind"] == "pdf"
        assert client.post("/uploads", content=b"second", headers=h).json()["name"] == "Quarterly report  final (2).pdf"
        assert client.post("/uploads", content=b"", headers=h).status_code == 400
        assert client.post("/uploads", content=b"x").status_code == 401


def test_a_new_message_carries_attachments_and_the_model_is_told_what_they_are(home):
    report = home["downloads"] / "report.txt"
    report.write_text("The deadline is 12 November.", encoding="utf-8")
    brain = ScriptBrain([], final="Read it.")
    app = _app(home, brain)
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        task_id = client.post("/tasks", json={"request": "What date does the report give?",
                                              "attachments": [str(report)]}, headers=h).json()["id"]
        task = _done_task(client, h, task_id)
        started = next(e for e in task["events"] if e["type"] == "task_started")
        assert started["request"] == "What date does the report give?"
        assert started["attachments"][0]["name"] == "report.txt"
        assert started["attachments"][0]["path"] == str(report.resolve())
        sent = "\n".join(str(m.get("content")) for m in brain.seen[0])
        assert "attached these files" in sent and "report.txt" in sent
        assert str(report.resolve()) in sent
        # The user's own words stay clean in the app.
        assert "attached these files" not in started["request"]


def test_a_follow_up_can_be_just_the_attached_file(home):
    note = home["downloads"] / "note.md"
    note.write_text("# Hello\n", encoding="utf-8")
    app = _app(home, ScriptBrain([], final="Seen."))
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        task_id = client.post("/tasks", json={"request": "Start here"}, headers=h).json()["id"]
        _done_task(client, h, task_id)
        got = client.post(f"/tasks/{task_id}/messages", json={"text": "", "attachments": [str(note)]}, headers=h)
        assert got.status_code == 200
        for _ in range(100):
            task = next(t for t in client.get("/tasks", headers=h).json() if t["id"] == task_id)
            if any(e["type"] == "user_message" for e in task["events"]) and task["status"] == "done":
                break
            time.sleep(0.05)
        message = next(e for e in task["events"] if e["type"] == "user_message")
        assert message["attachments"][0]["name"] == "note.md"
        assert "attached file" in message["text"]


def test_files_outside_the_allowed_folders_are_refused(home):
    home["outside"].mkdir()
    secret = home["outside"] / "secret.txt"
    secret.write_text("no", encoding="utf-8")
    app = _app(home, ScriptBrain([], final="ok"))
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        got = client.post("/tasks", json={"request": "read this", "attachments": [str(secret)]}, headers=h)
        assert got.status_code == 403
        assert client.post("/tasks", json={"request": "  "}, headers=h).status_code == 400

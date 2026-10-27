"""The phone's push channel: what it is told, what it is not told twice, and when
the long poll returns."""

import time
from types import SimpleNamespace

from fastapi.testclient import TestClient

from compii_core.keys import MemoryKeyStore
from compii_core.phone_push import signals
from compii_core.proactive import Update
from compii_core.server import build_app

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401 - fixtures


def _task(tid, status, events, request="Send the summary to Tom"):
    return SimpleNamespace(id=tid, status=status, events=events, request=request, origin=None)


def test_an_approval_is_a_signal_until_it_is_answered():
    asked = {"type": "approval_needed", "approval_id": "a1", "label": "Send email to tom@northwind.com", "at": 10.0}
    waiting = _task("t1", "waiting", [asked])
    out = signals([waiting], [], since=0)
    assert [s["kind"] for s in out["signals"]] == ["needs_you"]
    assert out["signals"][0]["id"] == "a1" and "tom@northwind.com" in out["signals"][0]["body"]
    assert out["pending"] == ["a1"]
    answered = _task("t1", "running", [asked, {"type": "approval_resolved", "approval_id": "a1", "at": 11.0}])
    assert signals([answered], [], since=0)["pending"] == [], "answered on the PC: the phone clears it"


def test_finished_failed_and_inbox_updates_are_told_once():
    done = _task("t1", "done", [{"type": "task_finished", "status": "done", "text": "Summary saved.", "at": 20.0}])
    failed = _task("t2", "failed", [{"type": "task_finished", "status": "failed", "text": "Outlook was closed.",
                                     "at": 21.0}])
    brief = Update("brief", "Good morning — your brief", "Three things today.", at=22.0)
    out = signals([done, failed], [brief], since=0)
    assert [s["kind"] for s in out["signals"]] == ["done", "failed", "update"]
    assert out["signals"][2]["update"] == "brief" and out["now"] == 22.0
    assert signals([done, failed], [brief], since=out["now"])["signals"] == [], "nothing is told twice"


def test_the_long_poll_answers_at_once_when_pending_changed_and_waits_otherwise(home):
    app = build_app(brain=ScriptBrain([]), workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))
    h = {"X-Compii-Token": "tok"}
    with TestClient(app) as client:
        app.state.agent.tasks["t9"] = _task("t9", "waiting", [
            {"type": "approval_needed", "approval_id": "a9", "label": "Delete old.zip", "at": time.time()}])
        t = time.monotonic()
        out = client.get("/phone/signals?since=0&wait=30", headers=h).json()
        assert time.monotonic() - t < 3 and out["pending"] == ["a9"]
        t = time.monotonic()
        quiet = client.get(f"/phone/signals?since={out['now']}&wait=1.5&pending=a9", headers=h).json()
        assert quiet["signals"] == [] and time.monotonic() - t >= 1.4, "nothing new: it waited"
        assert client.get("/phone/signals").status_code == 401, "only this PC or a paired phone"
        app.state.agent.tasks.pop("t9")  # a stand-in task; shutdown would try to stop it

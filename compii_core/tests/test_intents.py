"""Spoken "yes", "no", "stop" and "quiet" act at once, without the AI."""

from fastapi.testclient import TestClient

from compii_core.intents import parse
from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401 - fixtures

H = {"X-Compii-Token": "tok"}


def test_short_answers_only_when_something_is_waiting():
    assert parse("Yes please", "send").kind == "approve"
    assert parse("Hey Compii, go ahead", "change").kind == "approve"
    assert parse("no", "send").kind == "decline"
    assert parse("yes", None) is None  # nothing waiting: it's just a message for the AI
    assert parse("no, I meant the other folder in Documents please", "send") is None  # too long to be an answer
    assert parse("yes", "spend").kind == "refuse"  # never pay by voice
    assert parse("yes", "delete").kind == "refuse"
    assert parse("yes, delete it", "delete").kind == "approve"
    assert parse("stop", None).kind == "stop"
    assert parse("be quiet", "send").kind == "quiet"
    assert parse("stop the music app from autostarting", None) is None


def test_saying_yes_approves_the_waiting_action(home):
    calls = [("send_email", {"to": ["me@example.com"], "subject": "Hi", "body": "Hello"})]
    app = build_app(brain=ScriptBrain(calls), workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]), keys=MemoryKeyStore())
    app.state.agent.toolbox._open = lambda _t: None
    with TestClient(app) as c, c.websocket_connect("/events?t=tok") as ws:
        c.post("/tasks", json={"request": "email me"}, headers=H)
        seen = []
        while True:
            e = ws.receive_json()
            seen.append(e["type"])
            if e["type"] == "approval_needed":
                assert c.portal.call(app.state.act_on, "yes") is True
            if e["type"] == "task_finished":
                break
        assert "voice_intent" in seen and "approval_resolved" in seen
        assert c.portal.call(app.state.act_on, "please summarise my inbox") is False
        events = [e["event"] for e in c.get("/audit", headers=H).json()["entries"]]
        assert "voice_answer" in events

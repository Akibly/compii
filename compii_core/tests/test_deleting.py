"""Deleting: history, one teammate's chats, a teammate, and Compii's own memory and
set-up, from the app and from a sentence. Nothing still working is cut off."""

import asyncio

from fastapi.testclient import TestClient

from compii_core.keys import MemoryKeyStore
from compii_core.policy import ActionKind
from compii_core.server import build_app

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401 - fixtures

H = {"X-Compii-Token": "tok"}


def _app(home):
    return build_app(brain=ScriptBrain([], final="Done."), workspace=home["workspace"], roots=[home["downloads"]],
                     token="tok", keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))


def _finish(app, request, bot_id=None):
    async def go():
        task = app.state.agent.start(request, bot_id=bot_id)
        await asyncio.wait_for(task.runner, 10)
        return task

    return asyncio.run(go())


def test_clearing_history_deletes_finished_chats_and_keeps_a_running_one(home):
    app = _app(home)
    with TestClient(app) as client:
        a = _finish(app, "Plan the trip to Dakar")
        b = _finish(app, "Sort the receipts")
        busy = _finish(app, "Still going")
        busy.status = "running"
        out = client.delete("/tasks", headers=H).json()
        assert out == {"deleted": 2, "still_running": 1}
        ids = {t["id"] for t in client.get("/tasks", headers=H).json()}
        assert a.id not in ids and b.id not in ids and busy.id in ids


def test_one_teammates_history_can_be_cleared_alone(home):
    app = _app(home)
    with TestClient(app) as client:
        researcher = app.state.bots.create("Researcher", template="researcher")
        mine = _finish(app, "Compare laptops", researcher.id)
        compii = _finish(app, "Tidy my desktop")
        out = client.delete(f"/tasks?bot_id={researcher.id}", headers=H).json()
        assert out["deleted"] == 1
        ids = {t["id"] for t in client.get("/tasks", headers=H).json()}
        assert mine.id not in ids and compii.id in ids


def test_compii_can_be_reset_but_not_deleted(home):
    app = _app(home)
    with TestClient(app) as client:
        primary = app.state.bots.primary()
        app.state.bots.update(primary.id, name="Jarvis", instructions="Be terse.")
        app.state.bots.add_fact(primary.id, "Likes tea")
        assert client.delete(f"/bots/{primary.id}", headers=H).status_code == 400
        client.post("/bots/primary/reset", headers=H).raise_for_status()
        fresh = app.state.bots.primary()
        assert fresh.id == primary.id, "the same Compii, so its conversations still belong to it"
        assert fresh.name == "Compii" and fresh.facts == [] and "Be terse." not in fresh.instructions


def test_all_saved_memories_can_be_forgotten_at_once(home):
    app = _app(home)
    with TestClient(app) as client:
        for fact in ("Prefers tea", "Sister in Dakar"):
            app.state.agent.toolbox.remember({"fact": fact})
        assert client.delete("/memory", headers=H).json() == {"deleted": 2}
        assert client.get("/memory", headers=H).json() == []


def test_compii_can_delete_when_asked_and_every_deletion_asks_first(home):
    app = _app(home)
    tools = app.state.agent.toolbox.tools
    for name in ("delete_conversations", "delete_teammate", "reset_compii"):
        assert tools[name].kind_for({}) is ActionKind.DELETE, name
    with TestClient(app):
        trip = _finish(app, "Plan the trip to Dakar")
        keep = _finish(app, "Sort the receipts")
        out = tools["delete_conversations"].run({"about": "trip dakar"}).text
        assert "Deleted 1 conversation" in out
        assert trip.id not in app.state.agent.tasks and keep.id in app.state.agent.tasks

        app.state.bots.create("Researcher", template="researcher")
        assert "Deleted the teammate Researcher" in tools["delete_teammate"].run({"name": "researcher"}).text
        assert all(b.name != "Researcher" for b in app.state.bots.items.values())
        refused = None
        try:
            tools["delete_teammate"].run({"name": "Compii"})
        except Exception as e:  # noqa: BLE001
            refused = str(e)
        assert refused and "reset" in refused

        app.state.agent.toolbox.remember({"fact": "Prefers tea"})
        said = tools["reset_compii"].run({"what": ["memory", "conversations"]}).text
        assert "forgot 1 saved fact" in said and "deleted 1 conversation" in said
        assert app.state.agent.toolbox.memories() == []

"""Bots: named teammates with their own role, memory and a thread that survives restarts."""

import asyncio
import time

from fastapi.testclient import TestClient

from compii_core.agent import BrainReply, ToolCall
from compii_core.bots import Bots
from compii_core.chats import load as load_chats, restore as restore_chats, save as save_chats
from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401 - fixtures


class SystemSpy(ScriptBrain):
    def __init__(self, calls=None, final="Done."):
        super().__init__(calls or [], final)
        self.systems: list[str] = []

    async def step(self, system, messages, tools):
        self.systems.append(system)
        return await super().step(system, messages, tools)


def _app(home, brain, token="tok"):
    return build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token=token,
                     keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))


def test_registry_starts_with_compii_and_keeps_its_primary(home):
    bots = Bots(home["workspace"] / "bots.json")
    primary = bots.primary()
    assert primary is not None and primary.primary and primary.name == "Compii"
    try:
        bots.delete(primary.id)
    except ValueError as e:
        assert "primary" in str(e).lower()
    else:
        raise AssertionError("the primary bot must not be removable")


def test_bots_are_created_from_a_template_and_remember_facts(home):
    bots = Bots(home["workspace"] / "bots.json")
    inbox = bots.create("Inbox Manager", template="inbox")
    assert inbox.job and "mail" in inbox.instructions.lower()
    bots.add_fact(inbox.id, "Only surfaces mail that needs a reply today.")
    bots.add_fact(inbox.id, "Only surfaces mail that needs a reply today.")
    reloaded = Bots(home["workspace"] / "bots.json")
    again = reloaded.get(inbox.id)
    assert again is not None
    assert again.facts == ["Only surfaces mail that needs a reply today."]
    assert "Inbox Manager" in again.prompt() and "reply today" in again.prompt()
    assert reloaded.forget_fact(inbox.id, 0)
    assert reloaded.get(inbox.id).facts == []


def test_duplicate_bot_names_are_refused(home):
    bots = Bots(home["workspace"] / "bots.json")
    bots.create("Researcher")
    try:
        bots.create("researcher")
    except ValueError as e:
        assert "already" in str(e).lower()
    else:
        raise AssertionError("two bots with the same name would make @mentions ambiguous")


def test_the_bot_role_and_its_memory_reach_the_model(home):
    brain = SystemSpy([])
    app = _app(home, brain)
    bot = app.state.bots.create("Inbox Manager", template="inbox")
    app.state.bots.add_fact(bot.id, "Drafts stay under 80 words.")

    async def go():
        task = app.state.agent.start("triage today's mail", bot_id=bot.id)
        await asyncio.wait_for(task.runner, 10)
        return task

    task = asyncio.run(go())
    assert task.bot_id == bot.id
    assert "Inbox Manager" in brain.systems[0]
    assert "Drafts stay under 80 words." in brain.systems[0]
    assert all(e.get("bot_id") == bot.id for e in task.events)


def test_remember_bot_tool_saves_the_fact_for_that_bot(home):
    brain = ScriptBrain([("remember_bot", {"fact": "Always close with a one-line summary."})], final="Noted.")
    app = _app(home, brain)
    bot = app.state.bots.create("Researcher")

    async def go():
        task = app.state.agent.start("research something", bot_id=bot.id)
        await asyncio.wait_for(task.runner, 10)
        return task

    asyncio.run(go())
    facts = next(b for b in app.state.bots.view() if b["id"] == bot.id)["facts"]
    assert facts == ["Always close with a one-line summary."]


def test_bot_api_creates_edits_and_deletes(home):
    app = _app(home, ScriptBrain([]))
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        view = client.get("/bots", headers=h).json()
        assert view["primary"] and len(view["bots"]) == 1
        created = client.post("/bots", json={"name": "Scheduler", "template": "scheduler"}, headers=h)
        assert created.status_code == 200
        bot = next(b for b in created.json()["bots"] if b["name"] == "Scheduler")
        edited = client.patch(f"/bots/{bot['id']}", json={"pinned": True, "job": "Owns my week"}, headers=h).json()
        assert next(b for b in edited["bots"] if b["id"] == bot["id"])["pinned"]
        with_fact = client.post(f"/bots/{bot['id']}/facts", json={"fact": "Fridays are meeting-free."}, headers=h).json()
        assert next(b for b in with_fact["bots"] if b["id"] == bot["id"])["facts"] == ["Fridays are meeting-free."]
        assert client.delete(f"/bots/{bot['id']}/facts/0", headers=h).status_code == 200
        assert client.delete(f"/bots/{bot['id']}", headers=h).status_code == 200
        assert len(client.get("/bots", headers=h).json()["bots"]) == 1


def test_conversations_keep_their_bot_after_a_restart(home):
    brain = ScriptBrain([], final="Mail triaged: 2 things need you.")
    app = _app(home, brain)
    bot = app.state.bots.create("Inbox Manager", template="inbox")

    async def go():
        task = app.state.agent.start("triage my mail", bot_id=bot.id)
        await asyncio.wait_for(task.runner, 10)
        return task

    task = asyncio.run(go())
    files = [t for t in app.state.agent.tasks.values()]
    save_chats(home["workspace"] / "chats.json", files)

    again = _app(home, ScriptBrain([]))
    records = load_chats(home["workspace"] / "chats.json")
    restore_chats(again.state.agent, records, set(again.state.bots.items), again.state.bots.primary().id)
    restored = again.state.agent.tasks[task.id]
    assert restored.bot_id == bot.id
    assert restored.status == "done"
    assert restored.request == "triage my mail"
    assert [e["type"] for e in restored.events][-1] == "task_finished"
    assert restored.messages[-1]["role"] == "assistant"


class SlowBrain(ScriptBrain):
    async def step(self, system, messages, tools):
        await asyncio.sleep(30)
        return await super().step(system, messages, tools)


def test_an_unfinished_thread_comes_back_stopped_not_forever_waiting(home):
    app = _app(home, SlowBrain([]))
    bot = app.state.bots.primary()

    async def go():
        task = app.state.agent.start("something long", bot_id=bot.id)
        await asyncio.sleep(.05)
        save_chats(home["workspace"] / "chats.json", [task])
        task.runner.cancel()
        return task.id

    task_id = asyncio.run(go())
    records = load_chats(home["workspace"] / "chats.json")
    fresh = _app(home, ScriptBrain([]))
    restore_chats(fresh.state.agent, records, set(fresh.state.bots.items), bot.id)
    got = fresh.state.agent.tasks[task_id]
    assert got.status == "stopped"
    assert got.events[-1]["type"] == "task_finished"
    assert "restarted" in got.events[-1]["text"]

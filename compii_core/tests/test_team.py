"""Team chats: several bots share one thread, hand work to each other, and stay after a restart."""

import asyncio

from fastapi.testclient import TestClient

from compii_core.chats import load as load_chats, restore as restore_chats, save as save_chats
from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401 - fixtures


class TeamSpy(ScriptBrain):
    def __init__(self, calls=None, final="Done."):
        super().__init__(calls or [], final)
        self.systems: list[str] = []
        self.tool_names: list[set[str]] = []

    async def step(self, system, messages, tools):
        self.systems.append(system)
        self.tool_names.append({t["name"] for t in tools})
        return await super().step(system, messages, tools)


def _app(home, brain, token="tok"):
    return build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token=token,
                     keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))


def _run(app, request, bot_id, team=None):
    async def go():
        task = app.state.agent.start(request, bot_id=bot_id, team=team)
        await asyncio.wait_for(task.runner, 10)
        return task

    return asyncio.run(go())


def test_a_handoff_switches_the_speaker_and_gives_them_the_note(home):
    brain = TeamSpy([("handoff", {"bot": "Researcher", "note": "Find three options under €900."})],
                    final="Here are three, with links.")
    app = _app(home, brain)
    inbox = app.state.bots.create("Inbox Manager", template="inbox")
    researcher = app.state.bots.create("Researcher", template="researcher")
    team = [app.state.bots.primary().id, inbox.id, researcher.id]

    task = _run(app, "Find me a laptop and clear my mail", inbox.id, team)

    assert task.bot_id == researcher.id
    handoffs = [e for e in task.events if e["type"] == "handoff"]
    assert len(handoffs) == 1
    assert handoffs[0]["from"] == "Inbox Manager" and handoffs[0]["to"] == "Researcher"
    assert "€900" in handoffs[0]["note"]
    assert task.events[-1]["type"] == "task_finished" and task.events[-1]["bot_id"] == researcher.id
    # The second model call is made as the Researcher, who is told who else is on the team.
    assert "You are Researcher, one of Compii's teammates" in brain.systems[1]
    assert "Inbox Manager" in brain.systems[1] and "team chat" in brain.systems[1]
    assert "handoff" in brain.tool_names[1]


def test_a_one_to_one_chat_has_no_handoff_tool(home):
    brain = TeamSpy([], final="All yours.")
    app = _app(home, brain)
    inbox = app.state.bots.create("Inbox Manager", template="inbox")

    _run(app, "sort my inbox", inbox.id)

    assert "handoff" not in brain.tool_names[0]
    assert "team chat" not in brain.systems[0]


def test_at_mention_picks_who_answers(home):
    brain = TeamSpy([], final="Three good ones.")
    app = _app(home, brain)
    inbox = app.state.bots.create("Inbox Manager", template="inbox")
    researcher = app.state.bots.create("Researcher", template="researcher")
    team = [inbox.id, researcher.id]

    task = _run(app, "@Researcher compare three options", inbox.id, team)

    assert task.bot_id == researcher.id
    first = next(e for e in task.events if e["type"] == "handoff")
    assert first["by"] == "user" and first["to_id"] == researcher.id
    assert "You are Researcher, one of Compii's teammates" in brain.systems[0]
    assert "handoff" in brain.tool_names[0]


def test_a_handoff_to_someone_not_on_the_team_is_refused(home):
    brain = TeamSpy([("handoff", {"bot": "Ghost", "note": "Do it."})], final="I'll do it myself.")
    app = _app(home, brain)
    a = app.state.bots.create("Inbox Manager", template="inbox")
    b = app.state.bots.create("Researcher", template="researcher")

    task = _run(app, "something", a.id, [a.id, b.id])

    assert task.bot_id == a.id
    assert not [e for e in task.events if e["type"] == "handoff"]
    assert any("No teammate called Ghost" in str(m["content"]) for m in task.messages if m["role"] == "user")


def test_team_tasks_keep_their_team_after_a_restart(home):
    brain = TeamSpy([("handoff", {"bot": "Researcher", "note": "Compare them."})], final="Done here.")
    app = _app(home, brain)
    primary = app.state.bots.primary()
    inbox = app.state.bots.create("Inbox Manager", template="inbox")
    researcher = app.state.bots.create("Researcher", template="researcher")
    task = _run(app, "research then file it", primary.id, [primary.id, inbox.id, researcher.id])

    save_chats(home["workspace"] / "chats.json", list(app.state.agent.tasks.values()))
    again = _app(home, ScriptBrain([]))
    restore_chats(again.state.agent, load_chats(home["workspace"] / "chats.json"),
                  set(again.state.bots.items), again.state.bots.primary().id)
    restored = again.state.agent.tasks[task.id]
    assert restored.team == [primary.id, inbox.id, researcher.id]
    assert restored.bot_id == researcher.id


def test_the_api_starts_a_team_and_refuses_more_than_six(home):
    app = _app(home, ScriptBrain([], final="On it."))
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        made = [app.state.bots.create(f"Bot {i}") for i in range(1, 8)]
        ids = [b.id for b in made]
        task = client.post("/tasks", json={"request": "handle this together", "bot_id": ids[0], "team": ids[:3]},
                           headers=h).json()
        assert task["team"] == ids[:3]
        listed = client.get("/tasks", headers=h).json()
        assert next(t for t in listed if t["id"] == task["id"])["team"] == ids[:3]
        too_many = client.post("/tasks", json={"request": "all of you", "team": ids}, headers=h)
        assert too_many.status_code == 400
        one = client.post("/tasks", json={"request": "just you", "bot_id": ids[0], "team": [ids[0]]}, headers=h)
        assert one.json()["team"] == []


def test_compii_knows_its_team_before_it_is_asked(home):
    brain = TeamSpy([], final="On it.")
    app = _app(home, brain)
    researcher = app.state.bots.create("Researcher", template="researcher")
    app.state.bots.update(researcher.id, trust="trusted")
    app.state.bots.create("Inbox Manager", template="inbox")

    _run(app, "organise my week", None)

    system = brain.systems[0]
    assert "Your team, live" in system
    assert "Researcher — Turns a question into a sourced brief" in system
    assert "Trust: trusted" in system
    assert "Inbox Manager" in system and "on probation (drafts only)" in system


def test_talking_to_a_probation_bot_directly_keeps_its_probation(home):
    brain = TeamSpy([], final="Draft ready.")
    app = _app(home, brain)
    analyst = app.state.bots.create("Analyst", job="Reads numbers out of files")

    task = _run(app, "summarise the invoice", analyst.id)

    assert task.probation
    assert "You are on probation" in brain.systems[0]


def test_a_trusted_bot_chatted_directly_keeps_its_trust(home):
    brain = TeamSpy([], final="Done.")
    app = _app(home, brain)
    analyst = app.state.bots.create("Analyst", job="Reads numbers out of files")
    app.state.bots.update(analyst.id, trust="trusted")

    task = _run(app, "summarise the invoice", analyst.id)

    assert not task.probation
    assert "You are on probation" not in brain.systems[0]

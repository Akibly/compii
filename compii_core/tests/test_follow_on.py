"""One train of thought stays one conversation: a quick ask minutes after the last answer
carries that thread on, and a thread that does start fresh still hears what was just said."""

import asyncio

from fastapi.testclient import TestClient

from compii_core.agent import FOLLOW_ON_SECONDS
from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import home, quiet_voice  # noqa: F401 - fixture
from test_honest_and_coach import Scripted


class Seeing(Scripted):
    """Scripted, keeping the system prompt each step was answered with."""

    def __init__(self, replies):
        super().__init__(replies)
        self.systems = []

    async def step(self, system, messages, tools):
        self.systems.append(system)
        return await super().step(system, messages, tools)


def _app(home, brain):
    return build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t",
                     keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))


async def _done(task):
    await asyncio.wait_for(task.runner, 10)
    return task


def test_a_quick_ask_minutes_later_carries_the_conversation_on(home):
    brain = Seeing(["Accra is 24 degrees and sunny.", "Tomorrow looks like rain, around 22."])
    agent = _app(home, brain).state.agent

    async def go():
        first = await _done(agent.start("What's the weather in Accra?"))
        went = agent.carry_on("and tomorrow?")
        assert went is first
        await _done(went)
        return first

    first = asyncio.run(go())
    assert len(agent.tasks) == 1
    said = [m["content"] for m in brain.seen[1] if m["role"] == "user"]
    assert said[0].startswith("What's the weather in Accra?") and said[-1].startswith("and tomorrow?")
    assert first.status == "done"


def test_new_topic_an_old_thread_or_a_routine_open_their_own(home):
    brain = Seeing(["Sure."] * 4)
    agent = _app(home, brain).state.agent

    async def go():
        first = await _done(agent.start("Plan my week"))
        assert agent.carry_on("New topic: what is 2+2?") is None
        first.active -= FOLLOW_ON_SECONDS + 5  # the last word was more than ten minutes ago
        assert agent.carry_on("and the weekend?") is None
        job = await _done(agent.start("Check the inbox", origin={"routine": "r1", "title": "Inbox"}))
        assert agent.recent_conversation() is not job
        assert agent.carry_on("what did it find?") is None

    asyncio.run(go())


def test_a_new_conversation_hears_the_one_just_before_it(home):
    brain = Seeing(["Your flight to Lagos leaves at 9:40.", "Done, noted."])
    agent = _app(home, brain).state.agent

    async def go():
        await _done(agent.start("When is my flight to Lagos?"))
        return await _done(agent.start("Remind me of that again"))

    second = asyncio.run(go())
    assert "When is my flight to Lagos?" in brain.systems[1]
    assert "Compii: Your flight to Lagos leaves at 9:40." in brain.systems[1]
    seen = [e for e in second.events if e["type"] == "context"][0]
    assert any(i["source"] == "earlier_chat" and i["kind"] == "conversation" for i in seen["items"])
    # Nothing came before the first conversation, so it was told nothing.
    assert "in another conversation" not in brain.systems[0]


def test_the_user_can_strike_the_earlier_conversation_off(home):
    brain = Seeing(["Ghana uses GMT.", "Hello!"])
    agent = _app(home, brain).state.agent

    async def go():
        await _done(agent.start("What time zone is Ghana in?"))
        item = next(i for i in (await agent.preview_context())["items"] if i["source"] == "earlier_chat")
        await _done(agent.start("hello", context_off=[item["id"]]))

    asyncio.run(go())
    assert "Ghana" not in brain.systems[1]


def test_the_endpoint_follows_on_only_when_asked(home):
    app = _app(home, Seeing(["One.", "Two.", "Three."]))
    h = {"X-Compii-Token": "t"}
    with TestClient(app) as client, client.websocket_connect("/events?t=t") as ws:
        def finished():
            while ws.receive_json()["type"] != "task_finished":
                pass

        first = client.post("/tasks", json={"request": "first"}, headers=h).json()["id"]
        finished()
        again = client.post("/tasks", json={"request": "more", "follow_on": True}, headers=h).json()["id"]
        finished()
        assert again == first
        fresh = client.post("/tasks", json={"request": "a new chat"}, headers=h).json()["id"]
        finished()
        assert fresh != first

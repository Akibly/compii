"""Quick spoken questions stay small and fast; rate limits hand over at once."""

import asyncio

import httpx

from compii_core.agent import MORE_TOOLS, QUICK_TOOLS
from compii_core.keys import MemoryKeyStore
from compii_core.providers import FallbackBrain, OpenAICompatBrain
from compii_core.server import build_app

from test_core import ScriptBrain, home  # noqa: F401 - fixture


class ToolSpy(ScriptBrain):
    def __init__(self, calls, final="Done."):
        super().__init__(calls, final)
        self.tool_names: list[list[str]] = []

    async def step(self, system, messages, tools):
        self.tool_names.append([t["name"] for t in tools])
        return await super().step(system, messages, tools)


def _run(app, request, origin):
    async def go():
        task = app.state.agent.start(request, origin=origin)
        await asyncio.wait_for(task.runner, 10)
        return task

    return asyncio.run(go())


def test_a_quick_spoken_question_sends_only_the_slim_tool_set(home):
    brain = ToolSpy([])
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t", keys=MemoryKeyStore())
    _run(app, "what time zone is Ghana in", {"buddy": True})
    sent = brain.tool_names[0]
    assert MORE_TOOLS["name"] in sent and len(sent) <= len(QUICK_TOOLS) + 1
    assert "create_spreadsheet" not in sent


def test_more_tools_unlocks_everything_mid_task(home):
    brain = ToolSpy([("more_tools", {})])
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t", keys=MemoryKeyStore())
    _run(app, "what's up", {"buddy": True})
    assert "create_spreadsheet" not in brain.tool_names[0]
    assert "create_spreadsheet" in brain.tool_names[1]


def test_typed_and_file_requests_get_every_tool(home):
    for request, origin in [("hello", None), ("tidy my downloads folder", {"buddy": True})]:
        brain = ToolSpy([])
        app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t",
                        keys=MemoryKeyStore())
        _run(app, request, origin)
        assert "create_spreadsheet" in brain.tool_names[0], request


def test_over_the_limit_hands_to_the_backup_without_waiting():
    hits = {"main": 0}

    def main(request):
        hits["main"] += 1
        return httpx.Response(429, headers={"retry-after": "20"}, json={"error": {"message": "Rate limit reached"}})

    def backup(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": "Hi!"}, "finish_reason": "stop"}]})

    brain = FallbackBrain(OpenAICompatBrain("https://a/v1", "m", "k", transport=httpx.MockTransport(main)),
                          OpenAICompatBrain("https://b/v1", "m2", "k", transport=httpx.MockTransport(backup)))
    import time

    start = time.monotonic()
    reply = asyncio.run(brain.step("s", [{"role": "user", "content": "hi"}], []))
    assert reply.text == "Hi!" and hits["main"] == 1 and time.monotonic() - start < 1


class Recorder(ScriptBrain):
    def __init__(self, answers):
        super().__init__([])
        self.answers = answers
        self.sent: list[list[dict]] = []

    async def step(self, system, messages, tools):
        from compii_core.agent import BrainReply

        self.sent.append(messages)
        text = self.answers[len(self.sent) - 1]
        return BrainReply([{"type": "text", "text": text}], text, [], "end_turn")


def test_follow_ups_remember_the_conversation_compactly(home):
    brain = Recorder(["Ghana uses GMT.", "Yes, London is the same in winter."])
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t", keys=MemoryKeyStore())
    agent = app.state.agent

    async def go():
        t = agent.start("What time zone is Ghana in?\n\n<untrusted_data>a long screen reading</untrusted_data>",
                        origin={"buddy": True})
        await asyncio.wait_for(t.runner, 10)
        t2 = agent.reply(t.id, "Is that the same as London?")
        await asyncio.wait_for(t2.runner, 10)

    asyncio.run(go())
    second = brain.sent[1]
    assert [m["role"] for m in second] == ["user", "assistant", "user"]
    assert second[0]["content"] == "What time zone is Ghana in?"  # old screen reading left out
    assert second[1]["content"] == "Ghana uses GMT." and second[2]["content"] == "Is that the same as London?"


def test_compact_history_drops_tool_details_and_keeps_roles_alternating():
    from compii_core.agent import compact_history

    msgs = [
        {"role": "user", "content": "find my invoice"},
        {"role": "assistant", "content": [{"type": "text", "text": "Looking."},
                                          {"type": "tool_use", "id": "a", "name": "find_files", "input": {}}]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "a", "content": "huge listing"}]},
        {"role": "assistant", "content": [{"type": "text", "text": "Found it in Downloads."}]},
    ]
    out = compact_history(msgs)
    assert out == [{"role": "user", "content": "find my invoice"},
                   {"role": "assistant", "content": "Looking.\nFound it in Downloads."}]


def test_buddy_continues_the_last_conversation_until_new_topic():
    import time as _t

    from compii_core import buddy as b

    class V:
        settings = type("S", (), {"speak_replies": False})()
        on_auto_end = None
        def annotate(self, t): return t
        def say(self, t): pass

    class A:
        def __init__(self): self.calls = []
        def start(self, text, origin=None, screen=None):
            self.calls.append(("start", text)); return type("T", (), {"id": f"t{len(self.calls)}"})()
        def reply(self, tid, text, screen=None):
            self.calls.append(("reply", tid)); return type("T", (), {"id": tid})()

    async def no_intent(text): return False

    agent = A()
    bud = b.Buddy(V(), agent, lambda e: None, no_intent, lambda: None, snapshot=lambda: None, cursor=lambda: (0, 0))
    asyncio.run(bud._handle("what time zone is Ghana in", None))
    bud.on_task_event({"type": "task_finished", "task_id": "t1", "text": "GMT."})
    asyncio.run(bud._handle("and London?", None))
    asyncio.run(bud._handle("new topic", None))
    asyncio.run(bud._handle("how tall is Kilimanjaro", None))
    assert [c[0] for c in agent.calls] == ["start", "reply", "start"]
    bud._last_done = _t.monotonic() - b.FOLLOW_UP_SECONDS - 1
    asyncio.run(bud._handle("and Everest?", None))
    assert agent.calls[-1][0] == "start"  # too long ago: a fresh conversation


def test_compii_draws_on_screen_by_item_id(home):
    from compii_core.tools import Toolbox

    tb = Toolbox([home["downloads"]], home["workspace"])
    tb.snapshot = {"title": "Blender", "elements": [
        {"id": "e1", "role": "Button", "name": "Add", "x": 10, "y": 20, "w": 40, "h": 20},
        {"id": "e2", "role": "MenuItem", "name": "Mesh", "x": 10, "y": 60, "w": 60, "h": 20}]}
    drawn = []
    tb.on_draw = drawn.append
    r = tb.tools["draw_on_screen"].run({"shapes": [{"kind": "circle", "target": "e1"},
                                                   {"kind": "arrow", "target": "e2", "from": "e1"}],
                                        "message": "Add, then Mesh"})
    assert "Drew 2" in r.text
    assert drawn[0]["shapes"][0]["kind"] == "circle" and drawn[0]["shapes"][0]["x"] == 10
    assert drawn[0]["shapes"][1]["from"]["y"] == 20 and drawn[0]["message"] == "Add, then Mesh"

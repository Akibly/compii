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

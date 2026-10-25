"""Follow-ups keep their context with Claude's real reply objects, and the honesty checks stop
turning ordinary answers into failures or wiping facts about work done earlier in the thread."""

import asyncio

from anthropic.types.beta import BetaServerToolUseBlock, BetaTextBlock, BetaToolUseBlock

from compii_core.agent import BrainReply, compact_history, unbacked_claims
from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import home, quiet_voice  # noqa: F401 - fixture
from test_honest_and_coach import Scripted, _final


def _app(home, brain):
    return build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t",
                     keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))


def test_compact_history_reads_claude_sdk_blocks():
    msgs = [
        {"role": "user", "content": "make notes.txt"},
        {"role": "assistant", "content": [BetaToolUseBlock(id="a", name="write_text_file", input={}, type="tool_use")]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "a", "content": "ok"}]},
        {"role": "assistant", "content": [BetaTextBlock(text="Done - notes.txt is in Documents.", type="text")]},
    ]
    assert compact_history(msgs) == [{"role": "user", "content": "make notes.txt"},
                                     {"role": "assistant", "content": "Done - notes.txt is in Documents."}]


class ClaudeShaped(Scripted):
    """Like Scripted, but replies with the SDK objects the real Claude brain returns."""

    async def step(self, system, messages, tools):
        reply = await super().step(system, messages, tools)
        blocks = [BetaTextBlock(text=b["text"], type="text") if b["type"] == "text" else
                  BetaToolUseBlock(id=b["id"], name=b["name"], input=b["input"], type="tool_use")
                  for b in reply.content]
        return BrainReply(blocks, reply.text, reply.tool_calls, reply.stop_reason)


def test_a_follow_up_with_claude_still_sees_the_earlier_answer(home):
    brain = ClaudeShaped(["Ghana uses GMT.", "Yes, the same as London in winter."])
    app = _app(home, brain)

    async def go():
        agent = app.state.agent
        t = agent.start("What time zone is Ghana in?")
        await asyncio.wait_for(t.runner, 10)
        agent.reply(t.id, "Is that the same as London?")
        await asyncio.wait_for(t.runner, 10)
        return t

    asyncio.run(go())
    second = brain.seen[1]
    assert [m["role"] for m in second] == ["user", "assistant", "user"]
    assert second[1]["content"] == "Ghana uses GMT."


def test_let_me_know_is_an_answer_not_an_unfinished_plan(home):
    said = "Paris is the capital of France. Let me know if you want me to look up more."
    brain = Scripted([said])
    task = asyncio.run(_run_plain(_app(home, brain), "capital of France?"))
    assert len(brain.seen) == 1  # no "you described what you would do" nudge
    assert task.status == "done" and _final(task) == said


def test_words_after_the_nudge_are_delivered_not_failed(home):
    brain = Scripted(["I'll check the prices for you.",
                      "I need to know which city you mean before I can look anything up."])
    task = asyncio.run(_run_plain(_app(home, brain), "find the best one"))
    assert task.status == "done"
    assert _final(task).startswith("I need to know which city")


def test_a_follow_up_about_a_file_saved_earlier_keeps_its_answer(home):
    target = home["downloads"] / "notes.txt"
    brain = Scripted([("", [("write_text_file", {"path": str(target), "content": "Notes."})]),
                      "It's saved in your Downloads folder.",
                      "It's saved in Downloads as notes.txt."])
    app = _app(home, brain)

    async def go():
        agent = app.state.agent
        t = agent.start("make a note of this")
        await asyncio.wait_for(t.runner, 10)
        agent.reply(t.id, "where did it go?")
        await asyncio.wait_for(t.runner, 10)
        return t

    task = asyncio.run(go())
    assert _final(task) == "It's saved in Downloads as notes.txt."


def test_pointing_is_never_backed_by_an_earlier_turn():
    assert unbacked_claims("I'm pointing at it now.", set(), {"point_at"}) == ["pointed at it"]
    assert unbacked_claims("It's saved in Documents.", set(), {"write_text_file"}) == []


def test_claudes_own_web_search_backs_i_searched(home):
    class SearchesServerSide(Scripted):
        async def step(self, system, messages, tools):
            self.seen.append(messages)
            blocks = [BetaServerToolUseBlock(id="s1", name="web_search", input={"query": "q"},
                                             type="server_tool_use"),
                      BetaTextBlock(text="I searched and the results show it opens at 9.", type="text")]
            return BrainReply(blocks, blocks[1].text, [], "end_turn")

    brain = SearchesServerSide([])
    task = asyncio.run(_run_plain(_app(home, brain), "when does the museum open?"))
    assert _final(task) == "I searched and the results show it opens at 9."


async def _run_plain(app, request):
    t = app.state.agent.start(request)
    await asyncio.wait_for(t.runner, 10)
    return t


def test_an_empty_reply_after_real_work_is_asked_for_words(home):
    target = home["downloads"] / "a.txt"
    brain = Scripted([("", [("write_text_file", {"path": str(target), "content": "x"})]), "",
                      "I wrote a.txt in Downloads."])
    task = asyncio.run(_run_plain(_app(home, brain), "write a file"))
    assert "reply was empty" in brain.seen[2][-1]["content"][0]["text"]
    assert task.status == "done" and _final(task) == "I wrote a.txt in Downloads."


def test_silence_after_real_work_reports_what_ran_not_nothing(home):
    target = home["downloads"] / "a.txt"
    brain = Scripted([("", [("write_text_file", {"path": str(target), "content": "x"})]), "", ""])
    task = asyncio.run(_run_plain(_app(home, brain), "write a file"))
    assert task.status == "done"
    assert _final(task).startswith("I did this but didn't put it into words. What ran:")
    assert target.exists()


def test_running_out_of_steps_ends_with_a_real_report(home):
    calls = [("", [("list_folder", {"path": str(home["downloads"])})])] * 3
    brain = Scripted([*calls, "I listed Downloads three times; the sorting is still left."])
    app = _app(home, brain)

    async def go():
        t = app.state.agent.start("sort my downloads")
        t.max_steps = 3
        await asyncio.wait_for(t.runner, 20)
        return t

    task = asyncio.run(go())
    assert "out of steps" in brain.seen[3][-1]["content"][0]["text"]
    assert _final(task) == "I listed Downloads three times; the sorting is still left. (I ran out of steps before finishing.)"


def test_a_dropped_connection_is_retried(home, monkeypatch):
    import compii_core.agent as agent_mod

    monkeypatch.setattr(agent_mod.asyncio, "sleep", _no_wait)

    class DropsOnce(Scripted):
        async def step(self, system, messages, tools):
            if not getattr(self, "dropped", False):
                self.dropped = True
                raise RuntimeError("RemoteProtocolError: Server disconnected without sending a response.")
            return await super().step(system, messages, tools)

    task = asyncio.run(_run_plain(_app(home, DropsOnce(["Hello!"])), "hi"))
    assert task.status == "done" and _final(task) == "Hello!"


_real_sleep = asyncio.sleep


async def _no_wait(seconds, *a, **kw):
    await _real_sleep(0)

"""Usage: the ledger keeps what each answer cost, and says plainly which numbers are its own estimate."""

import asyncio
import time

import pytest
from fastapi.testclient import TestClient

from compii_core.agent import Agent, BrainReply, Task
from compii_core.journal import Journal
from compii_core.keys import MemoryKeyStore
from compii_core.ledger import Ledger, estimate, usage_tool
from compii_core.policy import ActionKind, Policy
from compii_core.providers import BrainChoice, FallbackBrain, make_brain
from compii_core.server import build_app

from test_core import home, opened, quiet_voice, toolbox  # noqa: F401 - fixtures used by these tests


# ---- writing and reading the file ------------------------------------------------


def test_an_estimate_is_characters_over_four():
    assert estimate("") == 0
    assert estimate("a" * 40) == 10


def test_a_broken_line_never_loses_the_rest(tmp_path):
    led = Ledger(tmp_path / "usage.jsonl")
    led.record(provider="groq", model="llama", prompt=100, completion=20, ms=900)
    with (tmp_path / "usage.jsonl").open("a", encoding="utf-8") as f:
        f.write("not json at all\n")
    led.record(provider="groq", model="whisper-large-v3-turbo", kind="listening", ms=400, audio_ms=3000)
    rows = led.entries()
    assert [r["kind"] for r in rows] == ["step", "listening"]
    assert rows[0]["prompt"] == 100 and rows[1]["audio_ms"] == 3000


def test_an_unwritable_file_costs_nobody_their_answer(tmp_path):
    blocker = tmp_path / "usage.jsonl"
    blocker.write_text("not a folder", encoding="utf-8")  # the ledger's own path is in the way
    led = Ledger(blocker / "today.jsonl")
    assert led.record(provider="groq", prompt=10)["kind"] == "step"
    assert led.entries() == [] and led.report()["total"]["steps"] == 0


def test_the_file_stays_a_bounded_window(tmp_path, monkeypatch):
    monkeypatch.setattr("compii_core.ledger.MAX_LINES", 6)
    led = Ledger(tmp_path / "usage.jsonl")
    for i in range(10):
        led.record(provider="groq", model="m", prompt=i)
    rows = led.entries()
    assert len(rows) <= 6 and rows[-1]["prompt"] == 9


# ---- the report ------------------------------------------------------------------


def test_report_adds_up_by_model_day_and_kind(tmp_path):
    led = Ledger(tmp_path / "usage.jsonl")
    led.record(provider="groq", model="openai/gpt-oss-20b", prompt=1000, completion=200, ms=1200)
    led.record(provider="groq", model="openai/gpt-oss-20b", prompt=50, completion=10, est=True, ms=300, ok=False)
    led.record(provider="ollama", model="qwen3", prompt=800, completion=100, ms=9000)
    led.record(provider="groq", model="whisper-large-v3-turbo", kind="listening", ms=500, audio_ms=4000)
    r = led.report(days=1)
    t = r["total"]
    assert t["steps"] == 4 and t["prompt"] == 1850 and t["completion"] == 310
    assert t["tokens"] == 2160 and t["estimated"] == 1 and t["failed"] == 1
    assert t["heard_ms"] == 4000
    assert r["by_model"][0]["model"] == "groq · openai/gpt-oss-20b" and r["by_model"][0]["steps"] == 2
    assert {k["kind"] for k in r["by_kind"]} == {"step", "listening"}
    assert r["local_share"] == 0.25
    assert r["biggest"]["tokens"] == 1200
    assert r["last_minute_steps"] == 4
    assert r["days"] == 1 and "prices" in r["note"]


def test_a_window_only_counts_the_days_it_covers(tmp_path):
    led = Ledger(tmp_path / "usage.jsonl")
    led.record(provider="groq", prompt=10, at=time.time() - 40 * 86400)
    led.record(provider="groq", prompt=20)
    assert led.report(days=7)["total"]["steps"] == 1
    assert led.report(days=90)["total"]["steps"] == 2
    assert led.report(days=0)["days"] == 7  # junk in, a sane window out


def test_the_words_say_which_numbers_are_estimates(tmp_path):
    led = Ledger(tmp_path / "usage.jsonl")
    led.record(provider="groq", model="llama", prompt=4000, completion=300, est=True, ms=60000)
    led.record(provider="groq", model="whisper-large-v3-turbo", kind="listening", ms=400, audio_ms=9000)
    words = led.text(days=7)
    assert "4,300 tokens" in words and "1.0 minutes of waiting" in words
    assert "9 seconds of speech" in words and "not tokens" in words
    assert "1 of those steps counted their tokens by estimate" in words
    assert "No AI steps" in Ledger(tmp_path / "nothing.jsonl").text()


# ---- counting the steps the agent takes -------------------------------------------


def test_a_step_is_counted_against_the_brain_that_answered(toolbox, tmp_path):
    class Groq:
        provider, model = "groq", "openai/gpt-oss-20b"

        async def step(self, system, messages, tools):
            raise AssertionError("not used here")

    led = Ledger(tmp_path / "usage.jsonl")
    agent = Agent(Groq(), toolbox, Policy(), Journal(tmp_path / "j.jsonl"), lambda e: asyncio.sleep(0))
    agent.ledger = led
    task = Task("t1", "count this step")
    agent._count(task, BrainReply([], "hi", [], "end_turn", {"prompt": 120, "completion": 34}),
                 "system words", [{"role": "user", "content": "hello"}], time.monotonic() - 0.5)
    row = led.entries()[0]
    assert row["provider"] == "groq" and row["model"] == "openai/gpt-oss-20b"
    assert row["prompt"] == 120 and row["completion"] == 34 and row["est"] is False
    assert row["ms"] >= 400

    # A provider that reports nothing: count the payload and mark it an estimate.
    agent._count(task, BrainReply([], "a" * 400, [], "end_turn"), "s" * 800,
                 [{"role": "user", "content": "t" * 800}], time.monotonic())
    second = led.entries()[1]
    assert second["est"] is True and second["prompt"] > 300 and second["completion"] == 100

    agent.ledger = None  # no ledger: counting is simply not done, and nothing breaks
    agent._count(task, BrainReply([], "x", [], "end_turn"), "", [], time.monotonic())


def test_a_refusal_is_recorded_as_a_failed_step(toolbox, tmp_path):
    class Silent:
        provider, model = "custom", "thing"

        async def step(self, system, messages, tools):
            raise AssertionError("not used here")

    led = Ledger(tmp_path / "usage.jsonl")
    agent = Agent(Silent(), toolbox, Policy(), Journal(tmp_path / "j.jsonl"), lambda e: asyncio.sleep(0))
    agent.ledger = led
    agent._count(Task("t2", "refuse this step"), BrainReply([], "", [], "refusal"), "", [], time.monotonic())
    assert led.entries()[0]["ok"] is False


# ---- which brain a fallback actually used -----------------------------------------


class _Stub:
    def __init__(self, provider: str, model: str, fails: bool = False) -> None:
        self.provider, self.model, self.fails = provider, model, fails

    async def step(self, system, messages, tools):
        if self.fails:
            raise RuntimeError("free tier is out")
        return BrainReply([], self.model, [], "end_turn")

    async def step_stream(self, system, messages, tools, on_text):
        return await self.step(system, messages, tools)


def test_the_fallback_reports_which_brain_actually_answered():
    seen: list[str] = []
    out_of_quota = FallbackBrain(_Stub("groq", "big", fails=True), _Stub("gemini", "small"), seen.append)
    assert asyncio.run(out_of_quota.step("s", [], [])).text == "small"
    assert asyncio.run(out_of_quota.step_stream("s", [], [], lambda t: asyncio.sleep(0))).text == "small"
    assert (out_of_quota.provider, out_of_quota.model) == ("gemini", "small")
    assert seen == ["free tier is out", "free tier is out"]

    healthy = FallbackBrain(_Stub("groq", "big"), _Stub("gemini", "small"))
    asyncio.run(healthy.step("s", [], []))
    assert healthy.model == "big"
    asyncio.run(healthy.step_stream("s", [], [], lambda t: asyncio.sleep(0)))
    assert healthy.model == "big"


def test_a_chosen_brain_knows_its_own_name_and_model():
    keys = MemoryKeyStore()
    brain = make_brain(BrainChoice("ollama"), keys)
    assert (brain.provider, brain.model) == ("ollama", "qwen3:4b")
    keys.set("groq", "gk")
    pair = make_brain(BrainChoice("groq", "openai/gpt-oss-20b"), keys)
    assert (pair.provider, pair.model) == ("groq", "openai/gpt-oss-20b")
    assert pair.backup.model == "openai/gpt-oss-120b"  # the stand-in is named, not blank


# ---- the tool and the route --------------------------------------------------------


def test_the_usage_tool_is_a_read_and_describes_itself(tmp_path):
    led = Ledger(tmp_path / "usage.jsonl")
    led.record(provider="groq", model="llama", prompt=40, completion=8)
    tool = usage_tool(led)
    assert tool.name == "usage_report" and tool.kind is ActionKind.READ
    assert tool.describe({"days": 30}) == "Add up what Compii has used"
    assert "48 tokens" in tool.run({"days": 7}).text
    assert tool.run({"days": "soon"}).text  # junk in, an answer out, never a crash


def test_usage_is_readable_from_the_phone_and_written_only_by_steps(home, monkeypatch):
    monkeypatch.setattr("compii_core.reach._v2ex_hot", lambda **kw: [])
    app = build_app(workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]), keys=MemoryKeyStore())
    h = {"X-Compii-Token": "tok"}
    with TestClient(app) as c:
        c.app.state.ledger.record(provider="ollama", model="qwen3", prompt=500, completion=90)
        r = c.get("/usage", params={"days": 3}, headers=h).json()
        assert r["days"] == 3 and r["total"]["tokens"] == 590
        assert r["by_model"][0]["model"] == "ollama · qwen3"
        assert c.get("/usage", headers={"X-Compii-Device": "nobody"}).status_code == 401
        assert "usage_report" in c.app.state.agent.toolbox.tools
        assert c.app.state.agent.ledger is c.app.state.ledger
        assert c.app.state.voice.ledger is c.app.state.ledger

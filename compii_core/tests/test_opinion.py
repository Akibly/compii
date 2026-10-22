"""Second opinions: a different AI, only one the user already configured, and it says which answered."""

from fastapi.testclient import TestClient

from compii_core import guard
from compii_core import opinion
from compii_core.agent import BrainReply
from compii_core.keys import MemoryKeyStore
from compii_core.ledger import Ledger
from compii_core.opinion import _usable, second_opinion_tool
from compii_core.policy import ActionKind
from compii_core.server import build_app
from compii_core.tools import ToolError

from test_core import home, quiet_voice  # noqa: F401 - fixtures used by these tests


def _tool(keys, ledger=None, current=""):
    return second_opinion_tool(keys, ledger=ledger, current=lambda: current)


def _error(tool, args) -> str:
    try:
        tool.run(args)
    except ToolError as e:
        return str(e)
    raise AssertionError("expected it to refuse")


def _reply(text="Ask it again and I would say the same.", **usage) -> BrainReply:
    return BrainReply([{"type": "text", "text": text}], text, [], "end_turn", usage)


# ---- who may be asked ------------------------------------------------------------


def test_only_a_provider_with_a_key_here_or_a_local_model_can_be_asked():
    bare = _usable(MemoryKeyStore())
    assert [n for n, _ in bare] == ["ollama"]  # the one local model with a default; nothing else configured

    keys = MemoryKeyStore()
    keys.set("groq", "gk")
    keys.set("anthropic", "ak")
    named = [n for n, _ in _usable(keys)]
    assert {"groq", "claude"} <= set(named)
    assert named.index("ollama") < named.index("groq")  # free and local beats a cloud key
    assert "mistral" not in named  # no key on this PC, so it is not on the list at all
    assert "openrouter" not in named  # it needs a model the user would have to choose


def test_the_tool_is_a_read_and_is_wrapped_as_outside_data():
    tool = _tool(MemoryKeyStore())
    assert tool.kind is ActionKind.READ and tool.long_running is True
    assert "second_opinion" in guard.UNTRUSTED_TOOLS
    assert tool.describe({"question": "is this plan sensible?"}) == "Ask another AI a second opinion"
    assert tool.describe({"question": "x", "provider": "groq"}) == "Ask groq a second opinion"


def test_a_short_question_and_an_unconfigured_provider_are_refused():
    tool = _tool(MemoryKeyStore())
    assert "Give the question" in _error(tool, {"question": "hmm?"})
    assert "no key for it" in _error(tool, {"question": "should I take the job?", "provider": "mistral"})
    assert "Configured: ollama" in _error(tool, {"question": "should I take the job?", "provider": "mistral"})


def test_with_nothing_configured_it_says_so_rather_than_inventing_an_opinion(monkeypatch):
    monkeypatch.setattr(opinion, "_usable", lambda keys: [])
    assert "No other AI is set up" in _error(_tool(MemoryKeyStore()), {"question": "what do you think of this?"})


# ---- asking ----------------------------------------------------------------------


def test_the_answer_is_attributed_and_counted(tmp_path, monkeypatch):
    led = Ledger(tmp_path / "usage.jsonl")
    asked = []

    def fake(brain, question):
        asked.append((brain.provider, brain.model, question))
        return _reply("I would read the contract first.", prompt=300, completion=12)

    monkeypatch.setattr(opinion, "_ask", fake)
    out = _tool(MemoryKeyStore(), ledger=led).run({"question": "should I sign this?"})
    assert "Ollama on this PC (qwen3:4b)" in out.text and "on this PC" in out.text
    assert "I would read the contract first." in out.text
    assert "Compare this with what you would say" in out.text
    assert asked[0] == ("ollama", "qwen3:4b", "should I sign this?")
    row = led.entries()[0]
    assert row["kind"] == "opinion" and row["provider"] == "ollama"
    assert row["prompt"] == 300 and row["completion"] == 12 and row["est"] is False


def test_a_provider_that_reports_nothing_is_counted_as_an_estimate(tmp_path, monkeypatch):
    led = Ledger(tmp_path / "usage.jsonl")
    keys = MemoryKeyStore()
    keys.set("groq", "gk")
    monkeypatch.setattr(opinion, "_ask", lambda brain, question: _reply("Yes, but check the dates."))
    out = _tool(keys, ledger=led, current="ollama").run({"question": "is thursday alright for this?"})
    assert "Groq" in out.text and "check the dates" in out.text
    row = led.entries()[0]
    assert row["provider"] == "groq" and row["est"] is True and row["prompt"] > 60
    assert row["completion"] == len("Yes, but check the dates.") // 4


def test_the_main_brain_is_skipped_so_the_opinion_is_actually_different(monkeypatch):
    keys = MemoryKeyStore()
    keys.set("groq", "gk")
    asked = []
    monkeypatch.setattr(opinion, "_ask", lambda brain, question: asked.append(brain.provider) or _reply("no"))
    out = _tool(keys, current="ollama").run({"question": "which one is faster?"})
    assert asked == ["groq"] and "Groq" in out.text and "from that provider" in out.text


def test_a_silent_or_broken_opinion_moves_on_and_then_says_what_failed(monkeypatch):
    calls = []

    def flaky(brain, question):
        calls.append(brain.provider)
        if len(calls) == 1:
            raise RuntimeError("connection reset")
        return _reply("")  # answers with nothing: still not an opinion

    keys = MemoryKeyStore()
    keys.set("groq", "gk")
    monkeypatch.setattr(opinion, "_ask", flaky)
    msg = _error(_tool(keys), {"question": "does this look right to you?"})
    assert "Nobody else answered" in msg and "connection reset" in msg and "answered with nothing" in msg
    assert "Groq" in msg  # the one that went quiet is named, so the user knows who was tried
    assert calls == ["ollama", "groq"]


def test_a_second_opinion_is_offered_by_the_running_core(home):
    app = build_app(workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                   voice=quiet_voice(home["workspace"]), keys=MemoryKeyStore())
    with TestClient(app) as c:
        tools = c.app.state.agent.toolbox.tools
        assert "second_opinion" in tools and "usage_report" in tools
        assert c.get("/health").status_code == 200

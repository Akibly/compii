"""Keeping up with a conversation: taken from real chats where Compii lost the thread.

* A model (gpt-oss) wrote a hand-off as JSON text, so the user was shown
  {"bot": "Sammy", "objective": ...} instead of the work starting.
* Misheard speech ("and I can see", "to order") was acted on as an instruction.
"""

import time

from compii_core.agent import BrainReply, ToolCall
from compii_core.providers import looks_like_json, recover_tool_call

TOOLS = [
    {"name": "delegate", "description": "", "input_schema": {"type": "object", "properties": {
        "bot": {}, "objective": {}, "done_when": {}, "context": {}, "minutes": {}},
        "required": ["bot", "objective", "done_when"]}},
    {"name": "search_web", "description": "", "input_schema": {"type": "object", "properties": {"query": {}},
                                                               "required": ["query"]}},
    {"name": "read_web_page", "description": "", "input_schema": {"type": "object", "properties": {"url": {}},
                                                                  "required": ["url"]}},
]


def _text(t: str) -> BrainReply:
    return BrainReply([{"type": "text", "text": t}], t, [], "end_turn")


def test_a_hand_off_written_as_json_becomes_the_hand_off():
    leaked = ('{\n  "bot": "Sammy",\n  "objective": "Research whether free-tier users can get API-like access",\n'
              '  "done_when": "A short summary with sources"\n}')
    r = recover_tool_call(_text(leaked), TOOLS)
    assert r.text == "" and r.stop_reason == "tool_use"
    assert [c.name for c in r.tool_calls] == ["delegate"]
    assert r.tool_calls[0].input["bot"] == "Sammy"


def test_a_named_call_in_a_code_fence_is_recovered_too():
    r = recover_tool_call(_text('```json\n{"name": "search_web", "arguments": {"query": "free tier API"}}\n```'), TOOLS)
    assert r.tool_calls[0].name == "search_web" and r.tool_calls[0].input == {"query": "free tier API"}


def test_prose_ambiguous_objects_and_real_calls_are_left_alone():
    prose = 'Here is the config you asked for: {"a": 1}'
    assert recover_tool_call(_text(prose), TOOLS).text == prose
    unknown = '{"colour": "blue", "size": 3}'
    assert recover_tool_call(_text(unknown), TOOLS).text == unknown, "fits no tool: the user asked for JSON"
    real = BrainReply([], "", [ToolCall("c1", "search_web", {"query": "x"})], "tool_use")
    assert recover_tool_call(real, TOOLS) is real


def test_json_is_held_back_while_it_streams_but_words_are_not():
    assert looks_like_json('{"bot": "Sam')
    assert looks_like_json("```json\n{")
    assert not looks_like_json("Sure — here's what I found")


class _Heard:
    """The voice object as annotate sees it, without loading a speech model."""

    def __init__(self, text, unclear=()):
        self.last_final = (text, time.monotonic())
        self.last_unclear = list(unclear)


def test_every_spoken_request_is_marked_as_possibly_misheard():
    from compii_core.voice import Voice

    said = Voice.annotate(_Heard("to order"), "to order")
    assert said.startswith("to order\n\n(Spoken, then transcribed: it may be misheard.")
    assert "ask one short question" in said and "instead of acting" in said
    doubt = Voice.annotate(_Heard("open synia", ["synia"]), "open synia")
    assert "unsure of: synia" in doubt
    typed = Voice.annotate(_Heard("something else"), "open the report")
    assert typed == "open the report", "typed text is not what was heard, so it is not marked"

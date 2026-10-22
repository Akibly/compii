"""Clicky-style cursor buddy: hold Ctrl+Alt from any app, screen-aware answers."""

import time

import numpy as np
from fastapi.testclient import TestClient

from compii_core import hotkey
from compii_core.hotkey import HoldToTalk
from compii_core.keys import MemoryKeyStore
from compii_core.screen import describe_snapshot
from compii_core.server import build_app
from compii_core.voice import RATE

from test_core import FakeMic, FakeSpeaker, ScriptBrain, home  # noqa: F401 - fixtures

CTRL, ALT, T = 0xA2, 0xA4, 0x54


def make(events):
    return HoldToTalk(lambda: events.append("start"), lambda held: events.append(("end", round(held, 1))),
                      lambda: events.append("cancel"))


def test_hold_ctrl_alt_starts_and_release_sends(monkeypatch):
    monkeypatch.setattr(hotkey, "HOLD_TO_START", 0.05)
    events = []
    h = make(events)
    h.key(CTRL, True)
    h.key(ALT, True)
    time.sleep(0.12)
    h.key(ALT, False)
    h.key(CTRL, False)
    assert events[0] == "start" and events[1][0] == "end"


def test_shortcuts_like_ctrl_alt_t_never_trigger(monkeypatch):
    monkeypatch.setattr(hotkey, "HOLD_TO_START", 0.05)
    events = []
    h = make(events)
    h.key(CTRL, True)
    h.key(ALT, True)
    h.key(T, True)  # a real shortcut: no listening at all
    time.sleep(0.1)
    h.key(T, False)
    h.key(ALT, False)
    h.key(CTRL, False)
    assert events == []
    h.key(CTRL, True)  # plain Ctrl+C style use is untouched
    h.key(0x43, True)
    h.key(0x43, False)
    h.key(CTRL, False)
    assert events == []


SNAP = {"title": "Report - Word", "app": "winword.exe", "cursor": [400, 300], "under_cursor": "Insert",
        "elements": [{"id": "e1", "role": "TabItem", "name": "Insert", "x": 100, "y": 50, "w": 60, "h": 24},
                     {"id": "e2", "role": "Button", "name": "Table", "x": 180, "y": 90, "w": 40, "h": 40}]}


def test_snapshot_text_for_the_ai_and_blocked_apps():
    text = describe_snapshot(SNAP)
    assert "e2 · Button · Table" in text and "over “Insert”" in text
    assert "doesn't read it" in describe_snapshot({"title": "Vault - Bitwarden", "blocked": True})


class Mic(FakeMic):
    """Says something, then goes quiet."""

    def start(self, on_audio):
        speech = (np.sin(np.arange(RATE // 10) / 3) * .2).astype(np.float32)
        for _ in range(5):
            on_audio(speech)

    def stop(self):
        pass


def test_buddy_round_trip_answers_about_the_screen_and_points_by_id(home, monkeypatch):
    from compii_core.voice import Voice

    monkeypatch.setattr("compii_core.vision.grab_foreground", lambda: None)  # no live desktop in tests
    calls = [("point_at", {"target": "e2", "message": "This one."})]
    brain = ScriptBrain(calls, final="Click Table, here.")
    voice = Voice(home["workspace"] / "models", lambda e: None, recorder_factory=Mic, speaker=FakeSpeaker())
    voice.can_listen = lambda: True
    voice.transcribe = lambda audio, final=True: "how do I add a table"
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="tok", voice=voice,
                    keys=MemoryKeyStore())
    buddy = app.state.buddy
    buddy._snapshot = lambda: SNAP
    buddy._cursor = lambda: (400, 300)
    with TestClient(app) as c, c.websocket_connect("/events?t=tok") as ws:
        buddy.start()
        buddy.end(1.0)  # held, then released: send now
        states, points = [], []
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            e = ws.receive_json()
            if e["type"] == "voice_buddy":
                states.append(e["state"])
                if e["state"] == "answer":
                    answer = e
                    break
            if e["type"] == "point":
                points.append(e)
        assert states[:2] == ["listening", "thinking"] and states[-1] == "answer"
        assert answer["text"] == "Click Table, here."
        assert points and points[0]["x"] == 180 and points[0]["name"] == "Table"
        first = brain.seen[0][0]["content"]
        assert "untrusted_data" in first and "e2 · Button · Table" in first
        task = app.state.agent.tasks[answer["task_id"]]
        assert task.origin["buddy"] is True


def test_quick_tap_sends_when_you_stop_talking(home, monkeypatch):
    from compii_core import voice as voice_mod
    from compii_core.voice import Voice

    monkeypatch.setattr(voice_mod, "AUTO_END_SILENCE", 0.3)
    sent = []
    voice = Voice(home["workspace"] / "models", lambda e: None, recorder_factory=Mic, speaker=FakeSpeaker())
    voice.can_listen = lambda: True
    voice.transcribe = lambda audio, final=True: "hello"
    voice.on_auto_end = lambda: sent.append(voice.stop_listening())
    voice.start_listening()
    voice.listen_hands_free()
    deadline = time.monotonic() + 5
    while not sent and time.monotonic() < deadline:
        time.sleep(0.05)
    assert sent == ["hello"]


def test_unclear_words_reach_the_ai_but_not_the_screen(home):
    import asyncio

    from compii_core.agent import Agent
    from compii_core.journal import Journal
    from compii_core.policy import Policy
    from compii_core.tools import Toolbox

    brain = ScriptBrain([], final="Did you mean Synology or Sonia?")
    events = []

    async def emit(e):
        events.append(e)

    async def run():
        agent = Agent(brain, Toolbox([home["downloads"]], home["workspace"]), Policy(), Journal(home["workspace"] / "j"), emit)
        task = agent.start("open synia\n\n(Spoken request. Possibly misheard words: synia.)")
        await asyncio.wait_for(task.runner, 5)
        return task

    task = asyncio.run(run())
    assert task.request == "open synia"
    assert "Possibly misheard words: synia" in brain.seen[0][0]["content"]


def test_answer_and_point_in_one_reply_skips_a_round_trip(home):
    import asyncio

    from compii_core.agent import Agent, BrainReply, ToolCall
    from compii_core.journal import Journal
    from compii_core.policy import Policy
    from compii_core.tools import Toolbox

    class OneShot:
        calls = 0

        async def step(self, system, messages, tools):
            OneShot.calls += 1
            if OneShot.calls == 1:
                call = ToolCall("p1", "point_at", {"target": "e2", "message": "Here."})
                return BrainReply([{"type": "text", "text": "It's the Table button."},
                                   {"type": "tool_use", "id": "p1", "name": "point_at", "input": call.input}],
                                  "It's the Table button.", [call], "tool_use")
            return BrainReply([{"type": "text", "text": "Sure."}], "Sure.", [], "end_turn")

    async def run():
        events = []

        async def emit(e):
            events.append(e)

        tb = Toolbox([home["downloads"]], home["workspace"])
        agent = Agent(OneShot(), tb, Policy(), Journal(home["workspace"] / "j"), emit)
        task = agent.start("where is table", screen=SNAP)
        await asyncio.wait_for(task.runner, 5)
        assert OneShot.calls == 1 and task.status == "done" and events[-1]["text"] == "It's the Table button."
        assert any(e["type"] == "point" for e in events)
        agent.reply(task.id, "thanks")  # a follow-up still works (roles stay valid)
        await asyncio.wait_for(task.runner, 5)
        assert task.messages[-2]["role"] == "user" and task.messages[-2]["content"][-1]["text"] == "thanks"

    asyncio.run(run())


def test_screen_is_read_only_when_the_question_is_about_it():
    from compii_core.buddy import moved, wants_screen

    assert not wants_screen("what time zone is Ghana in?")
    assert not wants_screen("remind me to call mum at six")
    assert wants_screen("what's this?")
    assert wants_screen("where do I click to export")
    assert wants_screen("summarise this page")
    assert wants_screen("what time zone is Ghana in?", gestured=True)  # pointing counts
    assert not moved([(100, 100), (102, 101), (103, 100)])  # a hand resting on the mouse
    assert moved([(100, 100), (160, 120), (200, 140)])

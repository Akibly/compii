"""Acting on the words in front of the user: what is highlighted, read off the app itself.

Nothing here copies anything. UIA is asked what its own selection holds, which is a read;
a password field or a password manager answers nothing, and a quick tap of Ctrl+Alt only
offers the words back when there are words to offer.
"""

from __future__ import annotations

import asyncio
import contextlib
import sys
import threading
import time
import types

import pytest
from fastapi.testclient import TestClient

from compii_core import guard, sight
from compii_core import screen
from compii_core.agent import QUICK_TOOLS
from compii_core.buddy import Buddy
from compii_core.policy import ActionKind
from compii_core.screen import PATTERN_TEXT, PATTERN_TYPE, describe_snapshot
from compii_core.server import build_app
from compii_core.tools import Toolbox, ToolError

from test_core import ScriptBrain, home  # noqa: F401 - fixtures

H = {"X-Compii-Token": "tok"}
WORDS = "Revenue is up twelve percent last quarter"  # seven words, exactly


class Range:
    """One highlighted run of text, as the app's text control hands it over."""

    def __init__(self, text):
        self._text, self.reads = text, 0

    def GetText(self, max_length=-1):  # noqa: N802 - UIA spelling
        self.reads += 1
        return self._text


class TextPattern:
    def __init__(self, *ranges):
        self._ranges = list(ranges)

    def GetSelection(self):  # noqa: N802
        return list(self._ranges)


class Field:
    """The control the caret is in. It offers the text pattern and nothing else."""

    def __init__(self, pattern=None, password=False, title="Report - Word", app="winword.exe"):
        self.Name, self.IsPassword = "body", password
        self.ProcessId, self.ClassName = 4242, "Edit"
        self._pattern, self._title, self._app = pattern, title, app

    def GetTopLevelControl(self):  # noqa: N802
        return types.SimpleNamespace(Name=self._title)

    def GetPattern(self, pid):  # noqa: N802
        return self._pattern if pid == PATTERN_TEXT else None


def an_app_with(monkeypatch, field):
    """Give Compii an app to ask, without needing a desktop."""
    monkeypatch.setitem(sys.modules, "uiautomation", types.SimpleNamespace(
        UIAutomationInitializerInThread=lambda: contextlib.nullcontext(),
        GetFocusedControl=lambda: field))
    monkeypatch.setattr(screen, "_need_windows", lambda: None)
    monkeypatch.setattr(screen, "_process_name", lambda pid: field._app)


@pytest.fixture
def seeing():
    was = sight.enabled()
    sight.set_enabled(True)
    yield
    sight.set_enabled(was)


@pytest.fixture
def loop():
    """The event loop the server would be running on, so the buddy can post work to it."""
    lo = asyncio.new_event_loop()
    threading.Thread(target=lo.run_forever, daemon=True).start()
    yield lo
    lo.call_soon_threadsafe(lo.stop)


class Quiet:
    """A microphone that says what the test decides and never really listens."""

    settings = type("S", (), {"output_mode": "off", "see_pictures": False})()

    def __init__(self):
        self.on_auto_end = None
        self.cancelled = 0
        self._listening = False
        self.text = "summarise this"

    def can_listen(self):
        return True

    def start_listening(self):
        pass

    def stop_recording(self):
        return True

    def stop_listening(self):
        return self.text

    def set_hints(self, hints):
        pass

    def cancel_listening(self):
        self.cancelled += 1

    def annotate(self, text):
        return text

    def say(self, text, spoken=None):
        return text


class Recorder:
    """An agent that only remembers what it was handed."""

    def __init__(self):
        self.seen = []

    def start(self, text, origin=None, screen=None):
        self.seen.append((text, screen))
        return types.SimpleNamespace(id=f"t{len(self.seen)}")

    def reply(self, tid, text, screen=None):
        self.seen.append((text, screen))
        return types.SimpleNamespace(id=tid)


async def no_intent(text):
    return False


def a_buddy(events, *, selection, cursor=lambda: (0, 0), loop=None):
    voice, agent = Quiet(), Recorder()
    bud = Buddy(voice, agent, events.append, no_intent, lambda: loop,
                snapshot=lambda: {"title": "Report - Word", "elements": []},
                cursor=cursor, selection=selection)
    return voice, agent, bud


def waited(items):
    """The buddy works on threads; give them a moment, then look."""
    deadline = time.monotonic() + 3
    while not items() and time.monotonic() < deadline:
        time.sleep(0.02)
    return items()


# ---- reading the highlight --------------------------------------------------------------


def test_the_highlighted_words_come_from_the_app_itself(monkeypatch, seeing):
    run = Range(WORDS)
    an_app_with(monkeypatch, Field(pattern=TextPattern(run)))
    picked = screen.selection()
    assert picked["text"] == WORDS and picked["words"] == 7 and picked["chars"] == len(WORDS)
    assert picked["window"] == "Report - Word" and picked["app"] == "winword.exe"
    assert run.reads == 1  # asked once, read once


def test_asking_for_the_words_never_asks_for_a_way_to_change_them(monkeypatch, seeing):
    asked = []

    class Strict(Field):
        def GetPattern(self, pid):  # noqa: N802
            asked.append(pid)
            return super().GetPattern(pid)

    an_app_with(monkeypatch, Strict(pattern=TextPattern(Range(WORDS))))
    screen.selection()
    assert asked == [PATTERN_TEXT] and PATTERN_TYPE not in asked


def test_several_runs_of_the_same_words_are_said_once(monkeypatch, seeing):
    an_app_with(monkeypatch, Field(pattern=TextPattern(Range("Revenue up"), Range("Revenue up"))))
    assert screen.selection()["text"] == "Revenue up"


def test_a_long_highlight_is_cut_to_size_not_dropped(monkeypatch, seeing):
    an_app_with(monkeypatch, Field(pattern=TextPattern(Range(WORDS * 200))))
    picked = screen.selection(limit=300)
    assert picked["chars"] == 300 and picked["words"] == len(picked["text"].split())


@pytest.mark.parametrize("field", [
    pytest.param(Field(pattern=TextPattern(Range("hunter2")), password=True), id="password field"),
    pytest.param(Field(pattern=TextPattern(Range("card 4111…")), app="keepass.exe"), id="password manager"),
    pytest.param(Field(pattern=TextPattern(Range("Vault - Bitwarden")), title="Vault - Bitwarden"), id="by window title"),
    pytest.param(Field(pattern=None), id="no text control"),
    pytest.param(Field(pattern=TextPattern()), id="nothing highlighted"),
    pytest.param(Field(pattern=TextPattern(Range("   \n  "))), id="only whitespace"),
])
def test_a_password_or_an_app_that_shares_nothing_answers_nothing(monkeypatch, seeing, field):
    an_app_with(monkeypatch, field)
    assert screen.selection() is None


def test_the_selection_is_not_asked_while_sight_is_off(monkeypatch):
    asked = []

    class Counting(Field):
        def GetPattern(self, pid):  # noqa: N802
            asked.append(pid)
            return super().GetPattern(pid)

    an_app_with(monkeypatch, Counting(pattern=TextPattern(Range(WORDS))))
    was = sight.enabled()
    try:
        sight.set_enabled(False)
        assert screen.selection() is None  # a passive read answers "nothing", it never refuses loudly
    finally:
        sight.set_enabled(was)
    assert asked == []


# ---- handing those words to the AI ------------------------------------------------------


def test_the_model_is_given_the_exact_words_and_told_this_means_them():
    text = describe_snapshot({"title": "Report - Word", "app": "winword.exe", "cursor": [400, 300],
                              "elements": [], "selection": {"text": WORDS, "words": 7, "window": "Report - Word"}})
    assert "7 words selected" in text and WORDS in text
    assert "When they say “this”" in text and "quote from them" in text
    assert "Items (id ·" not in text  # there were no items, so no empty table is announced


def test_a_tapped_selection_is_a_context_on_its_own():
    # The words are read but the window gave nothing else away: no cursor, no items, no title.
    text = describe_snapshot({"selection": {"text": "one", "words": 1, "window": "Mail"}})
    assert "1 word selected in “Mail”" in text


def test_one_hundred_words_is_still_called_words_not_word():
    text = describe_snapshot({"title": "Doc", "cursor": [0, 0], "elements": [],
                              "selection": {"text": "a b", "window": "Doc"}})
    assert "2 words selected" in text


# ---- the tool ---------------------------------------------------------------------------


def test_read_selection_is_a_quick_read_that_names_the_words(home, monkeypatch, seeing):
    tb = Toolbox([home["downloads"]], home["workspace"])
    tb.screen = types.SimpleNamespace(selection=lambda: {"text": WORDS, "words": 7, "chars": len(WORDS),
                                                          "window": "Report - Word", "app": "winword.exe"})
    assert "read_selection" in QUICK_TOOLS
    assert tb.tools["read_selection"].kind is ActionKind.READ
    assert "read_selection" in guard.UNTRUSTED_TOOLS  # the words are the user's, not a instruction
    out = tb.execute("read_selection", {})
    assert "7 words selected in “Report - Word” (winword.exe)" in out.text and WORDS in out.text


def test_a_selection_longer_than_what_was_read_says_so(home, monkeypatch, seeing):
    tb = Toolbox([home["downloads"]], home["workspace"])
    tb.screen = types.SimpleNamespace(selection=lambda: {"text": "Revenue up", "words": 2, "chars": 900,
                                                          "window": "Report", "app": ""})
    assert "longer than this" in tb.execute("read_selection", {}).text


def test_read_selection_refuses_for_the_real_reason(home, seeing):
    tb = Toolbox([home["downloads"]], home["workspace"])
    was = sight.enabled()
    try:
        sight.set_enabled(False)
        with pytest.raises(ToolError) as e:
            tb.execute("read_selection", {})
        assert "off" in str(e.value).lower()  # not a invented "nothing is selected"
    finally:
        sight.set_enabled(was)


def test_an_app_that_wont_share_its_selection_is_reported_as_that(home, seeing):
    tb = Toolbox([home["downloads"]], home["workspace"])
    tb.screen = types.SimpleNamespace(selection=lambda: None)
    out = tb.execute("read_selection", {})
    assert "doesn't share its selection" in out.text and "password" in out.text


# ---- the routes -------------------------------------------------------------------------


def test_the_selection_route_answers_what_is_highlighted_and_audits_it(home, monkeypatch):
    monkeypatch.setattr(screen, "selection", lambda: {"text": WORDS, "words": 7, "chars": len(WORDS),
                                                      "window": "Report - Word", "app": "winword.exe"})
    was = sight.enabled()
    sight.set_enabled(True)
    try:
        app = build_app(brain=ScriptBrain([], final="not used"), workspace=home["workspace"],
                        roots=[home["downloads"]], token="tok")
        with TestClient(app) as c:
            assert c.get("/screen/selection").status_code == 401
            body = c.get("/screen/selection", headers=H).json()
            assert body["selection"]["words"] == 7 and body["available"] is True and body["reason"] == ""
    finally:
        sight.set_enabled(was)
    audit = (home["workspace"] / "audit" / "audit.jsonl").read_text(encoding="utf-8")
    assert "selection_read" in audit and WORDS not in audit  # the words themselves stay off the log


def test_the_selection_route_says_so_when_the_words_are_not_there(home, monkeypatch):
    monkeypatch.setattr(screen, "selection", lambda: None)
    app = build_app(brain=ScriptBrain([], final="not used"), workspace=home["workspace"],
                    roots=[home["downloads"]], token="tok")
    with TestClient(app) as c:
        body = c.get("/screen/selection", headers=H).json()
        assert body["selection"] is None


def test_a_tap_on_an_offer_hands_the_words_to_the_task(home, loop):
    events, picked = [], {"text": WORDS, "words": 7, "chars": len(WORDS),
                          "window": "Report - Word", "app": "winword.exe"}
    voice, agent, bud = a_buddy(events, selection=lambda: picked, cursor=lambda: (400, 300), loop=loop)
    bud.start()
    bud._snap_thread.join(timeout=1)  # the press reads the window and the highlight on a thread
    assert bud.selected == picked  # held for the whole exchange, not re-read later

    bud.end(0.1)  # a quick tap: nothing was said, so offer the words instead
    assert waited(lambda: events)[-1]["state"] == "selected"
    card = events[-1]
    assert card["text"] == WORDS and card["words"] == 7 and card["cursor"] == [400, 300]
    assert voice.cancelled == 1  # a tap is not a request to keep listening

    assert bud.ask("Explain this") is True
    assert waited(lambda: agent.seen)
    said, snap = agent.seen[0]
    assert said == "Explain this"
    assert snap["selection"] == picked and snap["title"] == "Report - Word"
    assert picked["text"] in describe_snapshot(snap)


def test_a_tap_with_nothing_highlighted_is_the_accident_it_looks_like(home):
    events = []
    voice, _, bud = a_buddy(events, selection=lambda: None)
    bud.start()
    bud._snap_thread.join(timeout=1)
    bud.end(0.1)
    assert waited(lambda: events)
    assert [e["state"] for e in events] == ["listening", "idle"]  # no card, just the mic going off
    assert voice.cancelled == 1


def test_a_spoken_request_while_words_are_highlighted_carries_them(home, loop):
    picked = {"text": WORDS, "words": 7, "chars": len(WORDS), "window": "Report - Word", "app": "winword.exe"}
    events = []
    _, agent, bud = a_buddy(events, selection=lambda: picked, loop=loop)
    bud.start()
    bud.end(2.0)  # held, then released: what was said goes to the AI
    assert waited(lambda: agent.seen)
    assert agent.seen[0][1]["selection"] == picked


def test_asking_without_a_highlight_answers_honestly_instead_of_running(home):
    events = []
    bud = a_buddy(events, selection=lambda: None)[2]
    assert bud.ask("Explain this") is False
    assert "can’t see any selected text" in events[-1]["text"]

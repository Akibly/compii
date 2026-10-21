"""Compii never claims an action it didn't do, points at the right place in apps with bad
labels, and moves a lesson on by itself when the screen shows a step is done."""

import asyncio
import threading
import time

import numpy as np

from compii_core.agent import BrainReply, ToolCall
from compii_core.coach import Coach
from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import home  # noqa: F401 - fixture


class Scripted:
    """Replies in order; each item is text, or (text, [(tool, args)])."""

    def __init__(self, replies):
        self.replies = list(replies)
        self.seen = []

    async def step(self, system, messages, tools):
        self.seen.append([dict(m) for m in messages])
        item = self.replies.pop(0)
        text, calls = (item, []) if isinstance(item, str) else item
        blocks = ([{"type": "text", "text": text}] if text else []) + [
            {"type": "tool_use", "id": f"c{len(self.seen)}{i}", "name": n, "input": a} for i, (n, a) in enumerate(calls)]
        return BrainReply(blocks, text, [ToolCall(f"c{len(self.seen)}{i}", n, a) for i, (n, a) in enumerate(calls)],
                          "tool_use" if calls else "end_turn")


def _run(app, request):
    async def go():
        t = app.state.agent.start(request, origin={"buddy": True})
        await asyncio.wait_for(t.runner, 10)
        return t

    return asyncio.run(go())


def _final(task):
    return [e["text"] for e in task.events if e["type"] == "task_finished"][-1]


def test_a_claimed_point_without_pointing_gets_done_for_real(home):
    toolbox_snapshot = {"title": "Filmora", "elements": [
        {"id": "e1", "role": "Button", "name": "Import", "x": 10, "y": 10, "w": 60, "h": 24}]}
    brain = Scripted(["Click Import (I just pointed at it).",
                      ("Here it is.", [("point_at", {"target": "e1", "message": "Import"})])])
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t", keys=MemoryKeyStore())
    app.state.agent.toolbox.snapshot = toolbox_snapshot
    task = _run(app, "where is import")
    nudge = brain.seen[1][-1]["content"][0]["text"]
    assert "didn't happen" in nudge and "pointed at it" in nudge
    assert any(e["type"] == "action_done" and e.get("tool") == "point_at" for e in task.events)
    assert _final(task) == "Here it is."


def test_a_claim_that_still_isnt_backed_is_removed_not_spoken(home):
    brain = Scripted(["Click Import (I just pointed at it). Then choose a file.",
                      "Click Import (I just pointed at it). Then choose a file."])
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t", keys=MemoryKeyStore())
    task = _run(app, "where is import")
    assert _final(task) == "Click Import. Then choose a file."


def test_a_saved_file_that_was_never_written_is_not_left_in_the_reply(home):
    brain = Scripted(["I've saved the notes in Documents.", "I've saved the notes in Documents."])
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t", keys=MemoryKeyStore())
    task = _run(app, "make a note of this")
    assert _final(task) == "I couldn't save that file this time."
    assert not list(home["downloads"].glob("*.txt"))


def test_a_real_write_backs_up_the_saved_claim(home):
    target = home["downloads"] / "notes.txt"
    brain = Scripted([("", [("write_text_file", {"path": str(target), "content": "Notes."})]),
                      "It's saved in your Downloads folder."])
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t", keys=MemoryKeyStore())
    task = _run(app, "make a note of this")
    assert _final(task) == "It's saved in your Downloads folder."
    assert target.exists()


def test_a_promised_reminder_needs_a_watch_behind_it(home):
    brain = Scripted(["I'll remind you at six.", "I'll remind you at six."])
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="t", keys=MemoryKeyStore())
    task = _run(app, "remind me at six")
    nudge = brain.seen[1][-1]["content"][0]["text"]
    assert "didn't happen" in nudge and "follow up" in nudge
    assert _final(task) == "I couldn't set that up this time."


def test_ordinary_replies_are_not_treated_as_claims():
    from compii_core.agent import unbacked_claims

    for line in [
        "Downloads is tidy now — nothing needed saving.",
        "I hope that helps. Want me to make a spreadsheet of it?",
        "Your browser is open on the results page.",
        "The invoice is in Downloads, I didn't move anything.",
    ]:
        assert unbacked_claims(line, set()) == [], line


def test_a_click_the_app_never_confirmed_does_not_back_a_claim():
    from compii_core.agent import UNCONFIRMED, unbacked_claims

    said = "I clicked Save and it's done."
    unconfirmed = ("Clicked button “Save” in “Word”. Checked afterwards: the app's controls show no change, "
                   "so Compii can't confirm it did anything.")
    confirmed = ("Clicked button “Sync” in “Word”. Checked afterwards: it now shows “on”.")
    assert UNCONFIRMED.search(unconfirmed) and not UNCONFIRMED.search(confirmed)
    # A result that admits it couldn't check isn't evidence that the thing happened.
    assert unbacked_claims(said, set()) == ["clicked"]


def test_pointing_in_an_app_with_internal_names_uses_the_picture(home):
    from compii_core.tools import Toolbox

    tb = Toolbox([home["downloads"]], home["workspace"])
    tb.snapshot = {"title": "Wondershare Filmora", "app": "filmora.exe", "elements": [
        {"id": f"e{i}", "role": "Button", "name": n, "x": 0, "y": 0, "w": 2000, "h": 1200}
        for i, n in enumerate(["Tab_Effect", "FFPlayerToolBarBase", "QWidget", "Tab_Media", "Tab_Audio",
                               "TitleBar_Min", "TitleBar_Close", "Panel_Timeline", "Btn_Import"], start=1)]}
    asked = []
    tb.see_item = lambda target: asked.append(target) or {"name": "Effects", "x": 300, "y": 40, "w": 70, "h": 26}
    r = tb.point_at({"target": "e1", "message": "The Effects tab"})
    assert asked == ["Tab Effect"]
    assert r.point["x"] == 300 and r.point["name"] == "Effects"


def test_the_coach_notices_the_step_is_done_and_moves_on(monkeypatch):
    import compii_core.coach as coach_mod

    for name, value in (("TICK", .01), ("MIN_GAP", .03), ("FIRST_CHECK", .02)):
        monkeypatch.setattr(coach_mod, name, value)
    state = {"n": 0}

    def grab():
        state["n"] += 1
        bright = state["n"] > 20  # the user does the step a moment later
        return np.full((60, 100, 3), 200 if bright else 0, np.uint8), (0, 0, 100, 60)

    checks, finished, done = [], threading.Event(), []

    def check(png, done_when):
        checks.append(state["n"])
        return state["n"] > 20, "the dialog is open"

    coach = Coach(check, lambda task, dw, why: (done.append((task, dw, why)), finished.set()), lambda: True, grab=grab)
    assert "Watching" in coach.watch("t1", "the Import dialog is open")
    assert finished.wait(5)
    assert done == [("t1", "the Import dialog is open", "the dialog is open")]
    assert checks[0] <= 20 < checks[-1]  # looked early (not done yet), then again once the screen changed
    assert coach.watching == ""


def test_the_coach_stops_when_the_user_asks_something_else(monkeypatch):
    import compii_core.coach as coach_mod

    monkeypatch.setattr(coach_mod, "TICK", .01)
    coach = Coach(lambda png, dw: (False, ""), lambda *a: None, lambda: True,
                  grab=lambda: (np.zeros((10, 10, 3), np.uint8), (0, 0, 10, 10)))
    coach.watch("t1", "a sphere is in the viewport")
    assert coach.watching
    coach.stop()
    time.sleep(.05)
    assert coach.watching == ""

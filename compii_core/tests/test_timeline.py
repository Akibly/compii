"""Screen Timeline: local recording, search, privacy, retention and the tools' words."""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

import numpy as np
import pytest

from compii_core import ocr
from compii_core.timeline import Timeline, timeline_tools
from compii_core.tools import ToolError


class Clock:
    def __init__(self) -> None:
        self.now = 1_700_000_000.0

    def __call__(self) -> float:
        return self.now

    def tick(self, seconds: float) -> None:
        self.now += seconds


def picture(inverted: bool = False) -> np.ndarray:
    img = np.zeros((50, 80, 3), dtype=np.uint8)
    img[:, 40:] = 255
    return 255 - img if inverted else img


def sample(text: str = "The invoice total is 42.00", app: str = "chrome.exe",
           title: str = "Invoice — Chrome", pixels: np.ndarray | None = None) -> dict:
    return {"app": app, "title": title, "text": text, "pixels": picture() if pixels is None else pixels}


def make(tmp_path: Path, capture=None, clock: Clock | None = None, allow=lambda: True) -> Timeline:
    return Timeline(tmp_path / "timeline.db", tmp_path / "timeline.json",
                    capture=capture or (lambda: sample()), clock=clock or Clock(), allow=allow, background=False)


def test_off_until_turned_on_and_records_nothing_then(tmp_path):
    calls = []

    def capture():
        calls.append(1)
        return sample()

    t = make(tmp_path, capture)
    assert t.settings.enabled is False
    assert t.capture_once() is None
    assert calls == []
    assert t.status()["moments"] == 0


def test_turning_it_on_records_a_searchable_moment(tmp_path):
    t = make(tmp_path)
    t.update(enabled=True)
    got = t.capture_once()
    assert got and got["new"] is True
    rows = t.search("invoice")
    assert len(rows) == 1
    assert rows[0]["app"] == "chrome.exe"
    assert "42.00" in rows[0]["excerpt"]
    assert rows[0]["has_picture"] is True
    assert t.moment(rows[0]["id"])["text"].startswith("The invoice")
    assert t.picture(rows[0]["id"]).startswith(b"\x89PNG")


def test_the_same_screen_stays_one_moment_and_a_change_makes_another(tmp_path):
    clock = Clock()
    state = {"text": "First paragraph"}
    t = make(tmp_path, lambda: sample(text=state["text"]), clock)
    t.update(enabled=True)
    t.capture_once()
    clock.tick(30)
    assert t.capture_once()["new"] is False
    assert len(t.search()) == 1
    state["text"] = "A new error appeared"
    clock.tick(30)
    assert t.capture_once()["new"] is True
    assert len(t.search()) == 2
    assert t.search("error")[0]["title"] == "Invoice — Chrome"


def test_private_windows_are_never_recorded(tmp_path):
    cases = [
        sample(app="1password.exe", title="1Password"),
        sample(app="chrome.exe", title="Invoices - Incognito"),
        sample(app="chrome.exe", title="Compii settings"),
    ]
    for s in cases:
        t = make(tmp_path / str(id(s)), lambda s=s: s)
        t.update(enabled=True)
        assert t.capture_once() is None
        assert t.status()["moments"] == 0


def test_nothing_is_recorded_while_screen_reading_is_off(tmp_path):
    allowed = {"on": True}
    t = make(tmp_path, allow=lambda: allowed["on"])
    t.update(enabled=True)
    assert t.capture_once() is not None
    allowed["on"] = False
    assert t.capture_once() is None
    assert t.status()["paused"] is True
    assert "Screen reading is off" in t.status()["reason"]


def test_search_by_time_app_and_word(tmp_path):
    clock = Clock()
    t = make(tmp_path, clock=clock)
    t.update(enabled=True)
    t.capture_once()
    clock.tick(3600)
    t.update(enabled=False)
    t2 = make(tmp_path, lambda: sample(text="A spreadsheet", app="excel.exe", title="Budget.xlsx"), clock)
    t2.update(enabled=True)
    t2.capture_once()
    now = clock.now
    assert [r["app"] for r in t2.search(after=now - 60)] == ["excel.exe"]
    assert len(t2.search(before=now - 60)) == 1
    assert [r["app"] for r in t2.search(app="excel")] == ["excel.exe"]
    assert t2.search("spreadsheet")[0]["title"] == "Budget.xlsx"
    assert t2.search("nothing here") == []


def test_wildcards_in_a_query_stay_literal(tmp_path):
    clock = Clock()
    state = {"text": "100% done"}
    t = make(tmp_path, lambda: sample(text=state["text"]), clock)
    t.update(enabled=True)
    t.capture_once()
    state["text"] = "plain a_b"
    clock.tick(30)
    t.capture_once()
    assert len(t.search("100%")) == 1
    assert len(t.search("%")) == 1
    assert len(t.search("_")) == 1


def test_retention_forgets_old_moments(tmp_path):
    clock = Clock()
    state = {"text": "one"}
    t = make(tmp_path, lambda: sample(text=state["text"]), clock)
    t.update(enabled=True, keep_days=1)
    t.capture_once()
    clock.tick(3 * 86400)
    state["text"] = "two"
    t.capture_once()
    assert [r["text"] for r in t.search()] == ["two"]


def test_forgetting_the_last_hour_leaves_older_history(tmp_path):
    clock = Clock()
    state = {"text": "old"}
    t = make(tmp_path, lambda: sample(text=state["text"]), clock)
    t.update(enabled=True)
    t.capture_once()
    clock.tick(2 * 3600)
    state["text"] = "recent"
    t.capture_once()
    assert t.forget(hours=1) == 1
    assert [r["text"] for r in t.search()] == ["old"]
    assert t.forget(everything=True) == 1
    assert t.search() == []


def test_one_moment_can_be_forgotten_on_its_own(tmp_path):
    clock = Clock()
    state = {"text": "one"}
    t = make(tmp_path, lambda: sample(text=state["text"]), clock)
    t.update(enabled=True)
    first = t.capture_once()["id"]
    state["text"] = "two"
    clock.tick(30)
    second = t.capture_once()["id"]
    assert t.forget_moment(first) is True
    assert t.forget_moment(first) is False
    assert [r["id"] for r in t.search()] == [second]


def test_a_still_screen_reuses_its_picture_and_a_change_gets_a_new_one(tmp_path):
    clock = Clock()
    state = {"text": "one", "pixels": picture()}
    t = make(tmp_path, lambda: sample(text=state["text"], pixels=state["pixels"]), clock)
    t.update(enabled=True)
    a = t.capture_once()["id"]
    state["text"] = "two"
    clock.tick(30)
    b = t.capture_once()["id"]
    state["text"] = "three"
    state["pixels"] = picture(inverted=True)
    clock.tick(30)
    c = t.capture_once()["id"]
    con = sqlite3.connect(t.path)
    thumbs = [r[0] for r in con.execute("SELECT thumb_id FROM moments ORDER BY id")]
    con.close()
    assert len(thumbs) == 3 and thumbs[0] == thumbs[1] != thumbs[2]
    assert t.picture(a) == t.picture(b) != t.picture(c)


def test_settings_are_saved_and_stay_in_sane_bounds(tmp_path):
    t = make(tmp_path)
    t.update(enabled=True, every_seconds=1, keep_days=1000, max_mb=1)
    assert t.settings.every_seconds == 10
    assert t.settings.keep_days == 90
    assert t.settings.max_mb == 50
    again = Timeline(t.path, t.settings_path, capture=lambda: None, background=False)
    assert again.settings.enabled is True
    assert again.settings.keep_days == 90


def test_a_failed_look_is_simply_no_moment(tmp_path):
    def broken():
        raise RuntimeError("screen changed")

    t = make(tmp_path, broken)
    t.update(enabled=True)
    assert t.capture_once() is None


def test_the_search_tool_says_what_it_found_and_is_honest_when_empty(tmp_path):
    t = make(tmp_path)
    tools = {tool.name: tool for tool in timeline_tools(t)}
    with pytest.raises(ToolError, match="Screen timeline is off"):
        tools["search_screen_memory"].run({"query": "invoice"})
    t.update(enabled=True)
    t.capture_once()
    text = tools["search_screen_memory"].run({"query": "invoice"}).text
    assert "screen memory" in text.lower()
    assert "chrome.exe" in text
    assert "42.00" in text
    assert "Nothing in screen memory" in tools["search_screen_memory"].run({"query": "zebra"}).text


def test_the_forget_tool_forgets_the_scope_it_was_given(tmp_path):
    clock = Clock()
    state = {"text": "one"}
    t = make(tmp_path, lambda: sample(text=state["text"]), clock)
    t.update(enabled=True)
    t.capture_once()
    clock.tick(3 * 86400)
    state["text"] = "two"
    t.capture_once()
    forget = {tool.name: tool for tool in timeline_tools(t)}["forget_screen_memory"]
    assert "Deleted 1" in forget.run({"scope": "hour"}).text
    assert t.search("one") and not t.search("two")
    assert "Deleted 1" in forget.run({"scope": "all"}).text
    assert t.search() == []


@pytest.mark.skipif(sys.platform != "win32" or not ocr.available(), reason="needs Windows OCR")
def test_windows_ocr_reads_a_real_picture():
    shot = Path(__file__).resolve().parents[2] / "docs" / "compii" / "build-previews" / "phone-portrait-done.png"
    text = ocr.read_png(shot.read_bytes())
    assert "invoices" in text.lower()
    assert len(text) > 40

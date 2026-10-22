"""Clipboard history and snippets: opt-in, privacy, dedupe, retention and the tools' words."""

from __future__ import annotations

from pathlib import Path

import pytest

from compii_core import clips as clips_module
from compii_core.clips import Clips, clip_tools
from compii_core.tools import ToolError


class Clock:
    def __init__(self) -> None:
        self.now = 1_700_000_000.0

    def __call__(self) -> float:
        return self.now

    def tick(self, seconds: float) -> None:
        self.now += seconds


def make(tmp_path: Path, reader=None, source=None, clock: Clock | None = None, owner=None) -> Clips:
    return Clips(tmp_path / "clips.db", tmp_path / "clips.json", tmp_path / "snippets.json",
                 reader=reader or (lambda: ""), source=source or (lambda: ("chrome.exe", "Inbox — Chrome")),
                 sequence=lambda: 1, owner=owner or (lambda: ("", "")), clock=clock or Clock(), background=False)


def test_off_until_turned_on_and_reads_nothing_then(tmp_path):
    reads = []

    def reader():
        reads.append(1)
        return "a copied line"

    c = make(tmp_path, reader)
    assert c.settings.enabled is False
    assert c.remember_once() is None
    assert reads == []
    assert c.status()["items"] == 0
    assert "off" in c.status()["reason"].lower()


def test_a_copy_is_remembered_searchable_and_deduped(tmp_path):
    c = make(tmp_path)
    c.update(enabled=True)
    first = c.remember_text("Your invoice for September is ready", app="outlook.exe", title="Inbox")
    assert first and first["new"] is True
    assert first["kind"] == "text"
    again = c.remember_text("Your invoice for September is ready", app="outlook.exe", title="Inbox")
    assert again["new"] is False
    assert len(c.search("invoice")) == 1
    assert c.search("invoice")[0]["copies"] == 2
    assert c.search("outlook")[0]["app"] == "outlook.exe"
    assert len(c.search()) == 1
    assert c.item(first["id"])["text"].startswith("Your invoice")


def test_private_sources_are_skipped_without_reading_the_text(tmp_path):
    reads = []

    def reader():
        reads.append(1)
        return "hunter2-copied-password"

    for app, title in (("1password.exe", "1Password"), ("chrome.exe", "Mail — Incognito")):
        c = make(tmp_path / str(len(reads)), reader, lambda app=app, title=title: (app, title))
        c.update(enabled=True)
        assert c.remember_once() is None
        assert reads == []
        assert c.status()["items"] == 0


def test_a_copy_is_private_by_where_it_came_from_not_where_the_focus_is_now(tmp_path):
    """The watcher only notices a copy a poll later, by which time the user has tabbed away.

    So the privacy check cannot rest on the window in front: Windows names the window that set
    the data, and that is the one that decides whether the copy was private.
    """
    reads = []

    def reader():
        reads.append(1)
        return "hunter2-copied-password"

    c = make(tmp_path, reader, source=lambda: ("compii.exe", "Compii"),
             owner=lambda: ("chrome.exe", "My bank — InPrivate"))
    c.update(enabled=True)
    assert c.remember_once() is None
    assert reads == [], "it never even read what the private window copied"
    assert c.status()["items"] == 0


def test_the_history_names_the_app_that_copied_not_whatever_is_in_front(tmp_path):
    c = make(tmp_path, reader=lambda: "shipping address for order 4471",
             source=lambda: ("compii.exe", "Compii"), owner=lambda: ("outlook.exe", "Inbox — Outlook"))
    c.update(enabled=True)
    c.remember_once()
    assert c.search("shipping")[0]["app"] == "outlook.exe"


def test_remember_once_reads_a_new_copy_and_ignores_an_unchanged_one(tmp_path):
    state = {"text": "first copy"}
    reads = []

    def reader():
        reads.append(1)
        return state["text"]

    c = make(tmp_path, reader)
    c.update(enabled=True)
    got = c.remember_once()
    assert got and got["new"] is True
    assert c.remember_once() is None  # same words again: no second row
    state["text"] = "second copy"
    assert c.remember_once()["new"] is True
    assert len(reads) == 3
    assert len(c.search()) == 2


def test_pinned_copies_survive_pruning_and_forgetting(tmp_path):
    clock = Clock()
    c = make(tmp_path, clock=clock)
    c.update(enabled=True, keep_days=1)
    keep = c.remember_text("the address I always need")
    c.pin(keep["id"], True)
    c.remember_text("an old copy")
    clock.tick(2 * 86400)
    c.remember_text("a newer copy")  # remembering also prunes what fell out of retention
    assert [r["preview"] for r in c.search()] == ["the address I always need", "a newer copy"]
    assert c.forget_many(hours=0) == 1
    assert c.search()[0]["pinned"] is True
    assert c.forget_many(hours=0, keep_pinned=False) == 1
    assert c.search() == []


def test_the_history_keeps_the_newest_copies_up_to_the_limit(tmp_path):
    clock = Clock()
    c = make(tmp_path, clock=clock)
    c.update(enabled=True, max_items=50)
    for i in range(55):
        clock.tick(60)
        c.remember_text(f"copy number {i}")
    c.prune()
    rows = c.search(limit=100)
    assert len(rows) == 50
    assert "copy number 54" in rows[0]["preview"]
    assert all("number 4 " not in r["preview"] for r in rows)


def test_search_treats_percent_and_underscore_as_text(tmp_path):
    c = make(tmp_path)
    c.update(enabled=True)
    c.remember_text("sale 100%_off today")
    c.remember_text("sale 100X off today")
    assert len(c.search("100%_off")) == 1
    assert c.search("100%_off")[0]["preview"].startswith("sale 100%_off")


def test_links_and_code_are_recognised_for_the_list(tmp_path):
    c = make(tmp_path)
    c.update(enabled=True)
    assert c.remember_text("https://example.com/a?b=1")["kind"] == "link"
    assert c.remember_text("def go():\n    return 1")["kind"] == "code"
    assert c.remember_text("just a normal sentence")["kind"] == "text"


def test_snippets_are_named_text_that_can_be_added_replaced_edited_and_removed(tmp_path):
    c = make(tmp_path)
    snippet = c.snippets.add("Work signature", "Regards,\nSam")
    assert c.snippets.find("work signature").id == snippet.id
    with pytest.raises(ValueError):
        c.snippets.add("work signature", "other")
    replaced = c.snippets.add("Work signature", "Regards,\nSam Lee", replace=True)
    assert replaced.id != snippet.id and "Sam Lee" in replaced.body
    edited = c.snippets.update(replaced.id, name="Formal signature", body="Yours,\nSam")
    assert c.snippets.find("formal").body == "Yours,\nSam"
    with pytest.raises(ValueError):
        c.snippets.update(edited.id, name="")
    assert c.snippets.remove(edited.id) is True
    assert c.snippets.remove(edited.id) is False
    assert c.snippets.search("signature") == []


def test_snippet_search_and_context(tmp_path):
    c = make(tmp_path)
    c.snippets.add("Home address", "12 Market Street")
    c.snippets.add("Refund reply", "Happy to help with the refund.")
    assert len(c.snippets.search("refund")) == 1
    assert "Home address" in c.snippets.context()
    assert "Refund reply" in c.snippets.context()


def test_tools_search_save_copy_and_delete(tmp_path, monkeypatch):
    copied = []
    monkeypatch.setattr(clips_module, "write_clipboard", copied.append)
    c = make(tmp_path)
    c.update(enabled=True)
    c.remember_text("the link I copied was example.com/invoice", app="chrome.exe")
    tools = {t.name: t for t in clip_tools(c)}

    assert "invoice" in tools["search_clips"].run({"query": "invoice"}).text
    assert "clipboard history" in tools["search_clips"].run({"query": ""}).text.lower()

    saved = tools["save_snippet"].run({"name": "Invoice reply", "body": "Thanks, the invoice is attached."})
    assert "Saved the snippet" in saved.text
    assert "Invoice reply" in tools["list_snippets"].run({}).text
    used = tools["use_snippet"].run({"name": "Invoice reply"})
    assert copied == ["Thanks, the invoice is attached."]
    assert "ready to paste" in used.text
    assert c.snippets.find("Invoice reply").uses == 1
    with pytest.raises(ToolError):
        tools["use_snippet"].run({"name": "nope"})
    assert "Deleted the snippet" in tools["delete_snippet"].run({"name": "Invoice reply"}).text
    assert c.snippets.items == {}


def test_the_search_tool_says_when_history_is_off(tmp_path):
    c = make(tmp_path)
    tools = {t.name: t for t in clip_tools(c)}
    with pytest.raises(ToolError, match="off"):
        tools["search_clips"].run({"query": "anything"})

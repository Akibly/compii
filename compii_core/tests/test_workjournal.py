"""The work journal: one day written down while Compii still knows it, kept as plain text."""

import datetime as dt
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from compii_core.agent import Task
from compii_core.journal import Entry, Journal
from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app
from compii_core.workjournal import WorkJournal, journal_tool

from test_core import home, quiet_voice  # noqa: F401 - fixtures and helper


class FakeTimeline:
    def __init__(self, rows, enabled=True):
        self.settings = SimpleNamespace(enabled=enabled)
        self.rows = rows

    def search(self, query="", after=None, before=None, app="", limit=50, full=True):
        return [r for r in self.rows
                if (after is None or r["started"] >= after) and (before is None or r["started"] <= before)][:limit]


def _task(tid, request, status, at, text=""):
    t = Task(id=tid, request=request, status=status)
    t.events = [{"at": at, "text": text}] if text else [{"at": at}]
    return t


def _yesterday() -> float:
    """A moment inside the day the journal writes by default."""
    now = dt.datetime.now()
    return dt.datetime.combine((now - dt.timedelta(days=1)).date(), dt.time(9, 30)).timestamp()


def _moment(back: int, hour: int = 9, minute: int = 30) -> tuple[str, float]:
    """The date `back` days ago and a moment inside it."""
    day = dt.date.today() - dt.timedelta(days=back)
    return day.isoformat(), dt.datetime.combine(day, dt.time(hour, minute)).timestamp()


@pytest.fixture
def work(tmp_path: Path) -> WorkJournal:
    return WorkJournal(tmp_path / "journal")


def _a_day(back: int = 1):
    """Yesterday's (or any past day's) work: two finished tasks, one move, one app on screen."""
    _, at = _moment(back)
    tasks = [_task("t1", "File my invoices from Acme", "done", at), _task("t2", "Draft a reply to Priya", "done", at)]
    return tasks, at


def test_yesterday_is_written_as_plain_markdown(work):
    tasks, at = _a_day()
    j = Journal(work.folder.parent / "workspace" / "journal.jsonl")
    j.record(Entry("t1", "move_file", "change", {}, True, "Moved invoice.pdf to Accounts",
                   {"op": "move", "src": "a", "dst": "b"}, at=at))

    made = work.write(tasks=tasks, journal=j, timeline=FakeTimeline(
        [{"started": at, "app": "Excel", "title": "budget_final_copy.xlsx"}]))

    yesterday = (dt.date.today() - dt.timedelta(days=1)).isoformat()
    assert made["date"] == yesterday
    text = Path(made["path"]).read_text(encoding="utf-8")
    assert text.startswith(f"# Compii's journal for {(dt.date.today() - dt.timedelta(days=1)):%A %d %B %Y}")
    assert "2 tasks finished" in text and "Moved invoice.pdf to Accounts" in text
    assert "File my invoices from Acme" in text
    assert "- Excel · 1 moment" in text
    assert "budget_final_copy" not in text, "window titles stay in the rolling screen memory, not in the file"
    assert "can be undone" not in text, "a past day must not promise an undo that may no longer be there"


def test_a_past_day_shows_its_own_clock_times(work):
    three, at = _moment(3)
    tasks, _ = _a_day(3)
    j = Journal(work.folder.parent / "workspace" / "journal.jsonl")
    j.record(Entry("t1", "move_file", "change", {}, True, "Moved invoice.pdf to Accounts",
                   {"op": "move", "src": "a", "dst": "b"}, at=at))

    made = work.write(tasks=tasks, journal=j, timeline=None, day=three)
    assert made["date"] == three
    text = Path(made["path"]).read_text(encoding="utf-8")
    assert f"{dt.datetime.fromtimestamp(at):%H:%M}" in text, "a day three days back says 09:30, not how long ago it was"
    assert dt.date.fromisoformat(three).strftime("%B") in text


def test_a_quiet_day_gets_no_file(work):
    j = Journal(work.folder.parent / "workspace" / "journal.jsonl")
    assert work.write(tasks=[], journal=j, timeline=None) is None
    assert work.days() == []
    assert not list(work.folder.glob("*.md"))


def test_days_are_listed_newest_first_with_their_opening_line(work):
    j = Journal(work.folder.parent / "workspace" / "journal.jsonl")
    for back in (1, 2, 3):
        tasks, _ = _a_day(back)
        work.write(tasks=tasks, journal=j, timeline=None, day=_moment(back)[0])

    days = work.days()
    assert [d["date"] for d in days] == [_moment(b)[0] for b in (1, 2, 3)]
    assert "2 tasks finished" in days[0]["lead"]
    assert days[0]["title"] == f"{dt.date.today() - dt.timedelta(days=1):%A %d %B %Y}"


def test_a_bad_or_meddling_date_never_opens_a_file(work):
    tasks, _ = _a_day()
    j = Journal(work.folder.parent / "workspace" / "journal.jsonl")
    made = work.write(tasks=tasks, journal=j, timeline=None)
    assert work.read("../../etc/passwd") is None
    assert work.read("yesterday") is None
    assert work.read("2026-13-40") is None
    assert work.read("2026-01-01") is None
    assert work.read(made["date"]).startswith("# Compii's journal for"), "the file is headed with the human date"


def test_search_finds_the_day_behind_a_phrase_and_behind_two_words(work):
    j = Journal(work.folder.parent / "workspace" / "journal.jsonl")
    tasks, _ = _a_day()
    work.write(tasks=tasks, journal=j, timeline=None)

    whole = work.search("File my invoices from Acme")
    assert len(whole) == 1 and "Acme" in whole[0]["line"]
    split = work.search("invoices acme")
    assert [h["date"] for h in split] == [h["date"] for h in whole]
    assert work.search("nothing like this happened") == []
    assert work.search("") == []


def test_the_tool_says_what_is_recorded_and_what_is_not(work, tmp_path):
    from compii_core.policy import ActionKind

    tool = journal_tool(work)
    assert tool.kind_for({}) is ActionKind.READ
    assert "is empty" in tool.run({}).text

    j = Journal(tmp_path / "workspace" / "journal.jsonl")
    tasks, _ = _a_day()
    made = work.write(tasks=tasks, journal=j, timeline=None)

    listed = tool.run({}).text
    assert made["date"] in listed and "2 tasks finished" in listed
    assert "File my invoices from Acme" in tool.run({"date": made["date"]}).text
    missing = tool.run({"date": "2020-01-01"}).text
    assert "Nothing is recorded" in missing and made["date"] in missing
    assert made["date"] in tool.run({"query": "invoices"}).text
    assert "No journal day mentions" in tool.run({"query": "quidditch tickets"}).text


# ---- settings, routes and the index -------------------------------------------------------


def _client(home, monkeypatch):
    monkeypatch.setattr("compii_core.reach._v2ex_hot", lambda **kw: [])
    built = build_app(workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                      voice=quiet_voice(home["workspace"]), keys=MemoryKeyStore())
    return TestClient(built), {"X-Compii-Token": "tok"}, built


def test_the_journal_is_off_until_the_user_asks(home, monkeypatch):
    client, h, built = _client(home, monkeypatch)
    with client:
        assert "work_journal" in built.state.agent.toolbox.tools
        view = client.get("/proactive", headers=h).json()
        assert view["journal"] == {"enabled": False, "at": "21:00", "last": None}
        assert view["days"] == []

        after = client.put("/journal", json={"enabled": True, "at": "19:45"}, headers=h).json()
        assert after["journal"]["enabled"] is True and after["journal"]["at"] == "19:45"
        assert client.put("/journal", json={"at": "teatime"}, headers=h).status_code == 400
        assert client.get("/journal", headers=h).json()["journal"]["enabled"] is True
        # It is a setting the loop reads, so it has to survive a restart.
        assert built.state.plans.journal["at"] == "19:45"


def test_writing_a_day_indexes_it_for_asking_about_your_files(home, monkeypatch):
    client, h, built = _client(home, monkeypatch)
    with client:
        built.state.agent.journal.record(
            Entry("t1", "move_file", "change", {}, True, "Moved invoice.pdf to Accounts",
                  {"op": "move", "src": "a", "dst": "b"}, at=_yesterday()))
        written = client.post("/journal/now", headers=h).json()
        assert written["written"] is not None, written
        assert [d["date"] for d in written["days"]] == [written["written"]["date"]]

        folders = built.state.knowledge.folders()
        assert str(built.state.work.folder) in folders
        built.state.knowledge.refresh(str(built.state.work.folder))
        hits = built.state.knowledge.search("invoice")
        assert hits and hits[0]["path"].endswith(".md")

        day = written["written"]["date"]
        assert "Moved invoice.pdf to Accounts" in client.get(f"/journal/{day}", headers=h).json()["text"]
        assert client.get("/journal/2020-01-01", headers=h).status_code == 404
        assert client.get("/journal").status_code == 401


def test_a_quiet_day_says_so_instead_of_writing_an_empty_file(home, monkeypatch):
    client, h, built = _client(home, monkeypatch)
    with client:
        assert client.post("/journal/now", headers=h).json()["written"] is None
        assert client.get("/journal", headers=h).json()["days"] == []
        assert not (home["workspace"] / "journal").exists() or not list(
            (home["workspace"] / "journal").glob("*.md"))

import time
from types import SimpleNamespace

from fastapi.testclient import TestClient

from compii_core.agent import Task
from compii_core.daybook import build_daybook, daybook_tool
from compii_core.journal import Entry, Journal
from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import home, quiet_voice  # noqa: F401 - fixtures and helper


class FakeTimeline:
    def __init__(self, rows, enabled=True):
        self.settings = SimpleNamespace(enabled=enabled)
        self.rows = rows

    def search(self, query="", after=None, before=None, app="", limit=50, full=True):
        out = [r for r in self.rows if after is None or r["started"] >= after]
        return out[:limit]


def _task(tid, request, status, at, text=""):
    t = Task(id=tid, request=request, status=status)
    t.events = [{"at": at, "text": text}] if text else [{"at": at}]
    return t


def _journal(tmp_path) -> Journal:
    return Journal(tmp_path / "workspace" / "journal.jsonl")


def test_daybook_reads_tasks_actions_and_screen(tmp_path):
    now = time.time()
    j = _journal(tmp_path)
    j.record(Entry("t1", "move_file", "change", {}, True, "Moved report.txt to Archive",
                   {"op": "move", "src": "a", "dst": "b"}, at=now - 300))
    j.record(Entry("t1", "send_mail", "send", {}, True, "Mailed the invoice", at=now - 600))
    tasks = [
        _task("t1", "File my reports", "done", now - 300),
        _task("t2", "Draft a reply to Priya", "waiting", now - 120, "Waiting for your approval"),
        _task("t3", "Something from last week", "done", now - 4 * 86400),
    ]
    tl = FakeTimeline([
        {"started": now - 100, "app": "Chrome", "title": "Invoices — Acme"},
        {"started": now - 90, "app": "Chrome", "title": "Acme portal"},
        {"started": now - 80, "app": "Excel", "title": "budget.xlsx"},
        {"started": now - 5 * 86400, "app": "Old", "title": "before the window"},
    ])

    book = build_daybook(tasks=tasks, journal=j, timeline=tl, hours=24)

    assert book["counts"] == {"done": 1, "waiting": 1, "actions": 2, "apps": 2}
    assert [a["summary"] for a in book["actions"]] == ["Moved report.txt to Archive", "Mailed the invoice"]
    assert book["actions"][0]["can_undo"] and not book["actions"][1]["can_undo"]
    assert book["actions"][0]["about"] == "File my reports"
    assert book["undo"]["task_id"] == "t1" and book["undo"]["summary"] == "Moved report.txt to Archive"
    assert book["undo"]["id"] == book["actions"][0]["id"]
    assert book["left_off"]["task_id"] == "t2"
    assert book["screen"]["apps"][0]["app"] == "Chrome" and book["screen"]["apps"][0]["moments"] == 2
    md = book["markdown"]
    for heading in ("### Finished", "### Still open", "### What Compii did",
                     "### On screen", "### Where you left off"):
        assert heading in md
    assert "Draft a reply to Priya" in md and "last week" not in md


def test_screen_memory_off_is_not_invented(tmp_path):
    now = time.time()
    book = build_daybook(
        tasks=[_task("t1", "Sort the downloads", "done", now - 60)],
        journal=_journal(tmp_path),
        timeline=FakeTimeline([{"started": now, "app": "Chrome", "title": "A page"}], enabled=False),
        hours=24)
    assert book["counts"]["apps"] == 0 and book["screen"]["apps"] == []
    assert "On screen" not in book["markdown"]
    assert "Sort the downloads" in book["markdown"]


def test_an_undone_action_is_not_offered_again_and_a_quiet_day_says_so(tmp_path):
    now = time.time()
    j = _journal(tmp_path)
    j.record(Entry("t1", "move_file", "change", {}, True, "Moved notes.txt",
                   {"op": "move", "src": "a", "dst": "b", "done": True}, at=now - 60))
    book = build_daybook(tasks=[], journal=j, timeline=None, hours=24)
    assert book["undo"] is None and not book["actions"][0]["can_undo"]

    quiet = build_daybook(tasks=[], journal=_journal(tmp_path / "empty"), timeline=None, hours=24)
    assert quiet["headline"].startswith("A quiet stretch")
    assert "Nothing has been done" in quiet["markdown"]


def test_catch_me_up_tool_answers_in_hours(tmp_path):
    now = time.time()
    j = _journal(tmp_path)
    j.record(Entry("t1", "create_file", "create", {}, True, "Wrote summary.docx",
                   {"op": "created", "path": "x"}, at=now - 60))
    tool = daybook_tool(lambda: [_task("t1", "Write the summary", "done", now - 50)], j, None)

    out = tool.run({"hours": "3"}).text  # the model sends its own types
    assert "Wrote summary.docx" in out and "Write the summary" in out
    assert tool.run({}).text.startswith("Here is the user's own local daybook")


def test_daybook_route_serves_the_app_and_clamps_hours(home):
    app = build_app(workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]), keys=MemoryKeyStore())
    now = time.time()
    with TestClient(app) as c:
        agent = c.app.state.agent
        agent.tasks["t9"] = _task("t9", "Clean the archive folder", "done", now - 30)
        agent.journal.record(Entry("t9", "move_file", "change", {}, True, "Moved log.txt to Old",
                                   {"op": "move", "src": "a", "dst": "b"}))

        r = c.get("/daybook", headers={"X-Compii-Token": "tok"})
        assert r.status_code == 200, r.text
        book = r.json()
        assert book["counts"]["done"] == 1 and book["undo"]["task_id"] == "t9"
        assert "Moved log.txt to Old" in book["markdown"]

        assert c.get("/daybook", params={"hours": 99999}, headers={"X-Compii-Token": "tok"}).json()["hours"] == 168
        assert c.get("/daybook", params={"hours": 0}, headers={"X-Compii-Token": "tok"}).json()["hours"] == 1
        assert c.get("/daybook", headers={"X-Compii-Device": "nothing"}).status_code == 401

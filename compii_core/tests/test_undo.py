"""The undo centre: what Compii changed, listed by id, and put back one at a time.

Ordering matters more than here: an earlier change is only offered when nothing was
built on top of it, so reversing one can't leave a later move pointing at a file
that no longer exists.
"""

import json
import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from compii_core.agent import unbacked_claims
from compii_core.journal import Entry, Journal
from compii_core.keys import MemoryKeyStore
from compii_core.policy import ActionKind
from compii_core.server import build_app
from compii_core.tools import Toolbox

from test_core import home, quiet_voice  # noqa: F401 - fixtures and helper


@pytest.fixture
def journal(tmp_path: Path) -> Journal:
    return Journal(tmp_path / "workspace" / "journal.jsonl")


def _move(box: Toolbox, journal: Journal, task_id: str, name: str, into: Path) -> dict:
    res = box.execute("move_file", {"source": name, "destination": str(into)})
    journal.record(Entry(task_id, "move_file", "change", {}, True, res.text, res.undo))
    return {"id": journal.entries()[-1].id, "summary": res.text}


def _box(home) -> Toolbox:
    return Toolbox([home["downloads"]], home["workspace"], lambda _p: None)


# ---- what the centre offers ----------------------------------------------------


def test_only_the_latest_change_of_a_task_is_offered(journal):
    now = time.time()
    journal.record(Entry("t1", "move_file", "change", {}, True, "Moved a to b",
                         {"op": "move", "src": "C:/x/a.txt", "dst": "C:/x/b.txt"}, at=now - 400))
    journal.record(Entry("t1", "move_file", "change", {}, True, "Moved b to c",
                         {"op": "move", "src": "C:/x/b.txt", "dst": "C:/x/c.txt"}, at=now - 300))
    journal.record(Entry("t2", "send_mail", "send", {}, True, "Mailed the invoice", at=now - 200))
    journal.record(Entry("t3", "click_on", "change", {}, True, "Clicked Save", at=now - 100))

    rows = journal.reversible()
    assert [r["summary"] for r in rows] == ["Moved b to c"]
    assert rows[0]["id"].startswith("e") and rows[0]["task_id"] == "t1"
    assert rows[0]["what"]["dst"] == "C:/x/c.txt"


def test_the_day_is_a_window_not_a_guess(journal):
    now = time.time()
    journal.record(Entry("t1", "move_file", "change", {}, True, "Today",
                         {"op": "move", "src": "a", "dst": "b"}, at=now - 60))
    journal.record(Entry("t2", "move_file", "change", {}, True, "Yesterday",
                         {"op": "move", "src": "c", "dst": "d"}, at=now - 26 * 3600))

    assert [r["summary"] for r in journal.reversible(since=now - 3600)] == ["Today"]
    assert [r["summary"] for r in journal.reversible()] == ["Today", "Yesterday"]


def test_the_undone_one_disappears_from_the_list(journal, home):
    box, src = _box(home), home["downloads"] / "holiday.jpg"
    row = _move(box, journal, "t1", str(src), home["workspace"])
    assert not src.exists()

    assert "back to" in journal.undo_by_id(row["id"])
    assert src.exists()
    assert journal.reversible() == []


def test_a_file_compii_made_is_kept_not_thrown_away(journal, tmp_path):
    made = tmp_path / "note.md"
    made.write_text("draft", encoding="utf-8")
    journal.record(Entry("t1", "write_text_file", "create", {}, True, "Wrote note.md",
                         {"op": "created", "path": str(made)}))

    msg = journal.undo_by_id(journal.reversible()[0]["id"])
    assert not made.exists() and "kept a copy" in msg
    assert list((journal.path.parent / "undone").glob("*note.md"))


def test_what_cannot_be_put_back_says_why(journal):
    now = time.time()
    journal.record(Entry("t1", "click_on", "change", {}, False, "Clicked Send",
                         {"op": "move", "src": "a", "dst": "b"}, at=now - 300))
    journal.record(Entry("t2", "look_at_screen", "read", {}, True, "Read the window", at=now - 200))
    ids = [e.id for e in journal.entries()]

    assert journal.reversible() == []
    assert "didn’t work in the first place" in journal.undo_by_id(ids[0])
    assert "never recorded a way back" in journal.undo_by_id(ids[1])
    assert "can't find that action" in journal.undo_by_id("enothere1234")


def test_a_line_written_before_ids_is_still_reachable(journal, home):
    src, dst = home["downloads"] / "holiday.jpg", home["workspace"] / "holiday.jpg"
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(b"jpg")
    journal.path.write_text(json.dumps({"task_id": "old", "tool": "move_file", "kind": "change", "input": {},
                                        "ok": True, "summary": "Moved holiday.jpg",
                                        "undo": {"op": "move", "src": str(src), "dst": str(dst)},
                                        "at": time.time() - 60}) + "\n", encoding="utf-8")

    handle = journal.reversible()[0]["id"]
    assert handle.startswith("l") and journal.reversible()[0]["id"] == handle
    assert "back to" in journal.undo_by_id(handle)
    assert src.exists() and not dst.exists()
    assert "already put back" in journal.undo_by_id(handle)


# ---- the file has to survive a power cut ---------------------------------------


def test_a_torn_line_skips_the_step_it_broke_not_the_whole_journal(journal, tmp_path):
    """A write cut short by a power loss leaves half a line: the rest must still read."""
    src, dst = tmp_path / "a.txt", tmp_path / "b.txt"
    dst.write_text("moved here", encoding="utf-8")
    move = {"op": "move", "src": str(src), "dst": str(dst)}
    journal.record(Entry("t1", "move_file", "change", {}, True, "Good", move))
    with journal.path.open("a", encoding="utf-8") as f:
        f.write('{"task_id": "t2", "tool": "move_file", "kind": "chan')  # half a line, as a crash leaves it
        f.write("\n")
    journal.record(Entry("t3", "move_file", "change", {}, True, "Also good",
                         {"op": "move", "src": str(tmp_path / "c.txt"), "dst": str(tmp_path / "d.txt")}))

    assert [e.task_id for e in journal.entries()] == ["t1", "t3"]
    assert [r["task_id"] for r in journal.reversible()] == ["t3", "t1"]

    # Undoing one rewrites the file: the torn line must still be there afterwards, not quietly lost.
    journal.undo_by_id(journal.entries()[0].id)
    assert len(journal.path.read_text(encoding="utf-8").splitlines()) == 4
    assert src.read_text(encoding="utf-8") == "moved here"


def test_a_line_from_a_newer_build_is_read_for_what_this_one_knows(journal):
    journal.path.write_text(json.dumps({"task_id": "t1", "tool": "move_file", "kind": "change", "input": {},
                                        "ok": True, "summary": "Moved", "at": time.time(), "id": "eabc1234",
                                        "undo": {"op": "move", "src": "a", "dst": "b"},
                                        "confidence": 0.9, "device": "phone"}) + "\n", encoding="utf-8")
    assert [e.id for e in journal.entries()] == ["eabc1234"]
    assert journal.reversible()[0]["id"] == "eabc1234"


def test_undoes_from_several_threads_do_not_erase_the_record(journal):
    """Core records actions on more than one thread while the undo centre rewrites the file."""
    for n in range(30):
        journal.record(Entry(f"t{n}", "move_file", "change", {}, True, f"Moved {n}",
                             {"op": "move", "src": f"C:/x/{n}.txt", "dst": f"C:/y/{n}.txt"}))
    ids = [e.id for e in journal.entries()]

    def mark(entry_id: str) -> None:
        journal._mark_done(journal.entry(entry_id))  # noqa: SLF001 - the race itself is what is under test

    threads = [threading.Thread(target=mark, args=(i,)) for i in ids[:10]]
    writers = [threading.Thread(target=journal.record,
                                args=(Entry(f"w{n}", "click_on", "change", {}, True, "appended"),)) for n in range(10)]
    for t in threads + writers:
        t.start()
    for t in threads + writers:
        t.join()

    after = journal.entries()
    assert len(after) == 40  # every append survived the ten rewrites
    assert sum(1 for e in after if e.undo and e.undo.get("done")) == 10
    assert sum(1 for e in after if e.tool == "click_on") == 10


# ---- what Compii can be told to do ---------------------------------------------


def test_the_undo_tool_asks_before_it_acts(journal, home):
    from compii_core.server import _undo_tool

    tool = _undo_tool(journal)
    assert tool.kind_for({}) is ActionKind.READ
    assert tool.kind_for({"id": "e12345678"}) is ActionKind.CHANGE
    assert "no id" in tool.description and "list" in tool.description.lower()

    assert tool.run({}).text == "Nothing Compii changed is still waiting to be put back."
    box = _box(home)
    row = _move(box, journal, "t1", str(home["downloads"] / "invoice-sept-01.pdf"), home["workspace"])

    listing = tool.run({})
    assert row["id"] in listing.text and "never make one up" in listing.text
    assert "back to" in tool.run({"id": row["id"]}).text
    assert home["downloads"].joinpath("invoice-sept-01.pdf").exists()


def test_claiming_something_is_put_back_needs_the_undo_tool():
    assert unbacked_claims("I've put it back where it was.", set()) == ["put something back"]
    assert unbacked_claims("I'll put the folder back now.", set()) == ["put something back"]
    assert unbacked_claims("I'm putting it back for you.", set()) == ["put something back"]
    assert unbacked_claims("I undid that move.", {"undo_action"}) == []
    assert unbacked_claims("I undid that move.", {"move_file"}) == []
    assert unbacked_claims("Nothing here needs undoing today.", set()) == []
    # Not every "put … back" is a claim about a file.
    assert unbacked_claims("I'll put the kettle on and be back in a minute.", set()) == []


# ---- the app's route -----------------------------------------------------------


def _app(home, monkeypatch):
    monkeypatch.setattr("compii_core.reach._v2ex_hot", lambda **kw: [])
    built = build_app(workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                      voice=quiet_voice(home["workspace"]), keys=MemoryKeyStore())
    return TestClient(built), built


def test_the_app_lists_and_undoes_by_id(home, monkeypatch):
    client, built = _app(home, monkeypatch)
    h = {"X-Compii-Token": "tok"}
    journal = built.state.agent.journal
    res = Toolbox([home["downloads"]], home["workspace"], lambda _p: None).execute(
        "move_file", {"source": str(home["downloads"] / "holiday.jpg"), "destination": str(home["workspace"])})
    journal.record(Entry("t1", "move_file", "change", {}, True, res.text, res.undo))

    with client:
        assert client.get("/undo").status_code == 401
        rows = client.get("/undo?hours=24", headers=h).json()["actions"]
        assert [r["summary"] for r in rows] == [res.text]
        assert client.post("/undo", json={"id": rows[0]["id"]}, headers=h).json()["result"].startswith("Moved")
        assert client.get("/undo?hours=24", headers=h).json()["actions"] == []
        assert client.post("/undo", json={"id": ""}, headers=h).status_code == 400
        assert (home["downloads"] / "holiday.jpg").exists()


def test_the_daybook_points_at_the_same_id(home, monkeypatch):
    from compii_core.daybook import build_daybook

    client, built = _app(home, monkeypatch)
    journal = built.state.agent.journal
    res = Toolbox([home["downloads"]], home["workspace"], lambda _p: None).execute(
        "move_file", {"source": str(home["downloads"] / "holiday.jpg"), "destination": str(home["workspace"])})
    journal.record(Entry("t7", "move_file", "change", {}, True, res.text, res.undo))

    with client:
        book = build_daybook(tasks=[], journal=journal, timeline=None, hours=24)
        assert book["actions"][0]["id"] == journal.entries()[0].id
        assert book["undo"]["id"] == book["actions"][0]["id"]
        # The older route still works, so nothing the app already knows is broken.
        assert client.post("/tasks/t7/undo", headers={"X-Compii-Token": "tok"}).json()["result"].startswith("Moved")

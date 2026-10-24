"""Compii noticing a repeated ask and offering to take it over — counting, offering, accepting."""

import datetime as dt
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from compii_core import proactive as pro
from compii_core.chats import save as save_chats
from compii_core.keys import MemoryKeyStore
from compii_core.policy import ActionKind
from compii_core.proactive import Proactive
from compii_core.server import _habit_tool, build_app
from compii_core.skills import Skills
from compii_core.suggest import MAX_OPEN, Suggestions, habits, shape

from test_core import home, quiet_voice


def _at(*when: int) -> float:
    return dt.datetime(*when).timestamp()


def _rec(text: str, when: float, *, status: str = "done", origin: dict | None = None,
         steps: tuple[str, ...] = ()) -> dict:
    events = [{"type": "action_done", "ok": True, "tool": "list_folder", "label": s} for s in steps]
    return {"id": f"t{when}", "request": text, "status": status, "created": when,
            "origin": origin or {}, "bot_id": None, "team": [], "events": events, "history": []}


class Box:
    """Just enough of a toolbox to hold a tool."""

    def __init__(self) -> None:
        self.tools: dict = {}


NOW = _at(2026, 10, 21, 18, 0)
MORNINGS = [_rec("summarize the new files in Downloads folder", _at(2026, 10, d, 9, 0)) for d in (12, 13, 14)]


# ---- what counts as the same ask again ------------------------------------------


def test_specifics_are_washed_out_so_variants_of_one_ask_are_one_habit():
    assert shape("sort the invoices in D:\\Scan into 2026 folders") == shape("Sort my invoices into the folders")
    assert "2026" not in shape("remind me at 18:30 to call 555-0100")
    assert shape("email “Sam” to say I am late") == shape('email "Priya" to say I am late') == "email say late"


def test_a_habit_needs_three_asks_on_more_than_one_day():
    same_day = [_rec("summarize the new files in Downloads folder", _at(2026, 10, 12, h, m))
                for h, m in ((9, 5), (11, 0), (15, 30))]
    assert habits(same_day, now=NOW) == []
    across_days = same_day + [_rec("summarize the new files in Downloads folder", _at(2026, 10, 14, 9, 20))]
    got = habits(across_days, now=NOW)
    assert len(got) == 1 and got[0]["count"] == 4


def test_asks_compii_started_itself_are_not_the_users_habit():
    fired = [_rec("read my inbox", _at(2026, 10, d, 9, 0), origin={"routine": "r1"}) for d in (12, 13, 14)]
    fired += [_rec("read my inbox", _at(2026, 10, 15, 9, 0), origin={"watch": "w1"})]
    assert habits(fired, now=NOW) == []
    assert habits(MORNINGS + fired, now=NOW)[0]["count"] == 3


def test_a_habit_already_scheduled_is_not_news():
    assert habits(MORNINGS, now=NOW)
    assert habits(MORNINGS, exclude=["Summarize whatever is new in Downloads folder"], now=NOW) == []


# ---- the schedule it guesses, and the honesty of the reason ----------------------


def test_weekday_mornings_become_a_weekday_routine():
    got = habits(MORNINGS, now=NOW)[0]
    assert got["kind"] == "routine" and got["schedule"] == {"kind": "weekdays", "at": "09:00"}
    assert "3 times" in got["why"] and "weekdays" in got["why"]
    assert "hasn't done any of this by itself" in got["why"]


def test_the_same_weekday_every_time_is_named_as_weekly():
    got = habits([_rec("check the team spreadsheet", _at(2026, 10, d, 16, 5)) for d in (5, 12, 19)], now=NOW)[0]
    assert got["schedule"]["kind"] == "weekly" and got["schedule"]["days"] == ["mon"]


def test_asks_through_the_day_become_a_repeat_rather_than_a_morning():
    through = [_rec("tell me what changed in my inbox", _at(2026, 10, d, h, 0))
               for d, h in ((12, 8), (12, 11), (12, 15), (13, 9), (13, 12))]
    got = habits(through, now=NOW)[0]
    assert got["schedule"]["kind"] == "every" and got["schedule"]["minutes"] % 60 == 0
    assert "every 4 hours" in got["why"]
    assert pro.validate_schedule(got["schedule"]) == got["schedule"]


def test_a_scattered_habit_offers_a_skill_and_only_if_steps_actually_worked():
    scattered = [_rec("turn my receipts into an expense sheet", _at(2026, 10, d, h, 0))
                 for d, h in ((10, 21), (14, 7), (19, 15))]
    assert habits(scattered, now=NOW) == []  # nothing that worked to remember
    worked = scattered[:-1] + [_rec("turn my receipts into an expense sheet", _at(2026, 10, 19, 15, 0),
                                    steps=("Found the receipts", "Wrote the expense sheet"))]
    got = habits(worked, now=NOW)[0]
    assert got["kind"] == "skill" and got["schedule"] == {}
    assert got["steps"] == ["Found the receipts", "Wrote the expense sheet"]


def test_a_failed_ask_is_described_from_the_one_that_actually_worked():
    mixed = [_rec("turn my receipts into an expense sheet", _at(2026, 10, 10, 21, 0), status="failed"),
             _rec("turn my receipts into an expense sheet", _at(2026, 10, 14, 7, 0), status="stopped"),
             _rec("Turn my receipts into an expense sheet", _at(2026, 10, 19, 15, 0),
                  steps=("Found the receipts", "Wrote the expense sheet"))]
    got = habits(mixed, now=NOW)[0]
    assert got["instruction"] == "Turn my receipts into an expense sheet" and got["count"] == 3


def test_the_instruction_is_the_real_ask_not_a_paraphrase():
    asks = [_rec("summarize the new files in Downloads folder", _at(2026, 10, 12, 9, 0)),
            _rec("summarize the new files in Downloads folder", _at(2026, 10, 13, 9, 0)),
            _rec("Summarize the new files in the Downloads folder", _at(2026, 10, 14, 9, 0))]
    got = habits(asks, now=NOW)[0]
    assert got["instruction"] == "Summarize the new files in the Downloads folder"
    assert got["title"].startswith("Summarize")


# ---- the offers Compii keeps ------------------------------------------------------


def test_accepting_makes_the_routine_and_the_offer_stops_coming_back(tmp_path):
    store = Suggestions(tmp_path / "suggestions.json")
    found = store.scan(MORNINGS, now=NOW)
    assert len(found) == 1 and found[0].status == "open"
    plans = Proactive(tmp_path / "proactive.json")
    made = store.accept(found[0].id, plans=plans, skills=Skills(tmp_path / "skills.json"))
    assert made["kind"] == "routine" and made["when"] == "Every weekday at 09:00"
    routine = plans.routines[made["id"]]
    assert routine.instruction == "summarize the new files in Downloads folder"
    assert routine.next_run  # it is on the clock from now on
    assert store.scan(MORNINGS, now=NOW + 4000) == []  # a habit Compii already does is not re-offered


def test_accepting_a_skill_offer_saves_the_steps_that_worked(tmp_path):
    store = Suggestions(tmp_path / "suggestions.json")
    asks = [_rec("turn my receipts into an expense sheet", _at(2026, 10, 10, 21, 0)),
            _rec("turn my receipts into an expense sheet", _at(2026, 10, 14, 7, 0)),
            _rec("Turn my receipts into an expense sheet", _at(2026, 10, 19, 15, 0),
                 steps=("Found the receipts", "Wrote the expense sheet"))]
    found = store.scan(asks, now=NOW)
    assert found[0].kind == "skill"
    skills = Skills(tmp_path / "skills.json")
    made = store.accept(found[0].id, plans=Proactive(tmp_path / "proactive.json"), skills=skills)
    assert made["kind"] == "skill" and made["steps"] == 2
    assert skills.named(found[0].title).steps == ["Found the receipts", "Wrote the expense sheet"]


def test_an_offer_can_be_answered_only_once_and_a_time_can_be_chosen(tmp_path):
    store = Suggestions(tmp_path / "suggestions.json")
    plans = Proactive(tmp_path / "proactive.json")
    asks = [_rec("turn my receipts into an expense sheet", _at(2026, 10, 10, 21, 0)),
            _rec("turn my receipts into an expense sheet", _at(2026, 10, 14, 7, 0)),
            _rec("Turn my receipts into an expense sheet", _at(2026, 10, 19, 15, 0),
                 steps=("Found the receipts", "Wrote the expense sheet"))]
    found = store.scan(asks, now=NOW)
    made = store.accept(found[0].id, plans=plans, skills=Skills(tmp_path / "skills.json"),
                        schedule={"kind": "daily", "at": "17:00"})
    assert made["kind"] == "routine" and made["when"] == "Every day at 17:00"
    with pytest.raises(ValueError, match="already been answered"):
        store.accept(found[0].id, plans=plans, skills=Skills(tmp_path / "skills.json"))


def test_declining_keeps_the_offer_quiet_for_a_month(tmp_path):
    store = Suggestions(tmp_path / "suggestions.json")
    found = store.scan(MORNINGS, now=NOW)[0]
    answered = store.resolve(found.id, "declined")
    # The cooldown counts from when the answer was actually given, which resolve stamps
    # with the real clock; measuring from the fixture's fake NOW makes this pass or fail
    # depending on the hour the suite runs.
    assert answered is not None
    assert store.scan(MORNINGS, now=answered.resolved + 86400) == []
    assert store.scan(MORNINGS, now=answered.resolved + 32 * 86400)  # still a habit a month later: ask again


def test_only_the_strongest_offers_are_shown_and_answers_survive_a_restart(tmp_path):
    path = tmp_path / "suggestions.json"
    store = Suggestions(path)
    asks = []
    for n, thing in enumerate(["tidy the invoice folder", "summarize my meeting notes", "back up my photo album",
                               "send the weekly report", "clear out junk mail", "rename my downloads",
                               "print the budget sheet"]):
        asks += [_rec(thing, _at(2026, 10, d, 9, 0)) for d in (12, 13)] + \
                [_rec(thing, _at(2026, 10, 15, 9, 0))] * n
    open_items = store.scan(asks, now=NOW)
    assert len(open_items) == MAX_OPEN
    assert open_items[0].count == max(h["count"] for h in habits(asks, now=NOW))
    assert any(s.status == "expired" for s in store.items.values())
    assert [s.id for s in Suggestions(path).open()] == [s.id for s in open_items]


def test_a_damaged_offers_file_is_kept_and_started_fresh(tmp_path):
    path = tmp_path / "suggestions.json"
    path.write_text("{ not json", encoding="utf-8")
    store = Suggestions(path)
    assert store.items == {}
    assert list(tmp_path.glob("suggestions.broken-*.json"))


def test_the_archive_is_only_re_read_when_it_could_have_changed(tmp_path):
    store = Suggestions(tmp_path / "suggestions.json")
    store.refresh(MORNINGS, now=NOW)
    before = store.last_scan
    store.refresh([_rec("something else entirely", _at(2026, 10, 20, 9, 0))], now=NOW + 60)
    assert store.last_scan == before  # a minute later: the offers counted an hour ago still stand
    assert len(store.view()) == 1


def test_an_empty_archive_offers_nothing(tmp_path):
    assert Suggestions(tmp_path / "suggestions.json").scan([], now=time.time()) == []


# ---- Compii's own view, and the app's -------------------------------------------


def test_compii_reports_repetition_only_from_the_counting_tool():
    box = Box()
    _habit_tool(box, lambda: [{"title": "Summarize new files", "kind": "routine", "count": 4,
                               "steps": ["Listed the folder"]}])
    tool = box.tools["noticed_habits"]
    assert tool.kind is ActionKind.READ
    out = tool.run({}).text
    assert "asked 4 times" in out and "Listed the folder" in out and "let the user decide" in out


def test_with_nothing_repeated_compii_says_so_rather_than_inventing_a_habit():
    box = Box()
    _habit_tool(box, lambda: [])
    assert "Nothing has come back three times" in box.tools["noticed_habits"].run({}).text


def test_saying_a_habit_repeated_without_counting_it_is_an_unbacked_claim():
    from compii_core.agent import unbacked_claims

    claim = "You've asked for this 4 times since Monday"
    assert unbacked_claims(claim, set()) == ["counted how often something repeats"]
    assert unbacked_claims(claim, {"noticed_habits"}) == []
    assert unbacked_claims("Ask Compii to do it whenever you like", set()) == []


class _Task:
    """The bits of a finished conversation the archive keeps."""

    def __init__(self, record: dict) -> None:
        self.id, self.request, self.status = record["id"], record["request"], record["status"]
        self.created, self.origin, self.bot_id, self.team = record["created"], record["origin"], None, []
        self.active = record["created"]
        self.events, self.history = record["events"], record["history"]


def _seed(workspace: Path, asks: list[dict]) -> None:
    save_chats(workspace / "chats.json", [_Task(r) for r in asks])


def test_repeated_asks_are_offered_on_the_routines_page_and_can_be_taken_up(home, monkeypatch):
    monkeypatch.setattr("compii_core.reach._v2ex_hot", lambda **kw: [])
    _seed(home["workspace"], MORNINGS)
    app = build_app(workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]), keys=MemoryKeyStore())
    h = {"X-Compii-Token": "tok"}
    with TestClient(app) as c:
        got = c.get("/proactive", headers=h).json()
        assert got["suggestions"][0]["title"].startswith("Summarize")
        sid = got["suggestions"][0]["id"]
        made = c.post(f"/suggestions/{sid}/accept", json={}, headers=h).json()
        assert made["made"]["kind"] == "routine"
        assert [r["title"] for r in made["routines"]] == [made["made"]["title"]]
        assert c.post(f"/suggestions/{sid}/accept", json={}, headers=h).status_code == 400
        assert c.post("/suggestions/gzzzzzzz/accept", json={}, headers=h).status_code == 404
        assert c.get("/proactive", headers=h).json()["suggestions"] == []
        assert c.post("/suggestions/nonsense/decline", headers=h).status_code == 404


def test_declining_on_the_app_closes_the_card(home, monkeypatch):
    monkeypatch.setattr("compii_core.reach._v2ex_hot", lambda **kw: [])
    _seed(home["workspace"], MORNINGS)
    app = build_app(workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]), keys=MemoryKeyStore())
    h = {"X-Compii-Token": "tok"}
    with TestClient(app) as c:
        sid = c.get("/proactive", headers=h).json()["suggestions"][0]["id"]
        after = c.post(f"/suggestions/{sid}/decline", headers=h).json()
        assert after["suggestions"] == [] and after["routines"] == []
        assert c.app.state.suggestions.items[sid].status == "declined"

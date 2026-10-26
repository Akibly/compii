"""The end-of-day recap and the every-few-hours "needs you" check (after Muse's end-of-day recap and
Claude Duet's check-ins): built locally, quiet when there is nothing, one nudge per thing."""

import datetime as dt
from dataclasses import dataclass, field

from compii_core.proactive import Proactive, compose_checkin, compose_recap

from test_core import home  # noqa: F401 - fixture


@dataclass
class T:
    id: str
    request: str
    status: str
    events: list = field(default_factory=list)
    active: float = 0.0


def _at(now, minutes_ago):
    return (now - dt.timedelta(minutes=minutes_ago)).timestamp()


NOW = dt.datetime(2026, 10, 26, 18, 30)


def test_the_recap_says_what_landed_what_did_not_and_what_waits(tmp_path):
    plans = Proactive(tmp_path / "p.json")
    tasks = [
        T("a", "Sort my downloads", "done", [{"type": "action_done", "ok": True, "at": _at(NOW, 90)},
                                             {"type": "task_finished", "at": _at(NOW, 80)}]),
        T("b", "Book the dentist", "failed", [{"type": "task_finished", "at": _at(NOW, 30)}]),
        T("c", "Send the invoice", "waiting", [{"type": "approval_needed", "at": _at(NOW, 10)}]),
        T("d", "Yesterday's thing", "done", [{"type": "task_finished", "at": _at(NOW, 60 * 24)}]),
    ]
    u = compose_recap(tasks=tasks, proactive=plans, now=NOW)
    assert u.title == "Your day, wrapped up"
    assert u.body == "1 task finished, 1 action taken, 1 didn't finish and 1 still waits on you."
    titles = {s["title"]: s["items"] for s in u.sections}
    assert titles["Finished today"] == ["Sort my downloads"]
    assert titles["Didn't finish"] == ["Book the dentist (failed)"]
    assert titles["Still waiting on you"] == ["Send the invoice"]


def test_a_quiet_day_says_so(tmp_path):
    u = compose_recap(tasks=[], proactive=Proactive(tmp_path / "p.json"), now=NOW)
    assert u.body.startswith("A quiet day")


def test_a_check_in_nudges_once_per_thing_and_stays_silent_otherwise():
    told: list[str] = []
    fresh = T("x", "Approve the email", "waiting", [{"type": "approval_needed", "at": _at(NOW, 5)}])
    assert compose_checkin(tasks=[fresh], told=told, now=NOW) is None  # still on their screen
    old = T("y", "Answer the question", "waiting", [{"type": "question", "at": _at(NOW, 45)}])
    u = compose_checkin(tasks=[fresh, old], told=told, now=NOW)
    assert u.kind == "needs_you" and u.title == "One thing needs you" and u.task_id == "y"
    assert u.body == "1 thing has waited on you a while."
    assert compose_checkin(tasks=[fresh, old], told=told, now=NOW) is None  # told already


def test_digests_come_when_due_and_survive_a_restart(tmp_path):
    path = tmp_path / "p.json"
    plans = Proactive(path)
    waiting = [T("y", "Answer the question", "waiting", [{"type": "question", "at": _at(NOW, 45)}])]
    early = NOW.replace(hour=7, minute=0)
    assert plans.due_digests(early, waiting) == []  # before the check-in window and the recap
    got = plans.due_digests(NOW, waiting)
    assert [(u.title, speak) for u, speak in got] == [("Your day, wrapped up", False), ("One thing needs you", True)]
    assert plans.due_digests(NOW + dt.timedelta(minutes=5), waiting) == []  # once a day, every few hours
    again = Proactive(path)
    assert again.recap["last"] == NOW.date().isoformat() and "y" in again.checkin["told"]
    assert [u.title for u in again.inbox][-2:] == ["Your day, wrapped up", "One thing needs you"]
    assert again.due_digests(NOW + dt.timedelta(hours=1), waiting) == []  # no repeat after a restart


def test_recap_and_checkin_settings_routes(home):
    from fastapi.testclient import TestClient

    from compii_core.keys import MemoryKeyStore
    from compii_core.server import build_app

    from test_core import quiet_voice

    app = build_app(brain=None, workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))
    with TestClient(app) as c:
        h = {"X-Compii-Token": "tok"}
        view = c.put("/recap", json={"at": "19:5", "enabled": False}, headers=h).json()
        assert view["recap"]["at"] == "19:05" and view["recap"]["enabled"] is False
        view = c.put("/checkin", json={"every_hours": 2, "start": "9:00", "end": "20:30"}, headers=h).json()
        # `last` is left out: the app's own loop may already have checked in during the day.
        got = {k: v for k, v in view["checkin"].items() if k != "last"}
        assert got == {"enabled": True, "every_hours": 2, "from": "09:00", "to": "20:30"}
        assert c.put("/checkin", json={"every_hours": 30}, headers=h).status_code == 400
        assert c.put("/recap", json={"at": "late"}, headers=h).status_code == 400

"""Per-bot routines, their run history, and teaching a task by demonstrating it."""

import asyncio
import datetime as dt
import time

from fastapi.testclient import TestClient

from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401 - fixtures


def _app(home, brain=None, token="tok"):
    return build_app(brain=brain or ScriptBrain([], final="Done."), workspace=home["workspace"],
                     roots=[home["downloads"]], token=token, keys=MemoryKeyStore(),
                     voice=quiet_voice(home["workspace"]))


async def test_a_routine_runs_as_the_teammate_who_owns_it(home):
    app = _app(home, ScriptBrain([], final="Inbox is clear."))
    plans = app.state.plans
    plans.brief["enabled"] = False
    bot = app.state.bots.create("Inbox Manager", template="inbox")
    r = plans.add_routine("Morning mail", "Triage my inbox", {"kind": "daily", "at": "07:00"}, bot_id=bot.id)
    r.next_run = (dt.datetime.now() - dt.timedelta(minutes=1)).replace(second=0, microsecond=0).isoformat()

    await app.state.tick()
    task = next(t for t in app.state.agent.tasks.values() if (t.origin or {}).get("routine") == r.id)
    assert task.bot_id == bot.id and task.origin["bot"] == bot.id
    await asyncio.wait_for(task.runner, 10)
    await asyncio.sleep(0)

    saved = plans.routines[r.id]
    assert saved.last_task == task.id
    assert saved.runs and saved.runs[0]["task_id"] == task.id and saved.runs[0]["status"] == "done"
    assert plans.inbox[-1].kind == "routine"


def test_a_routine_can_be_edited_and_keeps_its_history(home):
    app = _app(home)
    bot = app.state.bots.create("Researcher", template="researcher")
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        made = client.post("/routines", json={"title": "Check prices", "instruction": "Look for drops",
                                              "schedule": {"kind": "daily", "at": "09:00"}}, headers=h)
        rid = made.json()["routines"][0]["id"]
        edited = client.put(f"/routines/{rid}", json={
            "title": "Price watch", "instruction": "Look for price drops under €50",
            "schedule": {"kind": "weekdays", "at": "18:30"}, "bot_id": bot.id,
        }, headers=h)
        assert edited.status_code == 200, edited.text
        row = edited.json()["routines"][0]
        assert row["title"] == "Price watch" and row["bot_id"] == bot.id
        assert row["when"] == "Every weekday at 18:30"

        ran = client.post(f"/routines/{rid}/run", headers=h)
        assert ran.status_code == 200
        task_id = ran.json()["id"]
        view = client.get("/proactive", headers=h).json()["routines"][0]
        assert view["runs"][0]["task_id"] == task_id
        assert client.post("/routines", json={"title": "x", "instruction": "x",
                                              "schedule": {"kind": "daily", "at": "07:00"},
                                              "bot_id": "nope"}, headers=h).status_code == 400


class StubWatcher:
    """Stands in for the real screen watcher; the test fills in the steps."""

    def __init__(self):
        self.running = False
        self.steps = []
        self.actions = []
        self.started = 0.0

    def start(self):
        self.running = True
        self.steps, self.actions, self.started = [], [], time.monotonic()

    def stop(self):
        self.running = False
        return list(self.steps)

    def recorded(self):
        return [dict(a) for a in self.actions]


def test_teach_records_reviews_and_schedules_a_skill(home):
    app = _app(home)
    bot = app.state.bots.create("File Clerk", template="clerk")
    watcher = StubWatcher()
    app.state.buddy.watcher = watcher
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        start = client.post("/teach/start", json={"goal": "sort invoices"}, headers=h)
        assert start.status_code == 200 and start.json()["watching"] is True
        watcher.steps[:] = ['Click button “New folder” in “Explorer”', 'Type the text into “Name”']
        watcher.actions[:] = [{"kind": "click", "target": "New folder", "window": "Explorer"},
                              {"kind": "type", "field": "Name", "window": "Explorer"}]

        stop = client.post("/teach/stop", headers=h)
        assert stop.status_code == 200, stop.text
        draft = stop.json()
        assert draft["steps"] == watcher.steps and len(draft["actions"]) == 2

        saved = client.post("/teach/save", json={
            "name": "Sort invoices", "about": "Files new invoices by month.",
            "schedule": {"kind": "weekdays", "at": "17:00"}, "bot_id": bot.id,
        }, headers=h)
        assert saved.status_code == 200, saved.text
        body = saved.json()
        assert body["skill"]["name"] == "Sort invoices" and len(body["skill"]["actions"]) == 2
        assert body["routine"]["bot_id"] == bot.id
        assert watcher.running is False
        assert client.get("/teach", headers=h).json()["draft"] is False

        # The skill is there to run by name, and its routine runs as the File Clerk.
        skills = client.get("/skills", headers=h).json()
        assert any(s["name"] == "Sort invoices" and s["actions"] for s in skills)
        routines = client.get("/proactive", headers=h).json()["routines"]
        assert routines[0]["title"] == "Sort invoices" and routines[0]["bot_id"] == bot.id


def test_teach_review_trims_and_checks_steps(home, monkeypatch):
    app = _app(home)
    watcher = StubWatcher()
    app.state.buddy.watcher = watcher
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        assert client.post("/teach/start", json={"goal": "sort invoices"}, headers=h).status_code == 200
        watcher.steps[:] = ['Click button “New folder” in “Explorer”', 'Type the text into “Name”']
        watcher.actions[:] = [{"kind": "click", "target": "New folder", "window": "Explorer"},
                              {"kind": "type", "field": "Name", "window": "Explorer"}]
        assert client.post("/teach/stop", headers=h).status_code == 200

        from compii_core.tools import Toolbox

        class Found:
            name = "New folder"
            window = "Explorer"

        monkeypatch.setattr(Toolbox, "locate", lambda self, target: Found() if target == "New folder" else None)
        monkeypatch.setattr(Toolbox, "window_titles", lambda self: ["Explorer"])

        one = client.post("/teach/check", json={"keep": [0]}, headers=h)
        assert one.status_code == 200, one.text
        assert one.json()["ok"] is True and one.json()["steps"] == [watcher.steps[0]]
        missing = client.post("/teach/check", json={"keep": [0, 1]}, headers=h).json()
        assert missing["ok"] is False
        assert missing["checks"][1]["ok"] is False and "Name" in missing["checks"][1]["detail"]

        saved = client.post("/teach/save", json={"name": "New folder only", "keep": [0],
                                                 "steps": ["Open the New folder dialog"]}, headers=h)
        assert saved.status_code == 200, saved.text
        skill = saved.json()["skill"]
        assert skill["steps"] == ["Open the New folder dialog"]
        assert len(skill["actions"]) == 1 and skill["actions"][0]["kind"] == "click"


def test_teach_refuses_when_screen_reading_is_off(home):
    from compii_core import sight

    app = _app(home)
    with TestClient(app) as client:
        sight.set_enabled(False)
        try:
            r = client.post("/teach/start", json={"goal": "anything"}, headers={"X-Compii-Token": "tok"})
            assert r.status_code == 423 and "screen reading is turned off" in r.json()["detail"]
        finally:
            sight.set_enabled(True)

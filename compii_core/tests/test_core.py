import asyncio
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from compii_core.agent import Agent, BrainReply, ToolCall
from compii_core.journal import Journal
from compii_core.policy import ActionKind, Autonomy, Policy
from compii_core.rehearsal import RehearsalBrain
from compii_core.server import build_app
from compii_core.tools import Toolbox, ToolError


@pytest.fixture
def home(tmp_path: Path) -> dict[str, Path]:
    downloads = tmp_path / "Downloads"
    downloads.mkdir()
    (downloads / "invoice-sept-01.pdf").write_bytes(b"%PDF-fake")
    (downloads / "Invoice-sept-02.pdf").write_bytes(b"%PDF-fake2")
    (downloads / "holiday.jpg").write_bytes(b"jpg")
    return {"downloads": downloads, "workspace": tmp_path / "Compii", "outside": tmp_path / "Secret"}


@pytest.fixture
def opened() -> list[str]:
    return []


@pytest.fixture
def toolbox(home, opened) -> Toolbox:
    return Toolbox([home["downloads"]], home["workspace"], opened.append)


# ---- policy -------------------------------------------------------------------


def test_default_dial_asks_for_send_and_delete_but_not_reads():
    p = Policy()
    assert not p.needs_approval(ActionKind.READ, set())
    assert p.needs_approval(ActionKind.SEND, {ActionKind.SEND})
    assert p.needs_approval(ActionKind.DELETE, set())


def test_ask_once_per_task_stops_asking_after_first_approval():
    p = Policy()
    assert p.needs_approval(ActionKind.CHANGE, set())
    assert not p.needs_approval(ActionKind.CHANGE, {ActionKind.CHANGE})


def test_spending_can_never_be_set_to_just_do_it():
    with pytest.raises(ValueError):
        Policy().set(ActionKind.SPEND, Autonomy.JUST_DO_IT)


# ---- tools --------------------------------------------------------------------


def test_paths_outside_allowed_folders_are_refused(toolbox, home):
    home["outside"].mkdir()
    with pytest.raises(ToolError, match="outside the folders"):
        toolbox.execute("list_folder", {"path": str(home["outside"])})
    with pytest.raises(ToolError, match="outside the folders"):
        toolbox.execute("read_file", {"path": str(home["downloads"] / ".." / "Secret" / "x.txt")})


def test_find_files_is_case_insensitive(toolbox, home):
    out = json.loads(toolbox.execute("find_files", {"folder": str(home["downloads"]), "pattern": "*invoice*"}).text)
    assert out["count"] == 2


def test_move_can_be_undone_through_the_journal(toolbox, home, tmp_path):
    journal = Journal(tmp_path / "journal.jsonl")
    src = home["downloads"] / "holiday.jpg"
    res = toolbox.execute("move_file", {"source": str(src), "destination": str(home["workspace"])})
    from compii_core.journal import Entry

    journal.record(Entry("t1", "move_file", "change", {}, True, res.text, res.undo))
    assert not src.exists()
    assert "back to" in journal.undo_last("t1")
    assert src.exists()
    assert journal.undo_last("t1") == "Nothing to undo for this task."


def test_write_refuses_to_overwrite_without_flag(toolbox, home):
    target = home["workspace"] / "note.txt"
    toolbox.execute("write_text_file", {"path": str(target), "content": "a"})
    with pytest.raises(ToolError, match="already exists"):
        toolbox.execute("write_text_file", {"path": str(target), "content": "b"})
    assert toolbox.tools["write_text_file"].kind_for({"overwrite": True}) is ActionKind.CHANGE


def test_spreadsheet_round_trip_with_formula(toolbox, home):
    path = str(home["workspace"] / "t.xlsx")
    toolbox.execute("create_spreadsheet", {"path": path, "sheets": [
        {"name": "S", "header": ["Item", "Amount"], "rows": [["a", 2], ["b", 3], ["Total", "=SUM(B2:B3)"]]}]})
    text = toolbox.execute("read_file", {"path": path}).text
    assert "Item\tAmount" in text and "a\t2" in text


def test_email_without_account_opens_a_draft_and_says_not_sent(toolbox, opened, monkeypatch):
    monkeypatch.delenv("COMPII_SMTP_HOST", raising=False)
    res = toolbox.execute("send_email", {"to": ["a@example.com"], "subject": "Hi", "body": "Hello"})
    assert "NOT sent" in res.text
    assert opened and opened[0].endswith(".eml")


def test_open_item_refuses_executables(toolbox, home):
    exe = home["downloads"] / "setup.exe"
    exe.write_bytes(b"MZ")
    with pytest.raises(ToolError, match="does not launch programs"):
        toolbox.execute("open_item", {"target": str(exe)})


# ---- agent loop ----------------------------------------------------------------


class ScriptBrain:
    """Plays back a fixed list of tool calls, then a final message."""

    def __init__(self, calls: list[tuple[str, dict]], final: str = "All done.") -> None:
        self.calls = calls
        self.final = final
        self.seen: list[list[dict]] = []

    async def step(self, system, messages, tools):
        self.seen.append(messages)
        i = sum(1 for m in messages if m["role"] == "assistant")
        if i < len(self.calls):
            name, args = self.calls[i]
            return BrainReply([{"type": "tool_use", "id": f"c{i}", "name": name, "input": args}], "",
                              [ToolCall(f"c{i}", name, args)], "tool_use")
        return BrainReply([{"type": "text", "text": self.final}], self.final, [], "end_turn")


async def run_agent(toolbox, tmp_path, brain, on_event=None):
    events: list[dict] = []

    async def emit(e):
        events.append(e)
        if on_event:
            await on_event(e, agent)

    agent = Agent(brain, toolbox, Policy(), Journal(tmp_path / "j.jsonl"), emit)
    task = agent.start("do it")
    await asyncio.wait_for(task.runner, 5)
    return task, events, agent


async def test_approved_change_runs_and_task_finishes(toolbox, home, tmp_path):
    src = str(home["downloads"] / "holiday.jpg")
    brain = ScriptBrain([("move_file", {"source": src, "destination": str(home["workspace"])}),
                         ("list_folder", {"path": str(home["workspace"])})])

    async def approve(e, agent):
        if e["type"] == "approval_needed":
            assert e["kind"] == "change"
            agent.decide(e["approval_id"], True)

    task, events, _ = await run_agent(toolbox, tmp_path, brain, approve)
    assert task.status == "done"
    assert (home["workspace"] / "holiday.jpg").exists()
    assert [e["type"] for e in events].count("approval_needed") == 1


async def test_declined_action_is_not_run_and_model_is_told(toolbox, home, tmp_path):
    src = home["downloads"] / "holiday.jpg"
    brain = ScriptBrain([("move_file", {"source": str(src), "destination": str(home["workspace"])})])

    async def deny(e, agent):
        if e["type"] == "approval_needed":
            agent.decide(e["approval_id"], False)

    task, _, _ = await run_agent(toolbox, tmp_path, brain, deny)
    assert src.exists()
    result = brain.seen[-1][-2]["content"][0]  # the final assistant turn is appended after
    assert result["is_error"] and "declined" in result["content"]
    assert task.status == "done"


async def test_stop_while_waiting_for_approval_runs_nothing(toolbox, home, tmp_path):
    src = home["downloads"] / "holiday.jpg"
    brain = ScriptBrain([("move_file", {"source": str(src), "destination": str(home["workspace"])})])

    async def stop(e, agent):
        if e["type"] == "approval_needed":
            agent.stop(e["task_id"])

    task, events, _ = await run_agent(toolbox, tmp_path, brain, stop)
    assert task.status == "stopped"
    assert src.exists()
    assert not any(e["type"] == "action_started" for e in events)


async def test_tool_errors_go_back_to_the_model(toolbox, home, tmp_path):
    brain = ScriptBrain([("read_file", {"path": str(home["downloads"] / "missing.txt")})])
    task, events, _ = await run_agent(toolbox, tmp_path, brain)
    done = [e for e in events if e["type"] == "action_done"][0]
    assert not done["ok"] and task.status == "done"


# ---- HTTP service ---------------------------------------------------------------


def test_service_requires_token_and_runs_rehearsal(home, monkeypatch):
    monkeypatch.delenv("COMPII_SMTP_HOST", raising=False)
    brain = RehearsalBrain(home["downloads"], home["workspace"])
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]))
    agent = app.state.agent
    agent.toolbox._open = lambda _t: None
    with TestClient(app) as client:
        assert client.post("/tasks", json={"request": "x"}).status_code == 401
        h = {"X-Compii-Token": "tok"}
        with client.websocket_connect("/events?t=tok") as ws:
            task_id = client.post("/tasks", json={"request": "invoices"}, headers=h).json()["id"]
            while True:
                e = ws.receive_json()
                if e["type"] == "approval_needed":
                    assert e["kind"] == "send"
                    assert client.post(f"/approvals/{e['approval_id']}", json={"approved": True}, headers=h).json()["ok"]
                if e["type"] == "task_finished":
                    break
        tasks = client.get("/tasks", headers=h).json()
        assert tasks[0]["id"] == task_id and tasks[0]["status"] == "done"
        assert (home["workspace"] / "Invoices last month.xlsx").exists()


# ---- pointing -----------------------------------------------------------------


def test_point_at_reports_position_and_emits_point_event(toolbox, tmp_path):
    from compii_core.screen import Found

    toolbox._find = lambda target: Found("Save", "ButtonControl", "Report - Word", 100, 200, 160, 230)
    brain = ScriptBrain([("point_at", {"target": "save", "message": "Click Save."})])
    task, events, _ = asyncio.run(run_agent(toolbox, tmp_path, brain))
    point = next(e for e in events if e["type"] == "point")
    assert (point["x"], point["y"], point["w"], point["h"]) == (100, 200, 60, 30)
    assert point["message"] == "Click Save." and task.status == "done"


def test_point_at_missing_item_is_a_recoverable_error(toolbox):
    toolbox._find = lambda target: None
    with pytest.raises(ToolError, match="Couldn't find"):
        toolbox.execute("point_at", {"target": "Nope", "message": ""})


# ---- conversations, plans, files, memory ------------------------------------------


async def test_follow_up_continues_the_same_conversation(toolbox, home, tmp_path):
    brain = ScriptBrain([])
    events: list[dict] = []

    async def emit(e):
        events.append(e)

    agent = Agent(brain, toolbox, Policy(), Journal(tmp_path / "j.jsonl"), emit)
    task = agent.start("first question")
    await asyncio.wait_for(task.runner, 5)
    agent.reply(task.id, "and a follow-up")
    await asyncio.wait_for(task.runner, 5)
    user_texts = [m["content"] for m in task.messages if m["role"] == "user"]
    assert user_texts == ["first question", "and a follow-up"]
    assert any(e["type"] == "user_message" and e["text"] == "and a follow-up" for e in events)
    assert task.status == "done"


async def test_stopped_turn_leaves_a_valid_history_for_follow_ups(toolbox, home, tmp_path):
    src = home["downloads"] / "holiday.jpg"
    brain = ScriptBrain([("move_file", {"source": str(src), "destination": str(home["workspace"])})])

    async def stop(e, agent):
        if e["type"] == "approval_needed":
            agent.stop(e["task_id"])

    task, _, _ = await run_agent(toolbox, tmp_path, brain, stop)
    last = task.messages[-1]
    assert last["role"] == "user" and last["content"][0]["type"] == "tool_result"


async def test_plan_and_file_events_are_emitted(toolbox, home, tmp_path):
    brain = ScriptBrain([
        ("update_plan", {"steps": [{"title": "Write note", "status": "active"}]}),
        ("write_text_file", {"path": str(home["workspace"] / "n.txt"), "content": "hi"}),
    ])
    _, events, _ = await run_agent(toolbox, tmp_path, brain)
    plan = next(e for e in events if e["type"] == "plan")
    assert plan["steps"] == [{"title": "Write note", "status": "active"}]
    f = next(e for e in events if e["type"] == "file")
    assert f["path"].endswith("n.txt") and f["action"] == "created"


def test_memories_can_be_listed_and_forgotten(toolbox):
    toolbox.execute("remember", {"fact": "Prefers short replies"})
    toolbox.execute("remember", {"fact": "Works at Acme"})
    mems = toolbox.memories()
    assert [m["fact"] for m in mems] == ["Prefers short replies", "Works at Acme"]
    assert toolbox.forget(mems[0]["id"])
    assert [m["fact"] for m in toolbox.memories()] == ["Works at Acme"]
    assert "Acme" in toolbox.execute("recall", {"query": "acme"}).text


# ---- voice ------------------------------------------------------------------------

import numpy as np  # noqa: E402

from compii_core.voice import RATE, Voice  # noqa: E402


class FakeSpeaker:
    def __init__(self) -> None:
        self.said: list[str] = []
        self.stops = 0
        self.speaking = False

    def say(self, text: str) -> None:
        self.said.append(text)
        self.speaking = True

    def stop(self) -> None:
        self.stops += 1
        self.speaking = False


class FakeMic:
    def __init__(self) -> None:
        self.on_audio = None

    def start(self, on_audio) -> None:
        self.on_audio = on_audio
        on_audio(np.full(RATE, 0.05, np.float32))  # one second of "speech"

    def stop(self) -> None:
        pass


def quiet_voice(workspace: Path, events: list | None = None) -> Voice:
    v = Voice(workspace / "models", (events.append if events is not None else lambda e: None), FakeMic, FakeSpeaker())
    return v


def test_push_to_talk_gives_a_final_transcript_and_interrupts_speech(tmp_path):
    events: list[dict] = []
    v = quiet_voice(tmp_path, events)
    (v.whisper_dir).mkdir(parents=True)
    (v.whisper_dir / "model.bin").write_bytes(b"x")
    v.transcribe = lambda audio: "tidy my downloads" if audio.size >= RATE else ""
    v.say("I was in the middle of saying something")
    v.start_listening()
    assert v._speaker.stops >= 1, "the mic interrupts Compii"
    assert v.stop_listening() == "tidy my downloads"
    kinds = [e["type"] for e in events]
    assert kinds.count("voice_listening") == 2 and "voice_final" in kinds


def test_listening_needs_the_model_first(tmp_path):
    v = quiet_voice(tmp_path)
    with pytest.raises(RuntimeError, match="Settings"):
        v.start_listening()
    assert v.status()["engine"] in ("windows", "none")


def test_replies_and_questions_are_spoken_and_stop_silences(home, monkeypatch):
    monkeypatch.delenv("COMPII_SMTP_HOST", raising=False)
    voice = quiet_voice(home["workspace"])
    brain = RehearsalBrain(home["downloads"], home["workspace"])
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="tok", voice=voice)
    app.state.agent.toolbox._open = lambda _t: None
    h = {"X-Compii-Token": "tok"}
    with TestClient(app) as client, client.websocket_connect("/events?t=tok") as ws:
        client.post("/tasks", json={"request": "invoices"}, headers=h)
        while True:
            e = ws.receive_json()
            if e["type"] == "approval_needed":
                client.post(f"/approvals/{e['approval_id']}", json={"approved": True}, headers=h)
            if e["type"] == "task_finished":
                break
        assert any(s.startswith("I need your okay") for s in voice._speaker.said)
        assert "spreadsheet is ready" in voice._speaker.said[-1]
        client.post("/stop", headers=h)
        assert voice._speaker.stops >= 1
        client.put("/voice/settings", json={"speak_replies": False}, headers=h)
        assert client.get("/voice", headers=h).json()["settings"]["speak_replies"] is False


# ---- hands: apps and the browser ---------------------------------------------------

from compii_core.screen import Found, ScreenError, keys_to_sendkeys  # noqa: E402


class FakeScreen:
    def __init__(self) -> None:
        self.log: list[str] = []

    def click(self, target, window=None, before=None):
        f = Found(target, "ButtonControl", window or "Report - Word", 10, 20, 60, 40)
        if before:
            before(f)
        self.log.append(f"click {target}")
        return f

    def type_text(self, text, target=None, window=None, before=None):
        f = Found(target or "", "EditControl", "Notepad", 0, 0, 100, 20) if target else None
        if f and before:
            before(f)
        self.log.append(f"type {text}")
        return f

    def read_window(self, window=None):
        raise ScreenError("No open window has “Paint” in its title.")


class FakeBrowser:
    def __init__(self) -> None:
        self.log: list[str] = []

    def fill(self, field, value, submit=False):
        self.log.append(f"fill {field}={value} submit={submit}")
        return "Filled."


def test_click_points_first_then_acts(toolbox):
    screen = FakeScreen()
    toolbox.screen = screen
    order: list[str] = []
    toolbox.on_point = lambda p: order.append(f"point {p['name']}")
    screen.log = order
    out = toolbox.execute("click_on", {"target": "Save"})
    assert order == ["point Save", "click Save"]
    assert "Save" in out.text


def test_secrets_are_never_typed(toolbox):
    toolbox.screen = FakeScreen()
    toolbox._browser = FakeBrowser()
    for name, args in [("type_into", {"text": "hunter2", "target": "Password"}),
                       ("browser_fill", {"field": "Card number", "value": "4111 1111 1111 1111"})]:
        with pytest.raises(ToolError, match="password, payment detail or one-time code"):
            toolbox.execute(name, args)
    assert toolbox._browser.log == [] and toolbox.screen.log == []


def test_submitting_a_web_form_counts_as_sending(toolbox):
    tool = toolbox.tools["browser_fill"]
    assert tool.kind_for({"field": "Search", "value": "x"}) is ActionKind.CHANGE
    assert tool.kind_for({"field": "Message", "value": "hi", "submit": True}) is ActionKind.SEND
    assert Policy().needs_approval(ActionKind.SEND, {ActionKind.SEND})


def test_screen_problems_are_recoverable_errors(toolbox):
    toolbox.screen = FakeScreen()
    with pytest.raises(ToolError, match="Paint"):
        toolbox.execute("read_window", {"window": "Paint"})


def test_shortcut_names_translate():
    assert keys_to_sendkeys("ctrl+s") == "{Ctrl}s"
    assert keys_to_sendkeys("Alt + F4") == "{Alt}{F4}"
    with pytest.raises(ScreenError):
        keys_to_sendkeys("hyper+x")


# ---- thinking ahead: routines, watches, brief -------------------------------------------

import datetime as dt  # noqa: E402
import time  # noqa: E402

from compii_core import proactive as pro  # noqa: E402


def test_schedules_compute_the_next_run():
    wed_9 = dt.datetime(2026, 10, 14, 9, 0)  # a Wednesday
    assert pro.next_run({"kind": "daily", "at": "08:00"}, wed_9) == dt.datetime(2026, 10, 15, 8, 0)
    assert pro.next_run({"kind": "weekdays", "at": "08:00"}, dt.datetime(2026, 10, 16, 9, 0)) == dt.datetime(2026, 10, 19, 8, 0)
    assert pro.next_run({"kind": "weekly", "days": ["mon", "thu"], "at": "18:00"}, wed_9) == dt.datetime(2026, 10, 15, 18, 0)
    assert pro.next_run({"kind": "every", "minutes": 90}, wed_9) == dt.datetime(2026, 10, 14, 10, 30)
    assert pro.next_run({"kind": "once", "date": "2026-10-01", "at": "09:00"}, wed_9) is None
    assert pro.describe({"kind": "weekdays", "at": "08:00"}) == "Every weekday at 08:00"
    with pytest.raises(ValueError):
        pro.validate_schedule({"kind": "every", "minutes": 1})


def test_folder_watch_reports_only_new_files(home):
    w = pro.Watch("Invoices", "folder", {"folder": str(home["downloads"]), "pattern": "*invoice*"}, 1)
    resolve = Path
    assert pro.check_folder(w, resolve) == []  # first look records what is there
    (home["downloads"] / "invoice-oct.pdf").write_bytes(b"x")
    (home["downloads"] / "cat.jpg").write_bytes(b"x")
    assert pro.check_folder(w, resolve) == ["invoice-oct.pdf"]
    assert pro.check_folder(w, resolve) == []


def test_web_watch_fires_when_text_appears():
    pages = iter(["Sold out", "Sold out", "Back in stock now", "Back in stock now"])
    w = pro.Watch("Lamp", "web", {"url": "https://shop.example/lamp", "contains": "in stock"}, 15)
    results = [pro.check_web(w, fetch=lambda _u: next(pages)) for _ in range(4)]
    assert results == [None, None, "The page now says “in stock”.", None]


def test_brief_summarises_what_matters(home, tmp_path):
    plans = pro.Proactive(tmp_path / "p.json")
    plans.post(pro.Update("watch", "Invoices", "New: invoice-oct.pdf"))
    now = dt.datetime.now().replace(hour=8, minute=0)
    plans.add_routine("Tidy Downloads", "Tidy my Downloads", {"kind": "daily", "at": "23:30"})

    class T:  # minimal task stand-in
        def __init__(self, status, request, at):
            self.status, self.request, self.events = status, request, [{"at": at}]

    tasks = [T("waiting", "Email the report", time.time()), T("done", "Make the spreadsheet", time.time())]
    brief = pro.compose_brief(tasks=tasks, proactive=plans, downloads=home["downloads"], now=now)
    titles = [s["title"] for s in brief.sections]
    assert titles[:3] == ["Needs you", "Done since yesterday", "Your watches caught"]
    assert "1 thing needs you" in brief.body and "Good morning" in brief.body


async def test_routine_runs_on_time_and_posts_its_result(home, monkeypatch):
    brain = ScriptBrain([], final="Downloads tidied: 3 files sorted.")
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]))
    plans = app.state.plans
    plans.brief["enabled"] = False
    r = plans.add_routine("Tidy", "Tidy my Downloads", {"kind": "daily", "at": "07:00"})
    r.next_run = (dt.datetime.now() - dt.timedelta(minutes=1)).replace(second=0, microsecond=0).isoformat()
    await app.state.tick()
    task = next(t for t in app.state.agent.tasks.values() if (t.origin or {}).get("routine") == r.id)
    await asyncio.wait_for(task.runner, 5)
    assert plans.inbox[-1].kind == "routine" and "tidied" in plans.inbox[-1].body
    assert dt.datetime.fromisoformat(plans.routines[r.id].next_run) > dt.datetime.now()


async def test_ai_watch_only_reports_a_yes(home):
    for answer, expect in [("NO: nothing new", 0), ("YES: the price dropped to £40", 1)]:
        app = build_app(brain=ScriptBrain([], final=answer), workspace=home["workspace"] / answer[:2],
                        roots=[home["downloads"]], token="tok", voice=quiet_voice(home["workspace"]))
        plans = app.state.plans
        plans.brief["enabled"] = False
        plans.add_watch("Lamp price", "ai", {"check": "the lamp price", "notify_when": "under £45"})
        await app.state.tick()
        task = next(iter(app.state.agent.tasks.values()))
        await asyncio.wait_for(task.runner, 5)
        await asyncio.sleep(0)
        watch_updates = [u for u in plans.inbox if u.kind == "watch"]
        assert len(watch_updates) == expect
        if expect:
            assert watch_updates[0].body == "the price dropped to £40"


def test_creating_a_routine_needs_approval_like_any_standing_change(home):
    app = build_app(brain=ScriptBrain([]), workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]))
    tool = app.state.agent.toolbox.tools["create_routine"]
    assert tool.kind_for({}) is ActionKind.CHANGE
    out = tool.run({"title": "Brief", "instruction": "Summarise my day", "schedule": {"kind": "weekdays", "at": "08:30"}})
    assert "Every weekday at 08:30" in out.text


def test_folder_watches_stay_inside_allowed_folders(home):
    app = build_app(brain=ScriptBrain([]), workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]))
    home["outside"].mkdir()
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        bad = client.post("/watches", json={"title": "x", "kind": "folder", "spec": {"folder": str(home["outside"])}}, headers=h)
        assert bad.status_code == 403
        ok = client.post("/watches", json={"title": "Invoices", "kind": "folder", "spec": {"folder": str(home["downloads"]), "pattern": "*invoice*"}}, headers=h)
        assert ok.status_code == 200 and ok.json()["watches"][0]["title"] == "Invoices"


def test_run_now_starts_the_routine(home):
    app = build_app(brain=ScriptBrain([], final="Done."), workspace=home["workspace"], roots=[home["downloads"]],
                    token="tok", voice=quiet_voice(home["workspace"]))
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        rid = client.post("/routines", json={"title": "Tidy", "instruction": "Tidy", "schedule": {"kind": "daily", "at": "07:00"}},
                          headers=h).json()["routines"][0]["id"]
        r = client.post(f"/routines/{rid}/run", headers=h)
        assert r.status_code == 200 and r.json()["origin"]["routine"] == rid


# ---- hands-free -------------------------------------------------------------------------


def test_voice_choices_survive_a_restart(home):
    h = {"X-Compii-Token": "tok"}
    app = build_app(brain=ScriptBrain([]), workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]))
    with TestClient(app) as client:
        client.put("/voice/settings", json={"speak_replies": False, "engine": "windows"}, headers=h)
    again = build_app(brain=ScriptBrain([]), workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                      voice=quiet_voice(home["workspace"]))
    with TestClient(again) as client:
        settings = client.get("/voice", headers=h).json()["settings"]
    assert settings["speak_replies"] is False and settings["engine"] == "windows"


def test_hands_free_request_reaches_the_app(home):
    voice = quiet_voice(home["workspace"])
    app = build_app(brain=ScriptBrain([]), workspace=home["workspace"], roots=[home["downloads"]], token="tok", voice=voice)
    with TestClient(app) as client, client.websocket_connect("/events?t=tok") as ws:
        voice.on_command("tidy my downloads")
        e = ws.receive_json()
        while e["type"] != "voice_command":
            e = ws.receive_json()
        assert e["text"] == "tidy my downloads"


def test_hands_free_needs_speech_recognition_first(home):
    app = build_app(brain=ScriptBrain([]), workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]))
    with TestClient(app) as client:
        r = client.put("/voice/settings", json={"wake_word": True}, headers={"X-Compii-Token": "tok"})
        assert r.status_code == 409 and "Download speech recognition" in r.json()["detail"]


def test_damaged_or_bom_settings_never_stop_core(tmp_path):
    bom = tmp_path / "a.json"
    bom.write_text('﻿{"brief": {"enabled": false, "at": "07:00", "last": null}}', encoding="utf-8")
    assert pro.Proactive(bom).brief["at"] == "07:00"
    broken = tmp_path / "b.json"
    broken.write_text("{not json", encoding="utf-8")
    plans = pro.Proactive(broken)
    assert plans.routines == {} and any(p.name.startswith("b.broken-") for p in tmp_path.iterdir())

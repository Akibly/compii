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
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token="tok")
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

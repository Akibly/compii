"""Supervisor: delegated jobs, review verdicts, the trust ladder and hiring."""

import asyncio
import re

from fastapi.testclient import TestClient

from compii_core.agent import Agent, BrainReply, ToolCall
from compii_core.bots import Bots
from compii_core.journal import Journal
from compii_core.keys import MemoryKeyStore
from compii_core.policy import Policy
from compii_core.server import build_app
from compii_core.supervise import Supervisor

from test_core import home, opened, quiet_voice, toolbox  # noqa: F401 - fixtures


def _agent(toolbox, tmp_path, brain, roster):
    agent = Agent(brain, toolbox, Policy(), Journal(tmp_path / "journal.jsonl"),
                  lambda e: asyncio.sleep(0))
    agent.roster = lambda: roster
    return agent


def _worker(bot_id="bworker"):
    return {"id": bot_id, "name": "Analyst", "job": "Reads numbers out of files", "primary": False,
            "trust": "probation", "stats": {}, "working": []}


def _compii():
    return {"id": "bmain", "name": "Compii", "job": "", "primary": True, "trust": "full",
            "stats": {}, "working": []}


class SupervisorBrain:
    """Compii delegates; the teammate does the job; Compii reviews it."""

    def __init__(self, report: str, verdict: str = "accept", note: str = "Checked the file."):
        self.report = report
        self.verdict = verdict
        self.note = note

    @staticmethod
    def _job(messages) -> str:
        for m in reversed(messages):
            if m["role"] != "user":
                continue
            for block in m["content"] if isinstance(m["content"], list) else []:
                found = re.search(r"Job (j[0-9a-f]{8})\.", str(block.get("content", "")))
                if found:
                    return found.group(1)
        return ""

    async def step(self, system, messages, tools):
        assistant = sum(1 for m in messages if m["role"] == "assistant")
        if "This is one job handed to you" in system:
            if assistant == 0:
                return BrainReply([{"type": "tool_use", "id": "w0", "name": "read_file",
                                    "input": {"path": self.report.split("||")[0]}}], "",
                                  [ToolCall("w0", "read_file", {"path": self.report.split("||")[0]})], "tool_use")
            if assistant == 1:
                path, body = self.report.split("||")
                return BrainReply([{"type": "tool_use", "id": "w1", "name": "write_text_file",
                                    "input": {"path": path + ".summary.md", "content": body}}], "",
                                  [ToolCall("w1", "write_text_file", {"path": path + ".summary.md", "content": body})],
                                  "tool_use")
            return BrainReply([{"type": "text", "text": "Read the file and saved the summary."}],
                              "Read the file and saved the summary.", [], "end_turn")
        if assistant == 0:
            return BrainReply([{"type": "tool_use", "id": "d0", "name": "delegate", "input": {
                "bot": "Analyst", "objective": "Summarise the invoice",
                "done_when": "a summary file exists next to it", "context": "It is in Downloads."}}], "",
                [ToolCall("d0", "delegate", {"bot": "Analyst", "objective": "Summarise the invoice",
                                             "done_when": "a summary file exists next to it",
                                             "context": "It is in Downloads."})], "tool_use")
        if assistant == 1:
            job = self._job(messages)
            return BrainReply([{"type": "tool_use", "id": "r0", "name": "review_work", "input": {
                "job": job, "verdict": self.verdict, "note": self.note}}], "",
                [ToolCall("r0", "review_work", {"job": job, "verdict": self.verdict, "note": self.note})],
                "tool_use")
        return BrainReply([{"type": "text", "text": "Checked and done."}], "Checked and done.", [], "end_turn")


def test_the_books_records_a_job_and_its_track_record(home):
    book = Supervisor(home["workspace"] / "team.json")
    job = book.open_job(parent_task="t1", child_task="t2", bot_id="b1", bot_name="Analyst",
                        objective="Summarise the invoice", done_when="summary exists", budget_min=5)
    book.finish_job(job.id, "done", "Done, saved summary.md", actions=2, files=["C:/x/summary.md"])
    book.review_job(job.id, "accept", "Checked the file.")
    stats = book.stats("b1")
    assert stats == {"jobs": 1, "done": 1, "failed": 0, "running": 0, "accepted": 1, "rejected": 0,
                     "success": 100, "last_review": "Checked the file.", "last_verdict": "accepted"}
    again = Supervisor(home["workspace"] / "team.json")
    assert again.job(job.id).result.startswith("Done, saved")
    assert again.stats("b1")["success"] == 100


def test_restarting_closes_a_job_whose_waiter_died(home):
    book = Supervisor(home["workspace"] / "team.json")
    job = book.open_job(parent_task="t1", child_task="t2", bot_id="b1", bot_name="Analyst",
                        objective="x", done_when="y")
    again = Supervisor(home["workspace"] / "team.json")
    assert again.job(job.id).status == "stopped"


def test_a_delegated_job_runs_in_its_own_thread_and_is_reviewed(tmp_path, home, toolbox):
    book = Supervisor(tmp_path / "team.json")
    agent = _agent(toolbox, tmp_path, SupervisorBrain(str(home["downloads"] / "invoice-sept-01.pdf") + "||total 42"),
                   [_compii(), _worker()])
    agent.on_job_open = lambda **kw: book.open_job(**kw).view()
    agent.on_job_done = lambda job_id, status, result, **kw: book.finish_job(job_id, status, result, **kw)
    agent.on_job_review = lambda job_id, verdict, note: (
        lambda j: {"job": j.view(), "stats": book.stats(j.bot_id)} if j else {"job": None}
    )(book.review_job(job_id, verdict, note))

    async def go():
        task = agent.start("Ask Analyst to summarise the invoice")
        await asyncio.wait_for(task.runner, 20)
        return task

    task = asyncio.run(go())
    child = next(t for t in agent.tasks.values() if t.parent_id == task.id)
    assert child.bot_id == "bworker" and child.probation and child.supervised
    assert child.max_steps == 16
    assert child.status == "done"
    assert (home["downloads"] / "invoice-sept-01.pdf.summary.md").exists()
    assert any(e["type"] == "delegation" and e["child_task"] == child.id for e in task.events)
    assert any(e["type"] == "delegation_done" and e["status"] == "done" for e in task.events)
    job = next(iter(book.jobs.values()))
    assert job.child_task == child.id and job.bot_id == "bworker"
    assert job.status == "done" and job.verdict == "accepted" and job.actions >= 2
    assert book.stats("bworker")["success"] == 100
    assert task.status == "done" and "Checked and done." in task.events[-1]["text"]


def test_probation_refuses_deleting_and_review_can_send_it_back(tmp_path, home, toolbox):
    book = Supervisor(tmp_path / "team.json")
    brain = SupervisorBrain(str(home["downloads"] / "invoice-sept-01.pdf") + "||ignored",
                            verdict="send_back", note="The summary is missing.")
    agent = _agent(toolbox, tmp_path, brain, [_compii(), _worker()])
    agent.on_job_open = lambda **kw: book.open_job(**kw).view()
    agent.on_job_done = lambda job_id, status, result, **kw: book.finish_job(job_id, status, result, **kw)
    agent.on_job_review = lambda job_id, verdict, note: (
        lambda j: {"job": j.view(), "stats": book.stats(j.bot_id)} if j else {"job": None}
    )(book.review_job(job_id, verdict, note))

    # The worker tries a DELETE instead of doing its job.
    class DeleteBrain(SupervisorBrain):
        async def step(self, system, messages, tools):
            if "This is one job handed to you" in system:
                if not any(m["role"] == "assistant" for m in messages):
                    args = {"path": str(home["downloads"] / "invoice-sept-01.pdf")}
                    return BrainReply([{"type": "tool_use", "id": "x", "name": "move_to_trash", "input": args}], "",
                                      [ToolCall("x", "move_to_trash", args)], "tool_use")
                return BrainReply([{"type": "text", "text": "I could not clear it."}],
                                  "I could not clear it.", [], "end_turn")
            return await super().step(system, messages, tools)

    agent.brain = DeleteBrain(str(home["downloads"] / "invoice-sept-01.pdf") + "||x", verdict="send_back",
                              note="The summary is missing.")

    async def go():
        task = agent.start("Ask Analyst to summarise the invoice")
        await asyncio.wait_for(task.runner, 20)
        return task

    task = asyncio.run(go())
    child = next(t for t in agent.tasks.values() if t.parent_id == task.id)
    blocked = [b.get("content", "") for m in child.messages if m["role"] == "user"
               for b in (m["content"] if isinstance(m["content"], list) else [])
               if "on probation" in str(b.get("content", ""))]
    assert blocked and "delete actions are off" in blocked[0]
    assert (home["downloads"] / "invoice-sept-01.pdf").exists()  # never touched
    job = next(iter(book.jobs.values()))
    assert job.verdict == "rejected" and book.stats("bworker")["success"] == 0


def test_hiring_waits_for_the_user_and_creates_the_teammate_they_named(tmp_path, home, toolbox):
    book = Supervisor(tmp_path / "team.json")
    bots = Bots(home["workspace"] / "bots.json")

    class HireBrain:
        async def step(self, system, messages, tools):
            assistant = sum(1 for m in messages if m["role"] == "assistant")
            if assistant == 0:
                args = {"name": "Ledger", "job": "Keeps invoices filed", "why": "Invoices keep piling up.",
                        "first_task": "File this month's invoices"}
                return BrainReply([{"type": "tool_use", "id": "h0", "name": "propose_teammate", "input": args}], "",
                                  [ToolCall("h0", "propose_teammate", args)], "tool_use")
            return BrainReply([{"type": "text", "text": "Hired and ready."}], "Hired and ready.", [], "end_turn")

    agent = _agent(toolbox, tmp_path, HireBrain(), [_compii()])
    agent.on_proposal = lambda **kw: book.propose(**kw).view()

    async def answer():
        while not agent.hire_requests:
            await asyncio.sleep(0.01)
        pid = next(iter(agent.hire_requests))
        made = bots.create("Ledger", job="Keeps invoices filed and paid on time")
        agent.resolve_hire(pid, made.view())
        book.resolve_proposal(pid, "hired", bot_id=made.id)
        return pid

    async def go():
        waiter = asyncio.create_task(answer())
        task = agent.start("We need someone for the invoices")
        await asyncio.wait_for(task.runner, 20)
        return task, await waiter

    task, pid = asyncio.run(go())
    assert task.status == "done"
    assert any(e["type"] == "hiring" and e["proposal"]["id"] == pid for e in task.events)
    assert any(e["type"] == "hiring_resolved" and e["status"] == "hired" for e in task.events)
    made = next(b for b in bots.items.values() if b.name == "Ledger")
    assert made.trust == "probation"
    assert "Hired Ledger" in task.events[-1]["text"] or "Hired and ready." in task.events[-1]["text"]


def test_bot_trust_is_persisted_and_compii_always_has_full_trust(home):
    bots = Bots(home["workspace"] / "bots.json")
    primary = bots.primary()
    assert primary.view()["trust"] == "full"
    analyst = bots.create("Analyst", job="Reads files")
    assert analyst.view()["trust"] == "probation"
    bots.update(analyst.id, trust="trusted")
    assert Bots(home["workspace"] / "bots.json").get(analyst.id).trust == "trusted"
    try:
        bots.update(primary.id, trust="trusted")
    except ValueError as e:
        assert "full trust" in str(e)
    else:
        raise AssertionError("Compii's own trust must not be lowered")


def test_the_hire_route_creates_the_teammate_from_the_card(home):
    app = build_app(brain=None, workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))
    prop = app.state.supervisor.propose(name="Ledger", job="Keeps invoices filed", why="Invoices pile up.")
    client = TestClient(app)
    res = client.post(f"/team/hires/{prop.id}", json={"name": "Ledger", "job": "Files invoices"}, headers={"X-Compii-Token": "tok"})
    assert res.status_code == 200, res.text
    made = res.json()["hired"]
    assert made["name"] == "Ledger" and made["trust"] == "probation"
    team = client.get("/team", headers={"X-Compii-Token": "tok"}).json()
    assert any(b["name"] == "Ledger" and b["stats"]["jobs"] == 0 for b in team["roster"])
    assert app.state.supervisor.proposal(prop.id).status == "hired"


def test_asked_for_a_teammate_from_the_buddy_compii_is_given_the_hiring_tool(tmp_path, home, toolbox):
    """The card is the only way a teammate gets made, so the tool that files it has to be in front
    of the model when the user asks for one - even from the cursor buddy's slim tool set."""
    seen: list[list[str]] = []

    class Watch:
        async def step(self, system, messages, tools):
            seen.append([t["name"] for t in tools])
            return BrainReply([{"type": "text", "text": "On it."}], "On it.", [], "end_turn")

    agent = _agent(toolbox, tmp_path, Watch(), [_compii()])
    async def go():
        task = agent.start("create a new teammate who files my invoices", origin={"buddy": True})
        await asyncio.wait_for(task.runner, 10)

    asyncio.run(go())
    assert "propose_teammate" in seen[0], seen[0]


def test_compii_says_who_can_make_a_teammate(home):
    """A user asking for a teammate has to be answered with the tool call, not with a promise:
    Compii's own role text is where that instruction lives."""
    from compii_core.bots import Bots

    primary = Bots(home["workspace"] / "bots.json").primary()
    assert primary is not None
    prompt = primary.prompt()
    assert "propose_teammate" in prompt and "hiring card" in prompt

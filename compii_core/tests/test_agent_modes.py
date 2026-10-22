"""Agentic modes: separate lanes, peer delegation, and the guards around them."""

import asyncio
import re

from compii_core.agent import MAX_DELEGATION_DEPTH, Agent, BrainReply, ToolCall
from compii_core.bots import TEMPLATES, packs_view, tools_for
from compii_core.journal import Journal
from compii_core.policy import Policy
from compii_core.supervise import Supervisor

from test_core import home, opened, quiet_voice, toolbox  # noqa: F401 - fixtures


def _job_id(messages) -> str:
    for m in reversed(messages):
        if m["role"] != "user":
            continue
        blocks = m["content"] if isinstance(m["content"], list) else []
        for block in blocks:
            found = re.search(r"Job (j[0-9a-f]{8})\.", str(block.get("content", "")))
            if found:
                return found.group(1)
    return ""


def _results(messages) -> list[str]:
    out = []
    for m in messages:
        if m["role"] != "user":
            continue
        for block in (m["content"] if isinstance(m["content"], list) else []):
            if isinstance(block, dict) and block.get("type") == "tool_result":
                out.append(str(block.get("content", "")))
    return out


class SpyBrain:
    """Plays tool calls and records which tools each teammate was offered."""

    def __init__(self, calls, final="Done."):
        self.calls = calls
        self.final = final
        self.tool_names: list[set[str]] = []
        self.systems: list[str] = []

    async def step(self, system, messages, tools):
        self.systems.append(system)
        self.tool_names.append({t["name"] for t in tools})
        i = sum(1 for m in messages if m["role"] == "assistant")
        if i < len(self.calls):
            name, args = self.calls[i]
            return BrainReply([{"type": "tool_use", "id": f"c{i}", "name": name, "input": args}], "",
                              [ToolCall(f"c{i}", name, args)], "tool_use")
        return BrainReply([{"type": "text", "text": self.final}], self.final, [], "end_turn")


class TeamBrain:
    """A tiny team: the parent delegates, the worker reports, the parent reviews."""

    def __init__(self, verdict="accept", note="Checked it."):
        self.verdict = verdict
        self.note = note

    async def step(self, system, messages, tools):
        assistant = sum(1 for m in messages if m["role"] == "assistant")
        if "This is one job handed to you" in system:
            return BrainReply([{"type": "text", "text": "Finished the job."}], "Finished the job.", [], "end_turn")
        if assistant == 0:
            args = {"bot": "Analyst", "objective": "Summarise the invoice",
                    "done_when": "a summary exists next to it"}
            return BrainReply([{"type": "tool_use", "id": "d0", "name": "delegate", "input": args}], "",
                              [ToolCall("d0", "delegate", args)], "tool_use")
        if assistant == 1:
            job = _job_id(messages)
            args = {"job": job, "verdict": self.verdict, "note": self.note}
            return BrainReply([{"type": "tool_use", "id": "r0", "name": "review_work", "input": args}], "",
                              [ToolCall("r0", "review_work", args)], "tool_use")
        return BrainReply([{"type": "text", "text": "All done."}], "All done.", [], "end_turn")


class ResumeBrain(TeamBrain):
    """Delegate, send it back once, then resume and accept the fix."""

    async def step(self, system, messages, tools):
        if "This is one job handed to you" in system:
            return await super().step(system, messages, tools)
        assistant = sum(1 for m in messages if m["role"] == "assistant")
        if assistant == 0:
            args = {"bot": "Analyst", "objective": "Summarise the invoice",
                    "done_when": "a summary exists next to it"}
            return BrainReply([{"type": "tool_use", "id": "d0", "name": "delegate", "input": args}], "",
                              [ToolCall("d0", "delegate", args)], "tool_use")
        job = _job_id(messages)
        if assistant == 1:
            args = {"job": job, "verdict": "send_back", "note": "The summary is missing."}
            return BrainReply([{"type": "tool_use", "id": "r0", "name": "review_work", "input": args}], "",
                              [ToolCall("r0", "review_work", args)], "tool_use")
        if assistant == 2:
            args = {"job": job, "note": "Write the summary file this time."}
            return BrainReply([{"type": "tool_use", "id": "s0", "name": "resume_work", "input": args}], "",
                              [ToolCall("s0", "resume_work", args)], "tool_use")
        if assistant == 3:
            args = {"job": job, "verdict": "accept", "note": "Now it landed."}
            return BrainReply([{"type": "tool_use", "id": "r1", "name": "review_work", "input": args}], "",
                              [ToolCall("r1", "review_work", args)], "tool_use")
        return BrainReply([{"type": "text", "text": "Fixed and checked."}], "Fixed and checked.", [], "end_turn")


class PeerBrain:
    """Boss delegates down; Analyst tries a loop, then hands further; Clerk tries to go deeper."""

    async def step(self, system, messages, tools):
        assistant = sum(1 for m in messages if m["role"] == "assistant")

        def hand(bot, tag):
            args = {"bot": bot, "objective": f"Step {tag}", "done_when": "the report lands"}
            return BrainReply([{"type": "tool_use", "id": tag, "name": "delegate", "input": args}], "",
                              [ToolCall(tag, "delegate", args)], "tool_use")

        if "You are Clerk" in system:
            if assistant == 0:
                return hand("Analyst", "c0")
            return BrainReply([{"type": "text", "text": "Clerk done."}], "Clerk done.", [], "end_turn")
        if "You are Analyst" in system:
            if assistant == 0:
                return hand("Boss", "a0")
            if assistant == 1:
                return hand("Clerk", "a1")
            return BrainReply([{"type": "text", "text": "Analyst done."}], "Analyst done.", [], "end_turn")
        if assistant == 0:
            return hand("Analyst", "b0")
        return BrainReply([{"type": "text", "text": "Boss done."}], "Boss done.", [], "end_turn")


def _bot(bot_id, name, *, job="", mode="team", trust="trusted", tools=None, primary=False):
    return {"id": bot_id, "name": name, "job": job, "primary": primary, "trust": trust,
            "mode": "lead" if primary else mode, "tools": list(tools or []),
            "stats": {}, "working": []}


def _agent(toolbox, tmp_path, brain, roster):
    agent = Agent(brain, toolbox, Policy(), Journal(tmp_path / "journal.jsonl"), lambda e: asyncio.sleep(0))
    agent.roster = lambda: roster
    agent.bot_info = lambda bid: next((b for b in roster if b["id"] == bid), None)
    agent.bot_context = lambda bid: f"You are {next(b['name'] for b in roster if b['id'] == bid)}."
    return agent


def _wire(agent, tmp_path):
    book = Supervisor(tmp_path / "team.json")
    agent.on_job_open = lambda **kw: book.open_job(**kw).view()
    agent.on_job_done = lambda job_id, status, result, **kw: book.finish_job(job_id, status, result, **kw)
    agent.on_job_review = lambda job_id, verdict, note: (
        lambda j: {"job": j.view(), "stats": book.stats(j.bot_id)} if j else {"job": None}
    )(book.review_job(job_id, verdict, note))
    agent.on_job_reopen = lambda job_id: (
        lambda j: {"job": j.view(), "stats": book.stats(j.bot_id)} if j else {"job": None}
    )(book.reopen_job(job_id))
    agent.on_job_info = lambda job_id: (job.view() if (job := book.job(job_id)) else None)
    return book


def _run(agent, request, timeout=15, **start):
    async def go():
        task = agent.start(request, **start)
        await asyncio.wait_for(task.runner, timeout)
        return task

    return asyncio.run(go())


def test_a_lane_offers_only_its_packs_and_refuses_the_rest(tmp_path, home, toolbox):
    brain = SpyBrain([("read_file", {"path": str(home["downloads"] / "invoice-sept-01.pdf")})], final="Couldn't.")
    roster = [_bot("bmail", "Inbox", mode="team", tools=["mail"])]
    agent = _agent(toolbox, tmp_path, brain, roster)

    task = _run(agent, "Check my mail", bot_id="bmail")

    assert "send_email" in brain.tool_names[0]
    assert "read_file" not in brain.tool_names[0]
    assert any("outside their lane" in r for r in _results(task.messages))
    assert task.status == "done"


def test_a_solo_bot_never_delegates(tmp_path, home, toolbox):
    brain = SpyBrain([("delegate", {"bot": "Analyst", "objective": "x", "done_when": "y"})], final="Myself.")
    roster = [_bot("bsolo", "Loner", mode="solo"), _bot("banalyst", "Analyst")]
    agent = _agent(toolbox, tmp_path, brain, roster)

    task = _run(agent, "Do this", bot_id="bsolo")

    assert "delegate" not in brain.tool_names[0]
    assert any("work alone" in r for r in _results(task.messages))
    assert len(agent.tasks) == 1


def test_a_team_player_delegates_to_a_peer_and_reviews_it(tmp_path, home, toolbox):
    brain = TeamBrain()
    roster = [_bot("bboss", "Boss"), _bot("banalyst", "Analyst", job="Reads invoices")]
    agent = _agent(toolbox, tmp_path, brain, roster)
    book = _wire(agent, tmp_path)

    task = _run(agent, "Summarise the invoice", bot_id="bboss")

    child = next(t for t in agent.tasks.values() if t.parent_id == task.id)
    assert child.bot_id == "banalyst"
    assert child.supervised and child.supervised["objective"] == "Summarise the invoice"
    assert child.depth == 1 and child.ancestry == ["bboss", "banalyst"]
    job = next(iter(book.jobs.values()))
    assert job.parent_task == task.id and job.status == "done" and job.verdict == "accepted"
    assert task.status == "done"


def test_work_cannot_circle_back_or_run_deeper_than_two_hops(tmp_path, home, toolbox):
    roster = [_bot("bboss", "Boss"), _bot("banalyst", "Analyst"), _bot("bclerk", "Clerk")]
    agent = _agent(toolbox, tmp_path, PeerBrain(), roster)
    book = _wire(agent, tmp_path)

    _run(agent, "Handle this", bot_id="bboss")

    analyst = next(t for t in agent.tasks.values() if t.bot_id == "banalyst")
    clerk = next(t for t in agent.tasks.values() if t.bot_id == "bclerk")
    assert analyst.depth == 1 and clerk.depth == 2
    assert clerk.ancestry == ["bboss", "banalyst", "bclerk"]
    assert any("circle" in r for r in _results(analyst.messages))
    assert any("two levels deep" in r for r in _results(clerk.messages))
    assert not [t for t in agent.tasks.values() if t.parent_id == clerk.id]
    assert MAX_DELEGATION_DEPTH == 2
    assert all(j.status == "done" for j in book.jobs.values())


def test_delegate_many_runs_independent_jobs_in_parallel(tmp_path, home, toolbox):
    class ManyBrain:
        async def step(self, system, messages, tools):
            if "This is one job handed to you" in system:
                return BrainReply([{"type": "text", "text": "Part done."}], "Part done.", [], "end_turn")
            assistant = sum(1 for m in messages if m["role"] == "assistant")
            if assistant == 0:
                jobs = [
                    {"bot": "Analyst", "objective": "Check the numbers", "done_when": "numbers checked"},
                    {"bot": "Clerk", "objective": "File the invoice", "done_when": "file is filed"},
                ]
                return BrainReply([{"type": "tool_use", "id": "m0", "name": "delegate_many",
                                    "input": {"jobs": jobs}}], "",
                                  [ToolCall("m0", "delegate_many", {"jobs": jobs})], "tool_use")
            return BrainReply([{"type": "text", "text": "Both done."}], "Both done.", [], "end_turn")

    roster = [_bot("bmain", "Compii", primary=True),
              _bot("banalyst", "Analyst"), _bot("bclerk", "Clerk")]
    agent = _agent(toolbox, tmp_path, ManyBrain(), roster)
    book = _wire(agent, tmp_path)

    task = _run(agent, "Do both")

    assert len(book.jobs) == 2
    starts = [e for e in task.events if e["type"] == "delegation"]
    assert len(starts) == 2 and all(e.get("parallel") for e in starts)
    assert all(j.status == "done" for j in book.jobs.values())
    children = [t for t in agent.tasks.values() if t.parent_id == task.id]
    assert {c.bot_id for c in children} == {"banalyst", "bclerk"}


def test_probation_follows_the_job_even_to_a_trusted_peer(tmp_path, home, toolbox):
    brain = TeamBrain()
    roster = [_bot("bprob", "Newbie", mode="team", trust="probation"),
              _bot("banalyst", "Analyst", trust="trusted")]
    agent = _agent(toolbox, tmp_path, brain, roster)
    _wire(agent, tmp_path)

    task = _run(agent, "Summarise the invoice", bot_id="bprob")

    child = next(t for t in agent.tasks.values() if t.parent_id == task.id)
    assert task.probation
    assert child.bot_id == "banalyst" and child.probation


def test_a_sent_back_job_resumes_in_the_same_thread_and_counts_attempts(tmp_path, home, toolbox):
    brain = ResumeBrain()
    roster = [_bot("bmain", "Compii", primary=True),
              _bot("banalyst", "Analyst", job="Reads invoices")]
    agent = _agent(toolbox, tmp_path, brain, roster)
    book = _wire(agent, tmp_path)

    task = _run(agent, "Summarise the invoice")

    job = next(iter(book.jobs.values()))
    assert job.attempts == 2
    assert job.verdict == "accepted"
    assert job.status == "done"
    child = next(t for t in agent.tasks.values() if t.parent_id == task.id)
    assert child.status == "done"
    resumed = [e for e in task.events if e["type"] == "delegation_resumed"]
    assert len(resumed) == 1 and resumed[0]["attempt"] == 2
    assert any("Write the summary file this time." in str(m["content"]) for m in child.messages
               if m["role"] == "user")


def test_only_the_bot_that_delegated_can_review_the_job(tmp_path, home, toolbox):
    class ForeignReviewBrain:
        """Delegates one job, then tries to review a different thread's job."""

        foreign = ""

        async def step(self, system, messages, tools):
            if "This is one job handed to you" in system:
                return BrainReply([{"type": "text", "text": "Done."}], "Done.", [], "end_turn")
            assistant = sum(1 for m in messages if m["role"] == "assistant")
            if assistant == 0:
                args = {"bot": "Analyst", "objective": "Summarise the invoice",
                        "done_when": "a summary exists next to it"}
                return BrainReply([{"type": "tool_use", "id": "d0", "name": "delegate", "input": args}], "",
                                  [ToolCall("d0", "delegate", args)], "tool_use")
            if assistant == 1:
                args = {"job": self.foreign, "verdict": "accept", "note": ""}
                return BrainReply([{"type": "tool_use", "id": "r0", "name": "review_work", "input": args}], "",
                                  [ToolCall("r0", "review_work", args)], "tool_use")
            return BrainReply([{"type": "text", "text": "Hm."}], "Hm.", [], "end_turn")

    brain = ForeignReviewBrain()
    roster = [_bot("bboss", "Boss"), _bot("banalyst", "Analyst")]
    agent = _agent(toolbox, tmp_path, brain, roster)
    book = _wire(agent, tmp_path)
    job = book.open_job(parent_task="somebody-else", child_task="t-x", bot_id="banalyst",
                        bot_name="Analyst", objective="x", done_when="y")
    brain.foreign = job.id

    task = _run(agent, "Review it", bot_id="bboss")

    assert any("belongs to another thread" in r for r in _results(task.messages)), _results(task.messages)
    assert job.verdict == ""


def test_templates_ship_with_their_own_mode_and_lane():
    packs = {p["key"] for p in packs_view()}
    by_key = {t["key"]: t for t in TEMPLATES}
    assert by_key["chief"]["mode"] == "lead" and by_key["chief"]["tools"] == []
    assert by_key["coder"]["tools"] == ["code", "files"]
    assert set(by_key["researcher"]["tools"]) <= packs
    assert tools_for(by_key["inbox"]["tools"]) == tools_for(["mail", "schedule", "knowledge"])
    assert "send_email" in tools_for(["mail"])
    assert "read_file" not in tools_for(["mail"])

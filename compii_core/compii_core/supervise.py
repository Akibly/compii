"""The supervisor's book: who did what, how it went, and who is still on probation.

Compii stays the one voice talking to the user. Teammates are specialists it can
hand a self-contained job to, then check against the definition of done before
accepting. This module keeps that record - delegated jobs, verdicts, and the
per-teammate track record the roster shows - and the hiring proposals Compii
offers when no teammate fits.
"""

from __future__ import annotations

import json
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

MAX_JOBS = 300
MAX_RESULT = 6000
TRUST = ("probation", "trusted")


@dataclass
class Job:
    id: str
    parent_task: str
    child_task: str
    bot_id: str
    bot_name: str
    objective: str
    done_when: str
    context: str = ""
    budget_min: int = 8
    status: str = "running"  # running | done | failed | stopped | timeout
    started: float = field(default_factory=time.time)
    ended: float = 0.0
    result: str = ""
    actions: int = 0
    files: list[str] = field(default_factory=list)
    verdict: str = ""  # "" while unreviewed, then accepted | rejected
    review_note: str = ""
    reviewed_at: float = 0.0
    attempts: int = 1  # send_back + resume starts another attempt in the same child thread

    def view(self) -> dict[str, Any]:
        return asdict(self)

    @property
    def seconds(self) -> int:
        end = self.ended or time.time()
        return max(0, round(end - self.started))


@dataclass
class Proposal:
    id: str
    name: str
    job: str
    why: str = ""
    first_task: str = ""
    avatar: str = ""
    created: float = field(default_factory=time.time)
    status: str = "open"  # open | hired | declined | expired
    bot_id: str = ""

    def view(self) -> dict[str, Any]:
        return asdict(self)


def _clean(text: str, limit: int) -> str:
    return " ".join(str(text or "").split())[:limit].strip()


class Supervisor:
    """Delegated jobs and hiring proposals, kept with the workspace."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.RLock()
        self.jobs: dict[str, Job] = {}
        self.proposals: dict[str, Proposal] = {}
        self._load()
        # A proposal is only answerable while the turn that asked is still waiting;
        # after a restart nothing is, so close stale ones rather than showing a dead card.
        changed = False
        for p in self.proposals.values():
            if p.status == "open":
                p.status = "expired"
                changed = True
        # A job's waiter died with the process: it is not running any more.
        for j in self.jobs.values():
            if j.status == "running":
                j.status = "stopped"
                j.ended = j.ended or time.time()
                changed = True
        if changed:
            self.save()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8-sig"))
            for d in data.get("jobs", []):
                job = Job(**{k: v for k, v in d.items() if k in Job.__dataclass_fields__})
                self.jobs[job.id] = job
            for d in data.get("proposals", []):
                prop = Proposal(**{k: v for k, v in d.items() if k in Proposal.__dataclass_fields__})
                self.proposals[prop.id] = prop
        except (OSError, ValueError, TypeError):
            self.path.replace(self.path.with_suffix(f".broken-{int(time.time())}.json"))

    def save(self) -> None:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(
                {"jobs": [j.view() for j in self.jobs.values()],
                 "proposals": [p.view() for p in self.proposals.values()]},
                indent=1, ensure_ascii=False), encoding="utf-8")
            tmp.replace(self.path)

    # ---- delegated jobs ----------------------------------------------------

    def open_job(self, *, parent_task: str, child_task: str, bot_id: str, bot_name: str,
                 objective: str, done_when: str, context: str = "", budget_min: int = 8) -> Job:
        job = Job(
            id="j" + uuid.uuid4().hex[:8], parent_task=parent_task, child_task=child_task,
            bot_id=bot_id, bot_name=_clean(bot_name, 80) or "Teammate",
            objective=_clean(objective, 1200), done_when=_clean(done_when, 500),
            context=_clean(context, 1500), budget_min=max(1, min(30, int(budget_min))),
        )
        with self._lock:
            self.jobs[job.id] = job
            self._trim()
            self.save()
        return job

    def finish_job(self, job_id: str, status: str, result: str, *, actions: int = 0,
                   files: list[str] | None = None) -> Job | None:
        with self._lock:
            job = self.jobs.get(job_id)
            if job is None:
                return None
            if job.status == "running":
                job.status = status if status in ("done", "failed", "stopped", "timeout") else "done"
                job.ended = time.time()
            job.result = _clean(result, MAX_RESULT)
            job.actions = max(0, int(actions))
            job.files = [str(f)[:300] for f in (files or [])][:20]
            self.save()
        return job

    def review_job(self, job_id: str, verdict: str, note: str = "") -> Job | None:
        with self._lock:
            job = self.jobs.get(job_id)
            if job is None:
                return None
            job.verdict = "accepted" if verdict in ("accept", "accepted") else "rejected"
            job.review_note = _clean(note, 600)
            job.reviewed_at = time.time()
            self.save()
        return job

    def reopen_job(self, job_id: str) -> Job | None:
        """A sent-back job goes back to the same teammate, in the same thread."""
        with self._lock:
            job = self.jobs.get(job_id)
            if job is None or job.status == "running":
                return None
            job.status = "running"
            job.ended = 0.0
            job.result = ""
            job.actions = 0
            job.files = []
            job.verdict = ""
            job.review_note = ""
            job.reviewed_at = 0.0
            job.attempts += 1
            self.save()
        return job

    def _trim(self) -> None:
        if len(self.jobs) <= MAX_JOBS:
            return
        order = sorted(self.jobs.values(), key=lambda j: j.started)
        for job in order[:len(self.jobs) - MAX_JOBS]:
            if job.status != "running":
                self.jobs.pop(job.id, None)

    def stats(self, bot_id: str) -> dict[str, Any]:
        """What this teammate has done, for the roster and for Compii's own judgement."""
        with self._lock:
            mine = [j for j in self.jobs.values() if j.bot_id == bot_id]
        done = [j for j in mine if j.status == "done"]
        accepted = [j for j in mine if j.verdict == "accepted"]
        rejected = [j for j in mine if j.verdict == "rejected"]
        reviewed = len(accepted) + len(rejected)
        last = max((j for j in mine if j.verdict), key=lambda j: j.reviewed_at, default=None)
        return {
            "jobs": len(mine),
            "done": len(done),
            "failed": len([j for j in mine if j.status in ("failed", "timeout")]),
            "running": len([j for j in mine if j.status == "running"]),
            "accepted": len(accepted),
            "rejected": len(rejected),
            "success": round(100 * len(accepted) / reviewed) if reviewed else None,
            "last_review": last.review_note if last else "",
            "last_verdict": last.verdict if last else "",
        }

    def job(self, job_id: str) -> Job | None:
        return self.jobs.get((job_id or "").strip())

    def jobs_view(self, limit: int = 40) -> list[dict[str, Any]]:
        with self._lock:
            recent = sorted(self.jobs.values(), key=lambda j: j.started, reverse=True)[:limit]
        return [j.view() for j in recent]

    # ---- hiring ------------------------------------------------------------

    def propose(self, *, name: str, job: str, why: str = "", first_task: str = "",
                avatar: str = "") -> Proposal:
        prop = Proposal(id="h" + uuid.uuid4().hex[:8], name=_clean(name, 40),
                        job=_clean(job, 120), why=_clean(why, 500),
                        first_task=_clean(first_task, 500), avatar=str(avatar or "")[:60])
        if not prop.name:
            raise ValueError("A teammate needs a name suggestion.")
        with self._lock:
            self.proposals[prop.id] = prop
            self.save()
        return prop

    def proposal(self, proposal_id: str) -> Proposal | None:
        return self.proposals.get((proposal_id or "").strip())

    def resolve_proposal(self, proposal_id: str, status: str, *, bot_id: str = "") -> Proposal | None:
        with self._lock:
            prop = self.proposals.get((proposal_id or "").strip())
            if prop is None:
                return None
            prop.status = status
            prop.bot_id = bot_id
            self.save()
        return prop

    def proposals_view(self, open_only: bool = True) -> list[dict[str, Any]]:
        with self._lock:
            items = [p for p in self.proposals.values() if not open_only or p.status == "open"]
        return [p.view() for p in sorted(items, key=lambda p: p.created, reverse=True)]

    def view(self) -> dict[str, Any]:
        return {"jobs": self.jobs_view(), "proposals": self.proposals_view(open_only=False)}

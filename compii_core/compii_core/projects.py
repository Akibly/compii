"""Projects: the long-running goals that span days and conversations.

A project is a goal with steps, deadlines and notes ("scholarship applications", "launch
the bakery's marketing"). Routines and watches read it, so Compii can carry on tomorrow
without being told again.
"""

from __future__ import annotations

import json
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult

MAX_STEPS = 40
STATUS = ("todo", "doing", "done", "blocked")
MARKS = {"todo": "[ ]", "doing": "[>]", "done": "[x]", "blocked": "[!]"}


@dataclass
class Step:
    title: str
    status: str = "todo"
    due: str = ""  # free text: "2026-11-30", "end of month"
    note: str = ""


@dataclass
class Project:
    title: str
    goal: str = ""
    id: str = field(default_factory=lambda: "p" + uuid.uuid4().hex[:8])
    created: float = field(default_factory=time.time)
    updated: float = field(default_factory=time.time)
    status: str = "active"  # active | done | parked
    steps: list[Step] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    files: list[str] = field(default_factory=list)

    def left(self) -> list[Step]:
        return [s for s in self.steps if s.status in ("todo", "doing", "blocked")]

    def as_text(self) -> str:
        marks = MARKS
        lines = [f"{marks.get(s.status, '[ ]')} {s.title}"
                 + (f" (due {s.due})" if s.due else "") + (f" - {s.note}" if s.note else "") for s in self.steps]
        out = [f"{self.title}: {self.goal}".rstrip(": ")]
        out += lines
        if self.notes:
            out.append("Notes: " + " | ".join(self.notes[-4:]))
        return "\n".join(out)


class Projects:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self.items: dict[str, Project] = {}
        if path.exists():
            try:
                for d in json.loads(path.read_text(encoding="utf-8-sig")):
                    steps = [Step(**s) for s in d.pop("steps", [])]
                    self.items[d["id"]] = Project(**d, steps=steps)
            except (ValueError, TypeError, KeyError):
                path.replace(path.with_suffix(f".broken-{int(time.time())}.json"))

    def save(self) -> None:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            rows = []
            for p in self.items.values():
                d = asdict(p)
                rows.append(d)
            tmp.write_text(json.dumps(rows, indent=1, ensure_ascii=False), encoding="utf-8")
            tmp.replace(self.path)

    def add(self, title: str, goal: str, steps: list[dict[str, Any]], files: list[str]) -> Project:
        p = Project(title.strip()[:80], goal.strip()[:600],
                    steps=[Step(str(s.get("title", ""))[:120], str(s.get("status", "todo")) if
                            str(s.get("status", "todo")) in STATUS else "todo",
                            str(s.get("due", ""))[:40], str(s.get("note", ""))[:200])
                           for s in steps[:MAX_STEPS] if str(s.get("title", "")).strip()],
                    files=files[:20])
        self.items[p.id] = p
        self.save()
        return p

    def active(self) -> list[Project]:
        return sorted((p for p in self.items.values() if p.status == "active"), key=lambda p: -p.updated)

    def find(self, title: str) -> Project | None:
        want = title.strip().lower()
        for p in self.items.values():
            if p.title.lower() == want:
                return p
        hits = [p for p in self.items.values() if want and (want in p.title.lower() or p.title.lower() in want)]
        return max(hits, key=lambda p: p.updated) if hits else None

    def context(self) -> str:
        live = self.active()[:8]
        if not live:
            return ""
        blocks = "\n".join(f"- {p.as_text()}" for p in live)
        return ("Projects in flight (goals the user is working towards; keep them current, and mention a step only "
                "when it matters):\n" + blocks)


def project_tools(projects: Projects) -> list[Tool]:
    s = {"type": "string"}
    step_schema = {"type": "object", "properties": {"title": s, "due": s, "note": s,
                                                    "status": {"enum": list(STATUS)}},
                   "required": ["title"], "additionalProperties": False}

    def start(a: dict[str, Any]) -> ToolResult:
        p = projects.add(a["title"], a.get("goal", ""), list(a.get("steps") or []), list(a.get("files") or []))
        return ToolResult(f"Started the project “{p.title}” with {len(p.steps)} steps.\n" + p.as_text(),
                          plan=[{"title": s_.title, "status": "done" if s_.status == "done" else "pending"}
                                for s_ in p.steps])

    def list_(a: dict[str, Any]) -> ToolResult:
        live = projects.active()
        if not live:
            return ToolResult("No open projects.")
        return ToolResult("\n\n".join(p.as_text() for p in live))

    def update(a: dict[str, Any]) -> ToolResult:
        p = projects.items.get(a.get("id") or "") or projects.find(a.get("title", ""))
        if p is None:
            raise ToolError("No project with that name. Start one with start_project.")
        said = []
        for mark in list(a.get("steps") or [])[:MAX_STEPS]:
            want = str(mark.get("title", "")).strip().lower()
            step = next((x for x in p.steps if x.title.lower() == want), None)
            step = step or next((x for x in p.steps if want and (want in x.title.lower() or x.title.lower() in want)), None)
            new = step is None
            if new:
                step = Step(str(mark.get("title", want))[:120])
                p.steps.append(step)
            if mark.get("status") in STATUS:
                step.status = mark["status"]
            if mark.get("due"):
                step.due = str(mark["due"])[:40]
            if mark.get("note"):
                step.note = str(mark["note"])[:200]
            said.append((f"added “{step.title}”" if new else f"“{step.title}”") +
                        (f" -> {step.status}" if new or mark.get("status") in STATUS else ""))
        if a.get("note"):
            p.notes.append(str(a["note"])[:300])
            said.append("noted")
        for f in list(a.get("files") or []):
            if str(f) not in p.files:
                p.files.append(str(f))
        if a.get("status") in ("active", "done", "parked"):
            p.status = a["status"]
        if a.get("goal"):
            p.goal = str(a["goal"])[:600]
        p.updated = time.time()
        projects.save()
        left = p.left()
        head = ", ".join(said) or "Updated"
        # upper() on the first character only: str.capitalize() would lowercase every other word too.
        head = head[0].upper() + head[1:]
        done = "Nothing left - tell the user the project is finished."
        rows = "\n".join(f"- {x.title}" + (f" (due {x.due})" if x.due else "") for x in left)
        return ToolResult(f"{head}\n{done}" if not left else
                          f"{head}\n{len(left)} step(s) left:\n{rows}")

    return [
        Tool("start_project", "Track a goal that takes more than one sitting (applications, a launch, a move, "
             "research plus action). Keep it updated so a routine or a later conversation can carry on.",
             {"title": {**s, "description": "Short name, e.g. 'Scholarship applications 2027'."},
              "goal": {**s, "description": "What finished looks like, in a sentence."},
              "steps": {"type": "array", "items": step_schema},
              "files": {"type": "array", "items": s, "description": "Files that belong to this project."}},
             ["title"], ActionKind.CREATE, start, lambda a: f"Start the project “{a['title']}”"),
        Tool("project_status", "The projects in flight with their steps, deadlines and what's left.",
             {}, [], ActionKind.READ, list_, lambda a: "Look at the open projects"),
        Tool("update_project", "Mark steps done or blocked, add steps, deadlines, notes or files as work moves on.",
             {"title": s, "id": s, "goal": s, "status": {"enum": ["active", "done", "parked"]},
              "note": s, "files": {"type": "array", "items": s},
              "steps": {"type": "array", "items": step_schema}},
             [], ActionKind.CHANGE, update,
             lambda a: f"Update “{a.get('title') or a.get('id') or 'the project'}”"),
    ]

"""Skills: teach Compii a task once, then reuse it by name.

A skill is a named recipe (what to do + the steps that worked). Make one from
any finished conversation ("Save as skill"), or ask Compii to save one. Try a
skill on a one-off task first; when it works, turn it into a routine.
"""

from __future__ import annotations

import asyncio
import json
import re
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult


@dataclass
class Skill:
    name: str
    instruction: str
    steps: list[str] = field(default_factory=list)
    source_task: str | None = None
    id: str = field(default_factory=lambda: "s" + uuid.uuid4().hex[:8])
    created: float = field(default_factory=time.time)
    uses: int = 0
    last_used: float | None = None
    # What it is for, in general terms; the instruction keeps the original wording.
    about: str = ""

    def as_prompt(self) -> str:
        steps = "\n".join(f"{i}. {s}" for i, s in enumerate(self.steps, 1)) or "(no fixed steps)"
        about = f"\nWhat it's for: {self.about}" if self.about else ""
        return (f"Skill “{self.name}”: {self.instruction}{about}\nSteps that worked before:\n{steps}\n"
                "Adapt names, dates and files to today's request.")


class Skills:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self.items: dict[str, Skill] = {}
        if path.exists():
            try:
                for d in json.loads(path.read_text(encoding="utf-8-sig")):
                    self.items[d["id"]] = Skill(**d)
            except (ValueError, TypeError, KeyError):
                path.replace(path.with_suffix(f".broken-{int(time.time())}.json"))

    def save(self) -> None:
        with self._lock:
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps([asdict(s) for s in self.items.values()], indent=1, ensure_ascii=False),
                           encoding="utf-8")
            tmp.replace(self.path)

    def add(self, name: str, instruction: str, steps: list[str], source_task: str | None = None,
            about: str = "") -> Skill:
        name = name.strip()[:60]
        if not name or not instruction.strip():
            raise ValueError("A skill needs a name and what it does.")
        old = self.named(name)
        if old:
            self.items.pop(old.id)
        skill = Skill(name, instruction.strip(), [s.strip() for s in steps if s.strip()][:30], source_task,
                      about=about.strip()[:300])
        self.items[skill.id] = skill
        self.save()
        return skill

    def named(self, name: str) -> Skill | None:
        """Exactly this name, ignoring case: the one a save would replace."""
        want = name.strip().lower()
        return next((s for s in self.items.values() if s.name.lower() == want), None)

    def find(self, name: str) -> Skill | None:
        want = name.strip().lower()
        for s in self.items.values():
            if s.name.lower() == want:
                return s
        for s in self.items.values():
            if want and (want in s.name.lower() or s.name.lower() in want):
                return s
        return None

    def remove(self, skill_id: str) -> bool:
        if self.items.pop(skill_id, None) is None:
            return False
        self.save()
        return True

    def used(self, skill: Skill) -> None:
        skill.uses += 1
        skill.last_used = time.time()
        self.save()

    def view(self) -> list[dict[str, Any]]:
        return [asdict(s) for s in sorted(self.items.values(), key=lambda s: -s.created)]

    def context(self) -> str:
        if not self.items:
            return ""
        names = ", ".join(f"“{s.name}”" + (f" ({s.about})" if s.about else "")
                          for s in list(self.items.values())[:40])
        return (f"Saved skills (things the user taught you): {names}. "
                "When a request matches one, call use_skill first and follow its steps, adapting to today's details.")


def from_task(task: Any) -> tuple[str, list[str]]:
    """The request and the actions that worked, from a finished conversation."""
    steps: list[str] = []
    for e in task.events:
        if e.get("type") == "action_done" and e.get("ok") and e.get("tool") not in ("update_plan", "recall"):
            label = str(e.get("label", "")).strip()
            if label and (not steps or steps[-1] != label):
                steps.append(label)
    requests = [task.request] + [e["text"] for e in task.events if e.get("type") == "user_message" and e.get("text")]
    return " Then: ".join(requests), steps


def suggest_name(text: str) -> str:
    words = re.sub(r"[^\w\s'-]", "", text).split()[:6]
    while len(words) > 1 and words[-1].lower() in _SMALL:
        words.pop()
    joined = " ".join(words)
    # Only the first letter: str.capitalize() would also lowercase "Ghana" and "Ltd" in the middle.
    return joined[0].upper() + joined[1:] if joined else "My skill"


DRAFT_PROMPT = """You name skills for Compii, a PC assistant. A skill is a reusable recipe saved from a finished
conversation. Read the conversation and reply with JSON only:
{"name": "2-5 words, Title case, says what it is for in general (not today's one-off details), e.g. 'Weekly invoice sort'",
 "about": "one sentence: what the skill does and when to use it, with today's specifics generalised"}"""


async def draft(brain: Any, task: Any, skills: Skills, timeout: float = 15) -> dict[str, Any]:
    """A name and summary that fit what the conversation was for, plus what saving it would keep."""
    instruction, steps = from_task(task)
    name, about = suggest_name(task.request), ""
    finals = [e.get("text", "") for e in task.events if e.get("type") == "task_finished"]
    done = [f"- {s}" for s in steps] or ["- (none)"]
    convo = "\n".join([f"User asked: {instruction}", "Steps that worked:", *done,
                       f"Compii's answer: {finals[-1][:600] if finals else ''}"])
    try:
        reply = await asyncio.wait_for(brain.step(DRAFT_PROMPT, [{"role": "user", "content": convo}], []), timeout)
        m = re.search(r"\{.*\}", reply.text or "", re.S)
        got = json.loads(m.group(0)) if m else {}
        if isinstance(got, dict):
            n = str(got.get("name") or "").strip().strip("'\"“”.")
            if 1 < len(n) <= 60:
                name = n
            about = str(got.get("about") or "").strip()[:300]
    except Exception:  # noqa: BLE001 - fall back to a name from the request
        pass
    taken = skills.named(name)
    return {"name": name, "about": about, "steps": steps, "instruction": instruction,
            "taken": taken.name if taken else None, "names": [s.name for s in skills.items.values()]}


_SMALL = {"a", "an", "the", "in", "on", "of", "to", "for", "and", "my", "me", "it", "from", "with", "into", "at"}


def skill_tools(skills: Skills) -> list[Tool]:
    s = {"type": "string"}

    def list_skills(_a: dict[str, Any]) -> ToolResult:
        if not skills.items:
            return ToolResult("No skills saved yet.")
        return ToolResult("\n".join(f"- {k.name}: {k.instruction}" for k in skills.items.values()))

    def use_skill(a: dict[str, Any]) -> ToolResult:
        skill = skills.find(a["name"])
        if skill is None:
            raise ToolError(f"No saved skill called “{a['name']}”. Use list_skills to see them.")
        skills.used(skill)
        return ToolResult(skill.as_prompt())

    def save_skill(a: dict[str, Any]) -> ToolResult:
        taken = skills.named(a["name"])
        if taken and not a.get("replace"):
            raise ToolError(f"There's already a skill called “{taken.name}”. Ask the user whether to replace it "
                            "(then call again with replace=true) or to choose another name.")
        try:
            skill = skills.add(a["name"], a["instruction"], list(a.get("steps") or []), about=a.get("about", ""))
        except ValueError as e:
            raise ToolError(str(e)) from e
        return ToolResult(f"Saved the skill “{skill.name}” with {len(skill.steps)} steps.")

    return [
        Tool("list_skills", "List the skills the user has taught you.", {}, [], ActionKind.READ, list_skills,
             lambda a: "Look at saved skills"),
        Tool("use_skill", "Load a saved skill's recipe by name before doing that task.", {"name": s}, ["name"],
             ActionKind.READ, use_skill, lambda a: f"Use the skill “{a['name']}”"),
        Tool("save_skill", "Save how to do a task as a reusable skill, when the user asks you to remember how to do it. "
             "Ask the user what to call it first (suggest a name) unless they already named it.",
             {"name": {**s, "description": "The name the user chose or agreed to, e.g. 'Weekly invoice sort'."},
              "about": {**s, "description": "One sentence: what it's for and when to use it."},
              "replace": {"type": "boolean", "description": "true only after the user agreed to replace a skill with this name."},
              "instruction": {**s, "description": "What the skill achieves, in one sentence."},
              "steps": {"type": "array", "items": s, "description": "The steps that worked, in order."}},
             ["name", "instruction", "steps"], ActionKind.CREATE, save_skill,
             lambda a: f"Save the skill “{a['name']}”"),
    ]

"""Lessons: when you ask Compii to teach you something ("teach me Blender"), it keeps
a lesson plan (the topic, the steps, where you are) on this PC. "What next?" carries on
from there, later the same day or after a restart."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult


class Lessons:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.current: dict[str, Any] | None = None
        try:
            self.current = json.loads(path.read_text(encoding="utf-8")) or None
        except (OSError, ValueError):
            self.current = None

    def _save(self) -> None:
        self.path.write_text(json.dumps(self.current or {}, indent=1), encoding="utf-8")

    def start(self, topic: str, steps: list[str], level: str = "") -> dict[str, Any]:
        steps = [s.strip() for s in steps if s and s.strip()]
        if not topic.strip() or not steps:
            raise ValueError("A lesson needs a topic and at least one step.")
        self.current = {"topic": topic.strip(), "level": level.strip(), "steps": steps, "step": 0,
                        "notes": [], "started": time.time(), "updated": time.time()}
        self._save()
        return self.current

    def update(self, step: int | None = None, note: str = "", finished: bool = False) -> dict[str, Any]:
        if not self.current:
            raise ValueError("There's no lesson going on.")
        if finished:
            done, self.current = self.current, None
            self._save()
            return done
        if step is not None:
            self.current["step"] = max(0, min(len(self.current["steps"]) - 1, step - 1))
        if note.strip():
            self.current["notes"] = (self.current["notes"] + [note.strip()[:200]])[-8:]
        self.current["updated"] = time.time()
        self._save()
        return self.current

    def context(self) -> str:
        """Added to the AI's instructions while a lesson is going on."""
        c = self.current
        if not c:
            return ""
        lines = [f"Lesson in progress: you are teaching the user {c['topic']}"
                 + (f" (level: {c['level']})" if c.get("level") else "") + ". The plan:"]
        for i, s in enumerate(c["steps"]):
            mark = "done" if i < c["step"] else "NOW" if i == c["step"] else "later"
            lines.append(f"  {i + 1}. [{mark}] {s}")
        if c.get("notes"):
            lines.append("What you know about how it's going: " + "; ".join(c["notes"]))
        lines.append("When the user says \"what next\", \"next\", \"continue\", \"done\" or asks about the lesson, "
                     "carry on from the NOW step: teach one small step at a time, show on screen with point_at or "
                     "start_walkthrough when the app is open, then call update_lesson to move on. Never start over "
                     "unless asked.")
        return "\n".join(lines)


def lesson_tools(lessons: Lessons) -> list[Tool]:
    s = {"type": "string"}

    def start_lesson(a: dict[str, Any]) -> ToolResult:
        try:
            c = lessons.start(a["topic"], list(a.get("steps") or []), a.get("level", ""))
        except ValueError as e:
            raise ToolError(str(e)) from e
        return ToolResult(f"Lesson saved: {c['topic']}, {len(c['steps'])} steps. Now teach step 1.")

    def update_lesson(a: dict[str, Any]) -> ToolResult:
        try:
            c = lessons.update(a.get("step"), a.get("note", ""), bool(a.get("finished")))
        except ValueError as e:
            raise ToolError(str(e)) from e
        if a.get("finished"):
            return ToolResult(f"Lesson on {c['topic']} finished.")
        return ToolResult(f"Now on step {c['step'] + 1} of {len(c['steps'])}: {c['steps'][c['step']]}")

    return [
        Tool("start_lesson",
             "When the user asks you to teach them something that takes more than one sitting (an app like Blender, "
             "a skill, a subject), save a lesson plan of 5-12 small, practical steps so you can carry on later.",
             {"topic": s, "steps": {"type": "array", "items": s, "description": "Small steps, in order."},
              "level": {**s, "description": "Beginner, some experience…, if known."}},
             ["topic", "steps"], ActionKind.READ, start_lesson, lambda a: f"Plan a lesson: {a['topic']}"),
        Tool("update_lesson",
             "Move the lesson on (step = the step number the user is on now), note how it's going, or finish it.",
             {"step": {"type": "integer"}, "note": s, "finished": {"type": "boolean"}},
             [], ActionKind.READ, update_lesson, lambda a: "Update the lesson"),
    ]

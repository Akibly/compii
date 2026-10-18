"""Walkthroughs: "Teach me to…". Compii points at each step, waits for the user
to do it, checks the screen, then moves on.

Each step names the item to press (found by its label with UI Automation) and,
optionally, what should be true afterwards: a window title appears, an item
appears, or an item goes away. Without one, the step counts as done when the
item disappears or a different window comes to the front. The current
walkthrough is saved, so a pause or interruption doesn't lose it.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult

STEP_SECONDS = 120
POLL = 0.6


class Walkthroughs:
    def __init__(self, toolbox: Any, state_path: Path, notify: Callable[[dict[str, Any]], None] | None = None,
                 say: Callable[[str], None] | None = None, step_seconds: float = STEP_SECONDS, poll: float = POLL) -> None:
        self.toolbox = toolbox
        self.state_path = state_path
        self.notify = notify or (lambda _e: None)
        self.say = say or (lambda _t: None)
        self.step_seconds = step_seconds
        self.poll = poll

    # ---- what's on screen ----

    def _find(self, label: str):
        try:
            return self.toolbox._find(label)
        except Exception:  # noqa: BLE001 - screen changing under us
            return None

    def _front(self) -> str:
        try:
            wins = self.toolbox.screen.list_windows()
            return wins[0]["title"] if wins else ""
        except Exception:  # noqa: BLE001
            return ""

    def _windows(self) -> list[str]:
        try:
            return [w["title"].lower() for w in self.toolbox.screen.list_windows()]
        except Exception:  # noqa: BLE001
            return []

    def _done(self, step: dict[str, Any], start_front: str) -> bool:
        when = step.get("done_when") or {}
        if when.get("window_title"):
            return any(when["window_title"].lower() in t for t in self._windows())
        if when.get("element"):
            return self._find(when["element"]) is not None
        if when.get("element_gone"):
            return self._find(when["element_gone"]) is None
        return self._find(step["target"]) is None or self._front() != start_front

    # ---- running ----

    def save(self, state: dict[str, Any]) -> None:
        self.state_path.write_text(json.dumps(state, indent=1, ensure_ascii=False), encoding="utf-8")

    def current(self) -> dict[str, Any] | None:
        try:
            return json.loads(self.state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

    def run(self, a: dict[str, Any]) -> ToolResult:
        halt = a.get("_halt")
        steps = [dict(s) for s in a["steps"] if str(s.get("target", "")).strip() and str(s.get("instruction", "")).strip()]
        if not steps:
            raise ToolError("A walkthrough needs steps, each with an instruction and the label of what to press.")
        start = max(0, int(a.get("start_at", 1)) - 1)
        state = {"goal": a["goal"], "steps": steps, "completed": start, "status": "running", "at": time.time()}
        self.save(state)
        self.notify({"type": "walkthrough", "goal": a["goal"], "steps": [s["instruction"] for s in steps],
                     "current": start, "status": "running"})
        for i in range(start, len(steps)):
            step = steps[i]
            found = self._find(step["target"])
            if found is None:
                state.update(status="paused", completed=i, note=f"couldn't find “{step['target']}”")
                self.save(state)
                self.notify({"type": "walkthrough", "goal": a["goal"], "current": i, "status": "paused",
                             "note": state["note"]})
                return ToolResult(
                    f"Paused at step {i + 1} of {len(steps)}: “{step['target']}” isn't on screen. "
                    "Ask the user what they see, or read_window and re-plan from this step (start_at).")
            point = {**found.as_event(), "message": step["instruction"]}
            if self.toolbox.on_point:
                self.toolbox.on_point(point)
            self.notify({"type": "walkthrough", "goal": a["goal"], "current": i, "status": "running",
                         "instruction": step["instruction"]})
            self.say(step["instruction"])
            start_front = self._front()
            deadline = time.monotonic() + self.step_seconds
            hinted = False
            while not self._done(step, start_front):
                if halt is not None and halt.is_set():
                    state.update(status="stopped", completed=i)
                    self.save(state)
                    return ToolResult(f"Stopped at step {i + 1}.")
                if time.monotonic() > deadline:
                    if hinted:
                        state.update(status="paused", completed=i, note="waited too long")
                        self.save(state)
                        self.notify({"type": "walkthrough", "goal": a["goal"], "current": i, "status": "paused",
                                     "note": "waiting for you"})
                        return ToolResult(f"Paused at step {i + 1} of {len(steps)}: the user hasn't done it yet. "
                                          "Ask if they're stuck; resume later with start_at.")
                    hinted = True
                    deadline = time.monotonic() + self.step_seconds / 2
                    hint = step.get("hint") or f"It's the “{found.name}” {found.role.replace('Control', '').lower()} I'm pointing at."
                    if self.toolbox.on_point:
                        self.toolbox.on_point({**point, "message": hint})
                    self.say(hint)
                time.sleep(self.poll)
            state["completed"] = i + 1
            self.save(state)
        state["status"] = "done"
        self.save(state)
        self.notify({"type": "walkthrough", "goal": a["goal"], "current": len(steps), "status": "done"})
        return ToolResult(f"Walkthrough finished: all {len(steps)} steps done and checked on screen.")

    def tool(self) -> Tool:
        s = {"type": "string"}
        step = {"type": "object", "properties": {
            "instruction": {**s, "description": "One short sentence said to the user, e.g. 'Click Insert at the top.'"},
            "target": {**s, "description": "The exact visible label of what to press."},
            "hint": {**s, "description": "Extra help if they don't find it."},
            "done_when": {"type": "object", "description": "Optional check that the step worked.", "properties": {
                "window_title": s, "element": s, "element_gone": s}, "additionalProperties": False},
        }, "required": ["instruction", "target"], "additionalProperties": False}
        return Tool(
            "start_walkthrough",
            "Teach the user to do something themselves: point at each step on their screen, wait while they do it, "
            "check it worked, then move on. Use when they say 'teach me', 'show me how' or 'walk me through'. "
            "read_window first so targets use exact labels.",
            {"goal": s, "steps": {"type": "array", "items": step}, "start_at": {"type": "integer"}},
            ["goal", "steps"], ActionKind.READ, self.run, lambda a: f"Walk you through: {a['goal']}",
            long_running=True,
        )

"""Replay a recorded demonstration, one action at a time, with the usual checks.

Only what was recorded is repeated: clicks by the exact label, shortcuts, and window
switches. Text typed during the demonstration is deliberately not recorded, so replay
asks for the words it needs and stops there rather than inventing them. Every step goes
through the same tools a hand-made action would, so each one is checked and reported
honestly; the first step that fails stops the replay.
"""

from __future__ import annotations

from typing import Any

from .tools import ToolError


class Replayer:
    def __init__(self, toolbox: Any) -> None:
        self.toolbox = toolbox

    def run(self, actions: list[dict[str, Any]], values: list[str] | None = None,
            start_at: int = 1, halt: Any = None) -> dict[str, Any]:
        """Run recorded actions from ``start_at`` (1-based); return a step-by-step account."""
        words = [str(v) for v in (values or [])]
        typed = 0
        lines: list[str] = []
        total = len(actions)
        start = max(0, int(start_at) - 1)
        for i in range(start, total):
            if halt is not None and halt.is_set():
                return {"done": i, "total": total, "lines": lines, "needs": None,
                        "stopped": f"Stopped at step {i + 1}; the rest was not attempted."}
            action = actions[i]
            kind = action.get("kind")
            if kind == "type" and typed >= len(words):
                return {"done": i, "total": total, "lines": lines, "stopped": None,
                        "needs": {"step": i + 1, "field": action.get("field") or "the field"}}
            try:
                got = self._do(action, words[typed] if kind == "type" else None)
            except ToolError as e:
                return {"done": i, "total": total, "lines": lines, "needs": None,
                        "stopped": f"Stopped at step {i + 1}: {e} The rest was not attempted."}
            if kind == "type":
                typed += 1
            lines.append(f"{i + 1}. {got.text}")
        return {"done": total, "total": total, "lines": lines, "stopped": None, "needs": None}

    def check(self, actions: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Look, without touching anything, at whether each step is reachable right now."""
        checks: list[dict[str, Any]] = []
        windows: list[str] | None = None
        for i, action in enumerate(actions):
            step = i + 1
            kind = action.get("kind")
            window = str(action.get("window") or "")
            if kind in ("click", "type"):
                label = str(action.get("target") or action.get("field") or "")
                try:
                    found = self.toolbox.locate(label) if label else None
                except Exception as e:  # noqa: BLE001 - this is a look, not an action
                    checks.append({"step": step, "ok": False, "detail": f"Couldn't look: {e}"})
                    continue
                if found is None:
                    checks.append({"step": step, "ok": False,
                                   "detail": f"Nothing called “{label}” is on screen right now."})
                    continue
                note = f"Found “{found.name}” in “{found.window}”."
                if window and found.window.lower() != window.lower():
                    note += f" The demo used “{window}”."
                checks.append({"step": step, "ok": True, "detail": note})
            elif kind == "switch":
                if windows is None:
                    try:
                        windows = self.toolbox.window_titles()
                    except Exception:  # noqa: BLE001
                        windows = []
                open_now = any(window.lower() in w.lower() or w.lower() in window.lower() for w in windows)
                checks.append({"step": step, "ok": open_now,
                               "detail": f"“{window}” is open." if open_now
                               else f"“{window}” isn't open right now."})
            elif kind == "keys":
                checks.append({"step": step, "ok": True, "detail": "Keys can be pressed when it runs."})
            else:
                checks.append({"step": step, "ok": False, "detail": f"“{kind}” isn't a step Compii can replay."})
        return checks

    def _do(self, action: dict[str, Any], text: str | None):
        kind = action.get("kind")
        window = action.get("window") or ""
        if kind == "switch":
            return self.toolbox.focus_window({"window": window})
        if kind == "click":
            args = {"target": action.get("target", "")}
            if window:
                args["window"] = window
            return self.toolbox.click_on(args)
        if kind == "keys":
            args = {"keys": action.get("keys", "")}
            if window:
                args["window"] = window
            return self.toolbox.press_keys(args)
        if kind == "type":
            args = {"text": text or "", "target": action.get("field") or ""}
            if window:
                args["window"] = window
            return self.toolbox.type_into(args)
        raise ToolError(f"“{kind}” is not something Compii can replay.")

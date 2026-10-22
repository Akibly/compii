"""Usage: what each answer cost, kept on this PC.

Compii counts what the AI actually reported and says plainly when a number is its
own estimate (characters divided by four, the usual rule of thumb). It does not
invent prices — a free key and a paid one are shown as what they are: tokens,
provider and seconds, so you can see which brain is earning its keep.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

MAX_LINES = 4000  # a few MB of history; older lines are dropped from the front
CHARS_PER_TOKEN = 4


def estimate(text: str) -> int:
    """Tokens in a piece of text when the provider didn't say."""
    return max(1, len(text or "") // CHARS_PER_TOKEN) if text else 0


class Ledger:
    """Append-only JSONL of every AI step, read back as a report."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lines = 0

    # ---- writing --------------------------------------------------------------

    def record(self, *, provider: str = "", model: str = "", kind: str = "step", prompt: int = 0,
               completion: int = 0, est: bool = False, ms: int = 0, ok: bool = True,
               audio_ms: int = 0, at: float | None = None) -> dict[str, Any]:
        row = {"at": at if at is not None else time.time(), "day": time.strftime("%Y-%m-%d"),
               "kind": kind, "provider": provider or "unknown", "model": model or "",
               "prompt": int(max(0, prompt)), "completion": int(max(0, completion)),
               "est": bool(est), "ms": int(max(0, ms)), "ok": bool(ok)}
        if audio_ms:  # only listening has audio: Whisper is billed by seconds, not tokens
            row["audio_ms"] = int(max(0, audio_ms))
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
            self._lines += 1
            if self._lines > MAX_LINES:
                self._trim()
        except OSError:
            pass  # usage is a nicety: a full disk must never cost the user their answer
        return row

    def _trim(self) -> None:
        rows = self.entries()
        keep = rows[MAX_LINES // 2:]
        try:
            self.path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in keep), encoding="utf-8")
        except OSError:
            return
        self._lines = len(keep)

    # ---- reading --------------------------------------------------------------

    def entries(self, *, since: float | None = None) -> list[dict[str, Any]]:
        try:
            raw = self.path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return []
        out = []
        for line in raw:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and (since is None or float(row.get("at") or 0) >= since):
                out.append(row)
        return out

    def report(self, days: int = 7) -> dict[str, Any]:
        days = max(1, min(365, int(days or 7)))
        since = time.time() - days * 86400
        rows = self.entries(since=since)
        by_day: dict[str, dict[str, Any]] = {}
        by_model: dict[str, dict[str, Any]] = {}
        by_kind: dict[str, dict[str, Any]] = {}
        total = {"steps": 0, "prompt": 0, "completion": 0, "estimated": 0, "failed": 0, "ms": 0, "heard_ms": 0}
        for r in rows:
            tokens = int(r.get("prompt") or 0) + int(r.get("completion") or 0)
            for bucket, key in ((by_day, str(r.get("day") or "")),
                                (by_model, f"{r.get('provider')} · {r.get('model')}" if r.get("model")
                                           else str(r.get("provider"))),
                                (by_kind, str(r.get("kind") or "step"))):
                b = bucket.setdefault(key, {"steps": 0, "tokens": 0, "ms": 0})
                b["steps"] += 1
                b["tokens"] += tokens
                b["ms"] += int(r.get("ms") or 0)
                if r.get("audio_ms"):
                    b["audio_ms"] = b.get("audio_ms", 0) + int(r["audio_ms"])
            total["steps"] += 1
            total["prompt"] += int(r.get("prompt") or 0)
            total["completion"] += int(r.get("completion") or 0)
            total["ms"] += int(r.get("ms") or 0)
            total["heard_ms"] += int(r.get("audio_ms") or 0)
            total["estimated"] += 1 if r.get("est") else 0
            total["failed"] += 0 if r.get("ok") else 1
        window = [r for r in rows if float(r.get("at") or 0) >= time.time() - 60]
        biggest = max(rows, key=lambda r: int(r.get("prompt") or 0) + int(r.get("completion") or 0), default=None)
        local = sum(1 for r in rows if _is_local(r))
        return {
            "days": days, "total": {**total, "tokens": total["prompt"] + total["completion"]},
            "by_day": [{"day": k, **v} for k, v in sorted(by_day.items())][-days:],
            "by_model": sorted(({"model": k, **v} for k, v in by_model.items()), key=lambda x: -x["tokens"])[:8],
            "by_kind": [{"kind": k, **v} for k, v in sorted(by_kind.items())],
            "last_minute_tokens": sum(int(r.get("prompt") or 0) + int(r.get("completion") or 0) for r in window),
            "last_minute_steps": len(window),
            "local_share": round(local / len(rows), 2) if rows else 0.0,
            "biggest": ({"model": f"{biggest.get('provider')} · {biggest.get('model')}",
                         "tokens": int(biggest.get("prompt") or 0) + int(biggest.get("completion") or 0),
                         "kind": biggest.get("kind")} if biggest else None),
            "note": "Token counts marked estimated were measured by counting characters, because that AI "
                    "didn’t report them. Compii doesn’t guess prices.",
        }

    def text(self, days: int = 7) -> str:
        """The same report in words, for Compii to answer with."""
        r = self.report(days=days)
        t = r["total"]
        if not t["steps"]:
            return f"No AI steps in the last {r['days']} days on this PC."
        mins = round(t["ms"] / 60000, 1)
        lines = [f"In the last {r['days']} days: {t['steps']} model steps, "
                 f"{t['tokens']:,} tokens ({t['prompt']:,} in, {t['completion']:,} out), {mins} minutes of waiting.",
                 f"{t['estimated']} of those steps counted their tokens by estimate, {t['failed']} failed, "
                 f"{round(r['local_share'] * 100)}% of steps ran on this PC rather than in the cloud."]
        if t.get("heard_ms"):
            lines.append(f"It also heard {round(t['heard_ms'] / 1000)} seconds of speech, billed as audio time, not tokens.")
        lines.append("By model:")
        lines += [f"- {m['model']}: {m['steps']} steps, {m['tokens']:,} tokens" for m in r["by_model"]]
        lines.append("By day:")
        lines += [f"- {d['day']}: {d['steps']} steps, {d['tokens']:,} tokens" for d in r["by_day"][-7:]]
        if r["biggest"]:
            lines.append(f"The single dearest step was {r['biggest']['tokens']:,} tokens on {r['biggest']['model']}.")
        lines.append(f"Right now: {r['last_minute_tokens']:,} tokens in the last minute "
                     f"({r['last_minute_steps']} steps) — compare that with your key's per-minute limit.")
        lines.append(r["note"])
        return "\n".join(lines)


def _is_local(row: dict[str, Any]) -> bool:
    return str(row.get("provider") or "") in ("ollama", "local", "lmstudio")


def usage_tool(ledger: Ledger) -> Any:
    from .policy import ActionKind
    from .tools import Tool, ToolResult

    def run(a: dict[str, Any]) -> ToolResult:
        try:
            days = int(a.get("days") or 7)
        except (TypeError, ValueError):
            days = 7
        return ToolResult(ledger.text(days=days))

    return Tool("usage_report", "Say what Compii has actually spent lately: which model answered, how many tokens "
                "and seconds it took, how much ran on this PC, and how close the last minute is to a free-tier limit. "
                "Use for “what did I burn this week”, “which model is using my quota”, “is the free key nearly out”.",
                {"days": {"type": "integer", "description": "How many days back (1–365, default 7)."}}, [],
                ActionKind.READ, run,
                lambda a: "Add up what Compii has used")

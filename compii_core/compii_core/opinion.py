"""A second opinion: ask a different AI the same question, and say which one answered.

Compii's own brain is one model with one set of blind spots. This asks a provider the
user has already configured (or a model running on this PC) the very same question, with
no tools and no memory of the user, so the two answers can be compared before Compii
replies. It never asks a service whose key isn't already on this machine, and it tells
the user plainly that the words left to another provider.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import time
from typing import Any, Callable

from . import ledger as ledger_mod
from . import providers as prov
from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult

SYSTEM = ("You are being asked for a second opinion, separately from the AI that normally answers this user. "
          "Answer plainly in up to six short sentences. You have no tools and no memory of this person. "
          "If you are not sure, say you are not sure rather than guessing.")
ANSWER_CHARS = 4000
TIMEOUT_SECONDS = 90

# Local and free first: a second opinion should cost the user nothing unless they ask otherwise.
_WHERE = {"local": 0, "cloud": 1}
_PRICE = {"free": 0, "free tier": 1, "free models": 1}


def _usable(keys: Any) -> list[tuple[str, str]]:
    """Providers this PC could ask right now: a local model, or one whose key is already stored.

    A provider with no default model is left out: an opinion must name the model it came from.
    """
    rows = []
    for name, preset in prov.PRESETS.items():
        if name == "custom" or not preset["model"]:
            continue
        local = preset["where"] == "local"
        if not local and not (preset["key"] and (keys.has(preset["key"]) or prov._env_key(preset["key"]))):
            continue
        rows.append((name, preset["label"]))
    order = {n: prov.PRESETS[n] for n, _ in rows}
    return sorted(rows, key=lambda r: (_WHERE.get(order[r[0]]["where"], 1),
                                       _PRICE.get(str(order[r[0]].get("price", "")), 2), r[1]))


def _ask(brain: Any, question: str) -> Any:
    """One plain question, no tools. Works whether or not a loop is already running here."""
    async def go() -> Any:
        return await asyncio.wait_for(brain.step(SYSTEM, [{"role": "user", "content": question}], []),
                                      TIMEOUT_SECONDS)

    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(go())
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(lambda: asyncio.run(go())).result(TIMEOUT_SECONDS + 15)


def _record(ledger: Any, brain: Any, reply: Any, question: str, ms: int) -> None:
    if ledger is None:
        return
    use = reply.usage or {}
    prompt, completion = int(use.get("prompt") or 0), int(use.get("completion") or 0)
    est = False
    if not (prompt or completion):
        prompt = ledger_mod.estimate(SYSTEM) + ledger_mod.estimate(question)
        completion = ledger_mod.estimate(reply.text)
        est = bool(prompt or completion)
    ledger.record(provider=str(getattr(brain, "provider", "") or ""), model=str(getattr(brain, "model", "") or ""),
                  kind="opinion", prompt=prompt, completion=completion, est=est, ms=ms)


def second_opinion_tool(keys: Any, *, ledger: Any = None,
                        current: Callable[[], str] = lambda: "") -> Tool:
    s = {"type": "string"}

    def run(a: dict[str, Any]) -> ToolResult:
        question = " ".join(str(a.get("question") or "").split())
        if len(question) < 6:
            raise ToolError("Give the question you want a second opinion on.")
        pool = _usable(keys)
        if not pool:
            raise ToolError("No other AI is set up on this PC to ask. Add a key in Settings → Brain, "
                            "or run a model locally with Ollama, and Compii can compare answers.")
        want = str(a.get("provider") or "").strip().lower()
        now = (current() or "").strip().lower()
        labels = dict(pool)
        if want:
            if want not in labels:
                raise ToolError(f"Compii can’t ask {want} — there’s no key for it on this PC. "
                                f"Configured: {', '.join(sorted(labels))}.")
            picks = [want]
        else:
            picks = [n for n, _ in pool if n != now] or [n for n, _ in pool]

        started = time.monotonic()
        errors = []
        for name in picks[:2]:  # the best pick, and one retry elsewhere if it says nothing
            try:
                brain = prov.make_brain(prov.BrainChoice(name), keys)
            except (prov.NoKeyError, ValueError) as e:
                errors.append(f"{labels[name]}: {str(e)[:100]}")
                continue
            try:
                reply = _ask(brain, question[:4000])
            except Exception as e:  # noqa: BLE001 - an opinion is optional: report, don't fail the turn
                errors.append(f"{labels[name]}: {type(e).__name__}: {str(e)[:100]}")
                continue
            text = (reply.text or "").strip()
            if not text:
                errors.append(f"{labels[name]}: answered with nothing.")
                continue
            _record(ledger, brain, reply, question, int((time.monotonic() - started) * 1000))
            model = str(getattr(brain, "model", "") or "")
            where = "on this PC" if prov.PRESETS[name]["where"] == "local" else "from that provider"
            return ToolResult(
                f"Second opinion — {labels[name]}{' (' + model + ')' if model else ''}, {where}, "
                f"with no memory of you:\n\n{text[:ANSWER_CHARS]}\n\n"
                f"It took {round((time.monotonic() - started), 1)}s. Compare this with what you would say; "
                "if they disagree, tell the user both answers instead of quietly picking one.")
        raise ToolError("Nobody else answered. " + "; ".join(errors)[:300])

    def describe(a: dict[str, Any]) -> str:
        want = str(a.get("provider") or "").strip()
        return f"Ask {'another AI' if not want else want} a second opinion"

    return Tool("second_opinion",
                "Ask a different AI on this PC the same question and report what it says, for “get a second "
                "opinion”, “is that right?”, “what would another model say”, or before a big call the user pays "
                "for. It answers with no tools and no memory of the user. Never say what another AI thinks "
                "without calling this first, and never name a provider that didn't answer.",
                {"question": s,
                 "provider": {**s, "description": "Ask this one by name (optional). Otherwise Compii picks a "
                                                   "local or free provider that is configured."}},
                ["question"], ActionKind.READ, run, describe, long_running=True)

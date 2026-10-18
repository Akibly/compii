"""Short spoken commands handled directly, without the AI.

When Compii is waiting for your okay, saying "yes" or "no" answers it; "stop"
stops what it's doing; "quiet" stops it talking. Only short utterances count,
so a real request that happens to start with "no" or "stop" still goes to the AI.

Safety: deleting by voice needs the word "delete" ("yes, delete it"), and
payments can never be approved by voice: press the button.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

MAX_WORDS = 6

_YES = re.compile(r"^(yes|yeah|yep|yup|sure|ok|okay|go ahead|go for it|do it|approve|approved|confirm|send it|"
                  r"that's fine|that is fine|fine|please do|correct|alright|all right)\b")
_NO = re.compile(r"^(no|nope|nah|don't|do not|decline|deny|cancel that|not now|skip it|skip that)\b")
_STOP_ALL = re.compile(r"^(stop|stop it|stop everything|stop all|cancel|cancel everything|abort|never mind|nevermind|halt)$")
_QUIET = re.compile(r"^(quiet|be quiet|shh+|shush|hush|silence|stop talking|shut up)$")


@dataclass
class Intent:
    kind: str  # approve | decline | stop | quiet | refuse
    reply: str = ""


def _clean(text: str) -> str:
    t = text.lower().strip()
    t = re.sub(r"^(hey |hi |ok |okay )?(compii|compy|compie)[,.!]?\s*", "", t)
    t = re.sub(r"[^\w\s']", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def parse(text: str, pending_kind: str | None) -> Intent | None:
    """What a short utterance means right now; None means "send it to the AI"."""
    t = _clean(text)
    if not t or len(t.split()) > MAX_WORDS:
        return None
    if _QUIET.match(t):
        return Intent("quiet")
    if pending_kind is not None:
        if _NO.match(t):
            return Intent("decline", "Okay, I won't.")
        if _YES.match(t) or (pending_kind == "delete" and re.match(r"^(delete it|yes delete)", t)):
            if pending_kind == "spend":
                return Intent("refuse", "Payments need your click on the button, not your voice.")
            if pending_kind == "delete" and "delete" not in t:
                return Intent("refuse", "To delete by voice, say “yes, delete it”. Or press the button.")
            return Intent("approve", "Okay.")
    if _STOP_ALL.match(t):
        return Intent("stop", "Stopped.")
    return None

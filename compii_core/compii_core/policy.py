"""Autonomy dial: decides whether an action needs the user's approval.

Every tool declares the kind of action it performs. The user sets, per kind,
whether Compii asks every time, asks once per task, or just does it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum


class ActionKind(StrEnum):
    READ = "read"  # look at files, pages, settings
    CREATE = "create"  # make new files, folders, drafts
    CHANGE = "change"  # modify or move existing things, run code, open apps
    SEND = "send"  # anything that leaves the machine to another person
    SPEND = "spend"  # money
    DELETE = "delete"  # remove things


class Autonomy(StrEnum):
    ASK_EVERY_TIME = "ask_every_time"
    ASK_ONCE_PER_TASK = "ask_once_per_task"
    JUST_DO_IT = "just_do_it"


DEFAULT_DIAL: dict[ActionKind, Autonomy] = {
    ActionKind.READ: Autonomy.JUST_DO_IT,
    ActionKind.CREATE: Autonomy.JUST_DO_IT,
    ActionKind.CHANGE: Autonomy.ASK_ONCE_PER_TASK,
    ActionKind.SEND: Autonomy.ASK_EVERY_TIME,
    ActionKind.SPEND: Autonomy.ASK_EVERY_TIME,
    ActionKind.DELETE: Autonomy.ASK_EVERY_TIME,
}

# Kinds that can never be set to "just do it".
ALWAYS_CONFIRM = {ActionKind.SPEND}


@dataclass
class Policy:
    dial: dict[ActionKind, Autonomy] = field(default_factory=lambda: dict(DEFAULT_DIAL))

    def set(self, kind: ActionKind, level: Autonomy) -> None:
        if kind in ALWAYS_CONFIRM and level is Autonomy.JUST_DO_IT:
            raise ValueError(f"{kind} actions always need approval")
        self.dial[kind] = level

    def needs_approval(self, kind: ActionKind, approved_this_task: set[ActionKind]) -> bool:
        level = self.dial.get(kind, Autonomy.ASK_EVERY_TIME)
        if level is Autonomy.JUST_DO_IT:
            return False
        if level is Autonomy.ASK_ONCE_PER_TASK:
            return kind not in approved_this_task
        return True


# ---- standing rules ("Always allow") and the kill switch -------------------------

# Kinds a rule may never cover: money always asks.
NEVER_RULE = {ActionKind.SPEND}
# After a suspected prompt injection in a task, these ask every time, whatever the rules say.
FRESH_AFTER_INJECTION = {ActionKind.SEND, ActionKind.DELETE, ActionKind.SPEND}


def scope_for(tool: str, args: dict) -> str:
    """What an "Always allow" covers: this tool on this folder, site, window or recipients."""
    import urllib.parse
    from pathlib import Path

    for key in ("path", "src", "folder"):
        if args.get(key):
            p = Path(str(args[key]))
            return str(p.parent if p.suffix else p)
    if args.get("url"):
        return urllib.parse.urlparse(str(args["url"])).netloc.lower()
    if args.get("to"):
        to = args["to"] if isinstance(args["to"], list) else [args["to"]]
        return ",".join(sorted(str(t).lower() for t in to))
    if args.get("window"):
        return str(args["window"]).lower()
    return ""


@dataclass
class Rule:
    tool: str
    scope: str
    kind: str
    label: str = ""
    id: str = ""
    created: float = 0.0

    def matches(self, tool: str, scope: str) -> bool:
        if tool != self.tool:
            return False
        if not self.scope:
            return True
        if scope == self.scope:
            return True
        # A folder rule also covers what is inside it.
        sep = "\\" if "\\" in self.scope else "/"
        return scope.lower().startswith(self.scope.lower().rstrip(sep) + sep)


@dataclass
class Gate:
    """The full decision, outside the model: dial + rules + lockdown + injection taint."""

    policy: Policy
    rules: list[Rule] = field(default_factory=list)
    lockdown: bool = False  # the kill switch: everything but reading asks, rules are ignored

    def needs_approval(self, kind: ActionKind, approved_this_task: set[ActionKind], tool: str = "",
                       args: dict | None = None, tainted: bool = False) -> bool:
        if kind is ActionKind.READ:
            return False
        if self.lockdown or kind in ALWAYS_CONFIRM:
            return True
        if tainted and kind in FRESH_AFTER_INJECTION:
            return True
        if tool and self.rule_for(tool, args or {}):
            return False
        return self.policy.needs_approval(kind, approved_this_task)

    def rule_for(self, tool: str, args: dict) -> Rule | None:
        scope = scope_for(tool, args)
        return next((r for r in self.rules if r.matches(tool, scope)), None)

    def add_rule(self, tool: str, args: dict, kind: ActionKind, label: str) -> Rule:
        import time
        import uuid

        if kind in NEVER_RULE:
            raise ValueError("Payments always need your approval.")
        rule = Rule(tool, scope_for(tool, args), kind.value, label, "r" + uuid.uuid4().hex[:8], time.time())
        self.rules = [r for r in self.rules if not (r.tool == rule.tool and r.scope == rule.scope)] + [rule]
        return rule

    def remove_rule(self, rule_id: str) -> bool:
        before = len(self.rules)
        self.rules = [r for r in self.rules if r.id != rule_id]
        return len(self.rules) != before

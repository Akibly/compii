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

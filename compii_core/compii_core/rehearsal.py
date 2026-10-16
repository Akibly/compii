"""Rehearsal brain: a scripted, non-AI stand-in used to test the app without API credentials.

The first request in a conversation always plays the same invoice task; follow-ups get a
canned reply. The app labels this mode clearly as a rehearsal.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .agent import BrainReply, ToolCall

PLAN = ["Find last month's invoices", "Build the spreadsheet", "Check it", "Email it to you"]


class RehearsalBrain:
    def __init__(self, downloads: Path, workspace: Path, email: str = "me@example.com") -> None:
        self.downloads = downloads
        self.workspace = workspace
        self.email = email

    async def step(self, system: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> BrainReply:
        # Position inside the current turn: assistant replies since the user's last typed message.
        starts = [i for i, m in enumerate(messages) if m["role"] == "user" and isinstance(m["content"], str)]
        turn = sum(1 for m in messages[starts[-1]:] if m["role"] == "assistant")
        if len(starts) > 1:
            text = f"(Rehearsal) With Claude connected I'd handle “{messages[starts[-1]]['content']}” here, using everything we did above."
            return BrainReply([{"type": "text", "text": text}], text, [], "end_turn")
        sheet = str(self.workspace / "Invoices last month.xlsx")
        if turn == 0:
            return self._plan("I'll find last month's invoices, build a spreadsheet and email it.", 0)
        if turn == 1:
            return self._call("Looking in Downloads.", "find_files",
                              {"folder": str(self.downloads), "pattern": "*invoice*", "modified_within_days": 31})
        if turn == 2:
            found = json.loads(_last_result(messages)).get("files", [])
            self._found = len(found)
            rows = [[Path(f["path"]).name, f["modified"][:10], f["size"]] for f in found]
            n = len(rows) + 1
            rows.append(["Total files", None, f"=COUNTA(A2:A{n})"])
            return self._call(f"Found {len(found)} invoice files.", "create_spreadsheet",
                              {"path": sheet, "sheets": [{"name": "Invoices", "header": ["File", "Date", "Size (bytes)"], "rows": rows}]})
        if turn == 3:
            return self._plan("", 2)
        if turn == 4:
            return self._call("Checking the spreadsheet.", "read_file", {"path": sheet})
        if turn == 5:
            return self._plan("", 3)
        if turn == 6:
            return self._call("Now the email.", "send_email",
                              {"to": [self.email], "subject": "Last month's invoices",
                               "body": "Here is the summary of last month's invoices.", "attachments": [sheet]})
        if turn == 7:
            return self._plan("", 4)
        text = ("Your invoice spreadsheet is ready. No mail account is connected, "
                "so I opened a ready email draft instead; press Send to send it.")
        return BrainReply([{"type": "text", "text": text}], text, [], "end_turn")

    def _plan(self, text: str, done: int) -> BrainReply:
        steps = [{"title": t, "status": "done" if i < done else "active" if i == done else "pending"}
                 for i, t in enumerate(PLAN)]
        return self._call(text, "update_plan", {"steps": steps})

    def _call(self, text: str, name: str, args: dict[str, Any]) -> BrainReply:
        call_id = f"rehearsal-{name}-{id(args)}"
        content = ([{"type": "text", "text": text}] if text else []) + [
            {"type": "tool_use", "id": call_id, "name": name, "input": args}]
        return BrainReply(content, text, [ToolCall(call_id, name, args)], "tool_use")


def _last_result(messages: list[dict[str, Any]]) -> str:
    for block in messages[-1]["content"]:
        if isinstance(block, dict) and block.get("type") == "tool_result":
            return block["content"]
    return "{}"

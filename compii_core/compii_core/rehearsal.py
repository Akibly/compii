"""Rehearsal brain: a scripted, non-AI stand-in used to test the app without API credentials.

It always plays the same invoice task, so the UI must label it as a rehearsal.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .agent import BrainReply, ToolCall


class RehearsalBrain:
    def __init__(self, downloads: Path, workspace: Path, email: str = "me@example.com") -> None:
        self.downloads = downloads
        self.workspace = workspace
        self.email = email

    async def step(self, system: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> BrainReply:
        turn = sum(1 for m in messages if m["role"] == "assistant")
        sheet = str(self.workspace / "Invoices last month.xlsx")
        if turn == 0:
            return self._call("I'll look for last month's invoices in Downloads.", "find_files",
                              {"folder": str(self.downloads), "pattern": "*invoice*", "modified_within_days": 31})
        if turn == 1:
            found = json.loads(_last_result(messages)).get("files", [])
            rows = [[Path(f["path"]).name, f["modified"][:10], f["size"]] for f in found]
            n = len(rows) + 1
            rows.append(["Total files", None, f"=COUNTA(A2:A{n})"])
            return self._call(f"Found {len(found)} invoice files. Building the spreadsheet.", "create_spreadsheet",
                              {"path": sheet, "sheets": [{"name": "Invoices", "header": ["File", "Date", "Size (bytes)"], "rows": rows}]})
        if turn == 2:
            return self._call("Checking the spreadsheet.", "read_file", {"path": sheet})
        if turn == 3:
            return self._call("Now the email.", "send_email",
                              {"to": [self.email], "subject": "Last month's invoices",
                               "body": "Here is the summary of last month's invoices.", "attachments": [sheet]})
        return BrainReply([{"type": "text", "text": "Done"}],
                          "The invoice spreadsheet is in your Compii folder. No mail account is connected, so I opened a ready email draft instead; press Send to send it.",
                          [], "end_turn")

    def _call(self, text: str, name: str, args: dict[str, Any]) -> BrainReply:
        call_id = f"rehearsal-{name}"
        content = [{"type": "text", "text": text}, {"type": "tool_use", "id": call_id, "name": name, "input": args}]
        return BrainReply(content, text, [ToolCall(call_id, name, args)], "tool_use")


def _last_result(messages: list[dict[str, Any]]) -> str:
    for block in messages[-1]["content"]:
        if isinstance(block, dict) and block.get("type") == "tool_result":
            return block["content"]
    return "{}"

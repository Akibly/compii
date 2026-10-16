"""Compii's hands: the tools the agent can use on this computer.

Each tool declares its action kind so the autonomy dial can decide whether to
ask first. File tools are limited to the folders the user allowed.
"""

from __future__ import annotations

import fnmatch
import json
import os
import shutil
import smtplib
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from email.message import EmailMessage
from pathlib import Path
from typing import Any

from .policy import ActionKind

MAX_RESULT_CHARS = 20_000


class ToolError(Exception):
    """A tool failed in a way the agent should hear about and can recover from."""


@dataclass
class ToolResult:
    text: str
    undo: dict[str, Any] | None = None


@dataclass
class Tool:
    name: str
    description: str
    properties: dict[str, Any]
    required: list[str]
    kind: ActionKind | Callable[[dict[str, Any]], ActionKind]
    run: Callable[[dict[str, Any]], ToolResult]
    describe: Callable[[dict[str, Any]], str]  # one human sentence for approvals and the task log

    def kind_for(self, args: dict[str, Any]) -> ActionKind:
        return self.kind(args) if callable(self.kind) else self.kind

    def schema(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "input_schema": {
                "type": "object",
                "properties": self.properties,
                "required": self.required,
                "additionalProperties": False,
            },
        }


class Toolbox:
    def __init__(self, roots: list[Path], workspace: Path, open_fn: Callable[[str], None] | None = None) -> None:
        self.workspace = workspace
        workspace.mkdir(parents=True, exist_ok=True)
        self.roots = [r.resolve() for r in [*roots, workspace] if r.exists()]
        self._open = open_fn or _default_open
        self.memory_path = workspace / "memory.jsonl"
        self.tools: dict[str, Tool] = {t.name: t for t in self._build()}

    # ---- path safety -------------------------------------------------------

    def path(self, raw: str) -> Path:
        p = Path(os.path.expandvars(os.path.expanduser(raw)))
        if not p.is_absolute():
            p = self.workspace / p
        p = p.resolve()
        if not any(p == r or r in p.parents for r in self.roots):
            allowed = ", ".join(str(r) for r in self.roots)
            raise ToolError(f"{p} is outside the folders Compii may use ({allowed}).")
        return p

    # ---- tool implementations ---------------------------------------------

    def list_folder(self, a: dict[str, Any]) -> ToolResult:
        p = self.path(a["path"])
        if not p.is_dir():
            raise ToolError(f"{p} is not a folder.")
        rows = []
        for c in sorted(p.iterdir(), key=lambda c: (not c.is_dir(), c.name.lower()))[:300]:
            st = c.stat()
            rows.append({
                "name": c.name + ("/" if c.is_dir() else ""),
                "size": st.st_size if c.is_file() else None,
                "modified": time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime)),
            })
        return ToolResult(json.dumps({"folder": str(p), "items": rows}))

    def find_files(self, a: dict[str, Any]) -> ToolResult:
        root = self.path(a["folder"])
        pattern = a.get("pattern") or "*"
        days = a.get("modified_within_days")
        cutoff = time.time() - days * 86400 if days else None
        walker = root.rglob("*") if a.get("recursive", True) else root.glob("*")
        hits = []
        for f in walker:
            if not f.is_file() or not fnmatch.fnmatch(f.name.lower(), pattern.lower()):
                continue
            st = f.stat()
            if cutoff and st.st_mtime < cutoff:
                continue
            hits.append({
                "path": str(f),
                "size": st.st_size,
                "modified": time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime)),
            })
            if len(hits) >= 200:
                break
        return ToolResult(json.dumps({"count": len(hits), "files": hits}))

    def read_file(self, a: dict[str, Any]) -> ToolResult:
        p = self.path(a["path"])
        if not p.is_file():
            raise ToolError(f"{p} does not exist.")
        suffix = p.suffix.lower()
        if suffix == ".pdf":
            from pypdf import PdfReader

            text = "\n\n".join((page.extract_text() or "") for page in PdfReader(p).pages)
        elif suffix in {".xlsx", ".xlsm"}:
            from openpyxl import load_workbook

            wb = load_workbook(p, data_only=True, read_only=True)
            parts = []
            for ws in wb.worksheets:
                parts.append(f"# Sheet {ws.title}")
                for row in ws.iter_rows(values_only=True):
                    parts.append("\t".join("" if v is None else str(v) for v in row))
            text = "\n".join(parts)
        else:
            text = p.read_text(encoding="utf-8", errors="replace")
        return ToolResult(text)

    def write_text_file(self, a: dict[str, Any]) -> ToolResult:
        p = self.path(a["path"])
        existed = p.exists()
        if existed and not a.get("overwrite"):
            raise ToolError(f"{p} already exists. Set overwrite to true to replace it.")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(a["content"], encoding="utf-8")
        return ToolResult(f"Wrote {p}", None if existed else {"op": "created", "path": str(p)})

    def create_folder(self, a: dict[str, Any]) -> ToolResult:
        p = self.path(a["path"])
        existed = p.exists()
        p.mkdir(parents=True, exist_ok=True)
        return ToolResult(f"Folder ready: {p}", None if existed else {"op": "created", "path": str(p)})

    def move_file(self, a: dict[str, Any]) -> ToolResult:
        src, dst = self.path(a["source"]), self.path(a["destination"])
        if not src.exists():
            raise ToolError(f"{src} does not exist.")
        if dst.is_dir():
            dst = dst / src.name
        if dst.exists():
            raise ToolError(f"{dst} already exists; choose another name.")
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), dst)
        return ToolResult(f"Moved {src} to {dst}", {"op": "move", "src": str(src), "dst": str(dst)})

    def create_spreadsheet(self, a: dict[str, Any]) -> ToolResult:
        from openpyxl import Workbook
        from openpyxl.styles import Font

        p = self.path(a["path"])
        if p.suffix.lower() != ".xlsx":
            p = p.with_suffix(".xlsx")
        if p.exists():
            raise ToolError(f"{p} already exists; choose another name.")
        wb = Workbook()
        wb.remove(wb.active)
        for sheet in a["sheets"]:
            ws = wb.create_sheet(sheet["name"][:31])
            ws.append(sheet["header"])
            for cell in ws[1]:
                cell.font = Font(bold=True)
            for row in sheet["rows"]:
                ws.append(row)
            for col in ws.columns:
                width = max(len(str(c.value or "")) for c in col)
                ws.column_dimensions[col[0].column_letter].width = min(max(10, width + 2), 60)
        p.parent.mkdir(parents=True, exist_ok=True)
        wb.save(p)
        return ToolResult(f"Saved spreadsheet {p}", {"op": "created", "path": str(p)})

    def run_python(self, a: dict[str, Any]) -> ToolResult:
        script = self.workspace / "scripts" / f"run-{int(time.time() * 1000)}.py"
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text(a["code"], encoding="utf-8")
        try:
            proc = subprocess.run(
                [sys.executable, "-I", str(script)],
                cwd=self.workspace,
                capture_output=True,
                text=True,
                timeout=120,
            )
        except subprocess.TimeoutExpired as e:
            raise ToolError("The script ran longer than 2 minutes and was stopped.") from e
        out = f"exit code {proc.returncode}\n--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
        if proc.returncode != 0:
            raise ToolError(out)
        return ToolResult(out)

    def open_item(self, a: dict[str, Any]) -> ToolResult:
        target = a["target"].strip()
        if target.startswith(("http://", "https://")):
            self._open(target)
            return ToolResult(f"Opened {target}")
        app = KNOWN_APPS.get(target.lower())
        if app:
            self._open(app)
            return ToolResult(f"Opened {target}")
        p = self.path(target)
        if not p.exists():
            raise ToolError(f"{p} does not exist.")
        if p.suffix.lower() in {".exe", ".bat", ".cmd", ".ps1", ".vbs", ".msi", ".lnk"}:
            raise ToolError("Compii does not launch programs from files. Name a known app instead.")
        self._open(str(p))
        return ToolResult(f"Opened {p}")

    def send_email(self, a: dict[str, Any]) -> ToolResult:
        msg = EmailMessage()
        msg["To"] = ", ".join(a["to"])
        msg["Subject"] = a["subject"]
        msg.set_content(a["body"])
        for raw in a.get("attachments", []):
            p = self.path(raw)
            msg.add_attachment(p.read_bytes(), maintype="application", subtype="octet-stream", filename=p.name)
        host = os.environ.get("COMPII_SMTP_HOST")
        if host:
            msg["From"] = os.environ.get("COMPII_SMTP_FROM") or os.environ.get("COMPII_SMTP_USER", "")
            with smtplib.SMTP(host, int(os.environ.get("COMPII_SMTP_PORT", "587")), timeout=30) as s:
                s.starttls()
                if os.environ.get("COMPII_SMTP_USER"):
                    s.login(os.environ["COMPII_SMTP_USER"], os.environ.get("COMPII_SMTP_PASSWORD", ""))
                s.send_message(msg)
            return ToolResult(f"Sent email to {msg['To']}")
        # No mail account connected yet: hand a ready draft to the default mail app.
        msg["X-Unsent"] = "1"
        draft = self.workspace / "outbox" / f"draft-{int(time.time())}.eml"
        draft.parent.mkdir(parents=True, exist_ok=True)
        draft.write_bytes(bytes(msg))
        self._open(str(draft))
        return ToolResult(
            f"No mail account is connected, so the email was NOT sent. A ready draft to {msg['To']} "
            f"was opened in the default mail app ({draft}); the user must press Send."
        )

    def remember(self, a: dict[str, Any]) -> ToolResult:
        with self.memory_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps({"fact": a["fact"], "at": time.time()}) + "\n")
        return ToolResult(f"Remembered: {a['fact']}")

    def recall(self, a: dict[str, Any]) -> ToolResult:
        if not self.memory_path.exists():
            return ToolResult("No memories saved yet.")
        words = [w for w in a.get("query", "").lower().split() if len(w) > 2]
        facts = [json.loads(line)["fact"] for line in self.memory_path.read_text(encoding="utf-8").splitlines() if line]
        hits = [f for f in facts if not words or any(w in f.lower() for w in words)]
        return ToolResult("\n".join(f"- {f}" for f in hits[-50:]) or "Nothing relevant remembered.")

    # ---- registry -----------------------------------------------------------

    def _build(self) -> list[Tool]:
        s = {"type": "string"}
        return [
            Tool("list_folder", "List the files and folders inside a folder, with sizes and modified dates.",
                 {"path": {**s, "description": "Folder path; ~ is the user's home."}}, ["path"],
                 ActionKind.READ, self.list_folder, lambda a: f"Look inside {_short(a['path'])}"),
            Tool("find_files", "Find files by name pattern (e.g. *.pdf, *invoice*) under a folder, optionally only recently modified ones.",
                 {"folder": s, "pattern": {**s, "description": "Glob on the file name, case-insensitive."},
                  "modified_within_days": {"type": "integer"}, "recursive": {"type": "boolean"}},
                 ["folder"], ActionKind.READ, self.find_files,
                 lambda a: f"Search {_short(a['folder'])} for {a.get('pattern') or 'files'}"),
            Tool("read_file", "Read a file's contents. Handles text, PDF and Excel files.",
                 {"path": s}, ["path"], ActionKind.READ, self.read_file, lambda a: f"Read {_short(a['path'])}"),
            Tool("write_text_file", "Write a text file (notes, CSV, Markdown, code). Refuses to replace an existing file unless overwrite is true.",
                 {"path": s, "content": s, "overwrite": {"type": "boolean"}}, ["path", "content"],
                 lambda a: ActionKind.CHANGE if a.get("overwrite") else ActionKind.CREATE,
                 self.write_text_file, lambda a: f"Write {_short(a['path'])}"),
            Tool("create_folder", "Create a folder.", {"path": s}, ["path"], ActionKind.CREATE,
                 self.create_folder, lambda a: f"Create folder {_short(a['path'])}"),
            Tool("move_file", "Move or rename a file or folder. Can be undone.",
                 {"source": s, "destination": s}, ["source", "destination"], ActionKind.CHANGE,
                 self.move_file, lambda a: f"Move {_short(a['source'])} to {_short(a['destination'])}"),
            Tool("create_spreadsheet", "Create an Excel (.xlsx) workbook. Cells starting with '=' are formulas, e.g. =SUM(B2:B9).",
                 {"path": s, "sheets": {"type": "array", "items": {
                     "type": "object",
                     "properties": {"name": s, "header": {"type": "array", "items": s},
                                    "rows": {"type": "array", "items": {"type": "array", "items": {"type": ["string", "number", "null"]}}}},
                     "required": ["name", "header", "rows"], "additionalProperties": False}}},
                 ["path", "sheets"], ActionKind.CREATE, self.create_spreadsheet,
                 lambda a: f"Create spreadsheet {_short(a['path'])}"),
            Tool("run_python", "Run a Python script in Compii's workspace folder and return its output. Use for calculations, data processing and file conversions the other tools can't do.",
                 {"code": s}, ["code"], ActionKind.CHANGE, self.run_python,
                 lambda a: "Run a Python script"),
            Tool("open_item", "Open a file or folder in its default app, a web address in the browser, or a known app ("
                 + ", ".join(sorted(KNOWN_APPS)) + ").",
                 {"target": s}, ["target"], ActionKind.CREATE, self.open_item, lambda a: f"Open {a['target']}"),
            Tool("send_email", "Send an email, optionally with attachments. Always state the exact recipients, subject and body.",
                 {"to": {"type": "array", "items": s}, "subject": s, "body": s, "attachments": {"type": "array", "items": s}},
                 ["to", "subject", "body"], ActionKind.SEND, self.send_email,
                 lambda a: f"Email {', '.join(a['to'])}: “{a['subject']}”"
                 + (f" with {len(a.get('attachments', []))} attachment(s)" if a.get("attachments") else "")),
            Tool("remember", "Save a durable fact about the user (preferences, people, projects) for future tasks.",
                 {"fact": s}, ["fact"], ActionKind.CREATE, self.remember, lambda a: f"Remember: {a['fact']}"),
            Tool("recall", "Look up facts previously saved about the user.", {"query": s}, ["query"],
                 ActionKind.READ, self.recall, lambda a: f"Recall {a['query']}"),
        ]

    def execute(self, name: str, args: dict[str, Any]) -> ToolResult:
        tool = self.tools.get(name)
        if tool is None:
            raise ToolError(f"Unknown tool {name}.")
        missing = [r for r in tool.required if r not in args]
        if missing:
            raise ToolError(f"Missing required input(s): {', '.join(missing)}.")
        result = tool.run(args)
        if len(result.text) > MAX_RESULT_CHARS:
            result.text = result.text[:MAX_RESULT_CHARS] + f"\n[truncated: {len(result.text)} characters total]"
        return result


KNOWN_APPS = {
    "notepad": "notepad.exe",
    "calculator": "calc.exe",
    "file explorer": "explorer.exe",
    "paint": "mspaint.exe",
    "excel": "excel.exe",
    "word": "winword.exe",
    "powerpoint": "powerpnt.exe",
    "outlook": "outlook.exe",
    "chrome": "chrome.exe",
    "edge": "msedge.exe",
}


def _short(raw: str) -> str:
    """File or folder name for labels; full paths stay in the approval details."""
    return Path(raw).name or raw


def _default_open(target: str) -> None:
    if sys.platform == "win32":
        os.startfile(target)  # noqa: S606 - opening user-approved items is the point
    else:
        subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", target])


def default_roots() -> list[Path]:
    home = Path.home()
    return [home / d for d in ("Downloads", "Documents", "Desktop", "Pictures")]

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
from dataclasses import dataclass, field
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
    point: dict[str, Any] | None = None  # something on screen for the character to point at
    plan: list[dict[str, str]] | None = None  # the checklist the user watches
    files: list[tuple[str, str]] = field(default_factory=list)  # (path, "created" | "changed" | "moved")


@dataclass
class Tool:
    name: str
    description: str
    properties: dict[str, Any]
    required: list[str]
    kind: ActionKind | Callable[[dict[str, Any]], ActionKind]
    run: Callable[[dict[str, Any]], ToolResult]
    describe: Callable[[dict[str, Any]], str]  # one human sentence for approvals and the task log
    long_running: bool = False  # gets a "_halt" event so it can stop with its task

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
        from . import screen

        self.screen = screen  # swappable in tests
        self._browser = None
        # Called with a screen rectangle just before Compii clicks or types there,
        # so the character can point at it ("watch me").
        self.on_point: Callable[[dict[str, Any]], None] | None = None
        # The latest screen snapshot (screen-aware turns): point_at accepts its ids.
        self.snapshot: dict[str, Any] | None = None
        self.tools: dict[str, Tool] = {t.name: t for t in self._build()}

    @property
    def browser(self):
        if self._browser is None:
            from .browser import Browser

            self._browser = Browser(self.workspace / "browser-profile")
        return self._browser

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
        return ToolResult(f"Wrote {p}", None if existed else {"op": "created", "path": str(p)},
                          files=[(str(p), "changed" if existed else "created")])

    def create_folder(self, a: dict[str, Any]) -> ToolResult:
        p = self.path(a["path"])
        existed = p.exists()
        p.mkdir(parents=True, exist_ok=True)
        return ToolResult(f"Folder ready: {p}", None if existed else {"op": "created", "path": str(p)},
                          files=[] if existed else [(str(p), "created")])

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
        return ToolResult(f"Moved {src} to {dst}", {"op": "move", "src": str(src), "dst": str(dst)},
                          files=[(str(dst), "moved")])

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
        return ToolResult(f"Saved spreadsheet {p}", {"op": "created", "path": str(p)}, files=[(str(p), "created")])

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
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),  # never flash a console window
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
            f"was opened in the default mail app ({draft}); the user must press Send.",
            files=[(str(draft), "drafted")],
        )

    # ---- hands: Windows apps ------------------------------------------------------

    def _show(self, found: Any, message: str) -> None:
        if self.on_point:
            self.on_point({**found.as_event(), "message": message})
            time.sleep(0.7)  # let the user see where Compii is about to act

    def _screen_call(self, fn: Callable[[], Any]) -> Any:
        from .screen import ScreenError

        try:
            return fn()
        except ScreenError as e:
            raise ToolError(str(e)) from e

    def list_windows(self, a: dict[str, Any]) -> ToolResult:
        wins = self._screen_call(self.screen.list_windows)
        return ToolResult("\n".join(f"- {w['title']}" for w in wins) or "No windows are open.")

    def focus_window(self, a: dict[str, Any]) -> ToolResult:
        title = self._screen_call(lambda: self.screen.focus_window(a["window"]))
        return ToolResult(f"Switched to “{title}”.")

    def read_window(self, a: dict[str, Any]) -> ToolResult:
        return ToolResult(self._screen_call(lambda: self.screen.read_window(a.get("window"))))

    def click_on(self, a: dict[str, Any]) -> ToolResult:
        found = self._screen_call(lambda: self.screen.click(
            a["target"], a.get("window"), before=lambda f: self._show(f, f"Clicking “{a['target']}”")))
        return ToolResult(f"Clicked {found.role.replace('Control', '').lower()} “{found.name}” in “{found.window}”.")

    def type_into(self, a: dict[str, Any]) -> ToolResult:
        _refuse_secrets(a.get("target") or "", a["text"])
        found = self._screen_call(lambda: self.screen.type_text(
            a["text"], a.get("target"), a.get("window"),
            before=lambda f: self._show(f, f"Typing into “{a.get('target')}”")))
        where = f"“{found.name}” in “{found.window}”" if found else "the active window"
        return ToolResult(f"Typed {len(a['text'])} characters into {where}.")

    def press_keys(self, a: dict[str, Any]) -> ToolResult:
        title = self._screen_call(lambda: self.screen.press_keys(a["keys"], a.get("window")))
        return ToolResult(f"Pressed {a['keys']}" + (f" in “{title}”." if title else "."))

    # ---- hands: the web (Compii's own Edge window) ---------------------------------

    def _browser_call(self, fn: Callable[[], str]) -> ToolResult:
        from .browser import BrowserError

        try:
            return ToolResult(fn())
        except BrowserError as e:
            raise ToolError(str(e)) from e

    def browse(self, a: dict[str, Any]) -> ToolResult:
        return self._browser_call(lambda: self.browser.open(a["url"]))

    def read_page(self, a: dict[str, Any]) -> ToolResult:
        return self._browser_call(self.browser.read)

    def browser_click(self, a: dict[str, Any]) -> ToolResult:
        return self._browser_call(lambda: self.browser.click(a["text"]))

    def browser_fill(self, a: dict[str, Any]) -> ToolResult:
        _refuse_secrets(a["field"], a["value"])
        return self._browser_call(lambda: self.browser.fill(a["field"], a["value"], bool(a.get("submit"))))

    def point_at(self, a: dict[str, Any]) -> ToolResult:
        found = self._from_snapshot(a["target"]) or self._find(a["target"])
        if found is None:
            raise ToolError(
                f"Couldn't find anything named “{a['target']}” in the open windows. "
                "Try the exact label shown on screen."
            )
        point = {**found.as_event(), "message": a.get("message", "")}
        return ToolResult(
            f"Pointing at {found.role} “{found.name}” in “{found.window}” "
            f"at x={point['x']}, y={point['y']} ({point['w']}x{point['h']}).",
            point=point,
        )

    def _from_snapshot(self, target: str):
        """An item id (e12) from the screen snapshot, so the AI never has to guess pixels."""
        import re

        snap = self.snapshot
        if not snap or not re.fullmatch(r"e\d+", target.strip()):
            return None
        from .screen import Found

        for e in snap.get("elements", []):
            if e["id"] == target.strip():
                return Found(e["name"], e["role"], snap.get("title", ""), e["x"], e["y"], e["x"] + e["w"], e["y"] + e["h"])
        return None

    def _find(self, target: str):  # indirection so tests can stub the screen
        from .screen import find_element

        return find_element(target)

    def update_plan(self, a: dict[str, Any]) -> ToolResult:
        steps = [
            {"title": str(st.get("title", "")).strip(), "status": st.get("status", "pending")}
            for st in a["steps"]
            if str(st.get("title", "")).strip()
        ]
        for st in steps:
            if st["status"] not in ("pending", "active", "done", "skipped"):
                st["status"] = "pending"
        return ToolResult("Plan shown to the user.", plan=steps)

    def memories(self) -> list[dict[str, Any]]:
        if not self.memory_path.exists():
            return []
        out = []
        for i, line in enumerate(self.memory_path.read_text(encoding="utf-8").splitlines()):
            if line.strip():
                d = json.loads(line)
                out.append({"id": i, "fact": d["fact"], "at": d.get("at")})
        return out

    def forget(self, memory_id: int) -> bool:
        if not self.memory_path.exists():
            return False
        lines = self.memory_path.read_text(encoding="utf-8").splitlines()
        if not 0 <= memory_id < len(lines) or not lines[memory_id].strip():
            return False
        lines[memory_id] = ""  # keep line numbers stable for the other ids
        self.memory_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return True

    def remember(self, a: dict[str, Any]) -> ToolResult:
        with self.memory_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps({"fact": a["fact"], "at": time.time()}) + "\n")
        return ToolResult(f"Remembered: {a['fact']}")

    def recall(self, a: dict[str, Any]) -> ToolResult:
        if not self.memory_path.exists():
            return ToolResult("No memories saved yet.")
        words = [w for w in a.get("query", "").lower().split() if len(w) > 2]
        facts = [m["fact"] for m in self.memories()]
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
            Tool("list_windows", "List the windows open on the user's screen.", {}, [], ActionKind.READ,
                 self.list_windows, lambda a: "Look at open windows"),
            Tool("focus_window", "Bring a window to the front, by part of its title.",
                 {"window": s}, ["window"], ActionKind.CREATE, self.focus_window,
                 lambda a: f"Switch to {a['window']}"),
            Tool("read_window", "Read the text, buttons, menus and fields of a window (the topmost one if no title given). "
                 "Use it to see exact labels before clicking or typing.",
                 {"window": {**s, "description": "Part of the window title, optional."}}, [], ActionKind.READ,
                 self.read_window, lambda a: f"Read {a.get('window') or 'the window'}"),
            Tool("click_on", "Click a button, menu, tab, link or checkbox in a Windows app by its visible label. "
                 "The user sees Compii point at it first.",
                 {"target": s, "window": {**s, "description": "Part of the window title, optional."}}, ["target"],
                 ActionKind.CHANGE, self.click_on,
                 lambda a: f"Click “{a['target']}”" + (f" in {a['window']}" if a.get("window") else "")),
            Tool("type_into", "Type text into a field of a Windows app, found by its label; without a target, types where the cursor is. "
                 "Never type passwords, card numbers or one-time codes.",
                 {"text": s, "target": {**s, "description": "The field's label, optional."},
                  "window": {**s, "description": "Part of the window title, optional."}}, ["text"],
                 ActionKind.CHANGE, self.type_into,
                 lambda a: f"Type into {a.get('target') or 'the active window'}"),
            Tool("press_keys", "Press a key or shortcut, e.g. 'ctrl+s', 'enter', 'alt+tab', 'f5'.",
                 {"keys": s, "window": {**s, "description": "Part of the window title to send them to, optional."}}, ["keys"],
                 ActionKind.CHANGE, self.press_keys, lambda a: f"Press {a['keys']}"),
            Tool("browse", "Open a web page in Compii's own browser window (separate from the user's browser) and read it.",
                 {"url": s}, ["url"], ActionKind.READ, self.browse, lambda a: f"Open {a['url']}"),
            Tool("read_page", "Read the page currently open in Compii's browser.", {}, [], ActionKind.READ,
                 self.read_page, lambda a: "Read the page"),
            Tool("browser_click", "Click a button, link or tab on the page in Compii's browser, by its visible text.",
                 {"text": s}, ["text"], ActionKind.CHANGE, self.browser_click, lambda a: f"Click “{a['text']}” on the page"),
            Tool("browser_fill", "Fill a field on the page in Compii's browser, by its label or placeholder; "
                 "submit=true also presses Enter (this counts as sending and always asks the user). "
                 "Never fill passwords, card numbers or one-time codes: ask the user to do that in the browser window.",
                 {"field": s, "value": s, "submit": {"type": "boolean"}}, ["field", "value"],
                 lambda a: ActionKind.SEND if a.get("submit") else ActionKind.CHANGE, self.browser_fill,
                 lambda a: f"Fill “{a['field']}”" + (" and submit" if a.get("submit") else "")),
            Tool("point_at", "Point at a button, menu, field or other item in the user's open windows, by its visible label, "
                 "with a short message in a speech bubble. Use it when teaching or when showing the user where something is.",
                 {"target": {**s, "description": "The item's id from the screen snapshot (e.g. 'e12'), or its visible label, e.g. 'Save'."},
                  "message": {**s, "description": "One short sentence for the speech bubble."}},
                 ["target", "message"], ActionKind.READ, self.point_at,
                 lambda a: f"Point at “{a['target']}”"),
            Tool("update_plan", "Show the user your plan as a checklist, and update it as you go. "
                 "Call it before multi-step work and again when a step starts or finishes.",
                 {"steps": {"type": "array", "items": {
                     "type": "object",
                     "properties": {"title": {"type": "string", "description": "Short step, under 8 words."},
                                    "status": {"type": "string", "enum": ["pending", "active", "done", "skipped"]}},
                     "required": ["title", "status"], "additionalProperties": False}}},
                 ["steps"], ActionKind.READ, self.update_plan,
                 lambda a: "Update plan"),
            Tool("remember", "Save a durable fact about the user (preferences, people, projects) for future tasks.",
                 {"fact": s}, ["fact"], ActionKind.CREATE, self.remember, lambda a: f"Remember: {a['fact']}"),
            Tool("recall", "Look up facts previously saved about the user.", {"query": s}, ["query"],
                 ActionKind.READ, self.recall, lambda a: f"Recall {a['query']}"),
        ]

    def execute(self, name: str, args: dict[str, Any], halt: Any = None) -> ToolResult:
        tool = self.tools.get(name)
        if tool is None:
            raise ToolError(f"Unknown tool {name}.")
        missing = [r for r in tool.required if r not in args]
        if missing:
            raise ToolError(f"Missing required input(s): {', '.join(missing)}.")
        result = tool.run({**args, "_halt": halt}) if tool.long_running else tool.run(args)
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


_SECRET_FIELD = (
    r"\b(password|passcode|passphrase|pin|cvv|cvc|otp|2fa|mfa)\b|card number|card no|security code|"
    r"one[- ]time|verification code|sort code|iban|routing number|social security"
)


def _refuse_secrets(field: str, value: str) -> None:
    """Compii never types passwords, payment details or one-time codes."""
    import re

    if re.search(_SECRET_FIELD, field.lower()) or re.fullmatch(r"[\d\s-]{13,23}", value.strip() or "x"):
        raise ToolError(
            "That looks like a password, payment detail or one-time code. Compii doesn't type those; "
            "ask the user to enter it themselves, then continue."
        )

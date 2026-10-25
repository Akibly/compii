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
import threading
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


DRAW_KINDS = ("circle", "underline", "box", "arrow")

# A screen read that couldn't happen: Compii says less rather than guessing.
UNCHECKED = object()


@dataclass
class ToolResult:
    text: str
    undo: dict[str, Any] | None = None
    point: dict[str, Any] | None = None  # something on screen for the character to point at
    plan: list[dict[str, str]] | None = None  # the checklist the user watches
    files: list[tuple[str, str]] = field(default_factory=list)  # (path, "created" | "changed" | "moved")
    # Real web pages this action read, so an answer built on them can show its sources.
    sources: list[dict[str, str]] = field(default_factory=list)


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
        # forget() rewrites the whole file; remember() appends to it. Without this, a forget
        # in flight can drop a fact remembered a moment later.
        self._memory_lock = threading.Lock()
        from . import screen

        self.screen = screen  # swappable in tests
        self._browser = None
        # Called with a screen rectangle just before Compii clicks or types there,
        # so the character can point at it ("watch me").
        self.on_point: Callable[[dict[str, Any]], None] | None = None
        self.on_draw: Callable[[dict[str, Any]], None] | None = None  # marker drawings on the overlay
        # Finds an item in a picture of the window (set by the server when vision is available).
        self.see_item: Callable[[str], dict[str, Any] | None] | None = None
        # Reads the screen by picture: (question, whole screen?) -> {"text", "snap"} or None.
        self.read_screen: Callable[..., dict[str, Any] | None] | None = None
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
        return ToolResult(self._file_text(p))

    def _file_text(self, p: Path) -> str:
        """The words inside a file, whatever kind it is."""
        suffix = p.suffix.lower()
        if suffix == ".pdf":
            from pypdf import PdfReader

            return "\n\n".join((page.extract_text() or "") for page in PdfReader(p).pages)
        if suffix == ".docx":
            from .documents import docx_text

            return docx_text(p)
        if suffix in {".xlsx", ".xlsm"}:
            from openpyxl import load_workbook

            wb = load_workbook(p, data_only=True, read_only=True)
            parts = []
            for ws in wb.worksheets:
                parts.append(f"# Sheet {ws.title}")
                for row in ws.iter_rows(values_only=True):
                    parts.append("\t".join("" if v is None else str(v) for v in row))
            return "\n".join(parts)
        return p.read_text(encoding="utf-8", errors="replace")

    # A folder can hold anything: only look inside files that really are text.
    SEARCHABLE = {".txt", ".md", ".csv", ".tsv", ".json", ".xml", ".html", ".htm", ".log", ".ini", ".cfg",
                  ".yaml", ".yml", ".toml", ".py", ".js", ".ts", ".css", ".srt", ".vtt", ".eml", ".bat",
                  ".ps1", ".tex", ".rtf", ".pdf", ".docx", ".xlsx", ".xlsm"}

    def search_in_files(self, a: dict[str, Any]) -> ToolResult:
        root = self.path(a["folder"])
        if not root.is_dir():
            raise ToolError(f"{root} is not a folder.")
        needle = str(a["text"]).lower()
        name_pat = (a.get("pattern") or "*").lower()
        walker = root.rglob("*") if a.get("recursive", True) else root.glob("*")
        limit = int(a.get("max_results") or 40)
        hits = []
        for f in walker:
            if len(hits) >= limit:
                break
            if not f.is_file() or f.suffix.lower() not in self.SEARCHABLE:
                continue
            if not fnmatch.fnmatch(f.name.lower(), name_pat):
                continue
            try:
                if f.stat().st_size > 8_000_000:
                    continue
                text = self._file_text(f)
            except Exception:  # noqa: BLE001 - an unreadable file is simply not a match
                continue
            for n, line in enumerate(text.splitlines(), start=1):
                if needle in line.lower():
                    hits.append({"path": str(f), "line": n, "match": line.strip()[:200]})
                    break  # one line per file: wider is more useful than deeper
        return ToolResult(json.dumps({"folder": str(root), "text": a["text"], "count": len(hits), "hits": hits}))

    MAX_COMPARE_LINES = 20_000

    def compare_documents(self, a: dict[str, Any]) -> ToolResult:
        import difflib

        pa, pb = self.path(a["path_a"]), self.path(a["path_b"])
        for p in (pa, pb):
            if not p.is_file():
                raise ToolError(f"{p} does not exist.")
        baggier = str(a.get("ignore") or "")
        loose_space = "space" in baggier or baggier == "all"
        loose_case = "case" in baggier or baggier == "all"

        def lines(p: Path) -> tuple[list[str], bool]:
            text = self._file_text(p)
            rows = text.splitlines()
            cut = len(rows) > self.MAX_COMPARE_LINES
            out = []
            for row in rows[: self.MAX_COMPARE_LINES]:
                line = " ".join(row.split()) if loose_space else row.strip()
                out.append(line.lower() if loose_case else line)
            return out, cut

        x, xc = lines(pa)
        y, yc = lines(pb)
        sm = difflib.SequenceMatcher(None, x, y, autojunk=False)
        only_first = only_second = changed = 0
        diffs: list[dict[str, Any]] = []
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag == "equal":
                continue
            if tag == "replace":
                changed += max(i2 - i1, j2 - j1)
                kind = "changed"
            elif tag == "delete":
                only_first += i2 - i1
                kind = "only in the first"
            else:
                only_second += j2 - j1
                kind = "only in the second"
            context = next((t for t in reversed(x[max(0, i1 - 3):i1]) if t), "")
            diffs.append({
                "near": f"line {i1 + 1} of the first" if kind != "only in the second" else
                        f"line {j1 + 1} of the second",
                "after": context[:160],
                "kind": kind,
                "first": [t for t in x[i1:i2] if t][:3],
                "second": [t for t in y[j1:j2] if t][:3],
            })
        limit = max(1, min(40, int(a.get("max_differences") or 20)))
        same = not diffs
        return ToolResult(json.dumps({
            "first": str(pa), "second": str(pb),
            "identical": same,
            "similarity": round(sm.ratio(), 3),
            "counts": {"only_in_first": only_first, "only_in_second": only_second, "changed": changed},
            "compared_lines": {"first": len(x), "second": len(y)},
            "truncated": xc or yc,
            "ignored": baggier or "nothing",
            "differences": diffs[:limit],
            "difference_groups": len(diffs),
            "note": ("Read as words: a PDF, Word or Excel file is compared by the text inside it, not by layout."
                     if pa.suffix.lower() in self.SEARCHABLE or pb.suffix.lower() in self.SEARCHABLE else ""),
        }))

    DUP_SKIP_DIRS = {"node_modules", "__pycache__", "AppData", "$RECYCLE.BIN", "System Volume Information"}
    DUP_MAX_FILES = 30_000

    def find_duplicate_files(self, a: dict[str, Any]) -> ToolResult:
        import hashlib

        root = self.path(a["folder"])
        if not root.is_dir():
            raise ToolError(f"{root} is not a folder.")
        min_mb = 1.0 if a.get("min_size_mb") is None else float(a["min_size_mb"])
        min_bytes = max(0, int(min_mb * 1_000_000))
        pattern = (a.get("pattern") or "*").lower()

        by_size: dict[int, list[Path]] = {}
        scanned = 0
        unreadable = 0
        stopped = False
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in self.DUP_SKIP_DIRS and not d.startswith(".")]
            for name in filenames:
                if not fnmatch.fnmatch(name.lower(), pattern):
                    continue
                f = Path(dirpath) / name
                try:
                    if f.is_symlink() or not f.is_file():
                        continue
                    st = f.stat()
                    if st.st_size < min_bytes:
                        continue
                except OSError:
                    unreadable += 1
                    continue
                scanned += 1
                if scanned > self.DUP_MAX_FILES:
                    stopped = True
                    break
                by_size.setdefault(st.st_size, []).append(f)
            if stopped:
                break

        def digest(f: Path, head_only: bool) -> str | None:
            h = hashlib.sha256()
            try:
                with f.open("rb") as fh:
                    h.update(fh.read(65536))
                    if not head_only:
                        while chunk := fh.read(1 << 20):
                            h.update(chunk)
            except OSError:
                return None
            return h.hexdigest()

        groups: list[dict[str, Any]] = []
        for size, files in sorted(by_size.items(), key=lambda kv: -kv[0] * (len(kv[1]) - 1)):
            if len(files) < 2:
                continue
            heads: dict[str, list[Path]] = {}
            for f in files:
                d = digest(f, head_only=True)
                if d:
                    heads.setdefault(d, []).append(f)
            full: dict[str, list[Path]] = {}
            for same_head in heads.values():
                if len(same_head) < 2:
                    continue
                for f in same_head:
                    d = digest(f, head_only=False)
                    if d:
                        full.setdefault(d, []).append(f)
            for paths in full.values():
                if len(paths) > 1:
                    groups.append({"size": size, "count": len(paths), "wasted": size * (len(paths) - 1),
                                   "paths": [str(p) for p in sorted(paths, key=lambda p: p.name.lower())]})
        groups.sort(key=lambda g: -g["wasted"])
        shown = groups[: int(a.get("max_groups") or 25)]
        wasted = sum(g["wasted"] for g in groups)
        return ToolResult(json.dumps({
            "folder": str(root), "files_checked": scanned, "duplicate_groups": len(groups),
            "wasted_bytes": wasted,
            "pattern": a.get("pattern") or "*", "min_size_mb": min_mb,
            "skipped": {"unreadable": unreadable, "system_folders": True},
            "stopped_early": stopped,
            "groups": shown,
            "note": "Nothing was deleted or moved. Each group is listed A to Z; choose which copy to keep.",
        }))

    def move_to_trash(self, a: dict[str, Any]) -> ToolResult:
        p = self.path(a["path"])
        if not p.exists():
            raise ToolError(f"{p} does not exist.")
        _recycle(p)
        return ToolResult(f"Sent {p.name} to the Recycle Bin. Restore it from there if you need it back.",
                          files=[(str(p), "deleted")])

    def zip_files(self, a: dict[str, Any]) -> ToolResult:
        import zipfile

        dest = self.path(a["destination"])
        if dest.suffix.lower() != ".zip":
            dest = dest.with_suffix(".zip")
        if dest.exists():
            raise ToolError(f"{dest} already exists; choose another name.")
        items = [self.path(raw) for raw in a["items"]]
        for p in items:
            if not p.exists():
                raise ToolError(f"{p} does not exist.")
        dest.parent.mkdir(parents=True, exist_ok=True)
        files = 0
        with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
            for p in items:
                if p.is_dir():
                    for f in sorted(p.rglob("*")):
                        if f.is_file():
                            z.write(f, (p.name / f.relative_to(p)).as_posix())
                            files += 1
                else:
                    z.write(p, p.name)
                    files += 1
        return ToolResult(f"Packed {files} file(s) from {len(items)} item(s) into {dest}.",
                          {"op": "created", "path": str(dest)}, files=[(str(dest), "created")])

    def unzip(self, a: dict[str, Any]) -> ToolResult:
        import zipfile

        src = self.path(a["zip"])
        if not src.is_file() or src.suffix.lower() != ".zip":
            raise ToolError(f"{src} is not a .zip file.")
        into = self.path(a.get("into") or str(src.with_suffix("")))
        if into.exists() and any(into.iterdir()):
            raise ToolError(f"{into} already has files in it; choose another folder.")
        with zipfile.ZipFile(src) as z:
            root = into.resolve()
            names = z.namelist()
            for name in names:
                # A hand-made zip can name a path that climbs out of the folder ("zip slip").
                if not (root / name).resolve().is_relative_to(root):
                    raise ToolError(f"“{name}” in that zip points outside {into}, so Compii left it alone.")
            if sum(i.file_size for i in z.infolist()) > 500_000_000:
                raise ToolError("That zip unpacks to more than 500 MB, which is more than Compii writes at once.")
            z.extractall(into)
        return ToolResult(f"Unpacked {len(names)} item(s) into {into}.", files=[(str(into), "created")])

    def merge_pdfs(self, a: dict[str, Any]) -> ToolResult:
        """Join several PDFs into one new file, keeping their order."""
        from pypdf import PdfWriter

        raw = a["inputs"]
        if len(raw) < 2:
            raise ToolError("Give at least two PDFs to merge.")
        inputs = [self.path(x) for x in raw]
        for p in inputs:
            _check_pdf(p)
        dest = self.path(a["destination"])
        if dest.suffix.lower() != ".pdf":
            dest = dest.with_suffix(".pdf")
        if dest.exists():
            raise ToolError(f"{dest} already exists; choose another name.")
        dest.parent.mkdir(parents=True, exist_ok=True)
        writer = PdfWriter()
        pages = 0
        for p in inputs:
            reader = _pdf_reader(p)
            writer.append(reader)
            pages += len(reader.pages)
        with dest.open("wb") as f:
            writer.write(f)
        return ToolResult(f"Merged {len(inputs)} PDFs ({pages} pages) into {dest}.",
                          {"op": "created", "path": str(dest)}, files=[(str(dest), "created")])

    def split_pdf(self, a: dict[str, Any]) -> ToolResult:
        """Take pages out of a PDF: a chosen range into one new file, or every page on its own."""
        from pypdf import PdfWriter

        src = self.path(a["pdf"])
        _check_pdf(src)
        reader = _pdf_reader(src)
        count = len(reader.pages)
        spec = (a.get("pages") or "").strip()
        dest_raw = (a.get("destination") or "").strip()
        if spec:
            picked = _page_indexes(spec, count)
            dest = self.path(dest_raw) if dest_raw else src.with_name(f"{src.stem} - pages.pdf")
            if dest.suffix.lower() != ".pdf":
                dest = dest.with_suffix(".pdf")
            if dest == src:
                raise ToolError("Choose a different name; splitting must not overwrite the original.")
            if dest.exists():
                raise ToolError(f"{dest} already exists; choose another name.")
            dest.parent.mkdir(parents=True, exist_ok=True)
            with dest.open("wb") as f:
                writer = PdfWriter()
                for i in picked:
                    writer.add_page(reader.pages[i])
                writer.write(f)
            return ToolResult(f"Saved {_pages_text(picked)} of {src.name} ({count} pages) to {dest}.",
                              {"op": "created", "path": str(dest)}, files=[(str(dest), "created")])
        into = self.path(dest_raw) if dest_raw else src.with_name(src.stem)
        if into.suffix.lower() == ".pdf":
            raise ToolError("Without pages, the destination is a folder for one file per page.")
        if into.exists() and (not into.is_dir() or any(into.iterdir())):
            raise ToolError(f"{into} already has files in it; choose another folder.")
        into.mkdir(parents=True, exist_ok=True)
        made = []
        for i in range(count):
            out = into / f"{src.stem} - page {i + 1}.pdf"
            with out.open("wb") as f:
                writer = PdfWriter()
                writer.add_page(reader.pages[i])
                writer.write(f)
            made.append((str(out), "created"))
        return ToolResult(f"Split {src.name} into {count} single-page PDF(s) in {into}.",
                          {"op": "created", "path": str(into)}, files=made)

    def read_pdf(self, a: dict[str, Any]) -> ToolResult:
        """The words on a PDF's pages, page by page, plus any form fields it offers."""
        src = self.path(a["pdf"])
        _check_pdf(src)
        reader = _pdf_reader(src)
        count = len(reader.pages)
        spec = (a.get("pages") or "").strip()
        picked = _page_indexes(spec, count) if spec else list(range(count))
        head = [f"{src.name}: {count} page(s)."]
        fields = _pdf_fields(reader)
        if fields:
            head.append("Form fields: " + ", ".join(f"{name} ({kind})" for name, kind in fields.items()))
        blocks, used = [], 0
        for i in picked:
            try:
                text = (reader.pages[i].extract_text() or "").strip()
            except Exception:  # noqa: BLE001 - one odd page must not lose the rest
                text = ""
            if not text:
                text = "[no text on this page — it may be a scan or a picture]"
            elif len(text) > 12_000:
                text = text[:12_000] + "\n[page continues — this is the first 12,000 characters]"
            block = f"--- page {i + 1} ---\n{text}"
            blocks.append(block)
            used += len(block)
            if used > 18_000:
                blocks.append("[stopped here for length; ask again with pages, e.g. 4-6]")
                break
        return ToolResult("\n".join(head) + "\n\n" + "\n\n".join(blocks))

    def fill_pdf_form(self, a: dict[str, Any]) -> ToolResult:
        """Fill a PDF's form fields into a new copy; the original is never touched."""
        from pypdf import PdfWriter

        src = self.path(a["pdf"])
        _check_pdf(src)
        reader = _pdf_reader(src)
        available = _pdf_fields(reader)
        if not available:
            raise ToolError(f"{src.name} has no fillable form fields, so there is nothing to fill. "
                            "If it is a scanned form, it has to be typed over like a page on screen.")
        wanted = {str(k): str(v) for k, v in a["fields"].items()}
        if not wanted:
            raise ToolError("Give at least one field to fill, using the names read_pdf lists.")
        for name, value in wanted.items():
            _refuse_secrets(name, value)
        by_lower = {name.lower(): name for name in available}
        values, unknown = {}, []
        for name, value in wanted.items():
            real = name if name in available else by_lower.get(name.lower())
            if real:
                values[real] = value
            else:
                unknown.append(name)
        if unknown:
            raise ToolError(f"{src.name} has no field named {', '.join(map(repr, unknown))}. Nothing was written. "
                            f"Its fields are: {', '.join(f'{name} ({kind})' for name, kind in available.items())}.")
        dest = self.path(a["destination"]) if a.get("destination") else src.with_name(f"{src.stem} - filled.pdf")
        if dest.suffix.lower() != ".pdf":
            dest = dest.with_suffix(".pdf")
        if dest == src:
            raise ToolError("Choose a different name; filling must not overwrite the original.")
        if dest.exists():
            raise ToolError(f"{dest} already exists; choose another name.")
        dest.parent.mkdir(parents=True, exist_ok=True)
        writer = PdfWriter()
        writer.append(reader)
        writer.update_page_form_field_values(None, values)
        with dest.open("wb") as f:
            writer.write(f)
        return ToolResult(f"Filled {len(values)} field(s) in a copy at {dest}: {', '.join(values)}. "
                          "The original is untouched.",
                          {"op": "created", "path": str(dest)}, files=[(str(dest), "created")])

    def screenshot(self, a: dict[str, Any]) -> ToolResult:
        """A real picture of the screen, saved where the user can open it."""
        from . import vision

        if a.get("window"):
            self.screen.focus_window(a["window"])
        shot = vision.grab_screen() if a.get("full") else vision.grab_foreground()
        if shot is None:
            raise ToolError("Compii couldn't capture the screen right now.")
        pixels, (left, top, w, h) = shot
        p = self.path(a["path"]) if a.get("path") else self.workspace / f"screenshot-{time.strftime('%Y%m%d-%H%M%S')}.png"
        if p.suffix.lower() != ".png":
            p = p.with_suffix(".png")
        if p.exists():
            raise ToolError(f"{p} already exists; choose another name.")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(vision.encode_png(pixels))
        where = "all of the screen" if a.get("full") else "the window in front"
        return ToolResult(f"Saved a {w}x{h} PNG of {where} to {p}", {"op": "created", "path": str(p)},
                          files=[(str(p), "created")])

    def look_at_screen(self, a: dict[str, Any]) -> ToolResult:
        """Read what is on screen right now: by picture when Compii can see, else by the window's labels."""
        question = a.get("question") or "What is on the screen?"
        if self.read_screen is not None:
            try:
                seen = self.read_screen(question, bool(a.get("full")), a.get("window"))
            except Exception:  # noqa: BLE001 - fall back to the labels below
                seen = None
            if seen:
                if seen.get("snap"):
                    self.snapshot = seen["snap"]
                return ToolResult(seen["text"])
        if a.get("window"):
            # No picture of the named window: read that window's own labels, never whatever
            # happens to be in front instead.
            labels = self._screen_call(lambda: self.screen.read_window(a["window"]))
            return ToolResult("Read from the window's labels (no picture):\n" + labels)
        from .screen import describe_snapshot

        try:
            from .observe import observe
            snap = observe(question)
        except Exception:  # noqa: BLE001 - labels alone are still an answer
            snap = None
        if not snap:
            raise ToolError("Compii can't see the screen right now (only Compii's own window is in front).")
        self.snapshot = snap
        return ToolResult(describe_snapshot(snap))

    def clipboard(self, a: dict[str, Any]) -> ToolResult:
        text = a.get("text")
        if sys.platform != "win32":
            raise ToolError("Compii reads and writes the clipboard on Windows only.")
        if text is None:
            out = _powershell("[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; Get-Clipboard -Raw")
            got = (out or "").strip()
            if not got:
                return ToolResult("The clipboard holds no text right now.")
            return ToolResult(got[:6000] + ("\n[clipboard longer than 6000 characters]" if len(got) > 6000 else ""))
        # The text goes through an environment variable, never into the command line,
        # so quotes and newlines in it can't change what the command does.
        _powershell("Set-Clipboard -Value $env:COMPII_CLIPBOARD_TEXT", {"COMPII_CLIPBOARD_TEXT": str(text)})
        words = str(text).split()
        shown = " ".join(words[:8]) + ("…" if len(words) > 8 else "")
        return ToolResult(f"Copied to the clipboard: “{shown}”")

    def write_text_file(self, a: dict[str, Any]) -> ToolResult:
        p = self.path(a["path"])
        existed = p.exists()
        if existed and not a.get("overwrite"):
            raise ToolError(f"{p} already exists. Set overwrite to true to replace it.")
        content = a["content"]
        if p.suffix.lower() in (".md", ".markdown"):
            from .documents import tidy_markdown
            content = tidy_markdown(content)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        return ToolResult(f"Wrote {p}", None if existed else {"op": "created", "path": str(p)},
                          files=[(str(p), "changed" if existed else "created")])

    def create_document(self, a: dict[str, Any]) -> ToolResult:
        """Write a Word document from Markdown: styled headings, lists, tables and links."""
        from .documents import docx_bytes

        p = self.path(a["path"])
        if p.suffix.lower() not in (".docx", ".md", ""):
            raise ToolError(f"{p.name} is not a Word document; give it a .docx name.")
        if p.suffix.lower() != ".docx":
            p = p.with_suffix(".docx")
        if p.exists():
            raise ToolError(f"{p} already exists; choose another name.")
        md = a["content"]
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(docx_bytes(md, title=(a.get("title") or "").strip() or None))
        return ToolResult(f"Wrote {p}", {"op": "created", "path": str(p)}, files=[(str(p), "created")])

    def create_deck(self, a: dict[str, Any]) -> ToolResult:
        """Write a PowerPoint deck from slide data: cover, sections, bullets, quotes and stats."""
        from .slides import DeckError, deck_bytes

        p = self.path(a["path"])
        if p.suffix.lower() != ".pptx":
            p = p.with_suffix(".pptx")
        if p.exists():
            raise ToolError(f"{p} already exists; choose another name.")
        try:
            data = deck_bytes(a["title"], list(a.get("slides") or []), subtitle=a.get("subtitle", ""),
                              author=a.get("author", ""), theme=a.get("theme", "ink"))
        except DeckError as e:
            raise ToolError(str(e)) from e
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        return ToolResult(f"Saved deck {p} ({len(a.get('slides') or []) + 1} slides).",
                          {"op": "created", "path": str(p)}, files=[(str(p), "created")])

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

        from .documents import style_worksheet

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
            for row in sheet["rows"]:
                ws.append(row)
            style_worksheet(ws)
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

    def _probe(self, fn: Callable[[], Any]) -> Any:
        """Read the screen to check an action. A check that fails must not hide what was done,
        so it reports UNCHECKED and the result simply says less. (Apps and COM can refuse in
        any shape, so this catches widely on purpose - it only ever costs a sentence.)"""
        try:
            return self._screen_call(fn)
        except Exception:  # noqa: BLE001
            return UNCHECKED

    def list_windows(self, a: dict[str, Any]) -> ToolResult:
        wins = self._screen_call(self.screen.list_windows)
        return ToolResult("\n".join(f"- {w['title']}" for w in wins) or "No windows are open.")

    def focus_window(self, a: dict[str, Any]) -> ToolResult:
        title = self._screen_call(lambda: self.screen.focus_window(a["window"]))
        return ToolResult(f"Switched to “{title}”.")

    def read_window(self, a: dict[str, Any]) -> ToolResult:
        """A window's own controls, plus the words on it when the app reports very little."""
        text = self._screen_call(lambda: self.screen.read_window(a.get("window")))
        if len([ln for ln in text.splitlines()[1:] if ln.strip()]) < 12:
            try:
                from .observe import read_window_words
                words = read_window_words(a.get("window") or "")
            except Exception:  # noqa: BLE001 - the controls are already a real answer
                words = ""
            known = " \n ".join(text.splitlines()).lower()
            fresh = [ln for ln in words.splitlines() if ln.strip() and ln.strip().lower() not in known]
            if fresh:
                text += ("\n\nVisible text read from a picture with local OCR "
                         "(may contain small mistakes):\n" + "\n".join(fresh[:120]))
        return ToolResult(text)

    def read_selection(self, a: dict[str, Any]) -> ToolResult:
        """The words the user has highlighted, asked of the app itself — nothing is copied."""
        from . import sight

        if not sight.enabled():
            raise ToolError(sight.refusal())
        picked = self._screen_call(self.screen.selection)
        if not picked:
            return ToolResult("Nothing is highlighted where the caret is, or that app doesn't share its "
                              "selection. Compii never asks a password field.")
        text = str(picked["text"])
        return ToolResult(f"{picked['words']} words selected in “{picked['window']}”"
                          + (f" ({picked['app']})" if picked.get("app") else "")
                          + ". These are the exact words:\n\n" + text
                          + ("\n…(the selection is longer than this)" if picked["chars"] > len(text) else ""))

    def click_on(self, a: dict[str, Any]) -> ToolResult:
        from .screen import how_found, what_changed

        win_before = self._probe(self.screen.user_foreground)
        found = self._screen_call(lambda: self.screen.click(
            a["target"], a.get("window"), before=lambda f: self._show(f, f"Clicking “{a['target']}”")))
        role = found.role.replace("Control", "").lower()
        said = f"Clicked {role} “{found.name}” in “{found.window}” — {how_found(found)}."
        after = self._probe(lambda: self.screen.read_back(a["target"], a.get("window")))
        if after is UNCHECKED:
            # No read-back is not a confirmation: say so, so the model can't claim the app did something.
            return ToolResult(f"{said} Compii can't confirm the app changed.")
        note = what_changed(found, after, window_before=_title_of(win_before),
                            window_after=_title_of(self._probe(self.screen.user_foreground)))
        return ToolResult(f"{said} Checked afterwards: {note}." if note else said)

    def type_into(self, a: dict[str, Any]) -> ToolResult:
        from .screen import how_found, what_changed

        target, text = a.get("target"), a["text"]
        _refuse_secrets(target or "", text)
        # Without a named field the caret's own control is the only thing to compare against.
        before = UNCHECKED if target else self._probe(self.screen.focus_found)
        win_before = self._probe(self.screen.user_foreground)
        found = self._screen_call(lambda: self.screen.type_text(
            text, target, a.get("window"),
            before=lambda f: self._show(f, f"Typing into “{target}”")))
        where = f"“{found.name}” in “{found.window}” — {how_found(found)}" if found else "the active window"
        said = f"Typed {len(text)} characters into {where}."
        if target:
            if found is None:
                return ToolResult(said)
            base, after = found, self._probe(lambda: self.screen.read_back(target, a.get("window")))
        else:
            base, after = before, self._probe(self.screen.focus_found)
        if after is UNCHECKED or base is UNCHECKED:
            return ToolResult(f"{said} Compii can't confirm the app took it.")
        note = what_changed(base, after, typed=text, window_before=_title_of(win_before),
                            window_after=_title_of(self._probe(self.screen.user_foreground)))
        return ToolResult(f"{said} Checked afterwards: {note}." if note else said)

    def press_keys(self, a: dict[str, Any]) -> ToolResult:
        from .screen import what_changed

        before = self._probe(self.screen.focus_found)
        win_before = self._probe(self.screen.user_foreground)
        title = self._screen_call(lambda: self.screen.press_keys(a["keys"], a.get("window")))
        after = self._probe(self.screen.focus_found)
        said = f"Pressed {a['keys']}" + (f" in “{title}”." if title else ".")
        if before is UNCHECKED or after is UNCHECKED:
            return ToolResult(said)
        note = what_changed(before, after, window_before=_title_of(win_before),
                            window_after=_title_of(self._probe(self.screen.user_foreground)))
        return ToolResult(f"{said} Checked afterwards: {note}." if note else said)

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

    def _locate(self, target: str):
        """An on-screen item by snapshot id or label. In apps whose labels don't match what you
        see (or when nothing matches), look for it in a picture of the window instead."""
        from .screen import Found
        from .vision import needs_picture

        found = self._from_snapshot(target)
        if found is not None and not target.strip().lower().startswith("e"):
            return found  # a v-id or t-id: already located in the picture
        snap = self.snapshot
        name = found.name if found is not None else target
        if self.see_item and (found is None or (snap and needs_picture(snap))):
            try:
                seen = self.see_item(_words(name))
            except Exception:  # noqa: BLE001 - vision is a bonus
                seen = None
            if seen:
                return Found(seen["name"], "Text" if seen.get("src") == "ocr" else "Seen",
                             (snap or {}).get("title", ""), seen["x"], seen["y"],
                             seen["x"] + seen["w"], seen["y"] + seen["h"], src=seen.get("src", "picture"))
        return found or self._find(target)

    def point_at(self, a: dict[str, Any]) -> ToolResult:
        from .screen import how_found

        found = self._locate(a["target"])
        if found is None:
            raise ToolError(
                f"Couldn't find anything named “{a['target']}” in the open windows. "
                "Use look_at_screen or read_window to get the exact labels or item ids."
            )
        point = {**found.as_event(), "message": a.get("message", "")}
        return ToolResult(
            f"Pointing at {found.role} “{found.name}” in “{found.window}” "
            f"at x={point['x']}, y={point['y']} ({point['w']}x{point['h']}) — {how_found(found)}.",
            point=point,
        )

    def draw_on_screen(self, a: dict[str, Any]) -> ToolResult:
        """Circle, underline, box or arrow things on screen, like a teacher with a marker."""
        shapes, missing = [], []
        for sh in a.get("shapes") or []:
            kind = sh.get("kind", "circle")
            if kind not in DRAW_KINDS:
                raise ToolError(f"Unknown shape “{kind}”. Use one of: {', '.join(DRAW_KINDS)}.")
            found = self._locate(sh.get("target", ""))
            if found is None:
                missing.append(sh.get("target", ""))
                continue
            shape = {"kind": kind, **found.as_event()}
            if kind == "arrow" and sh.get("from"):
                start = self._locate(sh["from"])
                if start is not None:
                    shape["from"] = start.as_event()
            shapes.append(shape)
        if not shapes:
            raise ToolError(f"Couldn't find {', '.join(map(repr, missing)) or 'anything to draw on'} on screen.")
        drawing = {"shapes": shapes, "message": a.get("message", "")}
        if self.on_draw:
            self.on_draw(drawing)
        note = f" (couldn't find {', '.join(missing)})" if missing else ""
        return ToolResult(f"Drew {len(shapes)} mark(s) on screen{note}.", point=None)

    def _from_snapshot(self, target: str):
        """An item id from the screen snapshot, so the AI never has to guess pixels.

        e12 came from the app's own controls (exact), v1 was seen in a picture of the
        window, t1 is text read from that picture with local OCR.
        """
        import re

        snap = self.snapshot
        if not snap or not re.fullmatch(r"[evt]\d+", target.strip()):
            return None
        from .screen import Found

        for e in snap.get("elements", []):
            if e["id"] == target.strip():
                return Found(e["name"], e["role"], snap.get("title", ""), e["x"], e["y"], e["x"] + e["w"],
                             e["y"] + e["h"], src=e.get("src", "control"), value=e.get("value", ""),
                             can=tuple(e.get("can") or ()))
        return None

    def _find(self, target: str):  # indirection so tests can stub the screen
        from .screen import find_element

        return find_element(target)

    def locate(self, target: str):
        """Find an on-screen item by label without clicking or typing into it."""
        return self._find(target)

    def window_titles(self) -> list[str]:
        try:
            return [w["title"] for w in self._screen_call(self.screen.list_windows)]
        except ToolError:
            return []

    def update_plan(self, a: dict[str, Any]) -> ToolResult:
        raw = a["steps"]
        if isinstance(raw, str):  # some models send the list as JSON text, or one line per step
            try:
                raw = json.loads(raw)
            except ValueError:
                raw = raw.splitlines()
        if not isinstance(raw, list):
            raise ToolError("steps must be a list of {title, status}.")
        # Models also send bare titles ("Make folders"); those used to crash the turn's plan.
        rows = [st if isinstance(st, dict) else {"title": st} for st in raw]
        steps = [
            {"title": str(st.get("title", "")).strip(), "status": str(st.get("status") or "pending")}
            for st in rows
            if str(st.get("title", "")).strip()
        ]
        same = {"in_progress": "active", "running": "active", "completed": "done", "complete": "done"}
        for st in steps:
            st["status"] = same.get(st["status"], st["status"])
            if st["status"] not in ("pending", "active", "done", "skipped"):
                st["status"] = "pending"
        return ToolResult("Plan shown to the user.", plan=steps)

    def memories(self) -> list[dict[str, Any]]:
        if not self.memory_path.exists():
            return []
        out = []
        # errors="replace": one odd byte must not cost every fact Compii has ever learned.
        text = self.memory_path.read_text(encoding="utf-8", errors="replace")
        for i, line in enumerate(text.splitlines()):
            if not line.strip():
                continue
            try:
                d = json.loads(line)
                fact = str(d["fact"])
            except (ValueError, KeyError, TypeError):
                continue  # a torn line from a power loss is skipped, not fatal
            out.append({"id": i, "fact": fact, "at": d.get("at")})
        return out

    def forget(self, memory_id: int) -> bool:
        if not self.memory_path.exists():
            return False
        with self._memory_lock:
            lines = self.memory_path.read_text(encoding="utf-8", errors="replace").splitlines()
            if not 0 <= memory_id < len(lines) or not lines[memory_id].strip():
                return False
            lines[memory_id] = ""  # keep line numbers stable for the other ids
            self.memory_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return True

    def remember(self, a: dict[str, Any]) -> ToolResult:
        with self._memory_lock:
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
            Tool("read_file", "Read a file's contents. Handles text, PDF, Word (.docx) and Excel files.",
                 {"path": s}, ["path"], ActionKind.READ, self.read_file, lambda a: f"Read {_short(a['path'])}"),
            Tool("search_in_files", "Search INSIDE files for a word or phrase (text, PDF, Word, Excel) and list the file, line "
                 "and matching line. Use it to find which file mentions something, e.g. 'which invoice says overdue'.",
                 {"folder": {**s, "description": "Folder to search inside; ~ is the user's home."},
                  "text": {**s, "description": "The words to look for, case-insensitive."},
                  "pattern": {**s, "description": "Optional glob on the file name, e.g. *.pdf."},
                  "recursive": {"type": "boolean"}, "max_results": {"type": "integer"}},
                 ["folder", "text"], ActionKind.READ, self.search_in_files,
                 lambda a: f"Search inside files in {_short(a['folder'])} for “{a['text']}”"),
            Tool("compare_documents", "Compare two documents and report what actually differs: PDFs, Word files and "
                 "text are read as words, so it answers 'what changed between these two versions?' or 'are these the "
                 "same contract?'. Nothing is edited.",
                 {"path_a": {**s, "description": "The first file (the older one, usually)."},
                  "path_b": {**s, "description": "The second file to compare it with."},
                  "ignore": {**s, "description": "'space', 'case', 'all' or leave empty to treat every difference as real."},
                  "max_differences": {"type": "integer", "description": "How many difference groups to return (1–40, default 20)."}},
                 ["path_a", "path_b"], ActionKind.READ, self.compare_documents,
                 lambda a: f"Compare {_short(Path(a['path_a']).name)} with {_short(Path(a['path_b']).name)}"),
            Tool("find_duplicate_files", "Find files with identical contents in a folder (same bytes, not just same name) "
                 "and how much space they take up. Read-only: it never deletes anything, it lists the copies so the "
                 "user can choose.",
                 {"folder": {**s, "description": "Folder to walk; ~ is the user's home."},
                  "pattern": {**s, "description": "Optional glob on the file name, e.g. *.jpg."},
                  "min_size_mb": {"type": "number", "description": "Ignore files smaller than this (default 1 MB)."},
                  "max_groups": {"type": "integer", "description": "How many groups to return (default 25)."}},
                 ["folder"], ActionKind.READ, self.find_duplicate_files,
                 lambda a: f"Look for duplicate files in {_short(a['folder'])}"),
            Tool("write_text_file", "Write a text file (notes, CSV, Markdown, code). Markdown is tidied as it is "
                 "saved. Refuses to replace an existing file unless overwrite is true.",
                 {"path": s, "content": s, "overwrite": {"type": "boolean"}}, ["path", "content"],
                 lambda a: ActionKind.CHANGE if a.get("overwrite") else ActionKind.CREATE,
                 self.write_text_file, lambda a: f"Write {_short(a['path'])}"),
            Tool("create_document", "Write a real Word (.docx) document from Markdown. Headings (#, ##), bullet and "
                 "numbered lists, | tables | and [links](https://…) all come out styled; put the title in `title`. "
                 "Use this for anything the user will open in Word or hand to someone - reports, essays, letters, "
                 "applications. Use write_text_file instead for notes, code and CSV.",
                 {"path": {**s, "description": "Where to save it, with a .docx name."},
                  "content": {**s, "description": "The whole document as Markdown."},
                  "title": {**s, "description": "The big line at the top; defaults to the first heading."}},
                 ["path", "content"], ActionKind.CREATE, self.create_document,
                 lambda a: f"Write document {_short(a['path'])}"),
            Tool("create_deck", "Build a real PowerPoint (.pptx) deck the user can open, present or send. The cover "
                 "comes from title and subtitle. Slides are a list: kind 'content' (title, bullets, optional notes), "
                 "'section' (title, subtitle) to open a part, 'quote' (text, by), 'stats' (title, stats: "
                 "[{value, label, note}]) or 'closing' (title, subtitle). Keep bullets short (under ~110 characters, "
                 "3-5 a slide), make 5-12 slides, and put what you would say in notes. Use it for presentations, "
                 "pitches, lessons and reports instead of writing slides as text.",
                 {"path": {**s, "description": "Where to save it, with a .pptx name."},
                  "title": {**s, "description": "The big line on the cover."},
                  "subtitle": {**s, "description": "The cover line under the title."},
                  "author": {**s, "description": "Optional name on the cover."},
                  "theme": {**s, "enum": ["ink", "paper", "sea"],
                            "description": "ink (dark, default), paper (light) or sea (dark teal)."},
                  "slides": {"type": "array", "items": {
                      "type": "object",
                      "properties": {
                          "kind": {**s, "enum": ["content", "section", "quote", "stats", "closing"]},
                          "title": s, "subtitle": s,
                          "bullets": {"type": "array", "items": s},
                          "text": {**s, "description": "Body text, or the quote itself."},
                          "by": {**s, "description": "Who said the quote."},
                          "stats": {"type": "array", "items": {
                              "type": "object",
                              "properties": {"value": s, "label": s, "note": s},
                              "required": ["value", "label"], "additionalProperties": False}},
                          "notes": {**s, "description": "Speaker notes for this slide."},
                      },
                      "required": ["kind"], "additionalProperties": False}}},
                 ["path", "title", "slides"], ActionKind.CREATE, self.create_deck,
                 lambda a: f"Build deck {_short(a['path'])}"),
            Tool("create_folder", "Create a folder.", {"path": s}, ["path"], ActionKind.CREATE,
                 self.create_folder, lambda a: f"Create folder {_short(a['path'])}"),
            Tool("move_file", "Move or rename a file or folder. Can be undone.",
                 {"source": s, "destination": s}, ["source", "destination"], ActionKind.CHANGE,
                 self.move_file, lambda a: f"Move {_short(a['source'])} to {_short(a['destination'])}"),
            Tool("move_to_trash", "Put one file or folder in the Recycle Bin, where the user can still restore it. "
                 "This is how Compii clears something away; it never deletes for good.",
                 {"path": s}, ["path"], ActionKind.DELETE, self.move_to_trash,
                 lambda a: f"Put {_short(a['path'])} in the Recycle Bin"),
            Tool("zip_files", "Bundle files and folders into one new .zip archive (folders are included with everything in them).",
                 {"items": {"type": "array", "items": s, "description": "Files or folders to pack."},
                  "destination": {**s, "description": "Path for the new .zip."}},
                 ["items", "destination"], ActionKind.CREATE, self.zip_files,
                 lambda a: f"Zip {len(a['items'])} item(s) to {_short(a['destination'])}"),
            Tool("unzip", "Extract a .zip archive into a folder.", {"zip": s,
                 "into": {**s, "description": "Folder to create and unpack into; defaults next to the zip."}},
                 ["zip"], ActionKind.CREATE, self.unzip, lambda a: f"Unzip {_short(a['zip'])}"),
            Tool("merge_pdfs", "Join several PDFs, in the order given, into one new PDF.",
                 {"inputs": {"type": "array", "items": s, "description": "PDF paths, first to last."},
                  "destination": {**s, "description": "Path for the new PDF."}},
                 ["inputs", "destination"], ActionKind.CREATE, self.merge_pdfs,
                 lambda a: f"Merge {len(a['inputs'])} PDFs into {_short(a['destination'])}"),
            Tool("split_pdf", "Copy pages of a PDF into new files: give a page range (e.g. '1-3,5') to make one "
                 "new PDF, or leave pages out to save every page as its own PDF in a folder. The original stays untouched.",
                 {"pdf": s,
                  "pages": {**s, "description": "Pages to take, 1-based, like '1-3,5'. Leave out for one file per page."},
                  "destination": {**s, "description": "New PDF path, or a folder for one file per page; defaults next to the original."}},
                 ["pdf"], ActionKind.CREATE, self.split_pdf,
                 lambda a: f"Take {a.get('pages') or 'every page'} from {_short(a['pdf'])}"),
            Tool("read_pdf", "Read a PDF page by page, including its form field names, so nothing is guessed. "
                 "A page with no text is reported as a scan rather than made up.",
                 {"pdf": s, "pages": {**s, "description": "Pages to read, 1-based, like '1-3,5'; default every page."}},
                 ["pdf"], ActionKind.READ, self.read_pdf,
                 lambda a: f"Read {_short(a['pdf'])}" + (f" ({a['pages']})" if a.get("pages") else "")),
            Tool("fill_pdf_form", "Fill a PDF's form fields into a new copy; the original is never changed. "
                 "Use the field names read_pdf lists. For a checkbox, use the value the form expects (often /Yes or /Off).",
                 {"pdf": s,
                  "fields": {"type": "object", "additionalProperties": {"type": "string"},
                             "description": "Field name -> value, exactly as read_pdf shows the names."},
                  "destination": {**s, "description": "Path for the filled copy; defaults to '<name> - filled.pdf'."}},
                 ["pdf", "fields"], ActionKind.CHANGE, self.fill_pdf_form,
                 lambda a: f"Fill {len(a['fields'])} field(s) in {_short(a['pdf'])}"),
            Tool("screenshot", "Take a picture of the screen and save it as a PNG file the user can open. "
                 "Use it when asked for a screenshot, or to keep proof of how something looked.",
                 {"path": {**s, "description": "Where to save the PNG; defaults to Compii's workspace folder."},
                  "full": {"type": "boolean", "description": "true for every monitor; default is the window in front."},
                  "window": {**s, "description": "Bring this app to the front first, by part of its title."}},
                 [], ActionKind.CREATE, self.screenshot,
                 lambda a: f"Screenshot to {_short(a['path'])}" if a.get("path") else "Take a screenshot"),
            Tool("look_at_screen", "Look at the screen right now and read it closely: answers the question, copies the "
                 "important visible text exactly, and lists items with ids — e1, e2… are read straight from the app's own "
                 "controls (exact labels, values and what can be done to each), t1, t2… are lines of text read from a "
                 "picture of the window with local OCR (works with no model key), v1, v2… are spotted in the picture by a "
                 "vision model when one is configured. Use those ids in point_at, click_on or type_into. Use this whenever "
                 "the answer depends on what the user is seeing, an error on screen, or anything 'this'/'here' refers to. "
                 "It names the window it actually looked at, so quote that when it matters.",
                 {"question": {**s, "description": "What to find out from the screen."},
                  "full": {"type": "boolean", "description": "true to read every monitor; default is the window in front."},
                  "window": {**s, "description": "Look at this app instead of the one in front, by part of its title, e.g. 'Excel'."}},
                 [], ActionKind.READ, self.look_at_screen, lambda a: "Look at the screen"),
            Tool("clipboard", "Read the text on the clipboard, or put text on it so the user can paste it somewhere.",
                 {"text": {**s, "description": "Text to copy onto the clipboard. Leave out to read what is there."}},
                 [], lambda a: ActionKind.CHANGE if a.get("text") is not None else ActionKind.READ,
                 self.clipboard, lambda a: "Copy to the clipboard" if a.get("text") is not None else "Read the clipboard"),
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
            Tool("read_window", "Read a window (the topmost one if no title given) from the app's own controls: exact "
                 "labels, what each field holds, and [can click/type/toggle…] for each item. When the app reports very "
                 "little (Electron, canvas, games), it also adds the visible words read from a picture with local OCR. "
                 "Use it to get exact labels before clicking or typing.",
                 {"window": {**s, "description": "Part of the window title, optional."}}, [], ActionKind.READ,
                 self.read_window, lambda a: f"Read {a.get('window') or 'the window'}"),
            Tool("read_selection", "Read the words the user has currently highlighted in whatever app is in front — "
                 "asked of the app's own text control, so nothing is copied and the clipboard is untouched. Use it for "
                 "'explain this', 'translate what I selected', 'shorten this', when the ask points at something they "
                 "selected. Password fields and password managers answer nothing.",
                 {}, [], ActionKind.READ, self.read_selection, lambda a: "Read the words the user selected"),
            Tool("click_on", "Click a button, menu, tab, link or checkbox in a Windows app — by its item id from "
                 "look_at_screen (e12, the exact element) or its visible label. Compii uses the control's own button, "
                 "not a guessed position. The user sees Compii point at it first, and the result says what the app's "
                 "controls show afterwards — repeat that, don't claim more.",
                 {"target": {**s, "description": "Item id from look_at_screen (e.g. 'e12') or the exact visible label, e.g. 'Save'."},
                  "window": {**s, "description": "Part of the window title, optional."}}, ["target"],
                 ActionKind.CHANGE, self.click_on,
                 lambda a: f"Click “{a['target']}”" + (f" in {a['window']}" if a.get("window") else "")),
            Tool("type_into", "Type text into a field of a Windows app — by its item id from look_at_screen (e12) or its "
                 "label, or where the cursor is if neither is given. Sets the field's own value when it can, then reads "
                 "the field back: the result says whether the app actually shows the text. "
                 "Never type passwords, card numbers or one-time codes.",
                 {"text": s, "target": {**s, "description": "The field's item id or label, optional."},
                  "window": {**s, "description": "Part of the window title, optional."}}, ["text"],
                 ActionKind.CHANGE, self.type_into,
                 lambda a: f"Type into {a.get('target') or 'the active window'}"),
            Tool("press_keys", "Press a key or shortcut, e.g. 'ctrl+s', 'enter', 'alt+tab', 'f5'. The result says what "
                 "the window or caret shows afterwards, so a shortcut that did nothing visible is reported as that.",
                 {"keys": s, "window": {**s, "description": "Part of the window title to send them to, optional."}}, ["keys"],
                 ActionKind.CHANGE, self.press_keys, lambda a: f"Press {a['keys']}"),
            Tool("browse", "Open a web page in Compii's own browser window (separate from the user's browser) and read it.",
                 {"url": s}, ["url"], ActionKind.READ, self.browse, lambda a: f"Open {a['url']}"),
            Tool("read_page", "Read the page currently open in Compii's browser.", {}, [], ActionKind.READ,
                 self.read_page, lambda a: "Read the page"),
            Tool("browser_click", "Click a button, link or tab on the page in Compii's browser, by its visible text.",
                 {"text": s}, ["text"], ActionKind.CHANGE, self.browser_click, lambda a: f"Click “{a['text']}” on the page"),
            Tool("browser_fill", "Fill a field on the page in Compii's browser, by its label or placeholder; it reads "
                 "the field back, so the result says whether the page really kept the answer. "
                 "submit=true also presses Enter (this counts as sending and always asks the user). "
                 "Never fill passwords, card numbers or one-time codes: call hand_to_user for those instead.",
                 {"field": s, "value": s, "submit": {"type": "boolean"}}, ["field", "value"],
                 lambda a: ActionKind.SEND if a.get("submit") else ActionKind.CHANGE, self.browser_fill,
                 lambda a: f"Fill “{a['field']}”" + (" and submit" if a.get("submit") else "")),
            Tool("point_at", "Point at a button, menu, field or other item in the user's open windows, by its visible label, "
                 "with a short message in a speech bubble. Use it when teaching or when showing the user where something is.",
                 {"target": {**s, "description": "The item's id from the screen snapshot (e.g. 'e12'), or its visible label, e.g. 'Save'."},
                  "message": {**s, "description": "One short sentence for the speech bubble."}},
                 ["target", "message"], ActionKind.READ, self.point_at,
                 lambda a: f"Point at “{a['target']}”"),
            Tool("draw_on_screen", "Draw on the user's screen like a teacher with a marker: circle, underline, box or "
                 "arrow items (by snapshot id or visible label). Great when teaching or showing several things at once.",
                 {"shapes": {"type": "array", "items": {"type": "object", "properties": {
                     "kind": {"type": "string", "enum": list(DRAW_KINDS)},
                     "target": {**s, "description": "Item id (e12) or visible label."},
                     "from": {**s, "description": "For an arrow between two items: where it starts."}},
                     "required": ["kind", "target"]}},
                  "message": {**s, "description": "One short sentence for the speech bubble."}},
                 ["shapes"], ActionKind.READ, self.draw_on_screen,
                 lambda a: "Draw on the screen"),
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


def _check_pdf(p: Path) -> None:
    if not p.is_file() or p.suffix.lower() != ".pdf":
        raise ToolError(f"{p} is not a PDF file.")


def _pdf_reader(p: Path):
    from pypdf import PdfReader

    try:
        reader = PdfReader(p)
    except Exception as e:  # noqa: BLE001 - a broken file is a plain-language failure
        raise ToolError(f"{p.name} could not be opened as a PDF ({e}).") from e
    if reader.is_encrypted:
        try:
            reader.decrypt("")
        except Exception:  # noqa: BLE001 - a wrong password is the likely case
            pass
        if reader.is_encrypted:
            raise ToolError(f"{p.name} is password-protected, so Compii can't open it. "
                            "Ask the user to unlock it or save an unlocked copy.")
    return reader


def _pdf_fields(reader) -> dict[str, str]:
    """Every fillable field, name -> plain kind with its current value."""
    try:
        got = reader.get_fields() or {}
    except Exception:  # noqa: BLE001 - a form that can't be read simply offers none
        return {}
    kinds = {"/Tx": "text", "/Btn": "checkbox/choice", "/Ch": "choice", "/Sig": "signature"}
    out: dict[str, str] = {}
    for name, spec in got.items():
        kind = kinds.get(str(spec.get("/FT", "")), "field")
        value = spec.get("/V")
        out[str(name)] = kind + (f" = {value}" if value not in (None, "") else "")
    return out


def _page_indexes(spec: str, count: int) -> list[int]:
    """'1-3,5' as printed on the pages -> zero-based indexes, in the order asked."""
    picked: list[int] = []
    for part in spec.replace(" ", "").split(","):
        if not part:
            continue
        try:
            if "-" in part:
                first, last = part.split("-", 1)
                start = int(first)
                end = int(last) if last else count
            else:
                start = end = int(part)
        except ValueError:
            raise ToolError(f"“{part}” is not a page range. Use pages like 1-3,5.") from None
        if start < 1 or end > count or start > end:
            raise ToolError(f"Page range “{part}” is outside this PDF, which has {count} page(s).")
        picked.extend(range(start - 1, end))
    seen: set[int] = set()
    out: list[int] = []
    for i in picked:
        if i not in seen:
            seen.add(i)
            out.append(i)
    if not out:
        raise ToolError("Give at least one page, like 1 or 1-3,5.")
    return out


def _pages_text(indexes: list[int]) -> str:
    """[0, 1, 2, 4] -> 'pages 1-3, 5'."""
    nums = [i + 1 for i in indexes]
    spans: list[str] = []
    start = end = nums[0]
    for n in nums[1:]:
        if n == end + 1:
            end = n
            continue
        spans.append(str(start) if start == end else f"{start}-{end}")
        start = end = n
    spans.append(str(start) if start == end else f"{start}-{end}")
    return ("page " if len(nums) == 1 else "pages ") + ", ".join(spans)


def _default_open(target: str) -> None:
    if sys.platform == "win32":
        os.startfile(target)  # noqa: S606 - opening user-approved items is the point
    else:
        subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", target])


def _powershell(command: str, env_add: dict[str, str] | None = None) -> str:
    """Run one short PowerShell command without a console window flashing on screen."""
    env = {**os.environ, **(env_add or {})}
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", command],
                             capture_output=True, text=True, encoding="utf-8", timeout=15, env=env,
                             creationflags=0x08000000 if sys.platform == "win32" else 0)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ToolError(f"Windows would not run that ({type(e).__name__}).") from e
    if out.returncode != 0:
        raise ToolError(f"Windows refused that: {(out.stderr or out.stdout).strip()[:200]}")
    return out.stdout


def _recycle(p: Path) -> None:
    """Send a path to the Recycle Bin through the shell, so it stays recoverable.

    Compii never removes anything for good: a plain os.remove would leave the
    user with no way back if the model picked the wrong file.
    """
    if sys.platform != "win32":
        raise ToolError("Compii only puts things in the Recycle Bin on Windows.")
    import ctypes
    from ctypes import wintypes

    class _Op(ctypes.Structure):
        _fields_ = [("hwnd", wintypes.HWND), ("wFunc", ctypes.c_uint), ("pFrom", ctypes.c_wchar_p),
                    ("pTo", ctypes.c_wchar_p), ("fFlags", ctypes.c_ushort),
                    ("fAnyOperationsAborted", ctypes.c_int), ("hNameMappings", ctypes.c_void_p),
                    ("lpszProgressTitle", ctypes.c_wchar_p), ("fTimeout", wintypes.DWORD),
                    ("Reserved", ctypes.c_int)]

    op = _Op(0, 3, f"{p}\0\0", None, 0x4 | 0x10 | 0x40 | 0x400, 0, None, None, 0, 0)
    rc = ctypes.windll.shell32.SHFileOperationW(ctypes.byref(op))
    if rc or op.fAnyOperationsAborted:
        raise ToolError(f"Windows would not put {p.name} in the Recycle Bin (code {rc}).")


def default_roots() -> list[Path]:
    home = Path.home()
    return [home / d for d in ("Downloads", "Documents", "Desktop", "Pictures")]


def _refuse_secrets(field: str, value: str) -> None:
    """Compii never types passwords, payment details or one-time codes (the rule lives in guard.py)."""
    from .guard import is_secret

    if is_secret(field, value):
        raise ToolError(
            "That looks like a password, payment detail or one-time code. Compii doesn't type those; "
            "ask the user to enter it themselves, then continue."
        )


def _code_like(name: str) -> bool:
    """Internal names like "Tab_Effect" or "FFPlayerToolBarBase" rather than words on screen."""
    import re

    return " " not in name and bool("_" in name or re.search(r"[a-z][A-Z]", name))


def _title_of(probed: Any) -> str:
    """The front window's title from a _probe of user_foreground ("" if the read failed)."""
    return "" if probed is UNCHECKED else probed[1]


def _words(name: str) -> str:
    """ "Tab_Effect" -> "Tab Effect", "FFPlayerToolBar" -> "FF Player Tool Bar": what to look for in a picture."""
    import re

    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", name.replace("_", " ")).strip() if _code_like(name) else name

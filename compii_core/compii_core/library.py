"""Imported skills and connectors, kept behind a quarantine gate.

- Claude skills: a folder with SKILL.md (or a .md, .zip, or link). The written
  procedure and its reference files are copied into Compii's workspace. Code in
  a skill is reference material; Compii never runs it by itself.
- GPT Actions and other OpenAPI 3 connectors: every operation becomes a tool
  that can only call the server the spec names, with the key kept in Windows
  Credential Manager.
- Remote MCP servers: tools are discovered over the MCP HTTP transport and
  called the same way. Local command servers are refused: Compii does not
  launch third-party code.

Nothing is usable until the user approves it. Imported text is scanned for
instruction hijacking, secret exfiltration and destructive steps, and the user
sees every flag before saying yes.
"""

from __future__ import annotations

import base64
import ipaddress
import json
import re
import shutil
import socket
import threading
import time
import uuid
import zipfile
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote, unquote, urlparse

import httpx
import yaml

from .guard import looks_like_injection, redact, wrap_untrusted
from .keys import KeyStore, KeyStoreError
from .policy import ActionKind
from .skills import Skills
from .tools import Tool, ToolError, ToolResult

FORMATS = {
    "claude-skill": "Claude skill (SKILL.md)",
    "markdown": "Markdown skill",
    "openapi": "OpenAPI connector",
    "mcp": "MCP server",
}

MAX_FILE_BYTES = 2_000_000
MAX_TOTAL_BYTES = 20_000_000
MAX_FILES = 200
MAX_BODY = 40_000
MAX_RESPONSE = 40_000
MAX_OPERATIONS = 80
_SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", ".idea", ".vscode"}
_SCRIPT_SUFFIXES = {".exe", ".dll", ".bat", ".cmd", ".ps1", ".vbs", ".js", ".mjs", ".sh", ".py", ".rb", ".jar", ".msi"}
# The bundled files worth reading as words at import time — the same ones Compii may be
# told to read when the skill runs.
SCAN_SUFFIXES = {".md", ".markdown", ".txt", ".rst", ".json", ".yaml", ".yml", ".toml", ".csv", ".tsv",
                  ".html", ".htm", ".xml", ".py", ".js", ".mjs", ".ts", ".sh", ".ps1", ".bat", ".cmd", ".rb",
                  ".cfg", ".ini"}
SCAN_FILES = 40
SCAN_BYTES = 400_000
_HTTP_METHODS = {"get", "post", "put", "patch", "delete", "head"}
_SPEND = re.compile(r"\b(pay|payment|charge|purchase|checkout|transfer|refund|invoice.*pay)\b", re.I)
_SEND = re.compile(r"\b(send|email|e-mail|message|post|publish|tweet|share|invite|upload|forward|notify)\b", re.I)
_READ_HINT = re.compile(r"^(get|list|search|read|fetch|find|query|lookup|describe|show|view|retrieve|check)", re.I)
_DESTRUCTIVE = re.compile(
    r"\brm\s+-[a-z]*[rf]|\bRemove-Item\b[^\n]*-Recurse|\bdel\s+/[fsq]\b|shutil\.rmtree|format\s+[a-z]:"
    r"|drop\s+(table|database)|truncate\s+table|wipe\b",
    re.I,
)
_EXFIL = re.compile(
    r"(send|upload|post|email|forward|transmit|share)[^.\n]{0,70}"
    r"\b(passwords?|credentials?|api[\s-]?keys?|tokens?|private keys?|secret keys?|the user's files?)\b",
    re.I,
)
_INVISIBLE = re.compile("[\u200b-\u200f\u202a-\u202e\u2060-\u2064\ufeff]")


class LibraryError(Exception):
    """The import or approval cannot proceed, with a message the user can act on."""

    def __init__(self, message: str, scan: list[dict[str, Any]] | None = None) -> None:
        super().__init__(message)
        self.scan = scan or []


@dataclass
class Item:
    id: str
    kind: str  # skill | connector
    format: str  # claude-skill | markdown | openapi | mcp
    name: str
    about: str = ""
    status: str = "pending"  # pending | approved | disabled | rejected
    source: str = ""
    created: float = field(default_factory=time.time)
    approved_at: float | None = None
    files: list[str] = field(default_factory=list)
    scan: list[dict[str, Any]] = field(default_factory=list)
    skill: dict[str, Any] = field(default_factory=dict)
    connector: dict[str, Any] = field(default_factory=dict)
    skill_id: str | None = None
    note: str = ""


def _clean_name(raw: str) -> str:
    name = re.sub(r"\s+", " ", str(raw or "")).strip().strip("'\"“”.")
    return name[:60] or "Imported item"


def _slug(raw: str, limit: int = 30) -> str:
    text = re.sub(r"(?<!^)(?=[A-Z])", "_", str(raw or "")).lower()
    text = re.sub(r"[^a-z0-9]+", "_", text).strip("_")
    return text[:limit] or "item"


def _resolve_host(host: str) -> list[str]:
    infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    return sorted({str(i[4][0]) for i in infos})


def _frontmatter(text: str) -> tuple[dict[str, Any], str]:
    if text.lstrip().startswith("---"):
        body = text.lstrip()
        parts = body.split("---", 2)
        if len(parts) == 3:
            try:
                meta = yaml.safe_load(parts[1]) or {}
            except yaml.YAMLError:
                meta = {}
            if isinstance(meta, dict):
                return meta, parts[2].strip()
    return {}, text.strip()


def _paragraph(text: str) -> str:
    for block in re.split(r"\n\s*\n", text):
        line = " ".join(x.strip() for x in block.splitlines() if x.strip())
        if line and not line.startswith("#"):
            return re.sub(r"[*_`>]", "", line)[:500]
    return ""


def _list_steps(body: str) -> list[str]:
    out: list[str] = []
    for line in body.splitlines():
        m = re.match(r"^\s*(?:[-*+]|\d+[.)])\s+(.+?)\s*$", line)
        if m:
            step = re.sub(r"[*_`]", "", m.group(1)).strip()
            if 2 < len(step) <= 240 and (not out or out[-1] != step):
                out.append(step)
    return out[:12]


def _ref(spec: dict[str, Any], node: Any) -> dict[str, Any]:
    """Follow a local $ref a few hops; external refs are left alone."""
    seen = 0
    while isinstance(node, dict) and "$ref" in node and seen < 5:
        ref = str(node.get("$ref") or "")
        if not ref.startswith("#/"):
            return node
        target: Any = spec
        for part in ref[2:].split("/"):
            target = target.get(part, {}) if isinstance(target, dict) else {}
        node = target
        seen += 1
    return node if isinstance(node, dict) else {}


def _pick_auth(security: Any, schemes: dict[str, Any]) -> dict[str, Any]:
    """The first auth scheme Compii can actually apply. Never stores a secret."""
    if not security:
        return {"scheme": "none", "supported": True}
    for alt in security if isinstance(security, list) else []:
        if not isinstance(alt, dict):
            continue
        for key in alt:
            scheme = schemes.get(key) or {}
            kind = str(scheme.get("type") or "")
            if kind == "http" and str(scheme.get("scheme") or "").lower() in ("bearer", "basic"):
                return {"scheme": str(scheme["scheme"]).lower(), "supported": True,
                        "detail": "token", "scheme_name": key}
            if kind == "apiKey" and scheme.get("in") in ("header", "query") and scheme.get("name"):
                return {"scheme": "apiKey", "supported": True, "in": scheme["in"], "name": scheme["name"],
                        "detail": str(scheme.get("name")), "scheme_name": key}
            if kind in ("oauth2", "openIdConnect"):
                return {"scheme": "oauth2", "supported": False, "scheme_name": key,
                        "detail": "OAuth sign-in (not supported yet)"}
    return {"scheme": "unsupported", "supported": False, "detail": "an auth scheme Compii can't apply"}


def _manifest_auth(headers: dict[str, Any]) -> dict[str, Any]:
    """How a listed MCP server wants its key, from the header names it declares."""
    if not headers:
        return {"scheme": "none", "supported": True}
    for name, value in headers.items():
        if str(name).lower() == "authorization":
            return {"scheme": "bearer", "supported": True, "detail": str(value).strip() or "token"}
    first = str(next(iter(headers)))
    return {"scheme": "apiKey", "supported": True, "in": "header", "name": first,
            "detail": str(headers[first]).strip() or first}


class Library:
    def __init__(self, workspace: Path, *, keys: KeyStore | None = None,
                 resolver: Callable[[str], list[str]] | None = None,
                 client_factory: Callable[[], httpx.Client] | None = None) -> None:
        self.workspace = Path(workspace)
        self.root = self.workspace / "library"
        self.root.mkdir(parents=True, exist_ok=True)
        self.path = self.workspace / "library.json"
        self.keys = keys
        self._resolver = resolver or _resolve_host
        self._client_factory = client_factory or (lambda: httpx.Client(timeout=30, follow_redirects=False))
        self._lock = threading.Lock()
        self._toolbox: Any = None
        self._skills: Skills | None = None
        self._installed: dict[str, list[str]] = {}
        self.items: dict[str, Item] = {}
        if self.path.exists():
            try:
                for raw in json.loads(self.path.read_text(encoding="utf-8-sig")):
                    item = Item(**raw)
                    if item.status == "approved":
                        item.note = ""
                    self.items[item.id] = item
            except (ValueError, TypeError, KeyError):
                self.path.replace(self.path.with_suffix(f".broken-{int(time.time())}.json"))

    # ---- persistence ------------------------------------------------------

    def save(self) -> None:
        with self._lock:
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps([asdict(i) for i in self.items.values()], indent=1, ensure_ascii=False),
                           encoding="utf-8")
            tmp.replace(self.path)

    def item_view(self, item: Item) -> dict[str, Any]:
        d = asdict(item)
        connector = d.get("connector") or {}
        auth = connector.get("auth") or {}
        d["has_secret"] = bool(auth.get("scheme") in ("bearer", "basic", "apiKey") and self._secret(item.id))
        d["folder"] = str(self._files(item)) if item.kind == "skill" else ""
        d["tool_names"] = list(self._installed.get(item.id, []))
        return d

    def view(self) -> dict[str, Any]:
        out = [self.item_view(i) for i in sorted(self.items.values(), key=lambda i: -i.created)]
        return {"items": out, "formats": FORMATS, "root": str(self.root)}

    # ---- import -----------------------------------------------------------

    def import_path(self, raw: str) -> list[Item]:
        src = Path(raw).expanduser()
        if not src.exists():
            raise LibraryError(f"There is nothing at {src}.")
        if src.is_dir():
            if not (src / "SKILL.md").is_file():
                raise LibraryError("A skill folder needs a SKILL.md in it. Choose the folder Claude's skill came in.")
            return [self._import_skill_dir(src)]
        suffix = src.suffix.lower()
        if suffix == ".zip":
            return self._import_zip(src)
        if suffix == ".md":
            if src.name.lower() == "skill.md" and (src.parent / "SKILL.md").is_file():
                return [self._import_skill_dir(src.parent)]
            return [self._import_markdown_file(src)]
        if suffix in (".json", ".yaml", ".yml"):
            return self._import_data_file(src)
        raise LibraryError("Compii imports skill folders, SKILL.md or .md files, .zip archives, and OpenAPI "
                           "JSON/YAML files.")

    def import_url(self, url: str, allow_private: bool = False) -> list[Item]:
        url = url.strip()
        self._check_url(url, allow_private=allow_private)
        try:
            with self._client_factory() as client:
                with client.stream("GET", url, headers={"User-Agent": "Compii/1"}) as r:
                    if r.status_code != 200:
                        raise LibraryError(f"That link answered HTTP {r.status_code}.")
                    text, cut = _read_capped(r, MAX_FILE_BYTES)
        except httpx.HTTPError as e:
            raise LibraryError(f"Compii couldn't fetch that link: {e}") from e
        if cut:
            raise LibraryError("That file is too large for Compii to import in one piece.")
        name = unquote(Path(urlparse(url).path).name) or "Imported"
        return self._prepare_text(text, name, url, allow_private=allow_private)

    def import_manifest(self, data: dict[str, Any], source: str, filename: str = "") -> list[Item]:
        """Add what a JSON/YAML document describes: an OpenAPI spec or a list of MCP servers.

        A file, a link and a catalogue entry all end up here, so one shape of an import means
        one shape of a scan and one shape of an approval."""
        filename = filename or unquote(Path(urlparse(source).path).name) or "manifest"
        if "openapi" in data or "swagger" in data:
            return [self._import_openapi(data, filename, source)]
        if isinstance(data.get("mcpServers"), dict):
            return self._import_mcp_manifest(data, source)
        raise LibraryError("That document isn't an OpenAPI 3 spec or an MCP server list.")

    def import_folder(self, name: str, files: list[tuple[str, str]], source: str, about: str = "") -> Item:
        """Add a skill whose files came from somewhere else, keeping the folder shape.

        The names come off a third-party listing, so every one is judged again on the way in:
        a ``..`` or a drive letter would otherwise put a file where the user never agreed to
        have it. Compii keeps the text files it can read and says so in the scan."""
        kept: list[tuple[str, str]] = []
        total = 0
        for rel, text in files[:MAX_FILES]:
            clean = _safe_rel(rel)
            if clean is None:
                continue
            size = len(text.encode("utf-8"))
            if size > MAX_FILE_BYTES or total + size > MAX_TOTAL_BYTES:
                raise LibraryError("That skill is larger than Compii imports in one go.")
            total += size
            kept.append((clean, text))
        main = next((k for k, _ in kept if k.lower() == "skill.md"), "")
        if not main:
            raise LibraryError("There is no SKILL.md there, so there are no instructions to import.")
        body_text = next(t for k, t in kept if k == main)
        meta, body = _frontmatter(body_text)
        item = self._new_item("skill", "claude-skill", meta.get("name") or name,
                              about or str(meta.get("description") or ""), source)
        try:
            for rel, text in kept:
                self._write_rel(item, rel, text)
            item.files = _relative_files(self._files(item))
            self._fill_skill(item, meta, body)
            bundled, unread = self._read_bundled(item)
            item.scan = _scan_skill(item, body, bundled, unread)
            item.note = f"{len(item.files)} file(s) copied into Compii's own library."
        except Exception:
            self._discard(item)
            raise
        self.save()
        return item

    def _import_skill_dir(self, src: Path) -> Item:
        skill_md = src / "SKILL.md"
        meta, body = _frontmatter(skill_md.read_text(encoding="utf-8-sig", errors="replace"))
        name = _clean_name(meta.get("name") or src.name)
        item = self._new_item("skill", "claude-skill", name, str(meta.get("description") or ""), str(src))
        try:
            self._copy_tree(src, self._files(item))
            item.files = _relative_files(self._files(item))
            self._fill_skill(item, meta, body)
            bundled, unread = self._read_bundled(item)
            item.scan = _scan_skill(item, body, bundled, unread)
            item.note = f"{len(item.files)} file(s) copied into Compii's own library."
        except Exception:
            self._discard(item)
            raise
        self.save()
        return item

    def _import_markdown_file(self, src: Path) -> Item:
        text = src.read_text(encoding="utf-8-sig", errors="replace")
        meta, body = _frontmatter(text)
        name = _clean_name(meta.get("name") or src.stem)
        item = self._new_item("skill", "markdown", name, str(meta.get("description") or ""), str(src))
        try:
            self._write_file(item, src.name, text.encode("utf-8"))
            item.files = [src.name]
            self._fill_skill(item, meta, body)
            bundled, unread = self._read_bundled(item)
            item.scan = _scan_skill(item, body, bundled, unread)
        except Exception:
            self._discard(item)
            raise
        self.save()
        return item

    def _import_zip(self, src: Path) -> list[Item]:
        temp = self.root / ("z" + uuid.uuid4().hex[:8])
        dest = temp / "files"
        dest.mkdir(parents=True, exist_ok=True)
        try:
            _extract_zip(src, dest)
            found = next((p for p in sorted(dest.rglob("SKILL.md")) if _depth(p, dest) <= 3), None)
            if found is not None:
                root = found.parent
                meta, body = _frontmatter((root / "SKILL.md").read_text(encoding="utf-8-sig", errors="replace"))
                item = self._new_item("skill", "claude-skill", _clean_name(meta.get("name") or src.stem),
                                      str(meta.get("description") or ""), str(src))
                try:
                    self._copy_tree(root, self._files(item))
                    item.files = _relative_files(self._files(item))
                    self._fill_skill(item, meta, body)
                    bundled, unread = self._read_bundled(item)
                    item.scan = _scan_skill(item, body, bundled, unread)
                except Exception:
                    self._discard(item)
                    raise
                self.save()
                return [item]
            spec = next((p for p in sorted(dest.glob("*")) if p.suffix.lower() in (".json", ".yaml", ".yml")),
                        None)
            if spec is None:
                raise LibraryError("That archive has no SKILL.md or OpenAPI file in it.")
            text = spec.read_text(encoding="utf-8-sig", errors="replace")
            return self._prepare_text(text, spec.name, str(src))
        finally:
            shutil.rmtree(temp, ignore_errors=True)

    def _import_data_file(self, src: Path) -> list[Item]:
        text = src.read_text(encoding="utf-8-sig", errors="replace")
        return self._prepare_text(text, src.name, str(src))

    def _prepare_text(self, text: str, filename: str, source: str, allow_private: bool = False) -> list[Item]:
        data: Any = None
        if text.lstrip().startswith(("{", "[")):
            try:
                data = json.loads(text)
            except ValueError:
                data = None
        if data is None:
            try:
                data = yaml.safe_load(text)
            except yaml.YAMLError:
                data = None
        if isinstance(data, dict) and ("openapi" in data or "swagger" in data or isinstance(data.get("mcpServers"), dict)):
            return self.import_manifest(data, source, filename)
        if filename.lower().endswith((".json", ".yaml", ".yml")):
            raise LibraryError("That file is not an OpenAPI 3 spec or an MCP server list.")
        meta, body = _frontmatter(text)
        item = self._new_item("skill", "markdown", _clean_name(meta.get("name") or Path(filename).stem),
                              str(meta.get("description") or ""), source)
        try:
            self._write_file(item, Path(filename).name or "skill.md", text.encode("utf-8"))
            item.files = list(item.files) + [Path(filename).name or "skill.md"]
            self._fill_skill(item, meta, body)
            bundled, unread = self._read_bundled(item)
            item.scan = _scan_skill(item, body, bundled, unread)
        except Exception:
            self._discard(item)
            raise
        self.save()
        return [item]

    def _fill_skill(self, item: Item, meta: dict[str, Any], body: str) -> None:
        description = str(meta.get("description") or "").strip()
        about = description or _paragraph(body)
        instruction = (description.split(". ")[0].strip() if description else "") or f"Use the imported skill {item.name}."
        if len(instruction) > 300:
            instruction = instruction[:297].rstrip() + "…"
        kept = body[:MAX_BODY]
        item.about = about[:500]
        item.skill = {
            "instruction": instruction,
            "body": kept,
            "steps": _list_steps(kept),
            "meta": {k: v for k, v in meta.items() if k in ("name", "description", "version", "license")},
            "truncated": len(body) > len(kept),
        }

    def _import_openapi(self, spec: dict[str, Any], filename: str, source: str) -> Item:
        parsed, scan = _parse_openapi(spec, filename)
        item = self._new_item("connector", "openapi", parsed["name"], parsed.get("about", ""), source)
        try:
            self._write_file(item, Path(filename).name or "openapi.json",
                             json.dumps(spec, indent=1, ensure_ascii=False).encode("utf-8"))
            item.files = [Path(filename).name or "openapi.json"]
            item.connector = parsed
            item.scan = scan
            if not parsed["operations"]:
                raise LibraryError("That spec has no usable operations Compii can call.")
        except Exception:
            self._discard(item)
            raise
        self.save()
        return item

    def _import_mcp_manifest(self, data: dict[str, Any], source: str) -> list[Item]:
        out: list[Item] = []
        refused: list[str] = []
        for name, cfg in (data.get("mcpServers") or {}).items():
            if not isinstance(cfg, dict):
                continue
            url = str(cfg.get("url") or cfg.get("serverUrl") or "")
            if not url:
                refused.append(str(name))
                continue
            item = self._new_item("connector", "mcp", _clean_name(name),
                                  str(cfg.get("description") or "").strip()[:500] or "Remote MCP server", source)
            auth = _manifest_auth(cfg.get("headers") if isinstance(cfg.get("headers"), dict) else {})
            item.connector = {"url": url, "auth": auth, "allow_private": False, "tools": [], "transport": "http"}
            item.files = []
            item.scan = _scan_mcp(name, url, self)
            out.append(item)
            self.save()
        if refused and not out:
            raise LibraryError(
                "That list only has local command MCP servers (" + ", ".join(refused) + "). Compii doesn't "
                "start third-party programs on your PC; import a remote MCP server URL instead.")
        return out

    # ---- approval and lifecycle ------------------------------------------

    def approve(self, item_id: str, *, acknowledge: bool = False, allow_private: bool = False,
                name: str = "") -> Item:
        item = self._get(item_id)
        if item.status != "pending":
            raise LibraryError("This item has already been reviewed.")
        danger = [f for f in item.scan if f.get("level") == "danger"]
        if danger and not acknowledge:
            raise LibraryError("This import has a serious warning. Read the flags and confirm you understand.",
                               danger)
        if name.strip():
            item.name = _clean_name(name)
        if item.kind == "skill":
            self._apply_skill(item)
        else:
            item.connector["allow_private"] = bool(allow_private)
            self._check_connector(item)
            if item.format == "mcp" and not item.connector.get("tools"):
                self._discover_mcp(item)
            self._install(item)
        item.status = "approved"
        item.approved_at = time.time()
        item.note = ""
        self.save()
        return item

    def reject(self, item_id: str) -> Item:
        item = self._get(item_id)
        if item.status != "pending":
            raise LibraryError("Only an item waiting for review can be turned down.")
        item.status = "rejected"
        item.scan = []
        item.skill = {}
        item.connector = {}
        shutil.rmtree(self.root / item.id, ignore_errors=True)
        item.files = []
        self.save()
        return item

    def enable(self, item_id: str) -> Item:
        item = self._get(item_id)
        if item.status == "pending":
            raise LibraryError("Approve this item before turning it on.")
        if item.status == "rejected":
            raise LibraryError("This item was turned down. Import it again if you changed your mind.")
        if item.kind == "skill":
            self._apply_skill(item)
        else:
            self._install(item)
        item.status = "approved"
        self.save()
        return item

    def disable(self, item_id: str) -> Item:
        item = self._get(item_id)
        if item.status == "approved":
            if item.kind == "skill":
                self._drop_skill(item)
            else:
                self._uninstall(item)
            item.status = "disabled"
            self.save()
        return item

    def remove(self, item_id: str) -> None:
        item = self._get(item_id)
        if item.kind == "skill":
            self._drop_skill(item)
        else:
            self._uninstall(item)
        self.clear_secret(item.id)
        shutil.rmtree(self.root / item.id, ignore_errors=True)
        self.items.pop(item.id, None)
        self.save()

    def set_secret(self, item_id: str, value: str) -> None:
        item = self._get(item_id)
        if item.kind != "connector":
            raise LibraryError("Only connectors use a key.")
        if self.keys is None:
            raise LibraryError("Compii's key store isn't available.")
        try:
            self.keys.set(f"library/{item.id}", value)
        except KeyStoreError as e:
            raise LibraryError(str(e)) from e

    def clear_secret(self, item_id: str) -> None:
        if self.keys is not None:
            self.keys.delete(f"library/{item_id}")

    def tools_ready(self, item_id: str) -> bool:
        return bool(self._installed.get(item_id))

    # ---- wiring into the agent's toolbox ----------------------------------

    def attach(self, toolbox: Any, skills: Skills) -> None:
        self._toolbox = toolbox
        self._skills = skills
        for item in self.items.values():
            try:
                if item.status == "approved":
                    if item.kind == "skill":
                        self._apply_skill(item)
                    else:
                        self._install(item)
                elif item.kind == "connector":
                    self._uninstall(item)
                elif item.status in ("disabled", "rejected") and item.kind == "skill":
                    self._drop_skill(item)
            except Exception as e:  # noqa: BLE001 - one broken import must not take Core down
                item.note = f"Couldn't load: {str(e)[:200]}"

    def _apply_skill(self, item: Item) -> None:
        if self._skills is None:
            return
        existing = self._skills.by_library(item.id)
        if existing is not None:
            item.skill_id = existing.id
            return
        name = item.name
        if self._skills.named(name) is not None:
            name = f"{name} (imported)"[:60]
            n = 2
            while self._skills.named(name) is not None and n < 50:
                name = f"{item.name[:50]} ({n})"
                n += 1
        skill = self._skills.add(name, item.skill.get("instruction") or f"Use the imported skill {item.name}.",
                                 [], about=item.about, body=item.skill.get("body", ""),
                                 origin=FORMATS.get(item.format, item.format),
                                 library_id=item.id, folder=str(self._files(item)))
        item.skill_id = skill.id

    def _drop_skill(self, item: Item) -> None:
        if self._skills is None:
            return
        skill = self._skills.by_library(item.id)
        if skill is not None:
            self._skills.items.pop(skill.id, None)
            self._skills.save()
        item.skill_id = None

    def _install(self, item: Item) -> None:
        if self._toolbox is None or item.status not in ("approved", "pending"):
            return
        self._uninstall(item)
        tools = self._build_tools(item)
        names: list[str] = []
        for tool in tools:
            name = _unique(tool.name, self._toolbox.tools, self._installed)
            if name != tool.name:
                tool.name = name
            self._toolbox.tools[tool.name] = tool
            names.append(tool.name)
        self._installed[item.id] = names
        if not names:
            raise LibraryError("No usable tools came from this connector.")

    def _uninstall(self, item: Item) -> None:
        if self._toolbox is None:
            return
        for name in self._installed.pop(item.id, []):
            tool = self._toolbox.tools.get(name)
            if tool is not None and getattr(tool, "_library_item", None) == item.id:
                self._toolbox.tools.pop(name, None)

    def _build_tools(self, item: Item) -> list[Tool]:
        if item.format == "openapi":
            out = []
            base = str(item.connector.get("url") or "").rstrip("/")
            for op in item.connector.get("operations", []):
                if not op.get("available", True):
                    continue
                kind = _operation_kind(str(op.get("method") or "get"), str(op.get("summary") or ""))
                properties = dict(op.get("properties") or {})
                required = [r for r in op.get("required") or [] if r in properties]
                summary = str(op.get("summary") or op.get("id") or "call")
                name = f"conn_{_slug(item.name)}_{_slug(op.get('id'))}"
                tool = Tool(
                    name,
                    f"{item.name}: {summary}. Calls {str(op.get('method')).upper()} {op.get('path')} on "
                    f"{_host_of(base)}. It can only reach that server.",
                    properties, required, kind,
                    lambda args, _item=item, _op=op: self._call_openapi(_item, _op, args),
                    lambda args, _item=item, _op=op: f"{_item.name}: {_op.get('summary') or _op.get('id')}",
                )
                tool._library_item = item.id  # type: ignore[attr-defined]
                out.append(tool)
            return out
        if item.format == "mcp":
            out = []
            for t in item.connector.get("tools", []):
                schema = t.get("schema") if isinstance(t.get("schema"), dict) else {}
                properties = schema.get("properties") if isinstance(schema.get("properties"), dict) else {}
                required = [r for r in schema.get("required") or [] if r in properties]
                remote = str(t.get("name") or "")
                kind = _mcp_kind(remote, str(t.get("description") or ""))
                name = f"mcp_{_slug(item.name)}_{_slug(remote)}"
                tool = Tool(
                    name,
                    f"{item.name} (MCP): {str(t.get('description') or remote)[:400]}",
                    properties, required, kind,
                    lambda args, _item=item, _remote=remote: self._call_mcp(_item, _remote, args),
                    lambda args, _item=item, _remote=remote: f"{_item.name}: {_remote}",
                )
                tool._library_item = item.id  # type: ignore[attr-defined]
                out.append(tool)
            return out
        return []

    # ---- connector calls --------------------------------------------------

    def _call_openapi(self, item: Item, op: dict[str, Any], args: dict[str, Any]) -> ToolResult:
        method = str(op.get("method") or "get").upper()
        path = str(op.get("path") or "")
        params: dict[str, Any] = {}
        headers: dict[str, str] = {"Accept": "application/json, text/plain, */*",
                                   "User-Agent": "Compii/1"}
        for prm in op.get("params") or []:
            name = str(prm.get("name") or "")
            if not name or name not in args:
                continue
            value = args[name]
            where = prm.get("in")
            if where == "path":
                path = path.replace("{" + name + "}", quote(str(value), safe=""))
            elif where == "query":
                params[name] = value
            elif where == "header":
                headers[name] = str(value)
        if "{" in path:
            raise ToolError(f"This operation still needs {path[path.index('{'):path.index('}') + 1]}, and Compii "
                            "doesn't have a value for it.")
        auth = op.get("auth") or item.connector.get("auth") or {"scheme": "none"}
        self._apply_auth(item, auth, headers, params)
        url = str(item.connector.get("url") or "").rstrip("/") + path
        self._check_url(url, allow_private=bool(item.connector.get("allow_private")))
        body = args.get("body") if isinstance(args.get("body"), (dict, list)) else None
        try:
            with self._client_factory() as client:
                with client.stream(method, url, params=params or None, headers=headers, json=body) as r:
                    status = r.status_code
                    final = str(r.url)
                    text, cut = _read_capped(r, MAX_RESPONSE)
        except httpx.HTTPError as e:
            raise ToolError(f"{item.name} couldn't be reached: {e}") from e
        clean, _ = redact(text)
        if status in (401, 403):
            raise ToolError(f"{item.name} refused the call (HTTP {status}). Its key may be missing or expired — "
                            f"add it in Library. {clean[:400]}")
        if status >= 400:
            raise ToolError(f"{item.name} answered HTTP {status}: {clean[:800]}")
        if cut:
            clean += "\n[The response was cut short by Compii.]"
        result = ToolResult(wrap_untrusted(f"{item.name} ({method} {path})", clean or "(empty response)"))
        if method == "GET":
            result.sources = [{"title": f"{item.name}: {op.get('summary') or op.get('id')}", "url": final}]
        return result

    def _apply_auth(self, item: Item, auth: dict[str, Any], headers: dict[str, str],
                    params: dict[str, Any]) -> None:
        scheme = str(auth.get("scheme") or "none")
        if scheme in ("none", ""):
            return
        if scheme == "unsupported" or not auth.get("supported", True):
            raise ToolError(f"{item.name} uses {auth.get('detail') or 'an auth scheme Compii cannot apply'}.")
        secret = self._secret(item.id)
        if not secret:
            raise ToolError(f"{item.name} needs its {auth.get('detail') or 'key'}. Add it in Library, then try again.")
        if scheme == "bearer":
            headers["Authorization"] = f"Bearer {secret}"
        elif scheme == "basic":
            headers["Authorization"] = "Basic " + base64.b64encode(secret.encode("utf-8")).decode("ascii")
        elif scheme == "apiKey":
            if auth.get("in") == "query":
                params[str(auth.get("name") or "key")] = secret
            else:
                headers[str(auth.get("name") or "X-API-Key")] = secret

    def _check_connector(self, item: Item) -> None:
        connector = item.connector
        url = str(connector.get("url") or "")
        self._check_url(url, allow_private=bool(connector.get("allow_private")))
        if item.format == "openapi" and not connector.get("operations"):
            raise LibraryError("This connector has no operations Compii can call.")

    # ---- MCP --------------------------------------------------------------

    def _discover_mcp(self, item: Item) -> None:
        url = str(item.connector.get("url") or "")
        self._check_url(url, allow_private=bool(item.connector.get("allow_private")))
        key = self._secret(item.id)
        sid = ""
        try:
            with self._client_factory() as client:
                _, sid = _mcp_rpc(client, item, "initialize", {
                    "protocolVersion": "2025-03-26", "capabilities": {},
                    "clientInfo": {"name": "Compii", "version": "1.0"},
                }, session=sid, key=key)
                _mcp_notify(client, item, "notifications/initialized", session=sid, key=key)
                tools: list[dict[str, Any]] = []
                cursor: str | None = None
                for _ in range(10):
                    msg, sid = _mcp_rpc(client, item, "tools/list", {"cursor": cursor} if cursor else {},
                                        session=sid, key=key)
                    result = msg.get("result") or {}
                    for t in result.get("tools") or []:
                        if not isinstance(t, dict) or not t.get("name"):
                            continue
                        tools.append({
                            "name": str(t["name"]),
                            "description": str(t.get("description") or "")[:600],
                            "schema": t.get("inputSchema") if isinstance(t.get("inputSchema"), dict) else
                                      {"type": "object", "properties": {}},
                        })
                    cursor = result.get("nextCursor")
                    if not cursor:
                        break
        except LibraryError:
            raise
        except Exception as e:  # noqa: BLE001 - the server's words help the user fix the URL
            raise LibraryError(f"Compii couldn't reach this MCP server: {str(e)[:300]}") from e
        if not tools:
            raise LibraryError("That MCP server answered, but it offers no tools.")
        item.connector["tools"] = tools[:MAX_OPERATIONS]
        item.scan = _scan_mcp(item.name, url, self, len(tools))

    def _call_mcp(self, item: Item, remote: str, args: dict[str, Any]) -> ToolResult:
        url = str(item.connector.get("url") or "")
        self._check_url(url, allow_private=bool(item.connector.get("allow_private")))
        key = self._secret(item.id)
        sid = ""
        try:
            with self._client_factory() as client:
                init, sid = _mcp_rpc(client, item, "initialize", {
                    "protocolVersion": "2025-03-26", "capabilities": {},
                    "clientInfo": {"name": "Compii", "version": "1.0"},
                }, session=sid, key=key)
                _mcp_notify(client, item, "notifications/initialized", session=sid, key=key)
                msg, sid = _mcp_rpc(client, item, "tools/call", {"name": remote, "arguments": args},
                                    session=sid, key=key)
        except LibraryError:
            raise
        except Exception as e:  # noqa: BLE001
            raise ToolError(f"{item.name} couldn't be reached: {str(e)[:300]}") from e
        result = msg.get("result") or {}
        parts = [str(c.get("text") or "") for c in result.get("content") or []
                 if isinstance(c, dict) and c.get("type") == "text"]
        text = "\n".join(p for p in parts if p).strip()
        if result.get("isError"):
            clean, _ = redact(text or "The server did not say why.")
            raise ToolError(f"{item.name} reported an error: {clean[:800]}")
        clean, _ = redact(text or "(The MCP server returned no text.)")
        return ToolResult(wrap_untrusted(f"{item.name} (MCP {remote})", clean))

    # ---- helpers ----------------------------------------------------------

    def _new_item(self, kind: str, fmt: str, name: str, about: str, source: str) -> Item:
        item = Item(id="i" + uuid.uuid4().hex[:10], kind=kind, format=fmt, name=_clean_name(name),
                    about=about.strip()[:500], source=source)
        self.items[item.id] = item
        self._files(item).mkdir(parents=True, exist_ok=True)
        return item

    def _get(self, item_id: str) -> Item:
        item = self.items.get(item_id)
        if item is None:
            raise LibraryError("No such import.")
        return item

    def _files(self, item: Item) -> Path:
        return self.root / item.id / "files"

    def _read_bundled(self, item: Item) -> tuple[list[tuple[str, str]], int]:
        """The words in the files that came with a skill, and how many it couldn't read.
        SKILL.md is judged on its own; a hijack tucked into a reference sheet is what the
        false all-clear used to miss, because using the skill tells Compii to read those."""
        read: list[tuple[str, str]] = []
        unread = 0
        total = 0
        root = self._files(item)
        if len(item.files) < 2:
            return read, unread  # one file is the instructions themselves, already judged
        for rel in item.files:
            path = root / rel
            if rel.lower() == "skill.md" or path.suffix.lower() not in SCAN_SUFFIXES:
                continue
            try:
                size = path.stat().st_size
                if len(read) >= SCAN_FILES or total + size > SCAN_BYTES:
                    unread += 1
                    continue
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                unread += 1
                continue
            total += size
            read.append((rel, text))
        return read, unread

    def _write_file(self, item: Item, name: str, data: bytes) -> None:
        dest = self._files(item) / Path(name).name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)

    def _write_rel(self, item: Item, rel: str, text: str) -> None:
        """Write one file of a skill folder, refusing to let the folder be anywhere but Compii's."""
        root = self._files(item).resolve()
        dest = (root / rel).resolve()
        if root not in dest.parents:
            raise LibraryError("A file in that skill tried to land outside Compii's library folder.")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text, encoding="utf-8")

    def _copy_tree(self, src: Path, dest: Path) -> None:
        dest.mkdir(parents=True, exist_ok=True)
        total = 0
        count = 0
        for path in sorted(src.rglob("*")):
            rel = path.relative_to(src)
            if any(part in _SKIP_DIRS for part in rel.parts):
                continue
            if path.is_symlink():
                continue
            if path.is_file():
                count += 1
                size = path.stat().st_size
                total += size
                if count > MAX_FILES or size > MAX_FILE_BYTES or total > MAX_TOTAL_BYTES:
                    raise LibraryError("That skill folder is larger than Compii imports in one go.")
                target = dest / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)

    def _discard(self, item: Item) -> None:
        self.items.pop(item.id, None)
        shutil.rmtree(self.root / item.id, ignore_errors=True)

    def _secret(self, item_id: str) -> str | None:
        if self.keys is None:
            return None
        try:
            return self.keys.get(f"library/{item_id}")
        except KeyStoreError:
            return None

    def _check_url(self, url: str, *, allow_private: bool) -> None:
        _check_url(url, allow_private=allow_private, is_private=self._is_private)

    def _is_private(self, host: str) -> bool:
        low = host.lower().rstrip(".")
        if low in ("localhost", "localhost.localdomain") or low.endswith(
                (".local", ".internal", ".lan", ".home", ".localhost")):
            return True
        try:
            addresses = [host] if _ip(host) else self._resolver(host)
        except OSError as e:
            raise LibraryError(f"Compii couldn't look up {host}. Check the address and your connection.") from e
        for address in addresses:
            ip = _ip(address)
            if ip is not None and (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved
                                   or ip.is_multicast):
                return True
        return False


def _ip(raw: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        return ipaddress.ip_address(str(raw).strip("[]"))
    except ValueError:
        return None


def _check_url(url: str, *, allow_private: bool, is_private: Callable[[str], bool]) -> None:
    parsed = urlparse(url)
    if parsed.username or parsed.password:
        raise LibraryError("A link with a username or password inside it isn't accepted. Compii keeps keys in "
                           "Windows Credential Manager instead.")
    if parsed.scheme not in ("https", "http"):
        raise LibraryError("A connector address must start with https://.")
    host = parsed.hostname or ""
    if not host:
        raise LibraryError("That address has no server in it.")
    local = is_private(host)
    if local and not allow_private:
        raise LibraryError(f"{host} is on your local network. If that's intended, turn on local network access "
                           "for this connector.")
    if parsed.scheme == "http" and not (local and allow_private):
        raise LibraryError("Plain http would send your key in the open. Use https, or turn on local network "
                           "access for a server on this machine or your own network.")


def _host_of(url: str) -> str:
    return urlparse(url).hostname or url


def _relative_files(root: Path) -> list[str]:
    return [str(p.relative_to(root)).replace("\\", "/") for p in sorted(root.rglob("*")) if p.is_file()]


def _safe_rel(raw: Any) -> str:
    """A file name from somebody else's listing, as a path Compii will write, or "" to drop it."""
    name = str(raw or "").replace("\\", "/").lstrip("/")
    parts = Path(name).parts
    if not name or ".." in parts or len(parts) > 4:
        return ""
    if any(":" in p for p in parts) or any(p in _SKIP_DIRS for p in parts) or parts[-1].startswith("."):
        return ""
    return "/".join(parts)


def _depth(path: Path, root: Path) -> int:
    return len(path.relative_to(root).parts)


def _read_capped(response: httpx.Response, limit: int) -> tuple[str, bool]:
    chunks: list[bytes] = []
    total = 0
    cut = False
    for chunk in response.iter_bytes():
        total += len(chunk)
        if total > limit:
            keep = len(chunk) - (total - limit)
            if keep > 0:
                chunks.append(chunk[:keep])
            cut = True
            break
        chunks.append(chunk)
    return b"".join(chunks).decode("utf-8", "replace"), cut


def _extract_zip(src: Path, dest: Path) -> set[str]:
    total = 0
    count = 0
    names: set[str] = set()
    with zipfile.ZipFile(src) as z:
        for info in z.infolist():
            if info.is_dir():
                continue
            name = info.filename.replace("\\", "/").lstrip("/")
            parts = Path(name).parts
            if not name or ".." in parts or (parts and ":" in parts[0]):
                continue
            if (info.external_attr >> 16) & 0o170000 == 0o120000:
                continue  # symlink
            count += 1
            total += info.file_size
            if count > MAX_FILES or info.file_size > MAX_FILE_BYTES or total > MAX_TOTAL_BYTES:
                raise LibraryError("That archive is larger than Compii imports in one go.")
            data = z.read(info)
            target = (dest / name).resolve()
            if not str(target).startswith(str(dest.resolve())):
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            names.add(name)
    return names


def _scan_skill(item: Item, body: str, bundled: list[tuple[str, str]] | None = None,
                unread: int = 0) -> list[dict[str, Any]]:
    flags: list[dict[str, Any]] = []
    injection = looks_like_injection(body)
    if injection:
        flags.append({"level": "danger",
                      "what": f"Tries to give Compii new instructions: “{injection}”."})
    exfil = _EXFIL.search(body)
    if exfil:
        flags.append({"level": "danger",
                      "what": f"Asks for secrets to be sent somewhere: “{exfil.group(0)[:120]}”."})
    if _DESTRUCTIVE.search(body):
        flags.append({"level": "warn",
                      "what": "Mentions deleting or wiping things. Compii follows its normal approval rules and never "
                              "deletes for good."})
    if _INVISIBLE.search(body):
        flags.append({"level": "warn", "what": "Contains invisible direction-changing characters."})
    for name, text in bundled or []:
        hijack = looks_like_injection(text)
        if hijack:
            flags.append({"level": "danger",
                          "what": f"“{name}” tries to give Compii new instructions: “{hijack}”. Compii reads that "
                                  "file when the skill is used."})
        leak = _EXFIL.search(text)
        if leak:
            flags.append({"level": "danger",
                          "what": f"“{name}” asks for secrets to be sent somewhere: “{leak.group(0)[:120]}”."})
        if _INVISIBLE.search(text):
            flags.append({"level": "warn",
                          "what": f"“{name}” contains invisible direction-changing characters."})
    scripts = [f for f in item.files if Path(f).suffix.lower() in _SCRIPT_SUFFIXES]
    if scripts:
        flags.append({"level": "warn",
                      "what": f"Includes code ({', '.join(scripts[:4])}{'…' if len(scripts) > 4 else ''}). Compii "
                              "treats it as reference and never runs it by itself."})
    if not item.about:
        flags.append({"level": "warn", "what": "No description of when to use it."})
    if item.skill.get("truncated"):
        flags.append({"level": "warn", "what": f"The written procedure is very long; Compii keeps the first "
                                              f"{MAX_BODY // 1000}k characters."})
    if item.format == "claude-skill" and not item.files:
        flags.append({"level": "warn", "what": "The folder has no files besides its instructions."})
    if bundled or unread:
        # The all-clear only means what it read, so say which files those are.
        extra = f"; Compii didn't look through {unread} more" if unread else ""
        flags.append({"level": "warn" if unread else "info",
                      "what": f"Read {len(bundled or [])} file(s) alongside the instructions{extra}."})
    if not flags:
        flags.append({"level": "info", "what": "No instruction hijacking, secret requests or scripts found."})
    return flags


def _scan_mcp(name: str, url: str, library: Library, tool_count: int = 0) -> list[dict[str, Any]]:
    flags: list[dict[str, Any]] = []
    parsed = urlparse(url)
    host = parsed.hostname or url
    try:
        local = library._is_private(host)
    except LibraryError:
        local = None
    if parsed.scheme != "https":
        if local:
            flags.append({"level": "warn", "what": f"{host} is reached over plain http; that's only acceptable on "
                                                   "your own network."})
        else:
            flags.append({"level": "danger", "what": "This server is not using https."})
    if local:
        flags.append({"level": "warn", "what": f"{name} is on your local network. Approve local network access only "
                                               "if you know what is running there."})
    if tool_count:
        flags.append({"level": "info", "what": f"{tool_count} tool(s) discovered. Calls that change or send things "
                                             "follow your normal approval settings."})
    if not flags:
        flags.append({"level": "info", "what": "Remote MCP server. Compii never starts local command servers."})
    return flags


def _scan_openapi(item_name: str, url: str, library_is_private: Callable[[str], bool],
                  operations: list[dict[str, Any]], skipped: int, auth: dict[str, Any]) -> list[dict[str, Any]]:
    flags: list[dict[str, Any]] = []
    parsed = urlparse(url)
    host = parsed.hostname or url
    try:
        local = library_is_private(host)
    except LibraryError:
        local = None
    if parsed.scheme != "https" and not local:
        flags.append({"level": "danger", "what": "This connector's server is not using https, so its key would "
                                                 "travel in the open."})
    if local:
        flags.append({"level": "warn", "what": f"{host} is on your local network. Turn on local network access at "
                                               "approval if that's intended."})
    if auth.get("scheme") in ("oauth2", "unsupported"):
        flags.append({"level": "warn", "what": f"Sign-in method not supported: {auth.get('detail')}."})
    if skipped:
        flags.append({"level": "warn", "what": f"{skipped} operation(s) were skipped because Compii can't call "
                                               "them safely."})
    deletes = [o for o in operations if o.get("method") == "delete"]
    if deletes:
        flags.append({"level": "warn", "what": f"{len(deletes)} operation(s) delete things. They always ask first."})
    sends = [o for o in operations if o.get("kind") == "send" or o.get("kind") == "spend"]
    if sends:
        flags.append({"level": "warn", "what": f"{len(sends)} operation(s) send or pay. They always ask first."})
    for op in operations:
        text = f"{op.get('summary') or ''} {op.get('description') or ''}"
        injection = looks_like_injection(text)
        if injection:
            flags.append({"level": "danger",
                          "what": f"An operation description tries to give Compii instructions: “{injection}”."})
            break
    if not operations:
        flags.append({"level": "danger", "what": "No callable operations."})
    elif not flags:
        flags.append({"level": "info", "what": f"{len(operations)} operation(s), nothing unusual found."})
    return flags


def _parse_openapi(spec: dict[str, Any], filename: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    version = str(spec.get("openapi") or "")
    if not version.startswith("3"):
        raise LibraryError("Compii needs an OpenAPI 3 spec (GPT Actions export OpenAPI 3.1).")
    info = spec.get("info") if isinstance(spec.get("info"), dict) else {}
    name = _clean_name(info.get("title") or Path(filename).stem)
    about = str(info.get("description") or "")[:500]
    servers = spec.get("servers") if isinstance(spec.get("servers"), list) else []
    base = ""
    if servers and isinstance(servers[0], dict):
        base = str(servers[0].get("url") or "")
        for key, var in (servers[0].get("variables") or {}).items():
            if isinstance(var, dict):
                base = base.replace("{" + str(key) + "}", str(var.get("default", "{" + str(key) + "}")))
    if not base:
        raise LibraryError("That spec doesn't say which server to call (no servers[0].url).")
    schemes = ((spec.get("components") or {}).get("securitySchemes") or {})
    global_security = spec.get("security")
    default_auth = _pick_auth(global_security, schemes)
    operations: list[dict[str, Any]] = []
    skipped = 0
    for path, node in (spec.get("paths") or {}).items():
        if not isinstance(node, dict):
            continue
        path_params = node.get("parameters") if isinstance(node.get("parameters"), list) else []
        for method, raw in node.items():
            if str(method).lower() not in _HTTP_METHODS or not isinstance(raw, dict):
                continue
            op = _ref(spec, raw)
            op_id = str(op.get("operationId") or f"{str(method).lower()}_{path}")
            summary = str(op.get("summary") or op_id)[:200]
            description = str(op.get("description") or "")[:800]
            security = op.get("security", global_security)
            auth = _pick_auth(security, schemes) if security is not None else default_auth
            if not auth.get("supported", True):
                skipped += 1
                continue
            properties: dict[str, Any] = {}
            required: list[str] = []
            params: list[dict[str, str]] = []
            all_params = list(path_params) + (op.get("parameters") if isinstance(op.get("parameters"), list)
                                              else [])
            for raw_param in all_params:
                prm = _ref(spec, raw_param)
                pname = str(prm.get("name") or "")
                where = str(prm.get("in") or "")
                if not pname or where not in ("path", "query", "header"):
                    continue
                if where == "header" and pname.lower() in ("authorization", "x-api-key", "api-key"):
                    skipped += 1
                    continue
                schema = _ref(spec, prm.get("schema") or {"type": "string"})
                prop = {k: v for k, v in schema.items() if k not in ("$ref", "example", "examples")}
                prop.setdefault("type", "string")
                if prm.get("description") and "description" not in prop:
                    prop["description"] = str(prm["description"])[:300]
                key = pname
                if key in properties:
                    key = f"{where}_{pname}"
                properties[key] = prop
                params.append({"name": pname, "in": where, "key": key})
                if prm.get("required") or where == "path":
                    required.append(key)
            request = _ref(spec, op.get("requestBody") or {})
            content = request.get("content") if isinstance(request.get("content"), dict) else {}
            media = content.get("application/json") or next(
                (v for k, v in content.items() if "json" in str(k).lower() and isinstance(v, dict)), None)
            if isinstance(media, dict):
                schema = _ref(spec, media.get("schema") or {})
                body_prop = dict(schema)
                body_prop.pop("$ref", None)
                body_prop.setdefault("type", "object")
                body_prop.setdefault("description", "The JSON body to send.")
                properties["body"] = body_prop
                if request.get("required"):
                    required.append("body")
            operation = {
                "id": op_id,
                "method": str(method).lower(),
                "path": str(path),
                "summary": summary,
                "description": description,
                "properties": properties,
                "required": sorted(set(required)),
                "params": params,
                "auth": auth,
                "available": True,
            }
            operation["kind"] = _operation_kind(operation["method"], summary).value
            operations.append(operation)
    operations = operations[:MAX_OPERATIONS]
    scan = _scan_openapi(name, base, _public_private_probe, operations, skipped, default_auth)
    return {"name": name, "about": about, "url": base, "auth": default_auth, "operations": operations,
            "allow_private": False, "spec_version": version, "skipped": skipped}, scan


def _public_private_probe(host: str) -> bool:
    """At import time DNS may be unavailable; only obvious local names are flagged."""
    low = host.lower().rstrip(".")
    if low in ("localhost", "localhost.localdomain") or low.endswith((".local", ".internal", ".lan", ".home")):
        return True
    ip = _ip(low)
    return bool(ip and (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved))


def _operation_kind(method: str, summary: str) -> ActionKind:
    # The HTTP method is not the verb: a plain "Add a pet" POST writes data, it does not send it anywhere.
    if method in ("get", "head"):
        return ActionKind.READ
    if method == "delete":
        return ActionKind.DELETE
    text = summary.lower()
    if _SPEND.search(text):
        return ActionKind.SPEND
    if _SEND.search(text):
        return ActionKind.SEND
    return ActionKind.CHANGE


def _mcp_kind(name: str, description: str) -> ActionKind:
    text = f"{name} {description}"
    if re.search(r"\b(delete|remove|trash|revoke|destroy)\b", text, re.I):
        return ActionKind.DELETE
    if _SPEND.search(text):
        return ActionKind.SPEND
    if _SEND.search(text):
        return ActionKind.SEND
    if _READ_HINT.search(name.strip()):
        return ActionKind.READ
    return ActionKind.CHANGE


def _mcp_headers(item: Item, key: str | None) -> dict[str, str]:
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
               "User-Agent": "Compii/1"}
    auth = item.connector.get("auth") or {"scheme": "none"}
    scheme = auth.get("scheme")
    if scheme == "bearer" and key:
        headers["Authorization"] = f"Bearer {key}"
    elif scheme == "basic" and key:
        headers["Authorization"] = "Basic " + base64.b64encode(key.encode("utf-8")).decode("ascii")
    elif scheme == "apiKey" and key:
        headers[str(auth.get("name") or "X-API-Key")] = key
    return headers


def _mcp_rpc(client: httpx.Client, item: Item, method: str, params: dict[str, Any],
             session: str = "", key: str | None = None) -> tuple[dict[str, Any], str]:
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    headers = _mcp_headers(item, key)
    if session:
        headers["Mcp-Session-Id"] = session
    try:
        with client.stream("POST", str(item.connector.get("url") or ""), json=payload, headers=headers) as r:
            text, _ = _read_capped(r, MAX_RESPONSE)
            status = r.status_code
            sid = r.headers.get("mcp-session-id") or session
    except httpx.HTTPError as e:
        raise LibraryError(f"Compii couldn't reach this MCP server: {e}") from e
    if status >= 400:
        raise LibraryError(f"The MCP server answered HTTP {status}: {text[:300]}")
    msg = _jsonrpc_message(text)
    if msg is None:
        raise LibraryError("The MCP server answered in a shape Compii doesn't understand.")
    if msg.get("error"):
        error = msg["error"] if isinstance(msg["error"], dict) else {"message": str(msg["error"])}
        raise LibraryError(f"The MCP server refused: {str(error.get('message') or error)[:300]}")
    return msg, sid


def _mcp_notify(client: httpx.Client, item: Item, method: str, session: str,
                key: str | None = None) -> None:
    headers = _mcp_headers(item, key)
    if session:
        headers["Mcp-Session-Id"] = session
    try:
        client.post(str(item.connector.get("url") or ""), json={"jsonrpc": "2.0", "method": method},
                    headers=headers)
    except httpx.HTTPError:
        pass  # notifications are best-effort; the tool call will tell us if the session is broken


def _jsonrpc_message(text: str) -> dict[str, Any] | None:
    text = text.strip()
    if not text:
        return None
    if text.startswith("{"):
        try:
            msg = json.loads(text)
            return msg if isinstance(msg, dict) else None
        except ValueError:
            return None
    for line in text.splitlines():
        if line.startswith("data:"):
            payload = line[5:].strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                msg = json.loads(payload)
            except ValueError:
                continue
            if isinstance(msg, dict) and ("result" in msg or "error" in msg):
                return msg
    return None


def _unique(name: str, existing: dict[str, Any], ours: dict[str, list[str]]) -> str:
    mine = {n for names in ours.values() for n in names}
    if name not in existing or name in mine:
        return name
    n = 2
    while f"{name}_{n}" in existing:
        n += 1
    return f"{name}_{n}"

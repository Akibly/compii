"""The catalogues Compii searches when it should learn something it doesn't have yet.

Two indexes are worth asking: the official MCP registry, which lists remote servers Compii can
connect to, and skills.sh, which indexes procedure folders kept in git. Compii installs nothing
by searching. A result only names the thing; adding it fetches the files or the address and hands
them to the Library, so a catalogue item passes the same scan and the same approval as a folder
the user picked by hand.
"""

from __future__ import annotations

import json
import re
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any
from urllib.parse import quote, urlparse

import httpx

from .library import MAX_FILE_BYTES, MAX_TOTAL_BYTES, Library, LibraryError, SCAN_SUFFIXES

REGISTRY = "https://registry.modelcontextprotocol.io/v0/servers"
SKILLS = "https://skills.sh/api/search"
GITHUB_API = "https://api.github.com/repos"
GITHUB_RAW = "https://raw.githubusercontent.com"
UA = "Compii/1"
PER_CATALOGUE = 8
BROWSE_PAGE = 100  # one registry page; about 50 distinct servers once older versions are dropped
FOLDER_FILES = 60

# Both catalogues sit behind public networks that sometimes stall. A search is bounded so one slow
# index can never hold the other's results (or the whole answer) hostage.
SEARCH_TIMEOUT = httpx.Timeout(6.0, connect=4.0)

# Browsing has no second catalogue waiting on it, and the registry's own network is erratic —
# the same 8 KB page measured from 1 to 60 seconds. So the last good page is kept and shown at
# once; only a pressed Browse asks again, and a 30 second wait is allowed behind that press.
BROWSE_TIMEOUT = httpx.Timeout(30.0, connect=8.0)
PAGE_FILE = "catalog-first-page.json"

# A skill is only ever fetched from an exactly-named owner/repo folder on github.com: nothing in a
# catalogue row can point Compii at another host, and no address from the network is followed.
REPO = re.compile(r"^[A-Za-z0-9._-]{1,80}/[A-Za-z0-9._-]{1,80}$")
FOLDER = re.compile(r"^[A-Za-z0-9._-]{1,80}$")
BRANCH = re.compile(r"^[A-Za-z0-9._-]{1,80}(/[A-Za-z0-9._-]{1,80}){0,5}$")
HEADER_NAME = re.compile(r"^[A-Za-z0-9-]{1,40}$")

BROWSE = [
    {"name": "Smithery", "url": "https://smithery.ai/servers", "about": "Hosted MCP servers, one-click connect."},
    {"name": "Glama", "url": "https://glama.ai/mcp/servers", "about": "A wide directory of MCP servers with reviews."},
    {"name": "mcp.so", "url": "https://mcp.so", "about": "MCP servers, with the config each one wants."},
    {"name": "skills.sh", "url": "https://skills.sh", "about": "Skill folders indexed from git."},
    {
        "name": "Anthropic skills",
        "url": "https://github.com/anthropics/skills",
        "about": "The reference skill folders.",
    },
]


def search(query: str, *, library: Library, kind: str = "", fresh: bool = False) -> dict[str, Any]:
    """What the catalogues call the things Compii could learn, and which one didn't answer."""
    words = " ".join(str(query or "").split())[:80]
    if not words:
        return _browse(library, kind=kind, fresh=fresh)
    if len(words) < 2:
        raise LibraryError("Type at least two letters so Compii has something to look for.")
    asks: list[tuple[str, str, dict[str, str], Any]] = []
    if kind != "skill":
        asks.append(("MCP registry", REGISTRY, {"search": words, "limit": "25"}, _registry_rows))
    if kind != "connector":
        asks.append(("skills.sh", SKILLS, {"q": words}, _skill_rows))
    results: list[dict[str, Any]] = []
    problems: list[dict[str, str]] = []
    with ThreadPoolExecutor(max_workers=max(1, len(asks))) as pool:
        pending = [
            (name, pool.submit(_ask, library, url, params, SEARCH_TIMEOUT), to_rows)
            for name, url, params, to_rows in asks
        ]
        for name, answer, to_rows in pending:  # kept in catalogue order, not completion order
            try:
                results += to_rows(answer.result())
            except LibraryError as e:
                problems.append({"catalogue": name, "problem": str(e)})
    return {"query": words, "results": results, "problems": problems, "notes": [], "browse": BROWSE}


def _browse(library: Library, *, kind: str, fresh: bool = False) -> dict[str, Any]:
    """What the catalogues will show without being asked a question — the Library's opening view.

    The MCP registry lists; skills.sh does not. Its only address answers a query of two letters
    or more and there is no second one, so browsing skills is not a thing Compii can offer. The
    page says that in plain words rather than showing an empty box that reads as broken.
    """
    notes = (
        []
        if kind == "connector"
        else [
            "skills.sh has no list to browse — its index only answers a search of two letters or more. "
            "Open it from the places below, search there, and bring the folder back to Compii."
        ]
    )
    if kind == "skill":
        return {"query": "", "results": [], "problems": [], "notes": notes, "browse": BROWSE}
    saved = _saved_page(library)
    age = 0.0 if saved is None else time.time() - saved[0]
    results: list[dict[str, Any]] = []
    problems: list[dict[str, str]] = []
    if saved is not None and not fresh:
        results = saved[1]
        if age > 30 * 60:
            notes.append(
                f"This is the page the registry gave Compii {_ago(age)}. Press Browse to ask for a fresh one."
            )
    else:
        try:
            results = _registry_rows(
                _ask(library, REGISTRY, {"limit": str(BROWSE_PAGE)}, BROWSE_TIMEOUT), limit=BROWSE_PAGE
            )
            _keep_page(library, results)
        except LibraryError as e:
            if saved is not None:
                results = saved[1]
                notes.insert(
                    0, f"The registry didn't answer just now, so this is the page it gave Compii {_ago(age)}."
                )
            else:
                problems.append({"catalogue": "MCP registry", "problem": str(e)})
    return {"query": "", "results": results, "problems": problems, "notes": notes, "browse": BROWSE}


def _saved_page(library: Library) -> tuple[float, list[dict[str, Any]]] | None:
    try:
        raw = json.loads((library.root / PAGE_FILE).read_text(encoding="utf-8"))
        at, rows = float(raw["at"]), raw["results"]
        if not isinstance(rows, list) or not all(isinstance(r, dict) and r.get("id") for r in rows):
            return None
        return at, rows
    except (OSError, ValueError, TypeError, KeyError):
        return None


def _keep_page(library: Library, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return  # an empty answer must never wipe a page that had something on it
    try:
        path = library.root / PAGE_FILE
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"at": time.time(), "results": rows}, ensure_ascii=False), encoding="utf-8")
        tmp.replace(path)
    except OSError:
        pass  # a page that cannot be saved is still a page worth showing


def _ago(seconds: float) -> str:
    minutes = int(seconds // 60)
    if minutes < 60:
        return "a minute ago" if minutes < 2 else f"{minutes} minutes ago"
    hours = minutes // 60
    if hours < 24:
        return "an hour ago" if hours == 1 else f"{hours} hours ago"
    days = hours // 24
    return "a day ago" if days == 1 else f"{days} days ago"


def add(library: Library, entry: dict[str, Any]) -> list[Any]:
    """Fetch what a catalogue row names and put it in the Library, waiting to be reviewed."""
    kind = str(entry.get("kind") or "")
    if kind == "connector":
        return _add_server(library, entry)
    if kind == "skill":
        return _add_skill(library, entry)
    raise LibraryError("Compii doesn't know how to add that kind of thing.")


# ---- reading the catalogues ----------------------------------------------------


def _client(library: Library) -> httpx.Client:
    return library._client_factory()  # the Library's own client: same timeout, same test seam


def _ask(library: Library, url: str, params: dict[str, str], timeout: httpx.Timeout | None = None) -> Any:
    host = urlparse(url).netloc
    try:
        with _client(library) as client:
            r = client.get(
                url,
                params=params,
                headers={"User-Agent": UA},
                timeout=httpx.USE_CLIENT_DEFAULT if timeout is None else timeout,
            )
    except httpx.TimeoutException as e:
        raise LibraryError(f"{host} took too long to answer.") from e
    except httpx.HTTPError as e:
        raise LibraryError(f"Compii couldn't reach {host}: {str(e)[:120]}") from e
    if r.status_code != 200:
        raise LibraryError(f"{host} answered HTTP {r.status_code}.")
    try:
        return r.json()
    except ValueError:
        raise LibraryError(f"{host} sent back something that isn't a list of things to add.") from None


def _registry_rows(data: Any, *, limit: int = PER_CATALOGUE) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for entry in (data.get("servers") or []) if isinstance(data, dict) else []:
        server = entry.get("server") if isinstance(entry, dict) else None
        if not isinstance(server, dict):
            continue
        official = (entry.get("_meta") or {}).get("io.modelcontextprotocol.registry/official") or {}
        if official.get("isLatest") is False:
            continue  # the registry lists every version; only the current one is worth adding
        remotes = [
            r
            for r in (server.get("remotes") or [])
            if isinstance(r, dict) and str(r.get("url") or "").startswith("https://")
        ]
        rows.append(
            {
                "id": f"mcp:{server.get('name')}@{server.get('version')}",
                "kind": "connector",
                "catalogue": "MCP registry",
                "name": str(server.get("title") or server.get("name") or "MCP server")[:60],
                "about": str(server.get("description") or "")[:400],
                "homepage": str((server.get("repository") or {}).get("url") or server.get("websiteUrl") or "")[:300],
                "addable": bool(remotes),
                "needs_key": bool(_headers(remotes[0].get("headers") if remotes else None)),
                "why": ""
                if remotes
                else "This one is meant to run as a program on your PC. Compii only "
                "connects to servers that live somewhere else.",
                "ref": {
                    "name": str(server.get("name") or "")[:60],
                    "version": str(server.get("version") or "")[:20],
                    "url": str(remotes[0].get("url") or "") if remotes else "",
                    "headers": _headers(remotes[0].get("headers") if remotes else None),
                },
            }
        )
    return rows[:limit]


def _headers(raw: Any) -> dict[str, str]:
    """The header names a remote server says it needs, with whoever publishes it's description of them."""
    out: dict[str, str] = {}
    for item in raw or []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or "")
        if not HEADER_NAME.match(name):
            continue
        out[name] = str(item.get("description") or "")[:200]
    return out


def _skill_rows(data: Any) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for entry in (data.get("skills") or []) if isinstance(data, dict) else []:
        if not isinstance(entry, dict):
            continue
        source, ident = str(entry.get("source") or ""), str(entry.get("skillId") or entry.get("name") or "")
        if not REPO.match(source) or not FOLDER.match(ident):
            continue
        installs = entry.get("installs")
        rows.append(
            {
                "id": f"skill:{source}/{ident}",
                "kind": "skill",
                "catalogue": "skills.sh",
                "name": str(entry.get("name") or ident)[:60],
                "about": "",
                "detail": f"{source}"
                + (f" · {int(installs):,} installs" if isinstance(installs, (int, float)) else ""),
                "homepage": f"https://github.com/{source}",
                "addable": True,
                "why": "",
                "ref": {"source": source, "skill": ident},
            }
        )
    return rows[:PER_CATALOGUE]


# ---- fetching what a row names -------------------------------------------------


def _add_server(library: Library, entry: dict[str, Any]) -> list[Any]:
    ref = entry.get("ref") if isinstance(entry.get("ref"), dict) else {}
    url = str(ref.get("url") or "")
    if not url.startswith("https://"):
        raise LibraryError("That catalogue entry has no https address for Compii to connect to.")
    library._check_url(url, allow_private=False)  # the row arrived over the network: judge it again here
    name = str(ref.get("name") or entry.get("name") or "MCP server")[:60]
    headers = _headers(
        [
            {"name": k, "description": v}
            for k, v in (ref.get("headers") or {}).items()
            if isinstance(ref.get("headers"), dict)
        ]
    )
    server: dict[str, Any] = {"url": url, "description": str(entry.get("about") or "")[:400]}
    if headers:
        server["headers"] = headers
    return library.import_manifest({"mcpServers": {name: server}}, str(entry.get("homepage") or REGISTRY))


def _add_skill(library: Library, entry: dict[str, Any]) -> list[Any]:
    ref = entry.get("ref") if isinstance(entry.get("ref"), dict) else {}
    source, ident = str(ref.get("source") or ""), str(ref.get("skill") or "")
    if not REPO.match(source) or not FOLDER.match(ident):
        raise LibraryError("Compii takes skills only from an owner/repo folder it can name exactly.")
    branch = _branch(library, source)
    folder, tree = _locate(library, source, branch, ident)
    files = _fetch(library, source, branch, folder, tree)
    if not any(name.lower() == "skill.md" for name, _ in files):
        raise LibraryError(f"Compii couldn't read the instructions in {source}: SKILL.md didn't come back.")
    return [
        library.import_folder(
            ident, files, f"https://github.com/{source}/tree/{branch}/{folder}", about=str(entry.get("about") or "")
        )
    ]


def _branch(library: Library, source: str) -> str:
    data = _ask(library, f"{GITHUB_API}/{source}", {})
    branch = str((data or {}).get("default_branch") or "main")
    return branch if BRANCH.match(branch) else "main"


def _locate(library: Library, source: str, branch: str, ident: str) -> tuple[str, list[dict[str, Any]]]:
    """The folder holding this skill's SKILL.md, with the repository's whole file list.

    The listing comes back once, recursive, because GitHub's tree address only understands a
    branch or a SHA — a folder path like ``skills/pdf`` is a 404. So the files are picked out of
    this same listing instead of asking for the folder again.

    The index names a skill by an id that is often not its folder's name — ``agent-reach`` lives
    in ``agent_reach/skill`` — so the folder is matched three ways, in order: a folder named like
    the id, any path containing the id, and, in a repository that publishes exactly one skill,
    that one. When none hold, the message lists the SKILL.md files the repository actually has:
    "the index may be behind the repository" is a guess, and the file list is a fact.
    """
    data = _ask(library, f"{GITHUB_API}/{source}/git/trees/{quote(branch, safe='')}", {"recursive": "1"})
    if (data or {}).get("truncated"):
        raise LibraryError(f"{source} is too large for Compii to look through. Import the folder yourself.")
    entries = [e for e in (data or {}).get("tree") or [] if isinstance(e, dict)]
    holders = sorted(
        {
            str(e.get("path") or "")[: -len("skill.md")].rstrip("/")
            for e in entries
            if str(e.get("path") or "").lower().endswith("skill.md")
        }
    )
    want = _plain(ident)
    folders = [f for f in holders if _plain(f.rsplit("/", 1)[-1]) == want]
    if not folders and want:
        folders = [f for f in holders if want in _plain(f)]
    if not folders and len(holders) == 1:
        folders = holders
    if not folders:
        shown = ", ".join(holders[:4]) or "none at all"
        raise LibraryError(
            f"{source} has no folder named like “{ident}” holding a SKILL.md. "
            f"The SKILL.md files it does have are in: {shown}."
        )
    return folders[0], entries


def _plain(text: str) -> str:
    """A name with everything but its letters and digits gone, so a hyphen and an underscore agree."""
    return re.sub(r"[^a-z0-9]", "", text.lower())


def _fetch(
    library: Library, source: str, branch: str, folder: str, tree: list[dict[str, Any]]
) -> list[tuple[str, str]]:
    """Every readable file in one skill folder, as (name inside the folder, text)."""
    prefix = f"{folder}/"
    names: list[str] = []
    for entry in tree:
        if str(entry.get("type")) != "blob":
            continue
        path = str(entry.get("path") or "")
        rel = path[len(prefix) :] if path.startswith(prefix) else ""
        if not rel or not rel.lower().endswith(tuple(SCAN_SUFFIXES)) or int(entry.get("size") or 0) > MAX_FILE_BYTES:
            continue
        names.append(rel)
    names.sort(key=lambda n: (n.lower() != "skill.md", n.lower()))
    out: list[tuple[str, str]] = []
    total = 0
    address = f"{GITHUB_RAW}/{source}/{quote(branch, safe='/')}/{quote(folder, safe='/')}"
    try:
        with _client(library) as client:
            for rel in names[:FOLDER_FILES]:
                if total > MAX_TOTAL_BYTES:
                    break
                r = client.get(f"{address}/{quote(rel, safe='/')}", headers={"User-Agent": UA})
                if r.status_code != 200 or len(r.content) > MAX_FILE_BYTES:
                    continue
                total += len(r.content)
                out.append((rel, r.content.decode("utf-8", "replace")))
    except httpx.HTTPError as e:
        raise LibraryError(f"Compii couldn't fetch that skill: {str(e)[:120]}") from e
    return out

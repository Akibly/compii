"""The catalogues Compii searches when it should learn something it doesn't have yet.

Two indexes are worth asking: the official MCP registry, which lists remote servers Compii can
connect to, and skills.sh, which indexes procedure folders kept in git. Compii installs nothing
by searching. A result only names the thing; adding it fetches the files or the address and hands
them to the Library, so a catalogue item passes the same scan and the same approval as a folder
the user picked by hand.
"""

from __future__ import annotations

import re
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
FOLDER_FILES = 60

# Both catalogues sit behind public networks that sometimes stall. A search is bounded so one slow
# index can never hold the other's results (or the whole answer) hostage.
SEARCH_TIMEOUT = httpx.Timeout(6.0, connect=4.0)

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
    {
        "name": "Anthropic skills",
        "url": "https://github.com/anthropics/skills",
        "about": "The reference skill folders.",
    },
]


def search(query: str, *, library: Library, kind: str = "") -> dict[str, Any]:
    """What the catalogues call the things Compii could learn, and which one didn't answer."""
    words = " ".join(str(query or "").split())[:80]
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
    return {"query": words, "results": results, "problems": problems, "browse": BROWSE}


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


def _registry_rows(data: Any) -> list[dict[str, Any]]:
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
    return rows[:PER_CATALOGUE]


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
    """
    data = _ask(library, f"{GITHUB_API}/{source}/git/trees/{quote(branch, safe='')}", {"recursive": "1"})
    if (data or {}).get("truncated"):
        raise LibraryError(f"{source} is too large for Compii to look through. Import the folder yourself.")
    entries = [e for e in (data or {}).get("tree") or [] if isinstance(e, dict)]
    paths = [str(e.get("path") or "") for e in entries]
    wanted = f"/{ident.lower()}/skill.md"
    folders = sorted(p for p in paths if p.lower().endswith(wanted))
    if not folders:
        raise LibraryError(
            f"skills.sh lists {ident} in {source}, but Compii couldn't find that folder's "
            "SKILL.md there. The index may be behind the repository."
        )
    return folders[0][: -len("skill.md")].rstrip("/"), entries


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

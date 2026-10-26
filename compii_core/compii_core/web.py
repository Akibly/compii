"""Web search and reading for any AI (Claude has its own; NVIDIA, Groq, Gemini and
local models use these). Free and keyless: DuckDuckGo's HTML results, its Lite page when that
refuses, then Bing's RSS results, then the page text itself. Everything read here is untrusted
data for the AI."""

from __future__ import annotations

import html
import re
import urllib.parse
from typing import Any

from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
PAGE_CHARS = 14_000
# What a real browser sends. With only a User-Agent, many sites answer 403 to a page read.
HEADERS = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
           "Accept-Language": "en-US,en;q=0.9"}


def _clean(s: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", s)).strip()


def _ddg_link(url: str) -> str | None:
    url = html.unescape(url)
    if "duckduckgo.com/l/?" in url:  # unwrap the redirect link
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        url = q.get("uddg", [url])[0]
    if "duckduckgo.com/y.js" in url or url.startswith("/"):  # ads and internal links
        return None
    return url


def _ddg_html(text: str, limit: int) -> list[dict[str, str]]:
    results = []
    for b in re.split(r'<div class="result results_links', text)[1:]:
        m = re.search(r'class="result__a" href="([^"]+)"[^>]*>(.*?)</a>', b, re.S)
        url = _ddg_link(m.group(1)) if m else None
        if not m or not url:
            continue
        snip = re.search(r'class="result__snippet"[^>]*>(.*?)</a>', b, re.S)
        results.append({"title": _clean(m.group(2)), "url": url, "snippet": _clean(snip.group(1)) if snip else ""})
        if len(results) >= limit:
            break
    return results


def _ddg_lite(text: str, limit: int) -> list[dict[str, str]]:
    results = []
    links = list(re.finditer(r"""<a[^>]+href=["']([^"']+)["'][^>]*class=['"]result-link['"][^>]*>(.*?)</a>""", text, re.S))
    snips = re.findall(r"""class=['"]result-snippet['"][^>]*>(.*?)</td>""", text, re.S)
    for i, m in enumerate(links):
        url = _ddg_link(m.group(1))
        if not url:
            continue
        results.append({"title": _clean(m.group(2)), "url": url, "snippet": _clean(snips[i]) if i < len(snips) else ""})
        if len(results) >= limit:
            break
    return results


def _bing_rss(text: str, limit: int) -> list[dict[str, str]]:
    results = []
    for item in re.findall(r"<item>(.*?)</item>", text, re.S)[:limit]:
        def field(name: str) -> str:
            m = re.search(rf"<{name}>(.*?)</{name}>", item, re.S)
            return _clean(m.group(1)) if m else ""
        if field("link").startswith("http"):
            results.append({"title": field("title"), "url": field("link"), "snippet": field("description")})
    return results


def search(query: str, limit: int = 8, client: Any = None) -> list[dict[str, str]]:
    """Results from the first engine that answers. DuckDuckGo turns a busy client away with a
    202 and no results; that refusal used to end the search (53 of 57 failed searches in one
    user's history), so it now falls through to DuckDuckGo Lite, then to Bing's RSS feed."""
    import httpx

    engines = [
        ("DuckDuckGo", lambda c: c.post("https://html.duckduckgo.com/html/", data={"q": query}), _ddg_html),
        ("DuckDuckGo Lite", lambda c: c.post("https://lite.duckduckgo.com/lite/", data={"q": query}), _ddg_lite),
        ("Bing", lambda c: c.get("https://www.bing.com/search", params={"q": query, "format": "rss"}), _bing_rss),
    ]
    c = client or httpx.Client(timeout=15, follow_redirects=True, headers=HEADERS)
    problems: list[str] = []
    try:
        for name, ask, parse in engines:
            try:
                r = ask(c)
            except httpx.HTTPError as e:
                problems.append(f"{name}: {type(e).__name__}")
                continue
            if r.status_code != 200:
                problems.append(f"{name}: {r.status_code}")
                continue
            results = parse(r.text, limit)
            if results:
                return results
            problems.append(f"{name}: no results")
    finally:
        if client is None:
            c.close()
    if all(p.endswith("no results") for p in problems):
        return []
    raise ToolError("Web search didn't answer (" + "; ".join(problems) + "). Try again in a moment.")


def page_text(url: str, client: Any = None) -> tuple[str, str]:
    """(title, readable text) of a web page."""
    import httpx

    if not url.startswith(("http://", "https://")):
        raise ToolError("Give a full web address starting with https://")
    c = client or httpx.Client(timeout=20, follow_redirects=True, headers=HEADERS)
    try:
        r = c.get(url)
    finally:
        if client is None:
            c.close()
    if r.status_code >= 400:
        hint = (" The site blocks automatic readers: use another result, or browse it in Compii's browser."
                if r.status_code in (401, 403, 406, 429) else "")
        raise ToolError(f"That page answered {r.status_code}.{hint}")
    body = r.text
    title = _clean((re.search(r"<title[^>]*>(.*?)</title>", body, re.S | re.I) or [None, ""])[1])
    body = re.sub(r"(?is)<(script|style|noscript|svg|nav|footer|header|form)[^>]*>.*?</\1>", " ", body)
    body = re.sub(r"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr|section|article)>", "\n", body)
    text = _clean(body)
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n", text).strip()
    return title, text


def web_tools(client_factory=None) -> list[Tool]:
    s = {"type": "string"}

    def client():
        return client_factory() if client_factory else None

    def run_search(a: dict[str, Any]) -> ToolResult:
        results = search(a["query"], client=client())
        if not results:
            return ToolResult("No results. Try different words.")
        lines = [f"{i}. {r['title']} — {r['url']}\n   {r['snippet']}" for i, r in enumerate(results, 1)]
        return ToolResult("\n".join(lines))

    def run_read(a: dict[str, Any]) -> ToolResult:
        title, text = page_text(a["url"], client=client())
        more = f"\n[… {len(text) - PAGE_CHARS} more characters not shown]" if len(text) > PAGE_CHARS else ""
        # The page was really opened and read: record it as a source the user can check.
        return ToolResult(f"{title}\n{a['url']}\n\n{text[:PAGE_CHARS]}{more}",
                          sources=[{"title": title or a["url"], "url": a["url"]}])

    return [
        Tool("search_web", "Search the web (free). Returns titles, links and snippets. Use for current facts, prices, "
             "news, how-tos and research; then read_web_page on the best results.",
             {"query": s}, ["query"], ActionKind.READ, run_search, lambda a: f"Search the web for “{a['query']}”"),
        Tool("read_web_page", "Read the text of a web page (quick, no browser window). Use after search_web.",
             {"url": s}, ["url"], ActionKind.READ, run_read,
             lambda a: f"Read {urllib.parse.urlparse(a['url']).netloc or a['url']}"),
    ]

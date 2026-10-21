import asyncio

import httpx

from compii_core.web import page_text, search, web_tools

from test_core import ScriptBrain, home, opened, toolbox  # noqa: F401 - fixtures

RESULTS = """
<div class="result results_links results_links_deep web-result ">
  <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Flaptops&amp;rut=x">Best <b>laptops</b> 2026</a>
  <a class="result__snippet" href="#">Our <b>top</b> picks under $500.</a>
</div>
<div class="result results_links results_links_deep web-result ">
  <a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad=1">Sponsored</a>
</div>
"""
PAGE = "<html><head><title>Laptops</title><script>evil()</script></head><body><nav>menu</nav><p>The Acer Swift Go is best.</p><p>Second line</p></body></html>"


def client():
    def handle(request: httpx.Request) -> httpx.Response:
        if "duckduckgo" in str(request.url):
            return httpx.Response(200, text=RESULTS)
        return httpx.Response(200, text=PAGE)

    return httpx.Client(transport=httpx.MockTransport(handle))


def test_search_unwraps_links_and_skips_ads():
    r = search("laptops", client=client())
    assert r == [{"title": "Best laptops 2026", "url": "https://example.com/laptops", "snippet": "Our top picks under $500."}]


def test_page_text_keeps_the_words_not_the_code():
    title, text = page_text("https://example.com/laptops", client=client())
    assert title == "Laptops" and "Acer Swift Go" in text and "evil" not in text and "menu" not in text


def test_tools_are_read_only():
    tools = {t.name: t for t in web_tools(client)}
    assert tools["search_web"].kind_for({}).value == "read"
    assert "example.com/laptops" in tools["search_web"].run({"query": "x"}).text


def test_a_read_page_is_a_source_but_a_result_list_is_not():
    """Only a page Compii actually opened counts as a source; candidates it merely saw don't."""
    tools = {t.name: t for t in web_tools(client)}
    read = tools["read_web_page"].run({"url": "https://example.com/laptops"})
    assert read.sources == [{"title": "Laptops", "url": "https://example.com/laptops"}]
    assert tools["search_web"].run({"query": "x"}).sources == []


async def test_web_sources_reach_the_conversation_as_events(toolbox, home, tmp_path):
    from compii_core.agent import Agent
    from compii_core.journal import Journal
    from compii_core.policy import Policy

    brain = ScriptBrain([("read_web_page", {"url": "https://example.com/laptops"})], final="The Acer Swift Go is best.")
    events: list[dict] = []

    async def emit(e):
        events.append(e)

    agent = Agent(brain, toolbox, Policy(), Journal(tmp_path / "j.jsonl"), emit)
    agent.toolbox.tools.update({t.name: t for t in web_tools(client)})
    task = agent.start("best laptop?")
    await asyncio.wait_for(task.runner, 5)
    sources = [e for e in events if e["type"] == "sources"]
    assert sources and sources[0]["items"][0]["url"] == "https://example.com/laptops"

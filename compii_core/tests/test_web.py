import httpx

from compii_core.web import page_text, search, web_tools

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

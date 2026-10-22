from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from compii_core.keys import MemoryKeyStore
from compii_core.knowledge import Knowledge, KnowledgeError, knowledge_tools
from compii_core.server import build_app
from compii_core.tools import ToolError

from test_core import home, quiet_voice  # noqa: F401 - fixtures and helper


def make_docs(tmp_path: Path) -> Path:
    docs = tmp_path / "docs"
    docs.mkdir()
    (docs / "contract.md").write_text(
        "# Acme services agreement\n\n"
        "The cancellation deadline is 30 days before the renewal date.\n"
        "Questions go to legal@acme.test.\n",
        encoding="utf-8")
    (docs / "notes.txt").write_text("Groceries: milk, eggs, coffee.\n", encoding="utf-8")
    return docs


def test_indexes_files_and_cites_where_the_answer_came_from(tmp_path):
    docs = make_docs(tmp_path)
    k = Knowledge(tmp_path / "ws")
    k.add_folder(str(docs))
    stats = k.refresh()

    assert stats["indexed"] == 2
    hits = k.search("cancellation deadline")
    assert hits and Path(hits[0]["path"]) == docs / "contract.md"
    assert "cancellation" in hits[0]["excerpt"].lower()
    assert hits[0]["title"] == "Acme services agreement"
    assert k.search('"cancellation" OR *')  # quotes and operators in a question are just words
    assert k.view()["files"] == 2

    tool = {t.name: t for t in knowledge_tools(k)}["ask_my_files"]
    out = tool.run({"query": "cancellation deadline"}).text
    assert str(docs / "contract.md") in out and "30 days" in out
    empty = Knowledge(tmp_path / "other")
    with pytest.raises(ToolError):
        knowledge_tools(empty)[0].run({"query": "anything"})


def test_refresh_reads_only_changed_files_and_forgets_deleted_ones(tmp_path):
    docs = make_docs(tmp_path)
    calls: list[str] = []

    def extract(path: Path) -> str:
        calls.append(path.name)
        return path.read_text(encoding="utf-8")

    k = Knowledge(tmp_path / "ws", extract=extract)
    k.add_folder(str(docs))
    k.refresh()
    assert sorted(calls) == ["contract.md", "notes.txt"]
    k.refresh()
    assert len(calls) == 2  # unchanged files are not read again

    (docs / "notes.txt").write_text("Groceries: bread.\n", encoding="utf-8")
    stats = k.refresh()
    assert calls.count("notes.txt") == 2 and stats["indexed"] == 1
    assert k.search("milk") == []

    (docs / "notes.txt").unlink()
    stats = k.refresh()
    assert stats["removed"] == 1 and k.view()["files"] == 1


def test_password_stores_and_private_keys_are_never_indexed(tmp_path):
    docs = make_docs(tmp_path)
    (docs / ".env").write_text("OPENAI_API_KEY=sk-live-should-not-be-indexed\n", encoding="utf-8")
    (docs / "id_rsa").write_text("PRIVATE KEY\n", encoding="utf-8")
    (docs / "backup.pem").write_text("PRIVATE KEY\n", encoding="utf-8")
    k = Knowledge(tmp_path / "ws")
    k.add_folder(str(docs))
    k.refresh()

    assert k.view()["files"] == 2
    assert k.search("sk-live-should-not-be-indexed") == []
    with pytest.raises(KnowledgeError):
        k.add_folder(tmp_path.anchor)  # a whole drive is not a folder choice


def test_knowledge_routes_add_search_and_remove(home, tmp_path):
    app = build_app(workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    voice=quiet_voice(home["workspace"]), keys=MemoryKeyStore())
    h = {"X-Compii-Token": "tok"}
    docs = make_docs(tmp_path)
    with TestClient(app) as c:
        assert c.post("/knowledge/folders", json={"path": str(docs)},
                      headers={"X-Compii-Device": "phone"}).status_code == 403
        r = c.post("/knowledge/folders", json={"path": str(docs)}, headers=h)
        assert r.status_code == 200, r.text
        assert r.json()["folders"][0]["name"] == "docs"
        r = c.post("/knowledge/refresh", headers=h)
        assert r.status_code == 200 and r.json()["last"]["indexed"] == 2
        r = c.get("/knowledge/search", params={"q": "cancellation deadline"}, headers=h)
        assert r.status_code == 200
        assert "contract.md" in r.json()["results"][0]["path"]
        assert c.get("/knowledge/search", params={"q": "???"}, headers=h).status_code == 400
        assert c.delete("/knowledge/folders", params={"path": str(docs)}, headers=h).json()["folders"] == []
        assert c.get("/knowledge/search", params={"q": "cancellation"}, headers=h).json()["results"] == []

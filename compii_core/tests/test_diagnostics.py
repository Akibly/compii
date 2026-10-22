import json
import zipfile
from pathlib import Path

from fastapi.testclient import TestClient

from compii_core.diagnostics import clean
from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401


def test_report_removes_keys_tokens_and_user_name(home, monkeypatch):
    monkeypatch.setattr("subprocess.Popen", lambda *a, **k: None)
    keys = MemoryKeyStore()
    keys.set("groq", "gsk_SECRETSECRETSECRET123")
    ws = home["workspace"]
    ws.mkdir(parents=True, exist_ok=True)
    (ws / "core.log").write_text(f"started\nkey gsk_SECRETSECRETSECRET123 used\nWebSocket /events?t=tok-abcdefghijklmnop\n"
                                 f"file {Path.home() / 'Documents' / 'x.txt'}\n", encoding="utf-8")
    (ws / "app.log").write_text("Flutter error: boom\n", encoding="utf-8")
    app = build_app(brain=ScriptBrain([]), workspace=ws, roots=[home["downloads"]], token="tok-abcdefghijklmnop", keys=keys, voice=quiet_voice(ws))
    with TestClient(app) as c:
        r = c.post("/diagnostics", headers={"X-Compii-Token": "tok-abcdefghijklmnop"})
    path = Path(r.json()["path"])
    with zipfile.ZipFile(path) as z:
        everything = "\n".join(z.read(n).decode() for n in z.namelist())
        info = json.loads(z.read("info.json"))
    assert "gsk_SECRET" not in everything and "tok-abcdefghijklmnop" not in everything
    assert str(Path.home()) not in everything and "Flutter error: boom" in everything
    assert info["keys_stored"]["groq"] is True


def test_clean_masks_key_shapes_even_unknown_ones():
    assert "nvapi-" not in clean("using nvapi-AbCdEfGhIjKlMnOpQr", [])

"""Core getting out of the way of an update: release the keyboard, then stop the process."""
import time

from fastapi.testclient import TestClient

from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401

TOK = {"X-Compii-Token": "tok-abcdefghijklmnop"}


class FakeServer:
    should_exit = False


def a_core(home):
    ws = home["workspace"]
    ws.mkdir(parents=True, exist_ok=True)
    app = build_app(brain=ScriptBrain([]), workspace=ws, roots=[home["downloads"]],
                    token="tok-abcdefghijklmnop", keys=MemoryKeyStore(), voice=quiet_voice(ws))
    return app


def test_only_this_pcs_app_can_stop_core(home):
    app = a_core(home)
    with TestClient(app) as c:
        assert c.post("/shutdown").status_code == 403
        assert c.post("/shutdown", headers={"X-Compii-Token": "wrong"}).status_code == 403


def test_shutdown_releases_the_shortcut_keys_and_asks_the_server_to_stop(home):
    app = a_core(home)
    server = FakeServer()
    app.state.uvicorn = server
    app.state.buddy.hotkey.running = True
    app.state.buddy.dictation.running = True
    with TestClient(app) as c:
        r = c.post("/shutdown", headers=TOK)
        assert r.status_code == 200 and r.json() == {"stopping": "yes"}
        assert app.state.buddy.hotkey.running is False, "hold-Ctrl+Alt is still grabbing keys"
        assert app.state.buddy.dictation.running is False
        assert server.should_exit is False, "it must answer first, then close"
        time.sleep(1.2)  # the wind-down is scheduled on the loop, like a Ctrl+C
    assert server.should_exit is True


def test_a_core_that_was_never_served_keeps_running(home):
    """Under TestClient there is no real Server to stop, and that must never take the tests with it."""
    app = a_core(home)
    with TestClient(app) as c:
        assert c.post("/shutdown", headers=TOK).json() == {"stopping": "no"}

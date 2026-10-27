"""The online voice: chosen by default, falls back to this PC's voice when the
cloud doesn't answer (and says so once), and its MP3 audio decodes to samples."""

import io

import numpy as np
from fastapi.testclient import TestClient

from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app
from compii_core.voice import CLOUD_VOICES, Voice, VoiceSettings, _decode_mp3

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401 - fixtures


def test_the_online_voice_is_the_default():
    assert VoiceSettings().engine == "cloud"
    assert VoiceSettings().cloud_voice in CLOUD_VOICES


def test_a_failed_cloud_voice_hands_over_to_this_pc_and_says_so_once(tmp_path):
    events = []
    v = Voice(tmp_path / "models", events.append)
    assert v.uses_cloud_voice()
    v.cloud_failed(RuntimeError("offline"))
    v.cloud_failed(RuntimeError("offline"))
    assert not v.uses_cloud_voice(), "a failure moves speech to this PC for a while"
    said = [e for e in events if e.get("what") == "cloud_voice"]
    assert len(said) == 1 and "this PC's voice" in said[0]["error"]
    assert v.status()["engine"] != "cloud"


def test_mp3_from_the_cloud_decodes_to_mono_samples():
    import av

    rate = 24000
    tone = (np.sin(2 * np.pi * 440 * np.arange(rate // 2) / rate) * 0.4).astype(np.float32)
    buf = io.BytesIO()
    with av.open(buf, "w", format="mp3") as box:
        stream = box.add_stream("mp3", rate=rate, layout="mono")
        frame = av.AudioFrame.from_ndarray(tone.reshape(1, -1), format="flt", layout="mono")
        frame.sample_rate = rate
        for packet in stream.encode(frame):
            box.mux(packet)
        for packet in stream.encode(None):
            box.mux(packet)
    pcm, got = _decode_mp3(buf.getvalue())
    assert got == rate and pcm.dtype == np.float32
    assert 0.2 < float(np.abs(pcm).max()) <= 1.0
    assert abs(len(pcm) - len(tone)) < rate * 0.2


def test_settings_choose_the_online_voice_and_keep_it(home):
    app = build_app(brain=ScriptBrain([]), workspace=home["workspace"], roots=[home["downloads"]], token="tok",
                    keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        r = client.put("/voice/settings", json={"engine": "cloud", "cloud_voice": "en-GB-SoniaNeural"}, headers=h)
        assert r.status_code == 200
        st = client.get("/voice", headers=h).json()
        assert st["settings"]["engine"] == "cloud" and st["settings"]["cloud_voice"] == "en-GB-SoniaNeural"
        assert "en-US-AvaMultilingualNeural" in st["cloud_voices"]
        client.put("/voice/settings", json={"cloud_voice": "not-a-voice"}, headers=h)
        assert client.get("/voice", headers=h).json()["settings"]["cloud_voice"] == "en-GB-SoniaNeural"

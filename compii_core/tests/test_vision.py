import json
import struct
import types
import zlib

import httpx
import numpy as np

from compii_core import vision


def test_png_encoder_makes_a_valid_image():
    rgb = np.zeros((3, 4, 3), dtype=np.uint8)
    rgb[0, 0] = (255, 0, 0)
    png = vision.encode_png(rgb)
    assert png.startswith(b"\x89PNG\r\n\x1a\n")
    w, h = struct.unpack(">II", png[16:24])
    assert (w, h) == (4, 3)
    idat = png[png.index(b"IDAT") + 4: png.index(b"IEND") - 8]
    raw = zlib.decompress(idat)
    assert raw[:4] == b"\x00\xff\x00\x00"  # filter byte, then the red pixel


def test_only_apps_that_draw_their_own_ui_get_a_picture():
    many = [{"id": f"e{i}"} for i in range(30)]
    assert vision.needs_picture({"title": "Blender", "app": "blender.exe", "elements": many})
    assert vision.needs_picture({"title": "Some game", "app": "game.exe", "elements": many[:3]})
    assert not vision.needs_picture({"title": "Word", "app": "winword.exe", "elements": many})
    assert not vision.needs_picture({"title": "1Password", "app": "1password.exe", "elements": [], "blocked": True})
    assert not vision.needs_picture(None)


def test_what_the_picture_shows_becomes_items_to_point_at():
    reply = {"summary": "Blender with the default cube selected.",
             "items": [{"label": "Add menu", "x": 100, "y": 50, "w": 40, "h": 30}]}

    def answer(request):
        assert json.loads(request.content)["messages"][0]["content"][1]["type"] == "image_url"
        return httpx.Response(200, json={"choices": [{"message": {"content": "```json\n" + json.dumps(reply) + "\n```"}}]})

    seen = vision.look(b"png", "how do I add a sphere", "key", transport=httpx.MockTransport(answer))
    snap = vision.merge({"title": "Blender", "elements": []}, seen, (100, 200, 1000, 800))
    item = snap["elements"][0]
    assert item["id"] == "v1" and item["name"] == "Add menu"
    assert (item["x"] + item["w"] / 2, item["y"] + item["h"] / 2) == (200, 240)  # 10% across, 5% down the window
    assert snap["seen"].startswith("Blender with the default cube")


def test_a_messy_or_cut_off_reply_still_gives_summary_and_items():
    messy = '{"summary": "Compii home screen.", "items": [{"label": "Settings", "x": 40, "y": 900, "w": 60, "h": 30},]}'
    assert vision.parse_look(messy)["items"][0]["label"] == "Settings"
    cut = '{"summary": "Blender, cube selected.", "items": [{"label": "Add", "x": 100, "y": 50, "w": 40, "h": 30}, {"label": "Mod'
    got = vision.parse_look(cut)
    assert got["summary"] == "Blender, cube selected." and [i["label"] for i in got["items"]] == ["Add"]


def _reply(content):
    return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(content)}}]})


def test_pointing_zooms_in_for_a_second_more_exact_look():
    pixels = np.zeros((1000, 2000, 3), dtype=np.uint8)
    sizes = []

    def answer(request):
        url = json.loads(request.content)["messages"][0]["content"][1]["image_url"]["url"]
        import base64
        png = base64.b64decode(url.split(",", 1)[1])
        sizes.append(struct.unpack(">II", png[16:24]))
        if len(sizes) == 1:  # the whole window, roughly
            return _reply({"found": True, "label": "Bold", "x": 500, "y": 500, "w": 10, "h": 10})
        return _reply({"found": True, "label": "Bold", "x": 600, "y": 500, "w": 50, "h": 50})

    got = vision.locate_precise(pixels, (0, 0, 2000, 1000), "Bold", "key", transport=httpx.MockTransport(answer))
    assert sizes[0] == (1000, 500)  # downscaled to fit
    assert sizes[1] == (720, 520)  # a 360x260 crop around the first guess, at double size
    assert (got["x"] + got["w"] / 2, got["y"] + got["h"] / 2) == (1036, 500)


def test_pointing_keeps_the_first_guess_when_the_zoom_finds_nothing():
    pixels = np.zeros((1000, 2000, 3), dtype=np.uint8)
    calls = []

    def answer(request):
        calls.append(1)
        if len(calls) == 1:
            return _reply({"found": True, "label": "Bold", "x": 500, "y": 500, "w": 20, "h": 20})
        return _reply({"found": False})

    got = vision.locate_precise(pixels, (0, 0, 2000, 1000), "Bold", "key", transport=httpx.MockTransport(answer))
    assert len(calls) == 2 and (got["x"] + got["w"] / 2, got["y"] + got["h"] / 2) == (1000, 500)


def test_reading_the_screen_copies_text_and_gives_items():
    def answer(request):
        assert "copied exactly" in json.loads(request.content)["messages"][0]["content"][0]["text"]
        return _reply({"answer": "Excel shows a #REF! error in C4.", "text": "#REF!\nTotal 4,200",
                       "items": [{"label": "C4", "x": 300, "y": 400, "w": 20, "h": 10}]})

    got = vision.read(b"png", "what's wrong", "key", transport=httpx.MockTransport(answer))
    assert got["summary"].startswith("Excel shows") and "4,200" in got["text"] and got["items"][0]["label"] == "C4"


def test_the_whole_screen_is_measured_not_the_monitor_count(monkeypatch):
    """One monitor reports SM_CMONITORS=1 and SM_SAMEDISPLAYFORMAT=1: read those as the size and
    every picture of the desktop comes out 1x1, which looks like a broken capture, not a bug."""
    metrics = {0: 1920, 1: 1080, 76: 0, 77: 0, 78: 1920, 79: 1080, 80: 1, 81: 1}
    user32 = types.SimpleNamespace(GetSystemMetrics=metrics.get)
    monkeypatch.setattr(vision, "_win_gdi", lambda: (user32, None))
    asked: list[tuple[int, int, int, int]] = []
    pixels = np.zeros((1080, 1920, 3), np.uint8)
    monkeypatch.setattr(vision, "_grab_rect",
                        lambda left, top, w, h, hwnd=None: asked.append((left, top, w, h)) or pixels)
    assert vision.grab_screen() == (pixels, (0, 0, 1920, 1080))
    assert asked == [(0, 0, 1920, 1080)]


def test_a_screen_that_windows_won_t_draw_is_no_picture(monkeypatch):
    """A blocked or failing grab must give Compii nothing to claim, not a half-written file and
    not a 500: the caller says it couldn't see."""
    monkeypatch.setattr(vision, "_grab_rect", lambda *a, **kw: (_ for _ in ()).throw(OSError("locked")))
    assert vision.grab_screen() is None
    assert vision.grab_foreground(1234) is None

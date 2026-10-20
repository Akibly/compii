import json
import struct
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

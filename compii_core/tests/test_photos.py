"""Photos from the phone: "what is this?" and a snapped document, read by the
vision model (faked here) or, with no key, by local OCR."""

from __future__ import annotations

import json

import httpx
import numpy as np
import pytest
from PIL import Image

from compii_core import vision
from compii_core.agent import QUICK_TOOLS
from compii_core.guard import UNTRUSTED_TOOLS
from compii_core.tools import Toolbox, ToolError


def _photo(path, size=(80, 40), rotate=False):
    im = Image.new("RGB", size, (200, 30, 30))
    exif = Image.Exif()
    if rotate:
        exif[0x0112] = 6  # the camera held sideways: "rotate 90° clockwise to view"
    im.save(path, "JPEG", exif=exif)
    return path


def test_a_sideways_phone_photo_is_turned_upright(tmp_path):
    pixels = vision.photo_pixels(_photo(tmp_path / "p.jpg", rotate=True))
    assert pixels.shape == (80, 40, 3)


def test_a_huge_photo_is_shrunk_before_it_is_sent(tmp_path):
    jpeg = vision.photo_jpeg(np.zeros((3000, 4000, 3), dtype=np.uint8))
    with Image.open(__import__("io").BytesIO(jpeg)) as im:
        assert max(im.size) == vision.MAX_WIDTH


def test_the_vision_model_answers_and_copies_the_words():
    reply = {"kind": "receipt", "answer": "A receipt from Bean Bar for 7.40.", "text": "BEAN BAR\nFlat white 3.70\nTotal 7.40"}

    def answer(request):
        image = json.loads(request.content)["messages"][0]["content"][1]["image_url"]["url"]
        assert image.startswith("data:image/jpeg;base64,")
        return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(reply)}}]})

    seen = vision.photo(b"jpeg", "Read this", "key", transport=httpx.MockTransport(answer))
    assert seen == reply


def test_read_file_on_a_photo_looks_at_it(tmp_path):
    box = Toolbox([tmp_path], tmp_path / "ws")
    asked = []
    box.read_photo = lambda path, question: asked.append((path.name, question)) or "A red square."
    photo = _photo(tmp_path / "snap.jpg")
    assert box.read_file({"path": str(photo)}).text == "A red square."
    assert box.look_at_photo({"path": str(photo), "question": "What colour?"}).text == "A red square."
    assert asked == [("snap.jpg", "What is this?"), ("snap.jpg", "What colour?")]
    (tmp_path / "notes.txt").write_text("hi")
    with pytest.raises(ToolError, match="isn't a photo"):
        box.look_at_photo({"path": str(tmp_path / "notes.txt")})


def test_photos_are_outside_text_and_always_at_hand():
    assert "look_at_photo" in UNTRUSTED_TOOLS  # a photographed note can't give Compii orders
    assert "look_at_photo" in QUICK_TOOLS

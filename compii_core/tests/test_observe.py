from compii_core import observe


def test_only_questions_about_what_is_in_front_trigger_a_screen_look():
    for asked in ("what's this error?", "what am I looking at?", "read this page", "where is the Save button",
                  "summarize this page", "do you see the dialog", "translate this"):
        assert observe.refers_to_screen(asked), asked
    for asked in ("open Notepad", "write a report about taxes", "where is my tax file",
                  "what's the weather tomorrow", "find that email from Sam"):
        assert not observe.refers_to_screen(asked), asked


def test_observe_adds_the_words_a_local_ocr_pass_read(monkeypatch):
    import numpy as np

    from compii_core import ocr, screen, vision

    monkeypatch.setattr(screen, "snapshot_foreground",
                        lambda: {"title": "Editor", "app": "code.exe", "cursor": [1, 2], "elements": []})
    monkeypatch.setattr(vision, "blocked_foreground", lambda: False)
    monkeypatch.setattr(vision, "grab_foreground",
                        lambda: (np.zeros((500, 1000, 3), np.uint8), (0, 0, 1000, 500)))
    monkeypatch.setattr(ocr, "read_png_boxes",
                        lambda png: {"width": 1000, "height": 500, "lines": [
                            {"text": "Line 3: NameError", "x": 10, "y": 40, "w": 200, "h": 12, "words": []}]})

    snap = observe.observe("what's this error")
    assert snap["elements"][0]["id"] == "t1"
    assert snap["elements"][0]["src"] == "ocr"
    assert snap["ocr_text"] == "Line 3: NameError"


def test_a_password_manager_is_never_photographed(monkeypatch):
    from compii_core import screen, vision

    monkeypatch.setattr(screen, "snapshot_foreground",
                        lambda: {"title": "Vault", "app": "vault.exe", "blocked": True, "elements": []})
    monkeypatch.setattr(vision, "blocked_foreground", lambda: True)
    monkeypatch.setattr(vision, "grab_foreground",
                        lambda: (_ for _ in ()).throw(AssertionError("took a picture anyway")))

    snap = observe.observe("what's this")
    assert snap["blocked"] is True and "ocr_text" not in snap

from compii_core.lessons import Lessons, lesson_tools


def test_a_lesson_survives_a_restart_and_says_what_is_next(tmp_path):
    path = tmp_path / "lesson.json"
    lessons = Lessons(path)
    start, update = lesson_tools(lessons)
    start.run({"topic": "Blender", "steps": ["Move around the viewport", "Add a cube", "Scale and rotate"]})
    update.run({"step": 2, "note": "Got the hang of orbiting"})
    again = Lessons(path)  # Compii restarted
    ctx = again.context()
    assert "teaching the user Blender" in ctx
    assert "1. [done] Move around the viewport" in ctx and "2. [NOW] Add a cube" in ctx
    assert "orbiting" in ctx and "what next" in ctx
    lesson_tools(again)[1].run({"finished": True})
    assert Lessons(path).context() == ""

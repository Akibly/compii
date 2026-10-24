"""The rehearsal brain: a scripted stand-in for a model, run against the Core the app runs."""

import json

from compii_core.guard import wrap_untrusted
from compii_core.rehearsal import _last_result


def test_the_script_reads_a_step_through_the_envelope_that_names_it_as_data():
    """What a tool returned is wrapped as data from outside, the same way a real model is
    shown it. The script has to read the payload inside that envelope, or the demo of the
    whole app — which is what runs before anyone connects a key — quietly stops working."""
    messages = [
        {"role": "user", "content": [{"type": "text", "text": "what did you find?"}]},
        {
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": "c1",
                    "content": wrap_untrusted("find_files", '{"count": 2, "files": [{"path": "a.pdf"}]}'),
                    "is_error": False,
                }
            ],
        },
    ]
    assert json.loads(_last_result(messages))["count"] == 2


def test_a_result_that_is_not_an_envelope_is_still_read_as_it_stands():
    messages = [{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "c1", "content": '{"count": 1}'}]}]
    assert json.loads(_last_result(messages))["count"] == 1

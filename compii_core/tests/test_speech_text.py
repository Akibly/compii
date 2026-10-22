from compii_core.voice import _complete_sentences, _phrases, speakable


class _SpeakerStub:
    speaking = False

    def __init__(self) -> None:
        self.said: list[str] = []
        self.fed: list[str] = []
        self.chimes = 0
        self.stops = 0

    def say(self, text: str) -> None:
        self.said.append(text)

    def feed(self, text: str) -> None:
        self.fed.append(text)

    def chime(self) -> None:
        self.chimes += 1

    def stop(self) -> None:
        self.stops += 1


def _voice(tmp_path):
    from compii_core.voice import Voice

    speaker = _SpeakerStub()
    return Voice(tmp_path, emit=lambda _event: None, speaker=speaker), speaker


def test_speech_starts_before_the_answer_is_finished(tmp_path):
    voice, speaker = _voice(tmp_path)
    voice.settings.output_mode = "voice"
    voice.say_stream("t1", "The report is ready. It covers")
    assert speaker.fed == ["The report is ready."]  # the half-written sentence waits
    assert speaker.stops == 1  # a new answer takes the floor

    voice.say_stream("t1", "The report is ready. It covers five sources. Want me to send it?")
    assert speaker.fed == ["The report is ready.", "It covers five sources."]

    voice.finish_stream("t1", "The report is ready. It covers five sources. Want me to send it?")
    assert speaker.said == [] and speaker.fed == ["The report is ready.", "It covers five sources."]


def test_a_new_step_after_a_tool_call_is_said_too(tmp_path):
    voice, speaker = _voice(tmp_path)
    voice.settings.output_mode = "voice"
    voice.say_stream("t2", "Let me look at your files. There")
    voice.say_stream("t2", "Let me look at your files. There are three here.")
    voice.finish_stream("t2", "You have three invoices in Downloads.")
    assert speaker.fed[-1] == "You have three invoices in Downloads."
    assert "".join(speaker.fed).count("Let me look at your files.") == 1


def test_stop_silences_the_rest_of_that_answer(tmp_path):
    voice, speaker = _voice(tmp_path)
    voice.settings.output_mode = "voice"
    voice.say_stream("t3", "The first sentence. The second one")
    voice.stop_speaking()
    voice.say_stream("t3", "The first sentence. The second one. And a third.")
    voice.finish_stream("t3", "The first sentence. The second one. And a third.")
    assert "And a third." not in "".join(speaker.fed)
    assert speaker.said == []


def test_complete_sentences_only():
    assert _complete_sentences("Done! The file is ready. And more") == "Done! The file is ready."
    assert _complete_sentences("**Done.** Next sentence.") == "**Done.**"
    assert _complete_sentences("No punctuation yet") == ""


def test_replies_are_cleaned_up_before_speaking():
    reply = (
        "Your Downloads folder has three files:\n\n"
        "- **holiday.jpg** — 3 KB\n"
        "- **invoice-sept-01.pdf** in C:\\Users\\badem\\Downloads\\invoice-sept-01.pdf\n"
        "See [the guide](https://example.com/docs) or https://example.com/x. Want me to `open` one?"
    )
    said = speakable(reply)
    assert "*" not in said and "C:\\" not in said and "https" not in said and "`" not in said
    assert "invoice-sept-01 PDF" in said and "the guide" in said and "a link. Want me" in said
    assert said.startswith("Your Downloads folder has three files. holiday picture, 3 KB.")


def test_whole_sentences_keep_their_natural_flow():
    phrases = _phrases("Done, your spreadsheet is ready with all three invoices. Want me to email it?")
    assert phrases == ["Done, your spreadsheet is ready with all three invoices.", "Want me to email it?"]
    long_first = _phrases("Okay, I found every invoice from last month in your Downloads folder and put them all into a "
                          "single spreadsheet with totals. Anything else?")
    assert long_first[0] == "Okay," and long_first[-1] == "Anything else?"


def test_typographic_spaces_and_hyphens_become_plain():
    from compii_core.providers import strip_thinking

    assert strip_thinking("UTC + 0, year‑round") == "UTC + 0, year-round"


def test_what_compii_says_out_loud_is_short_and_natural():
    from compii_core.voice import speakable, spoken_reply

    long = ("Done! I saved the report to C:/Users/me/Documents/research/report.md. It covers five sources. "
            "Here are the findings in detail. More detail follows.")
    said = spoken_reply(long)
    assert said == "Done! I saved the report to report. It covers five sources."
    assert speakable("Press Ctrl+Alt+W, e.g. to watch → then click e12 😀") == \
        "Press Control Alt W, for example to watch to then click."
    assert speakable("Saved Invoices.xlsx and summary.pdf") == "Saved Invoices spreadsheet and summary PDF."
    assert "(" not in speakable("It works (this part is a very long aside that nobody wants read out loud) fine.")
    assert speakable("Ghana is UTC + 0, about 3.5 hours away.") == "Ghana is UTC + 0, about 3.5 hours away."


def test_gpt_oss_channel_markers_never_reach_the_user():
    from compii_core.providers import strip_thinking

    leaked = "<|channel|>analysis<|message|>Need to answer.<|end|><|start|>assistant<|channel|>final<|message|>Ghana uses GMT."
    assert strip_thinking(leaked) == "Ghana uses GMT."
    assert strip_thinking("Analysis shows the file is fine.") == "Analysis shows the file is fine."

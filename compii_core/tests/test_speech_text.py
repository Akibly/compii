from compii_core.voice import _phrases, speakable


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

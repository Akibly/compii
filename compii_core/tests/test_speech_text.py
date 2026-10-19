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
    assert "invoice-sept-01.pdf" in said and "the guide" in said and "a link" in said
    assert said.startswith("Your Downloads folder has three files. holiday.jpg")


def test_whole_sentences_keep_their_natural_flow():
    phrases = _phrases("Done, your spreadsheet is ready with all three invoices. Want me to email it?")
    assert phrases == ["Done, your spreadsheet is ready with all three invoices.", "Want me to email it?"]
    long_first = _phrases("Okay, I found every invoice from last month in your Downloads folder and put them all into a "
                          "single spreadsheet with totals. Anything else?")
    assert long_first[0] == "Okay," and long_first[-1] == "Anything else?"

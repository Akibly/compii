"""Providers that failed for a real user with real keys (audit, 2026-10-27), and why
they don't any more. No network: each failure is replayed from what the API said."""

import asyncio

import httpx
import pytest

from compii_core.agent import BrainReply
from compii_core.keys import MemoryKeyStore
from compii_core.providers import (PRESETS, BrainChoice, FallbackBrain, OpenAICompatBrain, explain_refusal,
                                   make_brain, refuse_billing_text)


def _keys(**kv):
    ks = MemoryKeyStore()
    for k, v in kv.items():
        ks.set(k, v)
    return ks


def test_every_cloud_preset_names_a_default_model():
    blank = [n for n, p in PRESETS.items() if p["where"] == "cloud" and n != "custom" and not p["model"]]
    assert blank == [], "a stored key with no model chosen used to fail with 'choose a model first'"


def test_refusals_say_what_to_do_first():
    assert explain_refusal(401, "Incorrect API key provided").startswith("The key was refused")
    assert "free model" in explain_refusal(402, "requires more credits")
    assert "Global" in explain_refusal(400, "This Go model requires Global regions.")
    assert "isn't enabled for your account" in explain_refusal(404, "Function 'x': Not found for account 'y'")
    assert explain_refusal(500, "boom") == "500: boom"


def test_a_quota_notice_dressed_as_an_answer_is_not_read_out():
    notice = ("Sorry, to prevent abuse of free resources, accounts that have not been recharged can only try "
              "10 times. https://console.aihubmix.com/topup")
    with pytest.raises(RuntimeError, match="topped up"):
        refuse_billing_text(BrainReply([], notice, [], "end_turn"), "https://api.aihubmix.com/v1")
    fine = BrainReply([], "Here is your answer.", [], "end_turn")
    assert refuse_billing_text(fine, "https://api.aihubmix.com/v1") is fine


def test_flaky_free_tiers_get_a_backup_and_openrouter_a_token_budget():
    ks = _keys(nvidia="k", openrouter="k", mistral="k")
    nv = make_brain(BrainChoice("nvidia", ""), ks)
    assert isinstance(nv, FallbackBrain) and nv.backup.model == "openai/gpt-oss-20b"
    orr = make_brain(BrainChoice("openrouter", ""), ks)
    assert isinstance(orr, FallbackBrain)
    assert orr.primary.extra["max_tokens"] == 4096, "without it a free account is refused 402 up front"
    ms = make_brain(BrainChoice("mistral", ""), ks)
    assert isinstance(ms, FallbackBrain) and ms.backup.model == "open-mistral-nemo"


def test_a_rate_limit_without_retry_after_is_waited_out_not_given_up(monkeypatch):
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        if len(calls) == 1:
            return httpx.Response(429, json={"message": "Rate limit exceeded"})
        return httpx.Response(200, json={"choices": [{"message": {"content": "hello"}, "finish_reason": "stop"}]})

    async def no_sleep(_):
        return None

    monkeypatch.setattr(asyncio, "sleep", no_sleep)
    brain = OpenAICompatBrain("https://api.mistral.ai/v1", "mistral-small-latest", "k",
                              transport=httpx.MockTransport(handler))
    reply = asyncio.run(brain.step("s", [{"role": "user", "content": "hi"}], []))
    assert reply.text == "hello" and len(calls) == 2

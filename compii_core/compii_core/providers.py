"""Which AI does the thinking: Claude, or any OpenAI-compatible server.

OpenAI-compatible covers free local models (Ollama, LM Studio, llama.cpp
server) as well as OpenRouter and OpenAI. The conversation is stored in
Claude's block format; this module translates it for the other servers, so
you can switch brains between conversations, or even mid-conversation.

A fallback brain is only used when the user turned it on. Compii never
silently moves from a local model to a cloud one.
"""

from __future__ import annotations

import json
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from .agent import MODEL, BrainReply, ClaudeBrain, ToolCall
from .keys import KeyStore

PRESETS: dict[str, dict[str, str]] = {
    "claude": {"label": "Claude (Anthropic)", "base_url": "", "model": MODEL, "key": "anthropic", "where": "cloud",
               "price": "paid", "signup": "https://console.anthropic.com/settings/keys"},
    "groq": {"label": "Groq", "base_url": "https://api.groq.com/openai/v1", "model": "openai/gpt-oss-120b",
             "key": "groq", "where": "cloud", "price": "free tier", "signup": "https://console.groq.com/keys"},
    "gemini": {"label": "Google Gemini", "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
               "model": "gemini-2.5-flash", "key": "gemini", "where": "cloud", "price": "free tier",
               "signup": "https://aistudio.google.com/apikey"},
    "ollama_cloud": {"label": "Ollama Cloud", "base_url": "https://ollama.com/v1", "model": "gpt-oss:120b",
                     "key": "ollama", "where": "cloud", "price": "free tier", "signup": "https://ollama.com/settings/keys"},
    "openrouter": {"label": "OpenRouter", "base_url": "https://openrouter.ai/api/v1", "model": "", "key": "openrouter",
                   "where": "cloud", "price": "free models", "signup": "https://openrouter.ai/keys"},
    "ollama": {"label": "Ollama on this PC", "base_url": "http://127.0.0.1:11434/v1", "model": "qwen3:4b",
               "key": "", "where": "local", "price": "free", "signup": "https://ollama.com/download"},
    "lmstudio": {"label": "LM Studio on this PC", "base_url": "http://127.0.0.1:1234/v1", "model": "",
                 "key": "", "where": "local", "price": "free", "signup": "https://lmstudio.ai"},
    "openai": {"label": "OpenAI", "base_url": "https://api.openai.com/v1", "model": "", "key": "openai", "where": "cloud",
               "price": "paid", "signup": "https://platform.openai.com/api-keys"},
    "custom": {"label": "Other OpenAI-compatible", "base_url": "", "model": "", "key": "custom", "where": "cloud",
               "price": "", "signup": ""},
}


@dataclass
class BrainChoice:
    provider: str = "claude"
    model: str = ""
    base_url: str = ""

    def resolved(self) -> "BrainChoice":
        p = PRESETS.get(self.provider, PRESETS["custom"])
        return BrainChoice(self.provider, self.model or p["model"], self.base_url or p["base_url"])

    @property
    def local(self) -> bool:
        url = self.resolved().base_url
        return PRESETS.get(self.provider, {}).get("where") == "local" or "127.0.0.1" in url or "localhost" in url


@dataclass
class BrainSettings:
    primary: BrainChoice = field(default_factory=BrainChoice)
    fallback: BrainChoice | None = None
    fallback_enabled: bool = False

    @classmethod
    def load(cls, path: Path) -> "BrainSettings":
        try:
            d = json.loads(path.read_text(encoding="utf-8-sig"))
            fb = d.get("fallback")
            return cls(BrainChoice(**d.get("primary", {})), BrainChoice(**fb) if fb else None,
                       bool(d.get("fallback_enabled")))
        except (OSError, ValueError, TypeError):
            return cls()

    def save(self, path: Path) -> None:
        path.write_text(json.dumps(asdict(self), indent=1), encoding="utf-8")


class NoKeyError(RuntimeError):
    pass


# ---- OpenAI-compatible -----------------------------------------------------------


def _get(block: Any, key: str, default: Any = None) -> Any:
    return block.get(key, default) if isinstance(block, dict) else getattr(block, key, default)


def to_openai(system: str, messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = [{"role": "system", "content": system}]
    for m in messages:
        content = m["content"]
        if isinstance(content, str):
            out.append({"role": m["role"], "content": content})
            continue
        if m["role"] == "user":
            texts = []
            for b in content:
                if _get(b, "type") == "tool_result":
                    c = _get(b, "content", "")
                    if not isinstance(c, str):
                        c = "".join(_get(x, "text", "") for x in c)
                    out.append({"role": "tool", "tool_call_id": _get(b, "tool_use_id"),
                                "content": ("ERROR: " if _get(b, "is_error") else "") + c})
                elif _get(b, "type") == "text":
                    texts.append(_get(b, "text", ""))
            if texts:
                out.append({"role": "user", "content": "\n".join(texts)})
        else:
            text = "".join(_get(b, "text", "") for b in content if _get(b, "type") == "text")
            calls = [
                {"id": _get(b, "id"), "type": "function",
                 "function": {"name": _get(b, "name"), "arguments": json.dumps(dict(_get(b, "input", {}) or {}))}}
                for b in content if _get(b, "type") == "tool_use"
            ]
            msg: dict[str, Any] = {"role": "assistant", "content": text or None}
            if calls:
                msg["tool_calls"] = calls
            out.append(msg)
    return out


def tools_to_openai(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                              "parameters": t["input_schema"]}} for t in tools]


def _args(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    try:
        v = json.loads(raw or "{}")
        return v if isinstance(v, dict) else {}
    except ValueError:
        return {}


class OpenAICompatBrain:
    """Any server speaking /v1/chat/completions with tool calls."""

    def __init__(self, base_url: str, model: str, api_key: str | None = None, timeout: float = 300,
                 transport: Any = None) -> None:
        if not base_url or not model:
            raise ValueError("Choose a server address and a model first.")
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api_key = api_key
        self.timeout = timeout
        self.transport = transport  # tests

    async def step(self, system: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> BrainReply:
        import httpx

        body: dict[str, Any] = {"model": self.model, "messages": to_openai(system, messages), "stream": False}
        if tools:
            body["tools"] = tools_to_openai(tools)
        headers = {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {}
        async with httpx.AsyncClient(timeout=self.timeout, transport=self.transport) as client:
            r = await client.post(f"{self.base_url}/chat/completions", json=body, headers=headers)
        if r.status_code >= 400:
            try:
                detail = r.json().get("error", r.text)
                detail = detail.get("message", detail) if isinstance(detail, dict) else detail
            except ValueError:
                detail = r.text
            raise RuntimeError(f"{self.model} at {self.base_url} said {r.status_code}: {str(detail)[:300]}")
        choice = r.json()["choices"][0]
        msg = choice.get("message") or {}
        text = strip_thinking(msg.get("content") or "")
        blocks: list[dict[str, Any]] = [{"type": "text", "text": text}] if text else []
        calls = []
        for c in msg.get("tool_calls") or []:
            fn = c.get("function") or {}
            call = ToolCall(c.get("id") or f"call_{uuid.uuid4().hex[:12]}", fn.get("name", ""), _args(fn.get("arguments")))
            calls.append(call)
            blocks.append({"type": "tool_use", "id": call.id, "name": call.name, "input": call.input})
        finish = choice.get("finish_reason") or "stop"
        stop = "max_tokens" if finish == "length" else "tool_use" if calls else "end_turn"
        return BrainReply(blocks, text, calls, stop)


def strip_thinking(text: str) -> str:
    """Local reasoning models may include their scratch thoughts; never show or speak them."""
    import re

    return re.sub(r"<think>.*?(</think>|$)", "", text, flags=re.S).strip()


class OllamaBrain(OpenAICompatBrain):
    """Ollama's own API: a context window big enough for Compii's tools, and
    "thinking" off so replies come quickly on a home PC."""

    def __init__(self, base_url: str, model: str, context: int | None = None, **kw: Any) -> None:
        import os

        super().__init__(base_url, model, **kw)
        self.root = self.base_url.removesuffix("/v1")
        self.context = context or int(os.environ.get("COMPII_OLLAMA_CTX", "16384"))

    async def step(self, system: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> BrainReply:
        import httpx

        msgs = to_openai(system, messages)
        for m in msgs:  # Ollama wants tool arguments as objects, not JSON text
            for c in m.get("tool_calls") or []:
                c["function"]["arguments"] = _args(c["function"]["arguments"])
        body: dict[str, Any] = {
            "model": self.model, "messages": msgs, "stream": False, "think": False, "keep_alive": "30m",
            "options": {"num_ctx": self.context, "temperature": 0.3},
        }
        if tools:
            body["tools"] = tools_to_openai(tools)
        async with httpx.AsyncClient(timeout=self.timeout, transport=self.transport) as client:
            r = await client.post(f"{self.root}/api/chat", json=body)
        if r.status_code >= 400:
            try:
                detail = r.json().get("error", r.text)
            except ValueError:
                detail = r.text
            raise RuntimeError(f"Ollama ({self.model}) said {r.status_code}: {str(detail)[:300]}")
        data = r.json()
        msg = data.get("message") or {}
        text = strip_thinking(msg.get("content") or "")
        blocks: list[dict[str, Any]] = [{"type": "text", "text": text}] if text else []
        calls = []
        for c in msg.get("tool_calls") or []:
            fn = c.get("function") or {}
            call = ToolCall(c.get("id") or f"call_{uuid.uuid4().hex[:12]}", fn.get("name", ""), _args(fn.get("arguments")))
            calls.append(call)
            blocks.append({"type": "tool_use", "id": call.id, "name": call.name, "input": call.input})
        stop = "max_tokens" if data.get("done_reason") == "length" else "tool_use" if calls else "end_turn"
        return BrainReply(blocks, text, calls, stop)


class FallbackBrain:
    """Use the main brain; if it fails, the backup the user chose."""

    def __init__(self, primary: Any, backup: Any, on_fallback=None) -> None:
        self.primary, self.backup, self.on_fallback = primary, backup, on_fallback

    async def step(self, system, messages, tools) -> BrainReply:
        try:
            return await self.primary.step(system, messages, tools)
        except Exception as e:  # noqa: BLE001 - any failure of the main brain
            if self.on_fallback:
                self.on_fallback(str(e)[:200])
            return await self.backup.step(system, messages, tools)


def make_brain(choice: BrainChoice, keys: KeyStore) -> Any:
    c = choice.resolved()
    preset = PRESETS.get(c.provider, PRESETS["custom"])
    key = keys.get(preset["key"]) if preset["key"] else None
    if c.provider == "claude":
        import os

        if not key and not (os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN")):
            raise NoKeyError("Add your Anthropic key in Settings → Brain, or pick a free option there (Groq, Gemini, Ollama Cloud or Ollama on this PC).")
        brain = ClaudeBrain(model=c.model)
        if key:
            import anthropic

            brain.client = anthropic.AsyncAnthropic(api_key=key)
        return brain
    if preset["where"] == "cloud" and preset["key"] and not key:
        raise NoKeyError(f"Add your {preset['label']} key in Settings → Brain first.")
    if c.provider == "ollama":
        return OllamaBrain(c.base_url, c.model)
    return OpenAICompatBrain(c.base_url, c.model, key)


class MissingBrain:
    """Stands in when no brain is usable yet; every task explains how to fix it."""

    def __init__(self, reason: str) -> None:
        self.reason = reason

    async def step(self, system, messages, tools) -> BrainReply:
        raise RuntimeError(self.reason)


# ---- capability probe ----------------------------------------------------------------

_PING = {"name": "ping", "description": "Reply to a connection test.",
         "input_schema": {"type": "object", "properties": {"word": {"type": "string"}}, "required": ["word"],
                          "additionalProperties": False}}


async def probe(brain: Any) -> dict[str, Any]:
    """Can this brain answer, and can it use tools? (One tiny request.)"""
    t0 = time.monotonic()
    try:
        r = await brain.step("You are being tested. Follow the instruction exactly.",
                             [{"role": "user", "content": "Call the ping tool with the word hello."}], [_PING])
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "tools": False, "ms": int((time.monotonic() - t0) * 1000), "error": str(e)[:300]}
    tools = any(c.name == "ping" for c in r.tool_calls)
    return {"ok": True, "tools": tools, "ms": int((time.monotonic() - t0) * 1000),
            "note": "" if tools else "This model answered but didn't use tools, so it can chat but can't do tasks."}


async def local_models(base_url: str, api_key: str | None = None) -> list[str]:
    """Models a server offers: installed ones (Ollama on this PC) or, with a key, a cloud provider's list."""
    import httpx

    root = base_url.rstrip("/").removesuffix("/v1")
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    async with httpx.AsyncClient(timeout=8) as client:
        if not api_key:
            try:
                r = await client.get(f"{root}/api/tags")
                if r.status_code == 200:
                    return [m["name"] for m in r.json().get("models", [])]
            except httpx.HTTPError:
                pass
        r = await client.get(f"{base_url.rstrip('/')}/models", headers=headers)
        r.raise_for_status()
        return [m["id"] for m in r.json().get("data", [])]

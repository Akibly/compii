"""Which AI does the thinking: Claude, or any OpenAI-compatible server.

OpenAI-compatible covers free local models (Ollama, LM Studio, llama.cpp
server) as well as OpenRouter and OpenAI. The conversation is stored in
Claude's block format; this module translates it for the other servers, so
you can switch brains between conversations, or even mid-conversation.

A fallback brain is only used when the user turned it on. Compii never
silently moves from a local model to a cloud one.
"""

from __future__ import annotations

import asyncio
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
    "nvidia": {"label": "NVIDIA", "base_url": "https://integrate.api.nvidia.com/v1",
               "model": "nvidia/nemotron-3-super-120b-a12b", "key": "nvidia", "where": "cloud", "price": "free tier",
               "signup": "https://build.nvidia.com/settings/api-keys"},
    "ollama_cloud": {"label": "Ollama Cloud", "base_url": "https://ollama.com/v1", "model": "gpt-oss:120b",
                     "key": "ollama", "where": "cloud", "price": "free tier", "signup": "https://ollama.com/settings/keys"},
    "mistral": {"label": "Mistral", "base_url": "https://api.mistral.ai/v1", "model": "mistral-small-latest",
                "key": "mistral", "where": "cloud", "price": "free tier", "signup": "https://console.mistral.ai/api-keys"},
    "openrouter": {"label": "OpenRouter", "base_url": "https://openrouter.ai/api/v1", "model": "", "key": "openrouter",
                   "where": "cloud", "price": "free models", "signup": "https://openrouter.ai/keys"},
    "aihubmix": {"label": "AIHubMix", "base_url": "https://api.aihubmix.com/v1", "model": "coding-minimax-m3-free",
                 "key": "aihubmix", "where": "cloud", "price": "free models", "signup": "https://console.aihubmix.com/"},
    "opencode_go": {"label": "OpenCode Go (free models)", "base_url": "https://opencode.ai/inference/go/openai/v1",
                    "model": "deepseek-v4.1-flash", "key": "opencode", "where": "cloud", "price": "free tier",
                    "signup": "https://opencode.ai/auth", "models_url": "https://opencode.ai/inference/go/v1/models"},
    "opencode_zen": {"label": "OpenCode Zen", "base_url": "https://opencode.ai/zen/v1", "model": "claude-opus-4-8",
                     "key": "opencode", "where": "cloud", "price": "paid", "signup": "https://opencode.ai/auth"},
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
                 transport: Any = None, extra: dict[str, Any] | None = None,
                 session_header: str = "") -> None:
        if not base_url or not model:
            raise ValueError("Choose a server address and a model first.")
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api_key = api_key
        self.timeout = timeout
        self.transport = transport  # tests
        self.extra = extra or {}  # provider-specific request fields
        # Some gateways route and prompt-cache per conversation and refuse a request that
        # does not name one (OpenCode Go answers 400 MissingSessionID without it).
        self.session_header = session_header

    def headers(self, messages: list[dict[str, Any]]) -> dict[str, str]:
        out = {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {}
        if self.session_header:
            out[self.session_header] = _session_id(messages)
        return out

    async def step(self, system: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> BrainReply:
        reply = await self._step_once(system, messages, tools)
        if not reply.text and not reply.tool_calls:
            # Same as the stream: an empty answer is a dropped reply, worth one more ask.
            reply = await self._step_once(system, messages, tools)
        return reply

    async def _step_once(self, system: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> BrainReply:
        import httpx

        body: dict[str, Any] = {"model": self.model, "messages": to_openai(system, messages), "stream": False, **self.extra}
        if tools:
            body["tools"] = tools_to_openai(tools)
        headers = self.headers(messages)
        async with httpx.AsyncClient(timeout=self.timeout, transport=self.transport) as client:
            for attempt in range(3):  # busy free tiers: retry brief server hiccups
                r = await client.post(f"{self.base_url}/chat/completions", json=body, headers=headers)
                if r.status_code not in (429, 500, 502, 503, 504) or attempt == 2:
                    break
                wait = 1.5 * (attempt + 1)
                if r.status_code == 429:
                    # Over a free plan's limit: wait only if it clears almost at once;
                    # otherwise hand over to the backup straight away instead of stalling.
                    wait = _retry_after(r.headers)
                    if wait is None or wait > 2:
                        break
                await asyncio.sleep(wait)
        if r.status_code >= 400:
            try:
                detail = r.json().get("error", r.text)
                detail = detail.get("message", detail) if isinstance(detail, dict) else detail
            except ValueError:
                detail = r.text
            raise RuntimeError(f"{self.model} at {self.base_url} said {r.status_code}: {str(detail)[:300]}")
        data = r.json()
        return _chat_reply((data.get("choices") or [{}])[0], data.get("usage"))

    async def step_stream(self, system: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]],
                          on_text: Any) -> BrainReply:
        """Same answer, streamed: the app shows words while they are still being written."""
        import httpx

        body: dict[str, Any] = {"model": self.model, "messages": to_openai(system, messages), "stream": True, **self.extra}
        if tools:
            body["tools"] = tools_to_openai(tools)
        headers = self.headers(messages)
        text_parts: list[str] = []
        pieces: dict[int, dict[str, str]] = {}
        finish = "stop"
        usage: dict[str, Any] = {}
        async with httpx.AsyncClient(timeout=self.timeout, transport=self.transport) as client:
            for attempt in range(3):
                request = client.build_request("POST", f"{self.base_url}/chat/completions", json=body, headers=headers)
                r = await client.send(request, stream=True)
                if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
                    await r.aread()
                    detail = _error_text(r)
                    await r.aclose()
                    wait = 1.5 * (attempt + 1)
                    if r.status_code == 429:
                        wait = _retry_after(r.headers)
                        if wait is None or wait > 2:
                            raise RuntimeError(f"{self.model} at {self.base_url} said 429: {str(detail)[:300]}")
                    await asyncio.sleep(wait)
                    continue
                if r.status_code >= 400:
                    await r.aread()
                    detail = _error_text(r)
                    await r.aclose()
                    raise RuntimeError(f"{self.model} at {self.base_url} said {r.status_code}: {str(detail)[:300]}")
                # Some OpenAI-compatible servers ignore stream=true and answer with plain JSON.
                if "application/json" in r.headers.get("content-type", ""):
                    raw = await r.aread()
                    await r.aclose()
                    try:
                        data = json.loads(raw)
                    except ValueError:
                        data = None
                    if isinstance(data, dict) and data.get("choices"):
                        reply = _chat_reply(data["choices"][0], data.get("usage"))
                        if reply.text:
                            await on_text(reply.text)
                        return reply
                    raise RuntimeError(f"{self.model} at {self.base_url} sent a streaming reply that wasn't a stream")
                try:
                    async for line in r.aiter_lines():
                        if not line.startswith("data:"):
                            continue
                        payload = line[5:].strip()
                        if payload == "[DONE]":
                            break
                        try:
                            chunk = json.loads(payload)
                        except ValueError:
                            continue
                        choices = chunk.get("choices") or []
                        if chunk.get("usage"):
                            usage = _openai_usage(chunk["usage"]) or usage
                        if not choices:
                            continue
                        choice = choices[0]
                        delta = choice.get("delta") or {}
                        piece = delta.get("content")
                        if piece:
                            text_parts.append(piece)
                            await on_text(strip_thinking("".join(text_parts)))
                        for tc in delta.get("tool_calls") or []:
                            slot = pieces.setdefault(tc.get("index", 0), {"id": "", "name": "", "arguments": ""})
                            if tc.get("id"):
                                slot["id"] = tc["id"]
                            fn = tc.get("function") or {}
                            if fn.get("name"):
                                slot["name"] = fn["name"]
                            if fn.get("arguments"):
                                slot["arguments"] += fn["arguments"]
                        if choice.get("finish_reason"):
                            finish = choice["finish_reason"]
                finally:
                    await r.aclose()
                if strip_thinking("".join(text_parts)) or pieces or attempt == 2:
                    break
                # A stream with no words and no tool call is the gateway dropping the answer, not the
                # model choosing silence (Ollama Cloud does this mid-job): ask again rather than
                # letting the task stop half-done.
                text_parts.clear()
                pieces.clear()
                finish = "stop"
                await asyncio.sleep(0.5 * (attempt + 1))
        text = strip_thinking("".join(text_parts))
        blocks: list[dict[str, Any]] = [{"type": "text", "text": text}] if text else []
        calls: list[ToolCall] = []
        for index in sorted(pieces):
            slot = pieces[index]
            if not slot["name"]:
                continue
            call = ToolCall(slot["id"] or f"call_{uuid.uuid4().hex[:12]}", slot["name"], _args(slot["arguments"]))
            calls.append(call)
            blocks.append({"type": "tool_use", "id": call.id, "name": call.name, "input": call.input})
        stop = "max_tokens" if finish == "length" else "tool_use" if calls else "end_turn"
        return BrainReply(blocks, text, calls, stop, usage)


def _chat_reply(choice: Any, usage: Any = None) -> BrainReply:
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
    return BrainReply(blocks, text, calls, stop, _openai_usage(usage))


def _openai_usage(u: Any) -> dict[str, Any]:
    """The token counts the server reported, if it reported any."""
    if not isinstance(u, dict):
        return {}
    return {"prompt": int(u.get("prompt_tokens") or u.get("input_tokens") or 0),
            "completion": int(u.get("completion_tokens") or u.get("output_tokens") or 0)}


def _ollama_usage(d: dict[str, Any]) -> dict[str, Any]:
    return {"prompt": int(d.get("prompt_eval_count") or 0), "completion": int(d.get("eval_count") or 0)}


def _error_text(r: Any) -> Any:
    try:
        detail = r.json().get("error", r.text)
        return detail.get("message", detail) if isinstance(detail, dict) else detail
    except ValueError:
        return r.text


def _retry_after(headers: Any) -> float | None:
    try:
        return float(headers.get("retry-after"))
    except (TypeError, ValueError):
        return None


def _session_id(messages: list[dict[str, Any]]) -> str:
    """A stable id for this conversation, derived from the first thing the user asked.

    OpenCode Go routes and prompt-caches on it, so it must not be random per request."""
    first = next((m.get("content") for m in messages if m.get("role") == "user"), "")
    if not isinstance(first, str):  # content blocks: join the text of the first turn
        first = " ".join(str(b.get("text", "")) for b in first if isinstance(b, dict))
    return "ses_" + uuid.uuid5(uuid.NAMESPACE_URL, first).hex


def strip_thinking(text: str) -> str:
    """Local reasoning models may include their scratch thoughts; never show or speak them.
    Typographic spaces and hyphens (gpt-oss loves them) become plain ones, so the voice reads them right."""
    import re

    text = text.translate(PLAIN_TYPOGRAPHY)
    text = re.sub(r"<think>.*?(</think>|$)", "", text, flags=re.S)
    # gpt-oss sometimes leaks its internal channel markers ("<|channel|>analysis", "commentary to=…").
    if "<|" in text or "to=functions" in text:
        # Keep only what follows the last "final" marker when there is one; drop the scaffolding.
        final = re.split(r"<\|channel\|>\s*final\s*<\|message\|>", text)
        text = final[-1]
        text = re.sub(r"<\|[^|>]{1,40}\|>", " ", text)
        text = re.sub(r"\b(?:assistant\s*)?(?:analysis|commentary)\s+to=\S+[^\n]*", "", text)
    return text.strip()


PLAIN_TYPOGRAPHY = str.maketrans({" ": " ", " ": " ", " ": " ", " ": " ", " ": " ",
                                  "‑": "-", "‐": "-", "​": ""})


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
        return BrainReply(blocks, text, calls, stop, _ollama_usage(data))

    async def step_stream(self, system: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]],
                          on_text: Any) -> BrainReply:
        import httpx

        msgs = to_openai(system, messages)
        for m in msgs:
            for c in m.get("tool_calls") or []:
                c["function"]["arguments"] = _args(c["function"]["arguments"])
        body: dict[str, Any] = {
            "model": self.model, "messages": msgs, "stream": True, "think": False, "keep_alive": "30m",
            "options": {"num_ctx": self.context, "temperature": 0.3},
        }
        if tools:
            body["tools"] = tools_to_openai(tools)
        text_parts: list[str] = []
        calls: list[ToolCall] = []
        done_reason = None
        usage: dict[str, Any] = {}
        async with httpx.AsyncClient(timeout=self.timeout, transport=self.transport) as client:
            async with client.stream("POST", f"{self.root}/api/chat", json=body) as r:
                if r.status_code >= 400:
                    await r.aread()
                    raise RuntimeError(f"Ollama ({self.model}) said {r.status_code}: {str(_error_text(r))[:300]}")
                async for line in r.aiter_lines():
                    if not line.strip():
                        continue
                    try:
                        data = json.loads(line)
                    except ValueError:
                        continue
                    msg = data.get("message") or {}
                    piece = msg.get("content")
                    if piece:
                        text_parts.append(piece)
                        await on_text(strip_thinking("".join(text_parts)))
                    for c in msg.get("tool_calls") or []:
                        fn = c.get("function") or {}
                        calls.append(ToolCall(c.get("id") or f"call_{uuid.uuid4().hex[:12]}",
                                              fn.get("name", ""), _args(fn.get("arguments"))))
                    if data.get("done"):
                        done_reason = data.get("done_reason")
                        usage = _ollama_usage(data)
                        break
        text = strip_thinking("".join(text_parts))
        blocks: list[dict[str, Any]] = [{"type": "text", "text": text}] if text else []
        calls = [c for c in calls if c.name]
        for call in calls:
            blocks.append({"type": "tool_use", "id": call.id, "name": call.name, "input": call.input})
        stop = "max_tokens" if done_reason == "length" else "tool_use" if calls else "end_turn"
        return BrainReply(blocks, text, calls, stop, usage)


class FallbackBrain:
    """Use the main brain; if it fails, the backup the user chose."""

    def __init__(self, primary: Any, backup: Any, on_fallback=None) -> None:
        self.primary, self.backup, self.on_fallback = primary, backup, on_fallback
        self.used = primary  # which one answered last: usage is counted against it

    @property
    def provider(self) -> str:
        return str(getattr(self.used, "provider", "") or "")

    @property
    def model(self) -> str:
        return str(getattr(self.used, "model", "") or "")

    async def step(self, system, messages, tools) -> BrainReply:
        try:
            reply = await self.primary.step(system, messages, tools)
        except Exception as e:  # noqa: BLE001 - any failure of the main brain
            if self.on_fallback:
                self.on_fallback(str(e)[:200])
            self.used = self.backup
            return await self.backup.step(system, messages, tools)
        self.used = self.primary
        return reply

    async def step_stream(self, system, messages, tools, on_text) -> BrainReply:
        try:
            reply = await self._run(self.primary, system, messages, tools, on_text)
        except Exception as e:  # noqa: BLE001 - the backup takes over mid-answer if it must
            if self.on_fallback:
                self.on_fallback(str(e)[:200])
            self.used = self.backup
            return await self._run(self.backup, system, messages, tools, on_text)
        self.used = self.primary
        return reply

    @staticmethod
    async def _run(brain, system, messages, tools, on_text) -> BrainReply:
        stream = getattr(brain, "step_stream", None)
        return await (stream(system, messages, tools, on_text) if stream else
                      brain.step(system, messages, tools))


ENV_KEYS = {"mistral": "MISTRAL_API_KEY", "nvidia": "NVIDIA_API_KEY", "groq": "GROQ_API_KEY", "gemini": "GEMINI_API_KEY", "ollama": "OLLAMA_API_KEY",
            "openrouter": "OPENROUTER_API_KEY", "openai": "OPENAI_API_KEY", "opencode": "OPENCODE_API_KEY",
            "aihubmix": "AIHUBMIX_API_KEY"}


def _env_key(name: str) -> str | None:
    """A key from the environment (e.g. NVIDIA_API_KEY), as provider examples use; Settings wins."""
    import os

    return os.environ.get(ENV_KEYS.get(name, ""), "").strip() or None


def _tag(brain: Any, provider: str, model: str) -> Any:
    """Stamp which provider and model this brain actually calls — the usage ledger counts against it."""
    brain.provider, brain.model = provider, model
    return brain


def make_brain(choice: BrainChoice, keys: KeyStore) -> Any:
    c = choice.resolved()
    preset = PRESETS.get(c.provider, PRESETS["custom"])
    key = (keys.get(preset["key"]) or _env_key(preset["key"])) if preset["key"] else None
    if c.provider == "claude":
        import os

        if not key and not (os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN")):
            raise NoKeyError("Add your Anthropic key in Settings → Brain, or pick a free option there (Groq, Gemini, Ollama Cloud or Ollama on this PC).")
        brain = ClaudeBrain(model=c.model)
        if key:
            import anthropic

            brain.client = anthropic.AsyncAnthropic(api_key=key)
        return _tag(brain, c.provider, c.model)
    if preset["where"] == "cloud" and preset["key"] and not key:
        raise NoKeyError(f"Add your {preset['label']} key in Settings → Brain first.")
    if c.provider == "ollama":
        return _tag(OllamaBrain(c.base_url, c.model), c.provider, c.model)
    if c.provider == "nvidia":
        # Thinking off: Compii answers out loud, so speed matters more than long reasoning.
        return _tag(OpenAICompatBrain(c.base_url, c.model, key, extra={
            "chat_template_kwargs": {"enable_thinking": False}, "temperature": 0.6, "top_p": 0.95,
            "max_tokens": 4096}), c.provider, c.model)
    if c.provider == "groq" and c.model.startswith("openai/gpt-oss"):
        # Spoken answers: brief reasoning is plenty and much faster. Each model has its own
        # free per-minute limit, so the other gpt-oss model stands in before any slower backup.
        fast = {"reasoning_effort": "low"}
        main = _tag(OpenAICompatBrain(c.base_url, c.model, key, extra=fast), c.provider, c.model)
        other = "openai/gpt-oss-20b" if c.model != "openai/gpt-oss-20b" else "openai/gpt-oss-120b"
        return FallbackBrain(main, _tag(OpenAICompatBrain(c.base_url, other, key, extra=fast), c.provider, other))
    if c.provider in ("opencode_go", "opencode_zen"):
        # OpenCode's gateway answers 400 MissingSessionID unless every request names its
        # conversation, so the brain carries a stable session id derived from the first turn.
        return _tag(OpenAICompatBrain(c.base_url, c.model, key, session_header="x-opencode-session"),
                    c.provider, c.model)
    return _tag(OpenAICompatBrain(c.base_url, c.model, key), c.provider, c.model)


class MissingBrain:
    """Stands in when no brain is usable yet; every task explains how to fix it."""

    def __init__(self, reason: str) -> None:
        self.reason = reason

    async def step(self, system, messages, tools) -> BrainReply:
        raise RuntimeError(self.reason)


class BotBrains:
    """The AI each teammate answers with, built once from its own choice and kept.

    No choice means None here — answer with Compii's brain — because a role, a lane of
    tools and a memory are not a model. When the user does name one, the chosen AI is the
    one that speaks, and a choice that cannot be built is reported in their words instead
    of quietly answering from a different model."""

    def __init__(self, keys: KeyStore) -> None:
        self.keys = keys
        self._built: dict[tuple[str, str], Any] = {}
        self._problems: dict[tuple[str, str], str] = {}

    def reset(self) -> None:
        """A new key or a new Settings brain changes what any of these can be."""
        self._built.clear()
        self._problems.clear()

    def build(self, provider: str, model: str) -> Any:
        key = (provider, model)
        if key not in self._built:
            self._built[key] = make_brain(BrainChoice(provider, model), self.keys)
            self._problems.pop(key, None)
        return self._built[key]

    def resolve(self, bot: dict[str, Any] | None) -> tuple[Any | None, str | None]:
        """(the brain this teammate answers with, or None for Compii's) and why it isn't there."""
        provider = str((bot or {}).get("provider") or "").strip()
        if not provider:
            return None, None
        model = str((bot or {}).get("model") or "").strip()
        key = (provider, model)
        if key in self._built:
            return self._built[key], None
        if key in self._problems:
            return None, self._problems[key]
        try:
            return self.build(provider, model), None
        except (NoKeyError, ValueError) as e:
            self._problems[key] = str(e)
            return None, str(e)


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


async def local_models(base_url: str, api_key: str | None = None, models_url: str | None = None) -> list[str]:
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
        r = await client.get(models_url or f"{base_url.rstrip('/')}/models", headers=headers)
        r.raise_for_status()
        return [m["id"] for m in r.json().get("data", [])]

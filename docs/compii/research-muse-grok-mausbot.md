# Learning from the beasts: Meta Muse, Grok Bot, MausBot + the Compii spec pack

Date: 2026-10-18. Inputs: the assignment PDFs (PRD, README, SECURITY, ARCHITECTURE v1.0,
2026-10-17) and public reporting on three agent products. Vendor claims are marked as such.

## What the three products do

| | Meta Muse (launched Sept 2026) | Grok Bot (xAI, beta since 11 Aug 2026) | MausBot (open source, Apache-2.0) |
|---|---|---|---|
| Where it runs | Cloud VM per user with a watchable browser; Mac app operates local apps | One persistent cloud computer per account, a screen per bot | Your own PC (local server on 127.0.0.1), optional cloud desktop |
| Brain | Meta's models | Not disclosed | Your installed `claude` / `codex` / `grok` CLIs, any model per bot |
| Signature ideas | Realtime video avatar; wake word on glasses; its own email address; commerce connectors; "Sentinel" read/write permission levels | **Teach a task** (record a workflow once, ≤10 min, it repeats it); skills → routines promotion; bots in group chat; **Allow once / Deny / Always allow** approvals saved as rules, "require approval" rules win; human takeover for passwords/2FA/CAPTCHA/payments | Bots as chat contacts (pin/unread/hide); voice calls that narrate work and ask approvals aloud; **write-only keys**; **routines calendar**; webhooks; **skill recorder**; phone companion that controls the PC; mascot with 20+ expressions |
| Safety | Approval before send/purchase; per-service read vs write | Approval rules + "Auto Review"; human takeover; secrets masked from the model | Approval gate, held drafts, local-only storage, localhost-only server |

Sources: [Muse on Wikipedia](https://en.wikipedia.org/wiki/Muse_(AI_agent)),
[TechCrunch, Connect 2026](https://techcrunch.com/2026/09/23/everything-new-coming-to-metas-ai-agent-muse/),
[Meta announcement](https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/),
[Grok Bot explainer](https://www.digitalapplied.com/blog/grok-bot-ai-teammates-launch-cloud-computer-2026),
[Interesting Engineering](https://interestingengineering.com/ai-robotics/xai-grok-bot-computer-agent),
[MausBot](https://mausbot.com/), [MausBot blog](https://mausbot.com/blog/ai-agent-that-controls-your-computer).

## What Compii already had (before this round)

Agent with plan checklist, undo journal, autonomy dial; files/spreadsheets/Python/email;
Windows apps via UI Automation; its own browser; point-at overlay; free local voice
(Whisper + Kokoro) with barge-in; "Hey Compii" wake word; routines, watches, daily brief,
updates inbox; phone pairing (encrypted LAN, device keys); Orbling character.

So Compii already matches Muse/Grok/MausBot on: approvals, routines, watches, voice that asks
approvals aloud, mascot with moods, phone companion, local-first storage, localhost server.

## Gaps worth stealing, ranked

1. **Free brain (spec: provider layer, Ollama first-class; MausBot: any model per bot).**
   Compii only spoke to Claude, and this PC has no key. → Provider layer with Claude and any
   OpenAI-compatible server (Ollama, LM Studio, llama.cpp, OpenRouter, OpenAI), a capability
   probe ("can it use tools?"), and an opt-in fallback chain (no silent cloud fallback).
2. **Keys in Windows Credential Manager, write-only (spec T3; MausBot).** Never in a file,
   never shown back.
3. **Always allow / require approval rules (Grok).** Approval cards get "Always allow"; the
   rule is scoped (this tool + this folder/site/window) and is revocable in Settings.
   Spend can never be always-allowed.
4. **Always-blocked actions (spec §5).** Lock/sign-out/shutdown shortcuts, installing
   software, security settings, money: refused by code, not by the model.
5. **Prompt-injection containment (spec §6).** Screen/file/web text is wrapped as untrusted
   data; suspected injections are reported once; after one, risky actions need fresh
   approval even if a rule allowed them.
6. **Redaction before cloud (spec T2).** Card numbers, API keys, SSN-like strings are masked
   in tool output before it goes to a cloud model, with an indicator.
7. **Kill switch (spec).** Ctrl+Alt+Shift+S stops everything, silences voice and switches
   Compii to "ask for everything" until you lift it.
8. **Tamper-evident audit log (spec T13).** Append-only, hash-chained, verifiable in-app.
9. **Skills — "teach once, repeat" (Grok teach-a-task, MausBot skill recorder).** Save any
   finished conversation as a skill; Compii can reuse it by name and you can promote it to a
   routine (Grok's "test on a one-off first, then make it a routine").
10. **Walkthroughs — "Teach me to…" (spec §7).** Compii points at each step, waits for you to do
    it, checks the screen (UI Automation) and moves on.

Deliberately not taken: cloud VMs (Compii is local-first), commerce/checkout connectors (Compii
never pays), human call centres, video avatar (the Orbling is the character).

## Status (2026-10-19)

All ten are built and tested: Core in `guard.py`, `providers.py`, `keys.py`, `policy.py` (Gate, rules),
`audit.py`, `skills.py`, `walkthrough.py`; the app in `lib/src/ui/trust.dart` (Settings → Brain, Safety page,
Skills page, lockdown and walkthrough bars, "Always allow" and "Save as skill") plus the Ctrl+Alt+Shift+S kill
switch. Not yet tried with a real local model: Ollama isn't installed on this PC.

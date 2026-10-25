# Grok Bot, Meta Muse and Claude Duet: what to take, what Compii already has

October 2026. Earlier notes on Muse and Grok are in [research-muse-grok-mausbot.md](research-muse-grok-mausbot.md); this pass adds Claude Duet (announced 21 October 2026) and what changed since.

All three are now the same shape: a personal agent with its own cloud computer that keeps working when your device is off, reaches your accounts through connectors, and asks before anything consequential. Compii's difference is that it runs on your PC, against your own apps and files, with any model, and nothing goes to a server of ours. That difference is worth keeping. The features below are about the experience around the work, not where it runs.

Most of what follows comes from launch coverage, not hands-on reviews, and some details conflict between sources. Treat specifics as provisional.

## The three products

**Grok Bot (xAI).** Early beta since 11 August 2026; macOS, Windows, iPhone; $200/month standalone, or bundled with SuperGrok Heavy and some Cursor plans. Named Bots, each with a short name, one job and a description, created from a suggested role or from scratch. Two to six Bots in a group chat message each other and pass ownership. All Bots share one cloud computer (browser, files, terminal) but keep their own role, preferences and summaries. Routines run on a schedule or after an event. "Teach a task": you do a browser workflow once and it drafts a skill for you to review. Approvals for sending, publishing, deleting, buying and production changes; passwords, 2FA and CAPTCHAs stay with you. Reviewers' complaints: memories cannot be seen, corrected, exported or deleted; xAI models only; Bots are not separate security boundaries.

**Meta Muse.** Launched 8 September 2026 (US, then Canada) on iOS, Android, muse.ai and WhatsApp; free, $20 and $100 tiers with a visible usage meter. Each user gets a dedicated VM with a browser. Asks before sending a message or spending money; you choose which accounts it can see. Keeps "a complete audit trail of everything it has done and plans to do." Remembers what matters and forgets on request. Makes suggestions unasked and comes back when it needs input. Muse for Mac (17 September): works across Files, Mail, Messages, Calendar and Notes, with per-app opt-in access; examples are tidying Downloads, filling forms from local files, and an end-of-day recap of messages and notes. Connect (23 September): its own email address you forward things to, a Realtime Avatar for video calls (coming soon), smart-glasses wake word (coming soon). A separate "Sentinel" agent controls what leaves the VM.

**Claude Duet (Anthropic).** Research preview since 21 October 2026, US Pro and Max, waitlist; iOS, Android, web. Built on Claude Opus 5.5, carrying the user's Claude memory, skills and connectors (6,000+). One ongoing thread for text and voice. A morning brief of what needs attention, then a check of connected apps every few hours, notifying only when something needs action; the user sets what it watches and when, and more frequent checks cost more usage. Background tasks on its own VM; you can see what it has done and is doing. Asks before sending, paying, signing or deleting; never trades or moves money between accounts. A classifier screens for sensitive data: card numbers and government ID are refused, health and finances shared only on explicit instruction. Purchases through Link or Shop Pay with a virtual card. Anthropic says it "might misread a thread or miscalibrate what's urgent."

## Feature by feature

| Feature | Seen in | Compii |
| --- | --- | --- |
| Named agents with a role, job and own memory | Grok | Has it: teammates with roles, lanes of tools, own memory and model |
| Group chat of agents passing work | Grok (2-6) | Has it: team chats up to 6, handoff, delegate and review |
| Teach a task by doing it once | Grok | Has it: "watch me" demonstrations become skills |
| Scheduled routines and event triggers | Grok, Duet | Has it: routines, folder/web/AI watches |
| Morning brief | Duet | Has it |
| **End-of-day recap** | Muse for Mac, Duet | **Added in this pass** |
| **Check every few hours, notify only when needed** | Duet | **Added in this pass** |
| Approvals: once, deny, always | Grok, Muse, Duet | Has it, plus scoped rules, lockdown and a kill switch |
| Hand over passwords and codes | Grok, Duet | Has it: hand_to_user, and it refuses to type secrets |
| Audit trail | Muse | Has it, hash-chained and verifiable |
| Memory you can see and remove | Muse (forget on request) | Has it; Grok lacks it |
| Forget a specific memory by asking | Muse | Added by the island session (forget_memory) |
| Sensitive-data screening | Duet | Has it: redaction of cards, keys and IDs before the model sees them |
| Its own browser | all three | Has it: a separate Edge profile |
| Phone access | Grok, Muse, Duet | Has it: paired phone |
| Usage meter | Muse | Partly: usage_report and the ledger exist; no meter in the app yet |
| Agent email address to forward things to | Muse | Not yet |
| Works while your computer is off | all three | No, by design: Compii is local |
| Realtime video avatar | Muse (coming soon) | No; Compii has a character face instead |
| Virtual-card purchases | Duet, Muse | No, and deliberately: Compii never completes payments |

## What was built from this

1. **End-of-day recap** (`proactive.compose_recap`). At 18:00 by default: what finished today, what didn't and why, what still waits on you, what your watches caught, and the first routines tomorrow. Built from the conversations Compii already holds, so it costs no model call. Goes to the updates inbox without speaking.
2. **"Needs you" check** (`proactive.compose_checkin`). Every 3 hours between 08:00 and 21:00 by default, a look at what has waited on you for more than 20 minutes, or failed today. It posts only when it finds something, and only once per task. It speaks, because it exists to reach you.
3. Settings: `PUT /recap {enabled, at}` and `PUT /checkin {enabled, every_hours, start, end}`; `GET /proactive` shows both. The app still needs a toggle for each.

## Worth doing next

- **An email address to forward things to** (Muse). In Compii's shape: a mail folder (e.g. Outlook "Compii") that it watches, accepting only mail from the user's own address, with the forwarded text treated as untrusted data and the user's covering note as the request.
- **A usage meter in the app** (Muse). The numbers are already in the ledger.
- **Choose what the check-in looks at** (Duet). Today it looks at Compii's own threads; Outlook and the watches could join it.
- **Share a teammate as a template** (Grok's planned template sharing): export a teammate's role, lanes and instructions, without its memory.

## Sources

- [Official Grok Bot Breakdown (Vellum)](https://www.vellum.ai/blog/official-grok-bot-breakdown) — written by a competitor
- [A Guide to Grok Bot (Composio)](https://composio.dev/content/guide-to-frok-bot)
- [Grok Bot is xAI's new 24/7 coworker (Interesting Engineering)](https://interestingengineering.com/ai-robotics/xai-grok-bot-computer-agent)
- [xAI Grok Bot template sharing and multi-account (AIbase)](https://news.aibase.com/news/30628)
- [What Meta actually shipped with Muse (Tech Insider)](https://tech-insider.org/what-meta-actually-shipped-with-muse/)
- [Meta Muse Guide 2026 (Codersera)](https://codersera.com/blog/meta-muse-ai-agent-app-guide-2026/)
- [Everything new coming to Meta's AI agent Muse (TechCrunch)](https://techcrunch.com/2026/09/23/everything-new-coming-to-metas-ai-agent-muse/)
- [Meta pushes into personal AI agents (CNBC)](https://www.cnbc.com/2026/09/08/meta-personal-ai-agents-public-reckoning-privacy-safety.html)
- [Claude Duet app is Anthropic's bet on agents (TechCrunch)](https://techcrunch.com/2026/10/22/claude-duet-app-is-anthropics-bet-on-agents/)
- [Anthropic rolls out Claude Duet (FoneArena)](https://www.fonearena.com/blog/495483/anthropic-claude-duet-features.html)
- [Claude Duet is the new Android rival to Gemini Intelligence (Android Authority)](https://www.androidauthority.com/claude-duet-android-app-launch-capabilities-features-3726465/)
- [Anthropic announces preview of Claude Duet (CNBC)](https://www.cnbc.com/2026/10/21/anthropic-preview-of-claude-duet-personal-ai-agent-take-on-muse-dots.html)

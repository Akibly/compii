# Compii vs the 2026 field, and the road to a product

Date: 2026-10-20. Builds on [research-clicky-competitors.md](research-clicky-competitors.md) and
[research-muse-grok-mausbot.md](research-muse-grok-mausbot.md). Vendor claims are marked as such; many
sources are secondary reviews, so treat specific numbers as indicative.

## Bottom line

Compii already does things no single competitor combines: it lives beside your cursor on Windows,
teaches with pointing, drawing, walkthroughs and lessons that remember, sees apps that draw their own
screens, does real work with approvals, and runs on free AI with its voice on your PC. HeyClicky, the
closest product, is still Mac-only with a Windows waitlist.

What stands between Compii and "best in the world" is no longer features. It is **being a product**:
installing in one click, updating itself, starting up reliably, a first run that sets everything up
without terminal commands, and conversation that feels as fluid as ChatGPT's or Gemini's voice.

## The field in October 2026

| Product | What it is | Platform, price | What Compii takes or beats |
|---|---|---|---|
| **HeyClicky** | Cursor buddy: hold a key, talk, it points and draws, walkthroughs advance on click | Mac only (Windows waitlist), $20–100/mo above free | Compii is on Windows and free. Matched: pointing, drawing, walkthroughs, dictation, memory. Compii adds lessons, actions with approvals and vision fallback |
| **Microsoft Copilot** (Windows) | "Hey Copilot" wake word, Copilot Vision (screen sharing), Copilot Actions (experimental multi-step on local files) | Built into Windows | Copilot Vision never clicks or types; Actions is experimental and users report wrong-but-plausible output and outages. Compii: buddy at the cursor, teaching, honest approvals, free model choice |
| **ChatGPT desktop** | GPT-Live voice (since Jul 2026) controls agents; Computer Use on Windows (foreground only) | Plus and up | Best-in-class voice feel. Compii must close the gap with streaming and barge-in (roadmap phase 2) |
| **Claude desktop** | Computer use in Cowork/Code (Windows beta since Apr 2026, needs Hyper-V for Cowork), Claude in Chrome, voice beta | Pro/Max | A general agent, not a companion. Compii runs on Windows Home too and needs no subscription |
| **Gemini** | Gemini Agent (Mariner folded in, May 2026), Gemini in Chrome, Live screen/camera on phones | Paid tiers for agent features | Browser-first; desktop OS control not its focus. Compii owns the Windows desktop |
| **Perplexity Comet** | AI browser with an assistant that acts across tabs | Free core, $20–200 for agents | Web only. Compii researches quietly with search_web/read_web_page and acts in desktop apps |
| **Highlight AI** | Always-on screen Q&A and recall ($40M Series A, Mar 2026) | ~$20/mo with credit caps | Doesn't click or type; continuous capture. Compii looks only when asked |
| **Littlebird** | Mac assistant with long-term memory of your work | Mac | Compii's memory is facts + lessons; a daily work journal is a gap (phase 3) |
| **Screenpipe** | Local recorder of screen and audio | Source-available | A capture layer, not an assistant |
| **Cluely** | Hidden meeting copilot | Mac/Windows | Deliberately not copied (hidden from others; ethics) |
| **Grok Bot, Meta Muse, MausBot** | See the earlier research note | | Already taken: teach-a-task, approval rules, phone companion |
| **Community "Clicky for Windows" ports** | Python/PyQt ports with Ollama | Free, open source | Show the demand. Compii is far further along (actions, safety, teaching, voice) |

What users complain about across these products: wrong-but-confident answers, outages and slow
replies, unclear costs (credits), and privacy of always-on screen capture. Each is a place Compii can win.

## Where Compii leads today

- **Windows, free, no subscription.** Groq for thinking and hearing, NVIDIA as backup and for vision, voice on the PC.
- **Teaching that remembers.** Lessons survive restarts ("what next?"), walkthroughs advance when you click,
  and Compii circles, underlines and draws arrows on screen.
- **Sees self-drawn apps** (Blender, games, design tools): a picture of just that window, only when asked;
  ~15 px pointing accuracy with NVIDIA's free nemotron VL in tests.
- **Show it, and it shows you.** Draw on screen while holding Ctrl+Alt; "watch me" records a task as a skill.
- **Trust built in.** Approvals by voice or with Yes/No beside the cursor, always-allow rules, blocked actions,
  prompt-injection handling, redaction, a kill switch and a tamper-evident audit log.
- **A character with nine moods** that matches its voice, and a phone companion in progress.

## Gaps, ranked by what users would feel first

1. **Not installable.** Core runs from the source folder with `uv`; there's no installer, no code signing
   (Windows SmartScreen will warn), no auto-update, and keys are set with terminal commands.
2. **Conversation feel.** Replies arrive whole, then are spoken. ChatGPT and Gemini stream speech and handle
   interruptions smoothly. Full-duplex research (Moshi, NVIDIA PersonaPlex) shows where this is heading.
3. **Free-tier fragility.** Groq's free plan allows ~8K tokens a minute per model; NVIDIA is slow at times.
   There's no offline brain unless Ollama is set up.
4. **First run.** No guided setup: voice download, mic check, free keys, privacy choices, start with Windows.
5. **One monitor.** The buddy overlay covers only the primary screen.
6. **Diagnostics.** Core logs to a file; the app has no crash reporting and there's no "send a report" button.
7. **Memory of your day** (Littlebird-style journal), with clear controls.
8. **Mobile** (in progress in its own session) and **chat from anywhere** (deferred).
9. **Accessibility and languages**: screen-reader labels, keyboard-only use, more than English.

## Roadmap

### Phase 1: an installable beta (about 2 weeks)

- **Bundle Core** with its own Python: a relocatable runtime (python-build-standalone via `uv`) plus a
  pre-built environment, so nothing needs installing. Voice models keep downloading in-app with progress.
  PyInstaller/Nuitka are alternatives but struggle with onnxruntime and ctranslate2.
- **Installer and auto-update with Velopack**: one setup.exe, delta updates, release channels (beta,
  stable). There's a Flutter wrapper (`velopack_flutter`).
- **Code signing**: Azure Artifact Signing is the cheapest route but is only open to individuals in the
  US and Canada (organisations: also EU/UK); otherwise an OV certificate. Either way, SmartScreen
  reputation builds over consecutive signed releases, not instantly.
- **First-run setup**: pick a voice, mic test, one-click "get a free Groq key" with an in-app paste box
  (stored in Credential Manager, never shown back), privacy choices, start with Windows.
- **Overlay on every monitor**, and the buddy follows the cursor across them.
- **Diagnostics**: app crash capture, Core log, "Send report" that bundles both with personal data removed.

### Phase 2: conversation that feels alive (1–2 weeks)

- **Stream replies into speech**: start speaking the first sentence while the rest is written.
- **Barge-in everywhere**: talking over Compii stops it at once and treats your words as a reply.
- **Quick vs deep router**: small, fast model for chit-chat and facts; the big one for tasks
  (HeyClicky does this too).
- **Offline brain**: Ollama with a small model as the last fallback, so Compii never just fails.
- **Warmer persona**: a short style guide for replies (contractions, encouragement when teaching,
  no lists aloud), checked by tests on spoken output.

### Phase 3: the best teacher on any PC (2 weeks)

- **Lesson view** in the app: steps, progress, "continue", with the character cheering milestones.
- **Lesson packs** for popular apps (Blender, Excel, Photoshop, VS Code), each a tested plan.
- **Check the step was done** using UI Automation or a before/after picture, then praise or help.
- **Daily journal** (opt-in): what you worked on and learned, so "what was I doing yesterday?" works.

### Phase 4: everywhere you are

- **Phone companion** (in progress): chat, approvals, the Face View.
- **Chat from anywhere**: an encrypted relay so the phone reaches the PC away from home.
- **Phone as a microphone** when it's nearby.

### Phase 5: trust and polish for a public launch

- Privacy policy and in-app "what leaves this PC" page; opt-in, anonymous usage stats only.
- Accessibility pass (screen reader names, keyboard navigation, contrast) and more languages.
- Beta programme, a website, a demo video, and a name and trademark check for "Compii".

## Decisions only you can make

- **Signing**: an OV certificate (roughly a few hundred dollars a year) or Azure Artifact Signing if you're
  eligible. Without one, people see "Windows protected your PC" on install.
- **Business model**: free with your own keys (as now), or a paid tier where Compii provides the AI.
- **Name**: confirm "Compii" is free to use as a product name where you'll sell it.

## Sources

- Copilot: [Windows Experience blog](https://blogs.windows.com/windowsexperience/2025/10/16/making-every-windows-11-pc-an-ai-pc/), [Techzine](https://www.techzine.eu/news/applications/135508/windows-11-gets-major-copilot-update/), [WindowsForum](https://windowsforum.com/threads/windows-11-copilot-update-voice-vision-and-actions-arrive.385231/), [Copilot reviews](https://checkthat.ai/brands/microsoft-copilot/reviews), [outages](https://windowsforum.com/threads/june-2026-copilot-outages-why-ai-reliability-is-now-an-office-availability-issue.425467)
- ChatGPT: [TechCrunch](https://techcrunch.com/2026/07/24/openais-new-voice-mode-makes-it-to-the-chatgpt-desktop-app/), [OpenAI community](https://community.openai.com/t/chatgpt-voice-is-now-in-the-desktop-app/1388031)
- Claude: [Anthropic on X](https://x.com/claudeai/status/2039836891508261106), [Help center](https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork), [fast.io guide](https://fast.io/resources/claude-desktop-app-guide/)
- Gemini: [Android Headlines on Mariner](https://www.androidheadlines.com/2026/05/google-shuts-down-project-mariner-ai-agent.html), [Gemini Computer Use model](https://blog.google/innovation-and-ai/models-and-research/google-deepmind/gemini-computer-use-model/)
- Comet: [MacRumors](https://www.macrumors.com/2026/03/18/perplexity-comet-browser-iphone/), [Comet review](https://perplexityaimagazine.com/perplexity-hub/perplexity-comet-review-2026/)
- Screen assistants: [Cluely vs Highlight](https://www.usecarly.com/blog/cluely-vs-highlight-ai/), [screen-aware tools](https://www.getjarvis.eu/blog/best-ai-for-screen-aware-help-2026) (vendor blog), [Littlebird alternatives](https://filipkonecny.com/blog/littlebird-ai-alternatives/)
- Clicky on Windows: [The Rundown](https://www.therundown.ai/tools/clicky), [clicky-windows](https://github.com/Bitshank-2338/clicky-windows)
- Voice research: [Instruct-FD](https://arxiv.org/pdf/2607.20460), [backchannel control](https://arxiv.org/pdf/2609.29418), [PersonaPlex](https://www.getmaxim.ai/blog/personaplex-full-duplex-voice-without-the-fixed-persona/)
- Shipping: [Code signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options), [Azure Artifact Signing](https://azure.microsoft.com/en-us/products/artifact-signing), [SmartScreen guide](https://comcomponent.com/en/blog/2026/05/11/000-windows-smartscreen-code-signing-guide/), [velopack_flutter](https://pub.dev/packages/velopack_flutter/versions/0.3.1), [Nuitka vs PyInstaller](https://beatsyncpro.ai/blog/nuitka-vs-pyinstaller)
- Free AI limits: [Groq rate limits](https://console.groq.com/docs/rate-limits), [Groq Orpheus voices](https://console.groq.com/docs/text-to-speech/orpheus)

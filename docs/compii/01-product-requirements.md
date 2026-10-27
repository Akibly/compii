# Compii — Product Requirements

Version 1.0 · 15 October 2026 · Pre-build baseline

## Status and reading order

The user selected the name Compii, Flutter, multiple AI providers, Wisp as the character direction, and the six-document set below. The user explicitly chose large-eye Face View as the default phone presentation, with an optional full-body presentation. Other implementation and release choices are recommended engineering defaults, not claims of completed functionality. This packet authorizes no deployment or external communications. Application implementation has not started.

1. [Product Requirements](01-product-requirements.md)
2. [User Flows](02-user-flows.md)
3. [Technical Architecture](03-technical-architecture.md)
4. [Design & Personality](04-design-and-personality.md)
5. [AI & Data Contracts](05-ai-and-data-contracts.md)
6. [Implementation & Test Plan](06-implementation-and-test-plan.md)

## Pitch

Compii is a personal AI companion that helps you understand your work, learn new skills, and get things done. Its expressive Wisp character lives on your desktop or paired phone, sees the context you choose to share, and switches naturally between teaching you, working alongside you, and carrying out tasks for you. Built with Flutter and your choice of AI providers, Compii brings conversation, screen guidance, research, and useful memory into one approachable experience.

Tagline: **Learn it. Do it. Together.**

## Who it serves

Initial audience: adult learners, creators, students, and independent professionals using Windows. The initial product is not a child-directed service. Core needs: learn unfamiliar software without leaving it; delegate repetitive work; research a decision with evidence; resume a project without repeating context. A child-directed edition would need a separate product and data design.

## Product principles

- Demonstrate capability through verified outcomes rather than a claim of fictional Jarvis-level intelligence.
- Teach, collaborate, and execute are distinct modes sharing the same task context.
- Desktop works independently; a phone adds presence and voice input.
- Prefer direct integrations and semantic controls to fragile coordinate clicking.
- Store useful, inspectable memory, not indiscriminate background recordings.
- Clearly show listening, capture, execution, waiting, and failure states.
- Keep routine interaction concise; explanations expand when learning requires it.

## Requirements and release allocation

V1 = initial Windows + Android release. V1.1 = expansion after V1 gates. V2 = advanced capability, separately validated.

| ID | Requirement | Release / acceptance outcome |
|---|---|---|
| C01 | Desktop Wisp with bubbles, pointing and a task panel | V1: usable without a phone; overlay does not intercept unrelated clicks |
| C02 | Phone presentation selection | V1: `face` default; `full_body` alternative, floating or resting; setting survives restart |
| C03 | Voice and text conversation | V1: push-to-talk, text, captions, optional spoken replies and interruption |
| C04 | Multiple AI providers | V1: two independently working reasoning/vision adapters; capability-aware UI; speech selected separately |
| C05 | Screen understanding | V1: user-selected display/window capture, OCR and accessible controls; stale captures refreshed |
| C06 | Teach me | V1: goal, level check, grounded step, user attempt, verification, hint and recap |
| C07 | With me / For me | V1: mode switching, bounded plans, pause/resume/stop, action results and approval for consequential actions |
| C08 | Desktop actions | V1: supported click, text, shortcut, scroll, app/URL opening and scoped file operations; drag after spike passes |
| C09 | Research | V1: bounded multi-source research, citations, contradictions, dated findings, Markdown report export |
| C10 | Project history and memory | V1: saved sessions, explicitly saved preferences/decisions, source links, export and deletion |
| C11 | Phone pairing | V1: authenticated local connection; selected phone microphone; synchronized gaze/state; reconnect |
| C12 | Meetings | V1.1: explicitly started recordings, transcript, summary and proposed action items; speaker identity uncertainty visible |
| C13 | Learning library | V1.1: uploaded-material lessons, quizzes, flashcards, practice progress and revision sessions |
| C14 | Creation workflows | V1.1: document/spreadsheet/presentation generation through supported tools with artifact validation |
| C15 | Integrations and developer work | V1.1: scoped connectors and code workspace tools; credentials and account context explicit |
| C16 | Recurring routines | V2: user-approved schedules, budgets, deduplication, notifications and cancellation |
| C17 | Learn a routine by demonstration | V2: record an explicit demonstration, propose editable steps, dry-run, then save |
| C18 | Proactive suggestions | V2: opt-in per source; quiet/suggest/approved-routine levels; no implied always-on surveillance |
| C19 | Platform expansion | V1.1: macOS/iOS; V2: Linux following compositor-specific validation |
| C20 | Local AI and advanced providers | V1.1: supported local models and more adapters, with explicit capability gaps and hardware requirements |

V1 supported coverage for C06–C08 is exactly the application matrix and 30 task fixtures in the [V1 Supported-Task Benchmark](benchmark/v1-supported-tasks.md): Google Sheets in Chrome, a pinned local practice web app in Chrome, and Windows File Explorer. Other applications may be explored but are not advertised as verified coverage. Full-body phone movement is inside Compii; floating over unrelated mobile apps is not a V1 promise.

## Success metrics and learning pilot

Status: **proposed default, awaiting user confirmation.** These metrics test the core bet: Compii teaches people to do a task themselves, not merely to watch it done.

**Pilot design.** 12–20 adults who fail a short pretest on the benchmark tasks. Each participant learns two tasks of similar difficulty from the [benchmark](benchmark/v1-supported-tasks.md): one with Compii in Teach me, one with the baseline (the application's official help pages plus web search, no AI). Task-to-condition assignment and order are counterbalanced. Each learning session is capped at 15 minutes.

**Measurement.** Two unaided repeats of each learned task, on a variant fixture (different data, same skill), with no Compii and no help: immediately after the session, and 2–7 days later. The benchmark checker scores pass/fail. The delayed repeat is the primary measure.

| ID | Metric | Target |
|---|---|---|
| M01 | Delayed unaided completion, Compii condition (primary) | ≥ 70% and ≥ 15 points above baseline |
| M02 | Immediate unaided completion, Compii condition | Reported; must not be below baseline |
| M03 | Erroneous guidance: Compii instructions that were wrong, judged by checker evidence and transcript review | ≤ 5% of instructions; zero advances on unverified evidence |
| M04 | User takeover or abandonment of a Teach me session | ≤ 15% of sessions |
| M05 | Dependence: Teach me sessions where the user asked Compii to finish the task | Reported; above 30% triggers a teaching-design review |
| M06 | Benchmark execution success (For me / With me) | Gates in the benchmark file |

**Decision rule.**

- **Expand** (start broader V1 execution work and add applications): M01 met, and M03 and M04 within target.
- **Iterate** (fix teaching behavior, rerun with a new cohort): M01 gain between 0 and 15 points, or any counter-metric (M03–M05) out of bounds.
- **Rethink the teaching approach** before more build: Compii at or below baseline on M01 after two iterations.

With 12–20 participants the result is directional, not statistically conclusive. Report raw counts and per-task results, not only percentages. Participants are adults who give informed consent; recordings follow the data rules in [AI & Data Contracts](05-ai-and-data-contracts.md).

## Scope boundaries

No unrestricted autonomous sending, purchases, deletion, or account changes. No default always-on microphone, screen recording, or meeting recording. No claim of universal undo, universal app support, identical platform capabilities, or a fully local experience when cloud services are selected. A web client, smart-home control, autonomous financial activity, and a public plugin marketplace are outside V1. Provider charges remain the user's responsibility; show estimates as estimates.

## Recommended product defaults

Windows desktop first, Android companion in the same V1 milestone; all tested desktop features remain usable without pairing. Start in Teach me, push-to-talk, optional system speech where available, no scheduled jobs. Face View is the phone default. Personality: calm, curious, quietly witty. Local history can be disabled; durable personal memory requires explicit saving in V1.

## Evidence and references

- [HeyClicky](https://www.heyclicky.com/), [changelog](https://www.heyclicky.com/changelog), [trust](https://www.heyclicky.com/trust): screen guidance, agents and real reliability issues; vendor claims, not independent testing.
- [Clacky](https://raynanwuyep.com/clacky): routines and scoped file undo.
- [OpenClicky](https://github.com/prasanthsasikumar/openclicky), [ClickyX](https://github.com/unn-Known1/clickyX): provider and desktop ecosystem references.
- [Omi](https://www.omi.me/): memory and meeting workflows.
- [Khanmigo](https://khanmigo.ai/): guided learning.
- [Public discussion](https://www.reddit.com/r/macapps/comments/1srzk5a/has_anyone_tried_clicky/): anecdotal feedback, not a representative survey.
- User's reference screenshot: phone with large eyes and small desktop pointer. [Supplied Short](https://youtube.com/shorts/IEYzYopNGVQ): fetch was throttled; video contents were not verified.

The product must be differentiated through a tested learning-to-action transition and reliable outcomes, not merely through features competitors already describe. That transition is measured by M01–M05 and the benchmark gates above.

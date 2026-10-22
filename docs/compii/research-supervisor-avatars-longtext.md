# Compii v2 research: supervisor, faces, skills, long text

Date: 2026-10-21. This note records the research behind the v2 work and the
decisions taken from it. It is a working document, not marketing copy.

## 1. Compii as the supervisor

### The pattern

Two ways to run a team of agents:

- **Handoff-first**: the active agent passes the conversation to another agent,
  which then speaks to the user. Cheap, but every handoff loses context,
  the user ends up talking to a stranger, and nobody owns the result.
- **Agent-as-tools (chosen)**: Compii stays the one voice talking to the user.
  Specialists are tools Compii can consult, task, and review. Compii keeps the
  user's intent, decomposes it, assigns steps, checks the result, and only then
  answers. This is how Anthropic's multi-agent research system, OpenAI's
  orchestrator patterns, and every serious enterprise "agent supervisor" design
  work: the supervisor owns the transaction; workers own narrow lanes.

Handoffs still exist inside a team chat, but only as a way for two specialists
to pass a sub-problem. They never take over the user relationship.

### What the supervisor needs

1. **Roster with real state** — who exists, their job, workload, current task,
   success rate, last review.
2. **Assignment contract** — every delegation carries: objective, context,
   definition of done, budget (steps/time), and what must come back
   (artifact, answer, or failure). No "go do the thing".
3. **Review, not trust** — a specialist's result is a draft until the supervisor
   verifies it against the definition of done (files exist, page loads, test
   passes, mail is still a draft). Rejections carry a reason and go back once.
4. **Hiring** — when no existing specialist fits, Compii proposes a new one to
   the user with a name, one-line job, and why. The user chooses the name and
   confirms. New agents start on probation: shadow mode (does the work, sends
   nothing) until they have a track record.
5. **Trust ladder** — new agent: drafts only. Trusted: acts inside the usual
   folders/apps with a receipt. Never: money, sends, deletes, credentials.
   The user can move anyone down a rung at any time.
6. **Budgets and stop rules** — per-agent step/time/token budgets, hard stop,
   and an escalation inbox for anything the supervisor cannot resolve.
7. **Performance reviews** — after each completed job, a one-line outcome and a
   running success rate. Retire or retrain agents that keep failing.

### Product surface

- A **Team** view: cards with face, job, workload, state, trust rung, success
  rate; "Assign" and "Review" open a focused sheet.
- A **hiring card** when Compii proposes a teammate: face preview, suggested
  name (editable), job, first assignment, and "Hire" / "Not now".
- Talking directly to an agent stays available (Bot home), but the result is
  always visible to Compii, and Compii can be asked "how is the team doing?".
- Every delegation and review is a visible turn in the thread, not hidden
  orchestration.

## 2. Faces: Orbforms

Emoji were a placeholder and never matched Compii's indigo-and-gold character.
The replacement is a procedural identity system, not an asset pack:

- **Genome**: `o1.body.crown.eyes.sigil.aura.palette.seed`.
- 8 bodies (Mochi, Drop, Seed, Bloom, Cloud, Ring, Prism, Comet) × 12 crowns
  (Halo, Antenna, Twin, Crescent, Orbit, Fins, Dish, Flame, Bubbles,
  Headphones, Ribbon, Sprout) × 9 eye styles × 5 sigils × 8 auras × 12 palettes
  ≈ **414,720 distinct faces**, before seed-level variation.
- **Drawn, not shipped**: one `CustomPainter` in normalized 100×100 space, so a
  face is crisp from 18 px in a sidebar to 150 px on a bot home, in light and
  dark themes, and costs no downloads.
- **Deterministic**: the seed drives jitter, blink phase and palette, so a face
  never rearranges between frames or restarts.
- **Existing bots**: a bot without a genome gets a stable one derived from its
  id at draw time, so there is no migration and no emoji flash.
- **Picker**: preview, 24 quick picks, per-part rows (body, crown, eyes, aura,
  sigil), 12 colours, "Surprise me". Template chips show mini faces.
- **Compii itself** keeps the gold sprout crown; the sprout becomes the
  company mark rather than a generic smiley.

## 3. Importing skills and connectors

Formats worth supporting, in order of demand:

1. **Claude Agent Skills** — a folder with `SKILL.md` (YAML frontmatter: name,
   description, optional metadata) plus optional scripts and reference files.
   The description is the trigger; the body is instructions loaded on demand.
2. **OpenAI GPT Actions** — an OpenAPI 3 schema plus auth. Importing the schema
   yields tools; the GPT's instruction text maps to a skill recipe.
3. **MCP servers** — the 2026-07-28 stateless spec; connect a server, list its
   tools, and expose them to Compii with per-tool permission.
4. **Plain prompt packs** — a text recipe with placeholders; the existing
   recipe format already covers this.

### Safety pipeline (non-negotiable)

Import is untrusted code and untrusted instructions:

- Quarantine the folder; never execute on import.
- Scan scripts for shell/powershell/network patterns and flag secrets access.
- Dry-run: show every command and URL the skill would use, and which tools it
  asks for. The user approves capabilities, not just the name.
- Default to draft-only; a skill can never widen Compii's own safety rules.
- Revoke and delete in one place; audit every run.
- Display provenance (source, author, hash) on the skill card.

Supply-chain reality: public skill and MCP registries already contain malicious
packages (Snyk has documented live campaigns). Import by default must be
quarantine + explicit capability grant.

## 4. Long text: never silently cut

The complaint was real: captions were clamped to 3 lines, the buddy bubble to 6,
and the overlay to 2–6, with ellipsis and no way to read the rest.

Research (BBC/Netflix subtitle guidance, WCAG 2.2, Meet/Zoom/Teams transcripts,
ChatGPT/Claude/Gemini voice):

- Caption line length ~42 characters; 2 lines = 84. Reading speed 18–20 chars/s.
  Hold a cue at least 1.2 s and at most 7 s; never cut mid-word.
- Glance layer (caption/bubble) and reading layer (thread/reader) are different
  jobs. Keep the glance short, but make the full text one obvious action away.
- Any clamp must be paired with an explicit "Read all", never ellipsis alone.
- Long text gets 60–75 characters per line, 1.6 line height, and generous
  paragraph spacing. Code blocks get a label, wrap/scroll, and copy.
- Reader surfaces: desktop side sheet or dialog; Escape returns to the exact
  place; copy copies the full raw markdown, even when collapsed.

### Shipped

- A single **AnswerReader** dialog (up to 780×820, 660 px text column,
  16.5 px/1.62) rendering the same markdown as the thread, with word/character
  count, reading time, copy-all and Escape-to-close.
- Voice dock: a 3-line caption gets an inline **Read all** button; the last full
  answer is kept after speech fades and can be reopened from a persistent
  document button.
- Thread: replies over 900 characters get **Read in reader**; tool-step details
  show their full text on hover.
- Buddy overlay: answer bubble grows to 8 lines and, when still truncated, says
  plainly that the full answer is in Compii instead of pretending it ended.

### Next

- Sentence-level read-along (12% tint + left rule, no word karaoke).
- A transcript panel with search and "jump to live" for long voice sessions.
- Reader for tables/code with sticky headers and a wrap toggle.

## 5. Ranked plan

1. **Screen awareness v2** — the top user pain. One observe pipeline (UIA +
   local Windows OCR + optional vision), screen snapshot attached to normal
   chat when the request refers to the screen, pointing from real boxes, and an
   honest "what Compii sees" preview.
2. **Supervisor** — roster, assign/review tools, hiring card, trust ladder.
3. **Skills and connectors** — Claude/GPT/MCP import with quarantine.
4. **Long text** — shipped the core; transcript and read-along next.
5. **Faces** — shipped; add per-face naming and "favourite faces" later.
6. **Innovative extras** — proactive morning brief, "what changed since
   yesterday" screen memory, teach-by-demonstration with review, offline
   command palette actions, and a local-only usage/cost ledger.

## Sources

Long-text guidance:

- BBC Subtitle Guidelines — https://www.bbc.co.uk/accessibility/forproducts/guides/subtitles
- Netflix English Timed Text Style Guide — https://partnerhelp.netflixstudios.com/hc/en-us/articles/217350977-English-USA-Timed-Text-Style-Guide
- Netflix Timed Text General Requirements — https://partnerhelp.netflixstudios.com/hc/en-us/articles/215758617-Timed-Text-Style-Guide-General-Requirements
- WCAG 2.2 — https://www.w3.org/TR/WCAG22/
- Understanding WCAG 1.4.12 Text Spacing — https://www.w3.org/WAI/WCAG22/Understanding/text-spacing.html
- Google Meet caption history — https://9to5google.com/2025/02/18/google-meet-captions-history/
- Zoom captions and transcripts FAQ — https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0085668
- ChatGPT Voice — https://help.openai.com/en/articles/20001274-chatgpt-voice
- Claude voice mode — https://support.claude.com/en/articles/11101966-use-voice-mode
- Gemini Live captions — https://www.androidpolice.com/gemini-live-no-longer-makes-you-turn-up-your-volume/
- Material 3 snackbar guidance — https://m3.material.io/components/snackbar/guidelines

Supervisor, skills and supply chain: Anthropic multi-agent research system
write-up; Claude Agent Skills documentation (`SKILL.md`); OpenAI GPT Actions /
OpenAPI 3; Model Context Protocol 2026-07-28 specification; Snyk State of AI
security reports on malicious skills and MCP servers.

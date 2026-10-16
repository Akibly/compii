# Validation Report — Compii

- **PRD:** `D:/compii/docs/compii/01-product-requirements.md`
- **Rubric:** `D:/compii/.agents/skills/bmad-prd/assets/prd-validation-checklist.md`
- **Run at:** 2026-10-15T18:05:49.937Z
- **Grade:** Fair

## Overall verdict

Compii has a coherent learning-to-action proposition, unusually explicit autonomy boundaries, and a concrete user-approved character/presentation direction; the linked flows, contracts and test plan make this substantially more useful than a feature wish list. It is adequate to start bounded feasibility work, but not yet a release-ready implementation contract: learning outcomes, the supported-task benchmark, and several acceptance bounds remain undefined. Treat the six-document packet as a strong planning baseline with unresolved release gates, not proof that planning or implementation is complete.

## Dimension verdicts

- Decision-readiness — adequate
- Substance over theater — strong
- Strategic coherence — thin
- Done-ness clarity — thin
- Scope honesty — adequate
- Downstream usability — thin
- Shape fit — adequate

## Findings by severity

### Critical (0)

None.

### High (2)

**[Strategic coherence]** — No decision-grade learning outcome (§ Evidence and references, final paragraph; linked Implementation & Test Plan § Provisional performance and quality gates) — “differentiated through a tested learning-to-action transition” is the core bet, but “Teaching pilot includes an unaided repeat task” does not define the cohort, task difficulty, baseline, success threshold, evaluation window, or outcome that would justify expansion.

Fix: Define a bounded pilot with an unaided completion measure and baseline, plus a decision rule for iteration versus expansion; add counter-metrics for erroneous guidance, user takeover, and dependence on automated completion.

**[Done-ness clarity]** — Supported scope and release benchmark are not enumerated (§ Requirements and release allocation, C06–C08 and teaching-validation paragraph; linked Implementation & Test Plan § Provisional performance and quality gates) — “a browser-based spreadsheet, a browser workflow, and Windows file management” and “a published fixed set of 30 low-risk supported tasks” leave engineers free to choose incompatible applications, task boundaries, fixtures and interpretations of success.

Fix: Publish the first supported application/version matrix and task fixtures with initial state, allowed actions, evidence of success, failure conditions, repeat counts and scoring rules before implementing or claiming the corresponding teaching/execution coverage.

### Medium (5)

**[Decision-readiness]** — Decision status lacks an operational resolution record (§ Recommended product defaults; § Requirements and release allocation; linked Technical Architecture § Constraints and engineering gates) — “Windows desktop first, Android companion in the same V1 milestone” and the broad V1 allocation are proposed defaults, but there is no decision register identifying which open choices block which milestone, who resolves them, and what evidence settles them.

Fix: Add a short decision table with status, decision owner/role, required evidence, and latest stage for resolution; retain the distinction between user-confirmed and engineering-proposed choices.

**[Strategic coherence]** — V1 breadth is not prioritized within the release (§ Requirements and release allocation, C01–C11) — Research, memory, phone pairing, voice, two providers, teaching, and desktop execution all land in V1. The linked build sequence orders engineering work but does not identify what can be deferred if feasibility or effort exceeds expectations without losing the core product thesis.

Fix: Distinguish the minimum learning-to-action validation milestone from the public V1 bundle and explicitly rank the remaining capabilities and their deferral consequences.

**[Done-ness clarity]** — Bounded research and runtime budgets have no baseline values (§ Requirements and release allocation, C07 and C09; linked User Flows § F07 and F08) — “bounded plans,” “bounded multi-source research,” and “scope/time/cost choice” do not define shipped defaults, hard ceilings, accounting when provider prices are unknown, or when a partial result becomes acceptable.

Fix: Specify configurable defaults and hard-stop behavior for time, actions, source/page counts and estimated spend; include a no-known-price behavior and deterministic cutoff acceptance cases.

**[Scope honesty]** — Historical baseline can be mistaken for current implementation status (§ Status and reading order; linked Implementation & Test Plan § Ready-to-start checklist) — “Application implementation has not started” and “A running Flutter build ... do not yet exist” are no longer accurate as current-state statements after the character-preview slice. They also conflate a visual prototype with completion of native/AI capability gates if corrected too broadly.

Fix: Preserve the dated baseline and add a current evidence/status note distinguishing implemented/tested character UI from unimplemented AI, native overlays, secure pairing and hardware verification; link test/build evidence without marking full P0/P1 complete.

**[Downstream usability]** — Shared terms and atomic obligations need stable extraction anchors (§ Product principles; § Requirements and release allocation, C03, C07 and C08; linked AI & Data Contracts § Task and teaching state) — Human labels “Teach me / With me / For me,” prose “teach, collaborate, and execute,” and wire values `teach | collaborate | execute` are consistent in intent but not collected in a glossary. Broad rows bundle independently testable behaviors such as pause/resume/stop, approval and verification, making story coverage easy to overstate.

Fix: Add a compact glossary mapping display labels to domain values and introduce stable sub-requirement/acceptance identifiers for bundled obligations; map stories/tests to those without renumbering C01–C20.

### Low (0)

None.

## Mechanical notes

- C01–C20 and F01–F10 are contiguous; T01–T18 cover the initial-release requirements. Later-release features intentionally lack detailed acceptance scenarios and must not be treated as ready stories.
- No inline `[ASSUMPTION]` tags, assumptions index, or memlog/addendum exist. Proposed defaults are instead qualified in prose; a future extraction should preserve that status rather than treating absence of tags as user confirmation.
- The main PRD contains no standalone success-metric IDs or glossary. These are substantive traceability gaps described above, not formatting failures by themselves.
- Flows use a generic user rather than named protagonists; the initial adult Windows audience is stated in the PRD. Retain that context when extracting a journey into a separate story.
- “Scope boundaries” excludes unrestricted consequential actions rather than all consequential actions; linked contracts explicitly allow exact-action approval. Preserve that distinction in summaries.

## Reviewer files

- [Independent rubric review](review-rubric.md)

Validation only: source planning documents were not changed and no BMAD finalization or sprint-readiness gate is claimed.


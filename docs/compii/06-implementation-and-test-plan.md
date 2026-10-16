# Compii — Implementation & Test Plan

Version 1.0 · 15 October 2026 · No application implementation started

## Build sequence and exit gates

No delivery dates are promised before native-platform spikes. Requirements refer to [Product Requirements](01-product-requirements.md); flows refer to [User Flows](02-user-flows.md).

| Stage | Work | Exit evidence |
|---|---|---|
| P0 — feasibility | Inspect Windows toolchain; Flutter bootstrap in isolated subtree; transparent overlay, capture, input, audio, credential storage and secure Android pairing spikes | Each capability demonstrated on real target hardware; unsupported pieces recorded |
| P1 — identity and shell | Wisp vector rendering, expressions, quick panel/workspace, keyboard access, phone Face/Full-body selector | Consistent identity at small/large sizes; Face default and preference persistence verified |
| P2 — conversation | Two reasoning/vision adapters, text, transcription, optional speech, interruption, cost reporting | Equivalent supported scenarios pass with both providers; unsupported capability states clear |
| P3 — teaching | Scoped screen context, OCR/control targets, annotations, lesson state and practice | Benchmark fixtures and checkers built for A1–A3; Teach me gate met; learning pilot run and decision rule applied |
| P4 — execution | Native action tools, task coordinator, scope/approval, stop, verification, action journal | Fixed benchmark tasks pass; no duplicate external write on retry; all policy gates pass |
| P5 — research and memory | Search adapter, source records, report export, local history, saved memories | Citation checks, partial-report behavior and deletion/retrieval tests pass |
| P6 — V1 integration | Android pairing, voice ownership, synchronized state, presentation modes, installer and recovery | Desktop-only and paired workflows pass on real Windows/Android devices |
| P7 — V1.1 | macOS/iOS, meetings, learning library, creation/connectors, local model adapters | Separate platform and feature gates; advertise only verified coverage |
| P8 — V2 | Linux, routines, demonstration learning, opt-in proactivity | Environment-specific coverage, repeat-action dedupe and bounded execution tests |

## First vertical slice

Launch Windows app > add a provider > ask about a selected spreadsheet window > Wisp points to a cell > user performs one step > Compii verifies it > pair Android > default large-eye face mirrors state > change to Full-body View > restart phone and confirm preference persists. This validates the product's core interaction before broad automation work.

## Requirements-to-test mapping

| Test ID | Requirements | Scenario and pass condition |
|---|---|---|
| T01 | C01 | Overlay appears without stealing focus; unrelated clicks reach underlying app; hide/show works |
| T02 | C02 | Fresh phone install starts in Face View; full eyes remain readable at portrait/landscape sizes |
| T03 | C02 | Switch Face -> Full-body/Float -> Rest -> Face during a task; no conversation/audio reset; persistence after restart |
| T04 | C03 | Interrupt spoken response; audio stops; no obsolete queued action fires; text works without mic permission |
| T05 | C04 | Same supported task runs through both adapters; invalid key, rate limit, missing vision and offline states handled |
| T06 | C05 | Move/resize window, change DPI/display, scroll; stale target rejected and refreshed |
| T07 | C06 | Learner makes wrong click; tutor notices, offers a new hint and does not repeat identical failed instruction indefinitely |
| T08 | C07 | Switch execute -> teach and press Stop at each action boundary; no subsequent mutation starts |
| T09 | C08 | Consequential action without matching approval is blocked; changed recipient/text invalidates old approval |
| T10 | C08 | Lost acknowledgement produces uncertain result/reconciliation, not duplicate send or file operation |
| T11 | C09 | Report claims link to actual accessible sources; contradictions and inaccessible pages disclosed |
| T12 | C10 | Delete a memory/project and verify it disappears from database references, retrieval and export |
| T13 | C11 | Invalid/replayed pairing challenge cannot control desktop; revocation rejects old device |
| T14 | C11 | Phone disconnect/background pauses its mic; reconnect does not replay actions; one mic owner enforced |
| T15 | C01–C11 | No secrets/screenshots/audio in ordinary logs, crash payloads or exports |
| T16 | C06–C08 | Malicious instructions inside a document/page are treated as data and cannot expand authorized task scope |
| T17 | C01–C03 | Keyboard-only, screen reader, 200% text scale, contrast and reduced-motion checks pass |
| T18 | C09 | Budget/time cutoff produces labelled partial report; no silent cross-provider fallback |

## Verification approach

Unit tests: state transitions, policy classification, approval matching, coordinate transforms, retention and schemas. Contract tests: provider adapters, event versions, pairing identity and tool outputs. Integration tests: native permissions, overlays, actual action results, local storage and reconnect. End-to-end scenarios: initial supported applications and real devices. Do not use mocks as proof that native screen capture or control works.

Use sandbox test accounts/workspaces for external-write tests. Paid API smoke tests need configured test credentials and explicit spending bounds; never assume credentials exist. Avoid broad test suites that merely mirror implementation; focus on observable behavior and known failure modes.

## Provisional performance and quality gates

These are engineering targets, not measured claims or guarantees. Record hardware, network, provider, sample size and percentiles.

- Local input acknowledgement under 150 ms p95; UI remains responsive while providers are slow.
- First useful voice response target under 3 seconds p50 on the documented test setup; disclose actual p95 before release.
- Stop prevents the next queued mutation and acknowledges locally within 250 ms p95; in-flight external effects are reported honestly.
- Execution and teaching gates, repeat counts and scoring rules are defined in the [V1 Supported-Task Benchmark](benchmark/v1-supported-tasks.md): 30 fixed tasks, 10 trials each, at least 90% overall and 8/10 per task. No cherry-picked demos as the only evidence.
- All unauthorized/consequential-action negative tests pass. A safety-gate failure blocks release regardless of overall task success.
- No secrets in diagnostic fixtures; memory deletion and device revocation pass every run.
- Ten-minute idle and thirty-minute active phone tests record memory, CPU, thermal/battery behavior and rendering smoothness; optimize before expanding ambient animation.
- Teaching pilot follows the design, metrics M01–M05 and decision rule in [Product Requirements § Success metrics and learning pilot](01-product-requirements.md#success-metrics-and-learning-pilot). Run it at the end of P3, before P4 breadth work.

## Migration and packaging

Preserve original Swift repository files and Git history. Add Flutter source separately. Reimplement protocol with authentication and bounded messages; do not retain the old unauthenticated transport for compatibility. Migrate no user keys or notes automatically. Any future importer must preview source and destination and avoid data loss. Keep original license and font notices for reused content.

Desktop installers must include permission guidance, uninstallation behavior and clear version identity. Code signing and distribution accounts are deployment prerequisites, not reasons to block local prototyping. Apple builds/testing require suitable Apple hardware/tooling. Linux support is released per verified environment.

## Key risks and mitigations

| Risk | Mitigation |
|---|---|
| Vision clicks wrong control | Prefer semantics; refresh observations; verify effects; pause on ambiguity |
| User and agent fight for cursor | Serialized foreground execution and user-input takeover |
| Voice latency/provider variance | Separate adapters, immediate local status, measured budgets, text fallback |
| Phone heat/battery drain | Local animation, throttled updates, reduced motion, bounded sessions |
| Over-broad learning claims | Small tested workflows, explicit knowledge gaps, practice evaluation |
| Scope expands endlessly | Complete V1 gates before starting V1.1/V2; record additions by requirement ID |
| Cloud dependency surprises | Explicit provider/data path, spending caps, opt-in fallbacks, exportable data |

## Ready-to-start checklist

Planning baseline is captured in the six documents. Next implementation action is P0, not a full feature rewrite. Remaining technical choices (tested Flutter/package versions, exact provider models, voice engine and secure transport library) are resolved through spikes and recorded as decisions. A running Flutter build, live provider tests and native capability measurements do not yet exist. Wisp's selected visual direction and the two phone presentations are fixed product requirements; production rendering details remain iterative.

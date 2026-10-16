# Compii — BMAD adoption and delivery status

Updated: 2026-10-15. BMAD Method 6.12.4 installed locally with Core, BMM and 29 Codex skills. This record is not a completed sprint plan or a declaration that planning gates passed.

## Product baseline

Compii is a cross-platform companion for learning and doing: Teach me, With me, and For me. Flutter is the chosen client stack. Windows and Android are the initial implementation targets; other platforms require their own capability validation.

Preserve the approved organic lilac Wisp identity. Phone Face View (large eyes) is the default; Full-body View is optional, with floating or resting behavior. Persist the choice per device. In-app presentation does not imply permission to float above other mobile apps.

## Existing planning inputs

These documents remain the canonical product inputs; do not fork competing copies just to match a template.

| Input | BMAD use |
|---|---|
| [Product requirements](../../docs/compii/01-product-requirements.md) | PRD validation and update |
| [User flows](../../docs/compii/02-user-flows.md) | UX and story scenarios |
| [Technical architecture](../../docs/compii/03-technical-architecture.md) | Architecture decisions and feasibility gates |
| [Design and personality](../../docs/compii/04-design-and-personality.md) | UX constraints and approved character identity |
| [AI and data contracts](../../docs/compii/05-ai-and-data-contracts.md) | Provider, trust, data and tool boundaries |
| [Implementation and test plan](../../docs/compii/06-implementation-and-test-plan.md) | Epic decomposition and acceptance evidence |

## Evidence at adoption

- Original Bluey Swift code is retained as reference, not represented as cross-platform Flutter functionality.
- Flutter local visual prototype exists at `compii_flutter/apps/companion`.
- Implemented: Wisp rendering, expression preview, Face/Full-body choice, float/rest behavior, preference persistence, reduced-motion handling and adaptive layout.
- Behavioral tests and Flutter analysis passed. A Windows debug build succeeded. Test-generated desktop/phone image captures passed; these are not real-device screenshots.
- Native Windows runtime QA and Android device testing are still pending. Android SDK license acceptance is a user/environment prerequisite, not something silently accepted by the agent.
- AI conversations, live provider keys, voice, device pairing, teaching verification, online research and computer automation are not implemented in this Flutter prototype.
- Original planning prose predates the prototype; statements that no build exists are historical and need a status-only refresh after review.

## BMAD sequence

1. Validate existing PRD with `bmad-prd` (Validate intent). Save independent findings and consolidated reports; do not infer completion from document presence.
2. Resolve high-impact findings through PRD Update, retaining approved decisions and clearly recording assumptions.
3. Review architecture with `bmad-architecture`, including credential storage, native host boundaries and pairing feasibility. Do not promise identical operating-system capabilities.
4. Use `bmad-create-epics-and-stories` to turn requirements into bounded stories with observable acceptance criteria. Treat the visual prototype as existing work needing verification, not a completed product epic.
5. Run `bmad-sprint-planning` readiness assessment before issuing a sprint tracking file.
6. Implement individual stories through `bmad-build`; review and test each increment before advancing.

Fresh context is recommended for each major BMAD workflow. Carry these paths and the latest reports forward so context resets do not restart product discovery.

## Candidate next increment (not a sprint commitment)

PRD validation completed on 2026-10-15: **Fair**, with 0 critical, 2 high and 5 medium findings. See the [consolidated report](prd-validation/validation-report.md). The two high findings concern measurable learning outcomes and an executable supported-task benchmark. Validation is complete; PRD finalization, architecture review and sprint readiness are not. Source documents were deliberately unchanged during Validate intent.

PRD Update on 2026-10-15 addressed both high findings as **proposed defaults awaiting user confirmation**: a learning pilot with metrics M01–M05 and a decision rule (PRD § Success metrics and learning pilot), and the [V1 Supported-Task Benchmark](../../docs/compii/benchmark/v1-supported-tasks.md) with a 3-app matrix, 30 task fixtures and scoring rules. The 5 medium findings remain open. Re-validate after the user confirms.

Finish native validation of the current visual shell, then implement secure provider configuration and a text-only conversation slice. Add no paid calls until credentials and explicit spending bounds are supplied. Defer autonomous external actions until approval, cancellation and verification contracts have passed tests.

## Shareable pitch

Compii is your friendly companion for learning and getting things done. A gentle lilac Wisp can explain a task, guide you step by step, or carry out approved actions while keeping you in control. Built around Flutter and a choice of AI providers, Compii aims to bring teaching, research and practical assistance together across desktop and phone—with a big-eyed Face View or an optional full-body companion.

This describes the product vision. The current build is a local character and interface prototype.

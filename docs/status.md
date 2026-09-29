# KdlBeef status

Last reviewed: 2026-09-29.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 1/1 pass (smoke test only) |
| `beefbuild -test -config=TestRelease` (Release settings) | 1/1 pass |
| `tests/fetch-spec.sh` | kdl-spec at 89c1087, 338 test inputs |
| `bench/compare/run.sh` | Runs 12 implementations on 6 inputs; results in `bench/compare/results.md` |

The spec-suite, round-trip and leak scripts come with phases 1–2 (`docs/plan.md` §6); add them here as
they land. Any change to `.bf` files must keep these green in both Debug and Release.

## Feature status

| Area | State |
|------|-------|
| Project skeleton | Workspace, library, `KdlTester` stub, smoke test |
| Research | Spec reference (`docs/spec-reference.md`), implementation survey (`docs/implementation-survey.md`), benchmark of existing implementations (`bench/compare/results.md`) |
| Parsing, writing, everything else | Not started: see `docs/plan.md` |

## Open items

Sizes are rough: S ≈ hours, M ≈ a day or two, L ≈ multi-day.

| ID | Item | Size |
|----|------|------|
| P1 | Phase 1: tokenizer, event reader, canonical printing from events, suite runner (`docs/plan.md` §6) | L |
| P2 | Phase 2: document model, canonical writer, 243/243 + 95/95 on the suite | L |
| P3 | Phase 3: performance pass and KdlBeef rows in `bench/compare` | M |
| P4 | Phase 4: located errors with goldens, collect-errors mode, positions, limits, streams | M |
| P5 | Phase 5: PreserveStyle round trip and mutation API | L |
| P6 | Phase 6: `[KdlObject]` typed mapping | M |
| Q | Open questions for the author (`docs/plan.md` §9) | — |

## Suggested order

P1 → P2 → P3, then P4 and P5 in either order, then P6.

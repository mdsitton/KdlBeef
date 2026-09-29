# KdlBeef status

Last reviewed: 2026-09-29.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 11/11 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 11/11 pass |
| `./test-kdl-spec.sh` (Debug `KdlTester`; run `beefbuild` first) | 243/243 valid cases match `expected_kdl`, 95/95 `_fail` cases rejected |
| `BIN=./build/Release_Linux64/KdlTester/KdlTester ./test-kdl-spec.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `beefbuild-win -test`, `beefbuild-win -test -config=TestRelease` (`~/development/beef-proton`) | 11/11 pass |
| `tests/fetch-spec.sh` | kdl-spec at 89c1087, 338 test inputs |
| `bench/compare/run.sh` | Runs 12 implementations on 6 inputs; results in `bench/compare/results.md` (no KdlBeef row yet) |

Any change to `.bf` files must keep these green in both Debug and Release.

## Feature status

| Area | State |
|------|-------|
| Pull reader (`KdlReader`) | Done: full KDL 2.0.0 grammar, validation (UTF-8, banned code points), slashdash, all string and number forms, located errors. See `docs/architecture.md` |
| Canonical formatting (`KdlCanonical.Format`) | Done from events; byte-exact on the whole suite |
| `KdlTester` | Prints the canonical form of a file or stdin; exit 1 on invalid input |
| Document model, writers, positions, limits, streams, PreserveStyle, `[KdlObject]` | Not started: see `docs/plan.md` §6 |

Unmeasured indication (not the benchmark rule): the Release `KdlTester` formats the 21 MB HTML
standard, process start to exit, in 0.24 s (≈ 87 MB/s including writing 37 MB of output).

## Open items

Sizes are rough: S ≈ hours, M ≈ a day or two, L ≈ multi-day.

| ID | Item | Size |
|----|------|------|
| P2 | Phase 2: `KdlDocument` (store, nodes, `KdlEntryList`, values), built on `KdlReader`; canonical writer over the document reusing `KdlCanonical`'s formatting; suite run through the document | L |
| P3 | Phase 3: `KdlTester -bench`, KdlBeef rows in `bench/compare`, profiling (SWAR scans, number fast paths) | M |
| P4 | Phase 4: golden error messages per `_fail` case, collect-errors mode, positions, limits (depth, nodes, entries, string bytes), streams | M |
| P5 | Phase 5: PreserveStyle round trip and mutation API | L |
| P6 | Phase 6: `[KdlObject]` typed mapping | M |
| Q | Open questions for the author (`docs/plan.md` §9) | — |

## Suggested order

P2 → P3, then P4 and P5 in either order, then P6.

# KdlBeef status

Last reviewed: 2026-09-29.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 18/18 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 18/18 pass |
| `./test-kdl-spec.sh` (Debug `KdlTester`; run `beefbuild` first) | In both modes (document, events): 243/243 valid cases match `expected_kdl`, 95/95 `_fail` cases rejected |
| `BIN=./build/Release_Linux64/KdlTester/KdlTester ./test-kdl-spec.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `beefbuild-win -test`, `beefbuild-win -test -config=TestRelease` (`~/development/beef-proton`) | 18/18 pass |
| `tests/fetch-spec.sh` | kdl-spec at 89c1087, 338 test inputs |
| `bench/compare/run.sh` (KdlBeef columns: `beefbuild -config=Release` first; `ONLY="KdlBeef\|KdlBeef events"` for just those) | 14 implementations on 6 inputs; results in `bench/compare/results.md` |

## Performance baseline

`bench/compare/results.md` (MB/s; the benchmark rule of `run.sh`):

| | ui | config | strings | numbers | html-standard | html-standard-compact |
|---|---:|---:|---:|---:|---:|---:|
| Document read | 266 | 230 | 299 | 140 | 246 | 254 |
| Event pass (`KdlReader`) | 335 | 307 | 345 | 177 | 328 | 338 |
| Canonical write (MB/s of output) | 327 | 390 | 532 | 315 | 414 | 424 |

The fastest other implementation reads 33–49 MB/s (ckdl, events only) and writes up to 356 MB/s
(kdl-rs, strings). `numbers` is below the plan's 150 MB/s document target: after the number fast
paths it spends its time in the digit loops of hex/octal/binary and underscored tokens and in copying
float lexemes into the document (the canonical form needs them).

Any change to `.bf` files must keep these green in both Debug and Release.

## Feature status

| Area | State |
|------|-------|
| Pull reader (`KdlReader`) | Done: full KDL 2.0.0 grammar, validation (UTF-8, banned code points), slashdash, all string and number forms, located errors. See `docs/architecture.md` |
| Canonical formatting (`KdlCanonical.Format`) | Done from events; byte-exact on the whole suite |
| Document (`KdlDocument`, `KdlNode`, `KdlEntry`) | Read (text, bytes, file), navigation, argument and property lookups, canonical `Write`; byte-exact on the whole suite. No mutation beyond names and annotations yet (phase 5), no property hash index yet |
| `KdlTester` | Prints the canonical form of a file or stdin through a document, or with `-events` straight from the reader; exit 1 on invalid input |
| Positions, limits, streams, PreserveStyle, mutation, `[KdlObject]` | Not started: see `docs/plan.md` §6 |

## Open items

Sizes are rough: S ≈ hours, M ≈ a day or two, L ≈ multi-day.

| ID | Item | Size |
|----|------|------|
| P3 | Rest of phase 3: the property hash index for nodes with more than 8 properties (`plan.md` §4.3) — add a lookup benchmark first (TomlBeef's `lookup.sh`) and build it only if scans of 5–20 properties show up; `numbers` document read (140 MB/s) | S |
| P4 | Phase 4: golden error messages per `_fail` case, collect-errors mode, positions, limits (depth, nodes, entries, string bytes), streams | M |
| P5 | Phase 5: PreserveStyle round trip and mutation API | L |
| P6 | Phase 6: `[KdlObject]` typed mapping | M |
| Q | Open questions for the author (`docs/plan.md` §9) | — |

## Suggested order

P3, then P4 and P5 in either order, then P6.

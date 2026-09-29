# KdlBeef status

Last reviewed: 2026-09-29.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 33/33 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 33/33 pass |
| `./test-kdl-spec.sh` (Debug `KdlTester`; run `beefbuild` first) | In all three modes (document, events, stream with a 16-byte buffer): 243/243 valid cases match `expected_kdl`, 95/95 `_fail` cases rejected with the message in `tests/errors/<name>.err` (`UPDATE_GOLDEN=1` rewrites them; review the diff) |
| `BIN=./build/Release_Linux64/KdlTester/KdlTester ./test-kdl-spec.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `beefbuild-win -test`, `beefbuild-win -test -config=TestRelease` (`~/development/beef-proton`) | 33/33 pass |
| `tests/fetch-spec.sh` | kdl-spec at 89c1087, 338 test inputs |
| `bench/compare/run.sh` (KdlBeef columns: `beefbuild -config=Release` first; `ONLY="KdlBeef\|KdlBeef events"` for just those) | 14 implementations on 6 inputs; results in `bench/compare/results.md` |

## Performance baseline

`bench/compare/results.md` (MB/s; the benchmark rule of `run.sh`):

| | ui | config | strings | numbers | html-standard | html-standard-compact |
|---|---:|---:|---:|---:|---:|---:|
| Document read | 250 | 209 | 291 | 139 | 233 | 232 |
| Event pass (`KdlReader`) | 320 | 299 | 341 | 178 | 306 | 311 |
| Canonical write (MB/s of output) | 330 | 375 | 471 | 321 | 403 | 407 |

(From memory. The stream cursor cost the in-memory path about 5%: before it, the document read was
230–299 and the event pass 307–345.)

The fastest other implementation reads 33–49 MB/s (ckdl, events only) and writes up to 356 MB/s
(kdl-rs, strings). `numbers` is below the plan's 150 MB/s document target: after the number fast
paths it spends its time in the digit loops of hex/octal/binary and underscored tokens and in copying
float lexemes into the document (the canonical form needs them).

Any change to `.bf` files must keep these green in both Debug and Release.

## Feature status

| Area | State |
|------|-------|
| Pull reader (`KdlReader`) | Done: full KDL 2.0.0 grammar, validation (UTF-8, banned code points), slashdash, all string and number forms, located errors; in-memory text or a `Stream` through a buffer (`KdlReaderCore<TCursor>`). See `docs/architecture.md` §3 |
| Streams | `KdlReader.Reset(Stream)`, `KdlDocument.Read(Stream)`, `ReadFile` streaming with `StreamBufferBytes`; memory bounded by the buffer and the longest construct (`MaxTokenBytes`); same documents, errors and positions as in memory (the suite through a 16-byte buffer; tests with 1-byte reads, I/O failure, limits). End to end about 16% slower than in memory on the HTML standard |
| Canonical formatting (`KdlCanonical.Format`) | Done from events; byte-exact on the whole suite |
| Document (`KdlDocument`, `KdlNode`, `KdlEntry`) | Read (text, bytes, file), navigation, argument and property lookups, canonical `Write`; byte-exact on the whole suite. Mutation: add, insert, move, remove nodes; add, set, remove arguments and properties (see `architecture.md` §4). No property hash index yet |
| `KdlTester` | Prints the canonical form of a file or stdin through a document, with `-events` straight from the reader, with `-stream N` through a Stream and an N-byte buffer; exit 1 on invalid input; `-bench` for `bench/compare` |
| Read config, limits, positions | `KdlReadConfig`: source name, MaxDepth (256), MaxInputBytes, MaxNodes, MaxEntriesPerNode, MaxStringBytes (enforced by the reader, so for events too); `KdlMetadataMode.Positions` with `TryGetSourceRange` on nodes and entries |
| Error messages | Located, with the source name; worded for the likely cause (`r"…"` is KDL 1, `#` inside an identifier, a slashdash after a type annotation, …); golden files for all 95 `_fail` cases |
| Collect-errors, PreserveStyle, `[KdlObject]` | Not started: see `docs/plan.md` §6 and §9 |

## Open items

Sizes are rough: S ≈ hours, M ≈ a day or two, L ≈ multi-day.

| ID | Item | Size |
|----|------|------|
| P3 | Rest of phase 3: the property hash index for nodes with more than 8 properties (`plan.md` §4.3) — add a lookup benchmark first (TomlBeef's `lookup.sh`) and build it only if scans of 5–20 properties show up; `numbers` document read (140 MB/s) | S |
| P4 | Rest of phase 4: collect-errors mode, an opt-in `KdlReadConfig` flag (decided, `plan.md` §9) | M |
| P5 | Rest of phase 5: PreserveStyle at TomlBeef's level (decided, `plan.md` §9): comments, blank lines, number/string formats, indentation style, slashdashed content; preserving writer; mutation keeping neighboring formatting | L |
| P6 | Phase 6: `[KdlObject]` typed mapping | M |
| Q | Open questions for the author (`docs/plan.md` §9) | — |

## Suggested order

P3, then P4 and P5 in either order, then P6.

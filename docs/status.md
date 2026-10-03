# KdlBeef status

Last reviewed: 2026-10-03 (the move onto FormatCore). The deep review and reproduced issues are in
[review.md](review.md).

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 79/79 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 79/79 pass |
| `./test-kdl-spec.sh` (Debug `KdlTester`; run `beefbuild` first) | In all four modes (document, events, stream with a 16-byte buffer, collect-errors): 243/243 valid cases match `expected_kdl`, 95/95 `_fail` cases rejected with the message in `tests/errors/<name>.err` (`UPDATE_GOLDEN=1` rewrites them; review the diff) |
| `BIN=./build/Release_Linux64/KdlTester/KdlTester ./test-kdl-spec.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-roundtrip.sh` (and with the Release `BIN`) | PreserveStyle: 245/245 (valid suite inputs and the HTML-standard documents) written back byte for byte, from memory and through a 16-byte stream buffer |
| `bash ./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `bash ./test-codegen.sh` | 14/14 `[KdlObject]` build fixtures as expected (`tests/codegen`, with a second project depending on KdlBeef) |
| FormatCore's `bash tools/sync.sh <KdlBeef> --check` (run in a FormatCore checkout) | PASS (the vendored scripts, bench-kit and the AGENTS.md block match FormatCore's) |
| `bash ./win-test.sh` (Test and TestRelease under the Proton-hosted Beef) | 79/79 pass in both |
| `bash bench/instructions.sh` (Release `KdlTester -bench-loop`; FormatCore's bench-kit) | The table under Performance baseline |
| `tests/fetch-spec.sh` | kdl-spec at 89c1087, 338 test inputs |
| `bench/compare/run.sh` (KdlBeef columns: `beefbuild -config=Release` first; `ONLY="KdlBeef\|KdlBeef events"` for just those) | 16 implementations on 6 inputs (knus on KDL v1 translations in `inputs/v1/`); results in `bench/compare/results.md`; `bench/compare/plot.py` redraws the README charts (`docs/benchmark*.svg`) from it and `typed-results.md` |

## Performance baseline

User-space instructions per input byte (`bash bench/instructions.sh`, 2026-10-03, after the move onto
FormatCore; the first row of each pair is before it, at 84f2bc2):

| input | events | document | stream | stream4k | write |
|---|---:|---:|---:|---:|---:|
| ui (before) | 40.77 | 48.44 | 87.81 | 86.91 | 23.93 |
| ui | 39.59 | 45.62 | 57.53 | 57.69 | 23.93 |
| config (before) | 52.85 | 65.87 | 82.55 | 82.65 | 31.17 |
| config | 51.89 | 62.34 | 73.49 | 73.63 | 31.17 |
| strings (before) | 47.44 | 51.80 | 70.54 | 70.65 | 22.45 |
| strings | 46.83 | 50.42 | 68.11 | 68.14 | 22.45 |
| numbers (before) | 82.43 | 94.28 | 113.77 | 113.88 | 33.15 |
| numbers | 76.51 | 86.91 | 96.11 | 96.29 | 33.15 |
| html-standard (before) | 41.64 | 51.60 | 90.58 | 90.49 | 32.64 |
| html-standard | 41.52 | 49.66 | 84.12 | 84.19 | 32.64 |
| html-standard-compact (before) | 38.92 | 48.70 | 86.77 | 86.03 | 30.63 |
| html-standard-compact | 38.81 | 46.73 | 72.03 | 72.12 | 30.63 |

`KdlTester -bench` on `bench/compare/inputs` (MB/s, the benchmark rule of `run.sh`, 2026-09-30;
`results.md` has the earlier run beside the other implementations):

| | ui | config | strings | numbers | html-standard | html-standard-compact |
|---|---:|---:|---:|---:|---:|---:|
| Document read | 265 | 227 | 297 | 146 | 241 | 255 |
| Event pass (`KdlReader`) | 318 | 294 | 336 | 166 | 302 | 325 |
| Canonical write (MB/s of output) | 343 | 393 | 542 | 328 | 406 | 430 |

(From memory. The one-pass number fast path, `TryParsePlainNumber`, raised document reads 3–9%;
the event pass is within noise of before. Single runs vary by a few percent.)

Property lookups (`KdlTester -bench-lookup`): 28 ns per lookup that finds its key on a node of 4
properties, 43 at 8, 64 at 16, 97 at 32, 164 at 64 (a miss: 9 to 81 ns). A hash index would cost
about 15–20 ns per lookup plus memory per document, so it would only pay past about 30 properties;
it is not built (`plan.md` §4.3's condition is not met).

Typed (`KdlTester -bench typed bench/compare/inputs/ui.kdl 5`: the 5 MB UI markup into the
`[KdlObject]` types of `KdlTester/src/TypedUi.bf`, 63,681 widgets through polymorphic
`[KdlChildren]`, checked by a checksum before and after a write and re-read): read (parse + bind)
30 ms, 159 MB/s (39 ms with positions for located errors, `KdlSerializer.Read`); bind alone from a
parsed document 10.6 ms, 453 MB/s; write (a new document from the objects, then its text) 23 ms.
`bench/compare/typed.sh` compares (`typed-results.md`): kdl-rs serde reads in 1476 ms, gokdl2 364,
KdlSharp 324; writes take 125, 153 and 196 ms. None of them keeps an ordered mix of child kinds or
the `(px)` annotations without help.

The fastest other implementation reads 33–49 MB/s (ckdl, events only) and writes up to 356 MB/s
(kdl-rs, strings). `numbers` (146 MB/s) stays a little below the plan's 150 MB/s document target: its
time is in the exact float division of Clinger's fast path, the digit loops of hex/octal/binary and
underscored tokens, copying float lexemes (the canonical form needs them) and writing 72-byte entry
records. A packed 48-byte record was tried and measured slower (numbers 129 MB/s): rebuilding the
value on every read costs more than the memory it saves.

Any change to `.bf` files must keep these green in both Debug and Release.

## Feature status

| Area | State |
|------|-------|
| Pull reader (`KdlReader`) | Done: full KDL 2.0.0 grammar, validation (UTF-8, banned code points), slashdash, all string and number forms, located errors; in-memory text or a `Stream` through a buffer (`KdlReaderCore<TCursor>`). See `docs/architecture.md` §3 |
| Streams | `KdlReader.Reset(Stream)`, `KdlDocument.Read(Stream)`, `ReadFile` streaming with `StreamBufferBytes`; memory bounded by the buffer and the longest construct (`MaxTokenBytes`, a hard limit whatever the buffer size; whitespace between constructs is not held); same documents, errors and positions as in memory (the suite through a 16-byte buffer; tests with 1-byte reads, I/O failure, limits). End to end about 16% slower than in memory on the HTML standard |
| Canonical formatting (`KdlCanonical.Format`) | Done from events; byte-exact on the whole suite |
| Document (`KdlDocument`, `KdlNode`, `KdlEntry`) | Read (text, bytes, file), navigation, argument and property lookups (typed getters with fallbacks, chainable `Find`, `Children.Named`, `Descendants`), canonical `Write`; byte-exact on the whole suite. Mutation: add, insert, move, remove nodes; add, set, remove arguments and properties (see `architecture.md` §4). No property hash index yet |
| `KdlTester` | Prints the canonical form of a file or stdin through a document, with `-events` straight from the reader, with `-stream N` through a Stream and an N-byte buffer; exit 1 on invalid input; `-bench` for `bench/compare` |
| Read config, limits, positions | `KdlReadConfig`: source name, MaxDepth (256), MaxInputBytes, MaxNodes, MaxEntriesPerNode, MaxStringBytes (enforced by the reader, so for events too; MaxStringBytes while a string is decoded, MaxInputBytes by `ReadFile` from the file's size before reading); `KdlMetadataMode.Positions` with `TryGetSourceRange` on nodes and entries |
| Error messages | Located, with the source name; worded for the likely cause (`r"…"` is KDL 1, `#` inside an identifier, a slashdash after a type annotation, …); golden files for all 95 `_fail` cases |
| Collect-errors | `KdlReadConfig.CollectErrors` (opt-in) and `MaxErrors`: the reader reports every error and skips each broken node; `KdlDocument` keeps what it read and lists `Errors`. Suite-checked and fuzzed (no crash or hang) |
| PreserveStyle | `KdlMetadataMode.PreserveStyle`: unchanged documents write back byte for byte (round-trip script, fuzzed); edits regenerate only what changed (values keep radix and quoting; new nodes follow the document's indentation); `WriteCanonical` for the canonical form. See `architecture.md` §4 |
| `[KdlObject]` | Compile-time typed mapping with KDL roles (properties, arguments, child values, child objects, repeated children, polymorphic `[KdlChildren]`, Lists and Dictionaries nested to any depth, with String, integer or enum keys), kebab-case naming, enums, converters seeing annotations, aliases, required fields, allocators, in-place updates of PreserveStyle documents, whole documents through `KdlDocument.Root` and `KdlSerializer`. See `architecture.md` §6 |

## Open items

Sizes are rough: S ≈ hours, M ≈ a day or two, L ≈ multi-day.

| ID | Item | Size |
|----|------|------|
| R | [Review](review.md) follow-ups: R1-R9 and F1-F5 are fixed, each with a regression test (see the review's resolutions). Left: the review's optional API additions (entry annotation setters, strict typed binding, unsigned getters, editable slashdashed content) | M |
| P5 | PreserveStyle refinements, if wanted: underscore grouping and digit counts of changed numbers (TomlBeef's `TomlIntegerFormat`), re-indenting a node's subtree when it moves to another depth, a style API to set formats in code | S |
| F | FormatCore follow-ups: the entry ranges and per-entry side tables onto FormatCore's `RangeTable`/`SideTable` (needs the node record's inline entry-range fields as an `ItemRange`); the generator's planning onto FormatCore's `Planner<TFormat>` (today only its driver, registry and helpers are used); `bench/compare/run.sh` onto the vendored `merge.sh`/`measure.sh` (vendored, not yet called) | M |
| Q | Open questions for the author (`docs/plan.md` §9) | — |

## Suggested order

The review's findings (R1-R9, and the follow-up's F1-F5) are fixed with regression tests in
`tests/KdlReviewTests.bf`, and the measured quadratic paths are linear. Optional API additions, planned refinements (P5)
and more lookup API can follow as the UI framework needs them. Phase 7's KQL, JSON-in-KDL, v1 input
and streaming writer remain dropped (`plan.md` §6).

# KdlBeef status

Last reviewed: 2026-09-29.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 49/49 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 49/49 pass |
| `./test-kdl-spec.sh` (Debug `KdlTester`; run `beefbuild` first) | In all four modes (document, events, stream with a 16-byte buffer, collect-errors): 243/243 valid cases match `expected_kdl`, 95/95 `_fail` cases rejected with the message in `tests/errors/<name>.err` (`UPDATE_GOLDEN=1` rewrites them; review the diff) |
| `BIN=./build/Release_Linux64/KdlTester/KdlTester ./test-kdl-spec.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-roundtrip.sh` (and with the Release `BIN`) | PreserveStyle: 245/245 (valid suite inputs and the HTML-standard documents) written back byte for byte, from memory and through a 16-byte stream buffer |
| `./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `beefbuild-win -test`, `beefbuild-win -test -config=TestRelease` (`~/development/beef-proton`) | 49/49 pass |
| `tests/fetch-spec.sh` | kdl-spec at 89c1087, 338 test inputs |
| `bench/compare/run.sh` (KdlBeef columns: `beefbuild -config=Release` first; `ONLY="KdlBeef\|KdlBeef events"` for just those) | 14 implementations on 6 inputs; results in `bench/compare/results.md`; `bench/compare/plot.py` redraws the README charts (`docs/benchmark*.svg`) from it and `typed-results.md` |

## Performance baseline

`bench/compare/results.md` (MB/s; the benchmark rule of `run.sh`):

| | ui | config | strings | numbers | html-standard | html-standard-compact |
|---|---:|---:|---:|---:|---:|---:|
| Document read | 250 | 209 | 291 | 139 | 233 | 232 |
| Event pass (`KdlReader`) | 320 | 299 | 341 | 178 | 306 | 311 |
| Canonical write (MB/s of output) | 330 | 375 | 471 | 321 | 403 | 407 |

(From memory. The stream cursor cost the in-memory path about 5%: before it, the document read was
230–299 and the event pass 307–345.)

Typed (`KdlTester -bench typed bench/compare/inputs/ui.kdl 5`: the 5 MB UI markup into the
`[KdlObject]` types of `KdlTester/src/TypedUi.bf`, 63,681 widgets through polymorphic
`[KdlChildren]`, checked by a checksum before and after a write and re-read): read (parse + bind)
30 ms, 159 MB/s (39 ms with positions for located errors, `KdlSerializer.Read`); bind alone from a
parsed document 10.6 ms, 453 MB/s; write (a new document from the objects, then its text) 23 ms.
`bench/compare/typed.sh` compares (`typed-results.md`): kdl-rs serde reads in 1476 ms, gokdl2 364,
KdlSharp 324; writes take 125, 153 and 196 ms. None of them keeps an ordered mix of child kinds or
the `(px)` annotations without help.

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
| Collect-errors | `KdlReadConfig.CollectErrors` (opt-in) and `MaxErrors`: the reader reports every error and skips each broken node; `KdlDocument` keeps what it read and lists `Errors`. Suite-checked and fuzzed (no crash or hang) |
| PreserveStyle | `KdlMetadataMode.PreserveStyle`: unchanged documents write back byte for byte (round-trip script, fuzzed); edits regenerate only what changed (values keep radix and quoting; new nodes follow the document's indentation); `WriteCanonical` for the canonical form. See `architecture.md` §4 |
| `[KdlObject]` | Compile-time typed mapping with KDL roles (properties, arguments, child values, child objects, repeated children, polymorphic `[KdlChildren]`), kebab-case naming, enums, converters seeing annotations, aliases, required fields, allocators, in-place updates of PreserveStyle documents, whole documents through `KdlDocument.Root` and `KdlSerializer`. See `architecture.md` §6 |

## Open items

Sizes are rough: S ≈ hours, M ≈ a day or two, L ≈ multi-day.

| ID | Item | Size |
|----|------|------|
| P3 | Rest of phase 3: the property hash index for nodes with more than 8 properties (`plan.md` §4.3) — add a lookup benchmark first (TomlBeef's `lookup.sh`) and build it only if scans of 5–20 properties show up; `numbers` document read (140 MB/s) | S |
| P5 | PreserveStyle refinements, if wanted: underscore grouping and digit counts of changed numbers (TomlBeef's `TomlIntegerFormat`), re-indenting a node's subtree when it moves to another depth, a style API to set formats in code | S |
| P6 | `[KdlObject]` limits: `List<List<T>>` and dictionaries are not supported | S |
| Q | Open questions for the author (`docs/plan.md` §9) | — |

## Suggested order

Everything in the plan's must-have scope is done. What is left is refinement (P3, P5, P6 rows) and
phase 7 extras (`plan.md` §6: streaming `KdlWriter`, KQL, KDL v1 input, JSON-in-KDL), to pick up
when the UI framework needs them.

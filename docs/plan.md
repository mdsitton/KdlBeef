# KdlBeef: implementation plan and handoff

KdlBeef is a KDL 2.0 parser and writer for the Beef programming language, written for a UI framework
that uses KDL as its markup (an XML/YAML alternative). It is the sibling of TomlBeef
(`~/development/TomlBeef`), a TOML 1.1 library by the same author that is fast, fully spec
compliant and format preserving; KdlBeef reuses its design, its tooling and, where it fits, its code.

This document is the handoff for the session that starts the implementation. It records what exists,
what was learned, the design to build and the phases to build it in. Read with it:

- `docs/spec-reference.md` — the KDL 2.0.0 rules and every edge case worth a test, with line
  references into the spec.
- `docs/implementation-survey.md` — how ten existing implementations work, what to copy and what
  to avoid.
- `bench/compare/results.md` — the benchmark of those implementations (how to rerun: below).
- `AGENTS.md` — Beef conventions and gotchas (carried over from TomlBeef), verification rules.
- TomlBeef's `docs/architecture.md` — the design most of this plan adapts.

## 1. State of the repository (2026-09-29)

| Path | What it is |
|---|---|
| `BeefSpace.toml`, `BeefProj.toml` | Workspace with the `KdlBeef` library (`src/KdlBeef/`) and the `KdlTester` CLI; `TestRelease` and Windows (LLVM toolset) configs as in TomlBeef |
| `src/KdlBeef/KdlVersion.bf` | Placeholder public type (`KdlVersion { V1, V2 }`) |
| `src/KdlBeef/tests/KdlSmokeTests.bf` | One smoke test so `beefbuild -test` runs |
| `KdlTester/src/Program.bf` | Stub; becomes the spec-suite and benchmark CLI (phase 1) |
| `tests/fetch-spec.sh` | Fetches kdl-org/kdl at a pinned commit into `tests/kdl-spec/` (git-ignored; CC BY-SA 4.0, so not vendored): the spec, 338 test cases, and the HTML-standard benchmark documents |
| `bench/compare/` | The comparison benchmark: `fetch.sh` (11 pinned clones + Zig 0.16), `build.sh`, `gen-inputs.py`, `run.sh`, and a harness per language (`c/`, `cpp/`, `rust/`, `go/`, `java/`, `js/`, `cs/`, `python/`, `zig/`) |
| `docs/` | This plan, the spec reference, the implementation survey, `status.md` |

`beefbuild` and `beefbuild -test` pass (1/1). Nothing parses KDL yet.

**Update (phase 1 done, 2026-09-29):** `KdlReader`, `KdlValue`, `KdlChar`, `KdlParseError` and
`KdlCanonical` exist; the suite passes in full through the reader (243/243 byte-exact, 95/95
rejected), which is more than phase 1 asked for. What was built and why is in `architecture.md`, the
current baseline in `status.md`. Two plan points were settled on the way: validation (UTF-8 and banned
code points) is one up-front pass rather than folded into the tokenizer (§4.2; revisit in phase 3),
and the reader works on a contiguous buffer with plain offsets (streams, phase 4, will need either a
generic cursor as in TomlBeef or copying event payloads when refilling). The canonical writer also
needs big integers converted to decimal (`hex_int` expects `0xABCDEF0123456789abcdef` →
`207698809136909011942886895`); `KdlCanonical.AppendIntegerLexeme` does it.

## 2. What the benchmark says

Every KDL v2 implementation whose language has a toolchain here was built from a pinned clone and
timed on six inputs: two real documents from the KDL repository (the HTML standard as KDL, 21 MB, and
its compact form, 16 MB — deep markup trees, the closest thing to a UI framework's documents) and four
generated ones (`ui`: a UI markup tree with properties, type annotations, comments and slashdash;
`config`; `strings`; `numbers`). Every harness also reports the node count, which must match the
reference or the cell is FAIL. The rule is TomlBeef's: 1 s warm-up, samples until 60% are within ±10%
of the median, median of 3 processes, DNF past 60 s. Full tables: `bench/compare/results.md`.

What stands out (parse throughput, MB/s of input):

- **The field is slow.** The fastest, ckdl (C, a pull/event parser that builds no document), reads
  33–49 MB/s; its C++ document API (kdlpp) 23–34. kdly (Go, lossless syntax tree) 20–48, kdl4j 17–34,
  KdlSharp 13–30, @bgotink/kdl 12–18, kdljs 5–13, ckdl's Python binding 15–25. The official Rust
  implementation, kdl-rs, manages **2–3 MB/s** (winnow combinators and an owned String per trivia
  fragment); kdl-py 0.4–0.6 (DNF on the full HTML standard).
- Writing a parsed document back is faster everywhere: KdlSharp 93–232 MB/s, kdl-rs 80–356,
  kdlpp 66–102, @bgotink/kdl 72–311.
- **Two implementations fail on valid input.** gokdl2 rejects four of the five inputs at positions
  deep in the files (tokens corrupted across its 64 KB refill buffer) and trips on backticks (its
  non-standard expression strings are always on); zig-kdl miscounts nodes under slashdashed
  containers (no depth tracking) and rejects the HTML standard, at 1–4 MB/s.
- For comparison, TomlBeef parses TOML at 80–700 MB/s (3 GB/s on comment-only input) with a document,
  full validation and located errors. KDL's grammar is no harder than TOML's. **A KdlBeef that reuses
  TomlBeef's techniques should be several times faster than every existing KDL implementation**;
  targets are in phase 3.

## 3. Feature set

From the spec and the survey, with the UI framework in mind. "Must" is the phase 1–5 scope.

| Feature | Priority | Notes |
|---|---|---|
| Full KDL 2.0.0 parsing, every rule in `spec-reference.md` | Must | Byte-exact canonical output on all 243 valid suite cases; all 95 `_fail` cases rejected |
| Document model with an ordered entry list per node | Must | Arguments and properties interleaved, duplicates kept, lookups last-wins (§4.3) |
| Canonical writer (the suite's format) | Must | Also the default writer |
| Pull/event reader (`KdlReader`) under the document builder | Must | Zero-allocation fast path for large markup; the document is built on it |
| Located errors (line, column, offset, length, source name) | Must | TomlBeef's `TomlParseError` model |
| Positions sidecar (where every node/entry came from) | Must | For UI diagnostics ("button at main.kdl:12:5") |
| Resource limits (depth, nodes, entries, string and token bytes, input size) | Must | Untrusted markup |
| Streams (read from a `Stream` with bounded memory) | Must | TomlBeef's buffered stream cursor |
| Format preservation (comments, whitespace, literal spellings) with byte-exact round-trip | Must | Editors and tools that rewrite markup |
| Mutation API (set/add/remove/rename entries, nodes, children) | Must | |
| Typed values with type annotations (`(px)12`, `(u8)255`) and typed accessors | Must | UI units live in annotations |
| Compile-time typed mapping (`[KdlObject]`) | Should | TomlBeef's `[TomlObject]` generator, adapted to KDL's roles (§4.10) |
| Multi-error reporting with recovery | Should | Hot reload: show every error at once (kdl-rs, @bgotink/kdl) |
| Streaming writer (`KdlWriter` emitter) | Should | Generate large markup without a document |
| KQL queries | Later | Spec unreleased; @bgotink/kdl and KdlSharp are the references |
| KDL v1 input (explicit, converted to v2) | Later | Only if needed; @bgotink/kdl's transform is the model; never a silent fallback |
| JSON-in-KDL / XML-in-KDL microsyntaxes, schema | Later | Optional layers |

## 4. Design

### 4.1 Layers

```
bytes ─► UTF-8 validation ─► cursor (contiguous or buffered stream)
      ─► tokenizer (every token, trivia included, first-byte dispatch)
      ─► KdlReader: pull events (node start/end, argument, property, children begin/end)
             ├─► document builder ─► KdlDocument (+ optional Positions / PreserveStyle sidecar)
             └─► user code that wants no document (fast scanning of large markup)
KdlDocument ─► canonical writer | preserving writer
KdlWriter (streaming emitter) ─► text, without a document
```

This is ckdl's layering (tokenizer → state machine → events → document) with TomlBeef's cursor
underneath. The event reader keeps the core allocation-free (event payloads are views into the input
or a scratch buffer, valid until the next event) and gives the UI framework a cheap way to skim a
document.

### 4.2 Cursor, UTF-8 and scanning (port from TomlBeef)

- `TomlCursor.bf` (`ITomlCursor`, `TomlByteCursor`): contiguous input, columns computed on demand
  from a line-start offset, 8-byte SWAR `ScanTextRun` for string and comment bodies. Port as
  `KdlCursor.bf`; KDL needs more newline kinds (CRLF, CR, LF, NEL, VT, FF, LS, PS) and a different
  stop-byte set, and multi-byte newlines (NEL, LS, PS) mean the SWAR stop mask must include their
  lead bytes (0xC2, 0xE2) and check the full sequence on a stop.
- `TomlBufferedStreamCursor.bf`: fixed buffer, nested marks, spill for long tokens, retained-bytes
  limit. Port as-is apart from names; its bounded growth is exactly what ckdl lacks.
- `TomlChar.bf`: whole-buffer `IsValidUtf8` fast pass with `LocateUtf8Error` for the precise error.
  KDL additionally forbids code points (U+0000–0008, U+000E–001F, U+007F, surrogates, bidi controls,
  U+FEFF except first): fold those checks into the tokenizer's slow path, not a second pass.
- Tokenizer dispatch: a 256-entry first-byte class table (@bgotink/kdl), `switch` in Beef, no maps.

### 4.3 Document model

- `KdlDocument` owns everything through a store (TomlBeef's `TomlDocumentStore.bf`: a
  `BumpAllocator` whose pools are recycled across reads). Strings are arena bytes viewed as
  `StringView` (TomlBeef's `NewKey`), not `String` objects with destructors.
- **Nodes are IDs, not objects** (decided 2026-09-29, after Sizzle's `EntityGraph`,
  `~/development/PortalEmulator/Sizzle/src/Entities/EntityGraph.bf`). Each node is a `KdlNodeId`
  (`uint32` index, 0 invalid) into the document's node table, which holds parallel arrays: name,
  annotation, entry range, and the hierarchy as parent / first child / last child / next sibling /
  previous sibling (20 bytes of links per node; no per-node children `List`). Building a node is a
  few array writes (the reader's frame stack knows the parent and previous sibling); moving or
  inserting is an O(1) relink; a stale ID is detectable, where a stale pointer would crash.
  - The public face is `KdlNode`, a 16-byte handle struct (document + ID) whose **properties** read
    and write through to the document (`node.Name`, `node.Parent`, `node.Children`,
    `node.TryGetProperty(…)`, `node.Name = "x"`), so user code reads like a pointer-based tree.
    Not Sizzle's packed graph-ID-plus-static-registry lookup: a library should not need a
    process-wide document table.
  - Unlike `EntityGraph`: **no stored depth** (it makes every reparent walk the subtree; compute it
    by walking up), and **no slot reuse** before `Clear()` (Sizzle's `AllocateSlot` reuses the first
    free slot, so an old ID can silently alias a new entity; add a generation to the ID if reuse is
    ever needed).
  - Child by index is O(i) through the sibling links (iteration, the common case, is not); keep a
    child count per node.
  - IDs are per document and per parse: hot-reload matching across parses uses the markup's own
    identity (an `id=` property or a node path), as Sizzle separates `PersistentId` from `EntityID`.
  - The metadata sidecars (Positions, PreserveStyle, §4.7) are keyed by the same ID.
- Entries: one document-wide array; each node holds a start and count. The reader produces them in
  document order, so a parse fills it contiguously. Adding an entry to an earlier node moves that
  node's range to the end (leaving a hole reclaimed on `Clear`/rebuild); settle the details in
  phase 2.
- `KdlEntry` (struct): optional key (a property) or none (an argument), optional type annotation,
  value. Arguments keep their order; properties keep source order and duplicates; property lookup
  returns the last. Canonical writing dedupes (last wins) and sorts.
- **Property index:** a node with more than 8 properties gets a hash index built lazily (over its
  entry range), as TomlBeef's `TomlEntryMap.bf` (ordered slots, linear scan up to 8, open-addressing index with a
  power-of-two mask and stored hashes past that). No existing implementation indexes; UI nodes carry
  5–20 attributes and are queried constantly. Children-by-name lookup: iterate, with an optional
  per-node name index later if profiles ask for it.
- `KdlValue` (tagged union, like `TomlValue`): String (arena view), Integer (`int64`), Float
  (`double`), Bool, Null, and **Number lexeme** for integers outside int64 and decimals outside double
  (`0xABCDEF0123456789abcdef`, `1.23E+1000`) — keep the lexeme, as ckdl does, never a decimal type
  (KdlSharp clamps) or doubles only (@bgotink/kdl and kdljs lose integers). `#inf`, `#-inf`, `#nan`
  are Float. Typed accessors: `TryGetInt64`, `TryGetDouble`, `TryGetString`, `TryGetBool`, with
  `TryGetAnnotation`; the UI framework maps `(px)`, `(%)`, `(em)` itself.

### 4.4 Numbers and strings

- Integers: TomlBeef's `TryParsePlainInteger` fast path (`TomlParser.Values.bf:525`), then the full
  path with KDL's underscore, sign and prefix rules; overflow keeps the lexeme.
- Floats: TomlBeef's `TryParsePlainFloat` (`TomlParser.Values.bf:555`, Clinger's exact fast path,
  bit-identical to `Double.Parse`) then `Double.Parse`; out-of-range exponents keep the lexeme. The
  canonical writer keeps the written mantissa and prints `E` with an explicit sign
  (`spec-reference.md` §12).
- Strings: identifiers, quoted (escapes, `\u{}` limits, whitespace escapes), raw (`#"…"#`, the
  first-closing-quote cut rule), multi-line (`"""`) with the dedent algorithm **in the spec's order**
  (whitespace escapes, then split, prefix, strip, join with LF, then other escapes; §9). Unescape in
  one pass into a scratch buffer, copy once into the store. The "looks like a number" rule for bare
  identifiers is an error, not a string (§7).

### 4.5 Errors

`KdlParseError { Kind, Message, Line, Column, Offset, Length, Source }` as TomlBeef's
`TomlError.bf` (per-thread message buffer, no cleanup, `ToString` as `source:line:column: message`),
line and column computed on demand. Messages name what was expected ("Expected whitespace before an
argument", "A `(type)` annotation cannot annotate a property key"), with hints where they help (kdly,
gokdl2). A **collect-errors** read mode (phase 4) recovers at the next value or node terminator and
reports every error, for hot reload; the default stops at the first. Golden error tests: expected
message and position per `_fail` case (kdl4j keeps 83 such snapshots).

### 4.6 Writers

- Canonical: exactly the suite's format (`spec-reference.md` §12): numbers in decimal, strings bare
  or quoted. Used by the suite, `KdlCanonical` and anyone who asks for it.
- Preserving: re-emits kept trivia and literal text (§4.7); regenerates only what changed.
- **"As written" is TomlBeef's PreserveStyle model, not a writer flag** (author's preference,
  2026-09-29: hex, octal and binary carry meaning — colors, masks, byte data — so numbers keep
  their written form whenever it still round-trips). As in TomlBeef:
  - `KdlReadConfig.MetadataMode` is `KdlMetadataMode { None, Positions, PreserveStyle }`
    (TomlBeef's `TomlMetadataMode`). `None` and `Positions` write canonically; `PreserveStyle` makes
    the writer take the preserving path.
  - Under PreserveStyle the sidecar keeps each value's original token and a format struct, as
    TomlBeef's `TomlIntegerFormat` (base, uppercase hex digits, underscore grouping, group size,
    minimum digits) and float format (decimal/scientific, exponent spelling). A clean value reuses
    its token exactly (`0xFF_00_ff`); a dirty one (TomlBeef's `TomlDirtyFlags.Value`) is regenerated
    in its format, so `0xFF00FF` set to 255 writes `0xFF`, not `255`. A style API (as TomlBeef's
    `TomlStyleApiTests`) sets formats on new or existing values (hex for a mask, say).
  - Strings get the same treatment (raw/quoted/bare, multi-line) in the same sidecar.
  - The reader's events always carry number lexemes (`KdlValue.Integer`/`Float` `text`, free:
    views of the input), so the PreserveStyle builder captures formats from them. A plain (`None`)
    document stores no integer lexemes; floats keep theirs (or a compact equivalent), because the
    canonical form itself needs the written mantissa (`1.0`, `1E+10`) — decide the representation
    in phase 2.
- `KdlWriter` streaming emitter (phase 7): nodes, entries and children written in order without a
  document, with ckdl's options (indent, escape mode, identifier mode, float format).
- Always KDL v2 output (gokdl2 defaults to v1; kdl-py prints `#inf` as `inf` and raw strings in v1
  syntax — test these cases).

### 4.7 Metadata sidecar: Positions and PreserveStyle

TomlBeef's `TomlMetadata.bf` design: an opt-in sidecar keyed by node ID, so a plain parse pays
nothing. `Positions` records the source range of every node and entry. `PreserveStyle` adds the trivia
slots kdl-rs identified (node: leading, between annotation and name, before children, before the
terminator, the terminator, trailing; entry: leading, after the key, around `=`, after the annotation,
the value's literal text), stored as text-arena views (TomlBeef's `TomlTextArena.bf`), and keeps
slashdashed nodes, entries and children as parsed structure (@bgotink/kdl) so tools can un-comment
them. **Changing a value drops its literal text** and keeps its surrounding trivia (kdl-rs's bug is
keeping it). Target: every valid suite input round-trips byte for byte (@bgotink/kdl asserts this).

### 4.8 Resource limits

TomlBeef's `TomlResourceLimitState.bf`: max input bytes, depth, nodes, entries per node, string bytes,
token bytes (streams). Only KdlSharp has any limit (depth 1000); ckdl's stream buffer is unbounded.

### 4.9 Public API sketch

```beef
let doc = scope KdlDocument();
Try!(doc.Read(text));                                   // or ReadFile, ReadBytes, Read(Stream)
for (let node in doc.Nodes)                             // top-level nodes, in order
{
    if (node.Name == "button" && node.TryGetProperty("on-click", let handler))
        ...;
    node.TryGetArgument(0, let label);
    for (let child in node.Children) ...;
}
doc.Nodes[0].SetProperty("enabled", false);
doc.Write(output);                                      // canonical, or preserving after a PreserveStyle read

let reader = scope KdlReader(text);                     // events, no document
while (Try!(reader.Next()) case .StartNode(let name, let annotation)) ...
```

### 4.10 Typed mapping (`[KdlObject]`)

Port TomlBeef's serialization (`TomlObjectAttribute.bf`, `TomlSerializerCodeGen.bf`, `TomlBind.bf`,
`ITomlConverter.bf`, `TomlSerializer.bf`, and the document-first `Deserialize`/`Serialize`): the
comptime generator, converters registered through `Type.TypeDeclarations`, `[KdlName]`, `[KdlIgnore]`,
`[KdlRequired]`, `[KdlAlias]` (rename in place on write), key naming policies (default as declared),
the optional allocator, update-in-place writing. KDL needs **roles**, since a field can be an
argument, a property, a child node or a list of child nodes (gokdl2's tags and KdlSharp's attributes
are the vocabulary):

```beef
[KdlObject] class Button
{
    [KdlArgument(0)] public String Label ~ delete _;       // button "Save"
    public String Id ~ delete _;                           // id="save" (scalar fields: properties)
    [KdlProperty("on-click")] public String OnClick ~ delete _;
    public Style Style ~ delete _;                         // a [KdlObject] field: a child node `style { … }`
    [KdlChildren] public List<Widget> Items ~ ...;         // every child node, dispatched by name
}
```

Type annotations map through converters (`(px)12` into a `Length` struct). This phase comes after the
core is complete (the UI framework can start on the document API).

## 5. Porting table (TomlBeef → KdlBeef)

| TomlBeef file | Use in KdlBeef | Changes |
|---|---|---|
| `TomlCursor.bf` (311 lines) | `KdlCursor.bf` | KDL newline set incl. multi-byte NEL/LS/PS; stop classes for KDL string/comment bodies |
| `TomlBufferedStreamCursor.bf` (524) | `KdlBufferedStreamCursor.bf` | Names; same limits |
| `TomlChar.bf` (333) | `KdlChar.bf` | UTF-8 fast validation as is; KDL identifier/whitespace/newline/disallowed classes |
| `TomlDocumentStore.bf` (121), `TomlTextArena.bf` (46) | `KdlDocumentStore.bf`, `KdlTextArena.bf` | Node allocation instead of tables; pool recycling as is |
| `TomlEntryMap.bf` (268) | `KdlEntryList.bf` | Slots hold keyed or unkeyed entries; index only property keys; lookups last-wins |
| `TomlError.bf` (153) | `KdlError.bf` | KDL error kinds |
| `TomlResourceLimitState.bf` (82) | `KdlResourceLimitState.bf` | KDL limits |
| `TomlMetadata.bf` (847) | `KdlMetadata.bf` | KDL trivia slots, slashdash structure |
| `TomlParser.Values.bf` fast paths | numbers | `TryParsePlainInteger`, `TryParsePlainFloat` with KDL's underscores/prefixes |
| Serialization files (≈1350 lines) | `[KdlObject]` | Roles (§4.10) |
| `test-leaks.sh`, `test-roundtrip.sh`, `test-official-toml.sh`, `json-compare.py` | `test-leaks.sh`, `test-kdl-spec.sh`, `test-roundtrip.sh` | KDL suite layout (`input/`, `expected_kdl/`, `_fail`) |
| `bench/compare` (`plot.py`, `beef/` harness, `modes.sh`) | `bench/compare` | Add KdlBeef rows; charts |
| `AGENTS.md` | done | |

Port a file only when the phase needs it, and test it in KdlBeef's own suite; do not add a package
dependency on TomlBeef (the two libraries should stay independent).

## 6. Phases

Each phase ends with Debug and Release tests, the leak check, the suite scripts on both binaries and
the Windows tests (see `AGENTS.md`), committed.

**Phase 1 — Tokenizer, event reader, suite runner.** *Done: the suite passes in full through
`KdlCanonical.Format`.*
Port cursor, UTF-8 and char classes; write the tokenizer and `KdlReader`; `KdlTester` prints the
canonical form from events (buffering one node's properties to sort them) and `test-kdl-spec.sh` runs
the suite. Done when all 95 `_fail` cases fail and the valid cases' event streams are right (most
expected outputs match already).

**Phase 2 — Document, canonical writer, full suite.**
`KdlDocument`, store, nodes, entries (`KdlEntryList`), values, number lexemes; canonical writer; the
test-suite script compares every valid case byte for byte. Done at 243/243 + 95/95, leak-free.
The document builder consumes `KdlReader` events; the writer reuses `KdlCanonical`'s value, string
and number formatting, and `KdlTester` switches to reading through the document (keeping the event
path as a second mode, both checked by the suite script).

**Phase 3 — Speed.**
Join `bench/compare` (a `beef` harness like TomlBeef's, `KdlTester -bench`), then profile: SWAR scans,
first-byte dispatch, number fast paths, arena strings, no per-token allocation. Targets on the
benchmark inputs: document parse ≥ 150 MB/s, event reader ≥ 300 MB/s, canonical write ≥ 300 MB/s
(ckdl, the fastest today: ~40 MB/s events, ~25 MB/s document).

**Phase 4 — Errors, positions, limits, streams.**
Located messages for every `_fail` case (golden files), collect-errors mode with recovery, Positions
sidecar, resource limits, `Read(Stream)` through the buffered cursor (all input paths identical).

**Phase 5 — PreserveStyle and mutation.**
Trivia sidecar, slashdash structure, preserving writer, mutation API; every valid suite input
round-trips byte for byte; edits keep neighboring formatting.

**Phase 6 — `[KdlObject]`.**
Port the TomlBeef generator with KDL roles; typed benchmark against kdl-rs serde, gokdl2 and KdlSharp.

**Phase 7 — Extras as needed.** Streaming `KdlWriter`, KQL, v1 input, JSON-in-KDL.

## 7. Testing

- The official suite at two strengths: canonical output equals `expected_kdl` byte for byte; with
  PreserveStyle, every valid input round-trips byte for byte. Known failures, if any, are listed and
  asserted to still fail. Never compare only structure (KdlSharp).
- `[Test]` units per area from `spec-reference.md` (each bullet there is a test), in Debug and
  Release; LeakSanitizer (`test-leaks.sh`); Windows via `~/development/beef-proton`.
- Golden error messages for the `_fail` cases.
- The benchmark inputs double as large-input tests (node counts must match the reference).

## 8. Rerunning the benchmark

```bash
tests/fetch-spec.sh                       # spec, test suite, HTML-standard documents
cd bench/compare
./fetch.sh && ./build.sh                  # pinned clones + Zig 0.16; builds every harness into bin/
./gen-inputs.py                           # inputs/ (copies the HTML standard, generates the rest)
./run.sh > results.md                     # ~1 h; REPEATS=1 for a quick look
```

Toolchains used: Rust 1.98.1 (pinned by `rust/rust-toolchain.toml`), Go 1.27, Java 26 + Gradle,
Node 26, .NET 10, Python 3.14, GCC 16 + CMake, Zig 0.16 (downloaded by `fetch.sh`).

## 9. Open questions for the author

1. **KDL v1 input**: needed at all? (Plan: no until asked; then an explicit converting front end.)
2. ~~**Parent pointers** on nodes~~ — decided: node IDs with parent/sibling link arrays and a
   `KdlNode` handle with properties (§4.3).
3. **Collect-errors as the default** for the UI framework's hot reload, or opt-in?
4. **Typed mapping defaults** (§4.10): scalar fields as properties, object fields as child nodes —
   agree before phase 6.
5. **Unicode identifiers** in the UI markup: anything to restrict beyond the spec?

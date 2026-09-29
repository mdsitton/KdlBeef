# KdlBeef Architecture

How KdlBeef works today and why. It is not a task list: open work is in [status.md](status.md), the
phases still to come in [plan.md](plan.md), the KDL rules in [spec-reference.md](spec-reference.md).
Code conventions and Beef gotchas are in `AGENTS.md`.

## 1. Overview

- A KDL 2.0.0 library for Beef, built for UI markup. Today it has a **pull reader** (`KdlReader`),
  a **document** built on it (`KdlDocument` with `KdlNode` handles) with a canonical writer, and a
  **canonical formatter** that needs no document (`KdlCanonical`); mutation, positions, format
  preservation and typed mapping are later phases (`plan.md` §6).
- **Strict.** Invalid KDL is rejected with a located `KdlParseError` (line, column, byte offset,
  length). Slashdashed content is validated like everything else.
- **No per-node allocation.** The reader's events are views into the input, or into three reusable
  buffers when a string has escapes or is multi-line; they are valid until the next event.
- Linux64 first; Windows verified through the Proton-hosted Beef (`AGENTS.md`).

## 2. Source layout

| File (`src/KdlBeef/`) | Responsibility |
|---|---|
| `KdlDocument.bf` | `KdlDocument`: the node and entry tables (`KdlNodeRecord`, `KdlEntryRecord`, `KdlRangeRecord`), `ReadConfig`, `Read`/`ReadBytes`/`ReadFile` (the builder over `KdlReader`, `KdlLineCounter` for positions), `Clear`, `GetNode`, the canonical `Write` |
| `KdlReadConfig.bf` | `KdlMetadataMode` and `KdlReadConfig` (source name, limits) |
| `KdlSourceRange.bf` | `KdlSourceRange`: a node's or entry's source line, column, offset and length |
| `KdlNode.bf` | `KdlNodeId`, the `KdlNode` handle (name, annotation, navigation, argument and property lookups), `KdlNodeList` (children or top-level nodes) |
| `KdlEntry.bf` | `KdlEntry` (an argument or property view) and `KdlEntryList` |
| `KdlDocumentStore.bf` | Internal: the document's text arena (a pool-recycling `BumpAllocator`, from TomlBeef) and `OwnValue` |
| `KdlReader.bf` | `KdlEvent`, and `KdlReader`: the state machine (nodes, entries, children, slashdash suppression), whitespace, comments and line continuations |
| `KdlReader.Values.bf` | `extension KdlReader`: strings (identifier, quoted, raw, multi-line with dedent), escapes, numbers, keywords |
| `KdlValue.bf` | `KdlValue`, the non-owning tagged union: `Null`, `Bool`, `Integer` (int64 + lexeme), `Float` (double + lexeme), `BigInteger` (lexeme), `String` |
| `KdlCanonical.bf` | `KdlCanonical.Format` (input → canonical text through the reader) and the canonical value, string and number formatting the document writer will share |
| `KdlChar.bf` | Internal: identifier, whitespace, newline and disallowed-code-point classes; UTF-8 decode/encode; `ValidateDocument`; `LineAndColumn` |
| `KdlError.bf` | `KdlErrorKind` and `KdlParseError` (TomlBeef's error model: per-thread message buffer, no cleanup) |
| `KdlVersion.bf` | `KdlVersion { V1, V2 }` (unused until KDL v1 input, if ever) |

Tests are in `src/KdlBeef/tests/`; the CLI is `KdlTester/src/Program.bf`; the acceptance scripts are
`test-kdl-spec.sh` (official suite) and `test-leaks.sh` (LeakSanitizer over the `[Test]`s).

## 3. Reading

### Validation first

`KdlChar.ValidateDocument` runs once over the whole input before the first event: UTF-8 validity
(overlongs, surrogates, > U+10FFFF) and the code points KDL bans everywhere (U+0000–0008,
U+000E–001F, DEL, bidi controls, U+FEFF after position 0). Words of ASCII with no control
characters other than tab, LF and CR are skipped 8 bytes at a time (`IsPlainAsciiWord`, exact
per-byte tests), so indented text rarely leaves the word loop. Doing it up front means no scanner below has to check for banned or malformed
sequences: comment, string and whitespace scans only look for their own stop characters, and
multi-byte newlines and spaces are recognized by their UTF-8 bytes (`NewlineLength`,
`UnicodeSpaceLength`; every non-ASCII one starts with 0xC2, 0xE1, 0xE2 or 0xE3). The plan considered
folding this into the tokenizer; it stays a separate pass unless profiles say otherwise (phase 3).

### The state machine

`KdlReader.Next` resumes a loop with two states and no recursion (depth costs a `Frame` per open
node, not stack):

- **Nodes** (between nodes): skip `line-space`; then end of input (an error if a block is open), `}`
  (closes the innermost node's children block), or a node: optional `/-`, optional `(type)`, a name.
  Pushes a `Frame` and reports `StartNode`.
- **Entries** (inside a node): skip `node-space`; then a terminator (newline, `;`, `//` comment,
  end of input, or the parent's `}`, which is left for Nodes) reports `EndNode`; `/-` before an entry
  or a children block; `{` opens the children block (state Nodes); anything else is an entry, which
  must follow whitespace.

`Frame.mPhase` enforces the order of `base-node`: entries, then slashdashed children blocks, then at
most one real block, then slashdashed blocks only.

**Properties need no backtracking.** An entry is read as a value; if it is a string, the
`node-space` after it is skipped and a `=` makes it a property's key. Otherwise the skipped space is
remembered (`mPendingSpace`) as the separator the next entry requires.

**Slashdash is suppression.** A slashdashed node, entry or children block is parsed by the same code
with `mSuppressed` raised, and no events are reported until it drops back to 0. Frames record whether
the node or its open block was slashdashed, so the counter is restored when they close.

**Errors are sticky.** The first error puts the reader in a failed state; `Next` returns it again.
`Reset` starts over with the same buffers.

**Internal results carry no error.** Every internal method returns `Result<T, KdlFailure>`, where
`KdlFailure` is an empty struct: `Fail(...)` records the `KdlParseError` in the reader and returns the
token, so `.Err(Fail(...))` and `Try!` read as usual, and only `Next` turns the failure back into the
recorded error. With the error (about 56 bytes) in every `Result`, returning values cost more than
reading them; this change alone took the event pass from about 225 to 330 MB/s.

**Fast paths** (phase 3): `SkipNodeSpace` and `SkipLineSpace` step over ASCII spaces, tabs (and for
line-space LF and CR) inline and return unless the next byte could continue whitespace (`/`, `\`, a
non-ASCII lead byte); quoted-string bodies are scanned 8 bytes at a time
(`KdlChar.ScanQuotedText`: stops at `"`, `\`, controls up to CR, 0xC2 and 0xE2); numbers try
TomlBeef's `TryParsePlainInteger` and `TryParsePlainFloat` (Clinger's exact fast path,
bit-identical to `Double.Parse`, checked by a test) before the full parse, whose float fallback strips
underscores on the stack.

### Values

- Bare tokens are scanned as identifier characters, then classified: a token that starts like a
  number (a digit, or `.` then a digit, after an optional sign) must be a valid number; the bare
  keywords (`true`, `inf`, …) are errors; anything else is an identifier string.
- Every number keeps its token as written (a view, so it costs nothing), so a PreserveStyle
  document built on the reader can keep numbers in their original radix and spelling (`plan.md`
  §4.6).
- Integers accumulate in a uint64 with overflow detection: within int64 they are `Integer`,
  otherwise `BigInteger` with the token as written. Decimals with a fraction or exponent are `Float`
  with the nearest double (from `Double.Parse` after removing underscores; out-of-range exponents
  give ±infinity or zero) **and the token as written**, because the canonical form keeps the written
  mantissa (`1.0`, `1e10` → `1E+10`).
- Quoted strings without escapes are views of the input; the first `\` switches to decoding into a
  buffer. Raw strings are always views (the first `"` followed by as many `#`s ends them).
- Multi-line strings find their closing `"""` (skipping escaped characters), then `Dedent` applies
  the spec's order exactly: resolve whitespace escapes, split lines on every newline kind, take the
  last line as the prefix (it must be whitespace only), strip it from every other line (lines of only
  whitespace become empty), join with LF, then resolve the remaining escapes. Raw multi-line strings
  skip both escape steps.
- Error positions: `KdlParseError.At` computes line and column from the byte offset by rescanning
  the input, counting every KDL newline, so the reader tracks no line state while it reads.

## 4. Document

### Nodes are IDs

A node is a `KdlNodeId`, an index into `KdlDocument.mNodes`, a list of `KdlNodeRecord`s: name,
annotation, entry range, child count and the links (parent, first and last child, next and previous
sibling; 0 is none). Record 0 is a hidden root whose children are the top-level nodes, so a top-level
node's parent is 0 and `Parent` returns an invalid handle. There is no per-node object and no
per-node children list; the design follows Sizzle's `EntityGraph` (`plan.md` §4.3), with the node's
fields kept together in one record rather than in parallel arrays, since a node's name, entries and
links are read together.

`KdlNode` is the public face: the document, the ID and the document's generation (16 bytes). Its
properties read and write the record. The generation changes on every `Clear` and `Read`, so a
handle from before is invalid even though its ID now names another node; a removed node (phase 5)
will be flagged in its record, its slot not reused until `Clear`. Navigation properties return invalid
handles where there is no node; anything else on an invalid handle is a fatal error.

### Entries

`mEntries` holds every entry of the document; a node's are `mEntryStart ..< mEntryStart +
mEntryCount`. The reader reports a node's entries before its children, so a parse appends each node's
entries contiguously, in order. `mEntryCapacity` is the room reserved at the start: adding an entry
past it (mutation, phase 5) moves the node's range to the end of the list, leaving the old range as a
hole until the next `Clear`. Property lookup scans the node's entries from the end, so the last
duplicate wins; the hash index for nodes with many properties (`plan.md` §4.3) is not built yet.

### Text

Every string, key, annotation, float lexeme and big integer is copied into the document's arena
(`KdlDocumentStore`), a `BumpAllocator` whose pools are kept across `Clear` and `Read` (TomlBeef
measured the page faults of fresh pools at up to 40% of parse time). A plain read drops integer
lexemes (the canonical form writes integers in decimal); PreserveStyle will keep them.

### Mutation

`KdlNode.Mutation.bf` has the public operations, `KdlDocument.Mutation.bf` the table work:

- Structure: `KdlDocument.AddNode`, `AddChild`, `InsertBefore`/`InsertAfter` (new siblings),
  `MoveInto`/`MoveBefore`/`MoveAfter`/`MoveToTopLevel` (O(1) relinks; a move into the node's own
  subtree or another document is refused), `Remove`. Removal unlinks the node and walks its subtree
  through the links to flag every record `Removed`, so all their handles become invalid; the slots
  stay until `Clear`.
- Entries: `AddArgument` (optionally annotated), `SetArgument`, `RemoveArgument`, `SetProperty`
  (changes the last property with the key, the one that counts, keeping its annotation and place;
  appends otherwise; an overload sets the annotation), `RemoveProperty` (every duplicate),
  `RemoveEntryAt`, `ClearEntries`. A node's entries stay contiguous: `AppendEntry` grows the range in
  place when it is the last in the list or has spare capacity, and otherwise moves it to the end with
  doubled capacity. Entry source ranges (Positions) move with their entries; added entries and nodes
  have none.
- Values passed in are copied into the document (`KdlDocumentStore.OwnValue`); a computed float
  without a lexeme is written as its shortest round-trip form with `.0` for integral values.

### Configuration, limits and positions

`KdlReadConfig` (TomlBeef's `TomlReadConfig` shape) carries the metadata mode, the source name and
the limits. The reader enforces the limits itself, so event users get them too: `MaxInputBytes`
before validation, `MaxDepth` (256 by default) and `MaxNodes` when a node opens, `MaxEntriesPerNode`
per entry, `MaxStringBytes` on every decoded string (names, keys, annotations, values). Slashdashed
content counts: it is parsed like the rest. Errors carry the source name (`source:line:column:
message`); `ReadFile` uses the path unless one is set.

The reader reports each event's range: `Offset` and `EndOffset` (a node's range, at `EndNode`,
runs from its `/-` or annotation to its last token, tracked as `mLastTokenEnd`). With
`KdlMetadataMode.Positions`, the builder turns them into line and column (`KdlLineCounter`: one
forward pass over the input, since events come in source order) and keeps a `KdlRangeRecord` per node
ID and per entry index, beside the records; plain reads keep none. `TryGetSourceRange` on nodes and
entries returns them as `KdlSourceRange`s naming the document's copy of the source name.

### Reading and writing

`Read` resets the document, runs a `KdlReader` (kept for its buffers) and turns events into records
with a stack of open node IDs; on an error the document is cleared. `Write` walks the tree through
the links (first child, else next sibling, else up to the parent's next sibling, closing blocks), so
it needs neither recursion nor a stack, and writes each node's head with the same formatting helpers
as `KdlCanonical`. The two paths are checked against each other: the suite script runs both, and they
agree on the HTML-standard document.

## 5. Canonical form

`KdlCanonical.Format` drives a `KdlReader` and buffers one pending line per open depth (reused across
nodes): the head (indent, annotation, name, arguments) and the properties (raw key, formatted value).
A node's line is written when its first child starts (with ` {`) or when it ends; properties are then
sorted by key (ordinal), keeping the last of each duplicate. Formatting rules (`spec-reference.md`
§12):

- Strings are bare when `IsBareIdentifier` (identifier characters only, not number-like, not a bare
  keyword, not empty), else quoted with `\" \\ \b \f \n \r \t` and `\u{…}` for newlines and banned
  code points.
- `Integer` in decimal; `BigInteger` converted from any radix with base-2^32 limbs and division by
  10^9; `Float` from its lexeme (no underscores or `+`, leading zeros trimmed, `E` with an explicit
  sign), or `#inf`/`#-inf`/`#nan`, or the shortest round-trip double with `.0` for computed values.

The canonical output of any valid document is a fixed point (formatting it again changes nothing);
this holds for the HTML-standard benchmark document.

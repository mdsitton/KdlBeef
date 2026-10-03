# KdlBeef Architecture

How KdlBeef works today and why. It is not a task list: open work is in [status.md](status.md), the
phases still to come in [plan.md](plan.md), the KDL rules in [spec-reference.md](spec-reference.md).
Code conventions and Beef gotchas are in `AGENTS.md`.

## 1. Overview

- A KDL 2.0.0 library for Beef, built for UI markup. Today it has a **pull reader** (`KdlReader`,
  over text in memory or a `Stream` read through a buffer),
  a **document** built on it (`KdlDocument` with `KdlNode` handles) with canonical and
  style-preserving writers, and a **canonical formatter** that needs no document (`KdlCanonical`),
  plus mutation, positions, resource limits, collect-errors and compile-time typed mapping
  (`[KdlObject]`).
- **Strict.** Invalid KDL is rejected with a located `KdlParseError` (line, column, byte offset,
  length). Slashdashed content is validated like everything else.
- **No per-node allocation.** The reader's events are views into the input, or into three reusable
  buffers when a string has escapes or is multi-line; they are valid until the next event.
- Linux64 first; Windows verified through the Proton-hosted Beef (`AGENTS.md`).
- **Built on FormatCore** (`~/development/FormatCore`, the shared core of the four format
  libraries): the input cursors, line counting, UTF-8 validation and helpers, the error carrier,
  numbers, the text arena and growable tables, tree links, the read shell and the typed-mapping driver
  are FormatCore's (its `docs/architecture.md`; `docs/migration.md` lists what moved). KDL's grammar,
  error kinds, recovery, document records, PreserveStyle and canonical forms stay here; `KdlText`
  gives FormatCore KDL's character rules.

## 2. Source layout

| File (`src/KdlBeef/`) | Responsibility |
|---|---|
| `KdlDocument.bf` | `KdlDocument`: the node and entry tables (`KdlNodeRecord`, `KdlEntryRecord`, `KdlRangeRecord`), `ReadConfig`, `Read` (text or `Stream`)/`ReadBytes`/`ReadFile` (the builder over `KdlReader`), `Clear`, `GetNode`, the canonical `Write` |
| `KdlReadConfig.bf` | `KdlMetadataMode` and `KdlReadConfig` (source name, limits) |
| `KdlSourceRange.bf` | `KdlSourceRange`: a node's or entry's source line, column, offset and length |
| `KdlNode.bf` | `KdlNodeId`, the `KdlNode` handle (name, annotation, navigation, argument and property lookups), `KdlNodeList` (children or top-level nodes) |
| `KdlNode.Lookup.bf` | Typed argument and property getters, chainable `Find`, `KdlNamedNodes` (`Children.Named`) and `KdlDescendants` |
| `KdlEntry.bf` | `KdlEntry` (an argument or property view) and `KdlEntryList` |
| `KdlDocument.Style.bf` | `extension KdlDocument`: PreserveStyle's `KdlNodeStyle`/`KdlEntryStyle` records, capture during a read, the preserving writer, styled value regeneration |
| `KdlDocument.Mutation.bf` | `extension KdlDocument`: `AddNode`, links, removal, entry growth and the per-entry side tables |
| `KdlNode.Mutation.bf` | `extension KdlNode`: the public edits (structure, arguments, properties) |
| `KdlObjectAttribute.bf` | `[KdlObject]`, `KdlNaming`, and the field attributes (`KdlName`, `KdlAlias`, `KdlIgnore`, `KdlRequired`, `KdlArgument`, `KdlArguments`, `KdlChild`, `KdlChildren`) |
| `KdlSerializerCodeGen.bf` | The comptime generator behind `[KdlObject]` |
| `KdlBind.bf` | `KdlValueRef`, `KdlValueWriter` and the runtime helpers the generated code calls |
| `IKdlSerializable.bf` | `IKdlSerializable`, `IKdlConverter<T>`, `[KdlConverter]`, `[KdlUseConverter]` |
| `KdlSerializer.bf` | `KdlSerializer.Read`/`ReadFile`/`Write`/`WriteFile` for whole documents |
| `KdlDocumentStore.bf` | Internal: the document's text (a FormatCore `TextArena`) and `OwnValue` |
| `KdlReader.bf` | `KdlEvent`; `KdlReader` (public: dispatches to an in-memory or a stream core); `KdlReaderCore<TCursor>`: the state machine (nodes, entries, children, slashdash suppression), whitespace, comments, line continuations and the window helpers |
| `KdlReader.Values.bf` | `extension KdlReaderCore<TCursor>`: strings (identifier, quoted, raw, multi-line with dedent), escapes, numbers, keywords |
| `KdlText.bf` | Internal: `KdlText`, KDL's `ITextPolicy` for FormatCore (banned code points and their messages, the newline set), the cursor settings of a read config and the mapping of FormatCore's input errors to `KdlParseError` |
| `KdlValue.bf` | `KdlValue`, the non-owning tagged union: `Null`, `Bool`, `Integer` (int64 + lexeme), `Float` (double + lexeme), `BigInteger` (lexeme), `String` |
| `KdlCanonical.bf` | `KdlCanonical.Format` (input → canonical text through the reader) and the canonical value, string and number formatting the document writer will share |
| `KdlChar.bf` | Internal: identifier, whitespace, newline and disallowed-code-point classes; the quoted-string stop scan (UTF-8, hex and validation are FormatCore's `Utf8` and `Hex`) |
| `KdlError.bf` | `KdlErrorKind`; `KdlParseError` and `KdlDiagnostic`, typealiases of FormatCore's `ParseError<KdlErrorKind>` and `Diagnostic<KdlErrorKind>` (per-thread message buffers, no cleanup) |
| `KdlVersion.bf` | `KdlVersion { V1, V2 }` (unused until KDL v1 input, if ever) |

Tests are in `src/KdlBeef/tests/`; the CLI is `KdlTester/src/Program.bf`; the acceptance scripts are
`test-kdl-spec.sh` (official suite) and `test-leaks.sh` (LeakSanitizer over the `[Test]`s).

## 3. Reading

### Cursors and the window

The reader is `KdlReaderCore<TCursor>`, specialized for FormatCore's two cursors,
`ByteCursor<KdlText>` and `BufferedStreamCursor<KdlText>` (`IInputCursor`; the window design began
here, from TomlBeef's `ITomlCursor`, and moved to FormatCore). The public `KdlReader` holds one core of
each, creates the stream one on first use, and dispatches on which is reading. The core's two largest
fields (the cursor and the pending error) come last: placed first they cost up to 1% of the
instructions per byte.

The core reads a **window**: `mData[offset]` for `mBase <= offset < mEnd`, with absolute offsets
(`mData` is the buffer pointer minus `mBase`), so every offset the reader keeps (token starts, frame
positions) stays valid when a stream moves its buffer. Every read that may reach the window's end
goes through a helper that asks for more first: `Avail(pos)`, `AvailN`, `PeekAt`, `NewlineAt`,
`SpaceAt` (up to 3 bytes: CRLF and multi-byte spaces never split), `DecodeAt` (4), `ScanQuoted`.
They call `Grow`, which calls `IInputCursor.Fill`:

- `ByteCursor` (in-memory text): the window is the whole input and `Fill` is an inlined `false`,
  so `Grow` folds to `return false` and `Avail(pos)` to `pos < mEnd`. `Grow` must stay `[Inline]`
  and return a constant when `Fill` adds nothing, and hot loops advance a local position rather
  than `mPos` (a store per byte): without these the in-memory path lost 25%. It is now within about
  5% of the pre-cursor reader.
- `BufferedStreamCursor` (a `Stream`; KdlBeef's stream cursor merged with JsonBeef's in FormatCore): a buffer
  (64 KiB by default, `StreamBufferBytes`) holding the window from the current construct on
  (`mRetain`: the node or entry being read; nothing between constructs). A refill counts the lines of
  the bytes it drops, moves the rest to the front and reads more; a construct longer than the buffer
  doubles it. `MaxTokenBytes` is a hard limit on what one construct holds (from its start through
  the reader's lookahead, `pos + count - keep` in `Fill`): the buffer starts no larger than it and
  never grows past it, so a construct over the limit cannot fit the window and always reaches the
  check. The whitespace loops store their local position into `mPos` at the window's end, so a
  refill drops idle whitespace; a drop never splits a CRLF (the line counter would count two
  newlines). When the buffer moves, the event's views (`mName`,
  `mAnnotation`, `mValue`, and `mEntryValue`, ReadEntry's key-or-argument kept as a field for this)
  are rebased onto it.

### Validation

FormatCore's `Utf8.FindInvalid<KdlText>` checks a range for invalid UTF-8 (Unicode table 3-7:
overlongs, surrogates, > U+10FFFF, bad or truncated sequences, reported at the lead byte with
messages that name the bytes) and the code points KDL bans everywhere (`KdlText`: U+0000–0008,
U+000E–001F, DEL, bidi controls, U+FEFF after position 0). Words of ASCII with no control characters
other than tab, LF and CR are skipped 32 and 8 bytes at a time (`KdlText.IsPlainWord`, exact per-byte
tests). UTF-16 and UTF-32 input is reported as such ("The input is UTF-16LE (KDL must be UTF-8)"). The byte cursor checks
the whole input in `Begin`, before the first event. The stream cursor checks each read as it
arrives, up to the last complete sequence (`CompleteSequencesEnd`), and its window ends there: the
reader never sees unchecked bytes. `Begin` fills and checks the first buffer, so a document that fits
reports the same first error either way; further on, events may come before an encoding error, and
when the reader runs into the end of what was delivered, the input's error (encoding, I/O, size)
replaces whatever the reader would have reported (`mInputFailed`).

Because everything the reader sees is valid, no scanner checks for banned or malformed sequences:
comment, string and whitespace scans only look for their own stop characters, and multi-byte newlines
and spaces are recognized by their UTF-8 bytes (every non-ASCII one starts with 0xC2, 0xE1, 0xE2 or
0xE3).

### Collect-errors

With `KdlReadConfig.CollectErrors` an error does not stop the read (`AfterError`): the core records
it (Next returns it) and `Recover` skips the rest of the broken node with `SkipToTerminator`, to its
newline or `;` (consumed), or the `}` or end that closes its parent, stepping over strings (a string
the error was in is restarted from its opening quote, `mStringStart`), comments, line continuations
and balanced children blocks without checking them. A node whose `StartNode` was reported gets its
`EndNode` next (`mEndAfterRecovery`); unclosed blocks at the end are reported once and then closed
one `EndNode` per call (`mClosingAtEnd`); a stray `}` is dropped; an error at the same offset twice
advances one byte, so recovery always progresses. `mSuppressed` is recounted from the frames, and a
frame closed at the end with its slashdashed children block still open releases that block's
suppression, so every reported `StartNode` gets its `EndNode`. Recovery runs before the error is
returned and may refill a stream: it only notes an input failure (`HasInputError`), because making
the input's error would overwrite the per-thread message buffer the pending error views; the input's
error is reported on a later call.
Encoding, I/O and resource-limit errors, and `MaxErrors` (100 by default), still stop the read
(`IsStopped`). `KdlDocument` keeps what it read and copies each error's message into its store
(`Errors`); `Read` returns the first, whose text therefore lives with the document:
`KdlParseError.Detach` copies it to the per-thread buffers, as `KdlSerializer` does before its
scoped document goes. The suite runs a fourth time in this mode (first error = the
golden one), and random mutations of the suite's inputs never crash or hang it.

### Positions and error locations

Errors and positions are located by the cursor (`Locate`), with forward FormatCore
`LineCounter<KdlText>`s: newlines are found 16 bytes at a time while a word holds no candidate byte
(below 0x0E, or 0xC2/0xE2, the lead bytes of NEL, LS and PS), and columns are counted only on request
(this made stream reads 9-34% cheaper in instructions than the per-code-point counter). An offset on
the LF of a CRLF is on the line the CRLF ends (XML's and JSON's rule; KdlBeef counted it at the CR).
The byte cursor counts from its last answer (or from the start for an earlier offset). The stream cursor keeps
one counter at the bytes it has dropped (nothing before it can be located) and one that moves forward
for requests (an earlier request counts from the first). Offsets an error may report after the window
has moved past them are located when read (`!IsWhole`, `LocateEarly`, `FailAt`): a
children block's `{` (for the unclosed-block error at the end), a `/* */` comment's start, a line
continuation's `\` and a slashdash's `/-`. A random-mutation comparison of stream and in-memory reads
of the suite's inputs finds no difference other than the documented order of encoding errors.

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

In the code, `ReadNext` is only the loop: each state is a step (`StepNodes`, `StepEntries`) that reads
one construct through a helper per construct (`AtInputEnd`, `CloseBlock`, `OpenNode`, `AtTerminator`,
`SlashdashedInNode`, `OpenBlock`, `NextEntry`) and returns its event, or `cNoEvent` when it has none
to report. Suppression and source capture meet in one place, `Report` (reported only outside
slashdashed content; depth, range and PreserveStyle slice set there); recovery's leftovers are the
first thing each step checks (`mClosingAtEnd`, `mEndAfterRecovery`). The helpers on the hot path are
`[Inline]`, so the compiled loop is the same shape as before the split: measured against it
(alternating runs), document reads are within ±1% on `ui` and `config`, +5% on `numbers` and −3% on
`html-standard` (same instruction count and fewer branch misses there: code layout).

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
`TryParsePlainNumber` (TomlBeef's `TryParsePlainInteger` and `TryParsePlainFloat` in one pass over
the integer part: Clinger's exact fast path for floats, bit-identical to `Double.Parse`, checked by a
test) before the full parse, whose float fallback strips underscores on the stack. Identifier
scanning is one table lookup per byte (`KdlChar.IdentifierByteClass`: stop, ASCII identifier
character, or a code point to decode). Property lookup scans the node's entries from the end:
28–64 ns for 4–16 properties (`KdlTester -bench-lookup`), so the planned hash index is not built.

### Values

- Bare tokens are scanned as identifier characters, then classified: a token that starts like a
  number (a digit, or `.` then a digit, after an optional sign) must be a valid number; the bare
  keywords (`true`, `inf`, …) are errors; anything else is an identifier string.
- Every number keeps its token as written (a view, so it costs nothing), so a PreserveStyle
  document built on the reader can keep numbers in their original radix and spelling (`plan.md`
  §4.6).
- Integers accumulate in a uint64 with overflow detection: within int64 they are `Integer`,
  otherwise `BigInteger` with the token as written. Decimals with a fraction or exponent are `Float`
  with the nearest double (from `Double.Parse` after removing underscores, with KdlBeef's own
  `NumberFormatInfo`, `KdlChar.sNumberFormat`, so the culture's decimal separator never applies;
  out-of-range exponents give ±infinity or zero, and a failed conversion is an error, not an
  infinity) **and the token as written**, because the canonical form keeps the written
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
handles where there is no node; anything else on an invalid handle is a fatal error. The views over
a node (`Children`, `Nodes`, `Entries`, `Named`, `Descendants` and their enumerators) are live and
follow the same rule: each keeps the generation it was made in (and its node), `IsValid` tells, and
using a stale one is a fatal error (`KdlDocument.CheckView`) instead of showing another document's
nodes.

Lookups (`KdlNode.Lookup.bf`) are API, not a query language (the author found KQL's selector syntax
hard to use; `plan.md` §6): typed getters for properties (by key) and arguments (by index),
`TryGet…(…, out)` and `Get…(…, fallback)` as in TomlBeef's tables; `Find(name)` for the first child;
`Children.Named(name)` and `Descendants` (depth first, document order, optionally `.Named`), both
walking the sibling links with no allocation. `Find` and the getters treat the default handle, which a
failed `Find` returns, as "no node", so chains end in the fallback instead of a fatal error; a stale
handle (removed node, cleared document) is still fatal, since it is a bug rather than absent data.

### Entries

`mEntries` holds every entry of the document; a node's are `mEntryStart ..< mEntryStart +
mEntryCount`. The reader reports a node's entries before its children, so a parse appends each node's
entries contiguously, in order. `mEntryCapacity` is the room reserved at the start: adding an entry
past it (mutation, phase 5) moves the node's range to the end of the list, leaving the old range as a
hole until the next `Clear`. Property lookup scans the node's entries from the end, so the last
duplicate wins; the hash index for nodes with many properties (`plan.md` §4.3) was measured unneeded
and is not built (§3).

### Text

Every string, key, annotation, float lexeme and big integer is copied into the document's arena
(`KdlDocumentStore`), a FormatCore `TextArena` whose chunks are kept across `Clear` and `Read`
(TomlBeef measured the page faults of fresh pools at up to 40% of parse time; the arena read
documents 1-3% cheaper than the pool-recycling `BumpAllocator` it replaced). The node and entry
tables are FormatCore `GrowList`s (inlined `Add`), linked through FormatCore's `Tree` over the node
record's `ITreeRecord` accessors. A plain read drops integer
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

### PreserveStyle

`KdlMetadataMode.PreserveStyle` keeps the source text of every node and entry, so `Write` gives back
the document as it was read and regenerates only what changed. The promise is TomlBeef's (comments,
blank lines, indentation and how values were written survive; `plan.md` §9), but the mechanism makes
an unchanged document round-trip byte for byte: `test-roundtrip.sh` checks every valid suite input
and both HTML-standard documents, from memory and through a 16-byte stream buffer, and random
valid mutations of the suite's inputs all round-trip.

- **Slices.** In this mode the reader cuts the source into one slice per reported event, from the
  end of the previous event's to the end of its own: a node's name (StartNode), an entry's value, a
  node's terminator (EndNode: its newline, `;` or `//` comment, or nothing before the parent's `}` or
  the end), and the rest at EndOfDocument. The slices of all events are the document (after a BOM).
  Landmarks split them: the node's start, `mNameStart`, the entry's start, `mValueStart`, and a
  children block's `{` (reported with the block's first reported event) and `}` (with its EndNode).
  Slashdashed content, comments and whitespace fall inside the slice of the next event. A stream
  keeps the slice in its window (`RetainIdle`: the slice start instead of nothing).
- **Pieces.** `KdlDocument.Style.bf` copies them into the store: per node (`KdlNodeStyle`, by ID)
  the leading text, annotation prefix, name, text before the children (to just after `{`), block
  end (to just after `}`) and tail; per entry (`KdlEntryStyle`, by index, moving with its entries
  like the source ranges) the leading text, prefix (key, `=`, annotation) and value; plus the text
  after the last node, the BOM and the indentation unit (from the first nested node; 4 spaces
  otherwise).
- **Writing** (`WritePreserving`) walks the tree like the canonical writer and concatenates the
  pieces. What is missing or marked dirty is generated: a node added or moved (`LeadingDirty`)
  starts a new line if the output does not end with one and is indented like the document; a renamed
  node or changed annotation regenerates that piece; a new children block is ` {` … `}` around the
  children, before the node's tail (so a trailing comment stays after `}`); a changed value
  (`ValueDirty`) keeps its original's form (`AppendStyledValue`: radix and hex case for integers;
  quoted, raw or bare for strings; raw only when the value cannot open as `#"""`, i.e. does not
  start with two quotes or equal one); new entries are ` key=value`. A kept tail ends with the node's
  terminator unless the node was last before a `}` or the end (`EndsWithTerminator`: a final `;` or
  newline that does not end a line continuation); when such a node is followed by a node after an
  edit (a move), the writer adds a newline first (`mNeedTerminator`), or the two would read as one
  node, or the second as the first's argument. Removing a node or entry removes its
  leading text (comments before it go with it). `WriteCanonical` gives the canonical form of any
  document.
- Plain reads pay one predictable branch per event: speeds are unchanged. A PreserveStyle read runs
  at 90–155 MB/s and writing it back at 540–890 MB/s.

### Configuration, limits and positions

`KdlReadConfig` (TomlBeef's `TomlReadConfig` shape) carries the metadata mode, the source name and
the limits. The reader enforces the limits itself, so event users get them too: `MaxInputBytes`
before validation, `MaxDepth` (256 by default) and `MaxNodes` when a node opens, `MaxEntriesPerNode`
per entry, `MaxStringBytes` on every decoded string (names, keys, annotations, values). Slashdashed
content counts: it is parsed like the rest. Errors carry the source name (`source:line:column:
message`); `ReadFile` uses the path unless one is set.

The byte limits are allocation budgets, not only checks of the result. A string that needs decoding
(escapes, a multi-line string's dedent) is checked as its value grows and fails as soon as it passes
`MaxStringBytes`; one without escapes is a view and allocates nothing; the intermediate copies of a
multi-line string are bounded by its source (a decoded string is never longer), which is in memory
already or, from a stream, bounded by `MaxTokenBytes`. `ReadFile` without streaming checks the file's
size against `MaxInputBytes` before reading anything, and stops at the limit if the file grows.

The reader reports each event's range: `Offset` and `EndOffset` (a node's range, at `EndNode`,
runs from its `/-` or annotation to its last token, tracked as `mLastTokenEnd`). With
`KdlMetadataMode.Positions`, the builder turns them into line and column through the reader's cursor
(`KdlReader.Locate`: a forward count, since events come in source order; streams too) and keeps a
`KdlRangeRecord` per node
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
- `Integer` in decimal; `BigInteger` written as written if decimal (without `+`, underscores and
  leading zeros: linear), else converted from its radix with base-2^32 limbs and division by 10^9; `Float` from its lexeme (no underscores or `+`, leading zeros trimmed, `E` with an explicit
  sign), or `#inf`/`#-inf`/`#nan`, or the shortest round-trip double with `.0` for computed values.

The canonical output of any valid document is a fixed point (formatting it again changes nothing);
this holds for the HTML-standard benchmark document.

## 6. Typed mapping (`[KdlObject]`)

TomlBeef's `[TomlObject]` design with KDL's roles (`plan.md` §4.10, decisions in §9 question 4).

- **Generation.** `[KdlObject]` is an `IComptimeTypeApply`: `KdlSerializerCodeGen.Emit` emits the
  signatures of `KdlNodeName`, `KdlRead(KdlNode, allocator)` and `KdlWrite(KdlNode)` (plus
  `IKdlSerializable` and, for classes, `KdlClaimedChildNames` and `KdlArgumentsStart`) and FormatCore's
  `MappingDriver` entry, a `[Comptime] KdlGen_` method in the type. Every body is
  `Compiler.Mixin(KdlGen_(part))`: `Body` classifies the fields and writes the code when the method is
  compiled. Because the evaluation's entry point is the user's own method, the converter and
  `[KdlChildren]` subtype lookups (`Type.TypeDeclarations` filtered by FormatCore's
  `Registry.IsVisible`) see exactly the user's project and its dependencies; inside `ApplyToType` they
  had relied on `AlwaysVisible` and found nothing once a second project depended on KdlBeef. Planning
  at body time also lets a type hold itself and handles generic types (stubs for the unspecialized
  pass). Errors now point at the generated entry, with the same `[KdlObject] Type.field: …` text.
  Naming, literals, integer bounds and type shapes are FormatCore's. Emitted code is fully qualified,
  reaches fields through `this.` and uses `_`-prefixed locals; enums are generated switches over their
  (named) cases, so nothing needs reflection at run time. A `[KdlObject]` base's methods are hidden
  (`new`) and called first. Unsupported field types, and roles on the wrong kind of field, stop the
  build naming the field. `Emit` works in three steps: `ScanChain` (the chain's shared places and
  conflicts), a `FieldPlan` per field from `PlanField` (kinds, dictionary value and list item types,
  role, argument index; every check), then the code from the plans, so nothing is emitted for a type
  whose mapping fails.
- **Roles.** Scalars (bool, integers, floats, String, enums, converter types) are properties;
  `[KdlArgument(n)]` an argument; `[KdlChild]` a `name value` child; `[KdlArguments] List` the
  arguments from the first free one. `[KdlObject]` fields are child nodes named after the field;
  `List<scalar>` a child holding the items as arguments; `List<[KdlObject]>` repeated children named
  after the element type (`KdlObjectAttribute.Name`, or the type name through its naming);
  `[KdlChildren] List<T>` every child no other field claims (a static `sKdlClaimed` array, built by a
  mixed-in method), dispatched
  by node name to the concrete `[KdlObject]` types assignable to T found through
  `Type.TypeDeclarations`, and written through `as IKdlSerializable` so each item's own type decides.
  Names are kebab-case by default (`KdlNaming`), enum cases too.
- **Containers as content.** A `Dictionary` field, and a `List` of Lists or Dictionaries, is a child
  node named after the field with the container as its *content*, one recursive rule to any depth
  (`EmitReadContent`/`EmitWriteContent`):
  - `List<scalar>`: the node's arguments (`tags a b`); `List<[KdlObject]>`: its children named after
    the item type; `List<List or Dictionary>`: its `-` children, one per item (JSON-in-KDL's
    convention: `matrix { - 1 2; - 3 }`);
  - `Dictionary<K, V>`: one child per entry, named by the key: a String as written (no naming
    policy), an integer in decimal (`"1" one`), an enum case by its name; a scalar V is the entry's
    argument (`key value`, `key #null` skipped), a `[KdlObject]` V the entry node itself, a container V
    its content (`sections { db { host x } }`).

  Children rather than properties, so every value type, annotations and any key fit one shape.
  Reading replaces the contents (deleting what they own, recursively, on a heap read), adds each item
  or entry before reading it (String keys through `TryAddAlt`, allocated only when new; a repeated
  key's old value is deleted, so the last one wins) and reads it in place. Writing works in place:
  list items reuse the existing arguments or children by position (`KdlArgumentCursor`,
  `KdlChildCursor`), dictionary entries by key (`KdlKeyIndex`, which indexes the entry nodes once,
  drops all but the last duplicate, and at `Finish` removes the keys the dictionary no longer has);
  kept entries keep their comments and number forms, new keys are appended in the dictionary's
  iteration order, leftovers are removed. Linear (64,000 keys write in about 7 ms). A null item is
  skipped, a null dictionary value removes its entry. `[KdlUseConverter]` on a container field
  applies to the scalars at its leaves. Dictionary keys of other types (floats, bools, objects) stop
  the build.
- **Whole documents** go through `KdlDocument.Root`, a valid handle for the document itself (no
  name or entries; its children are the top-level nodes). There, properties are `name value`
  children (`KdlBind` and `KdlValueWriter` redirect), so a config file reads `version 2`.
- **Runtime (`KdlBind`).** `Find*` locate a value (the last property or child with a name wins;
  `#null` is absent) as a `KdlValueRef` (value, annotation, node, entry), `To*` convert it with
  range checks (uint64 up to 2^64-1 through big integers), and errors name the node and field and
  are located at the entry or node (Positions; `KdlSerializer` raises the metadata mode to it).
  Writes go through `KdlValueWriter` and update in place: `SetProperty` keeps an existing annotation,
  arguments fill with `#null` up to their index, list items reuse the existing children by position
  and trim the rest, `[KdlChildren]` items reuse an unclaimed child with the right name or insert one
  there. A document read with PreserveStyle therefore keeps its comments and formatting. Lists are
  read and written in one pass (`KdlArgumentRefs`, and the cursors `KdlArgumentCursor`,
  `KdlChildCursor`, `KdlFreeChildCursor`, which carry their position instead of finding item i from
  the start: 64,000 items bind or write in 1-10 ms). A null list removes what it maps, like a null
  String: its arguments, its child node, its item children, or a `[KdlChildren]` list's unclaimed
  children; an empty list does the same.
- **Inheritance.** A subclass's `KdlRead` calls its `[KdlObject]` base's first, and both see the same
  node, so the claimed child names and the first free argument are computed over the whole chain,
  each level with its own naming. A class's claimed names are a `protected virtual
  KdlClaimedChildNames` property that subclasses override, so a base's `[KdlChildren]` list also
  leaves alone the children a subclass's fields claim. One `[KdlChildren]` list per chain.
- **Mapping checks.** The same pass over the chain stops the build, naming the fields and their
  declaring types, for anything that would read the same KDL twice: a negative or repeated
  `[KdlArgument]` index, a second `[KdlArguments]` or `[KdlChildren]`, more than one role attribute
  on a field, and two properties or two child nodes with one name (aliases and a List of objects'
  item name included). A property and a child node may share a name: they are different places.
- **Converters** (`IKdlConverter<T>`, `[KdlConverter(typeof(T))]`, `[KdlUseConverter]`) read a
  `KdlValueRef` (so they see the annotation: `(px)12`) and write through the `KdlValueWriter`.
- **Ownership** as TomlBeef: a null String, object or List field gets a new instance on read (from the
  allocator when one is given); replaced List items are deleted without an allocator.

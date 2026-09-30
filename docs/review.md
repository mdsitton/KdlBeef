# KdlBeef deep review

Reviewed: 2026-09-30. Source revision: `398e3236db9a00c0e947f000562b769e0fe63055`.

This review covers the reader, cursors and validation, document construction, canonical and
PreserveStyle writing, mutation and navigation, typed mapping, and the existing tests. Read it with
[architecture.md](architecture.md), [spec-reference.md](spec-reference.md), and [status.md](status.md).
Line references describe the reviewed revision and will move as fixes land.

The core design is sound: one iterative reader shares the grammar between memory and streams;
document text is owned through an arena; node handles detect stale generations; ordered entries keep
duplicates with last-wins lookup. Nine bugs were reproduced, despite all existing checks passing.
Fix error ownership and output corruption first, then recovery, numeric parsing, limits and typed
mapping. Performance and API recommendations below are separate from the confirmed correctness bugs.

## Handoff

Read R1-R9 below and add focused behavioral regression tests before fixing them. R1-R3 are the first
priority: collected serializer errors return dangling text, PreserveStyle moves can merge sibling
names, and stream recovery corrupts the error it is returning. R4-R9 cover locale-dependent float
values, ineffective token limits, ambiguous raw-string output, inherited child mappings, missing
closing events after recovery, and stale nodes after null-list writes. Then address quadratic typed
list traversal and the unnecessary decimal big-integer conversion. Follow AGENTS.md for all source
changes and verify Debug and Release on Linux and Windows.

## Confirmed correctness findings

P1 means a native lifetime error or silent output corruption that should be fixed first. P2 means an
incorrect result or contract violation under the stated input or configuration. These are review
priorities, not a claim that every caller exercises the affected paths.

| ID | Priority | Finding | Primary location |
|---|---|---|---|
| R1 | P1 | Collected serializer errors escape destroyed storage | `KdlSerializer.bf`, Read/ReadFile |
| R2 | P1 | PreserveStyle moves merge adjacent node names | `KdlDocument.Style.bf`, WriteNodeEnd |
| R3 | P1 | Stream recovery invalidates a pending error's text | `KdlReader.bf`, NextEvent; `KdlCursor.bf`, TryGetInputError |
| R4 | P2 | Float fallback uses the current decimal separator | `KdlReader.Values.bf`, ParseNumber |
| R5 | P2 | MaxTokenBytes depends on buffer capacity | `KdlCursor.bf`, Fill |
| R6 | P2 | Changed raw strings can become invalid KDL | `KdlDocument.Style.bf`, AppendRaw |
| R7 | P2 | Inherited child fields conflict with KdlChildren | `KdlSerializerCodeGen.bf`, Emit |
| R8 | P2 | EOF recovery omits matching EndNode events | `KdlReader.bf`, EndNode |
| R9 | P2 | Null object-list writes retain old child nodes | `KdlSerializerCodeGen.bf`, EmitWriteObjects |

### R1: collected errors escape a destroyed document

Locations: [KdlSerializer.bf:24](../src/KdlBeef/KdlSerializer.bf#L24),
[KdlDocument.bf:329](../src/KdlBeef/KdlDocument.bf#L329).

With `CollectErrors=true`, the document copies error messages into its arena and makes each error's
source view the document's source-name String. `Read` returns the first such error. The one-call
serializer propagates it with `Try!`, then destroys its scoped document before the caller receives
the result. Both message and source are dangling views.

Reproduction: call `KdlSerializer.Read("bad =;\n", target, config)` with `CollectErrors=true` and
`SourceName="review.kdl"`. Create another document and allocate text after the call returns, then
format the returned error. Both Debug and Release produced corrupted message and source text.

The struct Read overload and ReadFile use the same ownership pattern. Materialize a returned parse
error into storage that survives the scoped document, including its source name. A regression should
check the error after unrelated allocation, without depending on a particular allocator's poison
bytes or requiring corruption to occur in every run.

### R2: moving a node can silently merge it with its next sibling

Locations: [KdlDocument.Style.bf:285](../src/KdlBeef/KdlDocument.Style.bf#L285),
[KdlNode.Mutation.bf:85](../src/KdlBeef/KdlNode.Mutation.bf#L85).

Moves mark a node's leading text dirty, but WriteNodeEnd always reuses its captured tail. An empty
tail was valid for the final node before EOF or a parent's closing brace; it may be invalid before a
sibling in the new location. The following sibling's leading text may also be empty.

Reproduction:

```beef
let doc = scope KdlDocument();
doc.ReadConfig.MetadataMode = .PreserveStyle;
doc.Read("a\nb").IgnoreError();
doc.Nodes.Last.MoveBefore(doc.Nodes.First);
let output = doc.Write(.. scope .()); // "ba\n", one node instead of two
```

Moving `b` before `a` in `p{a;b}` produces `p{\n    ba;}`, also merging two children into one.
Both outputs parse successfully, so checking only that edited output parses will miss this bug.

Validate or regenerate separators at changed structural boundaries. Re-read the output and compare
names, hierarchy and values with the edited document. Cover compact child blocks, EOF without a
newline, moves in both directions, and comments at boundaries.

### R3: stream recovery corrupts the error it is about to return

Locations: [KdlReader.bf:350](../src/KdlBeef/KdlReader.bf#L350),
[KdlReader.bf:1120](../src/KdlBeef/KdlReader.bf#L1120),
[KdlCursor.bf:325](../src/KdlBeef/KdlCursor.bf#L325).

NextEvent calls AfterError/Recover before returning the syntax error. Recovery can refill a stream
and encounter an input failure. TryGetInputError constructs a new KdlParseError even when its output
is discarded with `?`; construction overwrites or reallocates the shared thread-local message
buffer. The pending syntax error still views its previous storage.

Reproduction: use CollectErrors and a 16-byte stream buffer with the bytes
`"n =bad /*" + 100 ASCII x characters + "*/\n" + NUL`. After StartNode, the returned UnexpectedChar
error at offset 2 has corrupted message text. Later calls report the disallowed NUL at offset 112.
This occurred in Debug and Release.

Separate querying whether an input error exists from materializing that error. Preserve the pending
error across recovery and define how a fatal input failure encountered during recovery is reported.
Test syntax errors followed by encoding, I/O and resource-limit failures across refills.

### R4: float values depend on the current decimal separator

Location: [KdlReader.Values.bf:214](../src/KdlBeef/KdlReader.Values.bf#L214).

The numeric fast paths use KDL's decimal point directly. The fallback calls `double.Parse(digits)`
using the current NumberFormatInfo. A conversion failure is then treated as overflow or underflow.

With a comma decimal separator, both Debug and Release produced:

| KDL token | Observed double | Expected double |
|---|---:|---:|
| `1.5` | 1.5 | 1.5 |
| `1.5_0` | Infinity | 1.5 |
| `1.234567890123456789` | Infinity | Approximately 1.2345678901234567 |

The probe installed a scope NumberFormatInfo with `NumberDecimalSeparator=","` in
`CultureInfo.CurrentCulture.mNumInfo`, restoring the original afterward. This forces the same
decimal-separator behavior that the fallback obtains from current culture settings.

Use explicitly invariant numeric parsing. A generic conversion failure should not silently become
an infinity or zero. Test equivalent fast-path and fallback forms under a non-dot decimal separator,
restoring all global or thread-local settings after the test.

### R5: MaxTokenBytes is not a hard construct limit

Location: [KdlCursor.bf:245](../src/KdlBeef/KdlCursor.bf#L245).

Fill checks MaxTokenBytes only when a completely full buffer must grow. A construct that fits the
initial buffer bypasses the check, and doubling can grow beyond the configured limit.

Reproduced in Debug and Release:

| Input | StreamBufferBytes | MaxTokenBytes | Observed |
|---|---:|---:|---|
| `n "` + 200 x characters + `"\n` | 1024 | 32 | Accepted |
| Same input | 16 | 32 | Resource-limit error |
| `n "` + 40 x characters + `"\n` | 16 | 33 | Accepted after growth to 64 |

Enforce the retained construct length independently of allocation capacity and clamp buffer growth.
Define the treatment of scanner lookahead explicitly. Test initial buffers larger than the limit,
non-power-of-two limits, exact boundaries, and buffer/stream chunk sizes that differ.

See also the idle-whitespace retention issue under performance: fixing the cap alone will not fix
the reader retaining bytes that it could already discard.

### R6: changed raw strings can produce ambiguous opening quotes

Location: [KdlDocument.Style.bf:367](../src/KdlBeef/KdlDocument.Style.bf#L367).

AppendRaw chooses enough hashes to avoid a closing delimiter within the body, but does not check
whether its output begins with a raw multiline opener.

Reproduction: read `n p=#"old"#\n` with PreserveStyle, then set `p` to `.String("\"")`. Writing
produces `n p=#"""#\n`, which fails to parse because the opening triple quotes require a newline.
A replacement beginning with two quotes, such as `""abc`, similarly produces invalid output.
Both cases were reproduced in Debug and Release.

Fall back to escaped quoted output when raw output would begin with ambiguous triple quotes.
Changing the number of hashes alone does not resolve opening-quote ambiguity. Test empty strings,
one quote, two leading quotes, three leading quotes, and quote/hash runs; verify decoded values after
re-reading the output.

### R7: inherited child fields conflict with KdlChildren

Locations: [KdlSerializerCodeGen.bf:89](../src/KdlBeef/KdlSerializerCodeGen.bf#L89),
[KdlSerializerCodeGen.bf:250](../src/KdlBeef/KdlSerializerCodeGen.bf#L250).

The claimed-name list includes only fields whose DeclaringType is the type being generated. The
base reader is called first and processes inherited fields, but the derived KdlChildren reader
subsequently treats those same child nodes as unclaimed.

Reproduction: a KdlObject base with `[KdlChild] public int version`, and a KdlObject derived type
with `[KdlChildren] public List<Item> items`, where Item's node name is `item`. Reading this document
through the derived type's KdlRead on Root fails:

```kdl
version 7
item count=3
```

The base reader sets version to 7, then the derived reader reports
`version: unknown node: expected one of item`. Debug and Release agree.

Build the mapping across the inheritance chain, accounting for each declaring type's naming policy
and aliases. Audit inherited argument roles at the same time: the first free argument is also
calculated from local fields only. The inherited-argument concern is a code observation, not a
separately reproduced finding.

### R8: EOF recovery omits matching EndNode events

Location: [KdlReader.bf:751](../src/KdlBeef/KdlReader.bf#L751).

With CollectErrors, `a /-{` reports StartNode, an UnbalancedBraces error, then EndOfDocument without
an EndNode. `a { b /-{` reports two StartNodes but no EndNodes. Both configurations reproduced this.

When closing frames at EOF, EndNode handles a slashdashed node but does not remove suppression from
that frame's unclosed slashdashed children block. Required closing events for the node and its
ancestors are therefore suppressed.

Restore suppression consistently when a frame is closed during recovery. Test the event sequence and
balance explicitly, including real blocks, slashdashed blocks, nested combinations, and EOF at
different depths.

### R9: null object-list writes retain old child nodes

Locations: [KdlSerializerCodeGen.bf:750](../src/KdlBeef/KdlSerializerCodeGen.bf#L750),
[KdlSerializerCodeGen.bf:921](../src/KdlBeef/KdlSerializerCodeGen.bf#L921).

EmitWriteObjects generates work only when the List field is non-null. After reading
`item count=3\n` into a List<Item> field, delete the list and its owned items, set the field to null,
and call KdlWrite on the same document. The old item remains. This was reproduced in Debug and
Release. EmitWriteChildren has the same missing null branch by inspection.

This differs from String, scalar-list and dictionary writers, which remove their mapped content
when null. Define consistent null-versus-empty semantics and add the corresponding removal branch.
Test null, empty, populated and shortened lists while preserving unrelated children.

## Performance and resource-budget findings

### Typed list traversal is quadratic

Locations: [KdlSerializerCodeGen.bf:683](../src/KdlBeef/KdlSerializerCodeGen.bf#L683),
[KdlBind.bf:252](../src/KdlBeef/KdlBind.bf#L252),
[KdlBind.bf:510](../src/KdlBeef/KdlBind.bf#L510).

Scalar-list reads call ArgumentCount in each loop condition, which scans the entries, and then
ArgumentAt searches again from the beginning for argument i. Repeated object writes likewise restart
the sibling scan through NthChild; KdlChildren writes do so through FreeChild.

A simple Release probe binding one scalar list measured approximately:

| Argument count | Elapsed time |
|---:|---:|
| 1,000 | 1 ms |
| 4,000 | 17 ms |
| 16,000 | 256 ms |

These are diagnostic timings, not a replacement for the repository's warmed-up benchmark protocol.
The approximately sixteenfold cost for fourfold input growth supports the quadratic code analysis.
Traverse entries or siblings once and carry the current position. Caching ArgumentCount removes
one repeated scan but does not fix repeated ArgumentAt lookup.

### Decimal big integers are converted to binary and back unnecessarily

Location: [KdlCanonical.bf:322](../src/KdlBeef/KdlCanonical.bf#L322).

AppendIntegerLexeme builds binary limbs one digit at a time and repeatedly divides them into decimal
chunks, even when the original lexeme is already decimal. Both stages have quadratic behavior.

Release CLI formatting of a node with one decimal integer took roughly 6 ms for 10,000 digits,
76 ms for 40,000 digits, and 1.33 seconds for 160,000 digits. These timings include process startup,
parsing and formatting; they are diagnostic, not formal throughput measurements.

Normalize decimal lexemes directly: remove underscores, the leading plus and redundant leading
zeros, while keeping the required sign behavior. Keep radix conversion for non-decimal lexemes.

### Idle ASCII whitespace is retained across refills

Location: [KdlReader.bf:1065](../src/KdlBeef/KdlReader.bf#L1065).

SkipLineSpace advances local p but leaves mPos at the beginning of the ASCII run. Grow chooses its
retain point using mPos, so refills retain the entire whitespace run and grow the buffer.

A thousand leading spaces followed by `n\n`, with a 16-byte stream buffer and MaxTokenBytes=32,
fail at the token limit despite containing no long node head or entry. Debug and Release agree.
The ASCII SkipNodeSpace loop has the same retention pattern by inspection.

Advance the discard position at refill boundaries while keeping the local-position hot loop.
PreserveStyle intentionally retains source slices; distinguish its required retention from plain
reader whitespace that can be discarded.

### String and file limits are checked after substantial allocation

Locations: [KdlReader.Values.bf:14](../src/KdlBeef/KdlReader.Values.bf#L14),
[KdlDocument.bf:297](../src/KdlBeef/KdlDocument.bf#L297).

MaxStringBytes is checked after the string has been scanned and decoded. The non-streaming ReadFile
path loads the entire file before MaxInputBytes is enforced. These limits reject oversized input,
but do not currently constitute strict allocation budgets. Consider checks during decoding and a
bounded file-read path when an input budget is configured.

### Other optimization candidates

The planned property hash index should follow a representative lookup benchmark. The quadratic
typed-list paths have stronger evidence and should take precedence. Long comments still use
byte-at-a-time scans; word scanning is another candidate if profiling shows those loops matter.
Retain the measured in-memory cursor specialization and small internal KdlFailure results when
refactoring: they are documented performance decisions.

## Readability and architecture

- **Reader invariants:** ReadNext combines normal parsing, slashdash suppression, recovery and
  source capture. Replace numeric Frame.mPhase values with a named enum and state invariants for
  event balance, retained offsets and view lifetimes. Refactor around those responsibilities while
  measuring any effect on the specialized hot paths.
- **Serializer generation:** Emit mixes field discovery, role selection, inheritance, ownership
  and source emission. An intermediate field descriptor would allow validation before emission and
  make these interactions easier to review. Reject negative or duplicate argument indices,
  overlapping mappings and incompatible role attributes at compile time.
- **View invalidation:** KdlNode checks generations, but KdlNodeList, KdlNamedNodes,
  KdlDescendants and KdlEntryList do not. A saved Children view returned nodes from a later Read;
  a saved entry list likewise returned the new entries. These are architectural consistency
  concerns: KdlEntry itself already documents a limited lifetime. Propagate generation checks or
  explicitly document invalidation rules for all selections and enumerators.
- **Long-lived mutation:** Arena ownership retains replaced text, and relocated entry ranges leave
  holes until Clear. Clear intentionally retains arena pools for reuse. Consider an explicit
  compact/trim operation for editing workloads rather than removing the useful pool-recycling design.
- **Documentation:** KdlReader configuration comments say MetadataMode is ignored, although
  PreserveStyle enables source capture and changes retention. Clarify the public contract.

## Potential API additions

These are recommendations, not missing KDL grammar requirements:

- Change or remove an entry's annotation independently of its value, including argument annotations.
- Optionally reject unknown properties and extra arguments during typed binding to catch markup typos.
- Expose slashdashed content as editable structure if uncommenting is an intended editor operation;
  currently it is preserved as raw trivia rather than navigable nodes or entries.
- Add direct unsigned numeric accessors where callers currently need serializer helpers.

V1 input, KQL and the streaming writer were deliberately dropped in [plan.md](plan.md). Do not treat
them as regressions or automatically restore them as part of these fixes. Existing status items for
numeric grouping, subtree re-indentation and nested collection mapping remain separate work.

## Verification and regression coverage

The following passed during the review, before any implementation fixes:

| Check | Result |
|---|---|
| Linux `beefbuild -test` | 56/56 |
| Linux `beefbuild -test -config=TestRelease` | 56/56 |
| Windows `beefbuild-win -test` | 56/56 |
| Windows `beefbuild-win -test -config=TestRelease` | 56/56 |
| Debug and Release `test-kdl-spec.sh` | In each of document, events, stream and collect modes: 243 valid cases match; 95 invalid cases match golden errors |
| Debug and Release `test-roundtrip.sh` | 245/245 in memory and 245/245 through streams |
| `test-leaks.sh` | No leaks detected |

Both KdlTester binaries were rebuilt before the acceptance scripts. The Windows runner required
execution outside the sandbox; both configurations then passed. Review probes were built separately
in Debug and Release. Implementation files and pinned external references were not changed.

The missing coverage is chiefly combinations and transformations: CollectErrors through a stream,
returned errors after scoped owners die, compact-node moves, changed raw-string values, inherited
typed roles, null-list writes, non-dot number formats and token budgets independent of buffer size.
Unchanged byte-exact round trips do not establish that edits preserve semantics, and leak detection
does not establish that returned views remain live.

For source fixes, run all checks required by AGENTS.md and update status.md if counts change. For
performance fixes, add representative measurements following the existing benchmark protocol.

## Temporary reproduction harnesses

The self-contained descriptions above are the durable evidence. The original scratch workspaces
may still be available locally; /tmp is not a permanent project dependency:

| Workspace | Probes |
|---|---|
| `/tmp/kdl-review` | R2, R5, R6, idle whitespace, saved views |
| `/tmp/kdl-review2` | R1 (`lifetime` argument), R3, R7, R9, scalar-list timing |
| `/tmp/kdl-review4` | R4 decimal separator |
| `/tmp/kdl-review5` | R8 event balance |

Run `beefbuild -run` or `beefbuild -config=Release -run` from a scratch workspace. For R1, run its
built Probe binary with `lifetime`. The R8 harness continues requesting EndOfDocument after the first
one; the relevant evidence is the number of StartNode and EndNode events before that point.

## Resolution

Fixed on 2026-09-30. Every finding has a behavioral regression test in
`src/KdlBeef/tests/KdlReviewTests.bf`; with each of R1-R6 and R8's fixes disabled, its test fails
with the reproduced symptom (checked once, then restored). All checks in AGENTS.md pass: 69/69
tests in Debug and TestRelease on Linux and Windows, the suite in all four modes and the round trip
with both binaries, no leaks. Read throughput is unchanged (document read 255 MB/s on `ui`, 226 on
`html-standard`; event pass 319 and 303). The `/tmp/kdl-review2` probe now prints the correct result
for R1, R3, R7 and R9.

| ID | Fix | Test |
|---|---|---|
| R1 | `KdlParseError.Detach` copies an error's message and source into the per-thread buffers; `KdlSerializer.Read`/`ReadFile` detach before their scoped document goes. `KdlDocument.Read` documents that collected errors' text belongs to the document | `R1_*` (after unrelated allocation) |
| R2 | The preserving writer notes a kept tail without a terminator (`EndsWithTerminator`: a final `;` or newline that does not end a line continuation) and writes a newline before the next node | `R2_MovesKeepNodesApart`: compact blocks, EOF without newline, both directions, comments, `}`-adjacent spaces, line continuation, NEL/CRLF, moves between blocks; output re-read and compared with the edited document's canonical form |
| R3 | `IKdlCursor.HasInputError` asks without making an error; `Grow` and `FailAt` use it, so recovery keeps the pending error's text; the input's failure is reported on a later call | `R3_RecoveryKeepsThePendingError`: disallowed code point (4 chunk sizes), invalid UTF-8, MaxInputBytes, I/O failure |
| R4 | Float fallback parses with KdlBeef's own `NumberFormatInfo` (`KdlChar.sNumberFormat`); out of range stays ±infinity/0 (the runtime's fast_float reports that as success), any other failure is an InvalidNumber error | `R4_FloatsIgnoreTheCulturesDecimalSeparator`, with a comma separator installed and restored |
| R5 | The stream buffer starts at most `MaxTokenBytes` and never grows past it; `Fill` rejects `pos + count - keep > MaxTokenBytes` whatever the capacity. Lookahead is counted (documented on `MaxTokenBytes`) | `R5_TokenLimitIndependentOfTheBuffer`: the review's table, and one threshold across 5 buffer and 3 chunk sizes |
| R6 | `CanWriteRaw` refuses values starting with `""` or equal to `"`; they are written quoted | `R6_ChangedRawStringsStayValid`: 10 values, re-read and compared |
| R7 | Claimed names and the first free argument are computed over the `[KdlObject]` chain with each level's naming; classes get a virtual `KdlClaimedChildNames`, so a base's `[KdlChildren]` also skips a subclass's child fields; a second `[KdlChildren]` in a chain is a build error | `R7_InheritedMappings`: both directions, inherited `[KdlArgument(0)]` + `[KdlArguments]`, read and write |
| R8 | `EndNode` releases the suppression of a frame's still-open slashdashed children block | `R8_EndOfInputClosesEveryNode`: 9 inputs, memory and stream |
| R9 | Null lists remove what they map (object items, `[KdlChildren]` items, `[KdlArguments]`); empty lists the same | `R9_*`: null, empty, shorter and repopulated lists, unrelated children kept |

Performance:

- **Typed lists** are read and written in one pass: `KdlArgumentRefs` for reading, and the cursors
  `KdlArgumentCursor`, `KdlChildCursor` and `KdlFreeChildCursor` for writing (they replace
  `ArgumentAt`, `NthChild`, `TrimArguments`, `TrimChildren`, `FreeChild` and `TrimFreeChildren`).
  Release timings, median of 5 after a warm-up, reads including the parse:

  | Items | Scalar list read / write | Object list read / write | `[KdlChildren]` read / write |
  |---:|---|---|---|
  | 4,000 | 0.24 / 0.08 ms | 0.61 / 0.10 ms | 0.61 / 0.11 ms |
  | 16,000 | 0.80 / 0.26 ms | 2.45 / 0.40 ms | 2.47 / 0.44 ms |
  | 64,000 | 3.19 / 1.00 ms | 9.90 / 1.61 ms | 10.09 / 1.78 ms |

  The review's probe binds 16,000 scalar arguments in under 1 ms (was 256 ms).
- **Decimal big integers** are normalized directly. Release CLI (best of 5, process included):
  10,000 digits 0.8 ms, 40,000 1.2 ms, 160,000 2.1 ms (was 1.33 s), 640,000 5.8 ms.
- **Idle whitespace** (from the performance findings): the whitespace loops store their position
  at the window's end, so a refill drops the run; a thousand leading spaces now read through a
  16-byte buffer with `MaxTokenBytes=32`. A drop never splits a CRLF.

Also fixed: `KdlReader`'s configuration comments now say what MetadataMode does.

Follow-ups done after that:

- **Dictionary writes** index the entry nodes by key once (`KdlKeyIndex`): 4,000 / 16,000 / 64,000
  keys write in 0.35 / 1.82 / 7.48 ms (test `Dictionaries_LargeWritesAndNulls`).
- **Mapping checks** at compile time: negative or repeated argument indices, a second
  `[KdlArguments]` or `[KdlChildren]` in a chain, several role attributes on one field, and two
  properties or two child nodes with one name all stop the build, naming both fields (each checked
  with a throwaway type; `FineSameName` guards against a false positive).
- **Saved views** (`Children`, `Nodes`, `Entries`, `Named`, `Descendants`, their enumerators) carry
  the document's generation and their node: `IsValid` tells, and using a stale one is a fatal error,
  as for a handle (test in `Handles_InvalidAfterReadOrClear`).

- **Budgets.** `MaxStringBytes` is checked as a string's value is decoded (quoted escapes,
  multi-line dedent), failing at the string's start as soon as it passes the limit; non-streaming
  `ReadFile` checks the file's size against `MaxInputBytes` before reading and stops at the limit if
  the file grows (tests `Budgets_*`).
- **Reader readability.** `Frame.mPhase` is a named `Phase` enum, and `KdlReaderCore` states its
  invariants (event balance and suppression, retention, view and error-buffer lifetimes).
- **Serializer descriptor.** `Emit` is three steps: `ScanChain`, a `FieldPlan` per field from
  `PlanField` (all validation), then emission from the plans. The generated code is unchanged (the
  typed benchmark's checksums and the tests agree).

Throughput after all of these: document read 254 MB/s on `ui` and 230 on `html-standard`, event pass
313-319 and 307, typed read 38.9 ms and write 23.2 ms, the same as before within noise.

Not done, recorded in `status.md`: splitting `ReadNext` along its responsibilities (its invariants
are stated, the code is not restructured); the API additions.

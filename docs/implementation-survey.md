# Survey of existing KDL implementations

What ten KDL v2 implementations do, how, and what to take or avoid. Read from the pinned clones under
`bench/compare/deps/` (see `bench/compare/fetch.sh`), 2026-09-29. File references are relative to
each clone. Benchmark results are in `bench/compare/results.md`; the plan built on this is
`docs/plan.md`.

## At a glance

| | architecture | API | property storage | numbers | format kept | errors | typed mapping | KQL | v1 |
|---|---|---|---|---|---|---|---|---|---|
| **kdl-rs** (Rust, official, 6.7.1) | winnow combinators, no lexer | DOM | one ordered `entries` list, dups kept, lookup = last | i128 / f64 | **yes**: trivia strings per level + `value_repr` | **multiple, with recovery**, spans, miette | serde (heuristic, `#args` hacks) | disabled | old crate + fallback |
| **ckdl** (C) + kdlpp (C++) + Python | tokenizer (emits trivia) + flag state machine | **pull events**; streaming emitter; kdlpp DOM | events in order; kdlpp `std::map` (sorted, deduped) | i64 / f64 / **decimal string** fallback | comments as events only | message only, **no position** | no | no | per-token autodetect |
| **kdl4j** (Java) | UTF-8 byte reader + lexer (ring buffer) + recursive descent | immutable DOM + builders | args and props split; props LinkedHashMap of lists | BigInteger / BigDecimal | no | one, rich context; **golden `.error` tests** | no | no | separate parser (+ buggy hybrid) |
| **@bgotink/kdl** (JS) | generator tokenizer, 256-entry first-char table, LL(1) | mutable DOM, fragment parsing | one ordered list, dups kept, lookup = last | JS double (lossy) | **yes**: trivia + typed whitespace, slashdash as parsed objects; opt-in location sidecar | **recoverable vs fatal**, all reported | "dessert" combinators, JSON-in-KDL | **yes** | parse v1, transform to v2 keeping format |
| **KdlSharp** (C#) | lexer (skips trivia) + recursive descent | DOM + token reader + streaming writer | args and props split, dups kept | System.Decimal (clamps!) | opt-in number/string kinds | first only, line:col | **reflection, attributes, converters, naming, polymorphism** | **yes** | Auto (catch and retry) |
| **gokdl2** (Go) | lexer + table-driven push state machine | DOM | order slice + map, dup overwrites in place | int64/float64/big.* boxed | radix/string-kind flags, node comments opt-in | string with line/col + excerpt | struct tags (`arg`, `props`, `children`, `multiple`, …) | no | yes (**writer defaults to v1**) |
| **kdly** (Go) | scanner + layout-state machine, 4 KB refill | **lossless CST** | all entries kept; map on demand | **raw literal** + accessors | **full** (every trivia byte) | string span + hints | reflection (WIP) | no | no |
| **kdljs** (JS, official) | Chevrotain regex lexer + LL(k) | plain objects | JS object (reorders int-like keys, `__proto__`) | JS double (lossy) | no | error objects with positions | no | yes | no |
| **kdlpy** (Python) | scannerless combinators | dataclasses | ordered list, dup replaced in place | typed Decimal(m,e)/Hex… or natives | radix/exponent (non-native mode) | first, "line:col" | tag/name converters | no | no |
| **zig-kdl** (Zig) | sentinel tokenizer + labelled-switch state machine | pull events + NodeIterator | unordered hash, **raw unresolved keys** | raw literal + comptime parse | no | `.invalid` only | comptime scalar coercion | no | no |

## Notes per implementation

**kdl-rs** (`src/v2_parser.rs`, `document.rs`, `node.rs`, `entry.rs`, `fmt.rs`, `de.rs`, `se.rs`)
- Model: `KdlDocument { nodes, format, span }`, `KdlNode { ty, name, entries, children, format, span }`,
  `KdlEntry { ty, value, name: Option, format, span }` — properties are named entries in the one list.
- Format structs are the right *set of slots* (node: leading, before/after type and name,
  before_children, before_terminator, terminator, trailing; entry: value_repr, leading, trailing,
  after_ty, after_key, after_eq). Slashdashed items are kept as raw text in neighbouring trivia.
- **Bug to avoid:** `KdlEntry::set_value` keeps the old `value_repr` (entry.rs:79-81), and Display
  prefers it, so a changed value prints its old text.
- Recovery: `resume_after_cut` skips a bad value to a terminator and inserts placeholder nodes
  (v2_parser.rs:204-254, 344-371): all errors in one pass. Good messages with help text.
- Spec tests: autoformat without comments, exact compare with `expected_kdl` (tests/compliance.rs).
- Cost: every trivia fragment is an owned String; linear lookups; combinator overhead (and the
  benchmarks show it: 2–3 MB/s).

**ckdl** (`src/tokenizer.c`, `src/parser.c`, `include/kdl/*.h`, `bindings/cpp`)
- Cleanest layering: tokenizer (also emits whitespace, newline, comment, slashdash, escline tokens) →
  flag-bitmask state machine → pull events (`kdl_parser_next_event`: START_NODE, END_NODE, ARGUMENT,
  PROPERTY, COMMENT, PARSE_ERROR) → streaming emitter with detailed options (indent, escape modes,
  identifier mode, float format, version).
- Zero-copy tokens, one reusable event struct, no per-node allocation in the C core; string views
  valid until the next event. Stream mode refills with memmove (unbounded growth).
- Numbers: long long / double / STRING_ENCODED for everything else (minimal bigint for overflow).
- Weakest errors of all: a static message, no position.
- v1/v2 autodetected per token (ambiguous strings unescaped both ways until a construct locks it).

**kdl4j** (`parse/lexer/*`, `Kdl2Parser.java`, `KdlProperties.java`, `KdlNumber.java`)
- Arbitrary precision (BigInteger/BigDecimal). One error, but a rich `ParseContext` (source lines,
  span) rendered miette-style, and **83 golden `*.kdl.error` snapshot tests** — worth copying.
- Printer options: version, indentation, newline, exponent char, empty children, null args/props,
  duplicate properties, property order, semicolons, always-quote.
- Bugs: the v2→v1 hybrid reuses a half-consumed stream (KdlHybridParser.java:19-22); Reporter swaps
  the v1/v2 labels (Reporter.java:47-48).

**@bgotink/kdl** (`src/parser/tokenize/tokenize.js`, `src/model/*`, `documentation/src/internals/*`)
- Fast JS design: lazy generator tokenizer, 256-entry first-character dispatch, numeric token types,
  no regex in the hot path; LL(1) grammar rewrite so property-vs-argument needs no lookahead.
- Best preservation model: trivia on each object plus a typed whitespace model in which a slashdash
  holds the *parsed* commented-out Entry/Node/Document. `Value.setValue` clears `representation`
  when the value changes (value.js:88-93) — the fix for kdl-rs's bug. `clearFormat()` gives canonical.
- Locations are an opt-in sidecar (`WeakMap`, `storeLocations: true`) — the TomlBeef Positions idea.
- Errors: recoverable ones are collected and all reported; fatal ones stop.
- Spec tests: asserts **byte-exact round-trip of every valid input** and `parseAndFormat ==
  expected_kdl`, with a known-broken list asserted to still fail.
- Extras: KQL, JSON-in-KDL, v1 → v2 transform keeping formatting, parse fragments (`{as: "node"}`).

**KdlSharp** (`Parsing/*`, `Serialization/*`, `Query/*`, `Schema/*`)
- Most features: KQL, schema validation, reflection serializer (`[KdlNode]`,
  `[KdlProperty(Name, Position, IsProperty)]`, `[KdlIgnore]`, converters, naming policies,
  polymorphism, cycle detection), streaming `KdlWriter` (Utf8JsonWriter-style).
- "Streaming" parse APIs call ReadToEnd first. Numbers in System.Decimal; out-of-range exponents are
  **silently clamped** (Lexer.cs:1110-1133). Spec tests compare structurally, not by text.

**gokdl2** (fork of sblinch/kdl-go)
- Pooled node/value slabs sized `inputSize/25`, zero-copy bare identifiers, one-pass number
  classification — but boxed `interface{}` values and map-of-maps dispatch per token.
- Struct tags `kdl:"name,arg|args|props|children|child|multiple|omitempty,format:…"` — the
  `multiple` rule and child slices matter for UI trees.
- Pitfalls: writer defaults to **v1** output; Auto mode reads all and may parse twice; backtick
  "expression" strings always on (break valid v2 identifiers).

**kdly** (`scan.go`, `parse.go`, `node.go`, `string.go`, `number.go`, `format.go`, `compress.go`)
- A lossless CST: every node/entry/key/annotation/block/slashdash keeps leading and trailing byte
  runs; strings and numbers are the raw literal, resolved lazily; properties resolved last-wins on
  demand. Formatter (keeps comments, normalizes whitespace) and Compressor (canonical).
- One allocation per token (scan.go:79); structured errors were removed in the last commit.

**kdljs**: Chevrotain regex lexer; numbers as doubles (`parseInt` loses > 2^53); properties in a
plain object; module-level singletons (not re-entrant); formatter validates the whole tree first.

**kdlpy**: 334/338 on the latest suite (fails `braces_in_bare_id`, three
`zero_space_before_slashdash_*`). Default printing bugs: `#inf`/`#nan` printed bare, ints become
floats, `(f64)1.5` → `1`, raw strings printed in v1 syntax, multi-line strings printed empty.

**zig-kdl**: `std.zig.Tokenizer`-style sentinel scanning and a labelled-switch pull parser (good
shape), but slashdashed child blocks end at the first `}` (no depth), properties in a hash map keyed
by *unresolved* raw text, several allocations per string, and stale APIs hidden by lazy compilation.

## Patterns to adopt (merged ranking)

1. **One ordered entry list per node** (arguments and properties interleaved, duplicates kept,
   lookups last-wins), with an index built only for nodes with many properties — the TomlBeef
   `TomlEntryMap` shape. Nobody indexes; UI nodes carry 5–20 attributes and are looked up constantly.
2. **Tokenizer that emits trivia, pull-event core, DOM on top** (ckdl, zig-kdl, bgotink): a
   zero-allocation event cursor for large markup and a document builder over it. Switch dispatch on
   the first byte (bgotink's table) and TomlBeef's 8-byte `ScanRun` for string/comment bodies.
3. **Formatting in an opt-in sidecar** (TomlBeef PreserveStyle; bgotink's WeakMap; kdly's CST as the
   completeness target), with kdl-rs's slot set, stored as spans/arena text, slashdashed content
   kept as parsed structure. Plain parses pay nothing.
4. **Changing a value drops its original token** (bgotink), keeping the surrounding trivia.
5. **Numbers: i64 / f64 fast path plus the original lexeme** (ckdl's string fallback; kdly's raw
   literal), never a decimal type (KdlSharp clamps) or doubles only (bgotink, kdljs lose integers).
   Keep radix/string-kind flags for preservation (gokdl2).
6. **Located, structured, multi-error diagnostics with recovery** (kdl-rs, bgotink), line/column
   computed on demand from byte offsets, golden error tests (kdl4j).
7. **Two writers**: canonical (matches `expected_kdl`) and preserving; always v2; correct keywords.
8. **Compile-time typed mapping with explicit roles**: argument (by position), arguments (rest),
   property, child, children (multiple), with naming and converters — `[TomlObject]`'s generator,
   with KdlSharp's attributes and gokdl2's roles as the vocabulary.
9. **Arena ownership sized from the input** (gokdl2 slabs, TomlBeef store), parser reuse via Reset.
10. **Spec suite at two strengths**: byte-exact round-trip of every valid input, and canonical output
    == `expected_kdl`; a known-failures list asserted to still fail; never structural-only.
11. **Resource limits** (depth, nodes, entries, string/token bytes). Only KdlSharp has one.
12. **v1 as an explicit, separate front end** if at all (bgotink's transform is the model); no
    silent fallback, no re-parsing a consumed stream.

## Pitfalls seen

Sorted or hashed property storage (kdlpp, zig-kdl, kdljs); stale original text after a change
(kdl-rs); lossy numbers (bgotink, kdljs, kdlpy, KdlSharp); keyword and raw-string round-trip bugs
(kdlpy); non-spec syntax on by default (gokdl2); v1 as the writer default (gokdl2); slashdash skipped
by token counting (zig-kdl); `\n`-only line counting (kdlpy); several allocations per string or token
(zig-kdl, kdly); positionless errors (ckdl, zig-kdl); structural-only or gated spec tests (KdlSharp,
gokdl2, kdljs); stale docs hidden by lazy compilation (zig-kdl).

# KdlBeef Architecture

How KdlBeef works today and why. It is not a task list: open work is in [status.md](status.md), the
phases still to come in [plan.md](plan.md), the KDL rules in [spec-reference.md](spec-reference.md).
Code conventions and Beef gotchas are in `AGENTS.md`.

## 1. Overview

- A KDL 2.0.0 reader for Beef, built for UI markup. Today it is a **pull reader** (`KdlReader`) and
  a **canonical formatter** built on it (`KdlCanonical`); the document model, writers, positions,
  format preservation and typed mapping are later phases (`plan.md` §6).
- **Strict.** Invalid KDL is rejected with a located `KdlParseError` (line, column, byte offset,
  length). Slashdashed content is validated like everything else.
- **No per-node allocation.** The reader's events are views into the input, or into three reusable
  buffers when a string has escapes or is multi-line; they are valid until the next event.
- Linux64 first; Windows verified through the Proton-hosted Beef (`AGENTS.md`).

## 2. Source layout

| File (`src/KdlBeef/`) | Responsibility |
|---|---|
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
U+000E–001F, DEL, bidi controls, U+FEFF after position 0). Words of printable ASCII are skipped 8
bytes at a time. Doing it up front means no scanner below has to check for banned or malformed
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

## 4. Canonical form

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

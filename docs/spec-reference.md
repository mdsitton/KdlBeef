# KDL 2.0.0 implementer's reference

A checklist of the exact rules and the edge cases that trip implementations, compiled from the pinned
spec repository (`tests/kdl-spec`, kdl-org/kdl at 89c1087, fetched by `tests/fetch-spec.sh`).

`SPEC.md` there is a one-line redirect: the real v2 specification is `draft-marchan-kdl2.md`
(1110 lines; "L" references below point into it). Its front matter says it "describes an unreleased
minor change to KDL" (the 2.0.0 wording is commented out at L45-49), so read it as 2.0.0 plus errata.
**The grammar (L939-1074) is authoritative where the prose disagrees (L941-943).** The test suite is
explicitly "NOT AUTHORITATIVE" (tests/README L44-56): the spec wins.

## 1. Encoding, BOM, version marker

- UTF-8 only (L100). Reject invalid UTF-8, including encoded surrogates.
- `document := bom? version? nodes` (L946). U+FEFF is allowed **only as the first code point**;
  anywhere else it is a disallowed code point, and v2 does not treat it as whitespace (L936;
  CHANGELOG L57). Tests: `bom_initial` passes, `bom_later_fail` fails.
- Version marker (L68-70, grammar L1071-1073):
  `'/-' unicode-space* 'kdl-version' unicode-space+ ('1'|'2') unicode-space* newline`, only after the
  optional BOM. It is a slashdashed node, so ignoring it gives the same document; it MAY be used as a
  v1/v2 hint. No test covers it.

## 2. Document and node structure

- Nodes separated by newlines, `;` and whitespace (L96-98): `nodes := (line-space* node)* line-space*`.
- `base-node` (L951-957):
  ```
  base-node := slashdash? type? node-space* string
      (node-space* (node-space | slashdash) node-prop-or-arg)*
      (node-space* slashdash node-children)*
      (node-space* node-children)?
      (node-space* slashdash node-children)*
      node-space*
  node := base-node node-terminator
  final-node := base-node node-terminator?
  node-children := '{' nodes final-node? '}'
  node-terminator := single-line-comment | newline | ';' | eof
  ```
- Node names are any string: identifier, quoted or raw (L116-118). Whitespace is allowed between a
  type annotation and the name (`(type) node`).
- Every entry needs node-space before it; a slashdash can stand in for it: `node"string"`,
  `node "string"1`, `node foo="value"bar=5` fail; `node "string"/-1`, `node "string"/-foo=1`,
  `node "string" {}/-{}` pass.
- Terminators (L149-151): newline, `;`, the parent's `}`, EOF. The last node in `{}` needs none
  (`node{foo;bar;baz}` is legal, CHANGELOG L47-49). `};` and a trailing `;` at EOF are fine.
- After a children block only node-space and a terminator (or more slashdashed blocks) may follow:
  `foo123{bar}foo weeee` fails. `node {` (unclosed) fails.
- Arguments keep their order (L203-213); interleaved properties do not affect it.
- Properties (L181-201): `prop := string node-space* '=' node-space* value` (L966). Spaces (and even
  an escline) are allowed around `=`; only U+003D is an equals sign. **Duplicate keys: rightmost wins**
  (`a=1 a=2` → 2, L187-194); duplicates must be accepted. Property order is not semantic
  (L140-143, L196-198). An argument and a property may share a name.
- Keys may be any string form (`""=x`, `#"k"#=1`); keywords as keys (`true=1`, `null=1`) fail,
  `true_id=1` passes. Duplicate nodes and names are kept, in order.

## 3. Type annotations (L253-341)

- `type := '(' node-space* string node-space* ')'`, `value := type? node-space* (string|number|keyword)`
  (L967-968). Whitespace and `/* */` are allowed inside the parens and before the target:
  `( type)node`, `(type/*hey*/)10`, `(type)/*hey*/10` pass; `( f oo )` fails.
- The annotation may be quoted or raw (`("")node`, `("type/")node`).
- Fail: `()`, `( )`; a dangling annotation (`node (type)`, `(type)`, `node key=(type)`); an annotation
  on a property key (`node (type)key=10`). One annotation per value.
- Reserved (MAY recognize, L271-332): `i8`–`i128`, `u8`–`u128`, `isize`, `usize`, `f32`, `f64`,
  `decimal64`, `decimal128`, and string types such as `date-time`, `uuid`, `base64`, `base85`.
  Otherwise semantics are the application's (L264-266).

## 4. Slashdash `/-` (L882-901, grammar L951-958 and L1058)

- Exactly three targets (CHANGELOG L72-77): a whole node (before its type annotation), a whole entry
  (before its type annotation), a children block.
- `slashdash := '/-' line-space*`: it may be followed by whitespace, **newlines**, comments and
  esclines, but not another `/-` (L900-901).
  - `/-\nnode` comments out `node`; `node foo /-\nnot-a-node bar` is `node foo bar` (the newline after
    `/-` does not end the node); `node 1 /- // stuff\n2 3` is `node 1 3`; `node /--1.0 2.0` is
    `node 2.0`; `/- node1 /- 1.0` is fine (the second is inside the commented node).
- Fail: after or inside a type annotation (`(ty)/-node`, `node (ty)/-arg`, `(/-ty)node`); between key
  and `=` or before the value (`key /- = value`, `key = /-val`); dangling before `;`, `}` or EOF.
- Children blocks: a slashdashed block may not come before an entry (`node /-{…} foo {…}` fails); one
  real block at most, with any number of slashdashed blocks before or after it
  (`node foo /-{one} /-{two} {three} /-{four}` passes; `node { one } /- { two } { three }` fails).

## 5. Comments and line continuations

- `// … (newline|eof)` (L1054); `//` may be followed directly by a newline; it also terminates a node.
- `/* */` **nest** (L877-880, L1055-1057): `/*/* nested */*/`, `/* * */`; allowed anywhere whitespace
  is, including inside type parens.
- `escline := '\' ws* (single-line-comment | newline | eof)` (L163-179, L1062); `ws` includes `/* */`.
  `node \<EOF>` is legal; a lone `\` line is legal. `node-space := ws* escline ws* | ws+` (L1068):
  within a node a newline is only allowed through an escline, or right after a slashdash.

## 6. Whitespace, newlines, disallowed code points

- Whitespace (`unicode-space`, L849-868): U+0009, U+0020, U+00A0, U+1680, U+2000–U+200A, U+202F,
  U+205F, U+3000. Not U+FEFF, U+180E or zero-width spaces.
- Newlines (L908-920): CRLF (one newline), CR, LF, NEL U+0085, **VT U+000B** (new in v2), FF U+000C,
  LS U+2028, PS U+2029. All of them end `//` comments. `only_cr` is a document of just `\r`.
- Disallowed literal code points anywhere (L924-937): U+0000–0008, U+000E–001F, U+007F, surrogates,
  bidi controls U+200E–200F, U+202A–202E, U+2066–2069, U+FEFF except at position 0. C1 controls other
  than NEL are **not** banned. Quoted strings can still produce them through `\u{}`; raw strings
  cannot (L925-926, L728-731).

## 7. Identifier (bare) strings (L368-416, grammar L973-986)

- `identifier-char`: any scalar value except whitespace, newlines, `\ / ( ) { } ; [ ] " # =` and the
  disallowed code points. v2 **allows** `, < >` and **forbids** `#` (CHANGELOG L16, L31).
- Shapes: `unambiguous-ident` (first char not a digit, sign or `.`); `signed-ident :=
  sign ((idchar - digit - '.') idchar*)?` (`-`, `+`, `--`, `-foo`); `dotted-ident := sign? '.'
  ((idchar - digit) idchar*)?` (`.`, `+.`, `.md`).
- Anything that starts like a number but is not a valid number is an **error** (L379-387): `0n`,
  `+0n`, `.0n`, `.0`, `.1`, `1.0v2`, `-1em`, `1.`, `1.e7`, `1._7`, `1.0.0`, `0x`, `0xx10`,
  `0x10g10`, `0o45678`, `0bx01`, `0x_10`. `_15` and `?15` are identifiers.
- Exactly `true`, `false`, `null`, `inf`, `-inf`, `nan` are errors wherever an identifier would be
  (L382-386, L985-986); `false_id`, `-infinity` are fine.
- In v2, bare identifiers are valid argument and property **values** (strings, CHANGELOG L37).
- `r"foo"` / `r#"foo"#` fail (v1 raw strings; in v2 that is an identifier touching a string).

## 8. Quoted strings (L418-496, grammar L988-1007)

- No literal newline in a single-line body except inside a whitespace escape (L423-429).
- Escapes: `\n \r \t \\ \" \b \f \s` (U+0020), `\u{H…}`. **`\/` is invalid in v2**; any other `\x`
  is an error (L493-496).
- `\u{}`: 1–6 hex digits (`\u{0012345}` fails), not a surrogate, ≤ 10FFFF, never empty.
- Whitespace escape `'\' (unicode-space | newline)+` (L1000) deletes the `\` and all that whitespace:
  `"1\<nl><nl><nl>2"` is `"12"`.
- A literal disallowed code point is an error.

## 9. Multi-line strings `"""` (L498-710)

- The opening `"""` must be **immediately** followed by a newline (`"""foo"""` fails). The closing
  `"""` is on its own line, preceded only by literal `unicode-space` or ws-escapes (L992). A single `"`
  spanning lines (v1 style) fails. The body may contain `"`, `""` but not `"""`; `\"""` gives `"""`.
- Algorithm, in normative order (L675-680):
  1. Resolve **whitespace escapes first**.
  2. Split into lines on any newline type.
  3. The last line (whitespace only) is the prefix.
  4. Each line between the first and last newline: a line of only literal whitespace becomes empty;
     otherwise it must begin with **exactly the same code points** as the prefix, which is stripped.
  5. Drop the opening newline and the final newline plus prefix.
  6. Join with LF.
  7. **Then** resolve the other escapes.
- Consequences: `\s` does not count as prefix; an escaped newline that pulls the closing `"""` onto a
  content line is an error (L682-694); an escape on the closing line is fine. Literal newlines
  (including CRLF) become LF; escaped `\r\n` stays. `"""\n"""` and `"""\n\t"""` are `""`. Mismatched
  tab/space prefixes fail (L661-668).

## 10. Raw strings (L712-771, grammar L1010-1025)

- One or more `#`, then `"…"` or `"""…"""`, then the same number of `#`. No escapes at all.
- Non-greedy with a cut point (L1090-1097): the first `"` followed by N `#` ends the string.
  `##"foo"#` fails; `#"\"#` is `\`; `###""#"##"###` is `"#"##`; `#"#"#` is `#`; `#"a"b"#` is `a"b`.
- `#"""#` is **invalid** (a multi-line opener without a newline), as is `#"""one line"""#`.
- Raw multi-line strings dedent like `"""`; `##"""` bodies may contain `"""` and `"#`.

## 11. Numbers (L773-818, grammar L1027-1043)

- `decimal := sign? integer ('.' integer)? exponent?`, `integer := digit (digit|'_')*`,
  `exponent := [eE] sign? integer`, `hex := sign? '0x' hexdig (hexdig|'_')*`,
  `octal := sign? '0o' [0-7][0-7_]*`, `binary := sign? '0b' [01][01_]*`. Prefixes are lowercase.
- Underscores between or after digits, never first in a part: `1___2`, `12__`, `0b10_`, `1.0_2`,
  `1.0e-10_0` are fine; `0x_1a`, `1._7` fail; `_12` is an identifier. Leading zeros are fine
  (`011` is 11); a leading `+` is fine; digits are required on both sides of `.`.
- Keyword numbers: `#inf`, `#-inf`, `#nan` (L803-818). The only other keywords: `#true #false #null`.
- Range and precision are the implementation's (L775-777, L816-818), but the suite needs
  `0xabcdef1234567890` (> i64, fits u64), `0xABCDEF0123456789abcdef` (88 bits:
  207698809136909011942886895) and `1.23E+1000` / `1.23E-1000` round-tripping. Keep the decimal
  lexeme (or an arbitrary-precision value), not only an f64.
- A number must be followed by a delimiter (`0x10g10` fails).

## 12. The official test suite (`tests/kdl-spec/tests/test_cases`)

- 338 inputs: 243 valid cases, each with a same-named file in `expected_kdl/`, and 95 `*_fail.kdl`
  cases with no expected file. Many inputs lack a trailing newline.
- Use: parse each input; `_fail` must fail; otherwise print in the canonical form below and compare
  bytes with the expected file.
- Canonical form (tests/README L11-42, checked against the files):
  - Comments, esclines and blank lines removed. One line per node: `name args… props… {children}`.
    Arguments in order; properties **deduplicated (rightmost wins) and sorted alphabetically**; single
    spaces. 4-space indentation; `{` at line end, `}` on its own line; an empty or only-slashdashed
    block is omitted (`node {}` → `node`). Output ends with `\n`; an empty document is `"\n"`.
  - `a = b` → `a=b`; `( type )` → `(type)`.
  - Strings (names, keys, annotations, values) bare if a valid identifier, else quoted: `""`,
    `"10.0"`, `("type/")`. Raw strings become quoted. Escapes `\" \\ \b \f \n \r \t`; `\s` prints as a
    space; the expected files use no `\u` (a writer must still `\u{…}`-escape disallowed code points).
  - Numbers: hex/octal/binary → decimal; drop a leading `+`, underscores and leading zeros. Decimals
    **keep their written mantissa** (`1.0`, `-10.0`, `1.02`); the exponent is uppercase `E` with an
    explicit sign (`1e10` → `1E+10`, `1.0e-10_0` → `1.0E-100`). The README's "single digit left of
    the decimal point" rule is not actually applied.
  - Keywords print as `#true #false #null #inf #-inf #nan`.
- `tests/benchmarks/html-standard{,-compact}.kdl` (21 MB, 16 MB) are for profiling; `examples/*.kdl`
  are v2 samples.

## 13. v1 vs v2 (`SPEC_v1.md` grammar L486-544; CHANGELOG L5-78)

Any document parses in only one version or means the same in both (L59-66), so "try v2, fall back to
v1" is safe. v1 differences: bare `true`/`false`/`null`, no inf/nan; raw strings `r"…"`/`r#"…"#`;
quoted strings may hold literal newlines (no `"""`, no dedent); `\/` escape, no `\s` or whitespace
escape, `\u` allows surrogates; bare identifiers only as names and keys, not values; identifiers
forbid `\/(){}<>;[]=,"` and anything ≤ 0x20 but allow `#`; the BOM is whitespace anywhere; VT is not a
newline; no whitespace inside `()`, after an annotation or around `=`; `/-` must be followed by
node-space only; no bans on bidi or control characters; an escline may not end at EOF; the last node
before `}` on the same line needed `;`; `.1` was an identifier.

## 14. Companion specs (not required by KDL 2.0.0)

- `QUERY-SPEC.md` (KQL): CSS-selector-like queries (`>`, `>>`, `+`, `++`, `||`; `top()`, `(type)`,
  `[val(n)]`, `[prop(k)]`, `name()`, `tag()`; `= != > >= < <= ^= $= *=`). Unreleased ("KQL `next`",
  L8; CHANGELOG L82-84).
- `SCHEMA-SPEC.md`: a schema language in KDL; header still says 1.0.0 (2021); not maintained with 2.0.
- `JSON-IN-KDL.md` (JiK 4.0.0) and `XML-IN-KDL.md` (XiK 1.0.0): stable, optional microsyntaxes. XiK
  maps elements to nodes, attributes to properties, text to the final argument or `-` nodes, and is
  what the HTML-standard benchmark documents use.

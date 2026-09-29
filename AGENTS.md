# AGENTS.md

## Notes for coding agents

- This repository is a Beef language project: a KDL 2.0 parser and writer, the sibling of TomlBeef
  (`~/development/TomlBeef`, a TOML library by the same author). Much of its design and some of its
  code come from there; `docs/plan.md` lists what to port.
- Beef `String` stores UTF-8 data and is mutable. Prefer `StringView` for borrowed string inputs.
- Beef uses manual and scope-based memory management. There is no tracing garbage collector.
- This project currently targets Linux64 first; Windows is verified with the Proton-hosted Beef
  (`~/development/beef-proton/bin/beefbuild-win`), as in TomlBeef.
- Preferred CLI tool: `beefbuild` on Linux, `BeefBuild` on Windows. Use from `PATH`.
- `tests/kdl-spec/` (the official KDL spec and test suite, fetched by `tests/fetch-spec.sh`) and
  `bench/compare/deps/` (other implementations, fetched by `bench/compare/fetch.sh`) are external,
  pinned, git-ignored reference material; do not edit them.
- Start with `docs/plan.md` (the implementation plan and handoff), `docs/spec-reference.md` (the KDL
  2.0 rules and edge cases), `docs/implementation-survey.md` (what other implementations do) and
  `docs/status.md` (current state, verification baseline, open items). Keep `status.md` current:
  remove finished items and update the baseline when test counts change. Durable design notes go in
  `docs/architecture.md` once the implementation has a design worth recording; `docs/plan.md` is the
  starting plan and is updated as phases complete, not duplicated.

## Critical rules

- **Do not use scripts or bash commands to edit code.** Use the provided `edit` or `write` tools directly. Violating this will result in a work stoppage.
- **Always use `edit` for changes to existing files**, never `write` unless creating a new file or doing a complete rewrite.
- **When using `edit` with multiple changes** in the same file, merge nearby changes into a single edit call with multiple entries in the `edits` array.
- **Do not include large unchanged regions** in `edits[].oldText`. Keep it as small as possible while still being unique.
- **NEVER REVERT CODE USING GIT OR ANY VERSION CONTROL.** Do not use `git checkout`, `git revert`, `git reset`, or any similar command that discards or rolls back code changes. This destroys work and context. If you think a revert is needed, **end your turn and ask for explicit permission first.**
- **Never add `Co-Authored-By` or any other attribution trailer to commit messages.**
- **Use US English spellings** in code, comments and documentation (neighbor, color, behavior).
- **Verify Beef source/project changes.** After modifying `.bf`, `BeefProj.toml`, or workspace files, run the tests in **both** Debug and Release: `beefbuild -test` and `beefbuild -test -config=TestRelease`. Debug catches runtime-check and allocator issues; Release catches optimizer-dependent bugs. Also run `./test-kdl-spec.sh` and `./test-roundtrip.sh` against both binaries (`BIN=./build/Release_Linux64/KdlTester/KdlTester` for Release) and `./test-leaks.sh`; the Windows tests (`~/development/beef-proton/bin/beefbuild-win -test`, and `-config=TestRelease`) before committing; `beefbuild -test` does not rebuild `KdlTester`, so run `beefbuild` (and `beefbuild -config=Release`) first. Report results. For docs-only edits, no build is required. If verification cannot be run, say why.

## Beef Language Gotchas

These are non-obvious Beef behaviors discovered through debugging (in TomlBeef). Violating these will cause crashes, leaks, or silent failures.

### Memory & lifetime

- **`scope` works for class types** — `scope KdlDocument()`, `scope List<T>()` all work fine. The object lives for the enclosing scope.
- **`scope List<String>()` does NOT delete String elements.** The list's internal buffer is freed but contained `String`/class instances leak. Use `defer { ClearAndDeleteItems!(list); }` for scope-allocated lists of owned items.
- **Field initializers with `~ delete _` require an explicit constructor.** Beef's generated default constructor does NOT run field initializers when `~ delete _` is present. Always write `public this() { mField = new Type(); }` explicitly.
- **`~ delete _` is preferred** over manual `~this()` methods for field-level cleanup.
- **`DeleteContainerAndDisposeItems!`, `ClearAndDeleteItems!`, `DeleteDictionaryAndKeys!`** are built-in mixins for container cleanup. Use them instead of manual loops.
- **`defer` on a mixin requires a block wrapper**: `defer { ClearAndDeleteItems!(x); }` — NOT `defer ClearAndDeleteItems!(x);`
- **`defer` runs in LIFO order.** For `defer SomeCall(arg)`, `arg` and `this` are evaluated immediately; for `defer { ... }`, captured variables are read when the scope exits.
- **`delete` on value types (enums, structs) is a no-op.** Types without `~this()` (which structs can't have) need explicit `.Dispose()`.

### String formatting

- **`$"...{var}..."` interpolation** is for string literals (`scope $"key={key}"`). Variable names are captured from scope.
- **`AppendF("...{}...", arg)` / `AppendF("...{0}...", arg)`** use positional placeholders. Do NOT use `{variable}` syntax in `AppendF` — it compiles but crashes at runtime.
- **Do not mutate string literals.** `String s = "literal"; s.Append(...)` attempts to mutate read-only literal storage. Use `scope String()..Append(...)` or `scope $"..."`.
- **`StringView.Substring(pos)` and `Substring(pos, length)`** exist. Prefer them over raw `StringView(&ptr[offset], length)`.
- **`Console.WriteLine($"{x}")` allocates nothing**: `WriteLine(StringView fmt, params Object[])` exists, so the interpolation becomes a format call. A `$"..."` passed to a method without such an overload (`list.Add($"...")`) creates a heap String; use `scope $"..."` there.

### Switch & pattern matching

- **`switch` does NOT fall through in Beef.** Each case breaks automatically. `fallthrough;` needed to continue into the next case.
- **`switch` on `Result<T, E>`**: `case .Ok(let val):` and `case .Err(let e):`
- **`if (X case .Err(let e))`** is preferred over `switch` for simple error checks. But it does NOT bind the success value — for `.Ok(let val)` extraction, use `switch` or a temporary variable.
- **A variable declared inside a condition cannot be used after a `||` that might skip it.** `if (!TryGetArray(let a) || a.Count != 3)` is fine, but `if (!a.TryGetFloat(0, let x) || !a.TryGetFloat(1, let y)) return; use(x, y);` fails with "Conditional short-circuiting may skip variable initialization". Declare the variables first and pass them with `out`, split the checks into separate `if`s, or `switch` on a tuple of results.
- **There is no `case A or B` pattern.** Compare explicitly.
- **Enum switches without `default:` warn on non-exhaustiveness** — useful for catching new enum variants.

### Test framework

- **`[Test]` methods must be static.**
- **`beefbuild -test`** auto-discovers `[Test]` methods. No configuration needed.
- **Test assertions produce virtually no console output.** Debug test failures in a console app first, then port to `[Test]` once proven.
- **`[Test(ShouldFail=true)]`** marks an expected failure. If the test passes, the framework reports "Test should have failed but didn't" as an error.
- **A segfault in a test is never acceptable.** `ShouldFail` is for assertion failures, not crashes.

### File I/O

- **`File.ReadAllText` strips exactly one BOM** via StreamReader. Use `File.ReadAll` with `List<uint8>` for raw bytes when BOM-preservation matters (KDL allows a BOM only as the first code point).
- **`File.ReadAll` requires `using System.Collections;`** for `List<uint8>`.
- **`entry.GetFilePath(.. scope .())`** — the `.. scope .()` syntax creates a scope-allocated out parameter.

### Type system

- **`StringView` cannot be null.** Passing `null` where `StringView` is expected creates a default/empty StringView.
- **`char8` vs `int` comparisons** need explicit `(uint8)` casts when comparing with hex literals like `0xEF`.
- **Shadowed variable warnings (BF4200)** — reusing a name like `e` in nested `case .Err(let e)` produces warnings. Use unique names.
- **`out` and `var` are mutually exclusive in parameter position.** Write `out existingVar` for a pre-existing variable, or `var newVar` to declare inline. `out var x` does **not** compile.
- **Reserved identifiers include `box`.** Do not use `box` as a local/parameter/field name.
- **Prefer Beef primitive aliases** (`int32`, `uint8`, `float`, `bool`) over wrapper type names such as `System.Int32`.
- **Wrapping arithmetic** (hashes) uses `&*`, `&+`.

#### Special type references

- **`Self`**, **`SelfBase`**, **`SelfOuter`**, **`var`**, **`let`**, and the **`.` (dot type)** expected-type shorthand (`return .Err(...)`, `(.)floatVal`) work as in TomlBeef.

### Comptime

- **`[Comptime]` code may enumerate `Type.TypeDeclarations`** (not `Type.Types`), read attributes with `GetCustomAttribute<T>()` on declarations, types and fields (`GetCustomAttributes<T>()` for repeated ones), and emit code with `Compiler.EmitTypeBody` / `EmitAddInterface`. `Runtime.FatalError` in comptime code becomes a build error. See TomlBeef's `TomlSerializerCodeGen.bf`.

### Console & debugging

- **`Console.Out.Flush()`** is often needed to see output before a crash. Console output is buffered.
- **`beefbuild -run -args ...`** runs the startup project with arguments (everything after `-args` is passed through).

## Debugging with lldb/gdb

Beef compiles to native code via LLVM and emits DWARF debug info on Linux. Both lldb and gdb work.

```bash
echo 'input data' > /tmp/test.kdl
lldb --batch -o "settings set target.input-path /tmp/test.kdl" -o run -o bt ./build/Debug_Linux64/KdlTester/KdlTester
echo 'input data' | gdb -batch -ex run -ex bt ./build/Debug_Linux64/KdlTester/KdlTester
```

Frame #0 is the crash point. Mangled names map to files (`bf::KdlBeef::KdlParser::ParseNode` → `KdlParser.bf`). "Unhandled error in result" means a `Result` holding `.Err` was discarded. Release builds strip debug info; debug against `build/Debug_Linux64/...`.

## Doc Comment Style

Public API surface uses `///` documentation comments with Doxygen-style tags, placed directly above the declaration (above attributes). Required: `@brief` first when a summary is wanted, `@param` for every parameter, `@return` for every non-void method. `@brief` alone is enough for constants, fields and trivial getters. Do not use C# XML tags.

## Beef Language Conventions

- `using` directives at the top: `System*` first, then dependencies, then project namespaces.
- Members are private by default; be explicit with `public` on API surface. `internal` requires `using internal <namespace>;` even within the same namespace.
- Struct methods that modify fields are marked `mut` after the signature; `set mut` for property setters.
- Use `Result<T, KdlParseError>` for fallible operations; propagate with `Try!` or `if (X case .Err(let e)) return .Err(e);`. There are no exceptions.
- `String` owned and mutable, `StringView` borrowed; never store a `StringView` in a long-lived object unless the backing storage is owned; prefer APIs that append into caller-provided `String` buffers; never return a `scope String`.
- Prefer `scope` for temporaries, `new` + `delete`/`defer delete` or `~ delete _` fields for owned objects.

## Naming Conventions

| Kind | Convention | Example |
|------|-----------|---------|
| Types | PascalCase | `KdlParser`, `KdlDocument` |
| Methods/functions | PascalCase | `Parse`, `TryGetString` |
| Fields (public) | camelCase | `maxInputBytes` |
| Fields (private) | `m` + PascalCase | `mNodes`, `mRootNodes` |
| Fields (static/private) | `s` + PascalCase | `sScratchBuffer` |
| Constants / enum values | PascalCase | `DefaultMaxInputBytes`, `Ok` |

## Code Organization

- Each public type normally gets its own file; small helper types may share a file when that improves cohesion.
- Library sources in `src/KdlBeef/`, tests in `src/KdlBeef/tests/`, the CLI harness in `KdlTester/`.
- Do not enumerate `src/` in `BeefProj.toml`.

## Build and Test Conventions

- `beefbuild -help` is the source of truth for CLI flags.
- `beefbuild -test` / `beefbuild -test -config=TestRelease` run the `[Test]` methods.
- `tests/fetch-spec.sh` fetches the pinned official test suite; `./test-kdl-spec.sh` runs it in
  four modes (document, events, stream, collect-errors; details in `test-kdl-spec.log`; golden
  error messages in `tests/errors/`), `./test-roundtrip.sh` checks PreserveStyle round trips,
  `./test-leaks.sh` runs the `[Test]`s under LeakSanitizer.
- The reader is generic over a cursor (`KdlReaderCore<TCursor>`): any read that may reach the end of
  the window goes through `Avail`/`PeekAt`/`NewlineAt`/…, and hot loops keep a local position
  (`docs/architecture.md` §3). Profile with `perf record` on the Release `KdlTester -bench`.
- Beef rejects comparing `uint8` with a char literal: text is handled as `char8*`/`char8`, with
  `(uint8)` casts only where hex values are compared.
- Benchmarks: `bench/compare/` (`fetch.sh`, `build.sh`, `gen-inputs.py`, `run.sh`), following the
  same measurement rule as TomlBeef's.

## References

- KDL 2.0 spec: `tests/kdl-spec/draft-marchan-kdl2.md` (fetched), https://kdl.dev
- Official Beef documentation: `https://www.beeflang.org/docs/`; docs source `~/development/Beef_website`
- Beef language and tool source: `~/development/Beef`
- TomlBeef (design and code to port): `~/development/TomlBeef`, especially `docs/architecture.md`

# KdlBeef

A [KDL 2.0](https://kdl.dev) parser and writer for the [Beef programming language](https://www.beeflang.org/),
built for UI markup: fast, spec-compliant, with located errors, format preservation and compile-time
typed mapping. The sibling of [TomlBeef](../TomlBeef).

**Status: early.** A complete KDL 2.0 pull reader (`KdlReader`) and canonical formatter
(`KdlCanonical`) pass the whole official test suite; the document model and the rest are next. See
[docs/status.md](docs/status.md) and [docs/plan.md](docs/plan.md).

## Layout

- `src/KdlBeef/` — the library (and `tests/`); `KdlTester/` — the command-line harness
- `docs/plan.md` — implementation plan and handoff
- `docs/spec-reference.md` — KDL 2.0 rules and edge cases
- `docs/implementation-survey.md` — how existing implementations work
- `tests/fetch-spec.sh` — fetches the official spec and test suite
- `bench/compare/` — benchmark of KDL implementations in C, C++, Rust, Go, Java, JavaScript, C#,
  Python and Zig (`results.md`)

## Building

```bash
beefbuild            # library + KdlTester
beefbuild -test      # tests (Debug); -config=TestRelease for Release settings
```

## License

MIT (see `LICENSE`). The KDL specification and test suite are CC BY-SA 4.0 and are fetched, not
included.

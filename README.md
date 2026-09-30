# KdlBeef

A [KDL 2.0](https://kdl.dev) parser and writer for the [Beef programming language](https://www.beeflang.org/),
built for UI markup: fast, spec-compliant, with located errors, format preservation and compile-time
typed mapping. The sibling of [TomlBeef](../TomlBeef).

**Status:** reading, writing, editing, positions, limits, streams, collect-errors, style
preservation and compile-time typed mapping (`[KdlObject]`) are done and pass the whole official
test suite. Parsing runs at 140–300 MB/s into a document and 180–340 MB/s as events,
several times the fastest other KDL implementation (`bench/compare/results.md`). See
[docs/status.md](docs/status.md), [docs/architecture.md](docs/architecture.md) and
[docs/plan.md](docs/plan.md).

```beef
let doc = scope KdlDocument();
doc.ReadConfig.MetadataMode = .PreserveStyle;          // keep comments and formatting
if (doc.ReadFile("ui.kdl") case .Err(let error))
    Console.WriteLine(error.ToString(.. scope .()));   // ui.kdl:12:5: Expected ...
for (let node in doc.Nodes)
{
    if (node.Name == "button" && node.TryGetProperty("on-click", let handler) && handler case .String(let name))
        Console.WriteLine(name);
    node.SetProperty("enabled", .Bool(true));
}
let text = doc.Write(.. scope .());                    // as it was, with the edits

let reader = scope KdlReader(text);                     // or events, without a document
while (reader.Next() case .Ok(let event) && event != .EndOfDocument) {}
```

Typed, generated at compile time:

```beef
[KdlObject] class Button : Widget
{
    [KdlArgument(0)] public String Label ~ delete _;   // button "Save" on-click=save width=120
    public String OnClick ~ delete _;
    public int32 Width = 80;
    public Style Style ~ delete _;                     // a child node: style color=red
}

[KdlObject] class Panel : Widget
{
    [KdlChildren] public List<Widget> Items ~ DeleteContainerAndItems!(_);   // button …, panel …
}

let panel = scope Panel();
Try!(panel.KdlRead(doc.Nodes.Find("panel")));           // or KdlSerializer.Read(text, obj) for a document
```

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
tests/fetch-spec.sh  # the official test suite, then:
./test-kdl-spec.sh   # the suite in four modes; ./test-roundtrip.sh, ./test-leaks.sh
```

## License

MIT (see `LICENSE`). The KDL specification and test suite are CC BY-SA 4.0 and are fetched, not
included.

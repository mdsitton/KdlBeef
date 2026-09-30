# Typed serialization compared

Produced by typed.sh on 2026-09-29 (Linux x86-64, single thread; pinned versions in fetch.sh). Each
library reads inputs/ui.kdl (generated UI markup: windows of nested row/column/stack/grid containers
holding eight widget kinds, lengths as `(px)` annotations) into its own native types and writes them
back. Every harness printed the same checksum (every node's count and a sum over its values) after
reading and after re-reading its own output. Read is text in memory to objects; write is objects to
text. Median of 3 processes, each the median of samples under run.sh's rule.

input: ui.kdl, 5035460 bytes, 63,681 windows, containers and widgets

| library | language | mapping | read (ms) | read (MB/s) | write (ms) |
|---|---|---|---:|---:|---:|
| KdlBeef | Beef | [KdlObject], compile time | 39.054 | 123.0 | 23.513 |
| KdlBeef (no positions) | Beef | [KdlObject], compile time | 30.178 | 159.1 | 23.606 |
| kdl-rs | Rust | serde derive, compile time | 1476.370 | 3.3 | 124.556 |
| gokdl2 | Go | struct tags, run-time reflection | 364.106 | 13.2 | 152.835 |
| KdlSharp | C# | attributes, run-time reflection | 323.679 | 14.8 | 196.424 |

How faithfully each mapping holds this document:

- **KdlBeef**: the document as written: `[KdlChildren] List<Widget>` keeps each container's children
  in order and picks the class by node name; `(px)` lengths through a converter that sees the
  annotation. `KdlSerializer.Read` records positions for located errors; "no positions" is a
  document read without them, then `KdlRead`. Types: `KdlTester/src/TypedUi.bf`.
- **kdl-rs** (serde): children are a map keyed by name, so each container holds one list per child
  kind and **the order across kinds is lost**; annotations are dropped. The derives alone cannot read
  a child name that occurs once or not at all as a list, nor write a list of structs as repeated
  nodes: the harness adds a `Many<T>` deserialize wrapper and hand-written `Serialize` impls for the
  three container types. 1.38 s of the 1.47 s read is kdl-rs's parser.
- **gokdl2** (struct tags, no hooks): one `,multiple` slice per child kind, so **the order across
  kinds is lost**; annotations are dropped, hex written as decimal. Its typed path uses automatic
  version detection, which reads the whole input first and so avoids the refill-buffer bug that makes
  its forced-v2 streaming parse fail in results.md.
- **KdlSharp**: its serializer binds only a document's first node, maps a `List<T>` to a named wrapper
  child, and cannot pick a subclass for a list item, so **it cannot map this document by itself**:
  the harness walks the tree, picks each node's class by name and calls the serializer's
  `FromDocument`/`ToDocument` per node (the library binds every value; the harness supplies the
  structure). Order is kept; annotations are dropped, hex written as decimal, numbers go through
  `decimal`.

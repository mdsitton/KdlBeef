using System;
using KdlBeef;

namespace KdlBeef;

/// Changing a document through KdlNode: structure, arguments, properties, handle validity.
static class KdlMutationTests
{
	static void AssertWrites(KdlDocument doc, StringView expected)
	{
		let output = doc.Write(.. scope .());
		Test.Assert(output == expected, scope $"got:\n{output}\nexpected:\n{expected}");
	}

	[Test]
	public static void Build_FromNothing()
	{
		let doc = scope KdlDocument();
		let window = doc.AddNode("window");
		window.SetProperty("title", .String("Main"));
		window.SetProperty("width", .Integer(800, default), "px");
		let panel = window.AddChild("panel");
		let save = panel.AddChild("button");
		save.AddArgument(.String("Save"));
		save.SetProperty("on-click", .String("save"));
		panel.AddChild("label").AddArgument(.Float(0.5, default), "ratio");
		doc.AddNode("status").AddArgument(.Bool(true));

		AssertWrites(doc, """
			window title=Main width=(px)800 {
			    panel {
			        button Save on-click=save
			        label (ratio)0.5
			    }
			}
			status #true

			""");
		Test.Assert(save.Parent == panel && panel.Parent == window && window.ChildCount == 1 && panel.ChildCount == 2);
	}

	[Test]
	public static void Structure_InsertMoveRemove()
	{
		let doc = scope KdlDocument();
		Test.Assert(doc.Read("a { b; c; d }\ne") case .Ok);
		let a = doc.Nodes.First;
		let b = a.Children.Find("b");
		let c = a.Children.Find("c");
		let d = a.Children.Find("d");
		let e = doc.Nodes.Last;

		let x = c.InsertBefore("x");
		let y = c.InsertAfter("y");
		Test.Assert(x.NextSibling == c && c.NextSibling == y && y.NextSibling == d && a.ChildCount == 5);
		let top = a.InsertBefore("top");
		Test.Assert(doc.Nodes.First == top && !top.Parent.IsValid);
		AssertWrites(doc, "top\na {\n    b\n    x\n    c\n    y\n    d\n}\ne\n");

		// Moves carry the subtree; a node cannot move into itself or its descendants
		Test.Assert(b.MoveInto(e));
		Test.Assert(!a.MoveInto(a) && !a.MoveBefore(x) && !e.MoveInto(b));
		Test.Assert(d.MoveBefore(a) && y.MoveAfter(e));
		c.MoveToTopLevel();
		AssertWrites(doc, "top\nd\na {\n    x\n}\ne {\n    b\n}\ny\nc\n");
		Test.Assert(a.ChildCount == 1 && e.ChildCount == 1 && doc.Nodes.Count == 6);

		// Removing a node invalidates its subtree's handles, and nothing else
		e.Remove();
		Test.Assert(!e.IsValid && !b.IsValid && a.IsValid && y.IsValid);
		Test.Assert(!doc.GetNode(b.Id).IsValid);
		x.Remove();
		Test.Assert(!a.HasChildren && a.ChildCount == 0);
		AssertWrites(doc, "top\nd\na\ny\nc\n");

		// Removing while iterating
		for (let node in doc.Nodes)
			node.Remove();
		Test.Assert(doc.Nodes.IsEmpty);
		AssertWrites(doc, "\n");
	}

	[Test]
	public static void Entries_SetAddRemove()
	{
		let doc = scope KdlDocument();
		Test.Assert(doc.Read("n 1 k=(px)1 2 k=(px)2 other=x") case .Ok);
		let n = doc.Nodes.First;

		// SetProperty changes the last duplicate (the one that counts), keeping its annotation
		n.SetProperty("k", .Integer(3, default));
		Test.Assert(n.TryGetProperty("k", let k) && k case .Integer(3, ?));
		AssertWrites(doc, "n 1 2 k=(px)3 other=x\n");
		n.SetProperty("k", .Integer(4, default), "em");
		AssertWrites(doc, "n 1 2 k=(em)4 other=x\n");
		Test.Assert(n.RemoveProperty("k") == 2 && n.RemoveProperty("k") == 0);
		n.SetProperty("new", .Null);
		AssertWrites(doc, "n 1 2 new=#null other=x\n");

		Test.Assert(n.SetArgument(1, .String("two")) && !n.SetArgument(2, .Null));
		Test.Assert(n.RemoveArgument(0) && !n.RemoveArgument(5));
		AssertWrites(doc, "n two new=#null other=x\n");
		Test.Assert(n.ArgumentCount == 1 && n.Entries.Count == 3);

		// In source order the entries are: two, other=x, new=#null (the writer sorts properties)
		n.RemoveEntryAt(1);
		Test.Assert(!n.HasProperty("other") && n.HasProperty("new"));
		n.ClearEntries();
		Test.Assert(n.Entries.Count == 0);
		AssertWrites(doc, "n\n");
	}

	[Test]
	public static void Entries_GrowWhereverTheNodeIs()
	{
		// Adding entries to an early node moves its range to the end of the entry list; its neighbors
		// keep theirs
		let doc = scope KdlDocument();
		Test.Assert(doc.Read("a 1 2\nb 3\nc 4") case .Ok);
		let a = doc.Nodes.First;
		for (int i < 20)
			a.AddArgument(.Integer(10 + i, default));
		doc.Nodes.Last.AddArgument(.Integer(5, default));
		doc.Nodes.First.NextSibling.SetProperty("p", .String("q"));
		Test.Assert(a.ArgumentCount == 22);
		Test.Assert(a.TryGetArgument(21, let last) && last case .Integer(29, ?));
		let output = doc.Write(.. scope .());
		Test.Assert(output.StartsWith("a 1 2 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29\nb 3 p=q\nc 4 5\n"), output);
	}

	[Test]
	public static void Positions_FollowEntriesThatMove()
	{
		let doc = scope KdlDocument();
		doc.ReadConfig.MetadataMode = .Positions;
		Test.Assert(doc.Read("a x=1 y=2\nb 3") case .Ok);
		let a = doc.Nodes.First;
		for (int i < 10)
			a.AddArgument(.Integer(i, default));
		// The read entries keep where they came from; the added ones have no range
		Test.Assert(a.Entries[1].TryGetSourceRange(let yRange) && yRange.mLine == 1 && yRange.mColumn == 7);
		Test.Assert(!a.Entries[5].TryGetSourceRange(?));
		a.RemoveEntryAt(0);
		Test.Assert(a.Entries[0].TryGetSourceRange(let yAgain) && yAgain.mColumn == 7);
		Test.Assert(doc.Nodes.Last.Entries[0].TryGetSourceRange(let bRange) && bRange.mLine == 2 && bRange.mColumn == 3);
		Test.Assert(!a.AddChild("new").TryGetSourceRange(?));
	}
}

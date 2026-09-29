using System;
using KdlBeef;

namespace KdlBeef;

/// KdlMetadataMode.PreserveStyle: documents written back as they were read, edits regenerating only
/// what changed.
static class KdlPreserveStyleTests
{
	static KdlDocument ReadPreserving(KdlDocument doc, StringView input)
	{
		doc.ReadConfig.MetadataMode = .PreserveStyle;
		if (doc.Read(input) case .Err(let error))
			Test.Assert(false, scope $"`{input}` failed: {error}");
		return doc;
	}

	static void AssertWrites(KdlDocument doc, StringView expected)
	{
		let output = doc.Write(.. scope .());
		Test.Assert(output == expected, scope $"got:\n{output}\nexpected:\n{expected}");
	}

	[Test]
	public static void Unchanged_WritesTheInputBack()
	{
		let input = scope String("\u{FEFF}// Settings\r\n\r\n");
		input.Append("window   title=\"Main\"  /* size */ width=(px)0x500 {\n");
		input.Append("\tpanel; spacer 1_000 \\\n\t\tlast=#true\n");
		input.Append("\t/- hidden { a }\n");
		input.Append("\tlabel #\"C:\\path\"# \"\"\"\n\t\tmulti\n\t\t\"\"\" ; tail { x }\n");
		input.Append("}   // end\n\n// trailing comment");
		let doc = ReadPreserving(scope KdlDocument(), input);
		AssertWrites(doc, input);
		// The canonical form is still there
		Test.Assert(doc.WriteCanonical(.. scope .()).StartsWith("window title=Main width=(px)1280 {\n    panel\n"));
	}

	[Test]
	public static void Values_KeepTheirForm()
	{
		let doc = ReadPreserving(scope KdlDocument(), "n color=0xFF00FF mask=0b1010 id=save label=\"Save\" path=#\"C:\\x\"# 1.5 // brand\n");
		let n = doc.Nodes.First;
		n.SetProperty("color", .Integer(0xABC, default));
		n.SetProperty("mask", .Integer(5, default));
		n.SetProperty("id", .String("load"));
		n.SetProperty("label", .String("Cancel"));
		n.SetProperty("path", .String("C:\\\"y\"#"));
		n.SetArgument(0, .Float(2.5, default));
		AssertWrites(doc, "n color=0xABC mask=0b101 id=load label=\"Cancel\" path=##\"C:\\\"y\"#\"## 2.5 // brand\n");

		// A bare string that can no longer be bare is quoted
		n.SetProperty("id", .String("two words"));
		Test.Assert(doc.Write(.. scope .()).Contains("id=\"two words\""));
	}

	[Test]
	public static void Additions_FitTheDocument()
	{
		let doc = ReadPreserving(scope KdlDocument(), "button \"OK\" // primary\npanel // main\n");
		doc.Nodes.First.SetProperty("enabled", .Bool(true));
		doc.Nodes.Last.AddChild("child").AddArgument(.Integer(1, default));
		AssertWrites(doc, "button \"OK\" enabled=#true // primary\npanel {\n    child 1\n} // main\n");

		// Indentation follows the document's (tabs here)
		ReadPreserving(doc, "a {\n\tb\n}\n");
		doc.Nodes.First.AddChild("c");
		doc.AddNode("d");
		AssertWrites(doc, "a {\n\tb\n\tc\n}\nd\n");

		// A node after one that ends the input without a newline starts a line of its own
		ReadPreserving(doc, "a 1");
		doc.AddNode("b");
		AssertWrites(doc, "a 1\nb\n");
	}

	[Test]
	public static void Changes_NamesAnnotationsRemovalsMoves()
	{
		let doc = ReadPreserving(scope KdlDocument(), "(old)node 1\n");
		let node = doc.Nodes.First;
		node.Name = "renamed";
		AssertWrites(doc, "(old)renamed 1\n");
		node.SetAnnotation("new");
		AssertWrites(doc, "(new)renamed 1\n");

		// A removed node takes the comments before it along
		ReadPreserving(doc, "a\n// about b\nb 2\nc\n");
		doc.Nodes.Find("b").Remove();
		AssertWrites(doc, "a\nc\n");

		ReadPreserving(doc, "x {\n    y\n}\nz 1\n");
		doc.Nodes.Last.MoveInto(doc.Nodes.First);
		AssertWrites(doc, "x {\n    y\n    z 1\n}\n");

		// Removing an entry removes the space before it
		ReadPreserving(doc, "n a b=1 c\n");
		doc.Nodes.First.RemoveProperty("b");
		AssertWrites(doc, "n a c\n");
	}
}

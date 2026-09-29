using System;
using KdlBeef;

namespace KdlBeef;

/// Resource limits (KdlReadConfig), source names, and the Positions metadata mode.
static class KdlLimitsAndPositionsTests
{
	static void AssertLimit(StringView input, KdlReadConfig config, int line, int column)
	{
		let doc = scope KdlDocument();
		switch (doc.Read(input, config))
		{
		case .Ok:
			Test.Assert(false, scope $"`{input}` should exceed a limit");
		case .Err(let error):
			Test.Assert(error.mKind == .ResourceLimitExceeded, scope $"`{input}`: {error}");
			Test.Assert(error.mLine == line && error.mColumn == column, scope $"`{input}`: expected {line}:{column}, got {error}");
		}
	}

	static void AssertWithin(StringView input, KdlReadConfig config)
	{
		let doc = scope KdlDocument();
		if (doc.Read(input, config) case .Err(let error))
			Test.Assert(false, scope $"`{input}` failed: {error}");
	}

	[Test]
	public static void Limits_DepthNodesEntriesStringsInput()
	{
		var config = KdlReadConfig();
		config.MaxDepth = 2;
		AssertWithin("a { b }", config);
		AssertLimit("a { b { c } }", config, 1, 9);
		// Slashdashed nodes count too: they are parsed
		AssertLimit("a { b { /- c } }", config, 1, 9);

		config = .();
		config.MaxNodes = 2;
		AssertWithin("a; b", config);
		AssertLimit("/- a; b; c", config, 1, 10);

		config = .();
		config.MaxEntriesPerNode = 2;
		AssertWithin("n 1 k=2 { c 1 2 }", config);
		AssertLimit("n 1 /-2 3", config, 1, 9);

		config = .();
		config.MaxStringBytes = 3;
		AssertWithin("abc \"a\\tb\" k=xyz", config);
		AssertLimit("n abcd", config, 1, 3);
		AssertLimit("name", config, 1, 1);
		AssertLimit("n (type)1", config, 1, 4);

		config = .();
		config.MaxInputBytes = 3;
		AssertWithin("abc", config);
		AssertLimit("abcd", config, 1, 1);
	}

	[Test]
	public static void Limits_DefaultDepthIs256()
	{
		let deep = scope String();
		for (int i < 300)
			deep.Append("n {");
		for (int i < 300)
			deep.Append('}');
		AssertLimit(deep, .(), 1, 256 * 3 + 1);

		let fine = scope String();
		for (int i < 256)
			fine.Append("n {");
		for (int i < 256)
			fine.Append('}');
		AssertWithin(fine, .());
	}

	[Test]
	public static void SourceName_InErrorsFromReaderAndDocument()
	{
		var config = KdlReadConfig();
		config.SourceName = "main.kdl";
		let reader = scope KdlReader("a\nb (", config);
		Test.Assert(reader.Next() case .Ok(.StartNode));
		Test.Assert(reader.Next() case .Ok(.EndNode));
		Test.Assert(reader.Next() case .Ok(.StartNode));
		Test.Assert(reader.Next() case .Err(let error));
		Test.Assert(error.mSource == "main.kdl");
		Test.Assert(error.ToString(.. scope .()).StartsWith("main.kdl:2:4: "), error.ToString(.. scope .()));

		let doc = scope KdlDocument();
		doc.ReadConfig.SourceName = "ui.kdl";
		Test.Assert(doc.Read("x \"") case .Err(let docError) && docError.mSource == "ui.kdl");
		Test.Assert(doc.SourceName == "ui.kdl");
	}

	[Test]
	public static void Positions_NodesAndEntries()
	{
		StringView input = "window title=\"Main\" {\n    button \"Save\" \\\n        on-click=save\n    /- hidden\n}\n(t)é 1\n  ü k=1";
		let doc = scope KdlDocument();
		doc.ReadConfig.MetadataMode = .Positions;
		doc.ReadConfig.SourceName = "ui.kdl";
		Test.Assert(doc.Read(input) case .Ok);

		let window = doc.Nodes.First;
		Test.Assert(window.TryGetSourceRange(let windowRange));
		Test.Assert(windowRange.mLine == 1 && windowRange.mColumn == 1 && windowRange.mOffset == 0);
		// To the `}` of its children block
		Test.Assert(windowRange.mLength == input.IndexOf('}') + 1);
		Test.Assert(windowRange.ToString(.. scope .()) == "ui.kdl:1:1");

		Test.Assert(window.Entries[0].TryGetSourceRange(let titleRange));
		Test.Assert(titleRange.mLine == 1 && titleRange.mColumn == 8 && titleRange.mLength == 12);

		let button = window.FirstChild;
		Test.Assert(button.TryGetSourceRange(let buttonRange));
		Test.Assert(buttonRange.mLine == 2 && buttonRange.mColumn == 5);
		// Through the continued line's last entry
		Test.Assert(input.Substring(buttonRange.mOffset, buttonRange.mLength) == "button \"Save\" \\\n        on-click=save");
		Test.Assert(button.Entries[0].TryGetSourceRange(let saveRange) && saveRange.mLine == 2 && saveRange.mColumn == 12 && saveRange.mLength == 6);
		Test.Assert(button.Entries[1].TryGetSourceRange(let clickRange) && clickRange.mLine == 3 && clickRange.mColumn == 9);
		Test.Assert(input.Substring(clickRange.mOffset, clickRange.mLength) == "on-click=save");

		// Columns count code points, not bytes
		let e = doc.Nodes.First.NextSibling;
		Test.Assert(e.TryGetSourceRange(let eRange) && eRange.mLine == 6 && eRange.mColumn == 1);
		Test.Assert(input.Substring(eRange.mOffset, eRange.mLength) == "(t)é 1");
		let u = e.NextSibling;
		Test.Assert(u.TryGetSourceRange(let uRange) && uRange.mLine == 7 && uRange.mColumn == 3);
		Test.Assert(u.Entries[0].TryGetSourceRange(let kRange) && kRange.mColumn == 5);

		// Without Positions there are none
		Test.Assert(doc.Read(input, .()) case .Ok);
		Test.Assert(!doc.Nodes.First.TryGetSourceRange(?));
		Test.Assert(!doc.Nodes.First.Entries[0].TryGetSourceRange(?));
	}
}

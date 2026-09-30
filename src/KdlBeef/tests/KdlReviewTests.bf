using System;
using System.Collections;
using System.Globalization;
using KdlBeef;

namespace KdlBeef.Tests;

// Types for the typed-mapping regressions (R7, R9)

/// Builds: a property and a child node may share a name (the mapping checks reject two properties, or
/// two children, with one name; argument indices that repeat or are negative; several role attributes
/// on a field; a second [KdlArguments] or [KdlChildren] in a chain; see architecture.md §6)
[KdlObject]
class FineSameName
{
	public int32 Color;
	[KdlChild, KdlName("color")] public int32 ColorChild;
}

/// Nested containers and non-String keys (P6)
[KdlObject]
class Nested
{
	public List<List<int32>> Matrix;
	public List<List<Point>> Paths;
	public List<Dictionary<String, int32>> Rows;
	public Dictionary<String, Dictionary<String, String>> Sections;
	public Dictionary<int32, String> ById;
	public Dictionary<Align, int32> Widths;
	public Dictionary<String, List<List<String>>> Groups;

	public ~this()
	{
		if (Matrix != null)
			DeleteContainerAndItems!(Matrix);
		if (Paths != null)
			DeleteContainerAndItems!(Paths);
		if (Rows != null)
		{
			for (let row in Rows)
				DeleteDictionaryAndKeys!(row);
			delete Rows;
		}
		if (Sections != null)
		{
			for (let entry in Sections)
			{
				delete entry.key;
				DeleteDictionaryAndKeysAndValues!(entry.value);
			}
			delete Sections;
		}
		if (ById != null)
			DeleteDictionaryAndValues!(ById);
		delete Widths;
		if (Groups != null)
		{
			for (let entry in Groups)
			{
				delete entry.key;
				for (let list in entry.value)
					DeleteContainerAndItems!(list);
				delete entry.value;
			}
			delete Groups;
		}
	}
}

/// F2: containers whose items or values may be null when a read replaces them
[KdlObject]
class NestedNull
{
	public List<List<String>> Values;
	public Dictionary<String, Dictionary<String, String>> Maps;

	public ~this()
	{
		if (Values != null)
		{
			for (let inner in Values)
			{
				if (inner != null)
					DeleteContainerAndItems!(inner);
			}
			delete Values;
		}
		if (Maps != null)
		{
			for (let entry in Maps)
			{
				delete entry.key;
				if (entry.value != null)
					DeleteDictionaryAndKeysAndValues!(entry.value);
			}
			delete Maps;
		}
	}
}

/// F3: a [KdlArguments] list in the base, a fixed argument in the subclass
[KdlObject]
class RestBase
{
	[KdlArguments] public List<int32> Rest ~ delete _;
}

[KdlObject]
class HeadDerived : RestBase
{
	[KdlArgument(0)] public int32 Head;
}

/// F4: integer keys at their types' limits
[KdlObject]
class IntegerKeys
{
	public Dictionary<int64, int32> Signed ~ delete _;
	public Dictionary<uint64, int32> Unsigned ~ delete _;
	public Dictionary<int8, int32> Small ~ delete _;
	public Dictionary<uint32, int32> Medium ~ delete _;
}

[KdlObject]
class ReviewProbe
{
	public int32 X;
}

[KdlObject(Name = "item")]
class CountItem
{
	public int32 Count;
}

[KdlObject]
class Versioned
{
	[KdlChild] public int32 Version;
}

/// R7: a [KdlChildren] list in a subclass, and a [KdlChild] field in its base
[KdlObject]
class Inventory : Versioned
{
	[KdlChildren] public List<CountItem> Items ~ DeleteContainerAndItems!(_);
}

[KdlObject]
class Holder
{
	[KdlChildren] public List<CountItem> Items ~ DeleteContainerAndItems!(_);
}

/// R7 the other way: a [KdlChildren] list in the base, a child object in the subclass
[KdlObject]
class StyledHolder : Holder
{
	public Style Style ~ delete _;
}

[KdlObject]
class NamedNode
{
	[KdlArgument(0)] public String Name ~ delete _;
}

/// R7, arguments: [KdlArguments] after an inherited [KdlArgument(0)]
[KdlObject]
class NamedValues : NamedNode
{
	[KdlArguments] public List<int32> Values ~ delete _;
}

/// Regressions for the deep review (`docs/review.md`, R1-R9, and the quadratic-path and big-integer
/// findings): each test is the review's reproduction, plus the neighboring cases it asked for.
static class KdlReviewTests
{
	// R1: an error returned by a one-call serializer read outlives the scoped document

	[Test]
	public static void R1_CollectedErrorOutlivesTheSerializersDocument()
	{
		// The message the same error has without CollectErrors (copied: the next error reuses the buffer)
		let expected = scope String();
		{
			let doc = scope KdlDocument();
			Test.Assert(doc.Read("bad =;\n") case .Err(let plain));
			expected.Append(plain.mMessage);
		}

		var config = KdlReadConfig();
		config.CollectErrors = true;
		config.SourceName = "review.kdl";
		let target = scope ReviewProbe();
		let result = KdlSerializer.Read("bad =;\n", target, config);
		Test.Assert(result case .Err(let error));

		// Unrelated allocations once the serializer's document is gone (no new errors: they would reuse
		// the per-thread buffer, which is the documented lifetime)
		for (int i < 20)
		{
			let other = scope:: KdlDocument();
			Test.Assert(other.Read("node \"some text to allocate\" key=\"more text\" { child 1 2 3 }") case .Ok);
		}
		let other = scope KdlDocument();
		other.ReadConfig.MetadataMode = .PreserveStyle;
		Test.Assert(other.Read("// filler\nfiller \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"\n") case .Ok);

		Test.Assert(error.mMessage == expected, scope $"message `{error.mMessage}`, expected `{expected}`");
		Test.Assert(error.mSource == "review.kdl");
		let shown = error.ToString(.. scope .());
		Test.Assert(shown.StartsWith("review.kdl:1:") && shown.EndsWith(expected), shown);
	}

	[Test]
	public static void R1_DetachCopiesADocumentsError()
	{
		KdlParseError kept;
		{
			let doc = scope KdlDocument();
			var config = KdlReadConfig();
			config.CollectErrors = true;
			config.SourceName = "in.kdl";
			Test.Assert(doc.Read("a =\nb }\n", config) case .Err(let error));
			kept = error;
			kept.Detach();
		}
		for (int i < 10)
		{
			let other = scope:: KdlDocument();
			Test.Assert(other.Read("x \"filler text that allocates\"") case .Ok);
		}
		Test.Assert(kept.mSource == "in.kdl" && kept.mLine == 1 && kept.mMessage.StartsWith("Expected"), kept.ToString(.. scope .()));
	}

	// R2: a moved node must not merge with its neighbors

	/// The edited document's structure (canonical form) must be what its preserving output reads back as.
	static void AssertSameStructure(KdlDocument edited, StringView what)
	{
		let output = edited.Write(.. scope .());
		let reread = scope KdlDocument();
		if (reread.Read(output) case .Err(let error))
		{
			Test.Assert(false, scope $"{what}: `{output}` does not parse: {error}");
			return;
		}
		let expected = edited.WriteCanonical(.. scope .());
		let actual = reread.Write(.. scope .());
		Test.Assert(expected == actual, scope $"{what}: wrote `{output}`, which reads as\n{actual}\nexpected\n{expected}");
	}

	static KdlDocument ReadPreserving(KdlDocument doc, StringView text)
	{
		doc.ReadConfig.MetadataMode = .PreserveStyle;
		if (doc.Read(text) case .Err(let error))
			Test.Assert(false, scope $"`{text}`: {error}");
		return doc;
	}

	[Test]
	public static void R2_MovesKeepNodesApart()
	{
		// The review's reproductions
		{
			let doc = ReadPreserving(scope KdlDocument(), "a\nb");
			doc.Nodes.Last.MoveBefore(doc.Nodes.First);
			Test.Assert(doc.Write(.. scope .()) == "b\na\n", doc.Write(.. scope .()));
			AssertSameStructure(doc, "last before first, no final newline");
		}
		{
			let doc = ReadPreserving(scope KdlDocument(), "p{a;b}");
			let p = doc.Root.Find("p");
			p.Children.Last.MoveBefore(p.Children.First);
			AssertSameStructure(doc, "compact block, b before a");
		}
		// The other direction, and more boundaries
		{
			let doc = ReadPreserving(scope KdlDocument(), "p{a;b}");
			let p = doc.Root.Find("p");
			p.Children.First.MoveAfter(p.Children.Last);
			AssertSameStructure(doc, "compact block, a after b");
		}
		{
			let doc = ReadPreserving(scope KdlDocument(), "a\nb");
			doc.Nodes.First.MoveAfter(doc.Nodes.Last);
			AssertSameStructure(doc, "first after last");
		}
		{
			// After a node that ended at the end with a line comment and no newline
			let doc = ReadPreserving(scope KdlDocument(), "a 1\nb 2 // last");
			doc.Nodes.Last.MoveBefore(doc.Nodes.First);
			AssertSameStructure(doc, "line comment at the end");
		}
		{
			// A block comment and spaces before the parent's `}`: `a 1 /* c */  ` then `b` would make b
			// an argument of a
			let doc = ReadPreserving(scope KdlDocument(), "p { b 2; a 1 /* c */  }");
			let p = doc.Root.Find("p");
			p.Children.Last.MoveBefore(p.Children.First);
			AssertSameStructure(doc, "comment and spaces before `}`");
		}
		{
			// A children block that ends the document
			let doc = ReadPreserving(scope KdlDocument(), "q\np { x }");
			doc.Nodes.First.MoveAfter(doc.Nodes.Last);
			AssertSameStructure(doc, "after a block at the end");
		}
		{
			// A line continuation at the end is not a terminator
			let doc = ReadPreserving(scope KdlDocument(), "b\na 1 \\\n");
			doc.Nodes.Last.MoveBefore(doc.Nodes.First);
			AssertSameStructure(doc, "line continuation at the end");
		}
		{
			// Into another block, and out to the top level
			let doc = ReadPreserving(scope KdlDocument(), "p{a;b}\nq{c}");
			let q = doc.Root.Find("q");
			doc.Root.Find("p").Children.Last.MoveInto(q);
			q.Children.First.MoveToTopLevel();
			AssertSameStructure(doc, "between blocks and the top level");
		}
		{
			// A newline other than LF ends a node too (NEL), and CRLF
			let doc = ReadPreserving(scope KdlDocument(), "a\u{85}b\r\nc");
			doc.Nodes.Last.MoveBefore(doc.Nodes.First);
			AssertSameStructure(doc, "NEL and CRLF");
		}
	}

	// R3: recovery in a stream must not corrupt the error it returns

	static void R3Check(StringView input, int chunk, KdlErrorKind laterKind)
	{
		// The syntax error's message from memory, without what follows
		let expected = scope String();
		{
			let doc = scope KdlDocument();
			Test.Assert(doc.Read("n =bad\n") case .Err(let plain));
			expected.Append(plain.mMessage);
		}
		var config = KdlReadConfig();
		config.CollectErrors = true;
		config.StreamBufferBytes = 16;
		let stream = scope KdlStreamTests.TrickleStream(input, chunk);
		let reader = scope KdlReader();
		reader.Reset(stream, config);
		Test.Assert(reader.Next() case .Ok(.StartNode));
		switch (reader.Next())
		{
		case .Ok(let event):
			Test.Assert(false, scope $"expected the syntax error, got {event}");
		case .Err(let error):
			Test.Assert(error.mKind == .UnexpectedChar && error.mOffset == 2, error.ToString(.. scope .()));
			Test.Assert(error.mMessage == expected, scope $"message `{error.mMessage}`, expected `{expected}`");
		}
		// The input's own failure, met during recovery, comes next (after the skipped node's EndNode)
		int guard = 0;
		while (guard++ < 10)
		{
			switch (reader.Next())
			{
			case .Ok(let event):
				Test.Assert(event != .EndOfDocument, "the input's failure was not reported");
				continue;
			case .Err(let error):
				Test.Assert(error.mKind == laterKind, error.ToString(.. scope .()));
			}
			break;
		}
		Test.Assert(reader.IsStopped);
	}

	[Test]
	public static void R3_RecoveryKeepsThePendingError()
	{
		let body = scope String("n =bad /*")..Append('x', 100)..Append("*/\n");
		// A disallowed code point after the comment (the review's reproduction), at offset 112
		let disallowed = scope String(body)..Append('\0');
		for (let chunk in int[](1, 3, 16, 4096))
			R3Check(disallowed, chunk, .DisallowedCodePoint);
		// Invalid UTF-8
		let invalid = scope String(body)..Append((char8)0xC3)..Append((char8)0x28);
		R3Check(invalid, 5, .InvalidUtf8);
		// The input size limit, reached during recovery
		{
			var config = KdlReadConfig();
			config.CollectErrors = true;
			config.StreamBufferBytes = 16;
			config.MaxInputBytes = 60;
			let expected = scope String();
			{
				let doc = scope KdlDocument();
				Test.Assert(doc.Read("n =bad\n") case .Err(let plain));
				expected.Append(plain.mMessage);
			}
			let reader = scope KdlReader();
			reader.Reset(scope KdlStreamTests.TrickleStream(body, 4), config);
			Test.Assert(reader.Next() case .Ok(.StartNode));
			Test.Assert(reader.Next() case .Err(let error) && error.mMessage == expected);
		}
		// An I/O failure during recovery
		{
			var config = KdlReadConfig();
			config.CollectErrors = true;
			config.StreamBufferBytes = 16;
			let expected = scope String();
			{
				let doc = scope KdlDocument();
				Test.Assert(doc.Read("n =bad\n") case .Err(let plain));
				expected.Append(plain.mMessage);
			}
			let reader = scope KdlReader();
			reader.Reset(scope KdlStreamTests.TrickleStream(body, 4, 50), config);
			Test.Assert(reader.Next() case .Ok(.StartNode));
			Test.Assert(reader.Next() case .Err(let error) && error.mMessage == expected);
			bool io = false;
			for (int i < 10)
			{
				if (reader.Next() case .Err(let later))
				{
					io = later.mKind == .IoError;
					break;
				}
			}
			Test.Assert(io);
		}
	}

	// R4: floats do not depend on the current culture's decimal separator

	[Test]
	public static void R4_FloatsIgnoreTheCulturesDecimalSeparator()
	{
		let culture = CultureInfo.CurrentCulture;
		let saved = culture.mNumInfo;
		let comma = scope NumberFormatInfo();
		comma.NumberDecimalSeparator = ",";
		culture.mNumInfo = comma;
		defer { culture.mNumInfo = saved; }
		// The setting takes effect for culture-dependent parsing
		Test.Assert(!(double.Parse("1.25") case .Ok(1.25)));

		let doc = scope KdlDocument();
		Test.Assert(doc.Read("n 1.5 1.5_0 1.234567890123456789 12_345.678_9e-2 1e400 -1e400 1e-400") case .Ok);
		let n = doc.Root.Find("n");
		Test.Assert(n.GetDouble(0) == 1.5 && n.GetDouble(1) == 1.5);
		Test.Assert(Math.Abs(n.GetDouble(2) - 1.2345678901234567) < 1e-15, scope $"{n.GetDouble(2)}");
		Test.Assert(Math.Abs(n.GetDouble(3) - 123.456789) < 1e-12, scope $"{n.GetDouble(3)}");
		// Out of range: infinities and zero, not errors
		Test.Assert(n.GetDouble(4) == double.PositiveInfinity && n.GetDouble(5) == double.NegativeInfinity && n.GetDouble(6) == 0);
	}

	// R5: MaxTokenBytes is a limit on the construct, whatever the buffer

	static bool ReadsWithin(StringView input, int buffer, int chunk, int maxToken)
	{
		var config = KdlReadConfig();
		config.StreamBufferBytes = buffer;
		config.MaxTokenBytes = maxToken;
		let doc = scope KdlDocument();
		switch (doc.Read(scope KdlStreamTests.TrickleStream(input, chunk), config))
		{
		case .Ok:
			return true;
		case .Err(let error):
			Test.Assert(error.mKind == .ResourceLimitExceeded, error.ToString(.. scope .()));
			return false;
		}
	}

	[Test]
	public static void R5_TokenLimitIndependentOfTheBuffer()
	{
		// The review's table: all rejected
		let long = scope String("n \"")..Append('x', 200)..Append("\"\n");
		Test.Assert(!ReadsWithin(long, 1024, 4096, 32));
		Test.Assert(!ReadsWithin(long, 16, 4096, 32));
		let medium = scope String("n \"")..Append('x', 40)..Append("\"\n");
		Test.Assert(!ReadsWithin(medium, 16, 4096, 33));

		// The smallest limit that accepts a document is the same for every buffer and chunk size, and
		// covers its longest token (42 bytes of string) with a few bytes of lookahead at most
		int threshold = -1;
		for (let buffer in int[](16, 17, 40, 64, 1024))
		{
			for (let chunk in int[](1, 7, 4096))
			{
				int found = -1;
				for (int limit = 30; limit <= 60; limit++)
				{
					if (ReadsWithin(medium, buffer, chunk, limit))
					{
						found = limit;
						break;
					}
				}
				Test.Assert(found > 0, scope $"buffer {buffer}, chunk {chunk}: nothing accepted");
				if (threshold < 0)
					threshold = found;
				Test.Assert(found == threshold, scope $"buffer {buffer}, chunk {chunk}: {found}, elsewhere {threshold}");
			}
		}
		Test.Assert(threshold >= 42 && threshold <= 46, scope $"{threshold}");

		// Whitespace between constructs is not held: a long run of it reads through a small limit
		let spaces = scope String()..Append(' ', 1000)..Append("n\n")..Append('\t', 500)..Append("m 1   \n\r\n\r\n");
		for (let chunk in int[](1, 3, 4096))
			Test.Assert(ReadsWithin(spaces, 16, chunk, 32), scope $"chunk {chunk}");
	}

	// R6: a changed raw string is written as valid KDL

	[Test]
	public static void R6_ChangedRawStringsStayValid()
	{
		for (let value in StringView[]("\"", "\"\"abc", "\"\"\"", "\"\"", "", "a\"#b", "\"#", "x\"##\"##y", "#\"q\"#", "plain"))
		{
			let doc = ReadPreserving(scope KdlDocument(), "n p=#\"old\"#\n");
			doc.Root.Find("n").SetProperty("p", .String(value));
			let output = doc.Write(.. scope .());
			let reread = scope KdlDocument();
			if (reread.Read(output) case .Err(let error))
			{
				Test.Assert(false, scope $"`{value}` written as `{output}`: {error}");
				continue;
			}
			Test.Assert(reread.Root.Find("n").GetString("p", "(none)") == value, scope $"`{value}` written as `{output}`");
		}
	}

	// R7: inherited fields are claimed children, and inherited arguments are taken

	[Test]
	public static void R7_InheritedMappings()
	{
		// The review's reproduction: a base [KdlChild], a subclass [KdlChildren]
		let inventory = scope Inventory();
		let doc = scope KdlDocument();
		Test.Assert(doc.Read("version 7\nitem count=3\nitem count=4\n") case .Ok);
		if (inventory.KdlRead(doc.Root) case .Err(let error))
			Test.Assert(false, error.ToString(.. scope .()));
		Test.Assert(inventory.Version == 7 && inventory.Items.Count == 2 && inventory.Items[1].Count == 4);
		delete inventory.Items.PopBack();
		Test.Assert(inventory.KdlWrite(doc.Root) case .Ok);
		Test.Assert(doc.Write(.. scope .()) == "version 7\nitem count=3\n", doc.Write(.. scope .()));

		// The other way: the base's [KdlChildren] leaves the subclass's child alone, reading and writing
		let holder = scope StyledHolder();
		let text = scope String();
		Test.Assert(KdlSerializer.Read("style color=red\nitem count=1\n", holder) case .Ok);
		Test.Assert(holder.Style.Color == "red" && holder.Items.Count == 1);
		Test.Assert(KdlSerializer.Write(holder, text) case .Ok);
		let back = scope StyledHolder();
		Test.Assert(KdlSerializer.Read(text, back) case .Ok, text);
		Test.Assert(back.Style.Color == "red" && back.Items.Count == 1, text);

		// Arguments: [KdlArguments] starts after the inherited [KdlArgument(0)]
		let named = scope NamedValues();
		let args = scope KdlDocument();
		Test.Assert(args.Read("n \"a\" 1 2 3") case .Ok);
		Test.Assert(named.KdlRead(args.Root.Find("n")) case .Ok);
		Test.Assert(named.Name == "a" && named.Values.Count == 3 && named.Values[0] == 1);
		named.Values.RemoveAt(0);
		Test.Assert(named.KdlWrite(args.Root.Find("n")) case .Ok);
		Test.Assert(args.Write(.. scope .()) == "n a 2 3\n", args.Write(.. scope .()));
	}

	// R8: recovery at the end still closes every started node

	static void AssertBalanced(StringView input)
	{
		var config = KdlReadConfig();
		config.CollectErrors = true;
		for (let stream in bool[](false, true))
		{
			let reader = scope KdlReader();
			if (stream)
			{
				var streamed = config;
				streamed.StreamBufferBytes = 16;
				reader.Reset(scope:: KdlStreamTests.TrickleStream(input, 3), streamed);
			}
			else
				reader.Reset(input, config);
			int starts = 0;
			int ends = 0;
			int errors = 0;
			bool done = false;
			for (int i < 100)
			{
				switch (reader.Next())
				{
				case .Ok(let event):
					if (event == .StartNode)
						starts++;
					else if (event == .EndNode)
					{
						ends++;
						Test.Assert(ends <= starts, scope $"`{input}`: EndNode without a StartNode");
					}
					else if (event == .EndOfDocument)
						done = true;
				case .Err:
					errors++;
				}
				if (done || reader.IsStopped)
					break;
			}
			Test.Assert(done && errors > 0, scope $"`{input}`: expected errors and the end");
			Test.Assert(starts == ends, scope $"`{input}` (stream {stream}): {starts} StartNodes, {ends} EndNodes");
		}
	}

	[Test]
	public static void R8_EndOfInputClosesEveryNode()
	{
		AssertBalanced("a /-{");
		AssertBalanced("a { b /-{");
		AssertBalanced("a {");
		AssertBalanced("a { b {");
		AssertBalanced("a /-{ b {");
		AssertBalanced("a { b /-{ c {");
		AssertBalanced("a { b /-{ c /-{ d");
		AssertBalanced("x\na { b 1\n    c /-{ d {\n");
		AssertBalanced("/-a { b\nc {");
	}

	// R9: null lists remove what they map; empty and shorter lists too

	[Test]
	public static void R9_NullListsRemoveTheirNodes()
	{
		let doc = scope KdlDocument();
		Test.Assert(doc.Read("version 1\nitem \"a\"\ntitle \"t\"\nitem \"b\"\nmain {\n    tags \"x\"\n    button \"A\"\n    label \"B\"\n}\n") case .Ok);
		let app = scope App();
		Test.Assert(app.KdlRead(doc.Root) case .Ok);
		Test.Assert(app.Items.Count == 2 && app.Main.Items.Count == 2);

		// Shorter: the extra item goes, the first stays in place (before `title`)
		delete app.Items.PopBack();
		Test.Assert(app.KdlWrite(doc.Root) case .Ok);
		Test.Assert(doc.Root.Children.Named("item").Count == 1 && doc.Root.Find("item").GetString(0) == "a");
		Test.Assert(doc.Root.Find("item").NextSibling.Name == "title", doc.Write(.. scope .()));

		// Null: every item goes, unrelated nodes stay
		DeleteContainerAndItems!(app.Items);
		app.Items = null;
		DeleteContainerAndItems!(app.Main.Items);
		app.Main.Items = null;
		Test.Assert(app.KdlWrite(doc.Root) case .Ok);
		let main = doc.Root.Find("main");
		Test.Assert(doc.Root.Children.Named("item").Count == 0 && doc.Root.Find("title").IsValid && doc.Root.Find("version").IsValid, doc.Write(.. scope .()));
		Test.Assert(main.ChildCount == 1 && main.Find("tags").IsValid, doc.Write(.. scope .()));

		// Empty lists: the same; populated again: back
		app.Items = new .();
		app.Main.Items = new .();
		Test.Assert(app.KdlWrite(doc.Root) case .Ok);
		Test.Assert(doc.Root.Children.Named("item").Count == 0 && main.ChildCount == 1);
		app.Items.Add(new Item() { Name = new .("c") });
		let label = new Label();
		label.Text = new .("L");
		app.Main.Items.Add(label);
		Test.Assert(app.KdlWrite(doc.Root) case .Ok);
		Test.Assert(doc.Root.Find("item").GetString(0) == "c" && main.ChildCount == 2 && main.LastChild.Name == "label", doc.Write(.. scope .()));
	}

	[Test]
	public static void R9_NullArgumentListRemovesItsArguments()
	{
		let doc = scope KdlDocument();
		Test.Assert(doc.Read("n \"a\" 1 2 3") case .Ok);
		let named = scope NamedValues();
		Test.Assert(named.KdlRead(doc.Root.Find("n")) case .Ok);
		delete named.Values;
		named.Values = null;
		Test.Assert(named.KdlWrite(doc.Root.Find("n")) case .Ok);
		Test.Assert(doc.Write(.. scope .()) == "n a\n", doc.Write(.. scope .()));
	}

	// Typed lists in one pass: long lists read and write correctly (arguments, children, [KdlChildren])

	[Test]
	public static void Lists_LongListsRoundTrip()
	{
		let text = scope String("n \"a\"");
		for (int i < 3000)
			text.AppendF(" {}", i);
		text.Append("\n");
		let doc = scope KdlDocument();
		Test.Assert(doc.Read(text) case .Ok);
		let named = scope NamedValues();
		Test.Assert(named.KdlRead(doc.Root.Find("n")) case .Ok);
		Test.Assert(named.Values.Count == 3000 && named.Values[2999] == 2999);
		named.Values.RemoveRange(1000, 2000);
		named.Values[0] = -1;
		Test.Assert(named.KdlWrite(doc.Root.Find("n")) case .Ok);
		let n = doc.Root.Find("n");
		Test.Assert(n.ArgumentCount == 1001 && n.GetInt64(1) == -1 && n.GetInt64(1000) == 999);

		let holder = scope Holder();
		let items = scope String();
		for (int i < 2000)
			items.AppendF("item count={}\n", i);
		Test.Assert(KdlSerializer.Read(items, holder) case .Ok);
		Test.Assert(holder.Items.Count == 2000);
		let output = scope String();
		Test.Assert(KdlSerializer.Write(holder, output) case .Ok);
		Test.Assert(output == items);
	}

	// Dictionaries are written through a key index: many keys, null values, removed and duplicate keys

	[Test]
	public static void Dictionaries_LargeWritesAndNulls()
	{
		let config = scope Config();
		config.Env = new .();
		config.Servers = new .();
		for (int i < 3000)
		{
			config.Env.Add(new $"k{i}", new $"v{i}");
			config.Servers.Add(new $"s{i}", new Server() { Port = (int32)i });
		}
		let doc = scope KdlDocument();
		Test.Assert(config.KdlWrite(doc.Root) case .Ok);
		Test.Assert(doc.Root.Find("env").ChildCount == 3000 && doc.Root.Find("servers").ChildCount == 3000);
		Test.Assert(doc.Root.Find("env").Find("k2999").GetString(0) == "v2999");

		// Null values remove their entries; removed keys go; a new key appends; the rest stay in place
		delete config.Env["k5"];
		config.Env["k5"] = null;
		delete config.Servers["s7"];
		config.Servers["s7"] = null;
		if (config.Env.GetAndRemoveAlt("k6") case .Ok(let removed))
		{
			delete removed.key;
			delete removed.value;
		}
		config.Env.Add(new .("new"), new .("n"));
		config.Env["k0"].Set("changed");
		Test.Assert(config.KdlWrite(doc.Root) case .Ok);
		let env = doc.Root.Find("env");
		Test.Assert(env.ChildCount == 2999 && !env.Find("k5").IsValid && !env.Find("k6").IsValid);
		Test.Assert(env.FirstChild.Name == "k0" && env.FirstChild.GetString(0) == "changed" && env.LastChild.Name == "new");
		Test.Assert(doc.Root.Find("servers").ChildCount == 2999 && !doc.Root.Find("servers").Find("s7").IsValid);

		// Duplicate keys in the document: the last is kept and updated, the others removed
		let dup = scope KdlDocument();
		Test.Assert(dup.Read("env { a \"1\"; b \"2\"; a \"3\" }") case .Ok);
		let small = scope Config();
		Test.Assert(small.KdlRead(dup.Root) case .Ok && small.Env["a"] == "3");
		small.Env["a"].Set("4");
		Test.Assert(small.KdlWrite(dup.Root) case .Ok);
		Test.Assert(dup.Root.Find("env").ChildCount == 2 && dup.Root.Find("env").LastChild.GetString(0) == "4", dup.Write(.. scope .()));
	}

	// Budgets: MaxStringBytes during decoding, MaxInputBytes before a file is read

	[Test]
	public static void Budgets_StringLimitWhileDecoding()
	{
		var config = KdlReadConfig();
		config.MaxStringBytes = 8;
		let doc = scope KdlDocument();
		// Escaped quoted strings, multi-line strings with and without escapes: located at the string
		for (let text in StringView[]("n \"abc\\tdefghijkl\"", "n \"\"\"\n    abcdefghij\n    \"\"\"", "n \"\"\"\n    abc\\tdefghij\n    \"\"\"", "n #\"\"\"\n    abcdefghij\n    \"\"\"#"))
		{
			switch (doc.Read(text, config))
			{
			case .Ok:
				Test.Assert(false, scope $"`{text}` should exceed the limit");
			case .Err(let error):
				Test.Assert(error.mKind == .ResourceLimitExceeded && error.mLine == 1 && error.mColumn == 3, scope $"`{text}`: {error}");
			}
		}
		// A long source that decodes to a short value is within it
		Test.Assert(doc.Read("n \"\\u{41}\\u{42}\\u{43}\\u{44}\\u{45}\\u{46}\\u{47}\\u{48}\" \"\"\"\n        abcdefgh\n        \"\"\"", config) case .Ok);
		Test.Assert(doc.Root.Find("n").GetString(0) == "ABCDEFGH" && doc.Root.Find("n").GetString(1) == "abcdefgh");
	}

	[Test]
	public static void Budgets_FileSizeBeforeReading()
	{
		let path = scope String();
		Test.Assert(System.IO.Path.GetTempPath(path) case .Ok);
		path.Append("kdlbeef-budget-test.kdl");
		let text = scope String();
		for (int i < 200)
			text.AppendF("node{} \"value\"\n", i);
		Test.Assert(System.IO.File.WriteAllText(path, text) case .Ok);
		defer { System.IO.File.Delete(path).IgnoreError(); }

		let doc = scope KdlDocument();
		var config = KdlReadConfig();
		config.MaxInputBytes = 100;
		switch (doc.ReadFile(path, config))
		{
		case .Ok:
			Test.Assert(false, "the file is larger than MaxInputBytes");
		case .Err(let error):
			Test.Assert(error.mKind == .ResourceLimitExceeded && error.mMessage.Contains(scope $"({text.Length} bytes)") && error.mSource == path, error.ToString(.. scope .()));
		}
		Test.Assert(doc.Nodes.IsEmpty);
		// Within the budget, and without one: the whole file
		config.MaxInputBytes = text.Length;
		Test.Assert(doc.ReadFile(path, config) case .Ok && doc.Nodes.Count == 200);
		Test.Assert(doc.ReadFile(path) case .Ok && doc.Nodes.Last.Name == "node199");
	}

	// Nested containers and non-String keys (P6)

	const String cNested = """
		matrix {
		    - 1 2 3
		    - 4
		    -
		}
		paths {
		    - { point 0 0; point 5 5 }
		    - { point 9 9 }
		}
		rows {
		    - { a 1; b 2 }
		    - { c 3 }
		}
		sections {
		    db { host "localhost"; port "5432" }
		    cache { host "redis" }
		}
		by-id { "1" one; "-2" minus-two; "3" #null }
		widths { start 10; end-aligned 30 }
		groups {
		    ui {
		        - button label
		        - slider
		    }
		}

		""";

	[Test]
	public static void Nested_ReadWriteAndUpdate()
	{
		let nested = scope Nested();
		if (KdlSerializer.Read(cNested, nested) case .Err(let error))
			Test.Assert(false, error.ToString(.. scope .()));
		Test.Assert(nested.Matrix.Count == 3 && nested.Matrix[0].Count == 3 && nested.Matrix[0][2] == 3 && nested.Matrix[1][0] == 4 && nested.Matrix[2].Count == 0);
		Test.Assert(nested.Paths.Count == 2 && nested.Paths[0].Count == 2 && nested.Paths[0][1].Y == 5 && nested.Paths[1][0].X == 9);
		Test.Assert(nested.Rows.Count == 2 && nested.Rows[0]["b"] == 2 && nested.Rows[1]["c"] == 3);
		Test.Assert(nested.Sections.Count == 2 && nested.Sections["db"]["port"] == "5432" && nested.Sections["cache"]["host"] == "redis");
		Test.Assert(nested.ById.Count == 2 && nested.ById[1] == "one" && nested.ById[-2] == "minus-two");
		Test.Assert(nested.Widths.Count == 2 && nested.Widths[.Start] == 10 && nested.Widths[.EndAligned] == 30);
		Test.Assert(nested.Groups["ui"].Count == 2 && nested.Groups["ui"][0][1] == "label" && nested.Groups["ui"][1][0] == "slider");

		// Read again into the filled object (what it owned is freed), with a repeated nested key
		Test.Assert(KdlSerializer.Read(cNested, nested) case .Ok);
		Test.Assert(KdlSerializer.Read("sections { db { a \"1\" }; db { b \"2\" } }\ngroups { ui { - x }; ui { - y z } }", nested) case .Ok);
		Test.Assert(nested.Sections.Count == 1 && nested.Sections["db"].Count == 1 && nested.Sections["db"]["b"] == "2");
		Test.Assert(nested.Groups["ui"].Count == 1 && nested.Groups["ui"][0][1] == "z");
		Test.Assert(KdlSerializer.Read(cNested, nested) case .Ok);

		// Written and read back: the same values
		let text = scope String();
		Test.Assert(KdlSerializer.Write(nested, text) case .Ok);
		Test.Assert(text.Contains("matrix {\n    - 1 2 3\n    - 4\n    -\n}\n"), text);
		Test.Assert(text.Contains("by-id {\n") && text.Contains("\"1\" one") && text.Contains("\"-2\" minus-two"), text);
		Test.Assert(text.Contains("widths {\n") && text.Contains("start 10") && text.Contains("end-aligned 30"), text);
		let back = scope Nested();
		if (KdlSerializer.Read(text, back) case .Err(let backError))
			Test.Assert(false, scope $"{backError}\n{text}");
		Test.Assert(back.Matrix[0][2] == 3 && back.Paths[0][1].Y == 5 && back.Rows[1]["c"] == 3 && back.Sections["db"]["host"] == "localhost");
		Test.Assert(back.ById[-2] == "minus-two" && back.Widths[.EndAligned] == 30 && back.Groups["ui"][0][1] == "label");

		// In place: comments stay; a shorter list, a removed key, a changed nested value
		let doc = scope KdlDocument();
		doc.ReadConfig.MetadataMode = .PreserveStyle;
		Test.Assert(doc.Read("matrix {\n    // first row\n    - 1 2 3\n    - 0x10\n}\nsections {\n    db { host \"a\" } // main\n    old { x \"y\" }\n}\n") case .Ok);
		let edited = scope Nested();
		Test.Assert(edited.KdlRead(doc.Root) case .Ok);
		Test.Assert(edited.Matrix[1][0] == 16);
		edited.Matrix[1][0] = 32;
		edited.Matrix[0].RemoveAt(2);
		if (edited.Sections.GetAndRemoveAlt("old") case .Ok(let removed))
		{
			delete removed.key;
			DeleteDictionaryAndKeysAndValues!(removed.value);
		}
		edited.Sections["db"]["host"].Set("b");
		Test.Assert(edited.KdlWrite(doc.Root) case .Ok);
		let output = doc.Write(.. scope .());
		Test.Assert(output == "matrix {\n    // first row\n    - 1 2\n    - 0x20\n}\nsections {\n    db { host \"b\" } // main\n}\n", output);
	}

	[Test]
	public static void Nested_KeyErrors()
	{
		let nested = scope Nested();
		switch (KdlSerializer.Read("by-id {\n    one \"x\"\n}", nested))
		{
		case .Ok: Test.Assert(false, "`one` is not an integer key");
		case .Err(let error): Test.Assert(error.mKind == .InvalidValue && error.mLine == 2 && error.mMessage.Contains("not an integer"), error.ToString(.. scope .()));
		}
		switch (KdlSerializer.Read("widths {\n    middle 3\n}", nested))
		{
		case .Ok: Test.Assert(false, "`middle` is not an Align");
		case .Err(let error): Test.Assert(error.mKind == .InvalidValue && error.mLine == 2 && error.mMessage.Contains("start, center, end-aligned"), error.ToString(.. scope .()));
		}
		switch (KdlSerializer.Read("by-id {\n    \"99999999999\" \"x\"\n}", nested))
		{
		case .Ok: Test.Assert(false, "out of int32's range");
		case .Err(let error): Test.Assert(error.mKind == .InvalidValue && error.mMessage.Contains("outside the range"), error.ToString(.. scope .()));
		}
	}

	// Follow-up review (docs/review.md F1-F5)

	[Test]
	public static void F1_BoundariesAroundComments()
	{
		{
			// A block comment before a line continuation: the node ended at the end, not with a newline
			let doc = ReadPreserving(scope KdlDocument(), "b\na 1 /* c */ \\\n");
			doc.Nodes.Last.MoveBefore(doc.Nodes.First);
			AssertSameStructure(doc, "block comment before a line continuation");
		}
		{
			// A `//` comment the end of the input closed, moved into a block: the `}` must not follow it
			let doc = ReadPreserving(scope KdlDocument(), "p { a }\nb // last");
			doc.Nodes.Last.MoveInto(doc.Root.Find("p"));
			AssertSameStructure(doc, "a closing comment moved before a `}`");
		}
		{
			// And moved before a sibling
			let doc = ReadPreserving(scope KdlDocument(), "a\nb // last");
			doc.Nodes.Last.MoveBefore(doc.Nodes.First);
			AssertSameStructure(doc, "a closing comment moved before a node");
		}
		// Unchanged: byte for byte, whatever the comments hold
		for (let text in StringView[]("a /*\n\\ */\nb\n", "a // x \\\nb\n", "p { a /* } */ }\nq", "a \\ // c\n  1\nb"))
		{
			let doc = ReadPreserving(scope KdlDocument(), text);
			let output = doc.Write(.. scope .());
			Test.Assert(output == text, scope $"`{text}` written as `{output}`");
		}
	}

	[Test]
	public static void F2_ReplacingNullNestedItems()
	{
		let target = scope NestedNull();
		target.Values = new .();
		target.Values.Add(null);
		target.Values.Add(new .() { new .("old") });
		target.Maps = new .();
		target.Maps.Add(new .("gone"), null);
		Test.Assert(KdlSerializer.Read("values { - hello }\nmaps { m { k v } }", target) case .Ok);
		Test.Assert(target.Values.Count == 1 && target.Values[0][0] == "hello" && target.Maps["m"]["k"] == "v");

		// A failed read into containers holding nulls
		target.Values.Add(null);
		target.Maps.Add(new .("empty"), null);
		Test.Assert(KdlSerializer.Read("values { - a; - b }\nmaps { m { k 1 } }", target) case .Err);
	}

	[Test]
	public static void F3_BaseArgumentListAfterDerivedArgument()
	{
		let doc = scope KdlDocument();
		Test.Assert(doc.Read("n 1 2 3") case .Ok);
		let node = doc.Root.Find("n");
		let target = scope HeadDerived();
		Test.Assert(target.KdlRead(node) case .Ok);
		Test.Assert(target.Head == 1 && target.Rest.Count == 2 && target.Rest[0] == 2 && target.Rest[1] == 3);
		target.Head = 10;
		target.Rest.Clear();
		target.Rest.Add(20);
		target.Rest.Add(30);
		Test.Assert(target.KdlWrite(node) case .Ok);
		Test.Assert(doc.Write(.. scope .()) == "n 10 20 30\n", doc.Write(.. scope .()));
	}

	[Test]
	public static void F4_IntegerKeysAtTheirLimits()
	{
		let keys = scope IntegerKeys();
		keys.Signed = new .() { (int64.MinValue, 1), (int64.MaxValue, 2), (0, 3) };
		keys.Unsigned = new .() { (uint64.MaxValue, 4), (0, 5) };
		keys.Small = new .() { (-128, 6), (127, 7) };
		keys.Medium = new .() { (uint32.MaxValue, 8) };
		let text = scope String();
		Test.Assert(KdlSerializer.Write(keys, text) case .Ok);
		let back = scope IntegerKeys();
		if (KdlSerializer.Read(text, back) case .Err(let error))
			Test.Assert(false, scope $"{error}\n{text}");
		Test.Assert(back.Signed[int64.MinValue] == 1 && back.Signed[int64.MaxValue] == 2 && back.Signed[0] == 3);
		Test.Assert(back.Unsigned[uint64.MaxValue] == 4 && back.Unsigned[0] == 5);
		Test.Assert(back.Small[-128] == 6 && back.Small[127] == 7 && back.Medium[uint32.MaxValue] == 8);

		// Out of each type's range: located errors
		for (let bad in StringView[]("small { \"128\" 1 }", "small { \"-129\" 1 }", "medium { \"4294967296\" 1 }", "medium { \"-1\" 1 }",
			"unsigned { \"-1\" 1 }", "unsigned { \"18446744073709551616\" 1 }", "signed { \"9223372036854775808\" 1 }", "signed { \"-9223372036854775809\" 1 }"))
		{
			let target = scope IntegerKeys();
			switch (KdlSerializer.Read(bad, target))
			{
			case .Ok: Test.Assert(false, scope $"`{bad}` should be out of range");
			case .Err(let rangeError): Test.Assert(rangeError.mKind == .InvalidValue && rangeError.mLine == 1, scope $"`{bad}`: {rangeError}");
			}
		}
	}

	[Test]
	public static void F5_TokenLimitsBelowFour()
	{
		// A token at the end of the input: within the limit when it fills it exactly
		for (let buffer in int[](16, 1024))
		{
			for (let chunk in int[](1, 4096))
			{
				Test.Assert(!ReadsWithin("abc", buffer, chunk, 1) && !ReadsWithin("abc", buffer, chunk, 2), scope $"buffer {buffer}, chunk {chunk}");
				Test.Assert(ReadsWithin("abc", buffer, chunk, 3) && ReadsWithin("abc", buffer, chunk, 4));
				// With more after it the lookahead counts: `abc` then a newline is 4 bytes held
				Test.Assert(!ReadsWithin("abc\n", buffer, chunk, 3) && ReadsWithin("abc\n", buffer, chunk, 4));
				Test.Assert(!ReadsWithin("a\nbcd\n", buffer, chunk, 3) && ReadsWithin("a\nbcd\n", buffer, chunk, 5));
			}
		}
	}

	// Decimal big integers are normalized directly

	[Test]
	public static void BigIntegers_DecimalAndOtherRadixes()
	{
		let doc = scope KdlDocument();
		Test.Assert(doc.Read("n +000_123_456_789_012_345_678_901_234_567_890 -0_099999999999999999999 0x1_0000_0000_0000_0000 -0o2_000_000_000_000_000_000_000") case .Ok);
		Test.Assert(doc.Write(.. scope .()) == "n 123456789012345678901234567890 -99999999999999999999 18446744073709551616 -18446744073709551616\n", doc.Write(.. scope .()));
		// Long: linear in the digits
		let digits = scope String("n ");
		digits.Append('9', 200000);
		Test.Assert(doc.Read(digits) case .Ok);
		let written = doc.Write(.. scope .());
		Test.Assert(written.Length == 200000 + 3 && written.EndsWith("99\n"));
	}
}

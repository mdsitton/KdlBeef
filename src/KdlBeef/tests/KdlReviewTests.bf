using System;
using System.Collections;
using System.Globalization;
using KdlBeef;

namespace KdlBeef.Tests;

// Types for the typed-mapping regressions (R7, R9)

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

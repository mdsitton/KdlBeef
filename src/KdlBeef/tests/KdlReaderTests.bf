using System;
using KdlBeef;

namespace KdlBeef;

/// KdlReader events and the canonical form, for the rules in docs/spec-reference.md that the official
/// suite does not cover (or covers only through the canonical text).
static class KdlReaderTests
{
	static void AssertCanonical(StringView input, StringView expected)
	{
		let output = scope String();
		switch (KdlCanonical.Format(input, output))
		{
		case .Ok:
			Test.Assert(output == expected, scope $"Canonical form of `{input}`: got `{output}`, expected `{expected}`");
		case .Err(let error):
			Test.Assert(false, scope $"`{input}` failed: {error}");
		}
	}

	static void AssertError(StringView input, KdlErrorKind kind, int line, int column)
	{
		let output = scope String();
		switch (KdlCanonical.Format(input, output))
		{
		case .Ok:
			Test.Assert(false, scope $"`{input}` should fail, got `{output}`");
		case .Err(let error):
			Test.Assert(error.mKind == kind, scope $"`{input}`: expected {kind}, got {error.mKind}: {error}");
			Test.Assert(error.mLine == line && error.mColumn == column, scope $"`{input}`: expected {line}:{column}, got {error}");
		}
	}

	static void Expect(KdlReader reader, KdlEvent expected)
	{
		switch (reader.Next())
		{
		case .Ok(let event):
			Test.Assert(event == expected, scope $"Expected {expected}, got {event}");
		case .Err(let error):
			Test.Assert(false, scope $"Expected {expected}, got error {error}");
		}
	}

	static void ExpectValue(KdlReader reader, KdlEvent expected, KdlValue value)
	{
		Expect(reader, expected);
		switch (value)
		{
		case .String(let s):
			Test.Assert(reader.Value case .String(let actual) && actual == s, scope $"Expected string `{s}`");
		case .Integer(let v, let text):
			Test.Assert(reader.Value case .Integer(let actual, let actualText) && actual == v && actualText == text, scope $"Expected integer {v} `{text}`");
		case .BigInteger(let text):
			Test.Assert(reader.Value case .BigInteger(let actual) && actual == text, scope $"Expected big integer {text}");
		case .Float(let v, let text):
			Test.Assert(reader.Value case .Float(let actual, let actualText) && actual == v && actualText == text, scope $"Expected float {v} `{text}`");
		case .Bool(let v):
			Test.Assert(reader.Value case .Bool(let actual) && actual == v, scope $"Expected bool {v}");
		case .Null:
			Test.Assert(reader.Value case .Null, "Expected null");
		}
	}

	[Test]
	public static void Events_ReportNodesEntriesAndDepth()
	{
		let reader = scope KdlReader("a 1 k=v {\n    b\n    /- c { d }\n}\n/- e\nf (t)\"x\"");
		Expect(reader, .StartNode);
		Test.Assert(reader.Name == "a" && reader.Depth == 0 && !reader.HasAnnotation);
		ExpectValue(reader, .Argument, .Integer(1, "1"));
		ExpectValue(reader, .Property, .String("v"));
		Test.Assert(reader.Name == "k");
		Expect(reader, .StartNode);
		Test.Assert(reader.Name == "b" && reader.Depth == 1);
		Expect(reader, .EndNode);
		Test.Assert(reader.Depth == 1);
		Expect(reader, .EndNode);
		Test.Assert(reader.Depth == 0);
		Expect(reader, .StartNode);
		Test.Assert(reader.Name == "f");
		ExpectValue(reader, .Argument, .String("x"));
		Test.Assert(reader.HasAnnotation && reader.Annotation == "t");
		Expect(reader, .EndNode);
		Expect(reader, .EndOfDocument);
		Expect(reader, .EndOfDocument);
	}

	[Test]
	public static void Events_StringsViewTheInputWhenUnescaped()
	{
		StringView input = "n abc \"def\" #\"g\\h\"# \"i\\tj\"";
		let reader = scope KdlReader(input);
		Expect(reader, .StartNode);
		for (int i < 3)
		{
			Expect(reader, .Argument);
			Test.Assert(reader.Value case .String(let s) && s.Ptr >= input.Ptr && s.Ptr + s.Length <= input.Ptr + input.Length);
		}
		ExpectValue(reader, .Argument, .String("i\tj"));
		Test.Assert(reader.Value case .String(let escaped) && (escaped.Ptr < input.Ptr || escaped.Ptr >= input.Ptr + input.Length));
	}

	[Test]
	public static void Events_ErrorIsSticky_AndResetReuses()
	{
		let reader = scope KdlReader("a\nb \"unterminated");
		Expect(reader, .StartNode);
		Expect(reader, .EndNode);
		Expect(reader, .StartNode);
		Test.Assert(reader.Next() case .Err(let first) && first.mKind == .UnterminatedString && first.mLine == 2 && first.mColumn == 3);
		Test.Assert(reader.Next() case .Err(let again) && again.mKind == .UnterminatedString);

		reader.Reset("x");
		Expect(reader, .StartNode);
		Test.Assert(reader.Name == "x");
		Expect(reader, .EndNode);
		Expect(reader, .EndOfDocument);
	}

	[Test]
	public static void Slashdash_CommentsOutNodesEntriesAndChildren()
	{
		AssertCanonical("/- kdl-version 2\nnode", "node\n");
		AssertCanonical("node foo /-\nnot-a-node bar", "node foo bar\n");
		AssertCanonical("node 1 /- // stuff\n2 3", "node 1 3\n");
		AssertCanonical("node /--1.0 2.0", "node 2.0\n");
		AssertCanonical("node /- key=1 key=2", "node key=2\n");
		AssertCanonical("node foo /-{one} /-{two} {three} /-{four}", "node foo {\n    three\n}\n");
		AssertCanonical("/- a { b { c } }\nd", "d\n");
		AssertError("node /-", .InvalidSlashdash, 1, 6);
		AssertError("node /- /- 1", .InvalidSlashdash, 1, 9);
		AssertError("node { a } /- { b } { c }", .InvalidChildren, 1, 21);
	}

	[Test]
	public static void Whitespace_AllNewlinesAndUnicodeSpaces()
	{
		AssertCanonical("a\u{85}b\u{2028}c\u{2029}d\x0Be\x0Cf\rg\r\nh", "a\nb\nc\nd\ne\nf\ng\nh\n");
		AssertCanonical("a // comment\u{85}b /* multi\u{2028}line */ 1", "a\nb 1\n");
		AssertCanonical("a\u{3000}1\u{A0}2\u{2009}3", "a 1 2 3\n");
		AssertCanonical("a \\\n  1 \\ // comment\n  2", "a 1 2\n");
		AssertCanonical("a /* /* nested */ */ 1", "a 1\n");
		AssertCanonical("", "\n");
		AssertCanonical("\n\n// only a comment\n", "\n");
		AssertError("a \\ 1", .InvalidLineContinuation, 1, 3);
		AssertError("a /* unterminated", .UnterminatedComment, 1, 3);
	}

	[Test]
	public static void Encoding_BomAndDisallowedCodePoints()
	{
		AssertCanonical("\u{FEFF}node", "node\n");
		AssertError("node\u{FEFF}", .DisallowedCodePoint, 1, 5);
		AssertError("node \"\u{200E}\"", .DisallowedCodePoint, 1, 7);
		AssertError("a\n\x01", .DisallowedCodePoint, 2, 1);
		AssertError("a \xFF", .InvalidUtf8, 1, 3);
		// Escapes can still produce them, and the canonical writer escapes them again
		AssertCanonical("n \"\\u{85}\\u{b}\\u{200e}\\u{7f}\\u{0}\"", "n \"\\u{85}\\u{B}\\u{200E}\\u{7F}\\u{0}\"\n");
	}

	[Test]
	public static void Numbers_IntegersOfAnySize()
	{
		AssertCanonical("n 0b1010 0o17 0x1F +12 007 1_000 -0x10", "n 10 15 31 12 7 1000 -16\n");
		AssertCanonical("n 0xABCDEF0123456789abcdef", "n 207698809136909011942886895\n");
		AssertCanonical("n 0xabcdef1234567890 -0o7777777777777777777777777", "n 12379813812177893520 -37778931862957161709567\n");
		AssertCanonical("n 0b1111111111111111111111111111111111111111111111111111111111111111111111", "n 1180591620717411303423\n");

		let reader = scope KdlReader("n -9223372036854775808 9223372036854775807 9223372036854775808 0xFF_00_ff 0x_ab");
		Expect(reader, .StartNode);
		ExpectValue(reader, .Argument, .Integer(int64.MinValue, "-9223372036854775808"));
		ExpectValue(reader, .Argument, .Integer(int64.MaxValue, "9223372036854775807"));
		ExpectValue(reader, .Argument, .BigInteger("9223372036854775808"));
		// The value and the spelling a style-preserving writer keeps
		ExpectValue(reader, .Argument, .Integer(0xFF00FF, "0xFF_00_ff"));
		Test.Assert(reader.Next() case .Err(let error) && error.mKind == .InvalidNumber);
	}

	[Test]
	public static void Numbers_FloatsKeepTheirSpelling()
	{
		AssertCanonical("n 1.0 1e10 1.5E-3 +0.5 00.5 1_1.0_2e+0_1 -0.0", "n 1.0 1E+10 1.5E-3 0.5 0.5 11.02E+1 -0.0\n");
		AssertCanonical("n #inf #-inf #nan", "n #inf #-inf #nan\n");

		let reader = scope KdlReader("n 1.23E+1000 -1.5e-1000 2.5");
		Expect(reader, .StartNode);
		Expect(reader, .Argument);
		Test.Assert(reader.Value case .Float(let big, let bigText) && big == double.PositiveInfinity && bigText == "1.23E+1000");
		Expect(reader, .Argument);
		Test.Assert(reader.Value case .Float(let small, let smallText) && small == 0 && smallText == "-1.5e-1000");
		ExpectValue(reader, .Argument, .Float(2.5, "2.5"));

		AssertError("n 1.", .InvalidNumber, 1, 3);
		AssertError("n 1.e7", .InvalidNumber, 1, 3);
		AssertError("n 1e_5", .InvalidNumber, 1, 3);
		AssertError("n .5", .InvalidNumber, 1, 3);
		AssertError("n 0x", .InvalidNumber, 1, 3);
		AssertError("n 0X10", .InvalidNumber, 1, 3);
		AssertError("n 1.0.0", .InvalidNumber, 1, 3);
	}

	[Test]
	public static void Numbers_FastPathsMatchDoubleParse()
	{
		// The plain-float fast path must round exactly as Double.Parse does; so must the fallback
		let random = scope Random(12345);
		let input = scope String("n");
		let texts = scope System.Collections.List<String>();
		defer { ClearAndDeleteItems!(texts); }
		for (int i < 2000)
		{
			let text = new String();
			double mantissa = random.NextDouble() * Math.Pow(10, random.Next(0, 12));
			mantissa.ToString(text);
			if (!text.Contains('.') && !text.Contains('E') && !text.Contains('e'))
				text.Append(".5");
			switch (i % 4)
			{
			case 1: text.AppendF("e{}", random.Next(-30, 30));
			case 2: text.AppendF("E+{}", random.Next(0, 30));
			case 3: text.Insert(0, "-");
			default:
			}
			texts.Add(text);
			input.Append(' ');
			input.Append(text);
		}
		let reader = scope KdlReader(input);
		Expect(reader, .StartNode);
		for (let text in texts)
		{
			Expect(reader, .Argument);
			Test.Assert(reader.Value case .Float(let v, let written), scope $"`{text}` is not a float");
			Test.Assert(written == text);
			Test.Assert(v == double.Parse(text).Value, scope $"`{text}`: {v} vs {double.Parse(text).Value}");
		}
	}

	[Test]
	public static void Strings_EscapesAndIdentifiers()
	{
		AssertCanonical("n \"1\\\n\n\n2\"", "n \"12\"\n");
		AssertCanonical("n \"\\u{e9}t\\u{E9}\" \"\\s\" \"\\b\\f\"", "n été \" \" \"\\b\\f\"\n");
		AssertCanonical("n #\"\\\"# ###\"\"#\"##\"### #\"#\"#", "n \"\\\\\" \"\\\"#\\\"##\" \"#\"\n");
		AssertCanonical("n true_id -foo + - . +. .md \"1\" \"-1\" \".5\" \"\"", "n true_id -foo + - . +. .md \"1\" \"-1\" \".5\" \"\"\n");
		AssertError("n true", .InvalidKeyword, 1, 3);
		AssertError("n #yes", .InvalidKeyword, 1, 3);
		AssertError("n \"\\/\"", .InvalidEscape, 1, 4);
		AssertError("n \"\\u{0012345}\"", .InvalidEscape, 1, 4);
		AssertError("n \"\\u{D800}\"", .InvalidEscape, 1, 4);
		AssertError("n \"a\nb\"", .UnterminatedString, 1, 5);
		AssertError("n ##\"a\"#", .UnterminatedString, 1, 3);
	}

	[Test]
	public static void Strings_MultiLineDedentInSpecOrder()
	{
		// Literal newlines (CRLF included) become LF; whitespace-only lines become empty
		AssertCanonical("n \"\"\"\r\n  a\r\n\r\n    b\r\n  \"\"\"", "n \"a\\n\\n  b\"\n");
		// An escaped CRLF is kept
		AssertCanonical("n \"\"\"\n  a\\r\\nb\n  \"\"\"", "n \"a\\r\\nb\"\n");
		// `\s` is not literal whitespace, so it is not part of the prefix
		AssertCanonical("n \"\"\"\n  \\sa\n  \"\"\"", "n \" a\"\n");
		AssertCanonical("n \"\"\"\n\"\"\"", "n \"\"\n");
		AssertCanonical("n #\"\"\"\n    \"\"\"one\n    \"\"\"#", "n \"\\\"\\\"\\\"one\"\n");
		// A whitespace escape that pulls the closing quotes onto a content line
		AssertError("n \"\"\"\n  a \\\n  \"\"\"", .InvalidMultiLineString, 1, 3);
		AssertError("n \"\"\"one line\"\"\"", .InvalidMultiLineString, 1, 3);
		// Pointing at the line whose indentation differs
		AssertError("n \"\"\"\n\ta\n  \"\"\"", .InvalidMultiLineString, 2, 1);
		AssertError("n #\"\"\"#", .InvalidMultiLineString, 1, 3);
	}

	[Test]
	public static void Structure_EntriesAnnotationsAndBraces()
	{
		AssertCanonical("node{foo;bar;baz}", "node {\n    foo\n    bar\n    baz\n}\n");
		AssertCanonical("(t)node ( t2 )1 k = (t3)#true", "(t)node (t2)1 k=(t3)#true\n");
		AssertCanonical("n b=2 a=1 b=3 c", "n c a=1 b=3\n");
		AssertCanonical("n {}", "n\n");
		AssertError("node\"string\"", .MissingSpace, 1, 5);
		AssertError("node (type)key=10", .InvalidAnnotation, 1, 6);
		AssertError("node key=(type)", .UnexpectedEof, 1, 16);
		AssertError("node ()1", .InvalidAnnotation, 1, 6);
		AssertError("1 a", .ExpectedString, 1, 1);
		AssertError("a {\n  b\n", .UnbalancedBraces, 1, 3);
		AssertError("a }", .UnbalancedBraces, 1, 3);
		AssertError("a {} b", .InvalidChildren, 1, 6);
		AssertError("a;;", .UnexpectedChar, 1, 3);
	}
}

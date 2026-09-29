using System;
using KdlBeef;

namespace KdlBeef;

/// KdlReadConfig.CollectErrors: every error reported, the rest of the document read.
static class KdlCollectErrorsTests
{
	static KdlDocument ReadCollecting(KdlDocument doc, StringView input, int maxErrors = 100)
	{
		doc.ReadConfig.CollectErrors = true;
		doc.ReadConfig.MaxErrors = maxErrors;
		doc.Read(input).IgnoreError();
		return doc;
	}

	static void AssertError(KdlParseError error, KdlErrorKind kind, int line, int column)
	{
		Test.Assert(error.mKind == kind && error.mLine == line && error.mColumn == column,
			scope $"expected {kind} at {line}:{column}, got {error.mKind}: {error}");
	}

	[Test]
	public static void Document_KeepsWhatCouldBeRead()
	{
		StringView input = """
			window {
			    button "ok" on-click=save
			    label bad"text"
			    input (type)key=1
			    image src=#nope
			    footer 1.2.3 {
			        child
			    }
			    last
			}
			status
			""";
		let doc = ReadCollecting(scope KdlDocument(), input);
		Test.Assert(doc.Errors.Length == 4, scope $"{doc.Errors.Length} errors");
		AssertError(doc.Errors[0], .MissingSpace, 3, 14);
		AssertError(doc.Errors[1], .InvalidAnnotation, 4, 11);
		AssertError(doc.Errors[2], .InvalidKeyword, 5, 15);
		AssertError(doc.Errors[3], .InvalidNumber, 6, 12);
		// A node keeps the entries before its error; the rest of it, children included, is skipped
		let output = doc.Write(.. scope .());
		Test.Assert(output == "window {\n    button ok on-click=save\n    label bad\n    input\n    image\n    footer\n    last\n}\nstatus\n", output);

		// Read returns the first error; the messages live with the document
		Test.Assert(doc.Read(input) case .Err(let first));
		AssertError(first, .MissingSpace, 3, 14);
		Test.Assert(doc.Errors[3].mMessage.StartsWith("Invalid number `1.2.3`"));
	}

	[Test]
	public static void Recovery_SkipsStringsCommentsAndBlocks()
	{
		// The broken node's strings (multi-line too), comments and children blocks are stepped over, so
		// nothing in them is read as nodes
		StringView input = "a 1 2 x=) \"\"\"\n  not { a node\n  \"\"\" /* } { */ { child; } \"}\"\nb \"\\u{D800}\" 3\nc";
		let doc = ReadCollecting(scope KdlDocument(), input);
		Test.Assert(doc.Errors.Length == 2, scope $"{doc.Errors.Length} errors");
		let output = doc.Write(.. scope .());
		Test.Assert(output == "a 1 2\nb\nc\n", output);
	}

	[Test]
	public static void Braces_UnclosedAndStray()
	{
		let doc = ReadCollecting(scope KdlDocument(), "a {\n    b {\n        c 1");
		Test.Assert(doc.Errors.Length == 1);
		AssertError(doc.Errors[0], .UnbalancedBraces, 2, 7);
		Test.Assert(doc.Write(.. scope .()) == "a {\n    b {\n        c 1\n    }\n}\n");

		ReadCollecting(doc, "a\n}\nb }\nc");
		Test.Assert(doc.Errors.Length == 2);
		AssertError(doc.Errors[0], .UnbalancedBraces, 2, 1);
		AssertError(doc.Errors[1], .UnbalancedBraces, 3, 3);
		Test.Assert(doc.Write(.. scope .()) == "a\nb\nc\n");
	}

	[Test]
	public static void Stops_AtMaxErrorsAndFatalErrors()
	{
		let doc = ReadCollecting(scope KdlDocument(), "a #x\nb #y\nc #z\nd", 2);
		Test.Assert(doc.Errors.Length == 2);
		Test.Assert(doc.Write(.. scope .()) == "a\nb\n");

		// Encoding errors end the read
		let invalid = scope String("a #x\nb \"")..Append((char8)0xFF)..Append("\"\nc");
		ReadCollecting(doc, invalid);
		Test.Assert(doc.Errors.Length == 1 && doc.Errors[0].mKind == .InvalidUtf8);

		// So do resource limits
		doc.ReadConfig.MaxNodes = 2;
		ReadCollecting(doc, "a #x\nb\nc\nd");
		Test.Assert(doc.Errors.Length == 2 && doc.Errors[1].mKind == .ResourceLimitExceeded);
	}

	[Test]
	public static void Reader_ContinuesAfterAnError()
	{
		var config = KdlReadConfig();
		config.CollectErrors = true;
		let reader = scope KdlReader("a 1 #bad 2\nb 3", config);
		Test.Assert(reader.Next() case .Ok(.StartNode));
		Test.Assert(reader.Next() case .Ok(.Argument));
		Test.Assert(reader.Next() case .Err(let error) && error.mKind == .InvalidKeyword);
		Test.Assert(!reader.IsStopped);
		Test.Assert(reader.Next() case .Ok(.EndNode));
		Test.Assert(reader.Next() case .Ok(.StartNode) && reader.Name == "b");
		Test.Assert(reader.Next() case .Ok(.Argument) && reader.Value case .Integer(3, ?));
		Test.Assert(reader.Next() case .Ok(.EndNode));
		Test.Assert(reader.Next() case .Ok(.EndOfDocument));

		// Without CollectErrors the first error stops the read
		reader.Reset("a #bad\nb");
		Test.Assert(reader.Next() case .Ok(.StartNode));
		Test.Assert(reader.Next() case .Err);
		Test.Assert(reader.IsStopped && reader.Next() case .Err);
	}
}

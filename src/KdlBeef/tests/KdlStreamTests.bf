using System;
using System.IO;
using KdlBeef;

namespace KdlBeef;

/// Reading from a Stream (KdlBufferedStreamCursor): the same documents, errors and positions as from
/// memory, whatever the buffer size and however the stream splits its reads.
static class KdlStreamTests
{
	/// A stream over text that returns at most `chunk` bytes per read, and fails once `failAt` bytes
	/// have been read (if set).
	class TrickleStream : Stream
	{
		StringView mData;
		int mPos;
		int mChunk;
		int mFailAt;

		public this(StringView data, int chunk, int failAt = -1)
		{
			mData = data;
			mChunk = chunk;
			mFailAt = failAt;
		}

		public override int64 Position
		{
			get => mPos;
			set => mPos = (int)value;
		}
		public override int64 Length => mData.Length;
		public override bool CanRead => true;
		public override bool CanWrite => false;

		public override Result<int> TryRead(Span<uint8> data)
		{
			if (mFailAt >= 0 && mPos >= mFailAt)
				return .Err;
			int n = Math.Min(Math.Min(mChunk, data.Length), mData.Length - mPos);
			if (mFailAt >= 0)
				n = Math.Min(n, mFailAt - mPos);
			Internal.MemCpy(data.Ptr, mData.Ptr + mPos, n);
			mPos += n;
			return n;
		}

		public override Result<int> TryWrite(Span<uint8> data) => .Err;
		public override Result<void> Close() => .Ok;
	}

	/// A document with something at every kind of boundary a refill can split.
	static void BuildSample(String input)
	{
		input.Append("\u{FEFF}// header comment\r\n");
		input.Append("window title=\"Main — é\" {\r\n");
		input.Append("    label \"a\\tb\\u{1F600}\" width=(px)12 /* a /* nested */ comment */ height=3\n");
		input.Append("    text \"\"\"\n        line one\r\n          line two\n        \"\"\"\n");
		input.Append("    raw #\"C:\\path\"# big=0xABCDEF0123456789abcdef f=1.5e10\u{85}");
		input.Append("    /- skipped { a; b }\n");
		input.Append("    long \"");
		input.Append('x', 300);
		input.Append("\" k=\\\n        continued \"ws\\   \n   escape\"\n");
		input.Append("    ünï \u{3000}(t)#true #-inf ;\n}\n");
	}

	static void AssertSameAsMemory(StringView input, int chunk, int buffer)
	{
		let expected = scope KdlDocument();
		Test.Assert(expected.Read(input) case .Ok);
		let expectedText = expected.Write(.. scope .());

		var config = KdlReadConfig();
		config.StreamBufferBytes = buffer;
		let doc = scope KdlDocument();
		let stream = scope TrickleStream(input, chunk);
		switch (doc.Read(stream, config))
		{
		case .Ok:
			let text = doc.Write(.. scope .());
			Test.Assert(text == expectedText, scope $"chunk {chunk}, buffer {buffer}: got\n{text}\nexpected\n{expectedText}");
		case .Err(let error):
			Test.Assert(false, scope $"chunk {chunk}, buffer {buffer}: {error}");
		}
	}

	[Test]
	public static void Documents_SameAsFromMemory()
	{
		let input = BuildSample(.. scope .());
		for (let chunk in int[](1, 2, 3, 7, 64, 4096))
		{
			for (let buffer in int[](16, 17, 64, 1000, 0))
				AssertSameAsMemory(input, chunk, buffer);
		}
	}

	static void AssertSameError(StringView input, int chunk, int buffer)
	{
		let memory = scope KdlDocument();
		Test.Assert(memory.Read(input) case .Err(let expected), scope $"`{input}` should fail");
		let expectedText = expected.ToString(.. scope .());

		var config = KdlReadConfig();
		config.StreamBufferBytes = buffer;
		let doc = scope KdlDocument();
		switch (doc.Read(scope TrickleStream(input, chunk), config))
		{
		case .Ok:
			Test.Assert(false, scope $"chunk {chunk}, buffer {buffer}: `{input}` should fail");
		case .Err(let error):
			let text = error.ToString(.. scope .());
			Test.Assert(text == expectedText && error.mKind == expected.mKind && error.mOffset == expected.mOffset,
				scope $"chunk {chunk}, buffer {buffer}: got `{text}`, expected `{expectedText}`");
		}
		Test.Assert(doc.Nodes.IsEmpty);
	}

	[Test]
	public static void Errors_SameAsFromMemory()
	{
		let padding = scope String();
		for (int i < 20)
			padding.Append("node \"padding\" 1 2 3\n");
		for (let tail in StringView[](
			"bad \"unterminated",
			"x \"\\u{D800}\"",
			"a { b",
			"a }",
			"n 0x10g10",
			"bidi \u{200E}here",
			"n \"\"\"\n  a\n\t\"\"\"",
			"n #\"never closed"))
		{
			let input = scope String()..Append(padding)..Append(tail);
			for (let chunk in int[](1, 5, 4096))
			{
				for (let buffer in int[](16, 64, 0))
					AssertSameError(input, chunk, buffer);
			}
		}
		// Invalid UTF-8 after the first buffer is found as the stream is read
		let invalid = scope String()..Append(padding)..Append("n \"")..Append((char8)0xC3)..Append((char8)0x28)..Append('"');
		AssertSameError(invalid, 3, 16);
	}

	[Test]
	public static void Limits_TokenAndInputSize()
	{
		let input = scope String("a 1\nlong \"");
		input.Append('x', 200);
		input.Append("\"\nb 2\n");

		var config = KdlReadConfig();
		config.StreamBufferBytes = 16;
		config.MaxTokenBytes = 64;
		let doc = scope KdlDocument();
		Test.Assert(doc.Read(scope TrickleStream(input, 7), config) case .Err(let tokenError));
		Test.Assert(tokenError.mKind == .ResourceLimitExceeded, tokenError.ToString(.. scope .()));

		// The limit is on one construct, not the input: short ones stream through a 16-byte buffer
		config.MaxTokenBytes = 250;
		Test.Assert(doc.Read(scope TrickleStream(input, 7), config) case .Ok);
		Test.Assert(doc.Nodes.Count == 3);

		config = .();
		config.StreamBufferBytes = 16;
		config.MaxInputBytes = 100;
		Test.Assert(doc.Read(scope TrickleStream(input, 7), config) case .Err(let inputError));
		Test.Assert(inputError.mKind == .ResourceLimitExceeded, inputError.ToString(.. scope .()));
	}

	[Test]
	public static void Io_FailureIsReported()
	{
		let input = scope String();
		for (int i < 10)
			input.Append("node 1 2 3\n");
		var config = KdlReadConfig();
		config.StreamBufferBytes = 16;
		config.SourceName = "net.kdl";
		let doc = scope KdlDocument();
		Test.Assert(doc.Read(scope TrickleStream(input, 5, 40), config) case .Err(let error));
		Test.Assert(error.mKind == .IoError && error.mSource == "net.kdl", error.ToString(.. scope .()));
		Test.Assert(doc.Nodes.IsEmpty);
	}

	[Test]
	public static void Positions_SameAsFromMemory()
	{
		let input = BuildSample(.. scope .());
		let memory = scope KdlDocument();
		memory.ReadConfig.MetadataMode = .Positions;
		Test.Assert(memory.Read(input) case .Ok);

		let doc = scope KdlDocument();
		doc.ReadConfig.MetadataMode = .Positions;
		doc.ReadConfig.StreamBufferBytes = 16;
		Test.Assert(doc.Read(scope TrickleStream(input, 3)) case .Ok);

		let expected = memory.Nodes.First.FirstChild;
		let actual = doc.Nodes.First.FirstChild;
		var e = expected;
		var a = actual;
		while (e.IsValid)
		{
			Test.Assert(a.IsValid);
			Test.Assert(e.TryGetSourceRange(let er));
			Test.Assert(a.TryGetSourceRange(let ar));
			Test.Assert(er.mLine == ar.mLine && er.mColumn == ar.mColumn && er.mOffset == ar.mOffset && er.mLength == ar.mLength,
				scope $"{e.Name}: {er} ({er.mLength}) vs {ar} ({ar.mLength})");
			for (int i < e.Entries.Count)
			{
				Test.Assert(e.Entries[i].TryGetSourceRange(let eer));
				Test.Assert(a.Entries[i].TryGetSourceRange(let aer));
				Test.Assert(eer.mLine == aer.mLine && eer.mColumn == aer.mColumn && eer.mLength == aer.mLength);
			}
			e = e.NextSibling;
			a = a.NextSibling;
		}
	}

	[Test]
	public static void Reader_EventsFromAStream()
	{
		let input = scope String("first key=\"value one\" 42 {\n    child (t)\"");
		input.Append('y', 100);
		input.Append("\"\n}\n");
		var config = KdlReadConfig();
		config.StreamBufferBytes = 16;
		let reader = scope KdlReader();
		reader.Reset(scope TrickleStream(input, 3), config);
		Test.Assert(reader.Next() case .Ok(.StartNode) && reader.Name == "first");
		Test.Assert(reader.Next() case .Ok(.Property) && reader.Name == "key" && reader.Value case .String("value one"));
		Test.Assert(reader.Next() case .Ok(.Argument) && reader.Value case .Integer(42, ?));
		Test.Assert(reader.Next() case .Ok(.StartNode) && reader.Name == "child");
		Test.Assert(reader.Next() case .Ok(.Argument) && reader.HasAnnotation && reader.Annotation == "t");
		Test.Assert(reader.Value case .String(let long) && long.Length == 100 && long[99] == 'y');
		Test.Assert(reader.Next() case .Ok(.EndNode) && reader.Depth == 1);
		Test.Assert(reader.Next() case .Ok(.EndNode) && reader.Depth == 0);
		Test.Assert(reader.Next() case .Ok(.EndOfDocument));
	}
}

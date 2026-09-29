using System;
using System.Collections;
using internal KdlBeef;

namespace KdlBeef;

/// @brief What KdlReader.Next reached.
public enum KdlEvent : uint8
{
	/// @brief The end of the document: every node has ended. Further calls return it again.
	EndOfDocument,
	/// @brief A node begins: `Name`, `Depth` and the node's annotation are set. Its arguments and
	/// properties follow in source order, then its children's events, then its EndNode.
	StartNode,
	/// @brief An argument of the current node: `Value` and the value's annotation are set.
	Argument,
	/// @brief A property of the current node: `Name` is the key; `Value` and the value's annotation
	/// are set. Duplicate keys are all reported, in source order (the last one wins).
	Property,
	/// @brief The current node ends, after its children if it has any.
	EndNode
}

/// A pull reader over a KDL 2.0 document: each call to `Next` reads up to the next event and reports
/// it. It builds no document and allocates nothing per node; the event's strings (`Name`,
/// `Annotation`, `Value`) are views into the input or into the reader's buffers, valid until the next
/// call to `Next` or `Reset`.
///
/// Everything is validated, including slashdashed (`/-`) nodes, entries and children blocks, which
/// produce no events. The first error ends the read: `Next` returns it again on every later call.
///
/// ```
/// let reader = scope KdlReader(text);
/// while (true)
/// {
///     switch (Try!(reader.Next()))
///     {
///     case .StartNode: Console.WriteLine(reader.Name);
///     case .EndOfDocument: return .Ok;
///     default:
///     }
/// }
/// ```
public class KdlReader
{
	enum State : uint8
	{
		/// Not validated yet.
		Start,
		/// Between nodes: before a node, a `}` or the end.
		Nodes,
		/// Inside a node, after its name or an entry: before an entry, a children block or a terminator.
		Entries,
		End,
		Failed
	}

	/// An open node.
	struct Frame
	{
		/// 0: arguments and properties may follow; 1: after a slashdashed children block (only children
		/// blocks may follow); 2: after the children block (only slashdashed ones may follow).
		public uint8 mPhase;
		/// The node is slashdashed.
		public bool mSlashdashed;
		/// Its open children block is slashdashed.
		public bool mChildrenSlashdashed;
		/// Offset of its open children block's `{`, for the unclosed-block error.
		public int32 mBraceOffset;
	}

	StringView mInput;
	char8* mData;
	int mPos;
	int mEnd;
	State mState;
	/// The open nodes, innermost last. While between nodes, every one of them has its children block open.
	List<Frame> mFrames ~ delete _;
	/// How many slashdashed constructs enclose the position; events are reported only at 0.
	int mSuppressed;
	/// The property lookahead after the last argument consumed the whitespace before the next entry.
	bool mPendingSpace;
	KdlParseError mError;

	String mNameBuffer ~ delete _;
	String mAnnotationBuffer ~ delete _;
	String mValueBuffer ~ delete _;

	StringView mName;
	StringView mAnnotation;
	bool mHasAnnotation;
	KdlValue mValue;
	int mDepth;
	int mEventOffset;

	/// @brief Create a reader with no input; call Reset before reading.
	public this()
	{
		mFrames = new .();
		mNameBuffer = new .();
		mAnnotationBuffer = new .();
		mValueBuffer = new .();
	}

	/// @brief Create a reader over `input`, which must outlive the reader's use of it.
	/// @param input The document text (UTF-8; a leading BOM is skipped).
	public this(StringView input) : this()
	{
		Reset(input);
	}

	/// @brief Start reading `input` from the beginning, reusing the reader's buffers.
	/// @param input The document text (UTF-8; a leading BOM is skipped).
	public void Reset(StringView input)
	{
		mInput = input;
		mData = input.Ptr;
		mPos = 0;
		mEnd = input.Length;
		mState = .Start;
		mFrames.Clear();
		mSuppressed = 0;
		mPendingSpace = false;
		mName = default;
		mAnnotation = default;
		mHasAnnotation = false;
		mValue = .Null;
		mDepth = 0;
		mEventOffset = 0;
	}

	/// @brief StartNode: the node's name. Property: the key.
	public StringView Name => mName;
	/// @brief Whether the node (StartNode) or value (Argument, Property) has a `(type)` annotation.
	public bool HasAnnotation => mHasAnnotation;
	/// @brief The annotation's text when HasAnnotation (it may be empty: `("")`).
	public StringView Annotation => mAnnotation;
	/// @brief Argument, Property: the value.
	public KdlValue Value => mValue;
	/// @brief The depth of the node the event belongs to: 0 for top-level nodes.
	public int Depth => mDepth;
	/// @brief Byte offset into the input where the event's construct starts (the node or entry,
	/// including its annotation; for EndNode, its terminator).
	public int Offset => mEventOffset;

	/// @brief Read up to the next event.
	/// @return The event, or the first error in the document.
	public Result<KdlEvent, KdlParseError> Next()
	{
		if (mState == .Failed)
			return .Err(mError);
		let result = ReadNext();
		if (result case .Err(let error))
		{
			mState = .Failed;
			mError = error;
		}
		return result;
	}

	Result<KdlEvent, KdlParseError> ReadNext()
	{
		if (mState == .Start)
		{
			Try!(KdlChar.ValidateDocument(mInput, let start));
			mPos = start;
			mState = .Nodes;
		}
		while (true)
		{
			switch (mState)
			{
			case .Nodes:
				Try!(SkipLineSpace());
				if (mPos >= mEnd)
				{
					if (mFrames.Count > 0)
						return .Err(Fail(.UnbalancedBraces, "Expected `}` to close this children block", mFrames.Back.mBraceOffset));
					mState = .End;
					mDepth = 0;
					mEventOffset = mPos;
					return .Ok(.EndOfDocument);
				}
				char8 b = mData[mPos];
				if (b == '}')
				{
					if (mFrames.Count == 0)
						return .Err(Fail(.UnbalancedBraces, "Unexpected `}` without a matching `{`", mPos));
					mPos++;
					ref Frame frame = ref mFrames.Back;
					if (frame.mChildrenSlashdashed)
					{
						frame.mChildrenSlashdashed = false;
						mSuppressed--;
						if (frame.mPhase == 0)
							frame.mPhase = 1;
					}
					else
						frame.mPhase = 2;
					mState = .Entries;
					mPendingSpace = false;
					continue;
				}
				int nodeStart = mPos;
				bool slashdash = false;
				if (b == '/' && PeekAt(1) == '-')
				{
					Try!(ReadSlashdash());
					slashdash = true;
				}
				Try!(ReadNodeHead());
				Frame opened = default;
				opened.mSlashdashed = slashdash;
				mFrames.Add(opened);
				if (slashdash)
					mSuppressed++;
				mState = .Entries;
				mPendingSpace = false;
				if (mSuppressed == 0)
				{
					mDepth = mFrames.Count - 1;
					mEventOffset = nodeStart;
					return .Ok(.StartNode);
				}

			case .Entries:
				bool space = mPendingSpace;
				mPendingSpace = false;
				if (Try!(SkipNodeSpace()))
					space = true;
				if (mPos >= mEnd)
				{
					if (EndNode())
						return .Ok(.EndNode);
					continue;
				}
				char8 c = mData[mPos];
				int terminatorStart = mPos;
				int newline = KdlChar.NewlineLength(mData, mPos, mEnd);
				bool terminated = true;
				if (newline > 0)
					mPos += newline;
				else if (c == ';')
					mPos++;
				else if (c == '/' && PeekAt(1) == '/')
					SkipSingleLineComment();
				else if (c == '}')
				{
					// The parent's `}` ends the node; the Nodes state consumes it
					if (mFrames.Count < 2)
						return .Err(Fail(.UnbalancedBraces, "Unexpected `}` without a matching `{`", mPos));
				}
				else
					terminated = false;
				if (terminated)
				{
					mEventOffset = terminatorStart;
					if (EndNode())
						return .Ok(.EndNode);
					continue;
				}

				ref Frame current = ref mFrames.Back;
				if (c == '/' && PeekAt(1) == '-')
				{
					Try!(ReadSlashdash());
					if (mData[mPos] == '{')
					{
						current.mChildrenSlashdashed = true;
						current.mBraceOffset = (int32)mPos;
						mSuppressed++;
						mPos++;
						mState = .Nodes;
						continue;
					}
					if (current.mPhase != 0)
						return .Err(Fail(.InvalidChildren, "Arguments and properties must come before the node's children blocks", mPos));
					if (!CanStartValue(mPos) && mData[mPos] != '(')
						return .Err(Unexpected("an argument, property or children block after `/-`"));
					mSuppressed++;
					Try!(ReadEntry());
					mSuppressed--;
					continue;
				}
				if (c == '{')
				{
					if (current.mPhase == 2)
						return .Err(Fail(.InvalidChildren, "A node can have only one children block; slashdash (`/-`) the others", mPos));
					current.mBraceOffset = (int32)mPos;
					mPos++;
					mState = .Nodes;
					continue;
				}
				if (!CanStartValue(mPos) && c != '(')
					return .Err(Unexpected("an argument, property, children block or the end of the node"));
				if (current.mPhase != 0)
					return .Err(Fail(.InvalidChildren, "Arguments and properties must come before the node's children block", mPos));
				if (!space)
					return .Err(Fail(.MissingSpace, "Expected whitespace before this argument or property", mPos));
				int entryStart = mPos;
				let event = Try!(ReadEntry());
				if (mSuppressed == 0)
				{
					mDepth = mFrames.Count - 1;
					mEventOffset = entryStart;
					return .Ok(event);
				}

			case .End:
				return .Ok(.EndOfDocument);

			case .Start, .Failed:
				Runtime.FatalError("KdlReader: unreachable state");
			}
		}
	}

	/// Pops the current node. @return Whether an EndNode event is due.
	bool EndNode()
	{
		Frame frame = mFrames.PopBack();
		mState = .Nodes;
		if (frame.mSlashdashed)
		{
			mSuppressed--;
			return false;
		}
		if (mSuppressed > 0)
			return false;
		mDepth = mFrames.Count;
		return true;
	}

	/// Consumes `/-` and the line-space after it, which must lead to something to comment out.
	Result<void, KdlParseError> ReadSlashdash()
	{
		int start = mPos;
		mPos += 2;
		Try!(SkipLineSpace());
		if (mPos < mEnd && mData[mPos] == '/' && PeekAt(1) == '-')
			return .Err(Fail(.InvalidSlashdash, "A slashdash `/-` cannot be followed by another slashdash", mPos, 2));
		if (mPos >= mEnd || mData[mPos] == '}' || mData[mPos] == ';')
			return .Err(Fail(.InvalidSlashdash, "A slashdash `/-` must be followed by a node, argument, property or children block", start, 2));
		return .Ok;
	}

	/// Reads a node's `(type)` and name.
	Result<void, KdlParseError> ReadNodeHead()
	{
		mHasAnnotation = false;
		if (mData[mPos] == '(')
		{
			Try!(ReadAnnotation());
			Try!(SkipNodeSpace());
		}
		else if (!CanStartValue(mPos))
			return .Err(Unexpected("a node"));
		int nameStart = mPos;
		KdlValue name = Try!(ReadValue(mNameBuffer));
		if (!name.TryGetString(out mName))
			return .Err(Fail(.ExpectedString, "A node name must be a string; quote it", nameStart, mPos - nameStart));
		return .Ok;
	}

	/// Reads `( node-space* string node-space* )` into the annotation.
	Result<void, KdlParseError> ReadAnnotation()
	{
		int start = mPos;
		mPos++;
		Try!(SkipNodeSpace());
		if (mPos < mEnd && mData[mPos] == ')')
			return .Err(Fail(.InvalidAnnotation, "A type annotation cannot be empty", start, mPos + 1 - start));
		int typeStart = mPos;
		KdlValue type = Try!(ReadValue(mAnnotationBuffer));
		if (!type.TryGetString(out mAnnotation))
			return .Err(Fail(.ExpectedString, "A type annotation must be a string; quote it", typeStart, mPos - typeStart));
		Try!(SkipNodeSpace());
		if (mPos >= mEnd || mData[mPos] != ')')
			return .Err(Unexpected("`)` to close the type annotation"));
		mPos++;
		mHasAnnotation = true;
		return .Ok;
	}

	/// Reads an argument or a property: `value`, or `string node-space* = node-space* value`.
	Result<KdlEvent, KdlParseError> ReadEntry()
	{
		int start = mPos;
		mHasAnnotation = false;
		bool annotated = false;
		if (mData[mPos] == '(')
		{
			Try!(ReadAnnotation());
			annotated = true;
			Try!(SkipNodeSpace());
		}
		int tokenStart = mPos;
		KdlValue value = Try!(ReadValue(mNameBuffer));
		int tokenEnd = mPos;
		// Space before a `=` belongs to the property; otherwise it separates this argument from the next entry
		bool space = Try!(SkipNodeSpace());
		if (mPos < mEnd && mData[mPos] == '=')
		{
			if (!value.TryGetString(out mName))
				return .Err(Fail(.ExpectedString, "A property key must be a string; quote it", tokenStart, tokenEnd - tokenStart));
			if (annotated)
				return .Err(Fail(.InvalidAnnotation, "A type annotation cannot annotate a property key; annotate the value instead (`key=(type)value`)", start, tokenEnd - start));
			mPos++;
			Try!(SkipNodeSpace());
			mHasAnnotation = false;
			if (mPos < mEnd && mData[mPos] == '(')
			{
				Try!(ReadAnnotation());
				Try!(SkipNodeSpace());
			}
			mValue = Try!(ReadValue(mValueBuffer));
			return .Ok(.Property);
		}
		mValue = value;
		mPendingSpace = space;
		return .Ok(.Argument);
	}

	// Whitespace and comments

	/// Skips `ws*` (Unicode spaces and `/* */` comments). @return Whether anything was skipped.
	Result<bool, KdlParseError> SkipWhitespace()
	{
		int begin = mPos;
		while (mPos < mEnd)
		{
			int n = KdlChar.UnicodeSpaceLength(mData, mPos, mEnd);
			if (n > 0)
			{
				mPos += n;
				continue;
			}
			if (mData[mPos] == '/' && PeekAt(1) == '*')
			{
				Try!(SkipBlockComment());
				continue;
			}
			break;
		}
		return mPos != begin;
	}

	/// Skips a `/* */` comment, which nests.
	Result<void, KdlParseError> SkipBlockComment()
	{
		int start = mPos;
		mPos += 2;
		int depth = 1;
		while (mPos < mEnd)
		{
			char8 b = mData[mPos];
			if (b == '*' && PeekAt(1) == '/')
			{
				mPos += 2;
				if (--depth == 0)
					return .Ok;
				continue;
			}
			if (b == '/' && PeekAt(1) == '*')
			{
				mPos += 2;
				depth++;
				continue;
			}
			mPos++;
		}
		return .Err(Fail(.UnterminatedComment, "Unterminated comment: expected `*/`", start, 2));
	}

	/// Skips a `//` comment and the newline that ends it.
	void SkipSingleLineComment()
	{
		mPos += 2;
		while (mPos < mEnd)
		{
			// Newline lead bytes never occur inside a multi-byte sequence, so stepping bytes is safe
			int n = KdlChar.NewlineLength(mData, mPos, mEnd);
			if (n > 0)
			{
				mPos += n;
				return;
			}
			mPos++;
		}
	}

	/// Skips `node-space*`: whitespace, and line continuations (`\` then a newline or `//` comment).
	/// @return Whether anything was skipped.
	Result<bool, KdlParseError> SkipNodeSpace()
	{
		bool any = false;
		while (true)
		{
			if (Try!(SkipWhitespace()))
				any = true;
			if (mPos >= mEnd || mData[mPos] != '\\')
				return any;
			int start = mPos;
			mPos++;
			Try!(SkipWhitespace());
			if (mPos < mEnd)
			{
				if (mData[mPos] == '/' && PeekAt(1) == '/')
					SkipSingleLineComment();
				else
				{
					int n = KdlChar.NewlineLength(mData, mPos, mEnd);
					if (n == 0)
						return .Err(Fail(.InvalidLineContinuation, "A line continuation `\\` must be followed by a newline or a `//` comment", start));
					mPos += n;
				}
			}
			any = true;
		}
	}

	/// Skips `line-space*`: node-space, newlines and `//` comments.
	Result<void, KdlParseError> SkipLineSpace()
	{
		while (true)
		{
			Try!(SkipNodeSpace());
			if (mPos >= mEnd)
				return .Ok;
			int n = KdlChar.NewlineLength(mData, mPos, mEnd);
			if (n > 0)
			{
				mPos += n;
				continue;
			}
			if (mData[mPos] == '/' && PeekAt(1) == '/')
			{
				SkipSingleLineComment();
				continue;
			}
			return .Ok;
		}
	}

	// Helpers

	[Inline]
	char8 PeekAt(int lookahead)
	{
		int pos = mPos + lookahead;
		return pos < mEnd ? mData[pos] : 0;
	}

	[Inline]
	StringView View(int start, int length)
	{
		return StringView(mData + start, length);
	}

	/// Whether a string, number or keyword can start at `pos`.
	bool CanStartValue(int pos)
	{
		if (pos >= mEnd)
			return false;
		char8 b = mData[pos];
		if (b == '"' || b == '#')
			return true;
		if ((uint8)b < 0x80)
			return KdlChar.IsIdentifierAscii(b);
		return KdlChar.IsIdentifierChar(KdlChar.Decode(mData, pos, var length));
	}

	KdlParseError Fail(KdlErrorKind kind, StringView message, int offset, int length = 1)
	{
		return KdlParseError.At(kind, message, mInput, offset, length);
	}

	/// "Expected X, found Y" at the current position.
	KdlParseError Unexpected(StringView expected)
	{
		let message = scope String();
		message.Append("Expected ");
		message.Append(expected);
		message.Append(", found ");
		if (mPos >= mEnd)
		{
			message.Append("the end of the input");
			return Fail(.UnexpectedEof, message, mPos, 0);
		}
		int length = 1;
		if (KdlChar.NewlineLength(mData, mPos, mEnd) > 0)
			message.Append("a newline");
		else
		{
			char32 cp = KdlChar.Decode(mData, mPos, out length);
			if ((uint32)cp < 0x20 || KdlChar.IsUnicodeSpace(cp))
				KdlChar.AppendCodePointName(message, (uint32)cp);
			else
			{
				message.Append('`');
				message.Append(View(mPos, length));
				message.Append('`');
			}
		}
		return Fail(.UnexpectedChar, message, mPos, length);
	}
}

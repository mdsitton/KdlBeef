using System;
using System.Collections;
using System.IO;
using internal KdlBeef;

namespace KdlBeef;

/// The error type of the reader's internal methods: empty, so their results are no bigger than their
/// values (a KdlParseError in every Result was copied on each return, a measurable cost). The error
/// itself is recorded in the reader by Fail, and Next returns it.
internal struct KdlFailure
{
}

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
/// The input is text in memory, or a Stream read through a buffer (memory stays bounded by the
/// buffer and the longest construct). Everything is validated, including slashdashed (`/-`) nodes,
/// entries and children blocks, which produce no events. The first error ends the read: `Next`
/// returns it again on every later call. An in-memory input is checked for encoding errors before the
/// first event; a stream as it is read, so events may come before an encoding error further on, and a
/// document with both a syntax error and a later encoding error reports the encoding error from
/// memory but the syntax error from a stream (that fits no buffer). Otherwise both give the same
/// events and errors.
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
	KdlReaderCore<KdlByteCursor> mBytes ~ delete _;
	KdlReaderCore<KdlBufferedStreamCursor> mStream ~ delete _;
	KdlStreamState mStreamState ~ delete _;
	bool mStreaming;

	/// @brief Create a reader with no input; call Reset before reading.
	public this()
	{
		mBytes = new .();
	}

	/// @brief Create a reader over `input`, which must outlive the reader's use of it.
	/// @param input The document text (UTF-8; a leading BOM is skipped).
	public this(StringView input) : this()
	{
		Reset(input);
	}

	/// @brief Create a reader over `input` with limits and a source name.
	/// @param input The document text (UTF-8; a leading BOM is skipped).
	/// @param config The limits and source name. MetadataMode matters only as PreserveStyle, which makes
	/// the reader keep each event's source text (for KdlDocument; it holds more of a stream at once).
	public this(StringView input, KdlReadConfig config) : this()
	{
		Reset(input, config);
	}

	/// @brief Start reading `input` from the beginning with the default config, reusing the reader's
	/// buffers.
	/// @param input The document text (UTF-8; a leading BOM is skipped).
	public void Reset(StringView input)
	{
		Reset(input, .());
	}

	/// @brief Start reading `input` from the beginning, reusing the reader's buffers.
	/// @param input The document text (UTF-8; a leading BOM is skipped).
	/// @param config The limits and source name (MetadataMode: see the constructor). The source name is
	/// only viewed: it must outlive the read.
	public void Reset(StringView input, KdlReadConfig config)
	{
		mStreaming = false;
		mBytes.Reset(KdlByteCursor(input, config), config);
	}

	/// @brief Start reading a stream with the default config.
	/// @param stream The document (UTF-8; a leading BOM is skipped); read from its current position,
	/// and must outlive the reader's use of it.
	public void Reset(Stream stream)
	{
		Reset(stream, .());
	}

	/// @brief Start reading a stream through a buffer of `config.StreamBufferBytes` (see also
	/// `config.MaxTokenBytes`).
	/// @param stream The document (UTF-8; a leading BOM is skipped); read from its current position,
	/// and must outlive the reader's use of it.
	/// @param config The limits, buffer size and source name (MetadataMode: see the constructor).
	public void Reset(Stream stream, KdlReadConfig config)
	{
		mStreaming = true;
		if (mStream == null)
		{
			mStream = new .();
			mStreamState = new .();
		}
		mStream.Reset(KdlBufferedStreamCursor(stream, mStreamState, config), config);
	}

	/// @brief StartNode: the node's name. Property: the key.
	public StringView Name => mStreaming ? mStream.mName : mBytes.mName;
	/// @brief Whether the node (StartNode) or value (Argument, Property) has a `(type)` annotation.
	public bool HasAnnotation => mStreaming ? mStream.mHasAnnotation : mBytes.mHasAnnotation;
	/// @brief The annotation's text when HasAnnotation (it may be empty: `("")`).
	public StringView Annotation => mStreaming ? mStream.mAnnotation : mBytes.mAnnotation;
	/// @brief Argument, Property: the value.
	public KdlValue Value => mStreaming ? mStream.mValue : mBytes.mValue;
	/// @brief The depth of the node the event belongs to: 0 for top-level nodes.
	public int Depth => mStreaming ? mStream.mDepth : mBytes.mDepth;
	/// @brief Byte offset into the input where the event's construct starts: the node (StartNode,
	/// EndNode) or entry, including its annotation.
	public int Offset => mStreaming ? mStream.mEventOffset : mBytes.mEventOffset;
	/// @brief Byte offset just past the event's construct: StartNode, the node's name; Argument and
	/// Property, the value; EndNode, the node's last token (its name, last entry or children block's
	/// `}`), so Offset ..< EndOffset spans the whole node. EndOfDocument: the input's length.
	public int EndOffset => mStreaming ? mStream.mEventEnd : mBytes.mEventEnd;

	/// @brief Whether the read has stopped at an error: after any error, or with
	/// KdlReadConfig.CollectErrors only after one that cannot be skipped (encoding, I/O, a resource
	/// limit, MaxErrors). Next then returns that error again.
	public bool IsStopped => mStreaming ? mStream.IsStopped : mBytes.IsStopped;

	/// @brief Read up to the next event.
	/// @return The event, or an error: the read's last (see IsStopped), or with
	/// KdlReadConfig.CollectErrors one of several, after which the next call goes on with what follows
	/// the broken node.
	[Inline]
	public Result<KdlEvent, KdlParseError> Next()
	{
		if (!mStreaming)
		{
			if (mBytes.NextEvent() case .Ok(let event))
				return .Ok(event);
			return .Err(mBytes.[Friend]mError);
		}
		if (mStream.NextEvent() case .Ok(let event))
			return .Ok(event);
		return .Err(mStream.[Friend]mError);
	}

	// PreserveStyle: the event's source slice and its landmarks (see KdlReaderCore)
	internal StringView SourceText => mStreaming ? mStream.SourceText : mBytes.SourceText;
	internal int SourceStart => mStreaming ? mStream.mSourceStart : mBytes.mSourceStart;
	internal int ContentStart => mStreaming ? mStream.mContentStart : mBytes.mContentStart;
	internal int NameStart => mStreaming ? mStream.mNameStart : mBytes.mNameStart;
	internal int ValueStart => mStreaming ? mStream.mValueStart : mBytes.mValueStart;
	internal int BlockOpenEnd => mStreaming ? mStream.mBlockOpenEnd : mBytes.mBlockOpenEnd;
	internal int BlockCloseEnd => mStreaming ? mStream.mBlockCloseEnd : mBytes.mBlockCloseEnd;

	/// The line and column of an offset at or after the current event's start (Positions).
	internal bool Locate(int offset, out int line, out int column)
	{
		if (mStreaming)
			return mStream.mCursor.Locate(offset, out line, out column);
		return mBytes.mCursor.Locate(offset, out line, out column);
	}
}

/// The reader itself, over a cursor (in-memory text or a buffered stream). It reads through a window:
/// `mData[offset]` for `mBase <= offset < mEnd`, offsets absolute, so the offsets it keeps survive the
/// window moving. Anything that may read at the window's end asks for more first (`Avail`, `PeekAt`,
/// `NewlineAt`, …); for in-memory text the window is the whole input and those checks compile away.
internal class KdlReaderCore<TCursor> where TCursor : IKdlCursor
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
		/// Offset of its open children block's `{`, for the unclosed-block error; with a stream, also
		/// its line and column (located when read: the stream cannot look back at the end).
		public int32 mBraceOffset;
		public int32 mBraceLine;
		public int32 mBraceColumn;
		/// Where the node starts (its `/-`, annotation or name).
		public int32 mStart;
		/// Its arguments and properties so far, slashdashed ones included (MaxEntriesPerNode).
		public int32 mEntryCount;
		/// PreserveStyle: just after the `}` of its (real) children block; 0 if none.
		public int32 mBlockCloseEnd;
	}

	internal TCursor mCursor;
	char8* mData;
	int mBase;
	int mPos;
	int mEnd;
	/// The start of the construct being read: the cursor keeps bytes from here on in the window
	/// (int.MaxValue: none, between constructs).
	int mRetain;
	/// The cursor stopped on an error of the input; the reader's next error is replaced by it.
	bool mInputFailed;
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

	internal StringView mName;
	internal StringView mAnnotation;
	internal bool mHasAnnotation;
	internal KdlValue mValue;
	/// ReadEntry's first value while it looks for a `=` (a key, or the argument).
	KdlValue mEntryValue;
	internal int mDepth;
	internal int mEventOffset;
	internal int mEventEnd;

	// PreserveStyle: the source is cut into one slice per reported event, from the end of the last
	// one to the end of this one (a node's name, an entry's value, a node's terminator), so the slices
	// of all events are the whole document. Landmarks are offsets, -1 where absent.
	bool mCapture;
	/// Where the next event's slice starts.
	int mSliceStart;
	internal int mContentStart;
	internal int mSourceStart;
	internal int mSourceEnd;
	/// StartNode: where the name starts (after any annotation). Argument, Property: where the value
	/// starts (after any key, `=` and annotation).
	internal int mNameStart;
	internal int mValueStart;
	/// Just after the `{` of a children block, reported with the block's first reported event (its
	/// first child's StartNode, or the node's EndNode).
	internal int mBlockOpenEnd;
	int mPendingBlockOpen;
	/// EndNode: just after the node's `}`.
	internal int mBlockCloseEnd;
	/// Just past the last name, value or `}` read (slashdashed ones included).
	int mLastTokenEnd;

	KdlReadConfig mConfig;
	int mNodeCount;
	// CollectErrors: errors so far, where the last one was, and the steps recovery left to do
	int mErrorCount;
	int mLastErrorOffset;
	/// The start of the string being read (-1: none), where recovery restarts after an error in it.
	int mStringStart;
	bool mEndAfterRecovery;
	bool mClosingAtEnd;

	public this()
	{
		mFrames = new .();
		mNameBuffer = new .();
		mAnnotationBuffer = new .();
		mValueBuffer = new .();
		mConfig = .();
	}

	public void Reset(TCursor cursor, KdlReadConfig config)
	{
		mCursor = cursor;
		mConfig = config;
		mData = null;
		mBase = 0;
		mPos = 0;
		mEnd = 0;
		mRetain = int.MaxValue;
		mCapture = config.MetadataMode == .PreserveStyle;
		mSliceStart = 0;
		mContentStart = 0;
		mSourceStart = 0;
		mSourceEnd = 0;
		mNameStart = -1;
		mValueStart = -1;
		mBlockOpenEnd = -1;
		mPendingBlockOpen = -1;
		mBlockCloseEnd = -1;
		mInputFailed = false;
		mNodeCount = 0;
		mErrorCount = 0;
		mLastErrorOffset = -1;
		mStringStart = -1;
		mEndAfterRecovery = false;
		mClosingAtEnd = false;
		mEventEnd = 0;
		mLastTokenEnd = 0;
		mState = .Start;
		mFrames.Clear();
		mSuppressed = 0;
		mPendingSpace = false;
		mName = default;
		mAnnotation = default;
		mHasAnnotation = false;
		mValue = .Null;
		mEntryValue = .Null;
		mDepth = 0;
		mEventOffset = 0;
	}

	/// The next event; on failure the error is in mError. (KdlReader.Next makes the public Result, so
	/// the large error is copied once.)
	[Inline]
	public Result<KdlEvent, KdlFailure> NextEvent()
	{
		if (mState == .Failed)
			return .Err(.());
		let result = ReadNext();
		if (result case .Err)
			AfterError();
		return result;
	}

	/// Whether the read has stopped (after an error that cannot be skipped).
	public bool IsStopped => mState == .Failed;

	/// After an error: stop, or with CollectErrors skip the broken node and go on.
	void AfterError()
	{
		bool fatal = mInputFailed || mError.mKind == .ResourceLimitExceeded || mError.mKind == .IoError ||
			mError.mKind == .InvalidUtf8 || mError.mKind == .DisallowedCodePoint;
		if (!mConfig.CollectErrors || fatal || mState == .Start || (mConfig.MaxErrors > 0 && ++mErrorCount >= mConfig.MaxErrors))
		{
			mState = .Failed;
			return;
		}
		Recover();
	}

	/// Skips what is left of the node the error was in: to its terminator (a newline or `;`,
	/// consumed), or to the `}` or end that closes its parent. Strings, comments, line continuations
	/// and whole children blocks on the way are stepped over. A node that was started gets its EndNode.
	void Recover()
	{
		// An error inside a string: restart at its opening quote (or `#`), so it is skipped whole
		if (mStringStart >= 0)
		{
			mPos = mStringStart;
			mStringStart = -1;
		}
		int start = mPos;
		// The reader was inside a started node's entries, or between nodes (a node's head: not started)
		bool inNode = mState == .Entries;
		if (mState == .Nodes && Avail(mPos) && mData[mPos] == '}' && mFrames.Count == 0)
		{
			// A `}` without its `{`: drop it
			mPos++;
		}
		else if (mState == .Nodes && !Avail(mPos) && mFrames.Count > 0)
		{
			// Unclosed blocks at the end: close them, one EndNode per call
			mClosingAtEnd = true;
		}
		else
		{
			SkipToTerminator();
			// A `}` that closes no block (the current node's frame is not a block): drop it too
			if (Avail(mPos) && mData[mPos] == '}' && mFrames.Count <= (inNode ? 1 : 0))
				mPos++;
			// Always make progress: an error at the same spot again would loop
			if (mPos == start && Avail(mPos) && start == mLastErrorOffset)
				mPos++;
		}
		mLastErrorOffset = start;
		mRetain = RetainIdle;
		mPendingSpace = false;
		mEndAfterRecovery = inNode && mFrames.Count > 0;
		mState = inNode ? .Entries : .Nodes;
		// Slashdashed entries raise mSuppressed only while they are read: count from the frames again
		mSuppressed = 0;
		for (let frame in mFrames)
		{
			if (frame.mSlashdashed)
				mSuppressed++;
			if (frame.mChildrenSlashdashed)
				mSuppressed++;
		}
	}

	/// Recovery: moves to the end of the current node, stepping over its strings, comments, line
	/// continuations and children blocks without checking them.
	void SkipToTerminator()
	{
		int depth = 0;
		while (Avail(mPos))
		{
			int newline = NewlineAt(mPos);
			if (newline > 0)
			{
				mPos += newline;
				if (depth == 0)
					return;
				continue;
			}
			char8 c = mData[mPos];
			switch (c)
			{
			case ';':
				mPos++;
				if (depth == 0)
					return;
			case '{':
				depth++;
				mPos++;
			case '}':
				if (depth == 0)
					return;
				depth--;
				mPos++;
			case '"':
				SkipStringForRecovery(0);
			case '#':
				int hashes = 0;
				while (Avail(mPos + hashes) && mData[mPos + hashes] == '#')
					hashes++;
				if (Avail(mPos + hashes) && mData[mPos + hashes] == '"')
				{
					mPos += hashes;
					SkipStringForRecovery(hashes);
				}
				else
					mPos += hashes;
			case '/':
				if (PeekAt(1) == '*')
				{
					// An unterminated comment runs to the end; that is fine here (and must not
					// replace the error being reported)
					ScanBlockComment();
				}
				else if (PeekAt(1) == '/')
				{
					SkipSingleLineComment();
					if (depth == 0)
						return;
				}
				else
					mPos++;
			case '\\':
				// A line continuation: the node goes on after the newline
				mPos++;
				while (Avail(mPos) && SpaceAt(mPos) > 0)
					mPos += SpaceAt(mPos);
				if (Avail(mPos))
					mPos += Math.Max(NewlineAt(mPos), 0);
			default:
				mPos++;
			}
		}
	}

	/// Recovery: steps over a quoted (`hashes` 0) or raw string at mPos, to its closing quotes, or for
	/// a single-line one the end of its line.
	void SkipStringForRecovery(int hashes)
	{
		bool multiLine = PeekAt(1) == '"' && PeekAt(2) == '"';
		mPos += multiLine ? 3 : 1;
		while (Avail(mPos))
		{
			char8 c = mData[mPos];
			if (c == '\\' && hashes == 0)
			{
				mPos += 2;
				continue;
			}
			if (!multiLine && NewlineAt(mPos) > 0)
				return;
			if (c == '"' && (!multiLine || (PeekAt(1) == '"' && PeekAt(2) == '"')))
			{
				int after = mPos + (multiLine ? 3 : 1);
				if (HashesAt(after, hashes))
				{
					mPos = after + hashes;
					return;
				}
			}
			mPos++;
		}
	}

	public Result<KdlEvent, KdlParseError> Next()
	{
		switch (NextEvent())
		{
		case .Ok(let event):
			return .Ok(event);
		case .Err:
			return .Err(mError);
		}
	}

	Result<KdlEvent, KdlFailure> ReadNext()
	{
		if (mState == .Start)
		{
			switch (mCursor.Begin(ref mData, ref mBase, ref mEnd))
			{
			case .Ok(let start):
				mPos = start;
				mContentStart = start;
				mSliceStart = start;
			case .Err(let error):
				mError = error;
				if (!mConfig.SourceName.IsEmpty)
					mError.SetSource(mConfig.SourceName);
				return .Err(.());
			}
			mState = .Nodes;
		}
		while (true)
		{
			switch (mState)
			{
			case .Nodes:
				mRetain = RetainIdle;
				Try!(SkipLineSpace());
				if (!Avail(mPos))
				{
					if (mInputFailed)
						return .Err(Fail(.IoError, "", mPos));
					if (mFrames.Count > 0)
					{
						if (mClosingAtEnd)
						{
							// CollectErrors, after reporting an unclosed block: close what is open
							if (EndNode())
								return .Ok(.EndNode);
							continue;
						}
						ref Frame open = ref mFrames.Back;
						return .Err(FailAt(.UnbalancedBraces, "Expected `}` to close this children block", open.mBraceOffset, open.mBraceLine, open.mBraceColumn));
					}
					mState = .End;
					mDepth = 0;
					mEventOffset = mPos;
					mEventEnd = mPos;
					ReportSlice(mPos);
					return .Ok(.EndOfDocument);
				}
				char8 b = mData[mPos];
				if (b == '}')
				{
					if (mFrames.Count == 0)
						return .Err(Fail(.UnbalancedBraces, "Unexpected `}` without a matching `{`", mPos));
					mPos++;
					mLastTokenEnd = mPos;
					ref Frame frame = ref mFrames.Back;
					if (frame.mChildrenSlashdashed)
					{
						frame.mChildrenSlashdashed = false;
						mSuppressed--;
						if (frame.mPhase == 0)
							frame.mPhase = 1;
					}
					else
					{
						frame.mPhase = 2;
						frame.mBlockCloseEnd = (int32)mPos;
					}
					mState = .Entries;
					mPendingSpace = false;
					continue;
				}
				int nodeStart = mPos;
				mRetain = Math.Min(nodeStart, RetainIdle);
				bool slashdash = false;
				if (b == '/' && PeekAt(1) == '-')
				{
					Try!(ReadSlashdash());
					slashdash = true;
				}
				Try!(ReadNodeHead());
				if (mConfig.MaxDepth > 0 && mFrames.Count >= mConfig.MaxDepth)
					return .Err(Fail(.ResourceLimitExceeded, scope $"Nodes are nested deeper than MaxDepth ({mConfig.MaxDepth})", nodeStart));
				if (mConfig.MaxNodes > 0 && ++mNodeCount > mConfig.MaxNodes)
					return .Err(Fail(.ResourceLimitExceeded, scope $"The document has more nodes than MaxNodes ({mConfig.MaxNodes})", nodeStart));
				Frame opened = default;
				opened.mSlashdashed = slashdash;
				opened.mStart = (int32)nodeStart;
				mFrames.Add(opened);
				if (slashdash)
					mSuppressed++;
				mState = .Entries;
				mPendingSpace = false;
				if (mSuppressed == 0)
				{
					mDepth = mFrames.Count - 1;
					mEventOffset = nodeStart;
					mEventEnd = mLastTokenEnd;
					ReportSlice(mLastTokenEnd);
					return .Ok(.StartNode);
				}

			case .Entries:
				if (mEndAfterRecovery)
				{
					// CollectErrors: the rest of this node was skipped
					mEndAfterRecovery = false;
					if (EndNode())
						return .Ok(.EndNode);
					continue;
				}
				mRetain = RetainIdle;
				bool space = mPendingSpace;
				mPendingSpace = false;
				if (Try!(SkipNodeSpace()))
					space = true;
				if (!Avail(mPos))
				{
					if (EndNode())
						return .Ok(.EndNode);
					continue;
				}
				char8 c = mData[mPos];
				int newline = NewlineAt(mPos);
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
						NoteBrace(ref current);
						mSuppressed++;
						mPos++;
						mState = .Nodes;
						continue;
					}
					if (current.mPhase != 0)
						return .Err(Fail(.InvalidChildren, "Arguments and properties must come before the node's children blocks", mPos));
					if (mData[mPos] == '=')
						return .Err(Fail(.InvalidSlashdash, "A slashdash `/-` cannot come between a property's key and `=`; put it before the key", mPos));
					if (!CanStartValue(mPos) && mData[mPos] != '(')
						return .Err(Unexpected("an argument, property or children block after `/-`"));
					Try!(CountEntry(ref current));
					mRetain = Math.Min(mPos, RetainIdle);
					mSuppressed++;
					Try!(ReadEntry());
					mSuppressed--;
					continue;
				}
				if (c == '{')
				{
					if (current.mPhase == 2)
						return .Err(Fail(.InvalidChildren, "A node can have only one children block; slashdash (`/-`) the others", mPos));
					NoteBrace(ref current);
					mPos++;
					if (mSuppressed == 0)
						mPendingBlockOpen = mPos;
					mState = .Nodes;
					continue;
				}
				if (!CanStartValue(mPos) && c != '(')
				{
					if (IsIdentifierByte(Before(mPos)) && (c == '/' || c == '[' || c == ']' || c == ')'))
						return .Err(Fail(.UnexpectedChar, scope $"`{c}` cannot appear in an identifier string: quote the string", mPos));
					return .Err(Unexpected("an argument, property, children block or the end of the node"));
				}
				if (current.mPhase == 2)
					return .Err(Fail(.InvalidChildren, "Expected the end of the node (a newline or `;`) after its children block", mPos));
				if (current.mPhase != 0)
					return .Err(Fail(.InvalidChildren, "Arguments and properties must come before the node's children blocks", mPos));
				if (!space)
					return .Err(MissingSpace());
				Try!(CountEntry(ref current));
				int entryStart = mPos;
				mRetain = Math.Min(entryStart, RetainIdle);
				let event = Try!(ReadEntry());
				if (mSuppressed == 0)
				{
					mDepth = mFrames.Count - 1;
					mEventOffset = entryStart;
					mEventEnd = mLastTokenEnd;
					ReportSlice(mLastTokenEnd);
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
		mEventOffset = frame.mStart;
		mEventEnd = mLastTokenEnd;
		// A slashdashed children block still open (closed at the end during recovery; normally its `}`
		// clears this): its suppression ends with the node, or the node's own EndNode and its
		// ancestors' would be suppressed too
		if (frame.mChildrenSlashdashed)
			mSuppressed--;
		if (frame.mSlashdashed)
		{
			mSuppressed--;
			return false;
		}
		if (mSuppressed > 0)
			return false;
		mDepth = mFrames.Count;
		mBlockCloseEnd = frame.mBlockCloseEnd > 0 ? frame.mBlockCloseEnd : -1;
		// Through the terminator (a newline, `;` or `//` comment), or up to the parent's `}` or the end
		ReportSlice(mPos);
		return true;
	}

	/// PreserveStyle: the idle retain point, the start of the next slice (the window must keep it);
	/// otherwise nothing.
	int RetainIdle
	{
		[Inline]
		get => mCapture ? mSliceStart : int.MaxValue;
	}

	/// PreserveStyle: the reported event's slice ends at `sliceEnd`.
	[Inline]
	void ReportSlice(int sliceEnd)
	{
		if (!mCapture)
			return;
		mSourceStart = mSliceStart;
		mSourceEnd = sliceEnd;
		mSliceStart = sliceEnd;
		mBlockOpenEnd = mPendingBlockOpen;
		mPendingBlockOpen = -1;
	}

	/// PreserveStyle: the reported event's slice.
	internal StringView SourceText => StringView(mData + mSourceStart, mSourceEnd - mSourceStart);

	/// Records where the node's children block opens (`{` at mPos).
	[Inline]
	void NoteBrace(ref Frame frame)
	{
		frame.mBraceOffset = (int32)mPos;
		frame.mBraceLine = 0;
		if (mCursor.LocatesOnlyForward && mCursor.Locate(mPos, let line, let column))
		{
			frame.mBraceLine = (int32)line;
			frame.mBraceColumn = (int32)column;
		}
	}

	/// Counts an entry of the current node against MaxEntriesPerNode.
	[Inline]
	Result<void, KdlFailure> CountEntry(ref Frame frame)
	{
		if (mConfig.MaxEntriesPerNode > 0 && ++frame.mEntryCount > mConfig.MaxEntriesPerNode)
			return .Err(Fail(.ResourceLimitExceeded, scope $"The node has more arguments and properties than MaxEntriesPerNode ({mConfig.MaxEntriesPerNode})", mPos));
		return .Ok;
	}

	/// Consumes `/-` and the line-space after it, which must lead to something to comment out.
	Result<void, KdlFailure> ReadSlashdash()
	{
		int start = mPos;
		// The line-space after it may move a stream's window past it
		LocateEarly(start, let line, let column);
		mPos += 2;
		Try!(SkipLineSpace());
		if (Avail(mPos) && mData[mPos] == '/' && PeekAt(1) == '-')
			return .Err(Fail(.InvalidSlashdash, "A slashdash `/-` cannot be followed by another slashdash", mPos, 2));
		if (!Avail(mPos) || mData[mPos] == '}' || mData[mPos] == ';')
			return .Err(FailAt(.InvalidSlashdash, "A slashdash `/-` must be followed by a node, argument, property or children block", start, line, column, 2));
		return .Ok;
	}

	/// Reads a node's `(type)` and name.
	Result<void, KdlFailure> ReadNodeHead()
	{
		mHasAnnotation = false;
		if (mData[mPos] == '(')
		{
			Try!(ReadAnnotation());
			Try!(SkipNodeSpace());
			Try!(ExpectValueAfterAnnotation("a node name after the type annotation"));
		}
		else if (!CanStartValue(mPos))
			return .Err(Unexpected("a node"));
		int nameStart = mPos;
		mNameStart = nameStart;
		KdlValue name = Try!(ReadValue(mNameBuffer));
		if (!name.TryGetString(out mName))
			return .Err(Fail(.ExpectedString, "A node name must be a string; quote it", nameStart, mPos - nameStart));
		mLastTokenEnd = mPos;
		return .Ok;
	}

	/// Reads `( node-space* string node-space* )` into the annotation.
	Result<void, KdlFailure> ReadAnnotation()
	{
		int start = mPos;
		mPos++;
		Try!(SkipNodeSpace());
		if (Avail(mPos) && mData[mPos] == ')')
			return .Err(Fail(.InvalidAnnotation, "A type annotation cannot be empty", start, mPos + 1 - start));
		if (Avail(mPos) && mData[mPos] == '/' && PeekAt(1) == '-')
			return .Err(Fail(.InvalidSlashdash, "A slashdash `/-` cannot appear inside a type annotation; put it before the annotation", mPos, 2));
		int typeStart = mPos;
		KdlValue type = Try!(ReadValue(mAnnotationBuffer));
		if (!type.TryGetString(out mAnnotation))
			return .Err(Fail(.ExpectedString, "A type annotation must be a string; quote it", typeStart, mPos - typeStart));
		Try!(SkipNodeSpace());
		if (!Avail(mPos) || mData[mPos] != ')')
			return .Err(Unexpected("`)` to close the type annotation"));
		mPos++;
		mHasAnnotation = true;
		return .Ok;
	}

	/// Reads an argument or a property: `value`, or `string node-space* = node-space* value`.
	Result<KdlEvent, KdlFailure> ReadEntry()
	{
		int start = mPos;
		mHasAnnotation = false;
		bool annotated = false;
		if (mData[mPos] == '(')
		{
			Try!(ReadAnnotation());
			annotated = true;
			Try!(SkipNodeSpace());
			Try!(ExpectValueAfterAnnotation("a value after the type annotation"));
		}
		int tokenStart = mPos;
		// A field, not a local: the lookahead below may move the window, and fields are rebased
		mEntryValue = Try!(ReadValue(mNameBuffer));
		int tokenEnd = mPos;
		// Space before a `=` belongs to the property; otherwise it separates this argument from the next entry
		bool space = Try!(SkipNodeSpace());
		if (Avail(mPos) && mData[mPos] == '=')
		{
			if (!mEntryValue.TryGetString(out mName))
				return .Err(Fail(.ExpectedString, "A property key must be a string; quote it", tokenStart, tokenEnd - tokenStart));
			if (annotated)
				return .Err(Fail(.InvalidAnnotation, "A type annotation cannot annotate a property key; annotate the value instead (`key=(type)value`)", start, tokenEnd - start));
			mPos++;
			Try!(SkipNodeSpace());
			mHasAnnotation = false;
			if (Avail(mPos) && mData[mPos] == '/' && PeekAt(1) == '-')
				return .Err(Fail(.InvalidSlashdash, "A slashdash `/-` cannot comment out just a property's value; put it before the key", mPos, 2));
			if (Avail(mPos) && mData[mPos] == '(')
			{
				Try!(ReadAnnotation());
				Try!(SkipNodeSpace());
				Try!(ExpectValueAfterAnnotation("a value after the type annotation"));
			}
			mValueStart = mPos;
			mValue = Try!(ReadValue(mValueBuffer));
			mLastTokenEnd = mPos;
			return .Ok(.Property);
		}
		mValue = mEntryValue;
		mValueStart = tokenStart;
		mPendingSpace = space;
		mLastTokenEnd = tokenEnd;
		return .Ok(.Argument);
	}

	// Whitespace and comments

	/// Skips `ws*` (Unicode spaces and `/* */` comments). @return Whether anything was skipped.
	Result<bool, KdlFailure> SkipWhitespace()
	{
		int begin = mPos;
		while (Avail(mPos))
		{
			int n = SpaceAt(mPos);
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
	Result<void, KdlFailure> SkipBlockComment()
	{
		int start = mPos;
		// A stream may drop the comment's start before its end is found: locate it now
		LocateEarly(start, let line, let column);
		if (!ScanBlockComment())
			return .Err(FailAt(.UnterminatedComment, "Unterminated comment: expected `*/`", start, line, column, 2));
		return .Ok;
	}

	/// For a stream (which only locates forward), the line and column of `pos`, for an error that may
	/// be reported after the window has moved on; 0 for in-memory input (located when needed).
	[Inline]
	void LocateEarly(int pos, out int line, out int column)
	{
		line = 0;
		column = 0;
		if (mCursor.LocatesOnlyForward && mCursor.Locate(pos, var l, var c))
		{
			line = l;
			column = c;
		}
	}

	/// Skips a `/* */` comment (nested ones too). @return Whether it was closed (else mPos is at the end).
	bool ScanBlockComment()
	{
		mPos += 2;
		int depth = 1;
		while (Avail(mPos))
		{
			char8 b = mData[mPos];
			if (b == '*' && PeekAt(1) == '/')
			{
				mPos += 2;
				if (--depth == 0)
					return true;
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
		return false;
	}

	/// Skips a `//` comment and the newline that ends it.
	void SkipSingleLineComment()
	{
		mPos += 2;
		while (Avail(mPos))
		{
			// Newline lead bytes never occur inside a multi-byte sequence, so stepping bytes is safe
			int n = NewlineAt(mPos);
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
	Result<bool, KdlFailure> SkipNodeSpace()
	{
		// Fast path: ASCII spaces and tabs, then anything that cannot continue node-space (a local
		// position, so the loop does not store mPos on every byte)
		int begin = mPos;
		int p = mPos;
		while (true)
		{
			// At the window's end, store the position first: a refill keeps only bytes from mPos on
			if (p >= mEnd)
			{
				mPos = p;
				if (!Grow(p, 1))
					break;
			}
			if (mData[p] != ' ' && mData[p] != '\t')
				break;
			p++;
		}
		mPos = p;
		if (!Avail(p) || !MayContinueSpace(mData[p]))
			return p != begin;
		bool any = mPos != begin;
		while (true)
		{
			if (Try!(SkipWhitespace()))
				any = true;
			if (!Avail(mPos) || mData[mPos] != '\\')
				return any;
			int start = mPos;
			LocateEarly(start, let line, let column);
			char8 previous = Before(start);
			mPos++;
			Try!(SkipWhitespace());
			if (Avail(mPos))
			{
				if (mData[mPos] == '/' && PeekAt(1) == '/')
					SkipSingleLineComment();
				else
				{
					int n = NewlineAt(mPos);
					if (n == 0)
					{
						if (IsIdentifierByte(previous))
							return .Err(FailAt(.InvalidLineContinuation, "`\\` cannot appear in an identifier string: quote the string (a `\\` at the end of a line continues the node)", start, line, column));
						return .Err(FailAt(.InvalidLineContinuation, "A line continuation `\\` must be followed by a newline or a `//` comment", start, line, column));
					}
					mPos += n;
				}
			}
			any = true;
		}
	}

	/// Skips `line-space*`: node-space, newlines and `//` comments.
	Result<void, KdlFailure> SkipLineSpace()
	{
		// Fast path: ASCII spaces, tabs, LF and CR, then anything that cannot continue line-space (a
		// local position, so the loop does not store mPos on every byte)
		int p = mPos;
		while (true)
		{
			// At the window's end, store the position first: a refill keeps only bytes from mPos on
			if (p >= mEnd)
			{
				mPos = p;
				if (!Grow(p, 1))
					break;
			}
			char8 c = mData[p];
			if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
				break;
			p++;
		}
		mPos = p;
		if (!Avail(p))
			return .Ok;
		char8 next = mData[p];
		if (!MayContinueSpace(next) && next != (char8)0x0B && next != (char8)0x0C)
			return .Ok;
		while (true)
		{
			Try!(SkipNodeSpace());
			if (!Avail(mPos))
				return .Ok;
			int n = NewlineAt(mPos);
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

	// The window

	/// Whether the byte at `pos` is available, reading more of a stream if needed.
	[Inline]
	bool Avail(int pos)
	{
		return pos < mEnd || Grow(pos, 1);
	}

	/// Whether `count` bytes from `pos` are available, reading more of a stream if needed.
	[Inline]
	bool AvailN(int pos, int count)
	{
		return pos + count <= mEnd || Grow(pos, count);
	}

	/// Asks the cursor for more input, keeping the current construct, and moves the event's views if
	/// the window moved. @return Whether `count` bytes from `pos` are now available.
	/// Inlined so that for in-memory input (Fill is an inlined `false`) it folds to a compare and the
	/// scanning loops keep the window in registers.
	[Inline]
	bool Grow(int pos, int count)
	{
		char8* oldData = mData;
		int oldBase = mBase;
		int oldEnd = mEnd;
		bool grew = mCursor.Fill(ref mData, ref mBase, ref mEnd, Math.Min(Math.Min(mRetain, mPos), pos), pos, count);
		if (mData != oldData)
			RebaseViews(oldData, oldBase, oldEnd);
		if (!grew)
		{
			// Nothing new: still short (Grow is only asked when it is), so a constant for in-memory input.
			// Only note the failure: recovery grows too, while the error it is about to return views the
			// per-thread message buffer that making the input's error would overwrite
			if (mCursor.HasInputError)
				mInputFailed = true;
			return false;
		}
		return pos + count <= mEnd;
	}

	void RebaseViews(char8* oldData, int oldBase, int oldEnd)
	{
		char8* low = oldData + oldBase;
		char8* high = oldData + oldEnd;
		Rebase(ref mName, low, high, oldData);
		Rebase(ref mAnnotation, low, high, oldData);
		Rebase(ref mValue, low, high, oldData);
		Rebase(ref mEntryValue, low, high, oldData);
	}

	/// Moves a view of the old window to the same offsets in the new one.
	void Rebase(ref StringView view, char8* low, char8* high, char8* oldData)
	{
		if (view.Ptr >= low && view.Ptr < high)
			view = .(mData + (view.Ptr - oldData), view.Length);
	}

	void Rebase(ref KdlValue value, char8* low, char8* high, char8* oldData)
	{
		switch (value)
		{
		case .String(var s):
			Rebase(ref s, low, high, oldData);
			value = .String(s);
		case .Integer(let v, var text):
			Rebase(ref text, low, high, oldData);
			value = .Integer(v, text);
		case .Float(let v, var text):
			Rebase(ref text, low, high, oldData);
			value = .Float(v, text);
		case .BigInteger(var text):
			Rebase(ref text, low, high, oldData);
			value = .BigInteger(text);
		default:
		}
	}

	[Inline]
	char8 PeekAt(int lookahead)
	{
		int pos = mPos + lookahead;
		return Avail(pos) ? mData[pos] : 0;
	}

	/// The byte before `pos`, or 0 if there is none in the window (only used to word error messages).
	[Inline]
	char8 Before(int pos)
	{
		return pos > mBase ? mData[pos - 1] : 0;
	}

	/// The byte length of the newline at `pos` (which must be available), or 0.
	[Inline]
	int NewlineAt(int pos)
	{
		uint8 b = (uint8)mData[pos];
		if (b > 0x0D && b != 0xC2 && b != 0xE2)
			return 0;
		if (pos + 3 > mEnd)
			Grow(pos, 3);
		return KdlChar.NewlineLength(mData, pos, mEnd);
	}

	/// The byte length of the Unicode space at `pos` (which must be available), or 0.
	[Inline]
	int SpaceAt(int pos)
	{
		char8 c = mData[pos];
		if (c == ' ' || c == '\t')
			return 1;
		if ((uint8)c < 0xC2)
			return 0;
		if (pos + 3 > mEnd)
			Grow(pos, 3);
		return KdlChar.UnicodeSpaceLength(mData, pos, mEnd);
	}

	/// The code point at `pos` (which must be available) and its length.
	[Inline]
	char32 DecodeAt(int pos, out int length)
	{
		if ((uint8)mData[pos] < 0x80)
		{
			length = 1;
			return (char32)mData[pos];
		}
		if (pos + 4 > mEnd)
			Grow(pos, 4);
		return KdlChar.Decode(mData, pos, out length);
	}

	[Inline]
	StringView View(int start, int length)
	{
		return StringView(mData + start, length);
	}

	// Helpers

	/// Whether whitespace, a comment or a line continuation may start with `c`, other than an ASCII
	/// space or tab: `/`, `\`, or a lead byte of a non-ASCII space or newline (0xC2 and up).
	[Inline]
	static bool MayContinueSpace(char8 c)
	{
		return c == '/' || c == '\\' || (uint8)c >= 0xC2;
	}

	/// Whether a string, number or keyword can start at `pos`.
	bool CanStartValue(int pos)
	{
		if (!Avail(pos))
			return false;
		char8 b = mData[pos];
		if (b == '"' || b == '#')
			return true;
		if ((uint8)b < 0x80)
			return KdlChar.IsIdentifierAscii(b);
		return KdlChar.IsIdentifierChar(DecodeAt(pos, var length));
	}

	/// Whether `c` can be part of an identifier (ASCII identifier characters, or any non-ASCII byte:
	/// only used to word error messages).
	static bool IsIdentifierByte(char8 c)
	{
		return (uint8)c >= 0x80 || KdlChar.IsIdentifierAscii(c);
	}

	/// The error for an entry that touches what comes before it, worded for the likely cause.
	KdlFailure MissingSpace()
	{
		char8 c = mData[mPos];
		char8 previous = Before(mPos);
		if (IsIdentifierByte(previous) && (c == '"' || c == '#' || c == '('))
		{
			// `r"…"` / `r#"…"#`: an identifier `r` touching a string
			if (previous == 'r' && !IsIdentifierByte(Before(mPos - 1)))
				return Fail(.MissingSpace, "Raw strings are written `#\"…\"#` in KDL 2 (`r\"…\"` is KDL 1)", mPos - 1);
			return Fail(.MissingSpace, scope $"`{c}` cannot appear in an identifier string: quote the string, or separate the values with whitespace", mPos);
		}
		return Fail(.MissingSpace, "Expected whitespace before this argument or property", mPos);
	}

	/// After a type annotation: the value must follow. A misplaced slashdash gets its own message.
	Result<void, KdlFailure> ExpectValueAfterAnnotation(StringView expected)
	{
		if (Avail(mPos) && mData[mPos] == '/' && PeekAt(1) == '-')
			return .Err(Fail(.InvalidSlashdash, "A slashdash `/-` cannot come after a type annotation; put it before the annotation", mPos, 2));
		if (!CanStartValue(mPos))
			return .Err(Unexpected(expected));
		return .Ok;
	}

	/// Records the error (Next reports it) and returns the token internal methods fail with. After the
	/// input itself failed (a stream's I/O, encoding or size error), that error is reported instead: the
	/// reader's own came from running into the end of what could be read.
	KdlFailure Fail(KdlErrorKind kind, StringView message, int offset, int length = 1)
	{
		if (mInputFailed && mCursor.TryGetInputError(let inputError))
			mError = inputError;
		else
		{
			int line = 0;
			int column = 0;
			if (mCursor.Locate(offset, var l, var c))
			{
				line = l;
				column = c;
			}
			mError = KdlParseError(kind, message, line, column, offset, length);
		}
		if (!mConfig.SourceName.IsEmpty)
			mError.SetSource(mConfig.SourceName);
		return .();
	}

	/// Fail at a position located earlier (line 0: locate it now, as Fail does).
	KdlFailure FailAt(KdlErrorKind kind, StringView message, int offset, int line, int column, int length = 1)
	{
		if (line == 0 || (mInputFailed && mCursor.HasInputError))
			return Fail(kind, message, offset, length);
		mError = KdlParseError(kind, message, line, column, offset, length);
		if (!mConfig.SourceName.IsEmpty)
			mError.SetSource(mConfig.SourceName);
		return .();
	}

	/// "Expected X, found Y" at the current position.
	KdlFailure Unexpected(StringView expected)
	{
		let message = scope String();
		message.Append("Expected ");
		message.Append(expected);
		message.Append(", found ");
		if (!Avail(mPos))
		{
			message.Append("the end of the input");
			return Fail(.UnexpectedEof, message, mPos, 0);
		}
		int length = 1;
		if (NewlineAt(mPos) > 0)
			message.Append("a newline");
		else
		{
			char32 cp = DecodeAt(mPos, out length);
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

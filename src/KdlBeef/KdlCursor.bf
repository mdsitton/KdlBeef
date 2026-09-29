using System;
using System.Collections;
using System.IO;
using internal KdlBeef;

namespace KdlBeef;

/// Where KdlReaderCore's bytes come from (TomlBeef's ITomlCursor design, reshaped for a reader that
/// scans raw bytes). The reader reads a window of the input through a pointer `data` indexed by
/// absolute offsets (`data[offset]`, valid for `windowStart <= offset < end`), so offsets it keeps stay
/// valid when a stream moves or grows its buffer; only `data`, `windowStart` and `end` change.
internal interface IKdlCursor
{
	/// Validates what it can up front (all of an in-memory input; a stream's first buffer) and sets up
	/// the window. @return The offset of the first content byte (after a BOM), or the input's error.
	Result<int, KdlParseError> Begin(ref char8* data, ref int windowStart, ref int end) mut;

	/// Makes the input up to `pos + count` available if there is that much, keeping every byte from
	/// `keep` on in the window (the reader's current construct). The window may move.
	/// @return Whether `end` grew.
	bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut;

	/// An error of the input itself (I/O, encoding, size) that stopped Fill. The reader reports it in
	/// place of its own once it has run into the end of what Fill delivered.
	bool TryGetInputError(out KdlParseError error);

	/// The 1-based line and column (in code points) of `offset`: always for in-memory input; for a
	/// stream only from the earliest offset it still counts (the start of the current construct).
	bool Locate(int offset, out int line, out int column) mut;

	/// Whether Locate only works forward (streams): positions an error may need later, such as a
	/// children block's `{`, must then be located when they are read.
	bool LocatesOnlyForward { get; }
}

/// Counts lines and columns forward through the input, one offset at a time.
internal struct KdlLineCounter
{
	public int mPos;
	public int mLine = 1;
	public int mColumn = 1;

	public this(int start)
	{
		mPos = start;
	}

	/// Moves to `offset` (not before the current position), counting every KDL newline (CRLF as one)
	/// and every code point. `text[mPos ..< offset]` must be available, up to `end`.
	public void AdvanceTo(char8* text, int offset, int end) mut
	{
		while (mPos < offset)
		{
			int newline = KdlChar.NewlineLength(text, mPos, end);
			if (newline > 0)
			{
				mPos += newline;
				mLine++;
				mColumn = 1;
				continue;
			}
			mPos += Math.Max(KdlChar.Utf8SequenceLength(text[mPos]), 1);
			mColumn++;
		}
	}
}

/// An in-memory input: the window is the whole input, validated up front; Fill never has more.
internal struct KdlByteCursor : IKdlCursor
{
	StringView mInput;
	int mMaxInputBytes;
	KdlLineCounter mLines;
	int mStart;

	public this(StringView input, KdlReadConfig config)
	{
		mInput = input;
		mMaxInputBytes = config.MaxInputBytes;
		mStart = KdlChar.StartsWithBom(input.Ptr, input.Length) ? 3 : 0;
		mLines = .(mStart);
	}

	public Result<int, KdlParseError> Begin(ref char8* data, ref int windowStart, ref int end) mut
	{
		data = mInput.Ptr;
		windowStart = 0;
		end = mInput.Length;
		if (mMaxInputBytes > 0 && mInput.Length > mMaxInputBytes)
			return .Err(KdlParseError(.ResourceLimitExceeded, scope $"The input ({mInput.Length} bytes) exceeds MaxInputBytes ({mMaxInputBytes})", 1, 1, 0, 0));
		let message = scope String();
		int bad = KdlChar.FindInvalid(mInput.Ptr, mStart, mInput.Length, message, let kind, let length);
		if (bad >= 0)
		{
			Locate(bad, let line, let column);
			return .Err(KdlParseError(kind, message, line, column, bad, length));
		}
		return mStart;
	}

	[Inline]
	public bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut
	{
		return false;
	}

	[Inline]
	public bool TryGetInputError(out KdlParseError error)
	{
		error = default;
		return false;
	}

	public bool LocatesOnlyForward
	{
		[Inline]
		get => false;
	}

	public bool Locate(int offset, out int line, out int column) mut
	{
		int target = Math.Min(offset, mInput.Length);
		if (target < mLines.mPos)
		{
			// Behind the counter (an error before the last position asked for): count from the start
			KdlChar.LineAndColumn(mInput, target, out line, out column);
			return true;
		}
		mLines.AdvanceTo(mInput.Ptr, target, mInput.Length);
		line = mLines.mLine;
		column = mLines.mColumn;
		return true;
	}
}

/// What a stream read owns (a cursor is a struct): the buffer and the input's error. The error is kept
/// in parts, with its own copy of the message: a KdlParseError's message lives in a per-thread buffer
/// that the next error overwrites.
internal class KdlStreamState
{
	public List<uint8> mBuffer ~ delete _;
	public bool mHasError;
	public KdlErrorKind mErrorKind;
	public String mErrorMessage ~ delete _;
	public int mErrorLine;
	public int mErrorColumn;
	public int mErrorOffset;
	public int mErrorLength;

	public this()
	{
		mBuffer = new .();
		mErrorMessage = new .();
	}

	public KdlParseError MakeError()
	{
		return KdlParseError(mErrorKind, mErrorMessage, mErrorLine, mErrorColumn, mErrorOffset, mErrorLength);
	}
}

/// A stream read through a buffer (TomlBeef's TomlBufferedStreamCursor, reshaped): the window is the
/// buffered part of the input from the reader's current construct on. A refill drops the bytes before
/// that construct and moves the rest to the front; a construct longer than the buffer doubles it
/// (bounded by MaxTokenBytes). Bytes are validated as they arrive; the window ends at the last
/// complete, valid code point, so the reader never sees bytes that are not.
internal struct KdlBufferedStreamCursor : IKdlCursor
{
	Stream mStream;
	KdlStreamState mState;
	/// Absolute offset of the buffer's first byte.
	int mBase;
	/// Bytes in the buffer, and how many of them are validated (the window).
	int mRaw;
	int mValid;
	/// The stream is exhausted, or failed (mState.mHasError).
	bool mDone;
	int mBytesRead;
	int mMaxInputBytes;
	int mMaxTokenBytes;
	/// Lines counted up to the bytes dropped from the buffer: nothing before it can be located.
	KdlLineCounter mLines;
	/// Lines counted forward for Locate (positions, early locations); a request behind it counts
	/// from mLines instead, so any offset still in the buffer can be located.
	KdlLineCounter mLocated;

	public this(Stream stream, KdlStreamState state, KdlReadConfig config)
	{
		mStream = stream;
		mState = state;
		mBase = 0;
		mRaw = 0;
		mValid = 0;
		mDone = false;
		mBytesRead = 0;
		mMaxInputBytes = config.MaxInputBytes;
		mMaxTokenBytes = config.MaxTokenBytes;
		mLines = .(0);
		mLocated = .(0);
		state.mHasError = false;
		int size = config.StreamBufferBytes > 0 ? Math.Max(config.StreamBufferBytes, 16) : 64 * 1024;
		state.mBuffer.Count = size;
	}

	[Inline]
	char8* Buffer => (char8*)mState.mBuffer.Ptr;

	public Result<int, KdlParseError> Begin(ref char8* data, ref int windowStart, ref int end) mut
	{
		// Enough to see a BOM (or the whole input, if it is shorter)
		while (mRaw < 3 && !mDone)
			ReadMore();
		int start = KdlChar.StartsWithBom(Buffer, mRaw) ? 3 : 0;
		mValid = start;
		mLines = .(start);
		mLocated = .(start);
		// Finish the first buffer, and validate it: in-memory input is validated before reading, so a
		// document that fits the buffer reports the same first error either way
		while (mRaw < mState.mBuffer.Count && !mDone)
			ReadMore();
		Validate();
		SetWindow(ref data, ref windowStart, ref end);
		if (mState.mHasError)
			return .Err(mState.MakeError());
		return start;
	}

	public bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut
	{
		int oldEnd = mBase + mValid;
		while (mBase + mValid < pos + count && !mDone)
		{
			// Drop what the reader is done with, counting its lines first
			int drop = Math.Min(keep, pos) - mBase;
			if (drop > 0)
			{
				mLines.AdvanceTo(Buffer - mBase, Math.Max(mBase + drop, mLines.mPos), mBase + mRaw);
				if (mLocated.mPos < mLines.mPos)
					mLocated = mLines;
				Internal.MemMove(Buffer, Buffer + drop, mRaw - drop);
				mBase += drop;
				mRaw -= drop;
				mValid -= drop;
			}
			if (mRaw == mState.mBuffer.Count)
			{
				// One construct fills the buffer: grow it
				if (mMaxTokenBytes > 0 && mRaw >= mMaxTokenBytes)
				{
					SetError(.ResourceLimitExceeded, scope $"A token or entry is longer than MaxTokenBytes ({mMaxTokenBytes})", mBase + mRaw);
					break;
				}
				mState.mBuffer.Count = mState.mBuffer.Count * 2;
			}
			ReadMore();
			Validate();
		}
		SetWindow(ref data, ref windowStart, ref end);
		return end > oldEnd;
	}

	void SetWindow(ref char8* data, ref int windowStart, ref int end)
	{
		data = Buffer - mBase;
		windowStart = mBase;
		end = mBase + mValid;
	}

	/// Reads once into the free part of the buffer.
	void ReadMore() mut
	{
		if (mDone)
			return;
		switch (mStream.TryRead(.(mState.mBuffer.Ptr + mRaw, mState.mBuffer.Count - mRaw)))
		{
		case .Ok(let read):
			if (read <= 0)
			{
				mDone = true;
				return;
			}
			mRaw += read;
			mBytesRead += read;
			if (mMaxInputBytes > 0 && mBytesRead > mMaxInputBytes)
				SetError(.ResourceLimitExceeded, scope $"The input exceeds MaxInputBytes ({mMaxInputBytes})", mMaxInputBytes);
		case .Err:
			SetError(.IoError, "Reading the input failed", mBase + mRaw);
		}
	}

	/// Validates the newly read bytes up to the last complete code point (all of them at the end of
	/// the input) and extends the window over them, or stops the stream at the first invalid one.
	void Validate() mut
	{
		char8* text = Buffer - mBase;
		int from = mBase + mValid;
		int to = mDone ? mBase + mRaw : KdlChar.CompleteSequencesEnd(text, from, mBase + mRaw);
		if (mState.mHasError)
			to = Math.Min(to, mState.mErrorOffset);
		let message = scope String();
		int bad = KdlChar.FindInvalid(text, from, to, message, let kind, let length);
		if (bad >= 0)
		{
			mValid = bad - mBase;
			SetError(kind, message, bad, length);
			return;
		}
		mValid = to - mBase;
	}

	/// Records the input's first error and stops reading.
	void SetError(KdlErrorKind kind, StringView message, int offset, int length = 1) mut
	{
		mDone = true;
		if (mState.mHasError)
			return;
		Locate(offset, out mState.mErrorLine, out mState.mErrorColumn);
		mState.mErrorKind = kind;
		mState.mErrorMessage.Set(message);
		mState.mErrorOffset = offset;
		mState.mErrorLength = length;
		mState.mHasError = true;
	}

	public bool TryGetInputError(out KdlParseError error)
	{
		error = mState.mHasError ? mState.MakeError() : default;
		return mState.mHasError;
	}

	public bool LocatesOnlyForward
	{
		[Inline]
		get => true;
	}

	public bool Locate(int offset, out int line, out int column) mut
	{
		line = 0;
		column = 0;
		if (offset < mLines.mPos)
			return false;
		int target = Math.Min(offset, mBase + mRaw);
		if (target >= mLocated.mPos)
		{
			mLocated.AdvanceTo(Buffer - mBase, target, mBase + mRaw);
			line = mLocated.mLine;
			column = mLocated.mColumn;
			return true;
		}
		// Behind the forward count (an error at an earlier offset): count from the dropped bytes
		var lines = mLines;
		lines.AdvanceTo(Buffer - mBase, target, mBase + mRaw);
		line = lines.mLine;
		column = lines.mColumn;
		return true;
	}
}

using System;
using FormatCore;
using internal FormatCore;
using internal KdlBeef;

namespace KdlBeef;

/// Categories of errors that can occur when reading a KDL document.
public enum KdlErrorKind : uint8
{
	// Encoding
	/// Bytes that are not valid UTF-8.
	InvalidUtf8,
	/// A code point that may not appear literally (control characters, bidi controls, a BOM after the start).
	DisallowedCodePoint,

	// Lexical
	/// A character that cannot start or continue what is being read.
	UnexpectedChar,
	/// The input ended inside a construct.
	UnexpectedEof,
	/// A string without its closing quote.
	UnterminatedString,
	/// A `/*` comment without its closing `*/`.
	UnterminatedComment,
	/// An unknown escape, or a malformed `\u{…}`.
	InvalidEscape,
	/// A malformed multi-line string (opening, closing line or indentation).
	InvalidMultiLineString,
	/// Text that starts like a number but is not a valid one.
	InvalidNumber,
	/// A `#` keyword that does not exist, or a keyword written without its `#`.
	InvalidKeyword,

	// Structure
	/// Missing whitespace between a node's name, arguments and properties.
	MissingSpace,
	/// A node name, property key or type annotation that is not a string.
	ExpectedString,
	/// A value is missing (after `=`, after a type annotation, at a node's start).
	ExpectedValue,
	/// A type annotation in a place it cannot be.
	InvalidAnnotation,
	/// A `/-` that comments out nothing, or is followed by another `/-`.
	InvalidSlashdash,
	/// Arguments or properties after a children block, or a second children block.
	InvalidChildren,
	/// A `}` without its `{`, or a `{` without its `}`.
	UnbalancedBraces,
	/// A line continuation `\` that is not followed by a newline or comment.
	InvalidLineContinuation,

	// Limits
	/// A resource limit was exceeded.
	ResourceLimitExceeded,

	// File I/O
	/// Reading the input failed.
	IoError,

	// Typed mapping ([KdlObject])
	/// A required property, argument or child is absent.
	MissingValue,
	/// A value has another type than its field.
	WrongType,
	/// A value has the right type but is not accepted (out of range, not a known name).
	InvalidValue
}

/// A read error with location information for precise error reporting.
///
/// The error owns nothing and needs no cleanup, so it can be dropped freely (including by `Try!`).
/// `mMessage` views a per-thread buffer: it stays valid until the next KdlParseError is created on the
/// same thread, which in practice means the next failing KdlBeef call. Copy it to keep it longer.
public struct KdlParseError
{
	/// Per-thread message and source-name storage, freed when the thread exits.
	static LazyTLS<String> sMessageBuffer = new .() ~ delete _;
	static LazyTLS<String> sSourceBuffer = new .() ~ delete _;

	public KdlErrorKind mKind;
	/// @brief Human-readable description. Valid until the next error on this thread.
	public StringView mMessage;
	/// @brief Name of the input the position refers to; empty if unnamed. Valid until the next error
	/// on this thread.
	public StringView mSource;
	/// @brief 1-based line (0 when there is no position).
	public int32 mLine;
	/// @brief 1-based column, in code points.
	public int32 mColumn;
	/// @brief Byte offset into the input.
	public int32 mOffset;
	/// @brief Length of the erroneous span in bytes.
	public int32 mLength;

	/// @brief Creates a new error at the given location.
	/// @param kind The category of error.
	/// @param message Human-readable description.
	/// @param line 1-based line number.
	/// @param column 1-based column number.
	/// @param offset Byte offset into the input.
	/// @param length Length of the erroneous span in bytes.
	public this(KdlErrorKind kind, StringView message, int line, int column, int offset, int length = 1)
	{
		mKind = kind;
		mLine = (int32)line;
		mColumn = (int32)column;
		mOffset = (int32)offset;
		mLength = (int32)length;

		mMessage = Store(sMessageBuffer.Value, message);
		mSource = default;
	}

	/// An error at byte `offset` of `input`, with the line and column computed from it.
	internal static KdlParseError At(KdlErrorKind kind, StringView message, StringView input, int offset, int length = 1)
	{
		Utf8.LineAndColumn<KdlText>(input, offset, let line, let column);
		return KdlParseError(kind, message, line, column, offset, length);
	}

	/// Copies `text` into a per-thread buffer and returns a view of it.
	static StringView Store(String buffer, StringView text)
	{
		// The text may itself be a view of the buffer (an error rebuilt from a previous one)
		char8* start = buffer.Ptr;
		if (text.Ptr >= start && text.Ptr < start + buffer.Length)
		{
			let copy = scope String(text);
			buffer.Set(copy);
		}
		else
			buffer.Set(text);
		return buffer;
	}

	/// @brief Set the source name the position refers to. Stored like the message: valid until the next
	/// error on this thread.
	/// @param source The source name, e.g. a file path.
	public void SetSource(StringView source) mut
	{
		mSource = Store(sSourceBuffer.Value, source);
	}

	/// @brief Copy the message and source name into this thread's error buffers, so the error no longer
	/// depends on where they were: needed for an error from KdlDocument.Errors (whose text the document
	/// owns) that must outlive the document. Afterwards the error is like any other: valid until the next
	/// error on this thread.
	public void Detach() mut
	{
		mMessage = Store(sMessageBuffer.Value, mMessage);
		let source = mSource;
		mSource = default;
		if (!source.IsEmpty)
			mSource = Store(sSourceBuffer.Value, source);
	}

	/// @brief Formats the error as `source:line:column: message`, dropping the parts that are unknown
	/// (no source name, or no position: line 0).
	/// @param strBuffer The string to append to.
	public override void ToString(String strBuffer)
	{
		if (!mSource.IsEmpty)
		{
			strBuffer.Append(mSource);
			strBuffer.Append(':');
		}
		if (mLine > 0)
			strBuffer.AppendF("{}:{}:", mLine, mColumn);
		if (!mSource.IsEmpty || mLine > 0)
			strBuffer.Append(' ');
		strBuffer.Append(mMessage);
	}
}

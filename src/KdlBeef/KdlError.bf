using System;
using FormatCore;
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

/// @brief A read error with its location (FormatCore's ParseError with KDL's error kinds): kind,
/// message, source name, line, column (in code points), byte offset and length; `ToString` formats it
/// as `source:line:column: message`.
///
/// The error owns nothing and needs no cleanup, so it can be dropped freely (including by `Try!`).
/// `mMessage` views a per-thread buffer: it stays valid until the next KdlParseError is created on the
/// same thread, which in practice means the next failing KdlBeef call. Copy it to keep it longer
/// (`KdlDiagnostic`), or `Detach` an error that views a document's text (KdlDocument.Errors).
public typealias KdlParseError = FormatCore.ParseError<KdlErrorKind>;

/// @brief An error that owns its text, for keeping it beyond the next error on the thread (a list of
/// diagnostics, errors from several readers or threads). Delete it when done.
public typealias KdlDiagnostic = FormatCore.Diagnostic<KdlErrorKind>;

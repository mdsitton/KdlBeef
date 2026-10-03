using System;
using FormatCore;
using internal FormatCore;
using internal KdlBeef;

namespace KdlBeef;

/// KDL's character rules for FormatCore's generic UTF-8 validator, line counter and cursors: the code
/// points that may not appear literally (control characters other than the whitespace and newlines,
/// DEL, the bidi controls, U+FEFF after the start) and KDL's newlines (CR, LF, CRLF, NEL, VT, FF, LS,
/// PS). Every member is static and inlined into the generic code that uses it.
internal struct KdlText : ITextPolicy
{
	public static bool ValidatesUpFront
	{
		[Inline]
		get => true;
	}

	/// ASCII other than DEL and the control characters, tab, LF and CR excepted (the bytes of indented
	/// text). Exact per byte: once the high bits are known to be clear, adding to a byte cannot carry
	/// into the next one. (VT and FF are allowed too, but rare: they take the byte checks.)
	[Inline]
	public static bool IsPlainWord(uint64 word)
	{
		if (!Swar.IsAscii(word))
			return false;
		// High bit set for bytes >= 0x20
		uint64 printable = (word + 0x60 * Swar.Ones) & Swar.High;
		uint64 del = Swar.BytesEqual(word, 0x7F);
		if (printable == Swar.High)
			return del == 0;
		uint64 control = ~printable & Swar.High;
		uint64 allowed = Swar.BytesEqual(word, 0x09) | Swar.BytesEqual(word, 0x0A) | Swar.BytesEqual(word, 0x0D);
		return (control & ~allowed) == 0 && del == 0;
	}

	[Inline]
	public static bool AllowsAscii(uint8 b) => !(b <= 0x08 || (b >= 0x0E && b <= 0x1F) || b == 0x7F);

	public static bool BansCodePoints
	{
		[Inline]
		get => true;
	}

	[Inline]
	public static bool AllowsCodePoint(uint32 c)
	{
		if (c < 0x200E)
			return true;
		return !(c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069) || c == 0xFEFF);
	}

	public static void AppendBanned(String message, uint32 cp)
	{
		if (cp == 0xFEFF)
		{
			message.Append("A byte order mark (U+FEFF) may only appear at the start of a document");
			return;
		}
		message.Append("The code point ");
		Hex.AppendCodePointName(message, cp);
		message.Append(" may not appear literally in a KDL document; use an escape in a quoted string");
	}

	[Inline]
	public static int NewlineLength(char8* text, int pos, int end) => KdlChar.NewlineLength(text, pos, end);

	[Inline]
	public static uint64 MayHoldNewline(uint64 word) => Swar.BytesBelow0E(word) | Swar.BytesEqual(word, 0xC2) | Swar.BytesEqual(word, 0xE2);

	public static bool OnlyAsciiNewlines
	{
		[Inline]
		get => false;
	}

	/// @brief KDL's error kind for an input error from FormatCore's cursors and validator.
	/// @param kind The input error's kind.
	/// @return The KDL kind.
	public static KdlErrorKind ErrorKindOf(InputErrorKind kind)
	{
		switch (kind)
		{
		case .InvalidUtf8, .InvalidEncoding, .UnsupportedEncoding:
			return .InvalidUtf8;
		case .InvalidChar, .ByteOrderMark:
			return .DisallowedCodePoint;
		case .ResourceLimitExceeded:
			return .ResourceLimitExceeded;
		case .IoError:
			return .IoError;
		}
	}
}

using System;
using FormatCore;
using internal FormatCore;
using internal KdlBeef;

namespace KdlBeef;

/// Character classification for the KDL reader and writers. The UTF-8, hex and SWAR helpers are
/// FormatCore's (`Utf8`, `Hex`, `Swar`); KDL's banned code points and newlines are `KdlText`.
///
/// KDL's whitespace, newlines and banned code points include multi-byte ones (NEL U+0085, LS U+2028,
/// PS U+2029, the Unicode spaces, the bidi controls), so the byte-level tests here recognize their
/// UTF-8 sequences directly: every non-ASCII one starts with 0xC2, 0xE1, 0xE2, 0xE3 or 0xEF.
internal static class KdlChar
{
	/// Number formatting that is KDL's whatever the current culture: `.` as the decimal point. Private
	/// to KdlBeef, so no culture setting reaches it; read-only after construction.
	internal static System.Globalization.NumberFormatInfo sNumberFormat = new .() ~ delete _;

	/// Identifier characters among the ASCII bytes: 0x21-0x7E except `\ / ( ) { } ; [ ] " # =`.
	static bool[128] sIdentifierAscii = BuildIdentifierAscii();

	static bool[128] BuildIdentifierAscii()
	{
		bool[128] table = default;
		for (int i = 0x21; i < 0x7F; i++)
		{
			char8 c = (char8)i;
			table[i] = !(c == '\\' || c == '/' || c == '(' || c == ')' || c == '{' || c == '}' || c == ';' ||
				c == '[' || c == ']' || c == '"' || c == '#' || c == '=');
		}
		return table;
	}

	/// Identifier scanning by byte: 0 stops (not an identifier character), 1 continues (an ASCII one),
	/// 2 starts a non-ASCII code point to decode. One lookup per byte in ScanIdentifier's loop.
	static uint8[256] sIdentifierByte = BuildIdentifierByte();

	static uint8[256] BuildIdentifierByte()
	{
		uint8[256] table = default;
		for (int i < 128)
			table[i] = sIdentifierAscii[i] ? 1 : 0;
		for (int i = 128; i < 256; i++)
			table[i] = 2;
		return table;
	}

	/// @return 0: not an identifier byte; 1: an ASCII identifier character; 2: the start (or middle) of
	/// a non-ASCII code point, to be decoded.
	[Inline]
	public static uint8 IdentifierByteClass(char8 c)
	{
		return sIdentifierByte[(uint8)c];
	}

	[Inline]
	public static bool IsDigit(char8 c)
	{
		return c >= '0' && c <= '9';
	}

	[Inline]
	public static bool IsIdentifierAscii(char8 c)
	{
		return (uint8)c < 0x80 && sIdentifierAscii[(uint8)c];
	}

	/// Bytes that end a run of plain quoted-string text: `"`, `\`, the control characters up to CR
	/// (newlines among them; a tab stops too, and the caller steps over it) and 0xC2 and 0xE2, the lead
	/// bytes of NEL, LS and PS.
	static bool[256] sQuotedStop = BuildQuotedStop();

	static bool[256] BuildQuotedStop()
	{
		bool[256] table = default;
		for (int i < 256)
			table[i] = i == 0x22 || i == 0x5C || i < 0x0E || i == 0xC2 || i == 0xE2;
		return table;
	}

	/// @brief Skip plain quoted-string text: bytes that cannot end the string, start an escape or be
	/// a newline. Tested 8 bytes at a time; a word holding a candidate is walked byte by byte.
	/// @param text The input.
	/// @param pos Where to start.
	/// @param end The end of the input.
	/// @return The offset of the first stop byte (see sQuotedStop), or `end`.
	public static int ScanQuotedText(char8* text, int pos, int end)
	{
		const uint64 ones = 0x0101010101010101UL;
		const uint64 high = 0x8080808080808080UL;
		uint8* data = (uint8*)text;
		int i = pos;
		while (true)
		{
			while (i + 8 <= end)
			{
				uint64 word = ?;
				Internal.MemCpy(&word, data + i, 8);
				// (w - n*ones) & ~w flags a byte below n; with w ^ c*ones, a byte equal to c. Either may
				// also flag a byte after a real match, which only sends the word to the byte loop.
				uint64 below = (word - 0x0E * ones) & ~word;
				uint64 quote = word ^ (0x22 * ones);
				uint64 backslash = word ^ (0x5C * ones);
				uint64 c2 = word ^ (0xC2 * ones);
				uint64 e2 = word ^ (0xE2 * ones);
				uint64 equal = ((quote - ones) & ~quote) | ((backslash - ones) & ~backslash) | ((c2 - ones) & ~c2) | ((e2 - ones) & ~e2);
				if (((below | equal) & high) != 0)
					break;
				i += 8;
			}
			int limit = Math.Min(i + 8, end);
			while (i < limit && !sQuotedStop[data[i]])
				i++;
			if (i < limit || i >= end)
				return i;
		}
	}

	/// @brief Whether `cp` is `unicode-space`: tab, space, NBSP, U+1680, U+2000-200A, U+202F, U+205F, U+3000.
	public static bool IsUnicodeSpace(char32 cp)
	{
		switch ((uint32)cp)
		{
		case 0x09, 0x20, 0xA0, 0x1680, 0x202F, 0x205F, 0x3000:
			return true;
		default:
			return (uint32)cp >= 0x2000 && (uint32)cp <= 0x200A;
		}
	}

	/// @brief Whether `cp` is a KDL newline: CR, LF, NEL, VT, FF, LS or PS.
	public static bool IsNewline(char32 cp)
	{
		switch ((uint32)cp)
		{
		case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
			return true;
		default:
			return false;
		}
	}

	/// @brief Whether `cp` may not appear literally in a document: U+0000-0008, U+000E-001F, DEL,
	/// surrogates, the bidi controls (U+200E-200F, U+202A-202E, U+2066-2069) and U+FEFF (allowed only
	/// as the first code point, which the caller handles).
	public static bool IsDisallowed(char32 cp)
	{
		uint32 c = (uint32)cp;
		if (c < 0x80)
			return c <= 0x08 || (c >= 0x0E && c <= 0x1F) || c == 0x7F;
		return (c >= 0xD800 && c <= 0xDFFF) || c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) ||
			(c >= 0x2066 && c <= 0x2069) || c == 0xFEFF;
	}

	/// @brief Whether `cp` is an `identifier-char`.
	public static bool IsIdentifierChar(char32 cp)
	{
		if ((uint32)cp < 0x80)
			return sIdentifierAscii[(uint32)cp];
		return !IsUnicodeSpace(cp) && !IsNewline(cp) && !IsDisallowed(cp);
	}

	/// @brief The byte length of the newline at `data[pos]`, or 0 if there is none (CRLF is one newline).
	[Inline]
	public static int NewlineLength(char8* text, int pos, int end)
	{
		uint8 b = (uint8)text[pos];
		if (b > 0x0D && b != 0xC2 && b != 0xE2)
			return 0;
		return NewlineLengthSlow((uint8*)text, pos, end);
	}

	static int NewlineLengthSlow(uint8* data, int pos, int end)
	{
		uint8 b = data[pos];
		switch (b)
		{
		case 0x0A, 0x0B, 0x0C:
			return 1;
		case 0x0D:
			return (pos + 1 < end && data[pos + 1] == 0x0A) ? 2 : 1;
		case 0xC2:
			return (pos + 1 < end && data[pos + 1] == 0x85) ? 2 : 0;
		case 0xE2:
			return (pos + 2 < end && data[pos + 1] == 0x80 && (data[pos + 2] == 0xA8 || data[pos + 2] == 0xA9)) ? 3 : 0;
		default:
			return 0;
		}
	}

	/// @brief The byte length of the `unicode-space` at `data[pos]`, or 0 if there is none.
	[Inline]
	public static int UnicodeSpaceLength(char8* text, int pos, int end)
	{
		char8 c = text[pos];
		if (c == ' ' || c == '\t')
			return 1;
		if ((uint8)c < 0xC2)
			return 0;
		return UnicodeSpaceLengthSlow((uint8*)text, pos, end);
	}

	static int UnicodeSpaceLengthSlow(uint8* data, int pos, int end)
	{
		uint8 b = data[pos];
		if (b == 0xC2)
			return (pos + 1 < end && data[pos + 1] == 0xA0) ? 2 : 0;
		if (pos + 2 >= end)
			return 0;
		uint8 b1 = data[pos + 1];
		uint8 b2 = data[pos + 2];
		switch (b)
		{
		case 0xE1:
			return (b1 == 0x9A && b2 == 0x80) ? 3 : 0;
		case 0xE2:
			if (b1 == 0x80 && ((b2 >= 0x80 && b2 <= 0x8A) || b2 == 0xAF))
				return 3;
			return (b1 == 0x81 && b2 == 0x9F) ? 3 : 0;
		case 0xE3:
			return (b1 == 0x80 && b2 == 0x80) ? 3 : 0;
		default:
			return 0;
		}
	}
}

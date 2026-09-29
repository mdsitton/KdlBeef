using System;
using internal KdlBeef;

namespace KdlBeef;

/// Character classification and UTF-8 helpers for the KDL reader and writers.
///
/// KDL's whitespace, newlines and banned code points include multi-byte ones (NEL U+0085, LS U+2028,
/// PS U+2029, the Unicode spaces, the bidi controls), so the byte-level tests here recognize their
/// UTF-8 sequences directly: every non-ASCII one starts with 0xC2, 0xE1, 0xE2, 0xE3 or 0xEF.
internal static class KdlChar
{
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

	/// @brief Return the byte length of a UTF-8 sequence starting with the given lead byte.
	/// @param lead The lead byte of the sequence.
	/// @return 1-4 for valid lead bytes, 0 for continuation/invalid bytes.
	[Inline]
	public static int Utf8SequenceLength(char8 leadChar)
	{
		uint8 lead = (uint8)leadChar;
		if (lead < 0x80) return 1;
		if ((lead & 0xE0) == 0xC0) return 2;
		if ((lead & 0xF0) == 0xE0) return 3;
		if ((lead & 0xF8) == 0xF0) return 4;
		return 0;
	}

	/// @brief Decode the code point at `data[pos]` from input already checked as UTF-8.
	/// @param data The bytes.
	/// @param pos Byte offset of the lead byte.
	/// @param length Receives the sequence length in bytes.
	/// @return The decoded code point.
	public static char32 Decode(char8* text, int pos, out int length)
	{
		uint8* data = (uint8*)text;
		uint8 b0 = data[pos];
		if (b0 < 0x80)
		{
			length = 1;
			return (char32)b0;
		}
		length = Utf8SequenceLength((char8)b0);
		switch (length)
		{
		case 2:
			return (char32)(((uint32)(b0 & 0x1F) << 6) | (uint32)(data[pos + 1] & 0x3F));
		case 3:
			return (char32)(((uint32)(b0 & 0x0F) << 12) | ((uint32)(data[pos + 1] & 0x3F) << 6) | (uint32)(data[pos + 2] & 0x3F));
		case 4:
			return (char32)(((uint32)(b0 & 0x07) << 18) | ((uint32)(data[pos + 1] & 0x3F) << 12) |
				((uint32)(data[pos + 2] & 0x3F) << 6) | (uint32)(data[pos + 3] & 0x3F));
		default:
			length = 1;
			return (char32)0xFFFD;
		}
	}

	/// @brief Encode a Unicode code point as UTF-8 and append to a String.
	/// @param result The destination string.
	/// @param cp The code point to encode (must be 0–0x10FFFF, excluding surrogates).
	public static void EncodeUtf8(String result, uint32 cp)
	{
		if (cp < 0x80)
		{
			result.Append((char8)cp);
		}
		else if (cp < 0x800)
		{
			result.Append((char8)(0xC0 | (cp >> 6)));
			result.Append((char8)(0x80 | (cp & 0x3F)));
		}
		else if (cp < 0x10000)
		{
			result.Append((char8)(0xE0 | (cp >> 12)));
			result.Append((char8)(0x80 | ((cp >> 6) & 0x3F)));
			result.Append((char8)(0x80 | (cp & 0x3F)));
		}
		else
		{
			result.Append((char8)(0xF0 | (cp >> 18)));
			result.Append((char8)(0x80 | ((cp >> 12) & 0x3F)));
			result.Append((char8)(0x80 | ((cp >> 6) & 0x3F)));
			result.Append((char8)(0x80 | (cp & 0x3F)));
		}
	}

	/// @brief Convert a hex digit character to its numeric value.
	/// @param c The hex digit character.
	/// @return 0–15 on success, or 255 if not a hex digit.
	[Inline]
	public static uint8 HexDigitValue(char8 c)
	{
		uint32 ci = (uint8)c;
		uint32 result = ci - (uint32)'0';
		if (result <= 9)
			return (uint8)result;
		// Convert uppercase to lowercase: 'A'|0x20 == 'a'
		result = (ci | 0x20) - (uint32)'a';
		if (result <= 5)
			return (uint8)(result + 10);
		return 255;
	}

	/// @brief Check that `input` is valid UTF-8 without disallowed code points, and find where the
	/// content starts (after an optional BOM, the only place U+FEFF may appear).
	/// @param input The document bytes.
	/// @param start Receives the offset of the first content byte (0, or 3 after a BOM).
	/// @return .Ok, or .Err at the first invalid byte or disallowed code point.
	public static Result<void, KdlParseError> ValidateDocument(StringView input, out int start)
	{
		uint8* data = (uint8*)input.Ptr;
		int length = input.Length;
		start = (length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) ? 3 : 0;
		int i = start;
		while (i < length)
		{
			// Words of printable ASCII (0x20-0x7E) need no further checks
			while (i + 8 <= length)
			{
				uint64 word = ?;
				Internal.MemCpy(&word, data + i, 8);
				const uint64 ones = 0x0101010101010101UL;
				const uint64 high = 0x8080808080808080UL;
				uint64 below = (word - 0x20 * ones) & ~word;
				uint64 del = word ^ (0x7F * ones);
				if (((word | below | ((del - ones) & ~del)) & high) != 0)
					break;
				i += 8;
			}
			int limit = Math.Min(i + 8, length);
			while (i < limit)
			{
				uint8 b = data[i];
				if (b >= 0x20 && b < 0x7F)
				{
					i++;
					continue;
				}
				if (b < 0x80)
				{
					if (b < 0x09 || (b > 0x0D && b < 0x20) || b == 0x7F)
						return .Err(DisallowedError(input, i, 1, b));
					i++;
					continue;
				}
				int seqLen = Utf8SequenceLength((char8)b);
				if (seqLen == 0)
					return .Err(KdlParseError.At(.InvalidUtf8, "Invalid UTF-8 lead byte", input, i));
				if (i + seqLen > length)
					return .Err(KdlParseError.At(.InvalidUtf8, "Truncated UTF-8 sequence", input, i));
				for (int j = 1; j < seqLen; j++)
				{
					if ((data[i + j] & 0xC0) != 0x80)
						return .Err(KdlParseError.At(.InvalidUtf8, "Invalid UTF-8 continuation byte", input, i + j));
				}
				uint32 cp = (uint32)Decode(input.Ptr, i, var decodedLength);
				if (seqLen == 2 ? cp < 0x80 : seqLen == 3 ? cp < 0x800 : cp < 0x10000)
					return .Err(KdlParseError.At(.InvalidUtf8, "Overlong UTF-8 sequence", input, i));
				if (cp >= 0xD800 && cp <= 0xDFFF)
					return .Err(KdlParseError.At(.InvalidUtf8, "UTF-8-encoded surrogate", input, i));
				if (cp > 0x10FFFF)
					return .Err(KdlParseError.At(.InvalidUtf8, "Code point beyond U+10FFFF", input, i));
				if (cp == 0xFEFF)
					return .Err(KdlParseError.At(.DisallowedCodePoint, "A byte order mark (U+FEFF) may only appear at the start of a document", input, i, seqLen));
				if (IsDisallowed((char32)cp))
					return .Err(DisallowedError(input, i, seqLen, cp));
				i += seqLen;
			}
		}
		return .Ok;
	}

	static KdlParseError DisallowedError(StringView input, int offset, int length, uint32 cp)
	{
		let message = scope String("The code point ");
		AppendCodePointName(message, cp);
		message.Append(" may not appear literally in a KDL document; use an escape in a quoted string");
		return KdlParseError.At(.DisallowedCodePoint, message, input, offset, length);
	}

	/// @brief Append `U+XXXX` (at least four uppercase hex digits).
	/// @param output The string to append to.
	/// @param cp The code point.
	public static void AppendCodePointName(String output, uint32 cp)
	{
		output.Append("U+");
		AppendHex(output, cp, 4);
	}

	/// @brief Append `value` in uppercase hex with at least `minDigits` digits.
	/// @param output The string to append to.
	/// @param value The value.
	/// @param minDigits The minimum number of digits (zero-padded).
	public static void AppendHex(String output, uint32 value, int minDigits)
	{
		int digits = 1;
		while (digits < 8 && (value >> (4 * digits)) != 0)
			digits++;
		digits = Math.Max(digits, minDigits);
		for (int d = digits - 1; d >= 0; d--)
		{
			uint32 nibble = (value >> (4 * d)) & 0xF;
			output.Append(nibble < 10 ? (char8)('0' + nibble) : (char8)('A' + nibble - 10));
		}
	}

	/// @brief The 1-based line and column (in code points) of byte `offset`, counting every KDL
	/// newline (CRLF as one). A leading BOM takes no column.
	/// @param input The document.
	/// @param offset A byte offset into it.
	/// @param line Receives the line.
	/// @param column Receives the column.
	public static void LineAndColumn(StringView input, int offset, out int line, out int column)
	{
		uint8* data = (uint8*)input.Ptr;
		int end = Math.Min(offset, input.Length);
		int i = (input.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) ? 3 : 0;
		line = 1;
		column = 1;
		while (i < end)
		{
			int newline = NewlineLength(input.Ptr, i, input.Length);
			if (newline > 0)
			{
				// A CRLF split by the offset still counts once, at its CR
				i += newline;
				line++;
				column = 1;
				continue;
			}
			i += Math.Max(Utf8SequenceLength(input[i]), 1);
			column++;
		}
	}
}

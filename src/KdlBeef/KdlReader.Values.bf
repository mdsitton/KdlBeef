using System;
using internal KdlBeef;

namespace KdlBeef;

/// Values: strings (identifier, quoted, raw, multi-line), numbers and keywords.
extension KdlReader
{
	/// Reads a string, number or keyword. Unescaped string text goes to `buffer` when it differs from
	/// the input; otherwise the value views the input.
	Result<KdlValue, KdlParseError> ReadValue(String buffer)
	{
		if (mPos >= mEnd)
			return .Err(Unexpected("a value"));
		char8 b = mData[mPos];
		if (b == '"')
			return .Ok(.String(Try!(ReadQuotedString(buffer))));
		if (b == '#')
			return ReadHashToken(buffer);
		if (!CanStartValue(mPos))
			return .Err(Unexpected("a value"));
		return ReadBareToken();
	}

	/// Scans identifier characters from `pos`. @return The offset of the first byte that is not one.
	int ScanIdentifier(int pos)
	{
		int i = pos;
		while (i < mEnd)
		{
			char8 b = mData[i];
			if ((uint8)b < 0x80)
			{
				if (!KdlChar.IsIdentifierAscii(b))
					break;
				i++;
				continue;
			}
			char32 cp = KdlChar.Decode(mData, i, let length);
			if (!KdlChar.IsIdentifierChar(cp))
				break;
			i += length;
		}
		return i;
	}

	/// Reads an identifier string, or a number: a bare token that starts like a number (a digit, or a
	/// `.` followed by a digit, after an optional sign) must be a valid one.
	Result<KdlValue, KdlParseError> ReadBareToken()
	{
		int start = mPos;
		int end = ScanIdentifier(start);
		mPos = end;
		StringView token = View(start, end - start);
		int i = start;
		if (mData[i] == '+' || mData[i] == '-')
			i++;
		if (i < end && (KdlChar.IsDigit(mData[i]) || (mData[i] == '.' && i + 1 < end && KdlChar.IsDigit(mData[i + 1]))))
			return ParseNumber(token, start);
		if (token == "true" || token == "false" || token == "null" || token == "inf" || token == "-inf" || token == "nan")
			return .Err(Fail(.InvalidKeyword, scope $"`{token}` is a keyword: write `#{token}`, or quote it for a string", start, token.Length));
		return .Ok(.String(token));
	}

	/// Reads a raw string (`#"…"#`) or a keyword (`#true`).
	Result<KdlValue, KdlParseError> ReadHashToken(String buffer)
	{
		int start = mPos;
		int hashes = 0;
		while (mPos + hashes < mEnd && mData[mPos + hashes] == '#')
			hashes++;
		if (mPos + hashes < mEnd && mData[mPos + hashes] == '"')
			return .Ok(.String(Try!(ReadRawString(hashes, buffer))));
		if (hashes > 1)
			return .Err(Fail(.UnexpectedChar, "Expected `\"` after the `#`s that open a raw string", start, hashes));
		int wordEnd = ScanIdentifier(start + 1);
		StringView word = View(start + 1, wordEnd - start - 1);
		mPos = wordEnd;
		if (word == "true")
			return .Ok(.Bool(true));
		if (word == "false")
			return .Ok(.Bool(false));
		if (word == "null")
			return .Ok(.Null);
		if (word == "inf")
			return .Ok(.Float(double.PositiveInfinity, default));
		if (word == "-inf")
			return .Ok(.Float(double.NegativeInfinity, default));
		if (word == "nan")
			return .Ok(.Float(double.NaN, default));
		return .Err(Fail(.InvalidKeyword, "Unknown keyword: the keywords are #true, #false, #null, #inf, #-inf and #nan", start, wordEnd - start));
	}

	// Numbers

	/// Parses a bare token that starts like a number.
	Result<KdlValue, KdlParseError> ParseNumber(StringView token, int offset)
	{
		char8* p =token.Ptr;
		int n = token.Length;
		int i = 0;
		bool negative = false;
		if (p[0] == '+' || p[0] == '-')
		{
			negative = p[0] == '-';
			i = 1;
		}

		if (n - i >= 2 && p[i] == '0' && (p[i + 1] == 'x' || p[i + 1] == 'o' || p[i + 1] == 'b'))
		{
			uint32 radix = p[i + 1] == 'x' ? 16 : p[i + 1] == 'o' ? 8 : 2;
			StringView radixName = radix == 16 ? "hexadecimal" : radix == 8 ? "octal" : "binary";
			i += 2;
			if (i >= n || KdlChar.HexDigitValue(p[i]) >= radix)
				return .Err(Fail(.InvalidNumber, scope $"Invalid number `{token}`: a {radixName} prefix must be followed by a digit", offset, n));
			uint64 magnitude = 0;
			bool overflow = false;
			for (; i < n; i++)
			{
				if (p[i] == '_')
					continue;
				uint32 digit = KdlChar.HexDigitValue(p[i]);
				if (digit >= radix)
					return .Err(Fail(.InvalidNumber, scope $"Invalid number `{token}`: `{(char8)p[i]}` is not a {radixName} digit", offset, n));
				if (magnitude > (uint64.MaxValue - digit) / radix)
					overflow = true;
				else
					magnitude = magnitude * radix + digit;
			}
			return .Ok(MakeInteger(negative, magnitude, overflow, token));
		}

		// decimal := sign? integer ('.' integer)? exponent?, integer := digit (digit | '_')*
		bool isFloat = false;
		int exponentSign = 0;
		if (!KdlChar.IsDigit(p[i]))
			return .Err(Fail(.InvalidNumber, scope $"Invalid number `{token}`: a decimal point must have a digit before it (`0.5`)", offset, n));
		i = SkipDigits(p, i, n);
		if (i < n && p[i] == '.')
		{
			isFloat = true;
			i++;
			if (i >= n || !KdlChar.IsDigit(p[i]))
				return .Err(Fail(.InvalidNumber, scope $"Invalid number `{token}`: a decimal point must be followed by a digit", offset, n));
			i = SkipDigits(p, i, n);
		}
		if (i < n && (p[i] == 'e' || p[i] == 'E'))
		{
			isFloat = true;
			i++;
			if (i < n && (p[i] == '+' || p[i] == '-'))
			{
				exponentSign = p[i] == '-' ? -1 : 1;
				i++;
			}
			if (i >= n || !KdlChar.IsDigit(p[i]))
				return .Err(Fail(.InvalidNumber, scope $"Invalid number `{token}`: an exponent must have digits", offset, n));
			i = SkipDigits(p, i, n);
		}
		if (i < n)
			return .Err(Fail(.InvalidNumber, scope $"Invalid number `{token}`: unexpected `{(char8)p[i]}`", offset, n));

		if (!isFloat)
		{
			uint64 magnitude = 0;
			bool overflow = false;
			for (int j = negative || p[0] == '+' ? 1 : 0; j < n; j++)
			{
				if (p[j] == '_')
					continue;
				uint32 digit = (uint32)((uint8)p[j] - (uint8)'0');
				if (magnitude > (uint64.MaxValue - digit) / 10)
					overflow = true;
				else
					magnitude = magnitude * 10 + digit;
			}
			return .Ok(MakeInteger(negative, magnitude, overflow, token));
		}

		let clean = scope String(n);
		for (int j < n)
		{
			if (p[j] != '_')
				clean.Append((char8)p[j]);
		}
		double value;
		switch (double.Parse(clean))
		{
		case .Ok(let parsed):
			value = parsed;
		case .Err:
			// Out of range: the lexeme is kept, and the double is its limit
			value = exponentSign < 0 ? 0.0 : double.PositiveInfinity;
			if (negative)
				value = -value;
		}
		return .Ok(.Float(value, token));
	}

	/// Skips `(digit | '_')*`. @return The offset after them.
	[Inline]
	static int SkipDigits(char8* p, int from, int n)
	{
		int i = from;
		while (i < n && (KdlChar.IsDigit(p[i]) || p[i] == '_'))
			i++;
		return i;
	}

	static KdlValue MakeInteger(bool negative, uint64 magnitude, bool overflow, StringView token)
	{
		if (!overflow)
		{
			if (!negative && magnitude <= (uint64)int64.MaxValue)
				return .Integer((int64)magnitude, token);
			if (negative && magnitude <= (uint64)int64.MaxValue + 1)
				return .Integer((int64)((uint64)0 &- magnitude), token);
		}
		return .BigInteger(token);
	}

	// Strings

	/// Reads a quoted string, single- or multi-line.
	Result<StringView, KdlParseError> ReadQuotedString(String buffer)
	{
		int start = mPos;
		if (PeekAt(1) == '"' && PeekAt(2) == '"')
			return ReadMultiLineString(buffer, start, 0);
		mPos++;
		int bodyStart = mPos;
		// Without escapes the string is a view of the input
		while (true)
		{
			if (mPos >= mEnd)
				return .Err(Fail(.UnterminatedString, "Unterminated string: expected a closing `\"`", start));
			char8 b = mData[mPos];
			if (b == '"')
			{
				mPos++;
				return .Ok(View(bodyStart, mPos - 1 - bodyStart));
			}
			if (b == '\\')
				break;
			if (KdlChar.NewlineLength(mData, mPos, mEnd) > 0)
				return .Err(NewlineInString());
			mPos++;
		}
		buffer.Clear();
		buffer.Append((char8*)mData + bodyStart, mPos - bodyStart);
		while (true)
		{
			if (mPos >= mEnd)
				return .Err(Fail(.UnterminatedString, "Unterminated string: expected a closing `\"`", start));
			char8 b = mData[mPos];
			if (b == '"')
			{
				mPos++;
				return .Ok(buffer);
			}
			if (b == '\\')
			{
				Try!(ReadEscape(mData, ref mPos, mEnd, buffer, -1));
				continue;
			}
			if (KdlChar.NewlineLength(mData, mPos, mEnd) > 0)
				return .Err(NewlineInString());
			buffer.Append((char8)b);
			mPos++;
		}
	}

	KdlParseError NewlineInString()
	{
		return Fail(.UnterminatedString, "A single-line string cannot contain a newline: escape it (`\\n`), or use a multi-line string (`\"\"\"`)", mPos);
	}

	/// Reads a raw string; `mPos` is at the first of `hashes` `#`s.
	Result<StringView, KdlParseError> ReadRawString(int hashes, String buffer)
	{
		int start = mPos;
		mPos += hashes;
		if (PeekAt(1) == '"' && PeekAt(2) == '"')
			return ReadMultiLineString(buffer, start, hashes);
		mPos++;
		int bodyStart = mPos;
		// The first `"` followed by as many `#`s ends the string
		while (true)
		{
			if (mPos >= mEnd)
				return .Err(Fail(.UnterminatedString, "Unterminated raw string: expected a `\"` followed by as many `#`s as opened it", start, hashes + 1));
			char8 b = mData[mPos];
			if (b == '"' && HashesAt(mPos + 1, hashes))
			{
				StringView text = View(bodyStart, mPos - bodyStart);
				mPos += 1 + hashes;
				return .Ok(text);
			}
			if (KdlChar.NewlineLength(mData, mPos, mEnd) > 0)
				return .Err(Fail(.UnterminatedString, "A single-line raw string cannot contain a newline: use a multi-line raw string (`#\"\"\"`)", mPos));
			mPos++;
		}
	}

	[Inline]
	bool HashesAt(int pos, int count)
	{
		if (pos + count > mEnd)
			return false;
		for (int i < count)
		{
			if (mData[pos + i] != '#')
				return false;
		}
		return true;
	}

	/// Reads a multi-line string (raw when `hashes` > 0); `mPos` is at its `"""`, `start` at the
	/// string's first byte.
	Result<StringView, KdlParseError> ReadMultiLineString(String buffer, int start, int hashes)
	{
		mPos += 3;
		int newline = mPos < mEnd ? KdlChar.NewlineLength(mData, mPos, mEnd) : 0;
		if (newline == 0)
			return .Err(Fail(.InvalidMultiLineString, "A multi-line string's opening `\"\"\"` must be followed by a newline", start, mPos - start));
		mPos += newline;
		int bodyStart = mPos;
		int bodyEnd;
		if (hashes == 0)
		{
			while (true)
			{
				if (mPos >= mEnd)
					return .Err(Fail(.UnterminatedString, "Unterminated multi-line string: expected a closing `\"\"\"`", start, 3));
				char8 b = mData[mPos];
				if (b == '\\')
				{
					// An escaped character, which may be a quote, cannot close the string
					mPos += 2;
					continue;
				}
				if (b == '"' && PeekAt(1) == '"' && PeekAt(2) == '"')
					break;
				mPos++;
			}
			bodyEnd = mPos;
			mPos += 3;
		}
		else
		{
			while (true)
			{
				if (mPos >= mEnd)
					return .Err(Fail(.UnterminatedString, "Unterminated multi-line raw string: expected `\"\"\"` followed by as many `#`s as opened it", start, hashes + 3));
				if (mData[mPos] == '"' && PeekAt(1) == '"' && PeekAt(2) == '"' && HashesAt(mPos + 3, hashes))
					break;
				mPos++;
			}
			bodyEnd = mPos;
			mPos += 3 + hashes;
		}
		Try!(Dedent(View(bodyStart, bodyEnd - bodyStart), hashes == 0, buffer, start));
		return .Ok(buffer);
	}

	/// Turns a multi-line string's body (from after the opening newline to before the closing quotes)
	/// into its value, in the spec's order: resolve whitespace escapes; split into lines; the last line
	/// (whitespace only) is the prefix every other line must start with, and is removed with it; lines of
	/// only whitespace become empty; join with LF; then resolve the other escapes.
	Result<void, KdlParseError> Dedent(StringView body, bool escapes, String buffer, int start)
	{
		StringView text = body;
		if (escapes && body.Contains('\\'))
		{
			let resolved = scope:: String(body.Length);
			ResolveWhitespaceEscapes(body, resolved);
			text = resolved;
		}
		char8* data = text.Ptr;
		int length = text.Length;

		int lastLineStart = 0;
		for (int i = 0; i < length;)
		{
			int n = KdlChar.NewlineLength(data, i, length);
			if (n > 0)
			{
				i += n;
				lastLineStart = i;
			}
			else
				i++;
		}
		StringView prefix = text.Substring(lastLineStart);
		if (!IsAllSpace(prefix))
			return .Err(Fail(.InvalidMultiLineString, "A multi-line string's closing `\"\"\"` must be on its own line, after only whitespace", start));

		String joined = escapes ? scope:: String(length) : buffer;
		joined.Clear();
		int lineStart = 0;
		while (lineStart < lastLineStart)
		{
			int lineEnd = lineStart;
			int n;
			while ((n = KdlChar.NewlineLength(data, lineEnd, length)) == 0)
				lineEnd++;
			StringView line = text.Substring(lineStart, lineEnd - lineStart);
			if (lineStart > 0)
				joined.Append('\n');
			if (!IsAllSpace(line))
			{
				if (!line.StartsWith(prefix))
					return .Err(Fail(.InvalidMultiLineString, "Every line of a multi-line string must start with the same whitespace as its closing line", start));
				joined.Append(line.Substring(prefix.Length));
			}
			lineStart = lineEnd + n;
		}

		if (escapes)
		{
			buffer.Clear();
			char8* p =joined.Ptr;
			int end = joined.Length;
			int i = 0;
			while (i < end)
			{
				if (p[i] == '\\')
				{
					Try!(ReadEscape(p, ref i, end, buffer, start));
					continue;
				}
				int runStart = i;
				while (i < end && p[i] != '\\')
					i++;
				buffer.Append((char8*)p + runStart, i - runStart);
			}
		}
		return .Ok;
	}

	/// Copies `body` to `output` without its whitespace escapes (`\` followed by whitespace and
	/// newlines), keeping every other escape as written.
	static void ResolveWhitespaceEscapes(StringView body, String output)
	{
		char8* p =body.Ptr;
		int n = body.Length;
		int i = 0;
		while (i < n)
		{
			if (p[i] == '\\' && i + 1 < n)
			{
				int k = i + 1;
				int skipped = SkipSpaceAndNewlines(p, k, n);
				if (skipped > k)
				{
					i = skipped;
					continue;
				}
				int length = Math.Max(KdlChar.Utf8SequenceLength(p[k]), 1);
				output.Append((char8*)p + i, Math.Min(1 + length, n - i));
				i = k + length;
				continue;
			}
			output.Append((char8)p[i]);
			i++;
		}
	}

	/// @return The offset after the Unicode spaces and newlines starting at `pos`.
	static int SkipSpaceAndNewlines(char8* p, int pos, int end)
	{
		int i = pos;
		while (i < end)
		{
			int n = KdlChar.UnicodeSpaceLength(p, i, end);
			if (n == 0)
				n = KdlChar.NewlineLength(p, i, end);
			if (n == 0)
				break;
			i += n;
		}
		return i;
	}

	static bool IsAllSpace(StringView text)
	{
		char8* p =text.Ptr;
		int i = 0;
		while (i < text.Length)
		{
			int n = KdlChar.UnicodeSpaceLength(p, i, text.Length);
			if (n == 0)
				return false;
			i += n;
		}
		return true;
	}

	/// Decodes the escape at `data[pos]` (a `\`) into `output` and advances past it. Errors point at the
	/// escape when `fixedErrorOffset` is negative (`data` is the input), else at `fixedErrorOffset`.
	Result<void, KdlParseError> ReadEscape(char8* data, ref int pos, int end, String output, int fixedErrorOffset)
	{
		int errorAt = fixedErrorOffset >= 0 ? fixedErrorOffset : pos;
		pos++;
		if (pos >= end)
			return .Err(Fail(.UnterminatedString, "Unterminated string: expected a closing `\"`", errorAt));
		char8 c = data[pos];
		switch (c)
		{
		case 'n': output.Append('\n');
		case 'r': output.Append('\r');
		case 't': output.Append('\t');
		case '\\': output.Append('\\');
		case '"': output.Append('"');
		case 'b': output.Append((char8)0x08);
		case 'f': output.Append((char8)0x0C);
		case 's': output.Append(' ');
		case 'u':
			pos++;
			if (pos >= end || data[pos] != '{')
				return .Err(Fail(.InvalidEscape, "Expected `{` after `\\u`: a Unicode escape is `\\u{1F600}`", errorAt));
			pos++;
			uint32 cp = 0;
			int digits = 0;
			while (pos < end && data[pos] != '}')
			{
				uint8 digit = KdlChar.HexDigitValue(data[pos]);
				if (digit == 255)
					return .Err(Fail(.InvalidEscape, "A Unicode escape `\\u{…}` must contain only hex digits", errorAt));
				if (++digits > 6)
					return .Err(Fail(.InvalidEscape, "A Unicode escape `\\u{…}` has at most 6 hex digits", errorAt));
				cp = cp * 16 + digit;
				pos++;
			}
			if (pos >= end)
				return .Err(Fail(.InvalidEscape, "Expected `}` to close the Unicode escape", errorAt));
			if (digits == 0)
				return .Err(Fail(.InvalidEscape, "A Unicode escape `\\u{…}` needs at least one hex digit", errorAt));
			if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
				return .Err(Fail(.InvalidEscape, "A Unicode escape must be a Unicode scalar value (not a surrogate, at most 10FFFF)", errorAt));
			KdlChar.EncodeUtf8(output, cp);
		default:
			int skipped = SkipSpaceAndNewlines(data, pos, end);
			if (skipped > pos)
			{
				// A whitespace escape removes the backslash and all the whitespace after it
				pos = skipped;
				return .Ok;
			}
			if (c == '/')
				return .Err(Fail(.InvalidEscape, "`\\/` is not an escape in KDL 2: write `/`", errorAt, 2));
			return .Err(Fail(.InvalidEscape, "Invalid escape: the escapes are \\n \\r \\t \\\\ \\\" \\b \\f \\s \\u{…} and `\\` before whitespace", errorAt, 2));
		}
		pos++;
		return .Ok;
	}
}

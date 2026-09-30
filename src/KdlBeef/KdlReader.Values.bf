using System;
using internal KdlBeef;

namespace KdlBeef;

/// Values: strings (identifier, quoted, raw, multi-line), numbers and keywords.
extension KdlReaderCore<TCursor>
{
	/// Reads a string, number or keyword. Unescaped string text goes to `buffer` when it differs from
	/// the input; otherwise the value views the input.
	Result<KdlValue, KdlFailure> ReadValue(String buffer)
	{
		int start = mPos;
		KdlValue value = Try!(ReadValueToken(buffer));
		if (mConfig.MaxStringBytes > 0 && value case .String(let s) && s.Length > mConfig.MaxStringBytes)
			return .Err(Fail(.ResourceLimitExceeded, scope $"A string of {s.Length} bytes exceeds MaxStringBytes ({mConfig.MaxStringBytes})", start, mPos - start));
		return value;
	}

	/// Decoding into `buffer` went past MaxStringBytes: checked as the text grows, so a long string fails
	/// before its whole value is built (a decoded string is never longer than its source, so the copies
	/// are bounded by the input, and a stream's by MaxTokenBytes)
	[Inline]
	bool PastStringLimit(String buffer)
	{
		return mConfig.MaxStringBytes > 0 && buffer.Length > mConfig.MaxStringBytes;
	}

	KdlFailure StringLimitError(int start)
	{
		return Fail(.ResourceLimitExceeded, scope $"A string of more than {mConfig.MaxStringBytes} bytes exceeds MaxStringBytes ({mConfig.MaxStringBytes})", start, Math.Max(mPos - start, 1));
	}

	Result<KdlValue, KdlFailure> ReadValueToken(String buffer)
	{
		if (!Avail(mPos))
			return .Err(Unexpected("a value"));
		char8 b = mData[mPos];
		if (b == '"' || b == '#')
		{
			// Recovery skips a string whole from its start: an error inside it leaves mPos anywhere
			mStringStart = mPos;
			let value = (b == '"') ? KdlValue.String(Try!(ReadQuotedString(buffer))) : Try!(ReadHashToken(buffer));
			mStringStart = -1;
			return .Ok(value);
		}
		if (!CanStartValue(mPos))
			return .Err(Unexpected("a value"));
		return ReadBareToken();
	}

	/// Scans identifier characters from `pos`. @return The offset of the first byte that is not one.
	int ScanIdentifier(int pos)
	{
		int i = pos;
		while (Avail(i))
		{
			char8 b = mData[i];
			if ((uint8)b < 0x80)
			{
				if (!KdlChar.IsIdentifierAscii(b))
					break;
				i++;
				continue;
			}
			char32 cp = DecodeAt(i, let length);
			if (!KdlChar.IsIdentifierChar(cp))
				break;
			i += length;
		}
		return i;
	}

	/// Reads an identifier string, or a number: a bare token that starts like a number (a digit, or a
	/// `.` followed by a digit, after an optional sign) must be a valid one.
	Result<KdlValue, KdlFailure> ReadBareToken()
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
	Result<KdlValue, KdlFailure> ReadHashToken(String buffer)
	{
		int start = mPos;
		int hashes = 0;
		while (Avail(mPos + hashes) && mData[mPos + hashes] == '#')
			hashes++;
		if (Avail(mPos + hashes) && mData[mPos + hashes] == '"')
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
	Result<KdlValue, KdlFailure> ParseNumber(StringView token, int offset)
	{
		// The common forms first; anything else (radixes, underscores, long or invalid tokens) falls
		// through to the full parse below, so errors are unchanged
		if (TryParsePlainInteger(token, var plainInteger))
			return .Ok(.Integer(plainInteger, token));
		if (TryParsePlainFloat(token, var plainFloat))
			return .Ok(.Float(plainFloat, token));

		char8* p = token.Ptr;
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
			StringView radixName = radix == 16 ? "a hexadecimal" : radix == 8 ? "an octal" : "a binary";
			i += 2;
			if (i >= n || KdlChar.HexDigitValue(p[i]) >= radix)
				return .Err(Fail(.InvalidNumber, scope $"Invalid number `{token}`: {radixName} prefix must be followed by a digit", offset, n));
			uint64 magnitude = 0;
			bool overflow = false;
			for (; i < n; i++)
			{
				if (p[i] == '_')
					continue;
				uint32 digit = KdlChar.HexDigitValue(p[i]);
				if (digit >= radix)
					return .Err(Fail(.InvalidNumber, scope $"Invalid number `{token}`: `{(char8)p[i]}` is not {radixName} digit", offset, n));
				if (magnitude > (uint64.MaxValue - digit) / radix)
					overflow = true;
				else
					magnitude = magnitude * radix + digit;
			}
			return .Ok(MakeInteger(negative, magnitude, overflow, token));
		}

		// decimal := sign? integer ('.' integer)? exponent?, integer := digit (digit | '_')*
		bool isFloat = false;
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
				i++;
			if (i >= n || !KdlChar.IsDigit(p[i]))
				return .Err(Fail(.InvalidNumber, scope $"Invalid number `{token}`: an exponent must have digits", offset, n));
			i = SkipDigits(p, i, n);
		}
		if (i < n)
			return .Err(Fail(.InvalidNumber, scope $"Invalid number `{token}`: unexpected `{(char8)p[i]}` (text that starts like a number must be one; quote it for a string)", offset, n));

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

		// Double.Parse takes no underscores: copy without them (on the stack for any sane length)
		StringView digits = token;
		if (token.Contains('_'))
		{
			char8* clean = n <= 128 ? scope:: char8[128]* : scope:: char8[n]*;
			int length = 0;
			for (int j < n)
			{
				if (p[j] != '_')
					clean[length++] = p[j];
			}
			digits = .(clean, length);
		}
		// KDL's `.`, whatever the current culture's decimal separator. Out of range is not a failure: the
		// parse gives ±infinity or ±0 (and the lexeme is kept); a failure would be a bug, not an overflow
		switch (double.Parse(digits, KdlChar.sNumberFormat))
		{
		case .Ok(let parsed):
			return .Ok(.Float(parsed, token));
		case .Err:
			return .Err(Fail(.InvalidNumber, scope $"The number `{token}` could not be converted to a double", offset, n));
		}
	}

	/// One-pass parse of an optional sign and 1–18 decimal digits (leading zeros allowed, as in KDL):
	/// valid as written and unable to overflow int64. Anything else returns false and takes the full
	/// path. (TomlBeef's TryParsePlainInteger.)
	[Inline]
	static bool TryParsePlainInteger(StringView token, out int64 value)
	{
		value = 0;
		char8* ptr = token.Ptr;
		int length = token.Length;
		int pos = (ptr[0] == '-' || ptr[0] == '+') ? 1 : 0;
		int digits = length - pos;
		if (digits < 1 || digits > 18)
			return false;
		int64 result = 0;
		for (int i = pos; i < length; i++)
		{
			uint8 digit = (uint8)ptr[i] - (uint8)'0';
			if (digit > 9)
				return false;
			result = result * 10 + digit;
		}
		value = (ptr[0] == '-') ? -result : result;
		return true;
	}

	/// Powers of ten that a double holds exactly (5^22 < 2^53).
	const double[23] cExactPowersOf10 = .(1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12,
		1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22);

	/// One-pass parse of a decimal without underscores, `[sign]digits[.digits][(e|E)[sign]digits]`
	/// with a fraction or exponent, whose digits fit an exact double mantissa (at most 2^53, 19 digits)
	/// and whose decimal exponent is within ±22. Then mantissa and power of ten are both exact, and one
	/// IEEE multiply or divide rounds correctly (Clinger's fast path), bit-identical to Double.Parse.
	/// Anything else returns false and takes the full path. (TomlBeef's TryParsePlainFloat, with KDL's
	/// leading zeros allowed.)
	static bool TryParsePlainFloat(StringView token, out double value)
	{
		value = 0;
		char8* ptr = token.Ptr;
		int length = token.Length;
		int pos = (ptr[0] == '-' || ptr[0] == '+') ? 1 : 0;

		uint64 mantissa = 0;
		int intStart = pos;
		while (pos < length && (uint8)ptr[pos] - (uint8)'0' <= 9 && pos - intStart < 19)
			mantissa = mantissa * 10 + ((uint8)ptr[pos++] - (uint8)'0');
		int intDigits = pos - intStart;
		if (intDigits == 0)
			return false;

		int exponent = 0;
		bool isFloat = false;
		if (pos < length && ptr[pos] == '.')
		{
			pos++;
			int fracStart = pos;
			while (pos < length && (uint8)ptr[pos] - (uint8)'0' <= 9 && pos - fracStart + intDigits < 19)
				mantissa = mantissa * 10 + ((uint8)ptr[pos++] - (uint8)'0');
			if (pos == fracStart)
				return false;
			exponent = -(pos - fracStart);
			isFloat = true;
		}
		if (pos < length && (ptr[pos] == 'e' || ptr[pos] == 'E'))
		{
			pos++;
			bool negativeExponent = false;
			if (pos < length && (ptr[pos] == '-' || ptr[pos] == '+'))
				negativeExponent = ptr[pos++] == '-';
			int expStart = pos;
			int expValue = 0;
			while (pos < length && (uint8)ptr[pos] - (uint8)'0' <= 9 && pos - expStart < 4)
				expValue = expValue * 10 + ((uint8)ptr[pos++] - (uint8)'0');
			if (pos == expStart)
				return false;
			exponent += negativeExponent ? -expValue : expValue;
			isFloat = true;
		}
		// A leftover character (an underscore, a 20th digit, a 5-digit exponent, anything invalid) or a
		// plain integer goes to the full path
		if (pos != length || !isFloat || mantissa > (1UL << 53) || exponent < -22 || exponent > 22)
			return false;

		double result = (double)mantissa;
		if (exponent < 0)
			result /= cExactPowersOf10[-exponent];
		else
			result *= cExactPowersOf10[exponent];
		value = (ptr[0] == '-') ? -result : result;
		return true;
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
	Result<StringView, KdlFailure> ReadQuotedString(String buffer)
	{
		int start = mPos;
		if (PeekAt(1) == '"' && PeekAt(2) == '"')
			return ReadMultiLineString(buffer, start, 0);
		mPos++;
		int bodyStart = mPos;
		// Without escapes the string is a view of the input
		while (true)
		{
			mPos = ScanQuoted(mPos);
			if (!Avail(mPos))
				return .Err(Fail(.UnterminatedString, "Unterminated string: expected a closing `\"`", start));
			char8 b = mData[mPos];
			if (b == '"')
			{
				mPos++;
				return .Ok(View(bodyStart, mPos - 1 - bodyStart));
			}
			if (b == '\\')
				break;
			if (NewlineAt(mPos) > 0)
				return .Err(NewlineInString());
			mPos++;
		}
		buffer.Clear();
		buffer.Append(mData + bodyStart, mPos - bodyStart);
		while (true)
		{
			if (PastStringLimit(buffer))
				return .Err(StringLimitError(start));
			int runStart = mPos;
			mPos = ScanQuoted(mPos);
			buffer.Append(mData + runStart, mPos - runStart);
			if (!Avail(mPos))
				return .Err(Fail(.UnterminatedString, "Unterminated string: expected a closing `\"`", start));
			char8 b = mData[mPos];
			if (b == '"')
			{
				mPos++;
				if (PastStringLimit(buffer))
					return .Err(StringLimitError(start));
				return .Ok(buffer);
			}
			if (b == '\\')
			{
				// The longest escape, `\u{10FFFF}`, is 10 bytes
				AvailN(mPos, 12);
				if (Try!(ReadEscape(mData, ref mPos, mEnd, buffer, -1)))
				{
					// A whitespace escape may go on past the window
					while (Avail(mPos))
					{
						int n = SpaceAt(mPos);
						if (n == 0)
							n = NewlineAt(mPos);
						if (n == 0)
							break;
						mPos += n;
					}
				}
				continue;
			}
			if (NewlineAt(mPos) > 0)
				return .Err(NewlineInString());
			buffer.Append((char8)b);
			mPos++;
		}
	}

	/// Skips plain quoted-string text from `pos` (see KdlChar.ScanQuotedText), across refills.
	/// @return The offset of the first stop byte, or the end of the input.
	int ScanQuoted(int pos)
	{
		int p = pos;
		while (true)
		{
			p = KdlChar.ScanQuotedText(mData, p, mEnd);
			if (p < mEnd || !Grow(p, 1))
				return p;
		}
	}

	KdlFailure NewlineInString()
	{
		return Fail(.UnterminatedString, "A single-line string cannot contain a newline: escape it (`\\n`), or use a multi-line string (`\"\"\"`)", mPos);
	}

	/// Reads a raw string; `mPos` is at the first of `hashes` `#`s.
	Result<StringView, KdlFailure> ReadRawString(int hashes, String buffer)
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
			if (!Avail(mPos))
				return .Err(UnclosedRawString(start, hashes));
			char8 b = mData[mPos];
			if (b == '"' && HashesAt(mPos + 1, hashes))
			{
				StringView text = View(bodyStart, mPos - bodyStart);
				mPos += 1 + hashes;
				return .Ok(text);
			}
			if (NewlineAt(mPos) > 0)
				return .Err(UnclosedRawString(start, hashes));
			mPos++;
		}
	}

	/// A single-line raw string that reaches the end of its line or the input unclosed.
	KdlFailure UnclosedRawString(int start, int hashes)
	{
		let closing = scope String("\"");
		closing.Append('#', hashes);
		return Fail(.UnterminatedString, scope $"This raw string is not closed on its line: expected `{closing}` (a multi-line raw string starts with `{StringView(mData + start, hashes)}\"\"\"`)", start, hashes + 1);
	}

	[Inline]
	bool HashesAt(int pos, int count)
	{
		if (!AvailN(pos, count))
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
	Result<StringView, KdlFailure> ReadMultiLineString(String buffer, int start, int hashes)
	{
		mPos += 3;
		int newline = Avail(mPos) ? NewlineAt(mPos) : 0;
		if (newline == 0)
			return .Err(Fail(.InvalidMultiLineString, "A multi-line string's opening `\"\"\"` must be followed by a newline", start, mPos - start));
		mPos += newline;
		int bodyStart = mPos;
		int bodyEnd;
		if (hashes == 0)
		{
			while (true)
			{
				if (!Avail(mPos))
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
				if (!Avail(mPos))
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
	Result<void, KdlFailure> Dedent(StringView body, bool escapes, String buffer, int start)
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
		// Errors point at the offending line, unless escapes were resolved into a copy
		int bodyOffset = text.Ptr == body.Ptr ? (int)(body.Ptr - mData) : -1;

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
			return .Err(Fail(.InvalidMultiLineString, "A multi-line string's closing `\"\"\"` must be on its own line, after only whitespace", bodyOffset >= 0 ? bodyOffset + lastLineStart : start));

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
					return .Err(Fail(.InvalidMultiLineString, "Every line of a multi-line string must start with the same whitespace as its closing line", bodyOffset >= 0 ? bodyOffset + lineStart : start));
				joined.Append(line.Substring(prefix.Length));
			}
			// Without escapes the joined lines are the value
			if (!escapes && PastStringLimit(joined))
				return .Err(StringLimitError(start));
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
				if (PastStringLimit(buffer))
					return .Err(StringLimitError(start));
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
	/// @return Whether it was a whitespace escape (which removes the whitespace after it up to `end`).
	Result<bool, KdlFailure> ReadEscape(char8* data, ref int pos, int end, String output, int fixedErrorOffset)
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
				return .Err(Fail(.InvalidEscape, "A Unicode escape must be a Unicode scalar value (not a surrogate, at most U+10FFFF)", errorAt));
			KdlChar.EncodeUtf8(output, cp);
		default:
			int skipped = SkipSpaceAndNewlines(data, pos, end);
			if (skipped > pos)
			{
				// A whitespace escape removes the backslash and all the whitespace after it
				pos = skipped;
				return .Ok(true);
			}
			if (c == '/')
				return .Err(Fail(.InvalidEscape, "`\\/` is not an escape in KDL 2: write `/`", errorAt, 2));
			return .Err(Fail(.InvalidEscape, "Invalid escape: the escapes are \\n \\r \\t \\\\ \\\" \\b \\f \\s \\u{…} and `\\` before whitespace", errorAt, 2));
		}
		pos++;
		return .Ok(false);
	}
}

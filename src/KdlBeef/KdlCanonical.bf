using System;
using System.Collections;
using internal KdlBeef;

namespace KdlBeef;

/// The canonical KDL form, the one the official test suite's `expected_kdl` files are written in:
/// no comments or blank lines, one node per line, 4-space indentation, arguments in order, properties
/// deduplicated (the last wins) and sorted by key, strings bare when they are valid identifiers and
/// quoted otherwise, integers in decimal, floats with their written mantissa and an `E±` exponent.
public static class KdlCanonical
{
	/// One open node's pending output.
	class PendingNode
	{
		/// Indentation, annotation, name and arguments, formatted.
		public String mHead ~ delete _;
		/// Property keys (raw) and values (formatted), back to back.
		public String mPropertyText ~ delete _;
		public List<PropertySpan> mProperties ~ delete _;
		/// The head has been written, with ` {`: children follow.
		public bool mOpened;

		public this()
		{
			mHead = new .();
			mPropertyText = new .();
			mProperties = new .();
		}
	}

	struct PropertySpan
	{
		public int32 mKeyStart;
		public int32 mKeyLength;
		public int32 mValueStart;
		public int32 mValueLength;
		public int32 mIndex;
	}

	/// @brief Reformat a KDL document into canonical form, reading it with a KdlReader (no document is
	/// built; memory grows with nesting depth and the properties of one node, not with the input).
	/// @param input The document text.
	/// @param output The string to append the canonical text to (ends with a newline; an empty
	/// document is a single newline).
	/// @return .Ok, or the document's first error (the output then holds what was written before it).
	public static Result<void, KdlParseError> Format(StringView input, String output)
	{
		let reader = scope KdlReader(input);
		let pending = scope List<PendingNode>();
		defer { ClearAndDeleteItems!(pending); }
		int startLength = output.Length;
		while (true)
		{
			switch (Try!(reader.Next()))
			{
			case .StartNode:
				int depth = reader.Depth;
				if (depth > 0 && !pending[depth - 1].mOpened)
				{
					let parent = pending[depth - 1];
					WriteHead(parent, output);
					output.Append(" {\n");
					parent.mOpened = true;
				}
				if (depth == pending.Count)
					pending.Add(new PendingNode());
				let node = pending[depth];
				node.mHead.Clear();
				node.mPropertyText.Clear();
				node.mProperties.Clear();
				node.mOpened = false;
				node.mHead.Append(' ', depth * 4);
				if (reader.HasAnnotation)
					AppendAnnotation(node.mHead, reader.Annotation);
				AppendString(node.mHead, reader.Name);

			case .Argument:
				let node = pending[reader.Depth];
				node.mHead.Append(' ');
				if (reader.HasAnnotation)
					AppendAnnotation(node.mHead, reader.Annotation);
				AppendValue(node.mHead, reader.Value);

			case .Property:
				let node = pending[reader.Depth];
				PropertySpan span;
				span.mIndex = (int32)node.mProperties.Count;
				span.mKeyStart = (int32)node.mPropertyText.Length;
				span.mKeyLength = (int32)reader.Name.Length;
				node.mPropertyText.Append(reader.Name);
				span.mValueStart = (int32)node.mPropertyText.Length;
				if (reader.HasAnnotation)
					AppendAnnotation(node.mPropertyText, reader.Annotation);
				AppendValue(node.mPropertyText, reader.Value);
				span.mValueLength = (int32)(node.mPropertyText.Length - span.mValueStart);
				node.mProperties.Add(span);

			case .EndNode:
				let node = pending[reader.Depth];
				if (node.mOpened)
				{
					output.Append(' ', reader.Depth * 4);
					output.Append("}\n");
				}
				else
				{
					WriteHead(node, output);
					output.Append('\n');
				}

			case .EndOfDocument:
				if (output.Length == startLength)
					output.Append('\n');
				return .Ok;
			}
		}
	}

	/// Writes the node's head and its properties, deduplicated and sorted by key.
	static void WriteHead(PendingNode node, String output)
	{
		output.Append(node.mHead);
		if (node.mProperties.IsEmpty)
			return;
		String text = node.mPropertyText;
		// By key, the last occurrence first; then the first of each run of equal keys is the one kept
		node.mProperties.Sort(scope (a, b) =>
			{
				int cmp = StringView.Compare(StringView(text, a.mKeyStart, a.mKeyLength), StringView(text, b.mKeyStart, b.mKeyLength));
				return cmp != 0 ? cmp : b.mIndex <=> a.mIndex;
			});
		StringView previousKey = default;
		for (let span in node.mProperties)
		{
			StringView key = StringView(text, span.mKeyStart, span.mKeyLength);
			if (@span.Index > 0 && key == previousKey)
				continue;
			previousKey = key;
			output.Append(' ');
			AppendString(output, key);
			output.Append('=');
			output.Append(StringView(text, span.mValueStart, span.mValueLength));
		}
	}

	/// @brief Append `(type)`.
	internal static void AppendAnnotation(String output, StringView annotation)
	{
		output.Append('(');
		AppendString(output, annotation);
		output.Append(')');
	}

	/// @brief Append a value in canonical form.
	internal static void AppendValue(String output, KdlValue value)
	{
		switch (value)
		{
		case .Null:
			output.Append("#null");
		case .Bool(let v):
			output.Append(v ? "#true" : "#false");
		case .Integer(let v, ?):
			v.ToString(output);
		case .BigInteger(let text):
			AppendIntegerLexeme(output, text);
		case .Float(let v, let text):
			if (v.IsNaN)
				output.Append("#nan");
			else if (!text.IsEmpty)
				AppendFloatLexeme(output, text);
			else if (v.IsInfinity)
				output.Append(v > 0 ? "#inf" : "#-inf");
			else
				AppendDouble(output, v);
		case .String(let s):
			AppendString(output, s);
		}
	}

	/// @brief Append a string bare when it is a valid identifier string, else quoted.
	internal static void AppendString(String output, StringView s)
	{
		if (IsBareIdentifier(s))
			output.Append(s);
		else
			AppendQuoted(output, s);
	}

	/// @brief Whether `s` can be written as an identifier string: non-empty, only identifier
	/// characters, not starting like a number and not one of the bare keywords.
	internal static bool IsBareIdentifier(StringView s)
	{
		if (s.IsEmpty)
			return false;
		char8* p =s.Ptr;
		int n = s.Length;
		int i = 0;
		while (i < n)
		{
			if ((uint8)p[i] < 0x80)
			{
				if (!KdlChar.IsIdentifierAscii(p[i]))
					return false;
				i++;
				continue;
			}
			char32 cp = KdlChar.Decode(p, i, let length);
			if (!KdlChar.IsIdentifierChar(cp))
				return false;
			i += length;
		}
		int first = (p[0] == '+' || p[0] == '-') ? 1 : 0;
		if (first < n && (KdlChar.IsDigit(p[first]) || (p[first] == '.' && first + 1 < n && KdlChar.IsDigit(p[first + 1]))))
			return false;
		return !(s == "true" || s == "false" || s == "null" || s == "inf" || s == "-inf" || s == "nan");
	}

	/// @brief Append `s` as a quoted string, escaping quotes, backslashes, the control characters with
	/// short escapes, and as `\u{…}` every code point that may not appear literally (including the
	/// newlines other than those with short escapes).
	internal static void AppendQuoted(String output, StringView s)
	{
		output.Append('"');
		char8* p =s.Ptr;
		int n = s.Length;
		int i = 0;
		while (i < n)
		{
			char8 b = p[i];
			if (IsPlainQuotedChar(b))
			{
				int runStart = i;
				while (i < n && IsPlainQuotedChar(p[i]))
					i++;
				output.Append(p + runStart, i - runStart);
				continue;
			}
			switch (b)
			{
			case '"': output.Append("\\\"");
			case '\\': output.Append("\\\\");
			case (char8)0x08: output.Append("\\b");
			case (char8)0x0C: output.Append("\\f");
			case '\n': output.Append("\\n");
			case '\r': output.Append("\\r");
			case '\t': output.Append("\\t");
			default:
				char32 cp = KdlChar.Decode(p, i, let length);
				if (KdlChar.IsDisallowed(cp) || KdlChar.IsNewline(cp))
				{
					output.Append("\\u{");
					KdlChar.AppendHex(output, (uint32)cp, 1);
					output.Append('}');
				}
				else
					output.Append((char8*)p + i, length);
				i += length;
				continue;
			}
			i++;
		}
		output.Append('"');
	}

	/// Printable ASCII other than `"` and `\`: written as is inside quotes.
	[Inline]
	static bool IsPlainQuotedChar(char8 c)
	{
		return (uint8)c >= 0x20 && (uint8)c < 0x7F && c != '"' && c != '\\';
	}

	/// @brief Append a float lexeme as written, canonicalized: no underscores or `+` sign, no leading
	/// zeros, `E` with an explicit sign.
	internal static void AppendFloatLexeme(String output, StringView text)
	{
		char8* p =text.Ptr;
		int n = text.Length;
		int i = 0;
		if (p[0] == '-')
			output.Append('-');
		if (p[0] == '-' || p[0] == '+')
			i++;
		i = AppendDigits(output, p, i, n, true);
		if (i < n && p[i] == '.')
		{
			output.Append('.');
			i = AppendDigits(output, p, i + 1, n, false);
		}
		if (i < n && (p[i] == 'e' || p[i] == 'E'))
		{
			i++;
			output.Append('E');
			if (i < n && (p[i] == '+' || p[i] == '-'))
				output.Append((char8)p[i++]);
			else
				output.Append('+');
			AppendDigits(output, p, i, n, true);
		}
	}

	/// Appends the digits from `i` (skipping underscores) up to a non-digit. @return Its offset.
	static int AppendDigits(String output, char8* p, int from, int n, bool trimLeadingZeros)
	{
		int i = from;
		bool any = false;
		while (i < n && (KdlChar.IsDigit(p[i]) || p[i] == '_'))
		{
			char8 b = p[i++];
			if (b == '_' || (trimLeadingZeros && !any && b == '0'))
				continue;
			output.Append(b);
			any = true;
		}
		if (!any && trimLeadingZeros)
			output.Append('0');
		return i;
	}

	/// @brief Append an integer lexeme of any size (any radix, underscores, sign) in decimal.
	internal static void AppendIntegerLexeme(String output, StringView text)
	{
		char8* p =text.Ptr;
		int n = text.Length;
		int i = 0;
		bool negative = false;
		if (p[0] == '-' || p[0] == '+')
		{
			negative = p[0] == '-';
			i++;
		}
		uint32 radix = 10;
		if (n - i >= 2 && p[i] == '0' && (p[i + 1] == 'x' || p[i + 1] == 'o' || p[i + 1] == 'b'))
		{
			radix = p[i + 1] == 'x' ? 16 : p[i + 1] == 'o' ? 8 : 2;
			i += 2;
		}
		// Little-endian base-2^32 limbs: multiply-add each digit, then divide by 10^9 repeatedly
		let limbs = scope List<uint32>();
		for (; i < n; i++)
		{
			if (p[i] == '_')
				continue;
			uint64 carry = KdlChar.HexDigitValue(p[i]);
			for (int k < limbs.Count)
			{
				uint64 product = (uint64)limbs[k] * radix + carry;
				limbs[k] = (uint32)product;
				carry = product >> 32;
			}
			if (carry != 0)
				limbs.Add((uint32)carry);
		}
		while (!limbs.IsEmpty && limbs.Back == 0)
			limbs.PopBack();
		if (limbs.IsEmpty)
		{
			output.Append('0');
			return;
		}
		let chunks = scope List<uint32>();
		while (!limbs.IsEmpty)
		{
			uint64 remainder = 0;
			for (int k = limbs.Count - 1; k >= 0; k--)
			{
				uint64 current = (remainder << 32) | limbs[k];
				limbs[k] = (uint32)(current / 1000000000);
				remainder = current % 1000000000;
			}
			chunks.Add((uint32)remainder);
			while (!limbs.IsEmpty && limbs.Back == 0)
				limbs.PopBack();
		}
		if (negative)
			output.Append('-');
		chunks.Back.ToString(output);
		for (int k = chunks.Count - 2; k >= 0; k--)
		{
			let digits = scope String();
			chunks[k].ToString(digits);
			output.Append('0', 9 - digits.Length);
			output.Append(digits);
		}
	}

	/// @brief Append a double that has no written form: the shortest round-trip digits, with `.0`
	/// added to integral values and the exponent as `E±`.
	internal static void AppendDouble(String output, double v)
	{
		let text = scope String();
		v.ToString(text);
		int e = text.IndexOf('E');
		if (e < 0)
			e = text.IndexOf('e');
		StringView mantissa = e >= 0 ? text.Substring(0, e) : text;
		output.Append(mantissa);
		if (!mantissa.Contains('.'))
			output.Append(".0");
		if (e >= 0)
		{
			output.Append('E');
			StringView exponent = text.Substring(e + 1);
			if (!exponent.StartsWith('-') && !exponent.StartsWith('+'))
				output.Append('+');
			output.Append(exponent);
		}
	}
}

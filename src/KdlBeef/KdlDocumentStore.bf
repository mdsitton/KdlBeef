using System;
using FormatCore;
using internal FormatCore;
using internal KdlBeef;

namespace KdlBeef;

/// @brief Owns the text of a document (names, keys, annotations, strings, number lexemes) in a
/// FormatCore TextArena: chunks that never move, kept across resets, so reading into a document again
/// reuses the previous document's memory (freeing it instead lets glibc trim the heap, and the next
/// parse page-faults every page back in: TomlBeef measured up to 40% of parse time on large inputs).
internal class KdlDocumentStore
{
	TextArena mArena ~ delete _;

	public this()
	{
		mArena = new .();
	}

	/// @brief Copy text into the arena as plain bytes (no String object or destructor).
	/// @param text The text to copy.
	/// @return A view of the store-owned copy (an empty one has a non-null pointer).
	[Inline]
	public StringView NewText(StringView text)
	{
		return mArena.Copy(text);
	}

	/// @brief A copy of `value` whose text (strings, number lexemes) the store owns.
	/// @param value The value, whose views may point anywhere.
	/// @param keepIntegerText Whether an integer keeps its written form (PreserveStyle); otherwise it
	/// is dropped, and the value is written in decimal.
	/// @return The owned value.
	[Inline]
	public KdlValue OwnValue(KdlValue value, bool keepIntegerText)
	{
		switch (value)
		{
		case .String(let s):
			return .String(NewText(s));
		case .Integer(let v, let text):
			return .Integer(v, keepIntegerText ? NewText(text) : default);
		case .Float(let v, let text):
			// The canonical form keeps a float's written mantissa (`1.0`, `1E+10`)
			return .Float(v, NewText(text));
		case .BigInteger(let text):
			return .BigInteger(NewText(text));
		default:
			return value;
		}
	}

	/// @brief Release all text, keeping the arena's chunks for the next document.
	public void Reset()
	{
		mArena.Reset();
	}

	/// @brief The bytes the arena holds (in use or kept for reuse).
	public int ReservedBytes => mArena.ReservedBytes;
}

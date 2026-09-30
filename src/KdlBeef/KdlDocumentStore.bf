using System;
using System.Collections;
using internal KdlBeef;

namespace KdlBeef;

/// @brief Owns the text of a document (names, keys, annotations, strings, number lexemes) in a
/// BumpAllocator arena, released together when the store is reset or destroyed.
internal class KdlDocumentStore
{
	/// A BumpAllocator that takes its pools from, and returns them to, a cache the store keeps across
	/// resets. Reading into a document again then reuses the previous document's memory: freeing it
	/// instead lets glibc trim the heap, and the next parse page-faults every page back in (TomlBeef
	/// measured up to 40% of parse time on large inputs). The cache holds at most the pools of the
	/// largest document read.
	class PoolRecyclingAllocator : BumpAllocator
	{
		List<Span<uint8>> mCache;

		public this(List<Span<uint8>> cache) : base(.Allow)
		{
			mCache = cache;
		}

		protected override Span<uint8> AllocPool()
		{
			if (!mCache.IsEmpty)
				return mCache.PopBack();
			return base.AllocPool();
		}

		protected override void FreePool(Span<uint8> span)
		{
			mCache.Add(span);
		}
	}

	private List<Span<uint8>> mPoolCache = new .();
	private BumpAllocator mAlloc;

	public this()
	{
		mAlloc = new PoolRecyclingAllocator(mPoolCache);
	}

	public ~this()
	{
		// The allocator returns its pools to the cache as it goes
		delete mAlloc;
		for (let pool in mPoolCache)
			delete pool.Ptr;
		delete mPoolCache;
	}

	/// @brief Copy text into the arena as plain bytes (no String object or destructor).
	/// @param text The text to copy.
	/// @return A view of the store-owned copy.
	public StringView NewText(StringView text)
	{
		if (text.IsEmpty)
			return "";
		let bytes = (char8*)mAlloc.Alloc(text.Length, 1);
		Internal.MemCpy(bytes, text.Ptr, text.Length);
		return .(bytes, text.Length);
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

	/// @brief Release all text, keeping the arena's pools for the next document.
	public void Reset()
	{
		delete mAlloc;
		mAlloc = new PoolRecyclingAllocator(mPoolCache);
	}
}

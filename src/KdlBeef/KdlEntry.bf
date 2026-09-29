using System;
using System.Collections;
using internal KdlBeef;

namespace KdlBeef;

/// An argument or property of a node: a view that is valid until the node's entries change.
public struct KdlEntry
{
	KdlDocument mDocument;
	int32 mIndex;

	internal this(KdlDocument document, int32 index)
	{
		mDocument = document;
		mIndex = index;
	}

	ref KdlEntryRecord Record => ref mDocument.mEntries[mIndex];

	/// @brief Whether this is a property (`key=value`).
	public bool IsProperty => Record.mFlags.HasFlag(.IsProperty);
	/// @brief Whether this is an argument.
	public bool IsArgument => !IsProperty;
	/// @brief The property's key (empty for an argument).
	public StringView Key => Record.mKey;
	/// @brief Whether the value has a `(type)` annotation.
	public bool HasAnnotation => Record.mFlags.HasFlag(.HasAnnotation);
	/// @brief The annotation's text (empty when there is none; see HasAnnotation).
	public StringView Annotation => Record.mAnnotation;
	/// @brief The value.
	public KdlValue Value => Record.mValue;
}

/// A node's arguments and properties, in order.
public struct KdlEntryList : IEnumerable<KdlEntry>
{
	KdlDocument mDocument;
	uint32 mNode;

	internal this(KdlDocument document, uint32 node)
	{
		mDocument = document;
		mNode = node;
	}

	/// @brief The number of entries.
	public int Count => mDocument.mNodes[mNode].mEntryCount;

	/// @brief The entry at a position.
	public KdlEntry this[int index]
	{
		get
		{
			ref KdlNodeRecord node = ref mDocument.mNodes[mNode];
			Runtime.Assert((uint)index < (uint)node.mEntryCount);
			return .(mDocument, node.mEntryStart + (int32)index);
		}
	}

	public Enumerator GetEnumerator()
	{
		ref KdlNodeRecord node = ref mDocument.mNodes[mNode];
		return .(mDocument, node.mEntryStart, node.mEntryStart + node.mEntryCount);
	}

	public struct Enumerator : IEnumerator<KdlEntry>
	{
		KdlDocument mDocument;
		int32 mNext;
		int32 mEnd;

		internal this(KdlDocument document, int32 start, int32 end)
		{
			mDocument = document;
			mNext = start;
			mEnd = end;
		}

		public Result<KdlEntry> GetNext() mut
		{
			if (mNext >= mEnd)
				return .Err;
			return KdlEntry(mDocument, mNext++);
		}
	}
}

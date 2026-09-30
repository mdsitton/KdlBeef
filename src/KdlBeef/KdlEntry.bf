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

	/// @brief Where the entry came from, when the document was read with KdlMetadataMode.Positions.
	/// @param range Receives the range: from the key (or annotation) to the end of the value.
	/// @return Whether the entry has one.
	public bool TryGetSourceRange(out KdlSourceRange range)
	{
		return mDocument.TryGetRange(mDocument.mEntryRanges, mIndex, out range);
	}
}

/// A node's arguments and properties, in order: a live view, valid while the node is in the document
/// (using it after the document is read again or cleared, or the node removed, is a fatal error).
public struct KdlEntryList : IEnumerable<KdlEntry>
{
	KdlDocument mDocument;
	uint32 mNode;
	uint32 mGeneration;

	internal this(KdlDocument document, uint32 node)
	{
		mDocument = document;
		mNode = node;
		mGeneration = document.mGeneration;
	}

	/// @brief Whether the view can still be used: its document was not read again or cleared, and its
	/// node was not removed.
	public bool IsValid => mDocument != null && mGeneration == mDocument.mGeneration && mDocument.IsLive(mNode);

	/// The node's record, after checking the view is still valid
	ref KdlNodeRecord Node
	{
		get
		{
			mDocument.CheckView(mGeneration, mNode);
			return ref mDocument.mNodes[mNode];
		}
	}

	/// @brief The number of entries.
	public int Count => Node.mEntryCount;

	/// @brief The entry at a position.
	public KdlEntry this[int index]
	{
		get
		{
			ref KdlNodeRecord node = ref Node;
			Runtime.Assert((uint)index < (uint)node.mEntryCount);
			return .(mDocument, node.mEntryStart + (int32)index);
		}
	}

	public Enumerator GetEnumerator()
	{
		ref KdlNodeRecord node = ref Node;
		return .(mDocument, node.mEntryStart, node.mEntryStart + node.mEntryCount);
	}

	public struct Enumerator : IEnumerator<KdlEntry>
	{
		KdlDocument mDocument;
		int32 mNext;
		int32 mEnd;
		uint32 mGeneration;

		internal this(KdlDocument document, int32 start, int32 end)
		{
			mDocument = document;
			mNext = start;
			mEnd = end;
			mGeneration = document.mGeneration;
		}

		public Result<KdlEntry> GetNext() mut
		{
			if (mNext >= mEnd)
				return .Err;
			mDocument.CheckView(mGeneration, 0);
			return KdlEntry(mDocument, mNext++);
		}
	}
}

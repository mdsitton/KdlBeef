using System;
using System.Collections;
using internal KdlBeef;

namespace KdlBeef;

/// @brief A node's identity within its document: an index into the document's node table. Stable
/// while the node is in the document (it is not reused until the document is cleared); not stable
/// across reads.
public struct KdlNodeId : IHashable, IEquatable<KdlNodeId>
{
	internal uint32 mValue;

	internal this(uint32 value)
	{
		mValue = value;
	}

	/// @brief Whether this can name a node (a node ID is never 0).
	public bool IsValid => mValue != 0;
	/// @brief The ID that names no node.
	public static KdlNodeId Invalid => default;
	/// @brief The ID as a number, for use as an index into per-node side tables.
	public uint32 Value => mValue;

	public int GetHashCode() => (int)mValue;
	public bool Equals(KdlNodeId other) => mValue == other.mValue;
	public static bool operator ==(KdlNodeId lhs, KdlNodeId rhs) => lhs.mValue == rhs.mValue;
	public static bool operator !=(KdlNodeId lhs, KdlNodeId rhs) => lhs.mValue != rhs.mValue;

	public override void ToString(String output)
	{
		mValue.ToString(output);
	}
}

/// A node of a KdlDocument: a handle (the document and the node's ID) whose properties read and write
/// the document. Handles are small values; copy them freely.
///
/// A handle is valid while its node is in the document. Reading from an invalid handle is a fatal
/// error, except for the navigation properties (`Parent`, `FirstChild`, …), which return invalid
/// handles where there is no such node; check `IsValid`.
public struct KdlNode : IEquatable<KdlNode>
{
	KdlDocument mDocument;
	uint32 mId;
	uint32 mGeneration;

	internal this(KdlDocument document, uint32 id)
	{
		mDocument = document;
		mId = id;
		mGeneration = document.mGeneration;
	}

	/// @brief Whether the handle refers to a node that is still in its document.
	public bool IsValid => mDocument != null && mGeneration == mDocument.mGeneration && (mId == 0 || mDocument.IsLive(mId));
	/// @brief Whether this is the document itself (KdlDocument.Root): no name or entries; its children
	/// are the top-level nodes.
	public bool IsDocumentRoot => mId == 0 && mDocument != null;

	/// A handle to node `id`, or the invalid (default) handle for 0, which names no node here.
	internal static KdlNode Of(KdlDocument document, uint32 id)
	{
		return id != 0 ? KdlNode(document, id) : default;
	}
	/// @brief The node's ID in its document.
	public KdlNodeId Id => .(mId);
	/// @brief The document the node belongs to.
	public KdlDocument Document => mDocument;

	ref KdlNodeRecord Record
	{
		get
		{
			if (!IsValid)
				Runtime.FatalError("KdlNode: the handle is invalid (no node, a removed node, or a cleared document)");
			return ref mDocument.mNodes[mId];
		}
	}

	KdlNode Link(uint32 id) => Of(mDocument, id);

	/// @brief The node's name.
	public StringView Name
	{
		get => Record.mName;
		set
		{
			if (mId == 0)
				Runtime.FatalError("KdlNode: the document root has no name");
			Record.mName = mDocument.mStore.NewText(value);
			mDocument.MarkNode(mId, .NameDirty);
		}
	}

	/// @brief Whether the node has a `(type)` annotation.
	public bool HasAnnotation => Record.mFlags.HasFlag(.HasAnnotation);
	/// @brief The annotation's text (empty when there is none; see HasAnnotation).
	public StringView Annotation => Record.mAnnotation;

	/// @brief Set the node's type annotation.
	/// @param annotation The annotation text.
	public void SetAnnotation(StringView annotation)
	{
		if (mId == 0)
			Runtime.FatalError("KdlNode: the document root has no annotation");
		ref KdlNodeRecord node = ref Record;
		node.mAnnotation = mDocument.mStore.NewText(annotation);
		node.mFlags |= .HasAnnotation;
		mDocument.MarkNode(mId, .HeadPrefixDirty);
	}

	/// @brief Remove the node's type annotation, if it has one.
	public void RemoveAnnotation()
	{
		ref KdlNodeRecord node = ref Record;
		node.mAnnotation = default;
		node.mFlags &= ~.HasAnnotation;
		mDocument.MarkNode(mId, .HeadPrefixDirty);
	}

	// Navigation

	/// @brief The parent node; invalid for a top-level node.
	public KdlNode Parent => Link(Record.mParent);
	/// @brief The first child node; invalid when there are no children.
	public KdlNode FirstChild => Link(Record.mFirstChild);
	/// @brief The last child node; invalid when there are no children.
	public KdlNode LastChild => Link(Record.mLastChild);
	/// @brief The next node with the same parent; invalid for the last one.
	public KdlNode NextSibling => Link(Record.mNextSibling);
	/// @brief The previous node with the same parent; invalid for the first one.
	public KdlNode PreviousSibling => Link(Record.mPrevSibling);
	/// @brief The child nodes, in order.
	public KdlNodeList Children
	{
		get
		{
			Runtime.Assert(IsValid, "KdlNode: the handle is invalid");
			return .(mDocument, mId);
		}
	}
	/// @brief Whether the node has children.
	public bool HasChildren => Record.mFirstChild != 0;
	/// @brief The number of child nodes.
	public int ChildCount => Record.mChildCount;

	/// @brief Where the node came from, when the document was read with KdlMetadataMode.Positions.
	/// @param range Receives the range: from the node's annotation (or `/-`) to its last token.
	/// @return Whether the node has one (not without Positions, nor for nodes added in code).
	public bool TryGetSourceRange(out KdlSourceRange range)
	{
		Runtime.Assert(IsValid, "KdlNode: the handle is invalid");
		return mDocument.TryGetRange(mDocument.mNodeRanges, mId, out range);
	}

	/// @brief The node's depth: 0 for a top-level node. Walks up the tree.
	public int Depth
	{
		get
		{
			int depth = 0;
			uint32 id = Record.mParent;
			while (id != 0)
			{
				depth++;
				id = mDocument.mNodes[id].mParent;
			}
			return depth;
		}
	}

	// Entries

	/// @brief The node's arguments and properties, in order.
	public KdlEntryList Entries
	{
		get
		{
			Runtime.Assert(IsValid, "KdlNode: the handle is invalid");
			return .(mDocument, mId);
		}
	}

	/// @brief The number of arguments.
	public int ArgumentCount
	{
		get
		{
			ref KdlNodeRecord node = ref Record;
			int count = 0;
			for (int i = node.mEntryStart; i < node.mEntryStart + node.mEntryCount; i++)
			{
				if (!mDocument.mEntries[i].mFlags.HasFlag(.IsProperty))
					count++;
			}
			return count;
		}
	}

	/// @brief Get an argument by position (properties do not count).
	/// @param index The argument's position among the arguments.
	/// @param value Receives its value.
	/// @return Whether there is such an argument.
	public bool TryGetArgument(int index, out KdlValue value)
	{
		ref KdlNodeRecord node = ref Record;
		int remaining = index;
		for (int i = node.mEntryStart; i < node.mEntryStart + node.mEntryCount; i++)
		{
			ref KdlEntryRecord entry = ref mDocument.mEntries[i];
			if (entry.mFlags.HasFlag(.IsProperty))
				continue;
			if (remaining-- == 0)
			{
				value = entry.mValue;
				return true;
			}
		}
		value = .Null;
		return false;
	}

	/// @brief Get a property's value. With duplicate keys, the last one wins.
	/// @param key The key.
	/// @param value Receives the value.
	/// @return Whether the node has the property.
	public bool TryGetProperty(StringView key, out KdlValue value)
	{
		int index = FindProperty(key);
		if (index < 0)
		{
			value = .Null;
			return false;
		}
		value = mDocument.mEntries[index].mValue;
		return true;
	}

	/// @brief Whether the node has a property with this key.
	/// @param key The key.
	/// @return Whether it does.
	public bool HasProperty(StringView key) => FindProperty(key) >= 0;

	/// The entry index of the last property with `key`, or -1.
	int FindProperty(StringView key)
	{
		ref KdlNodeRecord node = ref Record;
		for (int i = node.mEntryStart + node.mEntryCount - 1; i >= node.mEntryStart; i--)
		{
			ref KdlEntryRecord entry = ref mDocument.mEntries[i];
			if (entry.mFlags.HasFlag(.IsProperty) && entry.mKey == key)
				return i;
		}
		return -1;
	}

	public bool Equals(KdlNode other) => mDocument == other.mDocument && mId == other.mId && mGeneration == other.mGeneration;
	public static bool operator ==(KdlNode lhs, KdlNode rhs) => lhs.Equals(rhs);
	public static bool operator !=(KdlNode lhs, KdlNode rhs) => !lhs.Equals(rhs);
}

/// The children of a node (or the document's top-level nodes), in order: a live view of them, valid
/// while the node is in the document (like a KdlNode handle: using it after the document is read again
/// or cleared, or the node removed, is a fatal error).
public struct KdlNodeList : IEnumerable<KdlNode>
{
	KdlDocument mDocument;
	uint32 mParent;
	uint32 mGeneration;

	internal this(KdlDocument document, uint32 parent)
	{
		mDocument = document;
		mParent = parent;
		mGeneration = document.mGeneration;
	}

	/// @brief Whether the view can still be used: its document was not read again or cleared, and its
	/// node was not removed.
	public bool IsValid => mDocument != null && mGeneration == mDocument.mGeneration && (mParent == 0 || mDocument.IsLive(mParent));

	/// The parent's record, after checking the view is still valid
	ref KdlNodeRecord Parent
	{
		get
		{
			mDocument.CheckView(mGeneration, mParent);
			return ref mDocument.mNodes[mParent];
		}
	}

	/// @brief The number of nodes.
	public int Count => Parent.mChildCount;
	/// @brief Whether there are none.
	public bool IsEmpty => Parent.mFirstChild == 0;
	/// @brief The first node; invalid when there are none.
	public KdlNode First => KdlNode.Of(mDocument, Parent.mFirstChild);
	/// @brief The last node; invalid when there are none.
	public KdlNode Last => KdlNode.Of(mDocument, Parent.mLastChild);

	/// @brief The first node with the given name.
	/// @param name The name.
	/// @return The node, or an invalid handle.
	public KdlNode Find(StringView name)
	{
		uint32 id = Parent.mFirstChild;
		while (id != 0)
		{
			if (mDocument.mNodes[id].mName == name)
				break;
			id = mDocument.mNodes[id].mNextSibling;
		}
		return KdlNode.Of(mDocument, id);
	}

	public Enumerator GetEnumerator() => .(mDocument, Parent.mFirstChild);

	/// Walks the sibling links. It reads the next node before returning the current one, so the
	/// current node may be removed during the loop (not the document read again or cleared).
	public struct Enumerator : IEnumerator<KdlNode>
	{
		KdlDocument mDocument;
		uint32 mNext;
		uint32 mGeneration;

		internal this(KdlDocument document, uint32 first)
		{
			mDocument = document;
			mNext = first;
			mGeneration = document.mGeneration;
		}

		public Result<KdlNode> GetNext() mut
		{
			if (mNext == 0)
				return .Err;
			mDocument.CheckView(mGeneration, 0);
			let node = KdlNode(mDocument, mNext);
			mNext = mDocument.mNodes[mNext].mNextSibling;
			return node;
		}
	}
}

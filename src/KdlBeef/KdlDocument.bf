using System;
using System.Collections;
using System.IO;
using internal KdlBeef;

namespace KdlBeef;

[AllowDuplicates]
internal enum KdlNodeFlags : uint8
{
	None = 0,
	HasAnnotation = 1,
	/// Removed from the document; its slot is not reused until the document is cleared.
	Removed = 2
}

[AllowDuplicates]
internal enum KdlEntryFlags : uint8
{
	None = 0,
	/// A property (the key is set); otherwise an argument.
	IsProperty = 1,
	HasAnnotation = 2
}

/// A node's slot in the document's node table. Links are node IDs; 0 means none, except that a
/// parent of 0 is the hidden root, which holds the top-level nodes as its children.
internal struct KdlNodeRecord
{
	public StringView mName;
	public StringView mAnnotation;
	/// The node's entries are mEntries[mEntryStart ..< mEntryStart + mEntryCount].
	public int32 mEntryStart;
	public int32 mEntryCount;
	/// Room reserved at mEntryStart; adding an entry past it moves the range to the end.
	public int32 mEntryCapacity;
	public int32 mChildCount;
	public uint32 mParent;
	public uint32 mFirstChild;
	public uint32 mLastChild;
	public uint32 mNextSibling;
	public uint32 mPrevSibling;
	public KdlNodeFlags mFlags;
}

internal struct KdlEntryRecord
{
	public StringView mKey;
	public StringView mAnnotation;
	public KdlValue mValue;
	public KdlEntryFlags mFlags;
}

/// A KDL document: the top-level nodes and everything under them.
///
/// The document owns all of its text and nodes. Nodes are handed out as `KdlNode` handles (the
/// document plus a node ID), which read and write the document directly; a handle stays valid until
/// its node is removed or the document is cleared or read again, and `IsValid` tells. Strings
/// returned by the document view its storage and share that lifetime.
///
/// ```
/// let doc = scope KdlDocument();
/// Try!(doc.Read(text));
/// for (let node in doc.Nodes)
///     if (node.Name == "button" && node.TryGetProperty("on-click", let handler)) ...
/// ```
public class KdlDocument
{
	internal KdlDocumentStore mStore ~ delete _;
	internal List<KdlNodeRecord> mNodes ~ delete _;
	internal List<KdlEntryRecord> mEntries ~ delete _;
	/// Changes on every Clear and Read, so handles from before can tell they are stale.
	internal uint32 mGeneration;
	/// The reader behind Read, kept for its buffers.
	KdlReader mReader ~ delete _;
	/// Scratch for Read (open nodes) and Write (a node's property order).
	List<uint32> mNodeStack ~ delete _;
	List<int32> mPropertyOrder ~ delete _;

	/// @brief Create an empty document.
	public this()
	{
		mStore = new .();
		mNodes = new .();
		mEntries = new .();
		mNodeStack = new .();
		mPropertyOrder = new .();
		mNodes.Add(default);
		mGeneration = 1;
	}

	/// @brief The top-level nodes, in order.
	public KdlNodeList Nodes => .(this, 0);

	/// @brief Remove every node.
	public void Clear()
	{
		mStore.Reset();
		mNodes.Clear();
		mEntries.Clear();
		mNodes.Add(default);
		mGeneration++;
	}

	/// @brief The node with the given ID, if it is in this document.
	/// @param id A node ID, from `KdlNode.Id`.
	/// @return The node, or an invalid handle if the ID is unknown or its node was removed.
	public KdlNode GetNode(KdlNodeId id)
	{
		return .(this, IsLive(id.mValue) ? id.mValue : 0);
	}

	// Reading

	/// @brief Replace the document's content with the KDL document in `text`.
	/// @param text The document (UTF-8; a leading BOM is skipped).
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, KdlParseError> Read(StringView text)
	{
		Clear();
		if (mReader == null)
			mReader = new KdlReader();
		mReader.Reset(text);
		let result = Build(mReader);
		// Nothing may keep viewing the caller's text
		mReader.Reset(default);
		if (result case .Err)
			Clear();
		return result;
	}

	/// @brief Replace the document's content with the KDL document in `bytes`.
	/// @param bytes The document (UTF-8; a leading BOM is skipped).
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, KdlParseError> ReadBytes(Span<uint8> bytes)
	{
		return Read(StringView((char8*)bytes.Ptr, bytes.Length));
	}

	/// @brief Replace the document's content with the KDL document in a file.
	/// @param path The file's path; errors name it as their source.
	/// @return .Ok, or the first error (IoError if the file cannot be read); the document is then empty.
	public Result<void, KdlParseError> ReadFile(StringView path)
	{
		let bytes = scope List<uint8>();
		if (File.ReadAll(path, bytes) case .Err)
		{
			Clear();
			var error = KdlParseError(.IoError, "Cannot read the file", 0, 0, 0, 0);
			error.SetSource(path);
			return .Err(error);
		}
		if (ReadBytes(bytes) case .Err(var error))
		{
			error.SetSource(path);
			return .Err(error);
		}
		return .Ok;
	}

	Result<void, KdlParseError> Build(KdlReader reader)
	{
		mNodeStack.Clear();
		uint32 current = 0;
		while (true)
		{
			let event = Try!(reader.Next());
			switch (event)
			{
			case .StartNode:
				uint32 id = NewNode(reader.Name, reader.HasAnnotation, reader.Annotation);
				LinkLastChild(current, id);
				mNodeStack.Add(current);
				current = id;
			case .Argument, .Property:
				// A node's entries all come before its children, so they are appended contiguously
				ref KdlNodeRecord node = ref mNodes[current];
				if (node.mEntryCount == 0)
					node.mEntryStart = (int32)mEntries.Count;
				node.mEntryCount++;
				node.mEntryCapacity = node.mEntryCount;
				// Built in place: an entry record is 72 bytes
				KdlEntryRecord* entry = mEntries.GrowUninitialized(1);
				entry.mFlags = .None;
				if (event == .Property)
				{
					entry.mKey = mStore.NewText(reader.Name);
					entry.mFlags = .IsProperty;
				}
				else
					entry.mKey = default;
				if (reader.HasAnnotation)
				{
					entry.mAnnotation = mStore.NewText(reader.Annotation);
					entry.mFlags |= .HasAnnotation;
				}
				else
					entry.mAnnotation = default;
				entry.mValue = mStore.OwnValue(reader.Value, false);
			case .EndNode:
				current = mNodeStack.PopBack();
			case .EndOfDocument:
				return .Ok;
			}
		}
	}

	// Node table

	internal bool IsLive(uint32 id)
	{
		return id != 0 && id < (uint32)mNodes.Count && !mNodes[id].mFlags.HasFlag(.Removed);
	}

	/// Adds an unlinked node with its own copy of the name and annotation.
	internal uint32 NewNode(StringView name, bool hasAnnotation, StringView annotation)
	{
		KdlNodeRecord node = default;
		node.mName = mStore.NewText(name);
		if (hasAnnotation)
		{
			node.mAnnotation = mStore.NewText(annotation);
			node.mFlags = .HasAnnotation;
		}
		node.mEntryStart = (int32)mEntries.Count;
		uint32 id = (uint32)mNodes.Count;
		mNodes.Add(node);
		return id;
	}

	/// Links an unlinked node as the last child of `parent` (0: a top-level node).
	internal void LinkLastChild(uint32 parent, uint32 child)
	{
		ref KdlNodeRecord p = ref mNodes[parent];
		ref KdlNodeRecord c = ref mNodes[child];
		c.mParent = parent;
		c.mNextSibling = 0;
		c.mPrevSibling = p.mLastChild;
		if (p.mLastChild != 0)
			mNodes[p.mLastChild].mNextSibling = child;
		else
			p.mFirstChild = child;
		p.mLastChild = child;
		p.mChildCount++;
	}

	// Writing

	/// @brief Append the document in the canonical form (see `KdlCanonical`).
	/// @param output The string to append to.
	public void Write(String output)
	{
		int startLength = output.Length;
		uint32 id = mNodes[0].mFirstChild;
		int depth = 0;
		while (id != 0)
		{
			ref KdlNodeRecord node = ref mNodes[id];
			output.Append(' ', depth * 4);
			WriteHead(node, output);
			if (node.mFirstChild != 0)
			{
				output.Append(" {\n");
				id = node.mFirstChild;
				depth++;
				continue;
			}
			output.Append('\n');
			// Next: the sibling, or the sibling of the nearest ancestor that has one, closing blocks
			while (true)
			{
				if (mNodes[id].mNextSibling != 0)
				{
					id = mNodes[id].mNextSibling;
					break;
				}
				id = mNodes[id].mParent;
				if (id == 0)
					break;
				depth--;
				output.Append(' ', depth * 4);
				output.Append("}\n");
			}
		}
		if (output.Length == startLength)
			output.Append('\n');
	}

	/// Writes a node's annotation, name, arguments and properties (deduplicated, sorted by key).
	void WriteHead(KdlNodeRecord node, String output)
	{
		if (node.mFlags.HasFlag(.HasAnnotation))
			KdlCanonical.AppendAnnotation(output, node.mAnnotation);
		KdlCanonical.AppendString(output, node.mName);
		mPropertyOrder.Clear();
		for (int32 i = node.mEntryStart; i < node.mEntryStart + node.mEntryCount; i++)
		{
			ref KdlEntryRecord entry = ref mEntries[i];
			if (entry.mFlags.HasFlag(.IsProperty))
			{
				mPropertyOrder.Add(i);
				continue;
			}
			output.Append(' ');
			WriteEntryValue(entry, output);
		}
		if (mPropertyOrder.IsEmpty)
			return;
		// By key, the last occurrence first; then the first of each run of equal keys is the one kept
		mPropertyOrder.Sort(scope (a, b) =>
			{
				int cmp = StringView.Compare(mEntries[a].mKey, mEntries[b].mKey);
				return cmp != 0 ? cmp : b <=> a;
			});
		StringView previousKey = default;
		for (int k < mPropertyOrder.Count)
		{
			ref KdlEntryRecord entry = ref mEntries[mPropertyOrder[k]];
			if (k > 0 && entry.mKey == previousKey)
				continue;
			previousKey = entry.mKey;
			output.Append(' ');
			KdlCanonical.AppendString(output, entry.mKey);
			output.Append('=');
			WriteEntryValue(entry, output);
		}
	}

	static void WriteEntryValue(KdlEntryRecord entry, String output)
	{
		if (entry.mFlags.HasFlag(.HasAnnotation))
			KdlCanonical.AppendAnnotation(output, entry.mAnnotation);
		KdlCanonical.AppendValue(output, entry.mValue);
	}
}

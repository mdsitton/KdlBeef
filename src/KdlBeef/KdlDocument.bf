using System;
using System.Collections;
using System.IO;
using FormatCore;
using internal FormatCore;
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
/// parent of 0 is the hidden root, which holds the top-level nodes as its children. FormatCore's
/// `Tree` links and walks the table through the `ITreeRecord` accessors (inlined to the fields).
internal struct KdlNodeRecord : ITreeRecord
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

	public uint32 Parent { [Inline] get => mParent; [Inline] set mut => mParent = value; }
	public uint32 FirstChild { [Inline] get => mFirstChild; [Inline] set mut => mFirstChild = value; }
	public uint32 LastChild { [Inline] get => mLastChild; [Inline] set mut => mLastChild = value; }
	public uint32 Next { [Inline] get => mNextSibling; [Inline] set mut => mNextSibling = value; }
	public uint32 Prev { [Inline] get => mPrevSibling; [Inline] set mut => mPrevSibling = value; }
	public int32 ChildCount { [Inline] get => mChildCount; [Inline] set mut => mChildCount = value; }

	[Inline]
	public void SetLastChildAndCount(uint32 last, int32 count) mut
	{
		mLastChild = last;
		mChildCount = count;
	}

	public bool IsRemoved
	{
		[Inline]
		get => mFlags.HasFlag(.Removed);
	}

	[Inline]
	public void MarkRemoved() mut
	{
		mFlags |= .Removed;
	}
}

/// The node table's link operations: FormatCore's, with slot 0 the hidden root (a container, never a
/// node anyone descends from).
typealias KdlTree = Tree<KdlNodeRecord, const false>;

/// An argument or property. (A packed 48-byte form, with the value rebuilt from a tag on every read,
/// was measured slower on every input: numbers read 142 → 129 MB/s, written 321 → 187.)
internal struct KdlEntryRecord
{
	public StringView mKey;
	public StringView mAnnotation;
	public KdlValue mValue;
	public KdlEntryFlags mFlags;
}

/// A source range without the source name (the document holds it). Line 0: no position.
internal struct KdlRangeRecord
{
	public int32 mLine;
	public int32 mColumn;
	public int32 mOffset;
	public int32 mLength;
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
	/// @brief This document's read configuration, used by the Read/ReadBytes/ReadFile overloads that take
	/// no config: `doc.ReadConfig.MetadataMode = .Positions;`.
	public KdlReadConfig ReadConfig = .();

	internal KdlDocumentStore mStore ~ delete _;
	internal GrowList<KdlNodeRecord> mNodes ~ delete _;
	internal GrowList<KdlEntryRecord> mEntries ~ delete _;
	/// Positions mode: the source range of each node (by ID) and entry (by index); empty otherwise.
	internal List<KdlRangeRecord> mNodeRanges ~ delete _;
	internal List<KdlRangeRecord> mEntryRanges ~ delete _;
	/// The source name of the last read (for errors and ranges).
	internal String mSourceName ~ delete _;
	/// The errors of the last read with CollectErrors (messages in the store).
	List<KdlParseError> mErrors ~ delete _;
	/// PreserveStyle: the source text of each node (by ID) and entry (by index), the text after the
	/// last node, whether there was a BOM, and the indentation unit (empty: 4 spaces).
	internal bool mPreserve;
	internal List<KdlNodeStyle> mNodeStyles ~ delete _;
	internal List<KdlEntryStyle> mEntryStyles ~ delete _;
	StringView mTrailing;
	bool mHasBom;
	String mIndentUnit ~ delete _;
	/// Where the current preserving write started in its output.
	int mWriteStart;
	/// Preserving write: the node just written ended without a terminator (it was last before a `}` or
	/// the end in the source), so a node written next needs one first.
	bool mNeedTerminator;
	/// Preserving write: the node just written ended inside a `//` comment the end of the input closed,
	/// so even a `}` written next needs a newline first.
	bool mInComment;
	/// Changes on every Clear and Read, so handles from before can tell they are stale.
	internal uint32 mGeneration;
	/// The reader behind Read, kept for its buffers.
	KdlReader mReader ~ delete _;
	/// Scratch for Read (open nodes) and Write (a node's property order).
	GrowList<uint32> mNodeStack ~ delete _;
	List<int32> mPropertyOrder ~ delete _;

	/// @brief Create an empty document.
	public this()
	{
		mStore = new .();
		mNodes = new .();
		mEntries = new .();
		mNodeStack = new .();
		mPropertyOrder = new .();
		mNodeRanges = new .();
		mEntryRanges = new .();
		mSourceName = new .();
		mErrors = new .();
		mNodeStyles = new .();
		mEntryStyles = new .();
		mIndentUnit = new .();
		mNodes.Add(default);
		mGeneration = 1;
	}

	/// @brief The top-level nodes, in order.
	public KdlNodeList Nodes => .(this, 0);

	/// @brief The name of the source last read (KdlReadConfig.SourceName, or ReadFile's path); empty
	/// if unnamed.
	public StringView SourceName => mSourceName;

	/// @brief Remove every node.
	public void Clear()
	{
		mStore.Reset();
		mNodes.Clear();
		mEntries.Clear();
		mNodeRanges.Clear();
		mEntryRanges.Clear();
		mSourceName.Clear();
		mErrors.Clear();
		mPreserve = false;
		mNodeStyles.Clear();
		mEntryStyles.Clear();
		mTrailing = default;
		mHasBom = false;
		mIndentUnit.Clear();
		mNodes.Add(default);
		mGeneration++;
	}

	/// @brief The node with the given ID, if it is in this document.
	/// @param id A node ID, from `KdlNode.Id`.
	/// @return The node, or an invalid handle if the ID is unknown or its node was removed.
	public KdlNode GetNode(KdlNodeId id)
	{
		return IsLive(id.mValue) ? KdlNode(this, id.mValue) : default;
	}

	/// @brief The document itself as a node: no name or entries, the top-level nodes as its children
	/// (`AddChild` adds one). [KdlObject] types read and write whole documents through it.
	public KdlNode Root
	{
		get
		{
			return KdlNode(this, 0);
		}
	}

	// Reading

	/// @brief Replace the document's content with the KDL document in `text`, using ReadConfig.
	/// @param text The document (UTF-8; a leading BOM is skipped).
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, KdlParseError> Read(StringView text)
	{
		return Read(text, ReadConfig);
	}

	/// @brief Replace the document's content with the KDL document in `text`.
	/// @param text The document (UTF-8; a leading BOM is skipped).
	/// @param config Metadata, source name and limits.
	/// @return .Ok, or the first error. The document is then empty; with config.CollectErrors it keeps
	/// what could be read, and `Errors` lists every error. Those errors' text belongs to the document
	/// (valid until it is cleared, read again or deleted); KdlParseError.Detach copies it out.
	public Result<void, KdlParseError> Read(StringView text, KdlReadConfig config)
	{
		let readerConfig = BeginRead(config);
		mReader.Reset(text, readerConfig);
		return EndRead(Build(mReader, config), config);
	}

	/// @brief Replace the document's content with the KDL document read from a stream, using
	/// ReadConfig.
	/// @param stream The document (UTF-8; a leading BOM is skipped), read from its current position.
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, KdlParseError> Read(Stream stream)
	{
		return Read(stream, ReadConfig);
	}

	/// @brief Replace the document's content with the KDL document read from a stream, through a buffer
	/// of `config.StreamBufferBytes`: memory for the input stays bounded by the buffer and the longest
	/// construct (see `config.MaxTokenBytes`); the document itself grows with the content.
	/// @param stream The document (UTF-8; a leading BOM is skipped), read from its current position.
	/// @param config Metadata, source name, limits and buffer size.
	/// @return .Ok, or the first error (IoError if reading fails). The document is then empty; with
	/// config.CollectErrors it keeps what could be read, and `Errors` lists every error.
	public Result<void, KdlParseError> Read(Stream stream, KdlReadConfig config)
	{
		let readerConfig = BeginRead(config);
		mReader.Reset(stream, readerConfig);
		return EndRead(Build(mReader, config), config);
	}

	/// @brief The errors of the last read with KdlReadConfig.CollectErrors, in order (empty
	/// otherwise). Their messages belong to the document: valid until it is cleared or read again.
	public Span<KdlParseError> Errors => mErrors;

	/// Clears the document for a read and returns the reader's config, naming the document's copy of
	/// the source name.
	KdlReadConfig BeginRead(KdlReadConfig config)
	{
		Clear();
		mSourceName.Set(config.SourceName);
		var readerConfig = config;
		readerConfig.SourceName = mSourceName;
		if (mReader == null)
			mReader = new KdlReader();
		return readerConfig;
	}

	Result<void, KdlParseError> EndRead(Result<void, KdlParseError> result, KdlReadConfig config)
	{
		// Nothing may keep viewing the caller's text or stream
		mReader.Reset(StringView());
		if (result case .Err && !config.CollectErrors)
		{
			let sourceName = scope String(mSourceName);
			Clear();
			mSourceName.Set(sourceName);
		}
		return result;
	}

	/// @brief Replace the document's content with the KDL document in `bytes`, using ReadConfig.
	/// @param bytes The document (UTF-8; a leading BOM is skipped).
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, KdlParseError> ReadBytes(Span<uint8> bytes)
	{
		return Read(StringView((char8*)bytes.Ptr, bytes.Length), ReadConfig);
	}

	/// @brief Replace the document's content with the KDL document in `bytes`.
	/// @param bytes The document (UTF-8; a leading BOM is skipped).
	/// @param config Metadata, source name and limits.
	/// @return .Ok, or the first error; the document is then empty.
	public Result<void, KdlParseError> ReadBytes(Span<uint8> bytes, KdlReadConfig config)
	{
		return Read(StringView((char8*)bytes.Ptr, bytes.Length), config);
	}

	/// @brief Replace the document's content with the KDL document in a file, using ReadConfig.
	/// @param path The file's path; errors and source ranges name it unless ReadConfig.SourceName is set.
	/// @return .Ok, or the first error (IoError if the file cannot be read); the document is then empty.
	public Result<void, KdlParseError> ReadFile(StringView path)
	{
		return ReadFile(path, ReadConfig);
	}

	/// @brief Replace the document's content with the KDL document in a file: loaded whole, or with
	/// `config.StreamBufferBytes` set, streamed through a buffer of that size.
	/// @param path The file's path; errors and source ranges name it unless config.SourceName is set.
	/// @param config Metadata, source name, limits and buffer size.
	/// @return .Ok, or the first error (IoError if the file cannot be read); the document is then empty.
	public Result<void, KdlParseError> ReadFile(StringView path, KdlReadConfig config)
	{
		var config;
		if (config.SourceName.IsEmpty)
			config.SourceName = path;
		if (config.StreamBufferBytes > 0)
		{
			let file = scope FileStream();
			if (file.Open(path, .Read, .Read) case .Err)
			{
				Clear();
				var error = KdlParseError(.IoError, "Cannot open the file", 0, 0, 0, 0);
				error.SetSource(config.SourceName);
				return .Err(error);
			}
			return Read(file, config);
		}
		// The whole file within MaxInputBytes (FormatCore's read shell: a larger file fails from its size)
		let bytes = scope List<uint8>();
		if (ReadShell.ReadFileBytes(path, config.MaxInputBytes, bytes) case .Err(let inputError))
		{
			Clear();
			var error = KdlText.ErrorOf(inputError);
			error.SetSource(config.SourceName);
			return .Err(error);
		}
		return ReadBytes(bytes, config);
	}

	/// Turns the reader's events into records. In Positions mode, also records each node's and entry's
	/// source range; with CollectErrors, records the errors and goes on.
	Result<void, KdlParseError> Build(KdlReader reader, KdlReadConfig config)
	{
		bool preserve = config.MetadataMode == .PreserveStyle;
		bool positions = config.MetadataMode == .Positions || preserve;
		mPreserve = preserve;
		mNodeStack.Clear();
		if (positions)
			mNodeRanges.Add(default);
		uint32 current = 0;
		while (true)
		{
			KdlEvent event;
			switch (reader.Next())
			{
			case .Ok(let next):
				event = next;
			case .Err(let error):
				if (!config.CollectErrors)
					return .Err(error);
				// Kept with the document: the message buffer is shared with the next error
				var kept = error;
				kept.mMessage = mStore.NewText(error.mMessage);
				kept.mSource = mSourceName;
				mErrors.Add(kept);
				if (reader.IsStopped)
					return .Err(mErrors[0]);
				continue;
			}
			switch (event)
			{
			case .StartNode:
				uint32 id = NewNode(reader.Name, reader.HasAnnotation, reader.Annotation);
				LinkLastChild(current, id);
				if (preserve)
					CaptureStartNode(reader, current, id, mNodeStack.Count);
				mNodeStack.Add(current);
				current = id;
				if (positions)
					mNodeRanges.Add(RangeAt(reader, reader.Offset, 0));
			case .Argument, .Property:
				if (positions)
					mEntryRanges.Add(RangeAt(reader, reader.Offset, reader.EndOffset - reader.Offset));
				if (preserve)
					CaptureEntry(reader, mEntries.Count);
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
				if (positions)
					mNodeRanges[current].mLength = (int32)(reader.EndOffset - reader.Offset);
				if (preserve)
					CaptureEndNode(reader, current);
				current = mNodeStack.PopBack();
			case .EndOfDocument:
				if (preserve)
					CaptureEnd(reader);
				if (!mErrors.IsEmpty)
					return .Err(mErrors[0]);
				return .Ok;
			}
		}
	}

	// Node table

	/// A range record at `offset`, its line and column from the reader (events come in source order,
	/// so its line count only moves forward).
	static KdlRangeRecord RangeAt(KdlReader reader, int offset, int length)
	{
		reader.Locate(offset, let line, let column);
		return .() { mLine = (int32)line, mColumn = (int32)column, mOffset = (int32)offset, mLength = (int32)length };
	}

	/// The recorded source range, if the document was read with positions and `range` has one.
	internal bool TryGetRange(List<KdlRangeRecord> ranges, int index, out KdlSourceRange range)
	{
		if (index < ranges.Count && ranges[index].mLine > 0)
		{
			let r = ranges[index];
			range = .(r.mLine, r.mColumn, r.mOffset, r.mLength, mSourceName);
			return true;
		}
		range = default;
		return false;
	}

	internal bool IsLive(uint32 id)
	{
		return id != 0 && id < (uint32)mNodes.Count && !mNodes[id].mFlags.HasFlag(.Removed);
	}

	/// A saved view (a node's Children or Entries, Nodes, Named, Descendants) made at `generation` for
	/// node `id` (0: the document): a fatal error if the document was read again or cleared since, or
	/// the node removed, as for a KdlNode handle (it would show other content, or none).
	[Inline]
	internal void CheckView(uint32 generation, uint32 id)
	{
		if (generation != mGeneration || (id != 0 && !IsLive(id)))
			Runtime.FatalError("KdlBeef: a saved node list, entry list or enumerator is stale: its document was read again or cleared, or its node removed");
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
	[Inline]
	internal void LinkLastChild(uint32 parent, uint32 child)
	{
		KdlTree.LinkLast(mNodes.Ptr, parent, child);
	}

	// Writing

	/// @brief Append the document as text: as it was read (comments, formatting and all) when it was
	/// read with KdlMetadataMode.PreserveStyle, with what was changed or added regenerated; otherwise in
	/// the canonical form (see `KdlCanonical`).
	/// @param output The string to append to.
	public void Write(String output)
	{
		if (mPreserve)
			WritePreserving(output);
		else
			WriteCanonical(output);
	}

	/// @brief Append the document in the canonical form (see `KdlCanonical`), however it was read.
	/// @param output The string to append to.
	public void WriteCanonical(String output)
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

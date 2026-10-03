using System;
using System.Collections;
using FormatCore;
using internal FormatCore;
using internal KdlBeef;

namespace KdlBeef;

[AllowDuplicates]
internal enum KdlStyleFlags : uint16
{
	None = 0,
	/// The pieces were read from the source (a node or entry added in code has none).
	Captured = 1,
	/// The node had a children block in the source (`mBeforeChildren` and `mBlockEnd` are set).
	HasBlock = 2,
	/// Regenerate: the text before the node (it moved), its name, its annotation.
	LeadingDirty = 4,
	NameDirty = 8,
	HeadPrefixDirty = 16,
	/// Regenerate an entry's value, or its key, `=` and annotation.
	ValueDirty = 32,
	PrefixDirty = 64,
	/// The node's tail ends with its terminator (the reader saw a newline, `;` or `//` comment and its
	/// newline); otherwise it was last before a `}` or the end.
	Terminated = 128,
	/// The node's tail ends inside a `//` comment the end of the input closed.
	EndsInComment = 256
}

/// PreserveStyle: a node's source text, in the order it is written back.
internal struct KdlNodeStyle
{
	/// Before the node: the newline and indentation, comment lines, blank lines, slashdashed nodes.
	public StringView mLeading;
	/// The annotation and the space after it: `(type) `.
	public StringView mHeadPrefix;
	/// The name as written.
	public StringView mName;
	/// From the last entry to just after the children block's `{` (slashdashed blocks included).
	public StringView mBeforeChildren;
	/// From the last child to just after `}`.
	public StringView mBlockEnd;
	/// After the entries (or `}`), through the terminator: a newline, `;` or `//` comment, or nothing
	/// before the parent's `}` or the end.
	public StringView mTail;
	public KdlStyleFlags mFlags;
}

/// PreserveStyle: an entry's source text.
internal struct KdlEntryStyle
{
	/// Before the entry: spaces, comments, line continuations, slashdashed entries.
	public StringView mLeading;
	/// The key, `=` and annotation as written, up to the value.
	public StringView mPrefix;
	/// The value as written.
	public StringView mValue;
	public KdlStyleFlags mFlags;
}

/// PreserveStyle: capturing the source text while reading, and writing it back.
extension KdlDocument
{
	/// The node's style record, growing the list to reach it.
	internal ref KdlNodeStyle NodeStyle(uint32 id)
	{
		while (mNodeStyles.Count <= (int)id)
			mNodeStyles.Add(default);
		return ref mNodeStyles[id];
	}

	/// Marks part of a node to be regenerated on write (PreserveStyle documents only).
	internal void MarkNode(uint32 id, KdlStyleFlags flags)
	{
		if (mPreserve && id < (uint32)mNodeStyles.Count)
			mNodeStyles[id].mFlags |= flags;
	}

	/// Marks part of an entry to be regenerated on write (PreserveStyle documents only).
	internal void MarkEntry(int index, KdlStyleFlags flags)
	{
		if (mPreserve && index < mEntryStyles.Count)
			mEntryStyles[index].mFlags |= flags;
	}

	StringView Piece(StringView slice, int sliceStart, int from, int to)
	{
		return mStore.NewText(slice.Substring(from - sliceStart, to - from));
	}

	// Capture (Build calls these for each event)

	void CaptureStartNode(KdlReader reader, uint32 parent, uint32 id, int depth)
	{
		StringView slice = reader.SourceText;
		int start = reader.SourceStart;
		int from = start;
		if (reader.BlockOpenEnd >= 0)
		{
			// The parent's `{` comes with its first child
			ref KdlNodeStyle parentStyle = ref NodeStyle(parent);
			parentStyle.mBeforeChildren = Piece(slice, start, from, reader.BlockOpenEnd);
			parentStyle.mFlags |= .HasBlock;
			from = reader.BlockOpenEnd;
		}
		ref KdlNodeStyle style = ref NodeStyle(id);
		style.mLeading = Piece(slice, start, from, reader.Offset);
		style.mHeadPrefix = Piece(slice, start, reader.Offset, reader.NameStart);
		style.mName = Piece(slice, start, reader.NameStart, start + slice.Length);
		style.mFlags |= .Captured;
		// The indentation unit: the first indented line of a nested node
		if (depth == 1 && mIndentUnit.IsEmpty)
		{
			int lineStart = style.mLeading.LastIndexOf('\n') + 1;
			StringView indent = style.mLeading.Substring(lineStart);
			if (!indent.IsEmpty && lineStart > 0 && IsIndentation(indent))
				mIndentUnit.Set(indent);
		}
	}

	static bool IsIndentation(StringView text)
	{
		for (let c in text)
		{
			if (c != ' ' && c != '\t')
				return false;
		}
		return true;
	}

	void CaptureEntry(KdlReader reader, int index)
	{
		StringView slice = reader.SourceText;
		int start = reader.SourceStart;
		while (mEntryStyles.Count <= index)
			mEntryStyles.Add(default);
		ref KdlEntryStyle style = ref mEntryStyles[index];
		style.mLeading = Piece(slice, start, start, reader.Offset);
		style.mPrefix = Piece(slice, start, reader.Offset, reader.ValueStart);
		style.mValue = Piece(slice, start, reader.ValueStart, start + slice.Length);
		style.mFlags = .Captured;
	}

	void CaptureEndNode(KdlReader reader, uint32 id)
	{
		StringView slice = reader.SourceText;
		int start = reader.SourceStart;
		int from = start;
		ref KdlNodeStyle style = ref NodeStyle(id);
		if (reader.BlockOpenEnd >= 0)
		{
			// A block without reported children: its `{` comes with the node's end
			style.mBeforeChildren = Piece(slice, start, from, reader.BlockOpenEnd);
			style.mFlags |= .HasBlock;
			from = reader.BlockOpenEnd;
		}
		if (reader.BlockCloseEnd >= 0)
		{
			style.mBlockEnd = Piece(slice, start, from, reader.BlockCloseEnd);
			style.mFlags |= .HasBlock;
			from = reader.BlockCloseEnd;
		}
		style.mTail = Piece(slice, start, from, start + slice.Length);
		if (reader.NodeTerminated)
			style.mFlags |= .Terminated;
		if (reader.NodeEndsInComment)
			style.mFlags |= .EndsInComment;
	}

	void CaptureEnd(KdlReader reader)
	{
		mTrailing = mStore.NewText(reader.SourceText);
		mHasBom = reader.ContentStart == 3;
	}

	// Writing back

	/// Writes the document from its captured source text, regenerating what was added or changed.
	void WritePreserving(String output)
	{
		if (mHasBom)
			output.Append("\u{FEFF}");
		mWriteStart = output.Length;
		mNeedTerminator = false;
		mInComment = false;
		uint32 id = mNodes[0].mFirstChild;
		int depth = 0;
		while (id != 0)
		{
			WriteNodeStart(id, depth, output);
			ref KdlNodeRecord node = ref mNodes[id];
			bool hasBlock = node.mFirstChild != 0 || StyleFlags(id).HasFlag(.HasBlock);
			if (hasBlock)
			{
				if (StyleFlags(id).HasFlag(.HasBlock))
					output.Append(mNodeStyles[id].mBeforeChildren);
				else
					output.Append(" {");
				if (node.mFirstChild != 0)
				{
					id = node.mFirstChild;
					depth++;
					continue;
				}
				WriteNodeEnd(id, depth, true, output);
			}
			else
				WriteNodeEnd(id, depth, false, output);
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
				WriteNodeEnd(id, depth, true, output);
			}
		}
		output.Append(mTrailing);
	}

	KdlStyleFlags StyleFlags(uint32 id)
	{
		return id < (uint32)mNodeStyles.Count ? mNodeStyles[id].mFlags : .None;
	}

	/// The node's leading text, annotation, name and entries.
	void WriteNodeStart(uint32 id, int depth, String output)
	{
		ref KdlNodeRecord node = ref mNodes[id];
		KdlNodeStyle style = id < (uint32)mNodeStyles.Count ? mNodeStyles[id] : default;
		bool captured = style.mFlags.HasFlag(.Captured);
		// The previous node's end, kept from a place where nothing followed it: separate the two, or
		// they would read as one node (`a` then `b` as `ab`, or `b` as an argument of `a`)
		if (mNeedTerminator)
		{
			output.Append('\n');
			mNeedTerminator = false;
			mInComment = false;
		}
		if (captured && !style.mFlags.HasFlag(.LeadingDirty))
			output.Append(style.mLeading);
		else
		{
			// On a line of its own, indented like the document
			if (output.Length > mWriteStart && !output.EndsWith('\n'))
				output.Append('\n');
			AppendIndent(output, depth);
		}
		if (captured && !style.mFlags.HasFlag(.HeadPrefixDirty))
			output.Append(style.mHeadPrefix);
		else if (node.mFlags.HasFlag(.HasAnnotation))
			KdlCanonical.AppendAnnotation(output, node.mAnnotation);
		if (captured && !style.mFlags.HasFlag(.NameDirty))
			output.Append(style.mName);
		else
			KdlCanonical.AppendString(output, node.mName);

		for (int32 i = node.mEntryStart; i < node.mEntryStart + node.mEntryCount; i++)
		{
			ref KdlEntryRecord entry = ref mEntries[i];
			KdlEntryStyle entryStyle = i < mEntryStyles.Count ? mEntryStyles[i] : default;
			bool entryCaptured = entryStyle.mFlags.HasFlag(.Captured);
			output.Append(entryCaptured ? entryStyle.mLeading : " ");
			if (entryCaptured && !entryStyle.mFlags.HasFlag(.PrefixDirty))
				output.Append(entryStyle.mPrefix);
			else
			{
				if (entry.mFlags.HasFlag(.IsProperty))
				{
					KdlCanonical.AppendString(output, entry.mKey);
					output.Append('=');
				}
				if (entry.mFlags.HasFlag(.HasAnnotation))
					KdlCanonical.AppendAnnotation(output, entry.mAnnotation);
			}
			if (entryCaptured && !entryStyle.mFlags.HasFlag(.ValueDirty))
				output.Append(entryStyle.mValue);
			else
				AppendStyledValue(output, entry.mValue, entryCaptured ? entryStyle.mValue : default);
		}
	}

	/// The end of a node: its block's end (when `hasBlock`) and its tail.
	void WriteNodeEnd(uint32 id, int depth, bool hasBlock, String output)
	{
		KdlNodeStyle style = id < (uint32)mNodeStyles.Count ? mNodeStyles[id] : default;
		if (hasBlock)
		{
			if (style.mFlags.HasFlag(.HasBlock))
			{
				// The last child's tail may end in a `//` comment the end of the input closed (it moved
				// here from the end): the `}` would be inside it
				if (mInComment)
					output.Append('\n');
				output.Append(style.mBlockEnd);
			}
			else
			{
				if (!output.EndsWith('\n'))
					output.Append('\n');
				AppendIndent(output, depth);
				output.Append('}');
			}
			mInComment = false;
		}
		if (style.mFlags.HasFlag(.Captured))
		{
			// How the node ended in the source, as the reader saw it: what follows may need a terminator
			output.Append(style.mTail);
			mNeedTerminator = !style.mFlags.HasFlag(.Terminated);
			mInComment = style.mFlags.HasFlag(.EndsInComment);
		}
		else
		{
			output.Append('\n');
			mNeedTerminator = false;
			mInComment = false;
		}
	}

	void AppendIndent(String output, int depth)
	{
		StringView unit = mIndentUnit.IsEmpty ? "    " : mIndentUnit;
		for (int i < depth)
			output.Append(unit);
	}

	/// Writes a changed or added value, in the form its original had when there is one: the same
	/// radix (and hex case) for integers; quoted, raw or bare for strings.
	static void AppendStyledValue(String output, KdlValue value, StringView original)
	{
		switch (value)
		{
		case .Integer(let v, ?):
			StringView digits = original;
			if (digits.StartsWith('-') || digits.StartsWith('+'))
				digits = digits.Substring(1);
			uint32 radix = digits.StartsWith("0x") ? 16 : digits.StartsWith("0o") ? 8 : digits.StartsWith("0b") ? 2 : 10;
			if (radix == 10)
			{
				v.ToString(output);
				return;
			}
			bool upper = false;
			for (let c in digits.Substring(2))
			{
				if (c >= 'A' && c <= 'F')
					upper = true;
			}
			AppendRadix(output, v, radix, upper);
		case .String(let s):
			if (original.StartsWith('"'))
				KdlCanonical.AppendQuoted(output, s);
			else if (original.StartsWith('#') && CanWriteRaw(s))
				AppendRaw(output, s);
			else
				KdlCanonical.AppendString(output, s);
		default:
			KdlCanonical.AppendValue(output, value);
		}
	}

	static void AppendRadix(String output, int64 value, uint32 radix, bool upper)
	{
		uint64 magnitude = value < 0 ? (uint64)0 &- (uint64)value : (uint64)value;
		if (value < 0)
			output.Append('-');
		output.Append(radix == 16 ? "0x" : radix == 8 ? "0o" : "0b");
		char8[64] digits = ?;
		int count = 0;
		repeat
		{
			uint32 digit = (uint32)(magnitude % radix);
			digits[count++] = digit < 10 ? (char8)('0' + digit) : (char8)((upper ? 'A' : 'a') + digit - 10);
			magnitude /= radix;
		}
		while (magnitude != 0);
		while (count > 0)
			output.Append(digits[--count]);
	}

	/// Whether a raw string can hold `s`: one line, no code point that must be escaped, and not starting
	/// with two quotes (or being one), which would open it as `#"""`, a multi-line raw string.
	static bool CanWriteRaw(StringView s)
	{
		if (s.StartsWith('"') && (s.Length == 1 || s[1] == '"'))
			return false;
		int i = 0;
		while (i < s.Length)
		{
			char32 cp = Utf8.Decode(s.Ptr, i, let length);
			if (KdlChar.IsNewline(cp) || KdlChar.IsDisallowed(cp))
				return false;
			i += length;
		}
		return true;
	}

	/// `#"…"#` with enough `#`s that no `"` followed by them occurs inside.
	static void AppendRaw(String output, StringView s)
	{
		int hashes = 1;
		for (int i < s.Length)
		{
			if (s[i] != '"')
				continue;
			int run = 0;
			while (i + 1 + run < s.Length && s[i + 1 + run] == '#')
				run++;
			hashes = Math.Max(hashes, run + 1);
		}
		output.Append('#', hashes);
		output.Append('"');
		output.Append(s);
		output.Append('"');
		output.Append('#', hashes);
	}
}

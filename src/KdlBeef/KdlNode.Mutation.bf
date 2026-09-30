using System;
using internal KdlBeef;

namespace KdlBeef;

/// Changing a node: its place in the tree, its children, its arguments and properties. Every method
/// needs a valid handle (a fatal error otherwise); strings and values passed in are copied.
extension KdlNode
{
	// Structure

	/// @brief Add a child node at the end of this node's children.
	/// @param name The new node's name.
	/// @return The new node.
	public KdlNode AddChild(StringView name)
	{
		// The document root too: a top-level node
		if (!IsValid)
			Runtime.FatalError("KdlNode: the handle is invalid (no node, a removed node, or a cleared document)");
		uint32 id = mDocument.NewNode(name, false, default);
		mDocument.LinkLastChild(mId, id);
		return .(mDocument, id);
	}

	/// @brief Add a node just before this one, under the same parent.
	/// @param name The new node's name.
	/// @return The new node.
	public KdlNode InsertBefore(StringView name)
	{
		CheckValid();
		uint32 id = mDocument.NewNode(name, false, default);
		mDocument.LinkBefore(mId, id);
		return .(mDocument, id);
	}

	/// @brief Add a node just after this one, under the same parent.
	/// @param name The new node's name.
	/// @return The new node.
	public KdlNode InsertAfter(StringView name)
	{
		CheckValid();
		uint32 id = mDocument.NewNode(name, false, default);
		mDocument.LinkAfter(mId, id);
		return .(mDocument, id);
	}

	/// @brief Remove this node and its descendants from the document. Handles to any of them become
	/// invalid.
	public void Remove()
	{
		CheckValid();
		mDocument.RemoveNode(mId);
	}

	/// @brief Move this node (with its subtree) to the end of `parent`'s children.
	/// @param parent The new parent, in the same document.
	/// @return False, changing nothing, if `parent` is invalid, in another document, or this node or
	/// one of its descendants.
	public bool MoveInto(KdlNode parent)
	{
		CheckValid();
		if (!parent.IsValid || parent.mDocument != mDocument || mDocument.IsSelfOrAncestor(mId, parent.mId))
			return false;
		mDocument.Unlink(mId);
		// Its indentation (and the comments before it) belonged to its old place
		mDocument.MarkNode(mId, .LeadingDirty);
		mDocument.LinkLastChild(parent.mId, mId);
		return true;
	}

	/// @brief Move this node (with its subtree) to the end of the document's top-level nodes.
	public void MoveToTopLevel()
	{
		CheckValid();
		mDocument.Unlink(mId);
		// Its indentation (and the comments before it) belonged to its old place
		mDocument.MarkNode(mId, .LeadingDirty);
		mDocument.LinkLastChild(0, mId);
	}

	/// @brief Move this node (with its subtree) just before `sibling`, under the sibling's parent.
	/// @param sibling The node to move before, in the same document.
	/// @return False, changing nothing, if `sibling` is invalid, in another document, or this node or
	/// one of its descendants.
	public bool MoveBefore(KdlNode sibling)
	{
		CheckValid();
		if (!sibling.IsValid || sibling.IsDocumentRoot || sibling.mDocument != mDocument || mDocument.IsSelfOrAncestor(mId, sibling.mId))
			return false;
		mDocument.Unlink(mId);
		// Its indentation (and the comments before it) belonged to its old place
		mDocument.MarkNode(mId, .LeadingDirty);
		mDocument.LinkBefore(sibling.mId, mId);
		return true;
	}

	/// @brief Move this node (with its subtree) just after `sibling`, under the sibling's parent.
	/// @param sibling The node to move after, in the same document.
	/// @return False, changing nothing, if `sibling` is invalid, in another document, or this node or
	/// one of its descendants.
	public bool MoveAfter(KdlNode sibling)
	{
		CheckValid();
		if (!sibling.IsValid || sibling.IsDocumentRoot || sibling.mDocument != mDocument || mDocument.IsSelfOrAncestor(mId, sibling.mId))
			return false;
		mDocument.Unlink(mId);
		// Its indentation (and the comments before it) belonged to its old place
		mDocument.MarkNode(mId, .LeadingDirty);
		mDocument.LinkAfter(sibling.mId, mId);
		return true;
	}

	// Arguments

	/// @brief Add an argument after the existing entries.
	/// @param value The value.
	public void AddArgument(KdlValue value)
	{
		CheckValid();
		mDocument.AppendEntry(mId, mDocument.MakeEntry(false, default, false, default, value));
	}

	/// @brief Add an argument with a type annotation after the existing entries: `(annotation)value`.
	/// @param value The value.
	/// @param annotation The annotation.
	public void AddArgument(KdlValue value, StringView annotation)
	{
		CheckValid();
		mDocument.AppendEntry(mId, mDocument.MakeEntry(false, default, true, annotation, value));
	}

	/// @brief Replace an argument's value, keeping its annotation.
	/// @param index The argument's position among the arguments.
	/// @param value The new value.
	/// @return Whether there is such an argument.
	public bool SetArgument(int index, KdlValue value)
	{
		CheckValid();
		int entry = FindArgument(index);
		if (entry < 0)
			return false;
		mDocument.mEntries[entry].mValue = mDocument.mStore.OwnValue(value, false);
		mDocument.MarkEntry(entry, .ValueDirty);
		return true;
	}

	/// @brief Remove an argument.
	/// @param index The argument's position among the arguments.
	/// @return Whether there was such an argument.
	public bool RemoveArgument(int index)
	{
		int entry = FindArgument(index);
		if (entry < 0)
			return false;
		mDocument.RemoveEntry(mId, entry - Record.mEntryStart);
		return true;
	}

	/// The entry index of the argument at `index`, or -1.
	int FindArgument(int index)
	{
		ref KdlNodeRecord node = ref Record;
		int remaining = index;
		for (int i = node.mEntryStart; i < node.mEntryStart + node.mEntryCount; i++)
		{
			if (mDocument.mEntries[i].mFlags.HasFlag(.IsProperty))
				continue;
			if (remaining-- == 0)
				return i;
		}
		return -1;
	}

	// Properties

	/// @brief Set a property: replace the value of the last property with this key (the one that
	/// counts), keeping its annotation and place, or add the property after the existing entries.
	/// Earlier duplicates are left as they are (they have no effect).
	/// @param key The key.
	/// @param value The value.
	public void SetProperty(StringView key, KdlValue value)
	{
		CheckValid();
		int entry = FindProperty(key);
		if (entry >= 0)
		{
			mDocument.mEntries[entry].mValue = mDocument.mStore.OwnValue(value, false);
			mDocument.MarkEntry(entry, .ValueDirty);
		}
		else
			mDocument.AppendEntry(mId, mDocument.MakeEntry(true, key, false, default, value));
	}

	/// @brief Set a property with a type annotation, `key=(annotation)value`: as SetProperty, but the
	/// annotation is set too.
	/// @param key The key.
	/// @param value The value.
	/// @param annotation The annotation.
	public void SetProperty(StringView key, KdlValue value, StringView annotation)
	{
		CheckValid();
		int entry = FindProperty(key);
		if (entry >= 0)
		{
			ref KdlEntryRecord record = ref mDocument.mEntries[entry];
			record.mValue = mDocument.mStore.OwnValue(value, false);
			record.mAnnotation = mDocument.mStore.NewText(annotation);
			record.mFlags |= .HasAnnotation;
			mDocument.MarkEntry(entry, .ValueDirty | .PrefixDirty);
		}
		else
			mDocument.AppendEntry(mId, mDocument.MakeEntry(true, key, true, annotation, value));
	}

	/// @brief Remove every property with this key.
	/// @param key The key.
	/// @return How many were removed.
	public int RemoveProperty(StringView key)
	{
		int removed = 0;
		while (true)
		{
			int entry = FindProperty(key);
			if (entry < 0)
				return removed;
			mDocument.RemoveEntry(mId, entry - Record.mEntryStart);
			removed++;
		}
	}

	// Entries

	/// @brief Remove the entry (argument or property) at a position in `Entries`.
	/// @param index The position.
	public void RemoveEntryAt(int index)
	{
		CheckValid();
		Runtime.Assert((uint)index < (uint)Record.mEntryCount, "KdlNode.RemoveEntryAt: index out of range");
		mDocument.RemoveEntry(mId, index);
	}

	/// @brief Remove every argument and property.
	public void ClearEntries()
	{
		CheckValid();
		Record.mEntryCount = 0;
	}

	// For the typed mapping (KdlBind)

	/// The position in Entries of the last property with `key`, or -1.
	internal int PropertyIndex(StringView key)
	{
		int entry = FindProperty(key);
		return entry < 0 ? -1 : entry - Record.mEntryStart;
	}

	/// The position in Entries of the argument at `index`, or -1.
	internal int ArgumentIndex(int index)
	{
		int entry = FindArgument(index);
		return entry < 0 ? -1 : entry - Record.mEntryStart;
	}

	/// Sets the argument at `index`, with an annotation when `hasAnnotation`, adding `#null`
	/// arguments first if there are fewer.
	internal void WriteArgument(int index, KdlValue value, bool hasAnnotation, StringView annotation)
	{
		CheckValid();
		while (ArgumentCount < index)
			AddArgument(.Null);
		int entry = FindArgument(index);
		if (entry < 0)
		{
			if (hasAnnotation)
				AddArgument(value, annotation);
			else
				AddArgument(value);
			return;
		}
		ref KdlEntryRecord record = ref mDocument.mEntries[entry];
		record.mValue = mDocument.mStore.OwnValue(value, false);
		if (hasAnnotation)
		{
			record.mAnnotation = mDocument.mStore.NewText(annotation);
			record.mFlags |= .HasAnnotation;
			mDocument.MarkEntry(entry, .ValueDirty | .PrefixDirty);
		}
		else
			mDocument.MarkEntry(entry, .ValueDirty);
	}

	/// Changes the key of the property at `position` in Entries (an alias renamed on write).
	internal void RenameProperty(int position, StringView key)
	{
		CheckValid();
		int32 entry = Record.mEntryStart + (int32)position;
		mDocument.mEntries[entry].mKey = mDocument.mStore.NewText(key);
		mDocument.MarkEntry(entry, .PrefixDirty);
	}

	/// A node to change: valid, and not the document root (which has no name, entries or siblings).
	[Inline]
	void CheckValid()
	{
		if (!IsValid)
			Runtime.FatalError("KdlNode: the handle is invalid (no node, a removed node, or a cleared document)");
		if (mId == 0)
			Runtime.FatalError("KdlNode: the document root has no name, entries or place to change");
	}
}

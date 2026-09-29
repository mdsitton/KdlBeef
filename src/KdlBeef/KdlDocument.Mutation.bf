using System;
using System.Collections;
using internal KdlBeef;

namespace KdlBeef;

/// Changing the node tree and entries. Public entry points are on KdlNode (and AddNode here); these
/// are the operations on the tables they share.
extension KdlDocument
{
	/// @brief Add a top-level node at the end.
	/// @param name The node's name.
	/// @return The new node.
	public KdlNode AddNode(StringView name)
	{
		uint32 id = NewNode(name, false, default);
		LinkLastChild(0, id);
		return .(this, id);
	}

	// Links

	/// Links an unlinked node before `sibling`, under the sibling's parent.
	internal void LinkBefore(uint32 sibling, uint32 child)
	{
		ref KdlNodeRecord s = ref mNodes[sibling];
		ref KdlNodeRecord c = ref mNodes[child];
		ref KdlNodeRecord p = ref mNodes[s.mParent];
		c.mParent = s.mParent;
		c.mNextSibling = sibling;
		c.mPrevSibling = s.mPrevSibling;
		if (s.mPrevSibling != 0)
			mNodes[s.mPrevSibling].mNextSibling = child;
		else
			p.mFirstChild = child;
		s.mPrevSibling = child;
		p.mChildCount++;
	}

	/// Links an unlinked node after `sibling`, under the sibling's parent.
	internal void LinkAfter(uint32 sibling, uint32 child)
	{
		uint32 next = mNodes[sibling].mNextSibling;
		if (next != 0)
			LinkBefore(next, child);
		else
			LinkLastChild(mNodes[sibling].mParent, child);
	}

	/// Takes a node (and its subtree) out of its parent's children; it stays in the table.
	internal void Unlink(uint32 id)
	{
		ref KdlNodeRecord c = ref mNodes[id];
		ref KdlNodeRecord p = ref mNodes[c.mParent];
		if (c.mPrevSibling != 0)
			mNodes[c.mPrevSibling].mNextSibling = c.mNextSibling;
		else
			p.mFirstChild = c.mNextSibling;
		if (c.mNextSibling != 0)
			mNodes[c.mNextSibling].mPrevSibling = c.mPrevSibling;
		else
			p.mLastChild = c.mPrevSibling;
		p.mChildCount--;
		c.mParent = 0;
		c.mNextSibling = 0;
		c.mPrevSibling = 0;
	}

	/// Unlinks a node and marks it and every descendant removed. Their slots are not reused before
	/// Clear, so handles to them become invalid rather than naming other nodes.
	internal void RemoveNode(uint32 id)
	{
		Unlink(id);
		// Walk the subtree through the links; the removed node's parent is now 0, so the walk stops
		// on returning to it
		uint32 current = id;
		while (true)
		{
			mNodes[current].mFlags |= .Removed;
			if (mNodes[current].mFirstChild != 0)
			{
				current = mNodes[current].mFirstChild;
				continue;
			}
			while (current != id && mNodes[current].mNextSibling == 0)
				current = mNodes[current].mParent;
			if (current == id)
				return;
			current = mNodes[current].mNextSibling;
		}
	}

	/// Whether `ancestor` is `id` or one of its ancestors.
	internal bool IsSelfOrAncestor(uint32 ancestor, uint32 id)
	{
		uint32 current = id;
		while (current != 0)
		{
			if (current == ancestor)
				return true;
			current = mNodes[current].mParent;
		}
		return false;
	}

	// Entries

	/// Whether entry source ranges are kept (the document was read with Positions); they then mirror
	/// every change to mEntries.
	// The per-entry side tables (source ranges, PreserveStyle text) follow their entries: a table is in
	// use when it is not empty, and entries added since the read have default (empty) records.

	void SideCopy<T>(List<T> list, int32 from, int32 to, int32 count) where T : struct
	{
		if (list.IsEmpty)
			return;
		while (list.Count < mEntries.Count)
			list.Add(default);
		for (int32 i < count)
			list[to + i] = list[from + i];
	}

	void SideClear<T>(List<T> list, int32 at) where T : struct
	{
		if (list.IsEmpty)
			return;
		while (list.Count < mEntries.Count)
			list.Add(default);
		list[at] = default;
	}

	void SideRemove<T>(List<T> list, int32 at, int32 end) where T : struct
	{
		if (list.IsEmpty)
			return;
		while (list.Count < mEntries.Count)
			list.Add(default);
		for (int32 i = at; i < end - 1; i++)
			list[i] = list[i + 1];
	}

	/// Appends an entry to a node, growing its range in place when it can and moving it to the end of
	/// the entry list otherwise (the old range becomes a hole until Clear).
	internal void AppendEntry(uint32 id, KdlEntryRecord entry)
	{
		ref KdlNodeRecord node = ref mNodes[id];
		int32 end = node.mEntryStart + node.mEntryCount;
		if (node.mEntryCount == node.mEntryCapacity)
		{
			if (end == mEntries.Count)
			{
				// The range is at the end of the list: extend it
				mEntries.Add(default);
				node.mEntryCapacity++;
			}
			else
			{
				int32 capacity = Math.Max(node.mEntryCount * 2, 4);
				int32 newStart = (int32)mEntries.Count;
				mEntries.GrowUninitialized(capacity);
				for (int32 i < node.mEntryCount)
					mEntries[newStart + i] = mEntries[node.mEntryStart + i];
				SideCopy(mEntryRanges, node.mEntryStart, newStart, node.mEntryCount);
				SideCopy(mEntryStyles, node.mEntryStart, newStart, node.mEntryCount);
				node.mEntryStart = newStart;
				node.mEntryCapacity = capacity;
			}
			end = node.mEntryStart + node.mEntryCount;
		}
		mEntries[end] = entry;
		SideClear(mEntryRanges, end);
		SideClear(mEntryStyles, end);
		node.mEntryCount++;
	}

	/// Removes the node's entry at `index` (0-based within the node), keeping the order of the rest.
	internal void RemoveEntry(uint32 id, int index)
	{
		ref KdlNodeRecord node = ref mNodes[id];
		int32 at = node.mEntryStart + (int32)index;
		int32 end = node.mEntryStart + node.mEntryCount;
		for (int32 i = at; i < end - 1; i++)
			mEntries[i] = mEntries[i + 1];
		SideRemove(mEntryRanges, at, end);
		SideRemove(mEntryStyles, at, end);
		node.mEntryCount--;
	}

	/// An entry record with its own copies of the key, annotation and value.
	internal KdlEntryRecord MakeEntry(bool isProperty, StringView key, bool hasAnnotation, StringView annotation, KdlValue value)
	{
		KdlEntryRecord entry = default;
		if (isProperty)
		{
			entry.mKey = mStore.NewText(key);
			entry.mFlags = .IsProperty;
		}
		if (hasAnnotation)
		{
			entry.mAnnotation = mStore.NewText(annotation);
			entry.mFlags |= .HasAnnotation;
		}
		entry.mValue = mStore.OwnValue(value, false);
		return entry;
	}
}

using System;
using System.Collections;
using internal KdlBeef;

namespace KdlBeef;

/// Lookups on a node: typed argument and property values, and finding nodes by name among the
/// children or the whole subtree.
///
/// The `Find` and `Get…`/`TryGet…` methods also accept the empty handle that a failed Find returns, so
/// lookups chain: `doc.Root.Find("window").Find("grid").GetInt64("columns", 1)` is 1 when there is no
/// window, no grid or no columns. (A handle to a removed node is still a fatal error.)
extension KdlNode
{
	/// Whether this is the empty handle (default, as a failed Find returns), which lookups treat as
	/// "no node".
	bool IsNone => mDocument == null;

	// Finding nodes

	/// @brief The first child with the given name (Children.Find).
	/// @param name The node name.
	/// @return The child, or an invalid handle (also for an invalid handle, so Finds chain).
	public KdlNode Find(StringView name)
	{
		if (IsNone)
			return default;
		return Children.Find(name);
	}

	/// @brief Every node below this one, depth first, in document order (a node, then its children):
	/// `for (let slider in window.Descendants.Named("slider"))`. Do not add or remove nodes during the
	/// loop.
	public KdlDescendants Descendants
	{
		get
		{
			Runtime.Assert(IsValid, "KdlNode: the handle is invalid");
			return .(mDocument, mId);
		}
	}

	// Typed properties

	/// @brief Get a string property. With duplicate keys, the last one wins.
	/// @param key The property key.
	/// @param value Receives the string, valid until the document changes.
	/// @return Whether the node has the property and it is a string.
	public bool TryGetString(StringView key, out StringView value)
	{
		value = default;
		return Property(key, let v) && v.TryGetString(out value);
	}

	/// @brief Get an integer property within int64.
	/// @param key The property key.
	/// @param value Receives the integer.
	/// @return Whether the node has the property and it is an int64 integer.
	public bool TryGetInt64(StringView key, out int64 value)
	{
		value = 0;
		return Property(key, let v) && v.TryGetInt64(out value);
	}

	/// @brief Get a numeric property as a double (a float, or an integer converted).
	/// @param key The property key.
	/// @param value Receives the number.
	/// @return Whether the node has the property and it is a float or an int64 integer.
	public bool TryGetDouble(StringView key, out double value)
	{
		value = 0;
		return Property(key, let v) && v.TryGetDouble(out value);
	}

	/// @brief Get a boolean property.
	/// @param key The property key.
	/// @param value Receives the boolean.
	/// @return Whether the node has the property and it is a boolean.
	public bool TryGetBool(StringView key, out bool value)
	{
		value = false;
		return Property(key, let v) && v.TryGetBool(out value);
	}

	/// @brief A string property, or `defaultValue` when it is absent or not a string.
	/// @param key The property key.
	/// @param defaultValue The fallback.
	/// @return The string (valid until the document changes) or the fallback.
	public StringView GetString(StringView key, StringView defaultValue = default) => TryGetString(key, let v) ? v : defaultValue;

	/// @brief An integer property, or `defaultValue` when it is absent or not an int64 integer.
	/// @param key The property key.
	/// @param defaultValue The fallback.
	/// @return The integer or the fallback.
	public int64 GetInt64(StringView key, int64 defaultValue = 0) => TryGetInt64(key, let v) ? v : defaultValue;

	/// @brief A numeric property as a double, or `defaultValue` when it is absent or not a number.
	/// @param key The property key.
	/// @param defaultValue The fallback.
	/// @return The number or the fallback.
	public double GetDouble(StringView key, double defaultValue = 0) => TryGetDouble(key, let v) ? v : defaultValue;

	/// @brief A boolean property, or `defaultValue` when it is absent or not a boolean.
	/// @param key The property key.
	/// @param defaultValue The fallback.
	/// @return The boolean or the fallback.
	public bool GetBool(StringView key, bool defaultValue = false) => TryGetBool(key, let v) ? v : defaultValue;

	// Typed arguments

	/// @brief Get a string argument.
	/// @param index The argument's position among the arguments.
	/// @param value Receives the string, valid until the document changes.
	/// @return Whether there is such an argument and it is a string.
	public bool TryGetString(int index, out StringView value)
	{
		value = default;
		return Argument(index, let v) && v.TryGetString(out value);
	}

	/// @brief Get an integer argument within int64.
	/// @param index The argument's position among the arguments.
	/// @param value Receives the integer.
	/// @return Whether there is such an argument and it is an int64 integer.
	public bool TryGetInt64(int index, out int64 value)
	{
		value = 0;
		return Argument(index, let v) && v.TryGetInt64(out value);
	}

	/// @brief Get a numeric argument as a double (a float, or an integer converted).
	/// @param index The argument's position among the arguments.
	/// @param value Receives the number.
	/// @return Whether there is such an argument and it is a float or an int64 integer.
	public bool TryGetDouble(int index, out double value)
	{
		value = 0;
		return Argument(index, let v) && v.TryGetDouble(out value);
	}

	/// @brief Get a boolean argument.
	/// @param index The argument's position among the arguments.
	/// @param value Receives the boolean.
	/// @return Whether there is such an argument and it is a boolean.
	public bool TryGetBool(int index, out bool value)
	{
		value = false;
		return Argument(index, let v) && v.TryGetBool(out value);
	}

	/// @brief A string argument, or `defaultValue` when it is absent or not a string.
	/// @param index The argument's position among the arguments.
	/// @param defaultValue The fallback.
	/// @return The string (valid until the document changes) or the fallback.
	public StringView GetString(int index, StringView defaultValue = default) => TryGetString(index, let v) ? v : defaultValue;

	/// @brief An integer argument, or `defaultValue` when it is absent or not an int64 integer.
	/// @param index The argument's position among the arguments.
	/// @param defaultValue The fallback.
	/// @return The integer or the fallback.
	public int64 GetInt64(int index, int64 defaultValue = 0) => TryGetInt64(index, let v) ? v : defaultValue;

	/// @brief A numeric argument as a double, or `defaultValue` when it is absent or not a number.
	/// @param index The argument's position among the arguments.
	/// @param defaultValue The fallback.
	/// @return The number or the fallback.
	public double GetDouble(int index, double defaultValue = 0) => TryGetDouble(index, let v) ? v : defaultValue;

	/// @brief A boolean argument, or `defaultValue` when it is absent or not a boolean.
	/// @param index The argument's position among the arguments.
	/// @param defaultValue The fallback.
	/// @return The boolean or the fallback.
	public bool GetBool(int index, bool defaultValue = false) => TryGetBool(index, let v) ? v : defaultValue;

	/// TryGetProperty that treats the empty handle as a node without properties
	bool Property(StringView key, out KdlValue value)
	{
		value = .Null;
		return !IsNone && TryGetProperty(key, out value);
	}

	/// TryGetArgument that treats the empty handle as a node without arguments
	bool Argument(int index, out KdlValue value)
	{
		value = .Null;
		return !IsNone && TryGetArgument(index, out value);
	}
}

extension KdlNodeList
{
	/// @brief The nodes with the given name, in order: `for (let button in panel.Children.Named("button"))`.
	/// @param name The node name (borrowed for the loop).
	/// @return The matching nodes.
	public KdlNamedNodes Named(StringView name) => .(mDocument, Parent.mFirstChild, name);
}

/// Sibling nodes with one name (KdlNodeList.Named). Like the list's own enumerator, it reads the next
/// match before returning the current one, so the current node may be removed during the loop. Using it
/// after the document is read again or cleared is a fatal error.
public struct KdlNamedNodes : IEnumerable<KdlNode>
{
	KdlDocument mDocument;
	uint32 mFirst;
	StringView mName;
	uint32 mGeneration;

	internal this(KdlDocument document, uint32 first, StringView name)
	{
		mDocument = document;
		mFirst = first;
		mName = name;
		mGeneration = document.mGeneration;
	}

	/// @brief The first match.
	/// @return The node, or an invalid handle when none has the name.
	public KdlNode First => KdlNode.Of(mDocument, Next(mFirst));

	/// @brief The number of matches (walks the siblings).
	public int Count
	{
		get
		{
			int count = 0;
			for (uint32 id = Next(mFirst); id != 0; id = Next(mDocument.mNodes[id].mNextSibling))
				count++;
			return count;
		}
	}

	/// The first node from `id` on (itself included) with the name, or 0
	uint32 Next(uint32 id)
	{
		mDocument.CheckView(mGeneration, 0);
		var id;
		while (id != 0 && mDocument.mNodes[id].mName != mName)
			id = mDocument.mNodes[id].mNextSibling;
		return id;
	}

	public Enumerator GetEnumerator() => .(this);

	public struct Enumerator : IEnumerator<KdlNode>
	{
		KdlNamedNodes mNodes;
		uint32 mNext;

		internal this(KdlNamedNodes nodes)
		{
			mNodes = nodes;
			mNext = nodes.Next(nodes.mFirst);
		}

		public Result<KdlNode> GetNext() mut
		{
			if (mNext == 0)
				return .Err;
			mNodes.mDocument.CheckView(mNodes.mGeneration, 0);
			let node = KdlNode(mNodes.mDocument, mNext);
			mNext = mNodes.Next(mNodes.mDocument.mNodes[mNext].mNextSibling);
			return node;
		}
	}
}

/// Every node below one node (KdlNode.Descendants), depth first in document order: a node, then its
/// children, then its next sibling. Do not add or remove nodes while enumerating; using it after the
/// document is read again or cleared, or the node removed, is a fatal error.
public struct KdlDescendants : IEnumerable<KdlNode>
{
	KdlDocument mDocument;
	uint32 mRoot;
	StringView mName;
	bool mFiltered;
	uint32 mGeneration;

	internal this(KdlDocument document, uint32 root, StringView name = default, bool filtered = false)
	{
		mDocument = document;
		mRoot = root;
		mName = name;
		mFiltered = filtered;
		mGeneration = document.mGeneration;
	}

	/// @brief Only the descendants with the given name: `window.Descendants.Named("button")`.
	/// @param name The node name (borrowed for the loop).
	/// @return The matching descendants, in the same order.
	public KdlDescendants Named(StringView name)
	{
		var named = KdlDescendants(mDocument, mRoot, name, true);
		named.mGeneration = mGeneration;
		return named;
	}

	/// @brief The first descendant (with the name, after Named), depth first.
	/// @return The node, or an invalid handle when there is none.
	public KdlNode First => KdlNode.Of(mDocument, Match(After(mRoot, true)));

	/// @brief The first descendant with the given name, depth first.
	/// @param name The node name.
	/// @return The node, or an invalid handle when there is none.
	public KdlNode Find(StringView name) => Named(name).First;

	/// @brief The number of descendants (with the name, after Named). Walks the subtree.
	public int Count
	{
		get
		{
			int count = 0;
			for (uint32 id = Match(After(mRoot, true)); id != 0; id = Match(After(id, true)))
				count++;
			return count;
		}
	}

	/// The node after `id` in depth-first order within the subtree, or 0 at its end. With `enter`,
	/// `id`'s own children come first.
	uint32 After(uint32 id, bool enter)
	{
		mDocument.CheckView(mGeneration, mRoot);
		if (enter && mDocument.mNodes[id].mFirstChild != 0)
			return mDocument.mNodes[id].mFirstChild;
		var id;
		while (id != mRoot)
		{
			uint32 next = mDocument.mNodes[id].mNextSibling;
			if (next != 0)
				return next;
			id = mDocument.mNodes[id].mParent;
		}
		return 0;
	}

	/// The first node from `id` on (itself included) that matches the name filter, or 0
	uint32 Match(uint32 id)
	{
		var id;
		while (id != 0 && mFiltered && mDocument.mNodes[id].mName != mName)
			id = After(id, true);
		return id;
	}

	public Enumerator GetEnumerator() => .(this);

	public struct Enumerator : IEnumerator<KdlNode>
	{
		KdlDescendants mNodes;
		uint32 mNext;

		internal this(KdlDescendants nodes)
		{
			mNodes = nodes;
			mNext = nodes.Match(nodes.After(nodes.mRoot, true));
		}

		public Result<KdlNode> GetNext() mut
		{
			if (mNext == 0)
				return .Err;
			let node = KdlNode(mNodes.mDocument, mNext);
			mNext = mNodes.Match(mNodes.After(mNext, true));
			return node;
		}
	}
}

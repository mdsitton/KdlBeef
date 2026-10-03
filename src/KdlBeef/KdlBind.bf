using System;
using System.Collections;
using FormatCore;
using internal FormatCore;
using internal KdlBeef;

namespace KdlBeef;

/// @brief A value read for a [KdlObject] field or converter: the value, its annotation, and where it is,
/// for located errors.
public struct KdlValueRef
{
	/// @brief The node holding the value (for a `name value` child, that child).
	public KdlNode mNode;
	/// @brief Its position in mNode.Entries.
	public int mEntry;
	/// @brief The property key or child name, for messages (empty for an argument).
	public StringView mName;
	public KdlValue mValue;
	public bool mHasAnnotation;
	public StringView mAnnotation;

	/// @brief An InvalidValue error located at the value, naming where it is.
	/// @param message What is wrong.
	/// @return The error.
	public KdlParseError MakeError(StringView message)
	{
		return KdlBind.MakeError(mNode, mEntry, mName, message, .InvalidValue);
	}
}

/// @brief Where a [KdlObject] field's value is written: a property, an argument, or the argument of a
/// `name value` child node. Converters write through it.
public struct KdlValueWriter
{
	enum Target
	{
		Property,
		Argument,
		Child,
		/// The argument entry at position mIndex in Entries, or a new argument (mIndex -1)
		Entry,
		/// The first argument of mChild, a child of mNode named mName found already (or, invalid, to add)
		KeyedChild
	}

	KdlNode mNode;
	Target mTarget;
	StringView mName;
	int mIndex;
	KdlNode mChild;

	/// @brief The property `key` of `node` (for the document root, the child node `key`).
	/// @param node The node.
	/// @param key The key.
	/// @return The writer.
	public static KdlValueWriter Property(KdlNode node, StringView key)
	{
		KdlValueWriter writer = default;
		writer.mNode = node;
		writer.mTarget = node.IsDocumentRoot ? .Child : .Property;
		writer.mName = key;
		return writer;
	}

	/// @brief The argument at `index` of `node` (`#null`s fill in before it when there are fewer).
	/// @param node The node.
	/// @param index The argument's position.
	/// @return The writer.
	public static KdlValueWriter Argument(KdlNode node, int index)
	{
		KdlValueWriter writer = default;
		writer.mNode = node;
		writer.mTarget = .Argument;
		writer.mIndex = index;
		return writer;
	}

	/// @brief The first argument of the child node `name` (created when missing).
	/// @param node The parent node.
	/// @param name The child's name.
	/// @return The writer.
	public static KdlValueWriter Child(KdlNode node, StringView name)
	{
		KdlValueWriter writer = default;
		writer.mNode = node;
		writer.mTarget = .Child;
		writer.mName = name;
		return writer;
	}

	/// The argument entry at `position` in node.Entries, or with -1 a new argument (KdlArgumentCursor).
	internal static KdlValueWriter Entry(KdlNode node, int position)
	{
		KdlValueWriter writer = default;
		writer.mNode = node;
		writer.mTarget = .Entry;
		writer.mIndex = position;
		return writer;
	}

	/// A dictionary entry `name value` whose node `child` was found by KdlKeyIndex (invalid: none yet).
	internal static KdlValueWriter KeyedChild(KdlNode node, StringView name, KdlNode child)
	{
		KdlValueWriter writer = default;
		writer.mNode = node;
		writer.mTarget = .KeyedChild;
		writer.mName = name;
		writer.mChild = child;
		return writer;
	}

	/// @brief Write `value`, keeping any annotation already there.
	/// @param value The value.
	public void Set(KdlValue value)
	{
		Write(value, false, default);
	}

	/// @brief Write `value` with the annotation `(annotation)`.
	/// @param value The value.
	/// @param annotation The annotation.
	public void Set(KdlValue value, StringView annotation)
	{
		Write(value, true, annotation);
	}

	/// @brief Remove the value (a null String or converter result): the property, or the child node.
	/// An argument becomes `#null`.
	public void Remove()
	{
		switch (mTarget)
		{
		case .Property: mNode.RemoveProperty(mName);
		case .Argument, .Entry: Write(.Null, false, default);
		case .Child: KdlBind.RemoveChild(mNode, mName);
		case .KeyedChild:
			if (mChild.IsValid)
				mChild.Remove();
		}
	}

	void Write(KdlValue value, bool hasAnnotation, StringView annotation)
	{
		switch (mTarget)
		{
		case .Property:
			if (hasAnnotation)
				mNode.SetProperty(mName, value, annotation);
			else
				mNode.SetProperty(mName, value);
		case .Argument:
			if (mNode.IsDocumentRoot)
				Runtime.FatalError("[KdlObject] A document has no arguments: map the field with [KdlChild] or as a property");
			mNode.WriteArgument(mIndex, value, hasAnnotation, annotation);
		case .Child:
			KdlBind.ChildNode(mNode, mName).WriteArgument(0, value, hasAnnotation, annotation);
		case .KeyedChild:
			(mChild.IsValid ? mChild : mNode.AddChild(mName)).WriteArgument(0, value, hasAnnotation, annotation);
		case .Entry:
			if (mNode.IsDocumentRoot)
				Runtime.FatalError("[KdlObject] A document has no arguments: map the field with [KdlChild] or as a property");
			if (mIndex >= 0)
				mNode.WriteEntryValue(mIndex, value, hasAnnotation, annotation);
			else if (hasAnnotation)
				mNode.AddArgument(value, annotation);
			else
				mNode.AddArgument(value);
		}
	}
}

/// @brief The entry nodes of a dictionary's node, by key, for writing the dictionary in one pass (the
/// writer looks each key up here rather than scanning the children). Used by generated code.
public class KdlKeyIndex
{
	struct Entry
	{
		public KdlNode mNode;
		/// Written this time: Finish keeps it
		public bool mUsed;
	}

	KdlNode mNode;
	Dictionary<StringView, Entry> mEntries ~ delete _;

	/// @brief Index the entry nodes of `node`, removing all but the last of duplicate keys (the one
	/// reading used).
	/// @param node The dictionary's node.
	public this(KdlNode node)
	{
		mNode = node;
		mEntries = new .();
		var child = node.LastChild;
		while (child.IsValid)
		{
			let previous = child.PreviousSibling;
			// The name is document text (in its store), so the view outlives the removal
			Entry entry = default;
			entry.mNode = child;
			if (!mEntries.TryAdd(child.Name, entry))
				child.Remove();
			child = previous;
		}
	}

	/// @brief The entry node for `key`, added at the end when there is none.
	/// @param key The key.
	/// @return The node.
	public KdlNode Get(StringView key)
	{
		if (mEntries.TryGetRef(key, ?, let entry))
		{
			entry.mUsed = true;
			return entry.mNode;
		}
		Entry added = default;
		added.mNode = mNode.AddChild(key);
		added.mUsed = true;
		mEntries[added.mNode.Name] = added;
		return added.mNode;
	}

	/// @brief Where a scalar value for `key` goes: the entry node's argument, the node made when it is
	/// written, removed when the value is (a null String).
	/// @param key The key.
	/// @return The writer.
	public KdlValueWriter Value(StringView key)
	{
		KdlNode found = default;
		if (mEntries.TryGetRef(key, ?, let entry))
		{
			entry.mUsed = true;
			found = entry.mNode;
		}
		return KdlValueWriter.KeyedChild(mNode, key, found);
	}

	/// @brief Remove the entry nodes no key was written to (keys the dictionary no longer has).
	public void Finish()
	{
		for (let entry in mEntries.Values)
		{
			if (!entry.mUsed)
				entry.mNode.Remove();
		}
	}
}

/// @brief A node's arguments from one position on, as KdlValueRefs, in one pass over its entries (for
/// reading a List field). Used by generated code.
public struct KdlArgumentRefs : IEnumerable<KdlValueRef>
{
	KdlNode mNode;
	int mFrom;

	internal this(KdlNode node, int from)
	{
		mNode = node;
		mFrom = from;
	}

	public Enumerator GetEnumerator() => .(mNode, mFrom);

	public struct Enumerator : IEnumerator<KdlValueRef>
	{
		KdlNode mNode;
		KdlEntryList mEntries;
		int mPosition;
		int mSkip;

		internal this(KdlNode node, int from)
		{
			mNode = node;
			mEntries = node.IsDocumentRoot ? default : node.Entries;
			mPosition = 0;
			mSkip = from;
		}

		public Result<KdlValueRef> GetNext() mut
		{
			if (mNode.IsDocumentRoot)
				return .Err;
			while (mPosition < mEntries.Count)
			{
				let entry = mEntries[mPosition++];
				if (!entry.IsArgument || mSkip-- > 0)
					continue;
				KdlValueRef value;
				value.mNode = mNode;
				value.mEntry = mPosition - 1;
				value.mName = default;
				value.mValue = entry.Value;
				value.mHasAnnotation = entry.HasAnnotation;
				value.mAnnotation = entry.Annotation;
				return value;
			}
			return .Err;
		}
	}
}

/// @brief Writes a List field's items as a node's arguments from one position on, in one pass: each Next
/// is the following existing argument (updated in place, so annotations and formatting stay) or a new
/// one; Trim removes the arguments after the last one written. Used by generated code.
public struct KdlArgumentCursor
{
	KdlNode mNode;
	/// The entry position to look for the next argument from.
	int mNext;
	/// `#null` arguments still to add before the first item (the node had fewer than `from`).
	int mMissing;

	public this(KdlNode node, int from)
	{
		mNode = node;
		mNext = 0;
		mMissing = 0;
		if (node.IsDocumentRoot)
			return;
		// Past the first `from` arguments
		int skip = from;
		let entries = node.Entries;
		while (skip > 0 && mNext < entries.Count)
		{
			if (entries[mNext].IsArgument)
				skip--;
			mNext++;
		}
		mMissing = skip;
	}

	/// @brief Where the next item goes.
	/// @return The writer for it.
	public KdlValueWriter Next() mut
	{
		if (!mNode.IsDocumentRoot)
		{
			for (; mMissing > 0; mMissing--)
				mNode.AddArgument(.Null);
			let entries = mNode.Entries;
			while (mNext < entries.Count)
			{
				if (entries[mNext].IsArgument)
					return KdlValueWriter.Entry(mNode, mNext++);
				mNext++;
			}
			// A new argument goes after every entry: look past it next time
			mNext = entries.Count + 1;
		}
		return KdlValueWriter.Entry(mNode, -1);
	}

	/// @brief Remove the arguments after the last item written (list items no longer there).
	public void Trim()
	{
		if (mNode.IsDocumentRoot)
			return;
		for (int position = mNode.Entries.Count - 1; position >= mNext; position--)
		{
			if (mNode.Entries[position].IsArgument)
				mNode.RemoveEntryAt(position);
		}
	}
}

/// @brief Writes a List of [KdlObject]s as the child nodes named after the item type, in one pass: each
/// Next is the following child with that name, or a new one after the last of them (or at the end);
/// Trim removes those left over. Used by generated code.
public struct KdlChildCursor
{
	KdlNode mNode;
	StringView mName;
	KdlNode mLast;
	KdlNode mNext;

	public this(KdlNode node, StringView name)
	{
		mNode = node;
		mName = name;
		mLast = default;
		mNext = node.FirstChild;
	}

	/// @brief The node for the next item.
	/// @return The child.
	public KdlNode Next() mut
	{
		while (mNext.IsValid && mNext.Name != mName)
			mNext = mNext.NextSibling;
		if (mNext.IsValid)
		{
			mLast = mNext;
			mNext = mNext.NextSibling;
			return mLast;
		}
		// None left: every later child with the name has been used, so the new one goes after the last
		mLast = mLast.IsValid ? mLast.InsertAfter(mName) : mNode.AddChild(mName);
		return mLast;
	}

	/// @brief Remove the children with the name after the last item written.
	public void Trim() mut
	{
		while (mNext.IsValid)
		{
			let child = mNext;
			mNext = mNext.NextSibling;
			if (child.Name == mName)
				child.Remove();
		}
	}
}

/// @brief Writes a [KdlChildren] list in one pass: item i goes into the i-th child no other field claims
/// if that child has the item's node name, else into a new child inserted there (or at the end); Trim
/// removes the unclaimed children left over. Used by generated code.
public struct KdlFreeChildCursor
{
	KdlNode mNode;
	Span<StringView> mClaimed;
	KdlNode mNext;

	public this(KdlNode node, Span<StringView> claimed)
	{
		mNode = node;
		mClaimed = claimed;
		mNext = node.FirstChild;
	}

	/// @brief The node for the next item.
	/// @param name The item's node name.
	/// @return The child.
	public KdlNode Next(StringView name) mut
	{
		while (mNext.IsValid && KdlBind.IsClaimed(mNext.Name, mClaimed))
			mNext = mNext.NextSibling;
		if (!mNext.IsValid)
			return mNode.AddChild(name);
		if (mNext.Name != name)
			return mNext.InsertBefore(name);
		let child = mNext;
		mNext = mNext.NextSibling;
		return child;
	}

	/// @brief Remove the unclaimed children after the last item written.
	public void Trim() mut
	{
		while (mNext.IsValid)
		{
			let child = mNext;
			mNext = mNext.NextSibling;
			if (!KdlBind.IsClaimed(child.Name, mClaimed))
				child.Remove();
		}
	}
}

/// @brief Runtime support for the code [KdlObject] generates: finding a field's value, converting it with
/// located errors, and writing it back in place. Public because the generated code lives in the user's
/// types; not meant to be called directly.
///
/// The Find* helpers return whether the value is there (`#null` counts as absent): false leaves the field
/// alone, and a missing required value is a located error.
public static class KdlBind
{
	/// @brief An error located at the entry (or, without one, the node), in the form `node: name:
	/// message`.
	/// @param node The node.
	/// @param entry The position of the value in node.Entries, or -1.
	/// @param name The property key or child name, or empty.
	/// @param message What is wrong.
	/// @param kind The error kind.
	/// @return The error.
	public static KdlParseError MakeError(KdlNode node, int entry, StringView name, StringView message, KdlErrorKind kind)
	{
		KdlSourceRange range = default;
		bool located = entry >= 0 && node.Entries[entry].TryGetSourceRange(out range);
		if (!located && !node.IsDocumentRoot)
			located = node.TryGetSourceRange(out range);
		let text = scope String();
		if (!node.IsDocumentRoot)
			text.Append(node.Name, ": ");
		if (!name.IsEmpty && (node.IsDocumentRoot || name != node.Name))
			text.Append(name, ": ");
		else if (name.IsEmpty && entry >= 0 && node.Entries[entry].IsArgument)
			text.AppendF("argument {}: ", ArgumentPosition(node, entry));
		text.Append(message);
		var error = KdlParseError(kind, text, located ? range.mLine : 0, located ? range.mColumn : 0, located ? range.mOffset : 0, located ? range.mLength : 0);
		if (!node.Document.SourceName.IsEmpty)
			error.SetSource(node.Document.SourceName);
		return error;
	}

	static int ArgumentPosition(KdlNode node, int entry)
	{
		int position = 0;
		for (int i < entry)
		{
			if (node.Entries[i].IsArgument)
				position++;
		}
		return position;
	}

	static KdlValueRef Ref(KdlNode node, int entry, StringView name)
	{
		let item = node.Entries[entry];
		KdlValueRef value;
		value.mNode = node;
		value.mEntry = entry;
		value.mName = name;
		value.mValue = item.Value;
		value.mHasAnnotation = item.HasAnnotation;
		value.mAnnotation = item.Annotation;
		return value;
	}

	static KdlParseError Missing(KdlNode node, StringView what)
	{
		return MakeError(node, -1, default, scope $"{what} is required", .MissingValue);
	}

	// Finding values

	/// @brief The property `key` (for the document root, the child node `key`'s value).
	/// @param node The node.
	/// @param key The key.
	/// @param required Whether it must be there.
	/// @param value Receives the value when it is there.
	/// @return Whether it is there, or the error.
	public static Result<bool, KdlParseError> FindProperty(KdlNode node, StringView key, bool required, out KdlValueRef value)
	{
		value = default;
		if (node.IsDocumentRoot)
			return FindChildValue(node, key, required, out value);
		int entry = node.PropertyIndex(key);
		if (entry < 0 || node.Entries[entry].Value case .Null)
		{
			if (required)
				return .Err(Missing(node, scope $"The property `{key}`"));
			return false;
		}
		value = Ref(node, entry, key);
		return true;
	}

	/// @brief The argument at `index`.
	/// @param node The node.
	/// @param index The argument's position.
	/// @param required Whether it must be there.
	/// @param value Receives the value when it is there.
	/// @return Whether it is there, or the error.
	public static Result<bool, KdlParseError> FindArgument(KdlNode node, int index, bool required, out KdlValueRef value)
	{
		value = default;
		int entry = node.IsDocumentRoot ? -1 : node.ArgumentIndex(index);
		if (entry < 0 || node.Entries[entry].Value case .Null)
		{
			if (required)
				return .Err(Missing(node, scope $"Argument {index}"));
			return false;
		}
		value = Ref(node, entry, default);
		return true;
	}

	/// @brief The number of arguments (0 for the document root).
	/// @param node The node.
	/// @return The count.
	public static int ArgumentCount(KdlNode node)
	{
		return node.IsDocumentRoot ? 0 : node.ArgumentCount;
	}

	/// @brief The arguments from position `from` on, in one pass (for lists; none for the document root).
	/// @param node The node.
	/// @param from The first argument's position.
	/// @return The arguments.
	public static KdlArgumentRefs Arguments(KdlNode node, int from)
	{
		return .(node, from);
	}

	/// @brief The child node `name` (the last one, if there are several, as the last property wins).
	/// @param node The node.
	/// @param name The child's name.
	/// @param required Whether it must be there.
	/// @param child Receives the child when it is there.
	/// @return Whether it is there, or the error.
	public static Result<bool, KdlParseError> FindChild(KdlNode node, StringView name, bool required, out KdlNode child)
	{
		child = default;
		for (let candidate in node.Children)
		{
			if (candidate.Name == name)
				child = candidate;
		}
		if (!child.IsValid)
		{
			if (required)
				return .Err(Missing(node, scope $"The child node `{name}`"));
			return false;
		}
		return true;
	}

	/// @brief The value of the child node `name`: its first argument (`timeout 30`).
	/// @param node The node.
	/// @param name The child's name.
	/// @param required Whether it must be there.
	/// @param value Receives the value when it is there.
	/// @return Whether it is there, or the error.
	public static Result<bool, KdlParseError> FindChildValue(KdlNode node, StringView name, bool required, out KdlValueRef value)
	{
		value = default;
		if (!Try!(FindChild(node, name, required, let child)))
			return false;
		int entry = child.ArgumentIndex(0);
		if (entry < 0)
			return .Err(MakeError(child, -1, default, "expected a value (`name value`)", .MissingValue));
		if (child.Entries[entry].Value case .Null)
		{
			if (required)
				return .Err(Missing(child, "A value"));
			return false;
		}
		value = Ref(child, entry, name);
		return true;
	}

	/// @brief The value of a dictionary entry node (`key value`): its first argument.
	/// @param entry The entry node.
	/// @param value Receives the value when it is there.
	/// @return Whether it is there (`#null` counts as absent), or the error when the node has no argument.
	public static Result<bool, KdlParseError> EntryValue(KdlNode entry, out KdlValueRef value)
	{
		value = default;
		int index = entry.ArgumentIndex(0);
		if (index < 0)
			return .Err(MakeError(entry, -1, default, "expected a value (`key value`)", .MissingValue));
		if (entry.Entries[index].Value case .Null)
			return false;
		value = Ref(entry, index, entry.Name);
		return true;
	}

	/// @brief A dictionary entry's name as an integer key (decimal, with an optional sign) within
	/// [min, max].
	/// @param entry The entry node.
	/// @param min The key type's smallest value.
	/// @param max The key type's largest value.
	/// @return The key, or an error located at the entry.
	public static Result<int64, KdlParseError> IntegerKey(KdlNode entry, int64 min, int64 max)
	{
		StringView name = entry.Name;
		if (!KeyMagnitude(name, let negative, let magnitude))
			return .Err(MakeError(entry, -1, default, scope $"the key `{name}` is not an integer", .InvalidValue));
		// The magnitude is unsigned, so int64.MinValue (magnitude 2^63) fits
		bool inRange = negative ? magnitude <= (uint64)int64.MaxValue + 1 : magnitude <= (uint64)int64.MaxValue;
		int64 key = negative ? (int64)(0 &- magnitude) : (int64)magnitude;
		if (!inRange || key < min || key > max)
			return .Err(MakeError(entry, -1, default, scope $"the key `{name}` is outside the range {min} to {max}", .InvalidValue));
		return key;
	}

	/// @brief A dictionary entry's name as a uint64 key (decimal, up to 18446744073709551615).
	/// @param entry The entry node.
	/// @return The key, or an error located at the entry.
	public static Result<uint64, KdlParseError> UnsignedKey(KdlNode entry)
	{
		StringView name = entry.Name;
		if (!KeyMagnitude(name, let negative, let magnitude))
			return .Err(MakeError(entry, -1, default, scope $"the key `{name}` is not an integer", .InvalidValue));
		if (negative && magnitude != 0)
			return .Err(MakeError(entry, -1, default, scope $"the key `{name}` is outside the range 0 to {uint64.MaxValue}", .InvalidValue));
		return magnitude;
	}

	/// A decimal key's sign and magnitude (`-12`, `+3`, `40`), or false when it is not one or does not
	/// fit a uint64.
	static bool KeyMagnitude(StringView name, out bool negative, out uint64 magnitude)
	{
		StringView digits = name;
		negative = false;
		magnitude = 0;
		if (digits.StartsWith('-') || digits.StartsWith('+'))
		{
			negative = digits[0] == '-';
			digits = digits.Substring(1);
		}
		if (digits.IsEmpty)
			return false;
		for (let c in digits)
		{
			if (c < '0' || c > '9')
				return false;
			uint64 digit = (uint64)(c - '0');
			if (magnitude > (uint64.MaxValue - digit) / 10)
				return false;
			magnitude = magnitude * 10 + digit;
		}
		return true;
	}

	/// @brief The error for a dictionary entry whose name is no case of its enum key type.
	/// @param entry The entry node.
	/// @param cases The accepted names, "a, b, c".
	/// @return The error.
	public static KdlParseError UnknownKey(KdlNode entry, StringView cases)
	{
		return MakeError(entry, -1, default, scope $"the key `{entry.Name}` is not one of {cases}", .InvalidValue);
	}

	/// @brief The number of child nodes named `name`.
	/// @param node The node.
	/// @param name The name.
	/// @return The count.
	public static int CountChildren(KdlNode node, StringView name)
	{
		int count = 0;
		for (let child in node.Children)
		{
			if (child.Name == name)
				count++;
		}
		return count;
	}

	// Converting values

	static KdlParseError WrongType(KdlValueRef value, StringView expected)
	{
		return MakeError(value.mNode, value.mEntry, value.mName, scope $"expected {expected}, found {value.mValue.TypeName}", .WrongType);
	}

	/// @brief The value as an integer within [min, max].
	/// @param value The value.
	/// @param min The field type's smallest value.
	/// @param max The field type's largest value.
	/// @return The integer, or the error.
	public static Result<int64, KdlParseError> ToInteger(KdlValueRef value, int64 min, int64 max)
	{
		switch (value.mValue)
		{
		case .Integer(let v, ?):
			if (v < min || v > max)
				return .Err(value.MakeError(scope $"{v} is outside the range {min} to {max}"));
			return v;
		case .BigInteger(let text):
			return .Err(value.MakeError(scope $"{text} is outside the range {min} to {max}"));
		default:
			return .Err(WrongType(value, "integer"));
		}
	}

	/// @brief The value as a uint64 (up to 18446744073709551615, which KDL holds as a big integer).
	/// @param value The value.
	/// @return The integer, or the error.
	public static Result<uint64, KdlParseError> ToUInt64(KdlValueRef value)
	{
		switch (value.mValue)
		{
		case .Integer(let v, ?):
			if (v < 0)
				return .Err(value.MakeError(scope $"{v} is outside the range 0 to {uint64.MaxValue}"));
			return (uint64)v;
		case .BigInteger(let text):
			if (ParseUnsigned(text) case .Ok(let parsed))
				return parsed;
			return .Err(value.MakeError(scope $"{text} is outside the range 0 to {uint64.MaxValue}"));
		default:
			return .Err(WrongType(value, "integer"));
		}
	}

	/// A non-negative integer lexeme (any radix, underscores) as a uint64, if it fits.
	static Result<uint64> ParseUnsigned(StringView text)
	{
		StringView digits = text;
		if (digits.StartsWith('+'))
			digits = digits.Substring(1);
		if (digits.StartsWith('-'))
			return .Err;
		uint64 radix = digits.StartsWith("0x") ? 16 : digits.StartsWith("0o") ? 8 : digits.StartsWith("0b") ? 2 : 10;
		if (radix != 10)
			digits = digits.Substring(2);
		uint64 result = 0;
		for (let c in digits)
		{
			if (c == '_')
				continue;
			uint64 digit = Hex.DigitValue(c);
			if (result > (uint64.MaxValue - digit) / radix)
				return .Err;
			result = result * radix + digit;
		}
		return result;
	}

	/// @brief The value as a double (an integer converts).
	/// @param value The value.
	/// @return The number, or the error.
	public static Result<double, KdlParseError> ToDouble(KdlValueRef value)
	{
		if (value.mValue.TryGetDouble(let number))
			return number;
		return .Err(WrongType(value, "number"));
	}

	/// @brief The value as a boolean.
	/// @param value The value.
	/// @return The boolean, or the error.
	public static Result<bool, KdlParseError> ToBool(KdlValueRef value)
	{
		if (value.mValue case .Bool(let v))
			return v;
		return .Err(WrongType(value, "boolean"));
	}

	/// @brief The value as a string, borrowed from the document.
	/// @param value The value.
	/// @return The string, or the error.
	public static Result<StringView, KdlParseError> ToString(KdlValueRef value)
	{
		if (value.mValue case .String(let s))
			return s;
		return .Err(WrongType(value, "string"));
	}

	/// @brief The error for a string that names no enum case.
	/// @param value The value.
	/// @param text The string.
	/// @param cases The accepted names, "a, b, c".
	/// @return The error.
	public static KdlParseError UnknownCase(KdlValueRef value, StringView text, StringView cases)
	{
		return value.MakeError(scope $"`{text}` is not one of {cases}");
	}

	/// @brief A uint64 as a KDL value: an integer, or above int64.MaxValue a big integer written in `text`.
	/// @param v The value.
	/// @param text Storage for the big integer's digits (copied into the document when written).
	/// @return The value.
	public static KdlValue Unsigned(uint64 v, String text)
	{
		if (v <= (uint64)int64.MaxValue)
			return .Integer((int64)v, default);
		v.ToString(text);
		return .BigInteger(text);
	}

	// Child nodes

	/// @brief The child node `name` (the last one), added when there is none.
	/// @param node The node.
	/// @param name The child's name.
	/// @return The child.
	public static KdlNode ChildNode(KdlNode node, StringView name)
	{
		KdlNode found = default;
		for (let child in node.Children)
		{
			if (child.Name == name)
				found = child;
		}
		return found.IsValid ? found : node.AddChild(name);
	}

	/// @brief Remove every child node named `name`.
	/// @param node The node.
	/// @param name The name.
	public static void RemoveChild(KdlNode node, StringView name)
	{
		for (let child in node.Children)
		{
			if (child.Name == name)
				child.Remove();
		}
	}

	// [KdlChildren] (lists are written through KdlArgumentCursor, KdlChildCursor and KdlFreeChildCursor)

	/// @brief Whether another field of the type claims child nodes named `name`.
	/// @param name The name.
	/// @param claimed The names other fields use.
	/// @return Whether it is claimed.
	public static bool IsClaimed(StringView name, Span<StringView> claimed)
	{
		for (let other in claimed)
		{
			if (other == name)
				return true;
		}
		return false;
	}

	/// @brief The error for a child node no [KdlObject] type of a [KdlChildren] list is named after.
	/// @param child The child.
	/// @param expected The accepted names, "a, b, c".
	/// @return The error.
	public static KdlParseError UnknownChild(KdlNode child, StringView expected)
	{
		return MakeError(child, -1, default, scope $"unknown node: expected one of {expected}", .InvalidValue);
	}

	// Aliases

	/// @brief Rename a property found under an older name (writing moves it to the current one).
	/// @param node The node.
	/// @param key The current key.
	/// @param alias An older key.
	public static void RenamePropertyAlias(KdlNode node, StringView key, StringView alias)
	{
		if (node.IsDocumentRoot)
		{
			RenameChildAlias(node, key, alias);
			return;
		}
		if (node.PropertyIndex(key) >= 0)
			return;
		int position = node.PropertyIndex(alias);
		if (position >= 0)
			node.RenameProperty(position, key);
	}

	/// @brief Rename child nodes found under an older name.
	/// @param node The node.
	/// @param name The current name.
	/// @param alias An older name.
	public static void RenameChildAlias(KdlNode node, StringView name, StringView alias)
	{
		if (CountChildren(node, name) > 0)
			return;
		for (var child in node.Children)
		{
			if (child.Name == alias)
				child.Name = name;
		}
	}
}

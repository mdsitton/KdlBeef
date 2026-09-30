using System;
using System.Collections;
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
		Child
	}

	KdlNode mNode;
	Target mTarget;
	StringView mName;
	int mIndex;

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
		case .Argument: Write(.Null, false, default);
		case .Child: KdlBind.RemoveChild(mNode, mName);
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

	/// @brief The argument at `index`, which exists (for lists).
	/// @param node The node.
	/// @param index The argument's position.
	/// @return The value.
	public static KdlValueRef ArgumentAt(KdlNode node, int index)
	{
		return Ref(node, node.ArgumentIndex(index), default);
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

	/// @brief Remove the entry nodes of a dictionary's node whose keys the dictionary no longer has, and
	/// all but the last of duplicate keys (the one reading used).
	/// @param node The dictionary's node.
	/// @param dictionary The dictionary being written.
	public static void RemoveMissingKeys<TValue>(KdlNode node, Dictionary<String, TValue> dictionary)
	{
		let seen = scope HashSet<StringView>();
		var child = node.LastChild;
		while (child.IsValid)
		{
			let previous = child.PreviousSibling;
			if (!dictionary.ContainsKeyAlt(child.Name) || !seen.Add(child.Name))
				child.Remove();
			child = previous;
		}
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
			uint64 digit = KdlChar.HexDigitValue(c);
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

	/// @brief The child node named `name` at `index` among those (a list item), added after the last of
	/// them (or at the end) when there are fewer.
	/// @param node The node.
	/// @param name The name.
	/// @param index The position among the children named `name`.
	/// @return The child.
	public static KdlNode NthChild(KdlNode node, StringView name, int index)
	{
		int seen = 0;
		KdlNode last = default;
		for (let child in node.Children)
		{
			if (child.Name != name)
				continue;
			if (seen++ == index)
				return child;
			last = child;
		}
		return last.IsValid ? last.InsertAfter(name) : node.AddChild(name);
	}

	/// @brief Remove the children named `name` after the first `count` (list items no longer there).
	/// @param node The node.
	/// @param name The name.
	/// @param count How many to keep.
	public static void TrimChildren(KdlNode node, StringView name, int count)
	{
		int seen = 0;
		for (let child in node.Children)
		{
			if (child.Name == name && seen++ >= count)
				child.Remove();
		}
	}

	/// @brief Remove the arguments after the first `count`.
	/// @param node The node.
	/// @param count How many to keep.
	public static void TrimArguments(KdlNode node, int count)
	{
		while (node.ArgumentCount > count)
			node.RemoveArgument(node.ArgumentCount - 1);
	}

	// [KdlChildren]

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

	/// @brief The node for item `index` of a [KdlChildren] list: the index-th unclaimed child if it has
	/// the item's name, else a new child inserted there (or at the end).
	/// @param node The node.
	/// @param index The item's position.
	/// @param name The item's node name.
	/// @param claimed The names other fields use.
	/// @return The child to write the item into.
	public static KdlNode FreeChild(KdlNode node, int index, StringView name, Span<StringView> claimed)
	{
		int seen = 0;
		for (let child in node.Children)
		{
			if (IsClaimed(child.Name, claimed))
				continue;
			if (seen++ == index)
				return child.Name == name ? child : child.InsertBefore(name);
		}
		return node.AddChild(name);
	}

	/// @brief Remove the unclaimed children after the first `count` (items no longer in the list).
	/// @param node The node.
	/// @param count How many to keep.
	/// @param claimed The names other fields use.
	public static void TrimFreeChildren(KdlNode node, int count, Span<StringView> claimed)
	{
		int seen = 0;
		for (let child in node.Children)
		{
			if (!IsClaimed(child.Name, claimed) && seen++ >= count)
				child.Remove();
		}
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

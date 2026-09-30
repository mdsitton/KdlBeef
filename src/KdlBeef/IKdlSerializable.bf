using System;

namespace KdlBeef;

/// @brief A type that reads itself from and writes itself to a KdlNode. [KdlObject] generates it; a type
/// can also implement it by hand.
public interface IKdlSerializable
{
	/// @brief The node name of this object's type (for list items and [KdlChildren]).
	StringView KdlNodeName { get; }

	/// @brief Fill this object's fields from `node` (the document's Root for a whole document).
	/// @param node The node to read.
	/// @param allocator Where the objects the read creates (Strings, nested objects, Lists) come from,
	/// for example a `scope BumpAllocator`; null for the heap, and then this object owns them.
	/// @return .Ok, or the first error, located in the source when the document has positions.
	Result<void, KdlParseError> KdlRead(KdlNode node, ITypedAllocator allocator = null) mut;

	/// @brief Write this object's fields into `node`, updating what is there (so a document read with
	/// PreserveStyle keeps its formatting).
	/// @param node The node to write (the document's Root for a whole document).
	/// @return .Ok, or an error.
	Result<void, KdlParseError> KdlWrite(KdlNode node);
}

/// @brief Reads and writes one type `T` held in a single KDL value, with its annotation, for
/// [KdlObject] fields: types the serializer does not know, or a custom form such as `(px)12` for a
/// Length. Register it for every field of type T with [KdlConverter(typeof(T))] on the converter, or
/// use it for one field with [KdlUseConverter(typeof(Converter))].
///
/// ```
/// [KdlConverter(typeof(Length))]
/// struct LengthKdl : IKdlConverter<Length>
/// {
/// 	public static Result<void, KdlParseError> Read(KdlValueRef value, ref Length target)
/// 	{
/// 		if (!value.mValue.TryGetDouble(let amount))
/// 			return .Err(value.MakeError("expected a length such as (px)12"));
/// 		target = .(amount, value.mHasAnnotation ? value.mAnnotation : "px");
/// 		return .Ok;
/// 	}
///
/// 	public static void Write(Length value, KdlValueWriter writer)
/// 	{
/// 		writer.Set(.Float(value.Amount, default), value.Unit);
/// 	}
/// }
/// ```
public interface IKdlConverter<T>
{
	/// @brief Read `value` into `target`.
	/// @param value The value, its annotation and where it is (for errors).
	/// @param target The field or new list item to fill.
	/// @return .Ok, or an error (usually from value.MakeError).
	static Result<void, KdlParseError> Read(KdlValueRef value, ref T target);

	/// @brief Write `value` through `writer`: one Set.
	/// @param value The value to write.
	/// @param writer Where it goes.
	static void Write(T value, KdlValueWriter writer);
}

/// @brief Registers the converter it is placed on (an IKdlConverter<T>) for every [KdlObject] field and
/// list item of type `T`, in every project that can see the converter. At most one converter per type.
[AttributeUsage(.Struct | .Class)]
public struct KdlConverterAttribute : Attribute
{
	/// @brief The type the converter handles.
	public Type mTarget;

	/// @brief Register the converter for `target`.
	/// @param target The type the converter handles.
	public this(Type target)
	{
		mTarget = target;
	}
}

/// @brief Reads and writes one field with the given converter (an IKdlConverter<T> for the field's type,
/// or its item type for a List), ahead of any registered converter or built-in handling.
[AttributeUsage(.Field)]
public struct KdlUseConverterAttribute : Attribute
{
	/// @brief The converter type.
	public Type mConverter;

	/// @brief Use `converter` for this field.
	/// @param converter The converter type.
	public this(Type converter)
	{
		mConverter = converter;
	}
}

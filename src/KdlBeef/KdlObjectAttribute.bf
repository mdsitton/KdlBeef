using System;

namespace KdlBeef;

/// @brief Generates KDL reading and writing for a class or struct at compile time.
///
/// ```
/// [KdlObject]
/// class Button : Widget
/// {
/// 	[KdlArgument(0)] public String Label ~ delete _;       // button "Save"
/// 	public String OnClick ~ delete _;                      // on-click=save
/// 	public int32 Width = 80;                               // width=80
/// 	public Style Style ~ delete _;                         // a child node: style color=red
/// }
///
/// [KdlObject]
/// class Panel : Widget
/// {
/// 	[KdlChildren] public List<Widget> Items ~ DeleteContainerAndItems!(_);   // button …, panel …
/// }
/// ```
///
/// The type gets IKdlSerializable. Its public instance fields map to a node by role:
/// - scalars (bool, integers, float, double, String, enums, converter types; see IKdlConverter) are
///   properties, or with [KdlArgument(n)] the n-th argument, or with [KdlChild] a child node holding
///   the value as its argument (`name "value"`);
/// - [KdlArguments] List<scalar>: the arguments from the first one no [KdlArgument] takes on;
/// - another [KdlObject] type: a child node named after the field;
/// - List<scalar>: a child node named after the field, holding the items as its arguments;
/// - List<[KdlObject] type>: repeated child nodes named after the element type (`item` for `Item`);
/// - Dictionary<K, T> of the above (K a String, integer or enum): a child node named after the field
///   with one child per entry, named by its key: `env { PATH "/bin" }`, `servers { main host=h port=1 }`;
/// - containers nest to any depth: a List of Lists or Dictionaries is `-` children, one per item
///   (`matrix { - 1 2; - 3 }`), a Dictionary's container value is its entry's content;
/// - [KdlChildren] List<T>: every child node not claimed by another field, each read as the
///   [KdlObject] type assignable to T whose node name it has (found at compile time).
///
/// Names are kebab-case by default (`OnClick` is `on-click`, `TextBox` is `text-box`; see Naming,
/// KdlName, KdlAlias); enums are their case names in the same naming. Any other field type stops the
/// build with an error naming the field; [KdlIgnore] leaves a field out.
///
/// Reading fills an existing object: a missing property, argument or child leaves its field as it was
/// (unless [KdlRequired]); `#null` counts as missing. A String, object or List field that is null when
/// read gets a new instance, which the object then owns (declare such fields with `~ delete _` or a
/// container delete). Writing updates the node in place: values set, children written into the
/// existing ones, so a document read with PreserveStyle keeps its formatting and comments.
[AttributeUsage(.Class | .Struct)]
public struct KdlObjectAttribute : Attribute, IComptimeTypeApply
{
	/// @brief How field, type and enum case names become KDL names ([KdlName] on a field overrides).
	public KdlNaming Naming;

	/// @brief The type's node name, where one is needed (list items, [KdlChildren], a document's root
	/// node). Unset, the type's name through Naming.
	public String Name;

	/// @brief Checks the type's fields and emits IKdlSerializable into it.
	/// @param type The type carrying the attribute.
	[Comptime]
	public void ApplyToType(Type type)
	{
		KdlSerializerCodeGen.Emit(type, Naming, (Name != null) ? Name : "");
	}
}

/// @brief How [KdlObject] turns declared names into KDL names. Words split at case changes, keeping
/// acronyms together: `HTTPPort` is `http-port`.
public enum KdlNaming
{
	/// @brief `pool-size`, the usual KDL style (the default).
	KebabCase,
	/// @brief The name as written: `PoolSize`.
	AsDeclared,
	/// @brief `pool_size`.
	SnakeCase,
	/// @brief `poolSize`.
	CamelCase
}

/// @brief Serializes a field under `name` instead of its own name.
[AttributeUsage(.Field)]
public struct KdlNameAttribute : Attribute
{
	/// @brief The KDL name.
	public String mName;

	/// @brief Use `name` for the field.
	/// @param name The property key or child node name.
	public this(String name)
	{
		mName = name;
	}
}

/// @brief An older name, so documents written before a rename still read. Repeatable. Reading tries the
/// current name first, then each alias; writing uses the current name, and renames a property or child
/// found under an alias in place.
[AttributeUsage(.Field)]
public struct KdlAliasAttribute : Attribute
{
	/// @brief The older name.
	public String mName;

	/// @brief Also accept `name`.
	/// @param name The older property key or child node name.
	public this(String name)
	{
		mName = name;
	}
}

/// @brief Leaves a field out of the generated reading and writing.
[AttributeUsage(.Field)]
public struct KdlIgnoreAttribute : Attribute
{
}

/// @brief Makes reading fail (located at the node) when the field's property, argument or child is
/// absent.
[AttributeUsage(.Field)]
public struct KdlRequiredAttribute : Attribute
{
}

/// @brief Maps a scalar field to the node's argument at `index` (0 is the first).
[AttributeUsage(.Field)]
public struct KdlArgumentAttribute : Attribute
{
	/// @brief The argument's position among the node's arguments.
	public int mIndex;

	/// @brief Map the field to argument `index`.
	/// @param index The argument's position.
	public this(int index)
	{
		mIndex = index;
	}
}

/// @brief Maps a List of scalars to the node's arguments, from the first one no [KdlArgument] field
/// takes to the last.
[AttributeUsage(.Field)]
public struct KdlArgumentsAttribute : Attribute
{
}

/// @brief Maps a scalar field to a child node holding the value as its argument: `timeout 30`.
[AttributeUsage(.Field)]
public struct KdlChildAttribute : Attribute
{
}

/// @brief Maps a List<T> field to every child node that no other field claims; each child is read as the
/// [KdlObject] type assignable to T whose node name it has.
[AttributeUsage(.Field)]
public struct KdlChildrenAttribute : Attribute
{
}

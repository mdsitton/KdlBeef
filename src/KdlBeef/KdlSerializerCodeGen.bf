using System;
using System.Collections;
using System.Reflection;

namespace KdlBeef;

/// @brief The compile-time half of [KdlObject]: writes the Beef source of a type's KdlNodeName, KdlRead
/// and KdlWrite and hands it to the compiler. Nothing here runs in the finished program; the emitted
/// code calls KdlBind for the per-value work. (TomlBeef's TomlSerializerCodeGen, with KDL's roles.)
///
/// Emitted names are fully qualified (the user's file needs no `using KdlBeef`), fields are reached
/// through `this.` and locals start with `_`, so neither clashes with the type's own members. Enums
/// are matched with generated switches over their case names, so they need no reflection at run time.
public static class KdlSerializerCodeGen
{
	enum Kind
	{
		Unsupported,
		Bool,
		Integer,
		Float,
		String,
		Enum,
		Object,
		List,
		/// Dictionary<String, T>
		Dictionary,
		/// An IKdlConverter<T>: from [KdlUseConverter] on the field, or registered with [KdlConverter]
		Converter
	}

	/// Where a field lives in a node.
	enum Role
	{
		/// A scalar: a property (for the document root, a `name value` child).
		Property,
		/// A scalar: the argument at `index`.
		Argument,
		/// A scalar: a `name value` child ([KdlChild]).
		ChildValue,
		/// A List of scalars: the arguments from `index` on ([KdlArguments]).
		Arguments,
		/// A List of scalars: a child node holding them as arguments.
		ChildArguments,
		/// A [KdlObject]: a child node.
		ChildObject,
		/// A List of [KdlObject]s: child nodes named after the element type.
		ChildObjects,
		/// A List<T>: every unclaimed child, read as the [KdlObject] type named after it ([KdlChildren]).
		Children,
		/// A Dictionary, or a List of Lists or Dictionaries: a child node with the container as its content
		/// (EmitReadContent).
		ChildContent
	}

	/// @brief Emit IKdlSerializable into `type`.
	/// @param type A class or struct carrying [KdlObject].
	/// @param naming How names become KDL names.
	/// @param nodeName The type's node name (KdlObjectAttribute.Name), or empty for its name.
	[Comptime]
	public static void Emit(Type type, KdlNaming naming, StringView nodeName)
	{
		let read = scope String();
		let write = scope String();
		let ownerName = type.GetFullName(.. scope .());

		// A [KdlObject] base already has the methods: hide them, and read and write its fields first
		bool baseIsObject = type.BaseType != null && type.BaseType != typeof(Object) && type.BaseType.HasCustomAttribute<KdlObjectAttribute>();
		StringView hide = baseIsObject ? "new " : "";

		let name = scope String();
		if (!nodeName.IsEmpty)
			name.Append(nodeName);
		else
			ApplyNaming(type.GetName(.. scope .()), naming, name);
		read.AppendF("public {}StringView KdlNodeName => {};\n", hide, AppendLiteral(.. scope .(), name));
		read.AppendF("public {}Result<void, KdlBeef.KdlParseError> KdlRead(KdlBeef.KdlNode _node, System.ITypedAllocator _alloc = null){}\n{{\n", hide, type.IsValueType ? " mut" : "");
		write.AppendF("public {}Result<void, KdlBeef.KdlParseError> KdlWrite(KdlBeef.KdlNode _node)\n{{\n", hide);
		if (baseIsObject)
		{
			read.Append("\tTry!(base.KdlRead(_node, _alloc));\n");
			write.Append("\tTry!(base.KdlWrite(_node));\n");
		}

		// 1. The chain's shared places (argument positions, claimed child names), checked for conflicts
		let claimed = scope String();
		ScanChain(type, naming, ownerName, let nextArgument, claimed, let claimedCount);
		// The claimed names, as the [KdlChildren] code sees them: for a class through a virtual property,
		// so that a base's list also leaves alone the children a subclass's fields claim
		if (claimedCount > 0)
			read.Insert(0, scope $"static StringView[{claimedCount}] sKdlClaimed = .({claimed});\n");
		// Likewise the first argument a [KdlArguments] list takes: a subclass's [KdlArgument] fields move
		// it, including for a list its base declares (whose code was generated before the subclass)
		StringView claimedExpr;
		let argumentsStart = scope String();
		if (type.IsValueType)
		{
			claimedExpr = (claimedCount > 0) ? "sKdlClaimed" : "default";
			argumentsStart.AppendF("{}", nextArgument);
		}
		else
		{
			claimedExpr = "this.KdlClaimedChildNames";
			StringView overriding = baseIsObject ? "override" : "virtual";
			read.Insert(0, scope $"protected {overriding} Span<StringView> KdlClaimedChildNames => {(claimedCount > 0) ? "sKdlClaimed" : "default"};\n");
			read.Insert(0, scope $"protected {overriding} int KdlArgumentsStart => {nextArgument};\n");
			argumentsStart.Append("this.KdlArgumentsStart");
		}

		// 2. Every field's plan (its kinds and role), checked before any code is written
		let plans = scope List<FieldPlan>();
		defer { ClearAndDeleteItems!(plans); }
		for (let field in type.GetFields())
		{
			if (IsSerialized(type, field))
				plans.Add(PlanField(field, naming, ownerName, nextArgument));
		}

		// 3. The code, from the plans
		for (let plan in plans)
		{
			StringView fieldName = plan.mField.Name;
			switch (plan.mRole)
			{
			case .Property, .Argument, .ChildValue:
				EmitReadScalar(read, fieldName, plan.mKey, plan.mAliases, plan.mRequired, plan.mRole, plan.mIndex, plan.mType, plan.mKind, plan.mConverter, naming);
				EmitWriteScalar(write, fieldName, plan.mKey, plan.mAliases, plan.mRole, plan.mIndex, plan.mType, plan.mKind, plan.mConverter, naming);
			case .Arguments, .ChildArguments:
				EmitReadScalarList(read, fieldName, plan.mKey, plan.mAliases, plan.mRequired, plan.mRole, argumentsStart, plan.mType, plan.mElement, plan.mElementKind, plan.mElementConverter, naming);
				EmitWriteScalarList(write, fieldName, plan.mKey, plan.mAliases, plan.mRole, argumentsStart, plan.mElement, plan.mElementKind, plan.mElementConverter, naming);
			case .ChildObject:
				EmitReadObject(read, fieldName, plan.mKey, plan.mAliases, plan.mRequired, plan.mType);
				EmitWriteObject(write, fieldName, plan.mKey, plan.mAliases, plan.mType);
			case .ChildObjects:
				let rawName = NodeName(plan.mElement, .. scope .());
				let elementName = AppendLiteral(.. scope .(), rawName);
				EmitReadObjects(read, fieldName, rawName, elementName, plan.mRequired, plan.mType, plan.mElement);
				EmitWriteObjects(write, fieldName, elementName, plan.mElement);
			case .Children:
				EmitReadChildren(read, ownerName, fieldName, plan.mType, plan.mElement, claimedExpr);
				EmitWriteChildren(write, fieldName, plan.mElement, claimedExpr);
			case .ChildContent:
				EmitReadContentField(read, fieldName, plan.mKey, plan.mAliases, plan.mRequired, plan.mType, plan.mUseConverter, naming);
				EmitWriteContentField(write, fieldName, plan.mKey, plan.mAliases, plan.mType, plan.mUseConverter, naming);
			}
		}

		read.Append("\treturn .Ok;\n}\n");
		write.Append("\treturn .Ok;\n}\n");

		Compiler.EmitAddInterface(type, typeof(IKdlSerializable));
		Compiler.EmitTypeBody(type, read);
		Compiler.EmitTypeBody(type, write);
	}

	/// How one field maps: what Emit writes code from. For a List field, mElement* describe its items.
	class FieldPlan
	{
		public FieldInfo mField;
		/// The KDL name and its aliases, as Beef string literals.
		public String mKey = new .() ~ delete _;
		public List<String> mAliases = new .() ~ DeleteContainerAndItems!(_);
		public bool mRequired;
		public Role mRole;
		/// The argument index ([KdlArgument]), or the first one ([KdlArguments]).
		public int mIndex;
		public Type mType;
		public Kind mKind;
		public Type mConverter;
		/// [KdlUseConverter]'s converter, for the scalars inside a container field (null: none).
		public Type mUseConverter;
		public Type mElement;
		public Kind mElementKind;
		public Type mElementConverter;

		public this()
		{
		}
	}

	/// Classifies a field of the type being generated and picks its role, stopping the build (naming the
	/// field) for a type or role attribute that cannot work.
	[Comptime]
	static FieldPlan PlanField(FieldInfo field, KdlNaming naming, StringView ownerName, int nextArgument)
	{
		let plan = new FieldPlan();
		plan.mField = field;
		if (field.GetCustomAttribute<KdlNameAttribute>() case .Ok(let named))
			AppendLiteral(plan.mKey, named.mName);
		else
			AppendLiteral(plan.mKey, ApplyNaming(field.Name, naming, .. scope .()));
		for (let alias in field.GetCustomAttributes<KdlAliasAttribute>())
			plan.mAliases.Add(AppendLiteral(.. new .(), alias.mName));
		plan.mRequired = field.HasCustomAttribute<KdlRequiredAttribute>();

		let fieldType = field.FieldType;
		plan.mType = fieldType;
		Type converter = null;
		Kind kind;
		// [KdlUseConverter] converts the field, or in a container the scalars at its leaves
		Type useConverter = null;
		if (field.GetCustomAttribute<KdlUseConverterAttribute>() case .Ok(let use))
			useConverter = use.mConverter;
		plan.mUseConverter = useConverter;
		kind = LeafKind(fieldType, useConverter, out converter);
		plan.mKind = kind;
		plan.mConverter = converter;
		Type element = null;
		var elementKind = Kind.Unsupported;
		Type elementConverter = null;
		if (kind == .List)
		{
			element = ListElement(fieldType);
			elementKind = LeafKind(element, useConverter, out elementConverter);
		}
		plan.mElement = element;
		plan.mElementKind = elementKind;
		plan.mElementConverter = elementConverter;

		bool scalar = kind != .Object && kind != .List && kind != .Dictionary && kind != .Unsupported;
		bool scalarList = kind == .List && IsScalar(elementKind);
		if (field.HasCustomAttribute<KdlChildrenAttribute>())
		{
			if (kind != .List)
				Fail(ownerName, field.Name, "[KdlChildren] needs a List<T> field");
			plan.mRole = .Children;
		}
		else if (field.HasCustomAttribute<KdlArgumentsAttribute>())
		{
			if (!scalarList)
				Fail(ownerName, field.Name, "[KdlArguments] needs a List of scalars (bool, integers, floats, String, enums, converter types)");
			plan.mRole = .Arguments;
			plan.mIndex = nextArgument;
		}
		else if (field.GetCustomAttribute<KdlArgumentAttribute>() case .Ok(let argument))
		{
			if (!scalar)
				Fail(ownerName, field.Name, "[KdlArgument] needs a scalar field (bool, integers, floats, String, enums, converter types)");
			plan.mRole = .Argument;
			plan.mIndex = argument.mIndex;
		}
		else if (field.HasCustomAttribute<KdlChildAttribute>())
		{
			if (!scalar)
				Fail(ownerName, field.Name, "[KdlChild] needs a scalar field; [KdlObject] and List fields are child nodes already");
			plan.mRole = .ChildValue;
		}
		else if (scalar)
			plan.mRole = .Property;
		else if (kind == .Object)
			plan.mRole = .ChildObject;
		else if (scalarList)
			plan.mRole = .ChildArguments;
		else if (kind == .List && elementKind == .Object)
			plan.mRole = .ChildObjects;
		else if ((kind == .List || kind == .Dictionary) && IsContent(fieldType, useConverter))
			plan.mRole = .ChildContent;
		else
		{
			let typeName = fieldType.GetFullName(.. scope .());
			Fail(ownerName, field.Name, scope $"KDL serialization does not support fields of type {typeName}. Supported: bool, integers, float, double, String, enums, [KdlObject] types, and Lists and Dictionaries of those, nested to any depth, with dictionary keys of String, integer or enum types; also types with a converter ([KdlConverter] registration or [KdlUseConverter] on the field). Mark the field [KdlIgnore] to leave it out.");
			plan.mRole = .Property;
		}
		return plan;
	}

	/// Over the whole [KdlObject] chain from `type` (a base's fields are read by its own KdlRead, called
	/// first, but they share the node): the first argument no [KdlArgument] field takes, for
	/// [KdlArguments]; and the child names the fields claim (Beef literals, comma-separated, in
	/// `claimed`), which a [KdlChildren] list anywhere in the chain leaves alone. Stops the build for
	/// mappings that would read the same KDL twice: a negative or repeated argument index, a second
	/// [KdlArguments] or [KdlChildren], several role attributes on a field, and two properties or two
	/// child nodes with one name.
	[Comptime]
	static void ScanChain(Type type, KdlNaming naming, StringView ownerName, out int nextArgument, String claimed, out int claimedCount)
	{
		nextArgument = 0;
		claimedCount = 0;
		int childrenLists = 0;
		String argumentsField = null;
		// The field that maps each argument index, property key and child name ("Type.Field")
		let arguments = scope Dictionary<int, String>();
		let properties = scope Dictionary<String, String>();
		let children = scope Dictionary<String, String>();
		defer
		{
			delete argumentsField;
			for (let entry in arguments)
				delete entry.value;
			for (let entry in properties)
			{
				delete entry.key;
				delete entry.value;
			}
			for (let entry in children)
			{
				delete entry.key;
				delete entry.value;
			}
		}
		for (Type level = type; level != null && level.HasCustomAttribute<KdlObjectAttribute>(); level = level.IsValueType ? null : level.BaseType)
		{
			var levelNaming = naming;
			if (level != type && level.GetCustomAttribute<KdlObjectAttribute>() case .Ok(let attribute))
				levelNaming = attribute.Naming;
			for (let field in level.GetFields())
			{
				if (!IsSerialized(level, field))
					continue;
				let fieldPath = scope $"{level.GetFullName(.. scope .())}.{field.Name}";
				// One role attribute per field
				int roles = (field.HasCustomAttribute<KdlArgumentAttribute>() ? 1 : 0) + (field.HasCustomAttribute<KdlArgumentsAttribute>() ? 1 : 0) +
					(field.HasCustomAttribute<KdlChildAttribute>() ? 1 : 0) + (field.HasCustomAttribute<KdlChildrenAttribute>() ? 1 : 0);
				if (roles > 1)
					FailType(ownerName, scope $"{fieldPath} has more than one of [KdlArgument], [KdlArguments], [KdlChild] and [KdlChildren]: a field has one place in a node");

				if (field.GetCustomAttribute<KdlArgumentAttribute>() case .Ok(let argument))
				{
					if (argument.mIndex < 0)
						FailType(ownerName, scope $"{fieldPath}: [KdlArgument({argument.mIndex})] needs an index of 0 or more");
					if (arguments.TryGetValue(argument.mIndex, let other))
						FailType(ownerName, scope $"argument {argument.mIndex} is mapped by both {other} and {fieldPath}");
					arguments[argument.mIndex] = new .(fieldPath);
					nextArgument = Math.Max(nextArgument, argument.mIndex + 1);
				}
				else if (field.HasCustomAttribute<KdlChildrenAttribute>())
				{
					if (++childrenLists > 1)
						FailType(ownerName, scope $"{fieldPath}: only one [KdlChildren] list is allowed in a type and its [KdlObject] bases (both would read the same child nodes)");
				}
				else if (field.HasCustomAttribute<KdlArgumentsAttribute>())
				{
					if (argumentsField != null)
						FailType(ownerName, scope $"the arguments are mapped by both {argumentsField} and {fieldPath} ([KdlArguments])");
					argumentsField = new .(fieldPath);
				}
				else
				{
					let names = scope List<String>();
					defer { ClearAndDeleteItems!(names); }
					ClaimedNames(field, levelNaming, names);
					// Properties and child nodes are separate names in a node
					let used = IsPropertyField(field) ? properties : children;
					for (let claim in names)
					{
						if (used.TryGetValue(claim, let other))
							FailType(ownerName, scope $"{(used == properties) ? "the property" : "the child node"} `{claim}` is mapped by both {other} and {fieldPath} (the name comes from [KdlName] or the field's name, or for a List of objects from the item type's node name)");
						used[new .(claim)] = new .(fieldPath);
						if (claimedCount++ > 0)
							claimed.Append(", ");
						AppendLiteral(claimed, claim);
					}
				}
			}
		}
	}

	[Comptime]
	static bool IsSerialized(Type type, FieldInfo field)
	{
		return field.DeclaringType == type && !field.IsStatic && !field.IsConst && field.IsPublic && !field.HasCustomAttribute<KdlIgnoreAttribute>();
	}

	[Comptime]
	static void Fail(StringView ownerName, StringView fieldName, StringView message)
	{
		Runtime.FatalError(scope $"[KdlObject] {ownerName}.{fieldName}: {message}");
	}

	/// A mapping error about the type as a whole: `message` names the fields (with their declaring types).
	[Comptime]
	static void FailType(StringView ownerName, StringView message)
	{
		Runtime.FatalError(scope $"[KdlObject] {ownerName}: {message}");
	}

	/// Whether a field without a role attribute is a property: a scalar (a converter's too), not a child
	/// node ([KdlChild], objects, lists, dictionaries).
	[Comptime]
	static bool IsPropertyField(FieldInfo field)
	{
		if (field.HasCustomAttribute<KdlChildAttribute>())
			return false;
		let fieldType = field.FieldType;
		if (field.HasCustomAttribute<KdlUseConverterAttribute>())
			return ListElement(fieldType) == null && DictionaryValue(fieldType) == null;
		return IsScalar(Classify(fieldType, ?));
	}

	/// The child names (and property keys, which are children at the document root) a field uses.
	[Comptime]
	static void ClaimedNames(FieldInfo field, KdlNaming naming, List<String> names)
	{
		let fieldType = field.FieldType;
		if (field.GetCustomAttribute<KdlNameAttribute>() case .Ok(let named))
			names.Add(new .(named.mName));
		else
			names.Add(ApplyNaming(field.Name, naming, .. new .()));
		for (let alias in field.GetCustomAttributes<KdlAliasAttribute>())
			names.Add(new .(alias.mName));
		// A List of objects is items named after the element type
		let element = ListElement(fieldType);
		if (element != null && element.HasCustomAttribute<KdlObjectAttribute>() && FindRegisteredConverter(element) == null)
		{
			ClearAndDeleteItems!(names);
			names.Add(NodeName(element, .. new .()));
		}
	}

	/// How a field or list item of `type` is handled.
	[Comptime]
	static Kind Classify(Type type, out Type converter)
	{
		converter = null;
		if (type == typeof(bool))
			return .Bool;
		if (type == typeof(char8) || type == typeof(char16) || type == typeof(char32))
			return .Unsupported;
		if (type.IsInteger)
			return .Integer;
		if (type == typeof(float) || type == typeof(double))
			return .Float;
		if (type == typeof(String))
			return .String;
		converter = FindRegisteredConverter(type);
		if (converter != null)
			return .Converter;
		// Simple enums only: cases with payloads have no single name to write
		if (type.IsEnum && !type.IsUnion)
			return .Enum;
		if (type.HasCustomAttribute<KdlObjectAttribute>())
			return .Object;
		if (ListElement(type) != null)
			return .List;
		if (DictionaryValue(type) != null)
			return .Dictionary;
		return .Unsupported;
	}

	/// Whether values of `kind` are single KDL values.
	[Comptime]
	static bool IsScalar(Kind kind)
	{
		return kind != .Object && kind != .List && kind != .Dictionary && kind != .Unsupported;
	}

	/// The V of a Dictionary<K, V>, or null. (Which keys work is IsKeyType's question.)
	[Comptime]
	static Type DictionaryValue(Type type)
	{
		if (let specialized = type as SpecializedGenericType)
		{
			if (specialized.UnspecializedType == typeof(Dictionary<,>))
				return specialized.GetGenericArg(1);
		}
		return null;
	}

	/// The K of a Dictionary<K, V>, or null.
	[Comptime]
	static Type DictionaryKey(Type type)
	{
		if (let specialized = type as SpecializedGenericType)
		{
			if (specialized.UnspecializedType == typeof(Dictionary<,>))
				return specialized.GetGenericArg(0);
		}
		return null;
	}

	/// The converter registered with [KdlConverter(typeof(target))] that the type being compiled can see,
	/// or null. Two such registrations stop the build.
	[Comptime]
	static Type FindRegisteredConverter(Type target)
	{
		Type found = null;
		for (let declaration in Type.TypeDeclarations)
		{
			if (!(declaration.DeclaredInCurrent || declaration.DeclaredInDependency || declaration.AlwaysVisible))
				continue;
			if (!(declaration.GetCustomAttribute<KdlConverterAttribute>() case .Ok(let registration)) || registration.mTarget != target)
				continue;
			let converter = declaration.ResolvedType;
			if (found != null && found != converter)
				Runtime.FatalError(scope $"[KdlConverter] Both {found.GetFullName(.. scope .())} and {converter.GetFullName(.. scope .())} are registered for {target.GetFullName(.. scope .())}. Keep one, or pick one per field with [KdlUseConverter].");
			found = converter;
		}
		return found;
	}

	/// The [KdlObject] types a [KdlChildren] List<T> can hold: T itself for a struct, else every visible,
	/// concrete class deriving from (or implementing) T.
	[Comptime]
	static void ChildTypes(Type element, List<Type> types)
	{
		if (element.IsValueType)
		{
			if (element.HasCustomAttribute<KdlObjectAttribute>())
				types.Add(element);
			return;
		}
		for (let declaration in Type.TypeDeclarations)
		{
			if (!(declaration.DeclaredInCurrent || declaration.DeclaredInDependency || declaration.AlwaysVisible))
				continue;
			if (!declaration.HasCustomAttribute<KdlObjectAttribute>())
				continue;
			let type = declaration.ResolvedType;
			if (type == null || type.IsValueType || type.IsInterface || type.IsAbstract || type.IsGenericParam)
				continue;
			if (element.IsInterface ? type.ImplementsInterface(element) : type.IsSubtypeOf(element))
				types.Add(type);
		}
	}

	/// The T of a List<T>, or null.
	[Comptime]
	static Type ListElement(Type type)
	{
		if (let specialized = type as SpecializedGenericType)
		{
			if (specialized.UnspecializedType == typeof(List<>))
				return specialized.GetGenericArg(0);
		}
		return null;
	}

	/// A [KdlObject] type's node name: its Name, or its type name through its Naming.
	[Comptime]
	static void NodeName(Type type, String name)
	{
		if (type.GetCustomAttribute<KdlObjectAttribute>() case .Ok(let attribute))
		{
			if (attribute.Name != null)
				name.Append(attribute.Name);
			else
				ApplyNaming(type.GetName(.. scope .()), attribute.Naming, name);
		}
		else
			ApplyNaming(type.GetName(.. scope .()), .KebabCase, name);
	}

	/// Appends the KDL name for `name`. Words start at an upper-case letter that follows a lower-case
	/// letter or digit, or that ends an acronym (the last capital before a lower-case letter), so
	/// `HTTPPort` splits as HTTP, Port and `Utf8Name` as Utf8, Name; underscores also split.
	[Comptime]
	static void ApplyNaming(StringView name, KdlNaming naming, String result)
	{
		if (naming == .AsDeclared)
		{
			result.Append(name);
			return;
		}
		int words = 0;
		int i = 0;
		while (i < name.Length)
		{
			if (name[i] == '_')
			{
				i++;
				continue;
			}
			int start = i++;
			while (i < name.Length && name[i] != '_' && !(name[i].IsUpper && (name[i - 1].IsLower || name[i - 1].IsDigit ||
				(name[i - 1].IsUpper && i + 1 < name.Length && name[i + 1].IsLower))))
				i++;

			if (words > 0 && naming != .CamelCase)
				result.Append(naming == .KebabCase ? '-' : '_');
			for (int j = start; j < i; j++)
				result.Append((naming == .CamelCase && words > 0 && j == start) ? name[j].ToUpper : name[j].ToLower);
			words++;
		}
	}

	/// Appends `text` as a Beef string literal.
	[Comptime]
	static void AppendLiteral(String code, StringView text)
	{
		code.Append('"');
		for (let c in text.RawChars)
		{
			switch (c)
			{
			case '"': code.Append("\\\"");
			case '\\': code.Append("\\\\");
			default:
				if ((uint8)c < 0x20)
					Runtime.FatalError(scope $"[KdlName] \"{text}\" contains a control character");
				code.Append(c);
			}
		}
		code.Append('"');
	}

	/// The smallest and largest value of an integer type below 64 unsigned bits, as int64 source
	/// expressions.
	[Comptime]
	static void IntegerRange(Type type, String min, String max)
	{
		int bits = type.Size * 8;
		if (bits == 64)
		{
			min.Append("int64.MinValue");
			max.Append("int64.MaxValue");
		}
		else if (type.IsSigned)
		{
			min.AppendF("{}", -(1L << (bits - 1)));
			max.AppendF("{}", (1L << (bits - 1)) - 1);
		}
		else
		{
			min.Append("0");
			max.AppendF("{}", (1L << bits) - 1);
		}
	}

	[Comptime]
	static bool IsUInt64(Type type)
	{
		return type.IsInteger && type.Size == 8 && !type.IsSigned;
	}

	/// "a, b, c": the enum's case names, for error messages.
	[Comptime]
	static void CaseList(Type enumType, KdlNaming naming, String list)
	{
		for (let field in enumType.GetFields())
		{
			if (!field.IsEnumCase)
				continue;
			if (!list.IsEmpty)
				list.Append(", ");
			ApplyNaming(field.Name, naming, list);
		}
	}

	/// An allocation of `typeName(args)` from the read's allocator when there is one, else the heap.
	[Comptime]
	static void NewExpr(StringView typeName, StringView args, String code)
	{
		code.AppendF("((_alloc != null) ? new:_alloc {0}({1}) : new {0}({1}))", typeName, args);
	}

	/// The code that finds a scalar's value into `_r` (current name first, then aliases).
	[Comptime]
	static void EmitFind(String code, StringView indent, StringView key, List<String> aliases, bool required, Role role, int index)
	{
		StringView req = required ? "true" : "false";
		switch (role)
		{
		case .Argument:
			code.AppendF("{}KdlBeef.KdlValueRef _r;\n{}bool _found = Try!(KdlBeef.KdlBind.FindArgument(_node, {}, {}, out _r));\n", indent, indent, index, req);
		default:
			StringView find = (role == .ChildValue) ? "FindChildValue" : "FindProperty";
			code.AppendF("{}KdlBeef.KdlValueRef _r;\n{}bool _found = Try!(KdlBeef.KdlBind.{}(_node, {}, {}, out _r));\n", indent, indent, find, key, aliases.IsEmpty ? req : "false");
			for (int a < aliases.Count)
			{
				StringView last = (a == aliases.Count - 1) ? req : "false";
				code.AppendF("{}if (!_found)\n{}\t_found = Try!(KdlBeef.KdlBind.{}(_node, {}, {}, out _r));\n", indent, indent, find, aliases[a], last);
			}
		}
	}

	/// Converts `_r` into `target` (a field: `this.X`), or appends it to the list `target`.
	[Comptime]
	static void EmitConvert(String code, StringView indent, StringView target, bool toList, Type type, Kind kind, Type converter, KdlNaming naming)
	{
		switch (kind)
		{
		case .Integer:
			let value = scope String();
			if (IsUInt64(type))
				value.Append("Try!(KdlBeef.KdlBind.ToUInt64(_r))");
			else
			{
				let min = scope String();
				let max = scope String();
				IntegerRange(type, min, max);
				value.AppendF("(.)Try!(KdlBeef.KdlBind.ToInteger(_r, {}, {}))", min, max);
			}
			if (toList)
				code.AppendF("{}{}.Add({});\n", indent, target, value);
			else
				code.AppendF("{}{} = {};\n", indent, target, value);
		case .Float:
			if (toList)
				code.AppendF("{}{}.Add((.)Try!(KdlBeef.KdlBind.ToDouble(_r)));\n", indent, target);
			else
				code.AppendF("{}{} = (.)Try!(KdlBeef.KdlBind.ToDouble(_r));\n", indent, target);
		case .Bool:
			if (toList)
				code.AppendF("{}{}.Add(Try!(KdlBeef.KdlBind.ToBool(_r)));\n", indent, target);
			else
				code.AppendF("{}{} = Try!(KdlBeef.KdlBind.ToBool(_r));\n", indent, target);
		case .String:
			code.AppendF("{}let _s = Try!(KdlBeef.KdlBind.ToString(_r));\n", indent);
			if (toList)
				code.AppendF("{}{}.Add({});\n", indent, target, NewExpr("String", "_s", .. scope .()));
			else
				code.AppendF("{0}if ({1} == null)\n{0}\t{1} = {2};\n{0}else\n{0}\t{1}.Set(_s);\n", indent, target, NewExpr("String", "_s", .. scope .()));
		case .Enum:
			let cases = scope String();
			CaseList(type, naming, cases);
			code.AppendF("{}let _s = Try!(KdlBeef.KdlBind.ToString(_r));\n{}switch (_s)\n{}{{\n", indent, indent, indent);
			for (let field in type.GetFields())
			{
				if (!field.IsEnumCase)
					continue;
				code.AppendF("{}case ", indent);
				AppendLiteral(code, ApplyNaming(field.Name, naming, .. scope .()));
				if (toList)
					code.AppendF(": {}.Add(.{});\n", target, field.Name);
				else
					code.AppendF(": {} = .{};\n", target, field.Name);
			}
			code.AppendF("{0}default: return .Err(KdlBeef.KdlBind.UnknownCase(_r, _s, \"{1}\"));\n{0}}}\n", indent, cases);
		case .Converter:
			let converterName = converter.GetFullName(.. scope .());
			if (toList)
				code.AppendF("{0}{1}.Add(default);\n{0}Try!({2}.Read(_r, ref {1}[{1}.Count - 1]));\n", indent, target, converterName);
			else
				code.AppendF("{}Try!({}.Read(_r, ref {}));\n", indent, converterName, target);
		default:
		}
	}

	/// Writes `source` (a field or `_e`) through the KdlValueWriter `_w`.
	[Comptime]
	static void EmitSet(String code, StringView indent, StringView source, Type type, Kind kind, Type converter, KdlNaming naming)
	{
		switch (kind)
		{
		case .Integer:
			if (IsUInt64(type))
				code.AppendF("{}_w.Set(KdlBeef.KdlBind.Unsigned((uint64){}, scope:: String()));\n", indent, source);
			else
				code.AppendF("{}_w.Set(.Integer((int64){}, default));\n", indent, source);
		case .Float:
			code.AppendF("{}_w.Set(.Float((double){}, default));\n", indent, source);
		case .Bool:
			code.AppendF("{}_w.Set(.Bool({}));\n", indent, source);
		case .String:
			code.AppendF("{0}if ({1} != null)\n{0}\t_w.Set(.String({1}));\n{0}else\n{0}\t_w.Remove();\n", indent, source);
		case .Enum:
			code.AppendF("{}switch ({})\n{}{{\n", indent, source, indent);
			for (let field in type.GetFields())
			{
				if (!field.IsEnumCase)
					continue;
				code.AppendF("{}case .{}: _w.Set(.String(", indent, field.Name);
				AppendLiteral(code, ApplyNaming(field.Name, naming, .. scope .()));
				code.Append("));\n");
			}
			code.AppendF("{}}}\n", indent);
		case .Converter:
			code.AppendF("{}{}.Write({}, _w);\n", indent, converter.GetFullName(.. scope .()), source);
		default:
		}
	}

	[Comptime]
	static void EmitReadScalar(String code, StringView name, StringView key, List<String> aliases, bool required, Role role, int index, Type type, Kind kind, Type converter, KdlNaming naming)
	{
		code.Append("\t{\n");
		EmitFind(code, "\t\t", key, aliases, required, role, index);
		code.Append("\t\tif (_found)\n\t\t{\n");
		EmitConvert(code, "\t\t\t", scope $"this.{name}", false, type, kind, converter, naming);
		code.Append("\t\t}\n\t}\n");
	}

	[Comptime]
	static void EmitWriteScalar(String code, StringView name, StringView key, List<String> aliases, Role role, int index, Type type, Kind kind, Type converter, KdlNaming naming)
	{
		code.Append("\t{\n");
		for (let alias in aliases)
		{
			if (role == .ChildValue)
				code.AppendF("\t\tKdlBeef.KdlBind.RenameChildAlias(_node, {}, {});\n", key, alias);
			else if (role == .Property)
				code.AppendF("\t\tKdlBeef.KdlBind.RenamePropertyAlias(_node, {}, {});\n", key, alias);
		}
		switch (role)
		{
		case .Argument: code.AppendF("\t\tlet _w = KdlBeef.KdlValueWriter.Argument(_node, {});\n", index);
		case .ChildValue: code.AppendF("\t\tlet _w = KdlBeef.KdlValueWriter.Child(_node, {});\n", key);
		default: code.AppendF("\t\tlet _w = KdlBeef.KdlValueWriter.Property(_node, {});\n", key);
		}
		EmitSet(code, "\t\t", scope $"this.{name}", type, kind, converter, naming);
		code.Append("\t}\n");
	}

	/// Clears a List field whose items are about to be replaced, deleting owned object items.
	[Comptime]
	static void EmitReplaceList(String code, StringView indent, StringView name, Type listType, Type element)
	{
		code.AppendF("{0}if (this.{1} == null)\n{0}\tthis.{1} = {2};\n", indent, name, NewExpr(listType.GetFullName(.. scope .()), "", .. scope .()));
		// Without an allocator the list owns its object items: delete them before replacing
		if (!element.IsValueType)
			code.AppendF("{0}if (_alloc == null)\n{0}{{\n{0}\tfor (let _old in this.{1})\n{0}\t\tdelete _old;\n{0}}}\n", indent, name);
		code.AppendF("{}this.{}.Clear();\n", indent, name);
	}

	[Comptime]
	/// A List of scalars: the arguments from `argumentsStart` on (an expression: [KdlArguments]), or a
	/// child node's arguments.
	static void EmitReadScalarList(String code, StringView name, StringView key, List<String> aliases, bool required, Role role, StringView argumentsStart, Type listType, Type element, Kind kind, Type converter, KdlNaming naming)
	{
		code.Append("\t{\n");
		StringView req = required ? "true" : "false";
		if (role == .Arguments)
		{
			code.AppendF("\t\tlet _args = _node;\n\t\tint _from = {};\n", argumentsStart);
			code.AppendF("\t\tif (KdlBeef.KdlBind.ArgumentCount(_node) <= _from && {})\n\t\t\treturn .Err(KdlBeef.KdlBind.MakeError(_node, -1, default, \"arguments are required\", .MissingValue));\n", req);
			code.Append("\t\tif (KdlBeef.KdlBind.ArgumentCount(_node) > _from)\n\t\t{\n");
		}
		else
		{
			code.AppendF("\t\tKdlBeef.KdlNode _args;\n\t\tbool _found = Try!(KdlBeef.KdlBind.FindChild(_node, {}, {}, out _args));\n", key, aliases.IsEmpty ? req : "false");
			for (int a < aliases.Count)
				code.AppendF("\t\tif (!_found)\n\t\t\t_found = Try!(KdlBeef.KdlBind.FindChild(_node, {}, {}, out _args));\n", aliases[a], (a == aliases.Count - 1) ? req : "false");
			code.Append("\t\tint _from = 0;\n\t\tif (_found)\n\t\t{\n");
		}
		EmitReplaceList(code, "\t\t\t", name, listType, element);
		code.Append("\t\t\tfor (let _r in KdlBeef.KdlBind.Arguments(_args, _from))\n\t\t\t{\n");
		EmitConvert(code, "\t\t\t\t", scope $"this.{name}", true, element, kind, converter, naming);
		code.Append("\t\t\t}\n\t\t}\n\t}\n");
	}

	[Comptime]
	static void EmitWriteScalarList(String code, StringView name, StringView key, List<String> aliases, Role role, StringView argumentsStart, Type element, Kind kind, Type converter, KdlNaming naming)
	{
		// A null list removes what it maps (its arguments, or its child node), like a null String
		code.Append("\t{\n");
		if (role == .Arguments)
			code.AppendF("\t\tvar _ac = KdlBeef.KdlArgumentCursor(_node, {});\n\t\tif (this.{} != null)\n\t\t{{\n", argumentsStart, name);
		else
		{
			for (let alias in aliases)
				code.AppendF("\t\tKdlBeef.KdlBind.RenameChildAlias(_node, {}, {});\n", key, alias);
			code.AppendF("\t\tif (this.{0} == null)\n\t\t\tKdlBeef.KdlBind.RemoveChild(_node, {1});\n\t\telse\n\t\t{{\n\t\t\tvar _ac = KdlBeef.KdlArgumentCursor(KdlBeef.KdlBind.ChildNode(_node, {1}), 0);\n", name, key);
		}
		code.AppendF("\t\t\tfor (let _e in this.{})\n\t\t\t{{\n\t\t\t\tlet _w = _ac.Next();\n", name);
		EmitSet(code, "\t\t\t\t", "_e", element, kind, converter, naming);
		code.Append("\t\t\t}\n\t\t\t_ac.Trim();\n\t\t}\n");
		if (role == .Arguments)
			code.Append("\t\telse\n\t\t\t_ac.Trim();\n");
		code.Append("\t}\n");
	}

	[Comptime]
	static void EmitReadObject(String code, StringView name, StringView key, List<String> aliases, bool required, Type type)
	{
		StringView req = required ? "true" : "false";
		code.AppendF("\t{{\n\t\tKdlBeef.KdlNode _c;\n\t\tbool _found = Try!(KdlBeef.KdlBind.FindChild(_node, {}, {}, out _c));\n", key, aliases.IsEmpty ? req : "false");
		for (int a < aliases.Count)
			code.AppendF("\t\tif (!_found)\n\t\t\t_found = Try!(KdlBeef.KdlBind.FindChild(_node, {}, {}, out _c));\n", aliases[a], (a == aliases.Count - 1) ? req : "false");
		code.Append("\t\tif (_found)\n\t\t{\n");
		if (!type.IsValueType)
			code.AppendF("\t\t\tif (this.{0} == null)\n\t\t\t\tthis.{0} = {1};\n", name, NewExpr(type.GetFullName(.. scope .()), "", .. scope .()));
		code.AppendF("\t\t\tTry!(this.{}.KdlRead(_c, _alloc));\n\t\t}}\n\t}}\n", name);
	}

	[Comptime]
	static void EmitWriteObject(String code, StringView name, StringView key, List<String> aliases, Type type)
	{
		for (let alias in aliases)
			code.AppendF("\tKdlBeef.KdlBind.RenameChildAlias(_node, {}, {});\n", key, alias);
		// Into the existing child when there is one, so its other content and comments stay
		if (type.IsValueType)
			code.AppendF("\tTry!(this.{}.KdlWrite(KdlBeef.KdlBind.ChildNode(_node, {})));\n", name, key);
		else
			code.AppendF("\tif (this.{0} != null)\n\t\tTry!(this.{0}.KdlWrite(KdlBeef.KdlBind.ChildNode(_node, {1})));\n\telse\n\t\tKdlBeef.KdlBind.RemoveChild(_node, {1});\n", name, key);
	}

	[Comptime]
	static void EmitReadObjects(String code, StringView name, StringView rawName, StringView elementName, bool required, Type listType, Type element)
	{
		code.AppendF("\tif (KdlBeef.KdlBind.CountChildren(_node, {}) > 0)\n\t{{\n", elementName);
		EmitReplaceList(code, "\t\t", name, listType, element);
		code.AppendF("\t\tfor (let _c in _node.Children)\n\t\t{{\n\t\t\tif (_c.Name != {})\n\t\t\t\tcontinue;\n", elementName);
		let typeName = element.GetFullName(.. scope .());
		if (element.IsValueType)
			code.AppendF("\t\t\t{0} _o = .();\n\t\t\tTry!(_o.KdlRead(_c, _alloc));\n\t\t\tthis.{1}.Add(_o);\n", typeName, name);
		else // added before reading, so the list owns it even if reading fails
			code.AppendF("\t\t\tlet _o = {0};\n\t\t\tthis.{1}.Add(_o);\n\t\t\tTry!(_o.KdlRead(_c, _alloc));\n", NewExpr(typeName, "", .. scope .()), name);
		code.Append("\t\t}\n\t}\n");
		if (required)
		{
			code.Append("\telse\n\t\treturn .Err(KdlBeef.KdlBind.MakeError(_node, -1, default, ");
			AppendLiteral(code, scope $"`{rawName}` child nodes are required");
			code.Append(", .MissingValue));\n");
		}
	}

	[Comptime]
	static void EmitWriteObjects(String code, StringView name, StringView elementName, Type element)
	{
		// Items into the existing children by position, then the rest removed; a null list removes them all
		code.AppendF("\t{{\n\t\tvar _cc = KdlBeef.KdlChildCursor(_node, {});\n\t\tif (this.{} != null)\n\t\t{{\n\t\t\tfor (let _e in this.{})\n\t\t\t{{\n", elementName, name, name);
		if (!element.IsValueType)
			code.Append("\t\t\t\tif (_e == null)\n\t\t\t\t\tcontinue;\n");
		code.Append("\t\t\t\tTry!(_e.KdlWrite(_cc.Next()));\n\t\t\t}\n\t\t}\n\t\t_cc.Trim();\n\t}\n");
	}

	[Comptime]
	static void EmitReadChildren(String code, StringView ownerName, StringView name, Type listType, Type element, StringView claimedExpr)
	{
		code.Append("\t{\n");
		EmitReplaceList(code, "\t\t", name, listType, element);
		code.AppendF("\t\tfor (let _c in _node.Children)\n\t\t{{\n\t\t\tif (KdlBeef.KdlBind.IsClaimed(_c.Name, {}))\n\t\t\t\tcontinue;\n", claimedExpr);
		// The item types are found when this method is compiled, not now: they may derive from the type
		// being generated (a Container holding Rows and Columns), which is not complete yet
		code.AppendF("\t\t\tSystem.Compiler.Mixin(KdlBeef.KdlSerializerCodeGen.ChildrenDispatch(typeof({}), ", element.GetFullName(.. scope .()));
		AppendLiteral(code, ownerName);
		code.Append(", ");
		AppendLiteral(code, name);
		code.Append("));\n\t\t}\n\t}\n");
	}

	/// @brief The `switch` that reads child `_c` into the [KdlChildren] list `fieldName`, one case per
	/// [KdlObject] type the list can hold. Mixed into the generated KdlRead when it is compiled.
	/// @param element The list's item type.
	/// @param ownerName The type holding the list, for errors.
	/// @param fieldName The list field.
	/// @return The code.
	[Comptime]
	public static String ChildrenDispatch(Type element, String ownerName, String fieldName)
	{
		let types = scope List<Type>();
		ChildTypes(element, types);
		if (types.IsEmpty)
			Fail(ownerName, fieldName, scope $"[KdlChildren] found no [KdlObject] type for {element.GetFullName(.. scope .())}: mark the item types [KdlObject]");
		let expected = scope String();
		for (let type in types)
		{
			if (!expected.IsEmpty)
				expected.Append(", ");
			NodeName(type, expected);
		}
		let code = new String();
		code.Append("switch (_c.Name)\n{\n");
		for (let type in types)
		{
			let typeName = type.GetFullName(.. scope .());
			code.Append("case ");
			AppendLiteral(code, NodeName(type, .. scope .()));
			if (type.IsValueType)
				code.AppendF(":\n\t{0} _o = .();\n\tTry!(_o.KdlRead(_c, _alloc));\n\tthis.{1}.Add(_o);\n", typeName, fieldName);
			else
				code.AppendF(":\n\tlet _o = {0};\n\tthis.{1}.Add(_o);\n\tTry!(_o.KdlRead(_c, _alloc));\n", NewExpr(typeName, "", .. scope .()), fieldName);
		}
		code.AppendF("default:\n\treturn .Err(KdlBeef.KdlBind.UnknownChild(_c, \"{}\"));\n}}\n", expected);
		return code;
	}

	/// Appends the deletion of an owned value `expr` of `type` (a container's item or value being
	/// replaced): Strings and class objects are deleted, containers with what they own (String keys,
	/// reference-type items and values, recursively); value types need nothing. `depth` keeps the loop
	/// variables of nested containers apart.
	[Comptime]
	static void EmitDeleteOwned(String code, StringView indent, StringView expr, Type type, int depth)
	{
		if (type.IsValueType)
			return;
		// A container item or value may be null (writing skips a null one): nothing to enumerate then,
		// and `delete null` does nothing
		if (let element = ListElement(type))
		{
			if (!element.IsValueType)
			{
				code.AppendF("{0}if (({2}) != null)\n{0}{{\n{0}\tfor (let _x{1} in ({2}))\n{0}\t{{\n", indent, depth, expr);
				EmitDeleteOwned(code, scope $"{indent}\t\t", scope $"_x{depth}", element, depth + 1);
				code.AppendF("{0}\t}}\n{0}}}\n", indent);
			}
		}
		else if (let value = DictionaryValue(type))
		{
			bool ownsKeys = DictionaryKey(type) == typeof(String);
			if (ownsKeys || !value.IsValueType)
			{
				code.AppendF("{0}if (({2}) != null)\n{0}{{\n{0}\tfor (let _x{1} in ({2}))\n{0}\t{{\n", indent, depth, expr);
				if (ownsKeys)
					code.AppendF("{}\t\tdelete _x{}.key;\n", indent, depth);
				EmitDeleteOwned(code, scope $"{indent}\t\t", scope $"_x{depth}.value", value, depth + 1);
				code.AppendF("{0}\t}}\n{0}}}\n", indent);
			}
		}
		code.AppendF("{}delete ({});\n", indent, expr);
	}

	/// Whether `type` is a List or Dictionary.
	[Comptime]
	static bool IsContainer(Type type)
	{
		return ListElement(type) != null || DictionaryValue(type) != null;
	}

	/// Whether a dictionary's keys can be node names: String, integers (written in decimal) and simple
	/// enums (their case names).
	[Comptime]
	static bool IsKeyType(Type type)
	{
		if (type == typeof(String))
			return true;
		if (type == typeof(char8) || type == typeof(char16) || type == typeof(char32) || type == typeof(bool))
			return false;
		return type.IsInteger || (type.IsEnum && !type.IsUnion);
	}

	/// Whether `type` can be a List's item or a Dictionary's value: a scalar, a [KdlObject], or a
	/// container of those (recursively). A [KdlUseConverter] converter makes any non-container a scalar.
	[Comptime]
	static bool IsSupportedItem(Type type, Type useConverter)
	{
		if (IsContainer(type))
			return IsContent(type, useConverter);
		if (useConverter != null)
			return true;
		let kind = Classify(type, ?);
		return IsScalar(kind) || kind == .Object;
	}

	/// Whether a List or Dictionary type can be mapped as a node's content (see EmitReadContent).
	[Comptime]
	static bool IsContent(Type type, Type useConverter)
	{
		if (let element = ListElement(type))
			return IsSupportedItem(element, useConverter);
		if (let value = DictionaryValue(type))
			return IsKeyType(DictionaryKey(type)) && IsSupportedItem(value, useConverter);
		return false;
	}

	/// The kind and converter of a scalar leaf: the [KdlUseConverter] one when given, else as classified.
	[Comptime]
	static Kind LeafKind(Type type, Type useConverter, out Type converter)
	{
		if (useConverter != null && !IsContainer(type))
		{
			converter = useConverter;
			return .Converter;
		}
		return Classify(type, out converter);
	}

	/// A field whose type is a Dictionary, or a List of Lists or Dictionaries: the child node `key`, read
	/// as content (EmitReadContent).
	[Comptime]
	static void EmitReadContentField(String code, StringView name, StringView key, List<String> aliases, bool required, Type type, Type useConverter, KdlNaming naming)
	{
		StringView req = required ? "true" : "false";
		code.AppendF("\t{{\n\t\tKdlBeef.KdlNode _dn;\n\t\tbool _found = Try!(KdlBeef.KdlBind.FindChild(_node, {}, {}, out _dn));\n", key, aliases.IsEmpty ? req : "false");
		for (int a < aliases.Count)
			code.AppendF("\t\tif (!_found)\n\t\t\t_found = Try!(KdlBeef.KdlBind.FindChild(_node, {}, {}, out _dn));\n", aliases[a], (a == aliases.Count - 1) ? req : "false");
		code.Append("\t\tif (_found)\n\t\t{\n");
		EmitReadContent(code, "\t\t\t", "_dn", scope $"this.{name}", type, useConverter, naming, 1);
		code.Append("\t\t}\n\t}\n");
	}

	/// Reads the node `node` as the content of a List or Dictionary `type` into `target` (an lvalue), which
	/// is created when null and otherwise emptied first (its owned items deleted on a heap read):
	/// - List<scalar>: the node's arguments (`tags a b`);
	/// - List<[KdlObject]>: its children named after the item type;
	/// - List<List or Dictionary>: its children named `-`, each an item's content (`- 1 2`);
	/// - Dictionary<K, V>: its children, one per entry, named by the key (a String as written, an
	///   integer in decimal, an enum case by name): a scalar V is the entry's argument (`key value`,
	///   `key #null` skipped), a [KdlObject] V the entry node itself, a container V its content. The
	///   last of duplicate keys wins.
	/// Items are added before they are read, so the container owns them if reading fails. `depth` keeps
	/// the locals of nested levels apart.
	[Comptime]
	static void EmitReadContent(String code, StringView indent, StringView node, StringView target, Type type, Type useConverter, KdlNaming naming, int depth)
	{
		StringView i = indent;
		let inner = scope String(indent)..Append('\t');
		let typeName = type.GetFullName(.. scope .());
		// Created, or emptied of what it owned
		code.AppendF("{0}if ({1} == null)\n{0}\t{1} = {2};\n{0}else\n{0}{{\n", i, target, NewExpr(typeName, "", .. scope .()));
		let deleteOwned = scope String();
		if (let element = ListElement(type))
		{
			if (!element.IsValueType)
			{
				deleteOwned.AppendF("{0}\t\tfor (let _o{1} in {2})\n{0}\t\t{{\n", i, depth, target);
				EmitDeleteOwned(deleteOwned, scope $"{i}\t\t\t", scope $"_o{depth}", element, depth + 1);
				deleteOwned.AppendF("{}\t\t}}\n", i);
			}
		}
		else
		{
			bool ownsKeys = DictionaryKey(type) == typeof(String);
			let value = DictionaryValue(type);
			if (ownsKeys || !value.IsValueType)
			{
				deleteOwned.AppendF("{0}\t\tfor (let _o{1} in {2})\n{0}\t\t{{\n", i, depth, target);
				if (ownsKeys)
					deleteOwned.AppendF("{}\t\t\tdelete _o{}.key;\n", i, depth);
				EmitDeleteOwned(deleteOwned, scope $"{i}\t\t\t", scope $"_o{depth}.value", value, depth + 1);
				deleteOwned.AppendF("{}\t\t}}\n", i);
			}
		}
		if (!deleteOwned.IsEmpty)
			code.AppendF("{0}\tif (_alloc == null)\n{0}\t{{\n{1}{0}\t}}\n", i, deleteOwned);
		code.AppendF("{0}\t{1}.Clear();\n{0}}}\n", i, target);

		if (let element = ListElement(type))
		{
			code.AppendF("{}let _l{} = {};\n", i, depth, target);
			let elementKind = LeafKind(element, useConverter, let elementConverter);
			if (IsContainer(element))
			{
				// `- …` children, each an item
				code.AppendF("{0}for (let _c{1} in {2}.Children)\n{0}{{\n{0}\tif (_c{1}.Name != \"-\")\n{0}\t\tcontinue;\n{0}\t_l{1}.Add(default);\n", i, depth, node);
				EmitReadContent(code, inner, scope $"_c{depth}", scope $"_l{depth}[_l{depth}.Count - 1]", element, useConverter, naming, depth + 1);
				code.AppendF("{}}}\n", i);
			}
			else if (elementKind == .Object)
			{
				let elementName = AppendLiteral(.. scope .(), NodeName(element, .. scope .()));
				let elementTypeName = element.GetFullName(.. scope .());
				code.AppendF("{0}for (let _c{1} in {2}.Children)\n{0}{{\n{0}\tif (_c{1}.Name != {3})\n{0}\t\tcontinue;\n", i, depth, node, elementName);
				if (element.IsValueType)
					code.AppendF("{0}\t{1} _o{2} = .();\n{0}\tTry!(_o{2}.KdlRead(_c{2}, _alloc));\n{0}\t_l{2}.Add(_o{2});\n", i, elementTypeName, depth);
				else
					code.AppendF("{0}\tlet _o{1} = {2};\n{0}\t_l{1}.Add(_o{1});\n{0}\tTry!(_o{1}.KdlRead(_c{1}, _alloc));\n", i, depth, NewExpr(elementTypeName, "", .. scope .()));
				code.AppendF("{}}}\n", i);
			}
			else
			{
				// The arguments
				code.AppendF("{0}for (let _r in KdlBeef.KdlBind.Arguments({1}, 0))\n{0}{{\n", i, node);
				EmitConvert(code, inner, scope $"_l{depth}", true, element, elementKind, elementConverter, naming);
				code.AppendF("{}}}\n", i);
			}
			return;
		}

		// A Dictionary
		let keyType = DictionaryKey(type);
		let value = DictionaryValue(type);
		let valueKind = LeafKind(value, useConverter, let valueConverter);
		bool scalarValue = !IsContainer(value) && valueKind != .Object;
		code.AppendF("{0}let _m{1} = {2};\n{0}for (let _e{1} in {3}.Children)\n{0}{{\n", i, depth, target, node);
		// A scalar entry is `key value`; `key #null` is skipped, like an absent property
		if (scalarValue)
			code.AppendF("{0}KdlBeef.KdlValueRef _r;\n{0}if (!Try!(KdlBeef.KdlBind.EntryValue(_e{1}, out _r)))\n{0}\tcontinue;\n", inner, depth);
		if (keyType == typeof(String))
			code.AppendF("{0}if (_m{1}.TryAddAlt(_e{1}.Name, let _kp{1}, let _vp{1}))\n{0}\t*_kp{1} = {2};\n", inner, depth, NewExpr("String", scope $"_e{depth}.Name", .. scope .()));
		else
		{
			EmitReadKey(code, inner, scope $"_e{depth}", scope $"_key{depth}", keyType, naming);
			code.AppendF("{0}if (_m{1}.TryAdd(_key{1}, let _kp{1}, let _vp{1}))\n{0}\t*_kp{1} = _key{1};\n", inner, depth);
		}
		// A repeated key: the last one wins, the earlier value goes
		let deleteOld = EmitDeleteOwned(.. scope .(), scope $"{inner}\t", scope $"*_vp{depth}", value, depth + 1);
		if (!deleteOld.IsEmpty)
			code.AppendF("{0}else if (_alloc == null)\n{0}{{\n{1}{0}}}\n", inner, deleteOld);
		code.AppendF("{}*_vp{} = {};\n", inner, depth, (valueKind == .Object && value.IsValueType) ? ".()" : "default");
		let slot = scope $"(*_vp{depth})";
		if (IsContainer(value))
			EmitReadContent(code, inner, scope $"_e{depth}", slot, value, useConverter, naming, depth + 1);
		else if (valueKind == .Object)
		{
			if (!value.IsValueType)
				code.AppendF("{}{} = {};\n", inner, slot, NewExpr(value.GetFullName(.. scope .()), "", .. scope .()));
			code.AppendF("{}Try!({}.KdlRead(_e{}, _alloc));\n", inner, slot, depth);
		}
		else
			EmitConvert(code, inner, slot, false, value, valueKind, valueConverter, naming);
		code.AppendF("{}}}\n", i);
	}

	/// Converts an entry node's name into a non-String dictionary key `variable` of `keyType` (an integer
	/// in decimal, or an enum case name), or returns a located error.
	[Comptime]
	static void EmitReadKey(String code, StringView indent, StringView entry, StringView variable, Type keyType, KdlNaming naming)
	{
		let keyTypeName = keyType.GetFullName(.. scope .());
		if (keyType.IsEnum)
		{
			let cases = CaseList(keyType, naming, .. scope .());
			code.AppendF("{0}{1} {2};\n{0}switch ({3}.Name)\n{0}{{\n", indent, keyTypeName, variable, entry);
			for (let field in keyType.GetFields())
			{
				if (!field.IsEnumCase)
					continue;
				code.AppendF("{}case ", indent);
				AppendLiteral(code, ApplyNaming(field.Name, naming, .. scope .()));
				code.AppendF(": {} = .{};\n", variable, field.Name);
			}
			code.AppendF("{0}default: return .Err(KdlBeef.KdlBind.UnknownKey({1}, \"{2}\"));\n{0}}}\n", indent, entry, cases);
			return;
		}
		let min = scope String();
		let max = scope String();
		if (IsUInt64(keyType))
		{
			// The whole uint64 range, as the writer writes it
			code.AppendF("{}let {} = ({})Try!(KdlBeef.KdlBind.UnsignedKey({}));\n", indent, variable, keyTypeName, entry);
			return;
		}
		IntegerRange(keyType, min, max);
		code.AppendF("{}let {} = ({})Try!(KdlBeef.KdlBind.IntegerKey({}, {}, {}));\n", indent, variable, keyTypeName, entry, min, max);
	}

	/// Writes a content field (see EmitReadContentField) into its child node, which a null field removes.
	[Comptime]
	static void EmitWriteContentField(String code, StringView name, StringView key, List<String> aliases, Type type, Type useConverter, KdlNaming naming)
	{
		for (let alias in aliases)
			code.AppendF("\tKdlBeef.KdlBind.RenameChildAlias(_node, {}, {});\n", key, alias);
		code.AppendF("\tif (this.{0} == null)\n\t\tKdlBeef.KdlBind.RemoveChild(_node, {1});\n\telse\n\t{{\n\t\tlet _dn = KdlBeef.KdlBind.ChildNode(_node, {1});\n", name, key);
		EmitWriteContent(code, "\t\t", "_dn", scope $"this.{name}", type, useConverter, naming, 1);
		code.Append("\t}\n");
	}

	/// Writes `source` (a non-null List or Dictionary) as the content of `node` (see EmitReadContent), in
	/// place: items reuse the existing arguments or children by position (list) or key (dictionary, whose
	/// entry nodes are indexed once, KdlKeyIndex), so comments and number forms stay; what is left over is
	/// removed. A null item is skipped; a null dictionary value removes its entry.
	[Comptime]
	static void EmitWriteContent(String code, StringView indent, StringView node, StringView source, Type type, Type useConverter, KdlNaming naming, int depth)
	{
		StringView i = indent;
		let inner = scope String(indent)..Append('\t');
		if (let element = ListElement(type))
		{
			code.AppendF("{}let _l{} = {};\n", i, depth, source);
			let elementKind = LeafKind(element, useConverter, let elementConverter);
			if (IsContainer(element))
			{
				code.AppendF("{0}var _cc{1} = KdlBeef.KdlChildCursor({2}, \"-\");\n{0}for (let _x{1} in _l{1})\n{0}{{\n{0}\tif (_x{1} == null)\n{0}\t\tcontinue;\n{0}\tlet _cn{1} = _cc{1}.Next();\n", i, depth, node);
				EmitWriteContent(code, inner, scope $"_cn{depth}", scope $"_x{depth}", element, useConverter, naming, depth + 1);
				code.AppendF("{0}}}\n{0}_cc{1}.Trim();\n", i, depth);
			}
			else if (elementKind == .Object)
			{
				let elementName = AppendLiteral(.. scope .(), NodeName(element, .. scope .()));
				code.AppendF("{0}var _cc{1} = KdlBeef.KdlChildCursor({2}, {3});\n{0}for (let _x{1} in _l{1})\n{0}{{\n", i, depth, node, elementName);
				if (!element.IsValueType)
					code.AppendF("{0}\tif (_x{1} == null)\n{0}\t\tcontinue;\n", i, depth);
				code.AppendF("{0}\tTry!(_x{1}.KdlWrite(_cc{1}.Next()));\n{0}}}\n{0}_cc{1}.Trim();\n", i, depth);
			}
			else
			{
				code.AppendF("{0}var _ac{1} = KdlBeef.KdlArgumentCursor({2}, 0);\n{0}for (let _e in _l{1})\n{0}{{\n{0}\tlet _w = _ac{1}.Next();\n", i, depth, node);
				EmitSet(code, inner, "_e", element, elementKind, elementConverter, naming);
				code.AppendF("{0}}}\n{0}_ac{1}.Trim();\n", i, depth);
			}
			return;
		}

		// A Dictionary: the entry nodes by key, found once; keys the dictionary no longer has go at the end
		let keyType = DictionaryKey(type);
		let value = DictionaryValue(type);
		let valueKind = LeafKind(value, useConverter, let valueConverter);
		code.AppendF("{0}let _ix{1} = scope KdlBeef.KdlKeyIndex({2});\n{0}for (let _kv{1} in {3})\n{0}{{\n", i, depth, node, source);
		let keyName = scope String();
		if (keyType == typeof(String))
			keyName.AppendF("_kv{}.key", depth);
		else if (keyType.IsEnum)
		{
			keyName.AppendF("_kn{}", depth);
			code.AppendF("{0}StringView {1};\n{0}switch (_kv{2}.key)\n{0}{{\n", inner, keyName, depth);
			for (let field in keyType.GetFields())
			{
				if (!field.IsEnumCase)
					continue;
				code.AppendF("{}case .{}: {} = ", inner, field.Name, keyName);
				AppendLiteral(code, ApplyNaming(field.Name, naming, .. scope .()));
				code.Append(";\n");
			}
			code.AppendF("{}}}\n", inner);
		}
		else
		{
			keyName.AppendF("_kn{}", depth);
			code.AppendF("{}let {} = _kv{}.key.ToString(.. scope String());\n", inner, keyName, depth);
		}
		let valueExpr = scope $"_kv{depth}.value";
		if (IsContainer(value))
		{
			code.AppendF("{0}if ({1} == null)\n{0}\t_ix{2}.Value({3}).Remove();\n{0}else\n{0}{{\n{0}\tlet _en{2} = _ix{2}.Get({3});\n", inner, valueExpr, depth, keyName);
			EmitWriteContent(code, scope $"{inner}\t", scope $"_en{depth}", valueExpr, value, useConverter, naming, depth + 1);
			code.AppendF("{}}}\n", inner);
		}
		else if (valueKind == .Object)
		{
			if (value.IsValueType)
				code.AppendF("{}Try!({}.KdlWrite(_ix{}.Get({})));\n", inner, valueExpr, depth, keyName);
			else
				code.AppendF("{0}if ({1} == null)\n{0}\t_ix{2}.Value({3}).Remove();\n{0}else\n{0}\tTry!({1}.KdlWrite(_ix{2}.Get({3})));\n", inner, valueExpr, depth, keyName);
		}
		else
		{
			code.AppendF("{}let _w = _ix{}.Value({});\n", inner, depth, keyName);
			EmitSet(code, inner, valueExpr, value, valueKind, valueConverter, naming);
		}
		code.AppendF("{0}}}\n{0}_ix{1}.Finish();\n", i, depth);
	}

	[Comptime]
	static void EmitWriteChildren(String code, StringView name, Type element, StringView claimedExpr)
	{
		// Items into the unclaimed children by position, then the rest removed; a null list removes them all
		code.AppendF("\t{{\n\t\tvar _fc = KdlBeef.KdlFreeChildCursor(_node, {});\n\t\tif (this.{} != null)\n\t\t{{\n\t\t\tfor (let _e in this.{})\n\t\t\t{{\n", claimedExpr, name, name);
		if (element.IsValueType)
			code.Append("\t\t\t\tTry!(_e.KdlWrite(_fc.Next(_e.KdlNodeName)));\n");
		else
		{
			// The item's own type decides its node name and fields: call through the interface, which
			// dispatches on it (a [KdlObject] subclass hides its base's methods rather than overriding)
			if (element.HasCustomAttribute<KdlObjectAttribute>())
				code.Append("\t\t\t\tif (_e == null)\n\t\t\t\t\tcontinue;\n\t\t\t\tKdlBeef.IKdlSerializable _s = _e;\n");
			else
				code.Append("\t\t\t\tlet _s = _e as KdlBeef.IKdlSerializable;\n\t\t\t\tif (_s == null)\n\t\t\t\t\tcontinue;\n");
			code.Append("\t\t\t\tTry!(_s.KdlWrite(_fc.Next(_s.KdlNodeName)));\n");
		}
		code.Append("\t\t\t}\n\t\t}\n\t\t_fc.Trim();\n\t}\n");
	}
}

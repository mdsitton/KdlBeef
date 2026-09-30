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
		Children
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

		// The first argument no [KdlArgument] field takes, for [KdlArguments]; and the child names the
		// fields claim, which [KdlChildren] leaves alone
		int nextArgument = 0;
		let claimed = scope String();
		int claimedCount = 0;
		for (let field in type.GetFields())
		{
			if (!IsSerialized(type, field))
				continue;
			if (field.GetCustomAttribute<KdlArgumentAttribute>() case .Ok(let argument))
				nextArgument = Math.Max(nextArgument, argument.mIndex + 1);
			else if (!field.HasCustomAttribute<KdlChildrenAttribute>() && !field.HasCustomAttribute<KdlArgumentsAttribute>())
			{
				let names = scope List<String>();
				defer { ClearAndDeleteItems!(names); }
				ClaimedNames(field, naming, names);
				for (let claim in names)
				{
					if (claimedCount++ > 0)
						claimed.Append(", ");
					AppendLiteral(claimed, claim);
				}
			}
		}
		bool claimsArray = false;

		for (let field in type.GetFields())
		{
			if (!IsSerialized(type, field))
				continue;

			let key = scope String();
			if (field.GetCustomAttribute<KdlNameAttribute>() case .Ok(let named))
				AppendLiteral(key, named.mName);
			else
				AppendLiteral(key, ApplyNaming(field.Name, naming, .. scope .()));
			let aliases = scope List<String>();
			defer { ClearAndDeleteItems!(aliases); }
			for (let alias in field.GetCustomAttributes<KdlAliasAttribute>())
				aliases.Add(AppendLiteral(.. new .(), alias.mName));
			bool required = field.HasCustomAttribute<KdlRequiredAttribute>();

			let fieldType = field.FieldType;
			Type converter = null;
			Kind kind;
			if (field.GetCustomAttribute<KdlUseConverterAttribute>() case .Ok(let use))
			{
				converter = use.mConverter;
				kind = (ListElement(fieldType) != null) ? .List : .Converter;
			}
			else
				kind = Classify(fieldType, out converter);
			Type element = null;
			var elementKind = Kind.Unsupported;
			Type elementConverter = converter;
			if (kind == .List)
			{
				element = ListElement(fieldType);
				if (converter != null)
					elementKind = .Converter;
				else
					elementKind = Classify(element, out elementConverter);
			}

			Role role;
			int index = 0;
			bool scalar = kind != .Object && kind != .List && kind != .Unsupported;
			bool scalarList = kind == .List && elementKind != .Object && elementKind != .List && elementKind != .Unsupported;
			if (field.HasCustomAttribute<KdlChildrenAttribute>())
			{
				if (kind != .List)
					Fail(ownerName, field.Name, "[KdlChildren] needs a List<T> field");
				role = .Children;
			}
			else if (field.HasCustomAttribute<KdlArgumentsAttribute>())
			{
				if (!scalarList)
					Fail(ownerName, field.Name, "[KdlArguments] needs a List of scalars (bool, integers, floats, String, enums, converter types)");
				role = .Arguments;
				index = nextArgument;
			}
			else if (field.GetCustomAttribute<KdlArgumentAttribute>() case .Ok(let argument))
			{
				if (!scalar)
					Fail(ownerName, field.Name, "[KdlArgument] needs a scalar field (bool, integers, floats, String, enums, converter types)");
				role = .Argument;
				index = argument.mIndex;
			}
			else if (field.HasCustomAttribute<KdlChildAttribute>())
			{
				if (!scalar)
					Fail(ownerName, field.Name, "[KdlChild] needs a scalar field; [KdlObject] and List fields are child nodes already");
				role = .ChildValue;
			}
			else if (scalar)
				role = .Property;
			else if (kind == .Object)
				role = .ChildObject;
			else if (scalarList)
				role = .ChildArguments;
			else if (kind == .List && elementKind == .Object)
				role = .ChildObjects;
			else
			{
				let typeName = fieldType.GetFullName(.. scope .());
				Fail(ownerName, field.Name, scope $"KDL serialization does not support fields of type {typeName}. Supported: bool, integers, float, double, String, enums, [KdlObject] types, List<T> of those, and types with a converter ([KdlConverter] registration or [KdlUseConverter] on the field). Mark the field [KdlIgnore] to leave it out.");
				role = .Property;
			}

			if (role == .Children && !claimsArray)
			{
				claimsArray = true;
				read.Insert(0, scope $"static StringView[{claimedCount}] sKdlClaimed = .({claimed});\n");
			}

			switch (role)
			{
			case .Property, .Argument, .ChildValue:
				EmitReadScalar(read, field.Name, key, aliases, required, role, index, fieldType, kind, converter, naming);
				EmitWriteScalar(write, field.Name, key, aliases, role, index, fieldType, kind, converter, naming);
			case .Arguments, .ChildArguments:
				EmitReadScalarList(read, field.Name, key, aliases, required, role, index, fieldType, element, elementKind, elementConverter, naming);
				EmitWriteScalarList(write, field.Name, key, aliases, role, index, element, elementKind, elementConverter, naming);
			case .ChildObject:
				EmitReadObject(read, field.Name, key, aliases, required, fieldType);
				EmitWriteObject(write, field.Name, key, aliases, fieldType);
			case .ChildObjects:
				let rawName = NodeName(element, .. scope .());
				let elementName = AppendLiteral(.. scope .(), rawName);
				EmitReadObjects(read, field.Name, rawName, elementName, required, fieldType, element);
				EmitWriteObjects(write, field.Name, elementName, element);
			case .Children:
				EmitReadChildren(read, ownerName, field.Name, fieldType, element);
				EmitWriteChildren(write, field.Name, element);
			}
		}

		read.Append("\treturn .Ok;\n}\n");
		write.Append("\treturn .Ok;\n}\n");

		Compiler.EmitAddInterface(type, typeof(IKdlSerializable));
		Compiler.EmitTypeBody(type, read);
		Compiler.EmitTypeBody(type, write);
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
		return .Unsupported;
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
	static void EmitReadScalarList(String code, StringView name, StringView key, List<String> aliases, bool required, Role role, int index, Type listType, Type element, Kind kind, Type converter, KdlNaming naming)
	{
		code.Append("\t{\n");
		StringView req = required ? "true" : "false";
		if (role == .Arguments)
		{
			code.AppendF("\t\tlet _args = _node;\n\t\tint _from = {};\n", index);
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
		code.Append("\t\t\tfor (int _i = _from; _i < KdlBeef.KdlBind.ArgumentCount(_args); _i++)\n\t\t\t{\n\t\t\t\tlet _r = KdlBeef.KdlBind.ArgumentAt(_args, _i);\n");
		EmitConvert(code, "\t\t\t\t", scope $"this.{name}", true, element, kind, converter, naming);
		code.Append("\t\t\t}\n\t\t}\n\t}\n");
	}

	[Comptime]
	static void EmitWriteScalarList(String code, StringView name, StringView key, List<String> aliases, Role role, int index, Type element, Kind kind, Type converter, KdlNaming naming)
	{
		code.Append("\t{\n");
		if (role == .Arguments)
			code.AppendF("\t\tif (this.{0} != null)\n\t\t{{\n\t\t\tlet _args = _node;\n\t\t\tint _i = {1};\n", name, index);
		else
		{
			for (let alias in aliases)
				code.AppendF("\t\tKdlBeef.KdlBind.RenameChildAlias(_node, {}, {});\n", key, alias);
			code.AppendF("\t\tif (this.{0} == null)\n\t\t\tKdlBeef.KdlBind.RemoveChild(_node, {1});\n\t\telse\n\t\t{{\n\t\t\tlet _args = KdlBeef.KdlBind.ChildNode(_node, {1});\n\t\t\tint _i = 0;\n", name, key);
		}
		code.AppendF("\t\t\tfor (let _e in this.{})\n\t\t\t{{\n\t\t\t\tlet _w = KdlBeef.KdlValueWriter.Argument(_args, _i++);\n", name);
		EmitSet(code, "\t\t\t\t", "_e", element, kind, converter, naming);
		code.Append("\t\t\t}\n\t\t\tKdlBeef.KdlBind.TrimArguments(_args, _i);\n\t\t}\n\t}\n");
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
		code.AppendF("\tif (this.{} != null)\n\t{{\n\t\tint _i = 0;\n\t\tfor (let _e in this.{})\n\t\t{{\n", name, name);
		if (!element.IsValueType)
			code.Append("\t\t\tif (_e == null)\n\t\t\t\tcontinue;\n");
		code.AppendF("\t\t\tTry!(_e.KdlWrite(KdlBeef.KdlBind.NthChild(_node, {0}, _i++)));\n\t\t}}\n\t\tKdlBeef.KdlBind.TrimChildren(_node, {0}, _i);\n\t}}\n", elementName);
	}

	[Comptime]
	static void EmitReadChildren(String code, StringView ownerName, StringView name, Type listType, Type element)
	{
		let types = scope List<Type>();
		ChildTypes(element, types);
		if (types.IsEmpty)
			Fail(ownerName, name, scope $"[KdlChildren] found no [KdlObject] type for {element.GetFullName(.. scope .())}: mark the item types [KdlObject]");
		let expected = scope String();
		for (let type in types)
		{
			if (!expected.IsEmpty)
				expected.Append(", ");
			NodeName(type, expected);
		}
		code.Append("\t{\n");
		EmitReplaceList(code, "\t\t", name, listType, element);
		code.Append("\t\tfor (let _c in _node.Children)\n\t\t{\n\t\t\tif (KdlBeef.KdlBind.IsClaimed(_c.Name, sKdlClaimed))\n\t\t\t\tcontinue;\n\t\t\tswitch (_c.Name)\n\t\t\t{\n");
		for (let type in types)
		{
			let typeName = type.GetFullName(.. scope .());
			code.Append("\t\t\tcase ");
			AppendLiteral(code, NodeName(type, .. scope .()));
			if (type.IsValueType)
				code.AppendF(":\n\t\t\t\t{0} _o = .();\n\t\t\t\tTry!(_o.KdlRead(_c, _alloc));\n\t\t\t\tthis.{1}.Add(_o);\n", typeName, name);
			else
				code.AppendF(":\n\t\t\t\tlet _o = {0};\n\t\t\t\tthis.{1}.Add(_o);\n\t\t\t\tTry!(_o.KdlRead(_c, _alloc));\n", NewExpr(typeName, "", .. scope .()), name);
		}
		code.AppendF("\t\t\tdefault:\n\t\t\t\treturn .Err(KdlBeef.KdlBind.UnknownChild(_c, \"{}\"));\n\t\t\t}}\n\t\t}}\n\t}}\n", expected);
	}

	[Comptime]
	static void EmitWriteChildren(String code, StringView name, Type element)
	{
		code.AppendF("\tif (this.{} != null)\n\t{{\n\t\tint _i = 0;\n\t\tfor (let _e in this.{})\n\t\t{{\n", name, name);
		if (element.IsValueType)
			code.Append("\t\t\tTry!(_e.KdlWrite(KdlBeef.KdlBind.FreeChild(_node, _i++, _e.KdlNodeName, sKdlClaimed)));\n");
		else
		{
			// The item's own type decides its node name and fields
			code.Append("\t\t\tlet _s = _e as KdlBeef.IKdlSerializable;\n\t\t\tif (_s == null)\n\t\t\t\tcontinue;\n");
			code.Append("\t\t\tTry!(_s.KdlWrite(KdlBeef.KdlBind.FreeChild(_node, _i++, _s.KdlNodeName, sKdlClaimed)));\n");
		}
		code.Append("\t\t}\n\t\tKdlBeef.KdlBind.TrimFreeChildren(_node, _i, sKdlClaimed);\n\t}\n");
	}
}

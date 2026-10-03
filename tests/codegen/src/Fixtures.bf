using System;
using System.Collections;
using KdlBeef;

namespace Fixtures;

// Each fixture is built alone by test-codegen.sh, with -define=FIXTURE_<name>. A line
// `// FIXTURE <name>: <text>` gives the text the build error must contain, or OK for a mapping that must
// build (a positive control: the checks must not reject it).

class Program
{
	public static int Main()
	{
		return 0;
	}
}

struct Temperature
{
	public double mCelsius;
}

// FIXTURE OkBaseline: OK
#if FIXTURE_OkBaseline
[KdlObject]
class Item
{
	[KdlArgument(0)] public String title ~ delete _;
	public int32 count;
	public List<int32> sizes ~ delete _;
	public Dictionary<String, int32> totals ~ DeleteDictionaryAndKeys!(_);
}
#endif

// FIXTURE OkRegisteredConverter: OK
#if FIXTURE_OkRegisteredConverter
// Registered in this project while another project (Other) also depends on KdlBeef: found by the
// mixin-stage lookup (before, through AlwaysVisible, it was not, and the field was "not supported")
[KdlConverter(typeof(Temperature))]
struct TemperatureKdl : IKdlConverter<Temperature>
{
	public static Result<void, KdlParseError> Read(KdlValueRef value, ref Temperature target)
	{
		if (!value.mValue.TryGetDouble(let celsius))
			return .Err(value.MakeError("expected a temperature"));
		target.mCelsius = celsius;
		return .Ok;
	}

	public static void Write(Temperature value, KdlValueWriter writer)
	{
		writer.Set(.Float(value.mCelsius, default));
	}
}

[KdlObject]
class Station
{
	public Temperature outside;
	public List<Temperature> history ~ delete _;
}
#endif

// FIXTURE OkSelfReference: OK
#if FIXTURE_OkSelfReference
// A type that holds itself: planned when its methods compile, so no type-initialization cycle
[KdlObject]
class TreeNode
{
	[KdlArgument(0)] public String name ~ delete _;
	public List<TreeNode> children ~ DeleteContainerAndItems!(_);
}
#endif

// FIXTURE OkGeneric: OK
#if FIXTURE_OkGeneric
[KdlObject]
class Box<T>
{
	public T value;
}

static class UseBox
{
	public static void Use()
	{
		let holder = scope Box<int32>();
		holder.value = 1;
	}
}
#endif

// FIXTURE Unsupported: KDL serialization does not support fields of type char8
#if FIXTURE_Unsupported
[KdlObject]
class Bad
{
	public char8 initial;
}
#endif

// FIXTURE ChildrenNeedsList: [KdlChildren] needs a List<T> field
#if FIXTURE_ChildrenNeedsList
[KdlObject]
class Bad
{
	[KdlChildren] public int32 count;
}
#endif

// FIXTURE ArgumentsNeedScalars: [KdlArguments] needs a List of scalars
#if FIXTURE_ArgumentsNeedScalars
[KdlObject]
class Inner
{
	public int32 x;
}

[KdlObject]
class Bad
{
	[KdlArguments] public List<Inner> items ~ DeleteContainerAndItems!(_);
}
#endif

// FIXTURE NegativeArgument: needs an index of 0 or more
#if FIXTURE_NegativeArgument
[KdlObject]
class Bad
{
	[KdlArgument(-1)] public int32 x;
}
#endif

// FIXTURE RepeatedArgument: argument 0 is mapped by both Fixtures.Bad.a and Fixtures.Bad.b
#if FIXTURE_RepeatedArgument
[KdlObject]
class Bad
{
	[KdlArgument(0)] public int32 a;
	[KdlArgument(0)] public int32 b;
}
#endif

// FIXTURE RepeatedPropertyInChain: the property `size` is mapped by both
#if FIXTURE_RepeatedPropertyInChain
[KdlObject]
class Base
{
	public int32 size;
}

[KdlObject]
class Bad : Base
{
	[KdlName("size")] public int32 other;
}
#endif

// FIXTURE TwoRoles: has more than one of [KdlArgument], [KdlArguments], [KdlChild] and [KdlChildren]
#if FIXTURE_TwoRoles
[KdlObject]
class Bad
{
	[KdlArgument(0), KdlChild] public int32 x;
}
#endif

// FIXTURE ControlCharacterInName: contains a control character
#if FIXTURE_ControlCharacterInName
[KdlObject]
class Bad
{
	[KdlName("a\tb")] public int32 x;
}
#endif

// FIXTURE TwoConverters: [KdlConverter] Both
#if FIXTURE_TwoConverters
[KdlConverter(typeof(Temperature))]
struct FirstKdl : IKdlConverter<Temperature>
{
	public static Result<void, KdlParseError> Read(KdlValueRef value, ref Temperature target) => .Ok;
	public static void Write(Temperature value, KdlValueWriter writer)
	{
	}
}

[KdlConverter(typeof(Temperature))]
struct SecondKdl : IKdlConverter<Temperature>
{
	public static Result<void, KdlParseError> Read(KdlValueRef value, ref Temperature target) => .Ok;
	public static void Write(Temperature value, KdlValueWriter writer)
	{
	}
}

[KdlObject]
class Bad
{
	public Temperature t;
}
#endif

// FIXTURE ChildrenWithoutTypes: [KdlChildren] found no [KdlObject] type
#if FIXTURE_ChildrenWithoutTypes
interface IShape
{
}

[KdlObject]
class Bad
{
	[KdlChildren] public List<IShape> shapes ~ delete _;
}
#endif

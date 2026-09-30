using System;
using System.Collections;
using KdlBeef;

namespace KdlTester;

/// The typed model of bench/compare/inputs/ui.kdl (see gen-inputs.py `ui`), for `-bench typed`:
/// windows of nested containers of widgets, lengths as `(px)` annotations.
struct Px
{
	public double Value;
}

[KdlConverter(typeof(Px))]
struct PxKdl : IKdlConverter<Px>
{
	public static Result<void, KdlParseError> Read(KdlValueRef value, ref Px target)
	{
		if (!value.mValue.TryGetDouble(let amount))
			return .Err(value.MakeError("expected a length such as (px)12"));
		target.Value = amount;
		return .Ok;
	}

	public static void Write(Px value, KdlValueWriter writer)
	{
		writer.Set(.Integer((int64)value.Value, default), "px");
	}
}

[KdlObject]
abstract class Widget
{
	/// Widgets in this subtree, and a sum of their numbers, to check every reader bound the same values.
	public abstract void Tally(ref int count, ref int64 sum);
}

[KdlObject]
abstract class Container : Widget
{
	public int32 Spacing;
	public Px Padding;
	[KdlChildren] public List<Widget> Items ~ DeleteContainerAndItems!(_);

	public override void Tally(ref int count, ref int64 sum)
	{
		count++;
		sum += Spacing + (int64)Padding.Value;
		if (Items != null)
		{
			for (let item in Items)
				item.Tally(ref count, ref sum);
		}
	}
}

[KdlObject] class Column : Container {}
[KdlObject] class Row : Container {}
[KdlObject] class Stack : Container {}

[KdlObject]
class Grid : Container
{
	public int32 Columns;

	public override void Tally(ref int count, ref int64 sum)
	{
		sum += Columns;
		base.Tally(ref count, ref sum);
	}
}

[KdlObject]
class Label : Widget
{
	[KdlArgument(0)] public String Text ~ delete _;
	public String Style ~ delete _;
	public Px Size;

	public override void Tally(ref int count, ref int64 sum)
	{
		count++;
		sum += Text.Length + (int64)Size.Value;
	}
}

[KdlObject]
class Button : Widget
{
	[KdlArgument(0)] public String Text ~ delete _;
	public String Id ~ delete _;
	public String OnClick ~ delete _;
	public bool Enabled;

	public override void Tally(ref int count, ref int64 sum)
	{
		count++;
		sum += Id.Length + (Enabled ? 1 : 0);
	}
}

[KdlObject]
class Textbox : Widget
{
	public String Id ~ delete _;
	public String Placeholder ~ delete _;
	public int32 MaxLength;

	public override void Tally(ref int count, ref int64 sum)
	{
		count++;
		sum += MaxLength;
	}
}

[KdlObject]
class Checkbox : Widget
{
	[KdlArgument(0)] public String Text ~ delete _;
	public bool Checked;

	public override void Tally(ref int count, ref int64 sum)
	{
		count++;
		sum += Checked ? 1 : 0;
	}
}

[KdlObject]
class Slider : Widget
{
	public int32 Min;
	public int32 Max;
	public double Value;
	public double Step;

	public override void Tally(ref int count, ref int64 sum)
	{
		count++;
		sum += Max + (int64)(Value * 1000);
	}
}

[KdlObject]
class Image : Widget
{
	public String Src ~ delete _;
	public Px Width;
	public Px Height;

	public override void Tally(ref int count, ref int64 sum)
	{
		count++;
		sum += (int64)(Width.Value + Height.Value);
	}
}

[KdlObject]
class Icon : Widget
{
	[KdlArgument(0)] public String Name ~ delete _;
	public uint32 Tint;

	public override void Tally(ref int count, ref int64 sum)
	{
		count++;
		sum += Tint;
	}
}

[KdlObject]
class Spacer : Widget
{
	[KdlArgument(0)] public Px Size;

	public override void Tally(ref int count, ref int64 sum)
	{
		count++;
		sum += (int64)Size.Value;
	}
}

[KdlObject]
class Window
{
	[KdlArgument(0)] public String Title ~ delete _;
	public int32 Width;
	public int32 Height;
	public bool Resizable;
	[KdlChildren] public List<Widget> Items ~ DeleteContainerAndItems!(_);
}

/// The whole document: its top-level `window` nodes.
[KdlObject]
class UiDocument
{
	public List<Window> Windows ~ DeleteContainerAndItems!(_);

	public void Tally(out int count, out int64 sum)
	{
		count = 0;
		sum = 0;
		for (let window in Windows)
		{
			count++;
			sum += window.Width + window.Height;
			for (let item in window.Items)
				item.Tally(ref count, ref sum);
		}
	}
}

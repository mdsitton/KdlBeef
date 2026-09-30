using System;
using System.Collections;
using KdlBeef;

namespace KdlBeef.Tests;

enum Align
{
	Start,
	Center,
	EndAligned
}

enum LengthUnit
{
	Px,
	Em
}

/// A length with its unit in the annotation: `(px)12`, `(em)2`.
struct Length
{
	public double Amount;
	public LengthUnit Unit;
}

[KdlConverter(typeof(Length))]
struct LengthKdl : IKdlConverter<Length>
{
	public static Result<void, KdlParseError> Read(KdlValueRef value, ref Length target)
	{
		if (!value.mValue.TryGetDouble(let amount))
			return .Err(value.MakeError("expected a length such as (px)12"));
		target.Amount = amount;
		if (!value.mHasAnnotation || value.mAnnotation == "px")
			target.Unit = .Px;
		else if (value.mAnnotation == "em")
			target.Unit = .Em;
		else
			return .Err(value.MakeError("expected the unit px or em"));
		return .Ok;
	}

	public static void Write(Length value, KdlValueWriter writer)
	{
		writer.Set(.Float(value.Amount, default), value.Unit == .Px ? "px" : "em");
	}
}

[KdlObject]
class Style
{
	public String Color ~ delete _;
	public float Opacity = 1;
}

[KdlObject]
class Widget
{
	public String Id ~ delete _;
}

[KdlObject]
class Button : Widget
{
	[KdlArgument(0)] public String Label ~ delete _;
	public String OnClick ~ delete _;
	public int32 Width = 80;
	public Length Height;
	public Align Align;
	public bool Enabled = true;
	public Style Style ~ delete _;
}

[KdlObject]
class Label : Widget
{
	[KdlArgument(0)] public String Text ~ delete _;
	[KdlArguments] public List<int32> Numbers ~ delete _;
}

[KdlObject]
class Panel : Widget
{
	public List<String> Tags ~ DeleteContainerAndItems!(_);
	[KdlChildren] public List<Widget> Items ~ DeleteContainerAndItems!(_);
}

[KdlObject]
class Item
{
	[KdlArgument(0)] public String Name ~ delete _;
	public uint64 Big;
}

[KdlObject]
class App
{
	public String Title ~ delete _;
	[KdlRequired] public int32 Version;
	public List<Item> Items ~ DeleteContainerAndItems!(_);
	[KdlAlias("root")] public Panel Main ~ delete _;
	[KdlIgnore] public int Scratch;
}

[KdlObject]
struct Point
{
	[KdlArgument(0)] public int32 X;
	[KdlArgument(1)] public int32 Y;
}

[KdlObject(Naming = .AsDeclared)]
class Shape
{
	public Point Origin;
	public List<Point> Points ~ delete _;
}

/// No destructors: everything a read creates belongs to the allocator it was given.
[KdlObject]
class Arena
{
	public String Name;
	public List<String> Tags;
	public Style Style;
}

/// [KdlObject] typed mapping: roles, conversions, errors, and in-place updates.
static class KdlSerializerTests
{
	[Test]
	public static void Structs_AsChildrenAndItems()
	{
		let shape = scope Shape();
		Test.Assert(KdlSerializer.Read("Origin 1 2\npoint 3 4\npoint 5 6", shape) case .Ok);
		Test.Assert(shape.Origin.X == 1 && shape.Origin.Y == 2 && shape.Points.Count == 2 && shape.Points[1].Y == 6);
		let text = scope String();
		Test.Assert(KdlSerializer.Write(shape, text) case .Ok);
		Test.Assert(text == "Origin 1 2\npoint 3 4\npoint 5 6\n", text);
	}

	[Test]
	public static void Allocator_OwnsWhatTheReadCreates()
	{
		let arena = scope BumpAllocator();
		let target = scope Arena();
		Test.Assert(KdlSerializer.Read("name \"n\"\ntags \"a\" \"b\"\nstyle color=blue", target, .(), arena) case .Ok);
		Test.Assert(target.Name == "n" && target.Tags.Count == 2 && target.Style.Color == "blue");
		// The Style's own `~ delete _` field would free arena memory: detach before the arena goes
		target.Style.Color = null;
	}

	const String cDocument = """
		// An app
		title "My app"
		version 2
		item "a" big=18446744073709551615
		item "b"
		main id=root {
		    tags "x" "y"
		    button "Save" id=save on-click=save width=120 height=(em)2 align=end-aligned enabled=#false {
		        style color=red opacity=0.5
		    }
		    label "Ready" 1 2 3
		    panel id=inner {
		        button "Nested"
		    }
		}

		""";

	[Test]
	public static void Read_EveryRole()
	{
		let app = scope App();
		if (KdlSerializer.Read(cDocument, app) case .Err(let error))
			Test.Assert(false, error.ToString(.. scope .()));
		Test.Assert(app.Title == "My app" && app.Version == 2);
		Test.Assert(app.Items.Count == 2 && app.Items[0].Name == "a" && app.Items[0].Big == uint64.MaxValue && app.Items[1].Big == 0);

		let main = app.Main;
		Test.Assert(main.Id == "root" && main.Tags.Count == 2 && main.Tags[1] == "y");
		Test.Assert(main.Items.Count == 3);
		let button = main.Items[0] as Button;
		Test.Assert(button != null && button.Label == "Save" && button.Id == "save" && button.OnClick == "save");
		Test.Assert(button.Width == 120 && button.Height.Amount == 2 && button.Height.Unit == .Em);
		Test.Assert(button.Align == .EndAligned && !button.Enabled);
		Test.Assert(button.Style.Color == "red" && button.Style.Opacity == 0.5f);
		let label = main.Items[1] as Label;
		Test.Assert(label != null && label.Text == "Ready" && label.Numbers.Count == 3 && label.Numbers[2] == 3);
		let inner = main.Items[2] as Panel;
		Test.Assert(inner != null && inner.Id == "inner" && inner.Items.Count == 1);
		Test.Assert((inner.Items[0] as Button).Label == "Nested" && (inner.Items[0] as Button).Width == 80);
	}

	[Test]
	public static void Write_ThenReadBack()
	{
		let app = scope App();
		app.Title = new .("Out");
		app.Version = 3;
		app.Items = new .();
		app.Items.Add(new Item() { Name = new .("one"), Big = 7 });
		app.Main = new Panel();
		app.Main.Items = new .();
		let button = new Button();
		button.Label = new .("Go");
		button.Height = .() { Amount = 12, Unit = .Px };
		button.Align = .Center;
		app.Main.Items.Add(button);
		let label = new Label();
		label.Text = new .("Hi");
		label.Numbers = new .() { 4, 5 };
		app.Main.Items.Add(label);

		let text = scope String();
		Test.Assert(KdlSerializer.Write(app, text) case .Ok);
		Test.Assert(text.Contains("title Out\nversion 3\nitem one big=7\nmain {\n"), text);
		Test.Assert(text.Contains("button Go align=center enabled=#true height=(px)12.0 width=80"), text);
		Test.Assert(text.Contains("label Hi 4 5"), text);

		let back = scope App();
		Test.Assert(KdlSerializer.Read(text, back) case .Ok);
		Test.Assert(back.Title == "Out" && back.Version == 3 && back.Items[0].Big == 7);
		Test.Assert((back.Main.Items[0] as Button).Height.Amount == 12 && (back.Main.Items[1] as Label).Numbers[1] == 5);
	}

	static void AssertReadError(StringView text, KdlErrorKind kind, StringView message, int line)
	{
		let app = scope App();
		switch (KdlSerializer.Read(text, app))
		{
		case .Ok:
			Test.Assert(false, scope $"`{text}` should fail");
		case .Err(let error):
			let shown = error.ToString(.. scope .());
			Test.Assert(error.mKind == kind && shown.Contains(message) && error.mLine == line, scope $"got `{shown}` ({error.mKind})");
		}
	}

	[Test]
	public static void Errors_AreLocated()
	{
		AssertReadError("title \"x\"", .MissingValue, "The child node `version` is required", 0);
		AssertReadError("version \"two\"", .WrongType, "1:9: version: expected integer, found string", 1);
		AssertReadError("version 2\nmain {\n    button width=99999999999\n}", .InvalidValue, "button: width: 99999999999 is outside the range", 3);
		AssertReadError("version 2\nmain {\n    slider 1\n}", .InvalidValue, "slider: unknown node: expected one of", 3);
		AssertReadError("version 2\nmain {\n    button align=middle\n}", .InvalidValue, "`middle` is not one of start, center, end-aligned", 3);
		AssertReadError("version 2\nmain {\n    button height=(cm)3\n}", .InvalidValue, "expected the unit px or em", 3);
	}

	[Test]
	public static void Update_KeepsTheDocumentsStyle()
	{
		let doc = scope KdlDocument();
		doc.ReadConfig.MetadataMode = .PreserveStyle;
		Test.Assert(doc.Read("// config\nversion 1 // bump me\nroot id=old { /* empty */ }\n") case .Ok);
		let app = scope App();
		Test.Assert(app.KdlRead(doc.Root) case .Ok);
		// Read through the alias; written back under the current name, in place
		Test.Assert(app.Main != null && app.Main.Id == "old");
		app.Version = 2;
		app.Main.Id.Set("new");
		Test.Assert(app.KdlWrite(doc.Root) case .Ok);
		let text = doc.Write(.. scope .());
		Test.Assert(text == "// config\nversion 2 // bump me\nmain id=new { /* empty */ }\n", text);
	}
}

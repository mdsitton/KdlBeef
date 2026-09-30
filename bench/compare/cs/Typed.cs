// Typed mode: KdlSharpBench typed <read|write> <file> <min-samples>
//
// Maps the UI markup (inputs/ui.kdl) to the C# types below with KdlSharp's reflection serializer
// (KdlSerializer + [KdlNode]/[KdlProperty]/[KdlIgnore]). KdlSharp binds every node's arguments and
// properties, but its mapping cannot express three things this input needs, so the harness supplies
// them around the library calls:
//   - a document with several top-level nodes (FromDocument/Deserialize bind only Nodes[0]);
//   - children that sit directly in a node's block (a List<T> member maps to a wrapper child node
//     named after the member, whose children are the items);
//   - polymorphic lists on read (DeserializeCollection binds every item as the declared element
//     type; an abstract Widget cannot be instantiated). Serialization does use the runtime type.
// So the harness parses with KdlDocument.Parse, dispatches each node by name to
// serializer.FromDocument<T> (one reused single-node document) and recurses into the children; the
// write side calls serializer.ToDocument per object, renames the node and nests the children.
using System.Reflection;
using KdlSharp;
using KdlSharp.Serialization;
using KdlSharp.Serialization.Metadata;
using KdlSharp.Settings;

abstract class Widget { }

[KdlNode("label")]
sealed class Label : Widget
{
	[KdlProperty(Position = 0)] public string Text { get; set; } = "";
	public string Style { get; set; } = "";
	public long Size { get; set; }
}

[KdlNode("button")]
sealed class Button : Widget
{
	[KdlProperty(Position = 0)] public string Text { get; set; } = "";
	public string Id { get; set; } = "";
	public string OnClick { get; set; } = "";
	public bool Enabled { get; set; }
}

[KdlNode("textbox")]
sealed class Textbox : Widget
{
	public string Id { get; set; } = "";
	public string Placeholder { get; set; } = "";
	public long MaxLength { get; set; }
}

[KdlNode("checkbox")]
sealed class Checkbox : Widget
{
	[KdlProperty(Position = 0)] public string Text { get; set; } = "";
	public bool Checked { get; set; }
}

[KdlNode("slider")]
sealed class Slider : Widget
{
	public long Min { get; set; }
	public long Max { get; set; }
	public double Value { get; set; }
	public double Step { get; set; }
}

[KdlNode("image")]
sealed class Image : Widget
{
	public string Src { get; set; } = "";
	public double Width { get; set; }
	public double Height { get; set; }
}

[KdlNode("icon")]
sealed class Icon : Widget
{
	[KdlProperty(Position = 0)] public string Name { get; set; } = "";
	public long Tint { get; set; }
}

[KdlNode("spacer")]
sealed class Spacer : Widget
{
	[KdlProperty(Position = 0)] public long Size { get; set; }
}

abstract class Container : Widget
{
	public long Spacing { get; set; }
	public long Padding { get; set; }
	[KdlIgnore] public List<Widget> Children { get; } = new();
}

[KdlNode("column")] sealed class Column : Container { }
[KdlNode("row")] sealed class Row : Container { }
[KdlNode("stack")] sealed class Stack : Container { }

[KdlNode("grid")]
sealed class Grid : Container
{
	public long Columns { get; set; }
}

[KdlNode("window")]
sealed class Window
{
	[KdlProperty(Position = 0)] public string Title { get; set; } = "";
	public long Width { get; set; }
	public long Height { get; set; }
	public bool Resizable { get; set; }
	[KdlIgnore] public List<Widget> Children { get; } = new();
}

sealed class UiMapper
{
	readonly KdlSerializer serializer = new(new KdlSerializerOptions
	{
		PropertyNamingPolicy = KdlNamingPolicy.KebabCase,
		TargetVersion = KdlVersion.V2,
	});
	readonly KdlParserSettings parserSettings = new() { TargetVersion = KdlVersion.V2 };
	readonly KdlFormatterSettings formatterSettings = new() { TargetVersion = KdlVersion.V2 };
	readonly KdlDocument scratch = new();
	readonly Dictionary<Type, string> nodeNames = new();

	public List<Window> Read(string text)
	{
		var doc = KdlDocument.Parse(text, parserSettings);
		var windows = new List<Window>(doc.Nodes.Count);
		foreach (var node in doc.Nodes)
		{
			if (node.Name != "window")
				throw new InvalidDataException($"unexpected top-level node '{node.Name}'");
			var window = Bind<Window>(node);
			ReadChildren(node, window.Children);
			windows.Add(window);
		}
		return windows;
	}

	void ReadChildren(KdlNode parent, List<Widget> into)
	{
		foreach (var node in parent.Children)
		{
			Widget widget = node.Name switch
			{
				"label" => Bind<Label>(node),
				"button" => Bind<Button>(node),
				"textbox" => Bind<Textbox>(node),
				"checkbox" => Bind<Checkbox>(node),
				"slider" => Bind<Slider>(node),
				"image" => Bind<Image>(node),
				"icon" => Bind<Icon>(node),
				"spacer" => Bind<Spacer>(node),
				"column" => Bind<Column>(node),
				"row" => Bind<Row>(node),
				"stack" => Bind<Stack>(node),
				"grid" => Bind<Grid>(node),
				_ => throw new InvalidDataException($"unexpected node '{node.Name}'"),
			};
			if (widget is Container container)
				ReadChildren(node, container.Children);
			into.Add(widget);
		}
	}

	// The library's typed binding of one node (its arguments and properties).
	T Bind<T>(KdlNode node)
	{
		scratch.Nodes.Clear();
		scratch.Nodes.Add(node);
		return serializer.FromDocument<T>(scratch);
	}

	public string Write(List<Window> windows)
	{
		var doc = new KdlDocument();
		foreach (var window in windows)
		{
			var node = ToNode(window);
			WriteChildren(node, window.Children);
			doc.Nodes.Add(node);
		}
		return doc.ToKdlString(formatterSettings);
	}

	void WriteChildren(KdlNode parent, List<Widget> children)
	{
		foreach (var child in children)
		{
			var node = ToNode(child);
			if (child is Container container)
				WriteChildren(node, container.Children);
			parent.AddChild(node);
		}
	}

	// The library's typed serialization of one object; the root node is named by the options, so
	// rename it to the type's [KdlNode] name.
	KdlNode ToNode(object value)
	{
		var node = serializer.ToDocument(value).Nodes[0];
		node.Name = NodeName(value.GetType());
		return node;
	}

	string NodeName(Type type)
	{
		if (!nodeNames.TryGetValue(type, out var name))
			nodeNames[type] = name = type.GetCustomAttribute<KdlNodeAttribute>()!.Name;
		return name;
	}
}

static class TypedBench
{
	public static int Run(string[] args, Func<int, Action, (double MedianNs, int Samples, bool Converged)> measure)
	{
		if (args.Length < 4 || (args[1] != "read" && args[1] != "write"))
		{
			Console.Error.WriteLine("usage: KdlSharpBench typed <read|write> <file> <min-samples>");
			return 2;
		}
		string text = File.ReadAllText(args[2]);
		int minSamples = int.Parse(args[3]);
		var mapper = new UiMapper();

		List<Window> windows;
		string output;
		try
		{
			windows = mapper.Read(text);
			var (count, sum) = Check(windows);
			Console.WriteLine($"check: {count} {sum}");
			output = mapper.Write(windows);
			var (count2, sum2) = Check(mapper.Read(output));
			Console.WriteLine($"re-read check: {count2} {sum2}");
		}
		catch (Exception e)
		{
			Console.Error.WriteLine($"error: {e.GetType().Name}: {e.Message}");
			return 1;
		}

		long bytes = System.Text.Encoding.UTF8.GetByteCount(text);
		(double median, int samples, bool converged) result;
		if (args[1] == "read")
			result = measure(minSamples, () => GC.KeepAlive(mapper.Read(text)));
		else
		{
			result = measure(minSamples, () => output = mapper.Write(windows));
			bytes = System.Text.Encoding.UTF8.GetByteCount(output);
		}
		double ms = result.median / 1e6;
		Console.WriteLine($"{ms:F3} ms/op {bytes / 1048576.0 / (ms / 1000.0):F1} MB/s (n={result.samples}, {(result.converged ? "converged" : "capped")})");
		return 0;
	}

	static (long Count, long Sum) Check(List<Window> windows)
	{
		long count = 0, sum = 0;
		foreach (var w in windows)
		{
			count++;
			sum += w.Width + w.Height;
			Check(w.Children, ref count, ref sum);
		}
		return (count, sum);
	}

	static void Check(List<Widget> widgets, ref long count, ref long sum)
	{
		foreach (var widget in widgets)
		{
			count++;
			switch (widget)
			{
				case Grid g: sum += g.Spacing + g.Padding + g.Columns; Check(g.Children, ref count, ref sum); break;
				case Container c: sum += c.Spacing + c.Padding; Check(c.Children, ref count, ref sum); break;
				case Label l: sum += System.Text.Encoding.UTF8.GetByteCount(l.Text) + l.Size; break;
				case Button b: sum += System.Text.Encoding.UTF8.GetByteCount(b.Id) + (b.Enabled ? 1 : 0); break;
				case Textbox t: sum += t.MaxLength; break;
				case Checkbox cb: sum += cb.Checked ? 1 : 0; break;
				case Slider s: sum += s.Max + (long)(s.Value * 1000.0); break;
				case Image i: sum += (long)(i.Width + i.Height); break;
				case Icon ic: sum += ic.Tint; break;
				case Spacer sp: sum += sp.Size; break;
			}
		}
	}
}

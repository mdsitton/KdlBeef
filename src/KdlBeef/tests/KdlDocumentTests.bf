using System;
using KdlBeef;

namespace KdlBeef;

/// KdlDocument: building from the reader, navigation, lookups, handle validity, canonical writing.
static class KdlDocumentTests
{
	static KdlDocument ReadOrFail(KdlDocument doc, StringView text)
	{
		if (doc.Read(text) case .Err(let error))
			Test.Assert(false, scope $"`{text}` failed: {error}");
		return doc;
	}

	[Test]
	public static void Navigation_ParentsChildrenAndSiblings()
	{
		let doc = ReadOrFail(scope KdlDocument(), "window {\n    panel {\n        button\n        label\n    }\n    footer\n}\nstatus");
		Test.Assert(doc.Nodes.Count == 2);
		let window = doc.Nodes.First;
		Test.Assert(window.Name == "window" && window.Depth == 0 && !window.Parent.IsValid);
		Test.Assert(window.ChildCount == 2 && window.HasChildren);
		let panel = window.FirstChild;
		let footer = window.LastChild;
		Test.Assert(panel.Name == "panel" && footer.Name == "footer");
		Test.Assert(panel.NextSibling == footer && footer.PreviousSibling == panel);
		Test.Assert(!panel.PreviousSibling.IsValid && !footer.NextSibling.IsValid);
		let label = panel.Children.Find("label");
		Test.Assert(label.IsValid && label.Depth == 2 && label.Parent == panel && label.Parent.Parent == window);
		Test.Assert(!panel.Children.Find("missing").IsValid);
		Test.Assert(doc.Nodes.Last.Name == "status" && !doc.Nodes.Last.HasChildren);

		int count = 0;
		for (let child in panel.Children)
		{
			Test.Assert(child.Parent == panel);
			count++;
		}
		Test.Assert(count == 2);

		// IDs name the same node until the document changes
		Test.Assert(doc.GetNode(label.Id) == label);
		Test.Assert(!doc.GetNode(.Invalid).IsValid);
	}

	[Test]
	public static void Entries_ArgumentsPropertiesAndAnnotations()
	{
		let doc = ReadOrFail(scope KdlDocument(), "(ui)button \"Save\" id=save width=(px)120 2.5 id=\"save-2\" #true");
		let button = doc.Nodes.First;
		Test.Assert(button.HasAnnotation && button.Annotation == "ui");
		Test.Assert(button.Entries.Count == 6 && button.ArgumentCount == 3);

		Test.Assert(button.TryGetArgument(0, let label) && label case .String("Save"));
		Test.Assert(button.TryGetArgument(1, let ratio));
		Test.Assert(ratio.TryGetDouble(let r));
		Test.Assert(r == 2.5);
		Test.Assert(button.TryGetArgument(2, let flag) && flag case .Bool(true));
		Test.Assert(!button.TryGetArgument(3, ?));

		// The last duplicate wins
		Test.Assert(button.TryGetProperty("id", let id) && id case .String("save-2"));
		Test.Assert(button.TryGetProperty("width", let width));
		Test.Assert(width.TryGetInt64(let w));
		Test.Assert(w == 120);
		Test.Assert(!button.TryGetProperty("height", ?) && !button.HasProperty("height"));

		let widthEntry = button.Entries[2];
		Test.Assert(widthEntry.IsProperty && widthEntry.Key == "width" && widthEntry.HasAnnotation && widthEntry.Annotation == "px");
		Test.Assert(button.Entries[0].IsArgument && !button.Entries[0].HasAnnotation);

		int properties = 0;
		for (let entry in button.Entries)
		{
			if (entry.IsProperty)
				properties++;
		}
		Test.Assert(properties == 3);
	}

	[Test]
	public static void Values_OwnedByTheDocument()
	{
		let doc = scope KdlDocument();
		{
			let text = scope String("n \"a\\tb\" raw=#\"x\"# big=0xABCDEF0123456789abcdef f=1.0e10 i=0xFF");
			ReadOrFail(doc, text);
			// The input is gone; everything must live in the document
			text.Clear();
			text.Append('?', 64);
		}
		let n = doc.Nodes.First;
		Test.Assert(n.TryGetArgument(0, let a) && a case .String("a\tb"));
		Test.Assert(n.TryGetProperty("raw", let raw) && raw case .String("x"));
		Test.Assert(n.TryGetProperty("big", let big) && big case .BigInteger("0xABCDEF0123456789abcdef"));
		Test.Assert(n.TryGetProperty("f", let f) && f case .Float(1e10, "1.0e10"));
		// A plain read writes integers canonically, so it keeps no integer text
		Test.Assert(n.TryGetProperty("i", let i));
		Test.Assert(i case .Integer(let iValue, let iText) && iValue == 255 && iText.IsEmpty);

		let output = doc.Write(.. scope .());
		Test.Assert(output == "n \"a\\tb\" big=207698809136909011942886895 f=1.0E+10 i=255 raw=x\n");
	}

	[Test]
	public static void Handles_InvalidAfterReadOrClear()
	{
		let doc = ReadOrFail(scope KdlDocument(), "a { b }");
		let a = doc.Nodes.First;
		let b = a.FirstChild;
		Test.Assert(a.IsValid && b.IsValid);

		ReadOrFail(doc, "c { d }");
		// Same IDs, new document content: the old handles know
		Test.Assert(!a.IsValid && !b.IsValid);
		Test.Assert(doc.Nodes.First.Name == "c");
		Test.Assert(doc.GetNode(a.Id).Name == "c");

		doc.Clear();
		Test.Assert(doc.Nodes.IsEmpty && doc.Nodes.Count == 0 && !doc.Nodes.First.IsValid);
		Test.Assert(doc.Write(.. scope .()) == "\n");
	}

	[Test]
	public static void Read_ErrorLeavesTheDocumentEmpty()
	{
		let doc = ReadOrFail(scope KdlDocument(), "a 1");
		Test.Assert(doc.Read("a 1\nb \"unterminated") case .Err(let error) && error.mKind == .UnterminatedString && error.mLine == 2);
		Test.Assert(doc.Nodes.IsEmpty);

		Test.Assert(doc.ReadFile("/nonexistent/file.kdl") case .Err(let ioError) && ioError.mKind == .IoError);
		Test.Assert(ioError.mSource == "/nonexistent/file.kdl");
		Test.Assert(ioError.ToString(.. scope .()) == "/nonexistent/file.kdl: Cannot read the file");
	}

	[Test]
	public static void Write_MatchesTheEventFormatter()
	{
		StringView input = """
			/- kdl-version 2
			// A UI document
			(ui)window title="Main" width=800 title="Main window" {
			    panel layout=row {
			        button "Save" on-click=save
			        /- button "Cancel"
			        label "Ready" fg=(color)0xFF00FF
			    }
			    footer {}
			}
			status 1 2 3 {
			    /- skipped
			}
			""";
		let doc = ReadOrFail(scope KdlDocument(), input);
		let fromDocument = doc.Write(.. scope .());
		let fromEvents = scope String();
		Test.Assert(KdlCanonical.Format(input, fromEvents) case .Ok);
		Test.Assert(fromDocument == fromEvents, scope $"document:\n{fromDocument}\nevents:\n{fromEvents}");
		Test.Assert(fromDocument == """
			(ui)window title="Main window" width=800 {
			    panel layout=row {
			        button Save on-click=save
			        label Ready fg=(color)16711935
			    }
			    footer
			}
			status 1 2 3

			""");
	}

	[Test]
	public static void Lookup_TypedValues()
	{
		let doc = ReadOrFail(scope KdlDocument(), "button \"Save\" 3 1.5 #true width=120 scale=2 on-click=save enabled=#false width=140");
		let button = doc.Root.Find("button");

		// Properties: the last duplicate wins; integers read as doubles; wrong types fail
		Test.Assert(button.TryGetInt64("width", let width) && width == 140);
		Test.Assert(button.TryGetString("on-click", let handler) && handler == "save");
		Test.Assert(button.TryGetBool("enabled", let enabled) && !enabled);
		Test.Assert(button.TryGetDouble("scale", let scale) && scale == 2);
		Test.Assert(!button.TryGetString("width", ?) && !button.TryGetInt64("on-click", ?) && !button.TryGetBool("missing", ?));
		Test.Assert(button.GetInt64("width", 80) == 140 && button.GetInt64("height", 80) == 80);
		Test.Assert(button.GetString("on-click") == "save" && button.GetString("width", "none") == "none");
		Test.Assert(button.GetBool("enabled", true) == false && button.GetDouble("missing", 0.5) == 0.5);

		// Arguments by position
		Test.Assert(button.GetString(0) == "Save" && button.GetInt64(1) == 3 && button.GetDouble(2) == 1.5);
		Test.Assert(button.TryGetBool(3, let flag) && flag);
		Test.Assert(!button.TryGetInt64(0, ?) && !button.TryGetString(4, ?) && button.GetInt64(9, -1) == -1);
	}

	[Test]
	public static void Lookup_FindChains()
	{
		let doc = ReadOrFail(scope KdlDocument(), "window {\n    grid columns=3 {\n        button \"A\"\n    }\n}");
		Test.Assert(doc.Root.Find("window").Find("grid").GetInt64("columns", 1) == 3);
		Test.Assert(doc.Root.Find("window").Find("grid").Find("button").GetString(0) == "A");

		// A missing link gives the empty handle, and every later lookup its fallback
		let missing = doc.Root.Find("dialog").Find("grid");
		Test.Assert(!missing.IsValid);
		Test.Assert(missing.GetInt64("columns", 1) == 1 && missing.GetString(0, "none") == "none");
		Test.Assert(!missing.TryGetBool("visible", ?) && !missing.Find("button").IsValid);
	}

	[Test]
	public static void Lookup_NamedAndDescendants()
	{
		StringView input = """
			window {
			    row {
			        button "A"
			        label "x"
			        button "B"
			        column {
			            button "C"
			            slider
			        }
			    }
			    button "D"
			}
			status
			""";
		let doc = ReadOrFail(scope KdlDocument(), input);
		let window = doc.Root.Find("window");
		let row = window.Find("row");

		// Children with one name, in order
		let names = scope String();
		for (let button in row.Children.Named("button"))
			names.Append(button.GetString(0));
		Test.Assert(names == "AB");
		Test.Assert(row.Children.Named("button").Count == 2 && row.Children.Named("label").First.GetString(0) == "x");
		Test.Assert(row.Children.Named("missing").Count == 0 && !row.Children.Named("missing").First.IsValid);

		// The whole subtree, depth first in document order
		let order = scope String();
		for (let node in window.Descendants)
			order.AppendF("{} ", node.Name);
		Test.Assert(order == "row button label button column button slider button ", order);
		Test.Assert(window.Descendants.Count == 8 && doc.Root.Descendants.Count == 10);

		names.Clear();
		for (let button in window.Descendants.Named("button"))
			names.Append(button.GetString(0));
		Test.Assert(names == "ABCD");
		Test.Assert(window.Descendants.Find("slider").Parent.Name == "column");
		Test.Assert(window.Descendants.Named("button").First.GetString(0) == "A");
		Test.Assert(!window.Descendants.Find("status").IsValid && doc.Root.Descendants.Find("status").IsValid);
		Test.Assert(doc.Root.Find("status").Descendants.Count == 0 && !doc.Root.Find("status").Descendants.First.IsValid);

		// Removing the current node while walking Named siblings is allowed
		for (let button in row.Children.Named("button"))
			button.Remove();
		Test.Assert(row.Children.Named("button").Count == 0 && row.ChildCount == 2);
	}
}

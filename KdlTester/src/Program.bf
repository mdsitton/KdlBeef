using System;
using System.Collections;
using System.IO;
using KdlBeef;

namespace KdlTester;

/// Command-line harness for the official test suite and benchmarks (see docs/plan.md).
///
///   KdlTester [-events] [file]   read KDL from `file` (or stdin) and print it in the test suite's
///                                canonical form; exit 1 with the error on stderr if it is invalid.
///                                By default through a KdlDocument; `-events` formats straight from
///                                the KdlReader's events (KdlCanonical.Format)
class Program
{
	public static int Main(String[] args)
	{
		bool events = false;
		String path = null;
		for (let arg in args)
		{
			if (arg == "-events")
				events = true;
			else if (arg.StartsWith('-'))
			{
				Console.Error.WriteLine($"KdlTester: unknown option {arg}");
				return 2;
			}
			else
				path = arg;
		}

		let input = scope String();
		if (path != null)
		{
			let bytes = scope List<uint8>();
			if (File.ReadAll(path, bytes) case .Err)
			{
				Console.Error.WriteLine($"KdlTester: cannot read {path}");
				return 2;
			}
			input.Append((char8*)bytes.Ptr, bytes.Count);
		}
		else if (ReadStdin(input) case .Err)
		{
			Console.Error.WriteLine("KdlTester: cannot read stdin");
			return 2;
		}

		let output = scope String();
		if (events)
		{
			if (KdlCanonical.Format(input, output) case .Err(let error))
			{
				Console.Error.WriteLine(error.ToString(.. scope .()));
				return 1;
			}
		}
		else
		{
			let doc = scope KdlDocument();
			if (doc.Read(input) case .Err(let error))
			{
				Console.Error.WriteLine(error.ToString(.. scope .()));
				return 1;
			}
			doc.Write(output);
		}
		Console.Out.Write(output);
		Console.Out.Flush();
		return 0;
	}

	/// Reads stdin as raw bytes (a BOM is kept: the reader must see it).
	static Result<void> ReadStdin(String output)
	{
		let stream = Console.In.BaseStream;
		uint8[65536] chunk = ?;
		while (true)
		{
			switch (stream.TryRead(.(&chunk, chunk.Count)))
			{
			case .Ok(let count):
				if (count == 0)
					return .Ok;
				output.Append((char8*)&chunk, count);
			case .Err:
				return .Err;
			}
		}
	}
}

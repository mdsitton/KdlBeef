using System;
using System.Collections;
using System.IO;
using KdlBeef;

namespace KdlTester;

/// Command-line harness for the official test suite and benchmarks (see docs/plan.md).
///
///   KdlTester [file]        read KDL from `file` (or stdin) and print it in the test suite's canonical
///                           form; exit 1 with the error on stderr if it is invalid
class Program
{
	public static int Main(String[] args)
	{
		let input = scope String();
		if (args.Count > 0)
		{
			let bytes = scope List<uint8>();
			if (File.ReadAll(args[0], bytes) case .Err)
			{
				Console.Error.WriteLine($"KdlTester: cannot read {args[0]}");
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
		if (KdlCanonical.Format(input, output) case .Err(let error))
		{
			Console.Error.WriteLine(error.ToString(.. scope .()));
			return 1;
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

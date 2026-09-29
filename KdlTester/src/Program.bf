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
///   KdlTester -stream N [file]   the same through a document read from a Stream with an N-byte buffer
///   KdlTester -collect [file]    through a document read with CollectErrors: every error, one per line
///   KdlTester -bench <parse|events|write> <file> <min-samples>
///                                the bench/compare harness (see bench/compare/run.sh): prints
///                                `nodes: N`, then the median time of a document read (parse), a
///                                pass of the reader over every event (events), or a canonical write
///                                of the document (write, MB/s of output)
///   KdlTester -bench-events <parse|write> <file> <min-samples>
///                                the event reader's row in run.sh: parse is the events pass, write
///                                exits 3 (n/a)
class Program
{
	public static int Main(String[] args)
	{
		if (args.Count > 0 && (args[0] == "-bench" || args[0] == "-bench-events"))
		{
			int minSamples = 0;
			if (args.Count >= 4 && int.Parse(args[3]) case .Ok(let parsed))
				minSamples = parsed;
			if (minSamples < 1)
			{
				Console.Error.WriteLine("usage: KdlTester -bench <parse|events|write> <file> <min-samples>");
				return 2;
			}
			StringView mode = args[1];
			if (args[0] == "-bench-events")
			{
				// run.sh's row for the event reader: it parses, and has no writer of its own
				if (mode == "write")
					return 3;
				mode = "events";
			}
			return Bench(mode, args[2], minSamples);
		}

		bool events = false;
		bool collect = false;
		int streamBuffer = 0;
		String path = null;
		for (int i < args.Count)
		{
			let arg = args[i];
			if (arg == "-events")
				events = true;
			else if (arg == "-collect")
				collect = true;
			else if (arg == "-stream" && i + 1 < args.Count && int.Parse(args[i + 1]) case .Ok(let size))
			{
				streamBuffer = size;
				i++;
			}
			else if (arg.StartsWith('-'))
			{
				Console.Error.WriteLine($"KdlTester: unknown option {arg}");
				return 2;
			}
			else
				path = arg;
		}

		if (streamBuffer > 0)
		{
			// Through a Stream: the file, or stdin
			var config = KdlReadConfig();
			config.StreamBufferBytes = streamBuffer;
			let doc = scope KdlDocument();
			Result<void, KdlParseError> result;
			if (path != null)
			{
				let file = scope FileStream();
				if (file.Open(path, .Read, .Read) case .Err)
				{
					Console.Error.WriteLine($"KdlTester: cannot read {path}");
					return 2;
				}
				result = doc.Read(file, config);
			}
			else
				result = doc.Read(Console.In.BaseStream, config);
			if (result case .Err(let error))
			{
				Console.Error.WriteLine(error.ToString(.. scope .()));
				return 1;
			}
			let output = doc.Write(.. scope .());
			Console.Out.Write(output);
			Console.Out.Flush();
			return 0;
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
			doc.ReadConfig.CollectErrors = collect;
			if (doc.Read(input) case .Err(let error))
			{
				if (!collect)
					Console.Error.WriteLine(error.ToString(.. scope .()));
				for (let collected in doc.Errors)
					Console.Error.WriteLine(collected.ToString(.. scope .()));
				return 1;
			}
			doc.Write(output);
		}
		Console.Out.Write(output);
		Console.Out.Flush();
		return 0;
	}

	static int Bench(StringView mode, StringView path, int minSamples)
	{
		let bytes = scope List<uint8>();
		if (File.ReadAll(path, bytes) case .Err)
		{
			Console.Error.WriteLine($"cannot open {path}");
			return 2;
		}
		StringView input = .((char8*)bytes.Ptr, bytes.Count);
		let doc = scope KdlDocument();
		if (doc.Read(input) case .Err(let error))
		{
			Console.Error.WriteLine($"parse error: {error}");
			return 1;
		}
		Console.WriteLine($"nodes: {CountNodes(doc.Nodes)}");
		Console.Out.Flush();

		switch (mode)
		{
		case "parse":
			// The document is reused, as an application re-reading a file would (its arena pools stay)
			PrintResult(Measure(minSamples, scope () => { doc.Read(input).IgnoreError(); }), input.Length);
		case "events":
			let reader = scope KdlReader();
			PrintResult(Measure(minSamples, scope () =>
				{
					reader.Reset(input);
					while (reader.Next() case .Ok(let event) && event != .EndOfDocument) {}
				}), input.Length);
		case "write":
			let output = scope String();
			PrintResult(Measure(minSamples, scope () => { output.Clear(); doc.Write(output); }), output.Length);
		default:
			Console.Error.WriteLine($"unknown bench mode {mode}");
			return 2;
		}
		return 0;
	}

	static int CountNodes(KdlNodeList nodes)
	{
		int count = 0;
		for (let node in nodes)
			count += 1 + CountNodes(node.Children);
		return count;
	}

	struct Measurement
	{
		public double mMedianNs;
		public int mSamples;
		public bool mConverged;
	}

	/// The rule shared by every harness in bench/compare (see run.sh): warm up for at least 1 s (at least
	/// one run), then time single runs until at least `minSamples` were taken and at least 60% of them lie
	/// within ±10% of their median ("converged"), or 10 s of measuring or 1000 samples have passed. The
	/// median sample is reported. (TomlTester's Measure.)
	static Measurement Measure(int minSamples, delegate void() op)
	{
		let watch = scope System.Diagnostics.Stopwatch(true);
		repeat
			op();
		while (watch.Elapsed.TotalSeconds < 1);

		let samples = scope List<double>();
		let sorted = scope List<double>();
		watch.Restart();
		while (true)
		{
			let t0 = watch.Elapsed.Ticks;
			op();
			samples.Add((watch.Elapsed.Ticks - t0) * 100.0); // TimeSpan ticks are 100 ns
			sorted.Clear();
			sorted.AddRange(samples);
			sorted.Sort(scope (a, b) => a <=> b);
			int n = sorted.Count;
			double median = (n % 2 == 1) ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
			if (n >= minSamples)
			{
				int within = 0;
				for (let s in samples)
				{
					if (s >= median * 0.9 && s <= median * 1.1)
						within++;
				}
				if (within >= 0.6 * n)
					return .() { mMedianNs = median, mSamples = n, mConverged = true };
			}
			if (n >= 1000 || watch.Elapsed.TotalSeconds >= 10)
				return .() { mMedianNs = median, mSamples = n, mConverged = false };
		}
	}

	/// "<ms> ms/op <MB/s> MB/s (n=<samples>, converged|capped)", as bench/compare/c/bench.h prints it.
	static void PrintResult(Measurement m, int bytes)
	{
		double ms = m.mMedianNs / 1e6;
		double mbPerSecond = (double)bytes / 1048576.0 / (ms / 1000.0);
		Console.WriteLine($"{ms:F3} ms/op {mbPerSecond:F1} MB/s (n={m.mSamples}, {m.mConverged ? "converged" : "capped"})");
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

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
///   KdlTester -preserve [file]   through a document read with PreserveStyle: the input as it was
///                                (combines with -stream N and -collect)
///   KdlTester -bench <parse|events|write> <file> <min-samples>
///                                the bench/compare harness (see bench/compare/run.sh): prints
///                                `nodes: N`, then the median time of a document read (parse), a
///                                pass of the reader over every event (events), or a canonical write
///                                of the document (write, MB/s of output)
///   KdlTester -bench-events <parse|write> <file> <min-samples>
///                                the event reader's row in run.sh: parse is the events pass, write
///                                exits 3 (n/a)
///   KdlTester -bench-lookup [min-samples]
///                                ns per property lookup on nodes of 4 to 64 properties
class Program
{
	public static int Main(String[] args)
	{
		if (args.Count > 0 && args[0] == "-bench-lookup")
		{
			int samples = 5;
			if (args.Count >= 2 && int.Parse(args[1]) case .Ok(let parsed))
				samples = parsed;
			BenchLookup(samples);
			return 0;
		}
		if (args.Count > 0 && args[0] == "-bench-typed")
		{
			// bench/compare/typed.sh: one operation per run
			int samples = 0;
			if (args.Count >= 4 && int.Parse(args[3]) case .Ok(let parsed))
				samples = parsed;
			if (samples < 1)
			{
				Console.Error.WriteLine("usage: KdlTester -bench-typed <read|read-plain|write> <file> <min-samples>");
				return 2;
			}
			sTypedMode = args[1];
			return Bench("typed", args[2], samples);
		}
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
		bool preserve = false;
		int streamBuffer = 0;
		String path = null;
		for (int i < args.Count)
		{
			let arg = args[i];
			if (arg == "-events")
				events = true;
			else if (arg == "-collect")
				collect = true;
			else if (arg == "-preserve")
				preserve = true;
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
			if (preserve)
				config.MetadataMode = .PreserveStyle;
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
			if (preserve)
				doc.ReadConfig.MetadataMode = .PreserveStyle;
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
		case "typed":
			return BenchTyped(input, doc, minSamples);
		case "preserve":
			// A PreserveStyle read, then writing it back
			var config = KdlReadConfig();
			config.MetadataMode = .PreserveStyle;
			PrintResult(Measure(minSamples, scope () => { doc.Read(input, config).IgnoreError(); }), input.Length);
			let output = scope String();
			PrintResult(Measure(minSamples, scope () => { output.Clear(); doc.Write(output); }), output.Length);
		default:
			Console.Error.WriteLine($"unknown bench mode {mode}");
			return 2;
		}
		return 0;
	}

	/// ui.kdl into the [KdlObject] types of TypedUi.bf: reading (parse and bind, and binding alone from
	/// a parsed document) and writing (a new document from the objects, then its text).
	/// Property lookups (plan.md §4.3: the index waits for this to show a need): ns per TryGetProperty
	/// that finds its key (keys picked at random) and per one that does not, on 1,000 nodes of 4 to 64
	/// properties each, under the measurement rule of run.sh.
	static void BenchLookup(int minSamples)
	{
		const int cLookups = 100000;
		for (let count in int[](4, 8, 16, 32, 64))
		{
			let text = scope String();
			for (int n < 1000)
			{
				text.Append("node");
				for (int p < count)
					text.AppendF(" property-{}={}", p, p);
				text.Append('\n');
			}
			let doc = scope KdlDocument();
			if (doc.Read(text) case .Err)
				return;
			let keys = scope List<String>();
			defer { ClearAndDeleteItems!(keys); }
			for (int p < count)
				keys.Add(new $"property-{p}");
			let nodes = scope List<KdlNode>();
			for (let node in doc.Nodes)
				nodes.Add(node);
			let random = scope Random(1);
			let order = scope List<int>();
			for (int i < cLookups)
				order.Add(random.Next(0, count));

			int64 sum = 0;
			let hit = Measure(minSamples, scope [&]() =>
			{
				for (int i < cLookups)
				{
					if (nodes[i % nodes.Count].TryGetProperty(keys[order[i]], let value) && value case .Integer(let v, ?))
						sum += v;
				}
			});
			let miss = Measure(minSamples, scope [&]() =>
			{
				for (int i < cLookups)
				{
					if (nodes[i % nodes.Count].HasProperty("absent"))
						sum++;
				}
			});
			Console.WriteLine($"{count,3} properties: found {hit.mMedianNs / cLookups:F1} ns, absent {miss.mMedianNs / cLookups:F1} ns per lookup (check {sum})");
		}
	}

	static int BenchTyped(StringView input, KdlDocument doc, int minSamples)
	{
		let ui = scope UiDocument();
		if (ui.KdlRead(doc.Root) case .Err(let error))
		{
			Console.Error.WriteLine($"bind error: {error}");
			return 1;
		}
		ui.Tally(let count, let sum);
		Console.WriteLine($"check: {count} {sum}");

		// The check again after writing and re-reading, so the writer is checked too
		let written = scope String();
		let fresh = scope KdlDocument();
		ui.KdlWrite(fresh.Root).IgnoreError();
		fresh.Write(written);
		let again = scope UiDocument();
		KdlSerializer.Read(written, again).IgnoreError();
		again.Tally(let count2, let sum2);
		Console.WriteLine($"re-read check: {count2} {sum2}");

		StringView mode = sTypedMode;
		if (mode.IsEmpty || mode == "read")
		{
			// KdlSerializer.Read: the document records positions, for located errors
			Console.Write("read (parse + bind): ");
			PrintResult(Measure(minSamples, scope () =>
				{
					let target = scope UiDocument();
					KdlSerializer.Read(input, target).IgnoreError();
				}), input.Length);
		}
		if (mode.IsEmpty || mode == "read-plain")
		{
			// A document without positions, then the bind (errors then carry no line numbers)
			Console.Write("read, no positions:  ");
			PrintResult(Measure(minSamples, scope () =>
				{
					doc.Read(input).IgnoreError();
					let target = scope UiDocument();
					target.KdlRead(doc.Root).IgnoreError();
				}), input.Length);
		}
		if (mode.IsEmpty)
		{
			Console.Write("bind only:           ");
			PrintResult(Measure(minSamples, scope () =>
				{
					let target = scope UiDocument();
					target.KdlRead(doc.Root).IgnoreError();
				}), input.Length);
		}
		if (mode.IsEmpty || mode == "write")
		{
			let output = scope String();
			Console.Write("write (build + text): ");
			PrintResult(Measure(minSamples, scope () =>
				{
					output.Clear();
					KdlSerializer.Write(ui, output).IgnoreError();
				}), output.Length);
		}
		return 0;
	}

	/// `-bench-typed`'s operation (empty: all of them, for `-bench typed`).
	static String sTypedMode = "";

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

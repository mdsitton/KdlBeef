// C# KDL benchmark: KdlSharpBench <parse|write> <file> <min-samples>
//                   KdlSharpBench typed <read|write> <file> <min-samples>   (see Typed.cs)
// KdlSharp: KdlDocument.Parse (KDL v2 by default) into its document; write is ToKdlString of the
// document parsed once. Prints the node count as a check line. Timings follow the shared rule (see
// Measure and ../run.sh); the 1 s warm-up also lets the JIT compile the parser.
using System.Diagnostics;
using KdlSharp;

if (args.Length >= 1 && args[0] == "typed")
	return TypedBench.Run(args, Measure);

if (args.Length < 3)
{
	Console.Error.WriteLine("usage: KdlSharpBench <parse|write|typed <read|write>> <file> <min-samples>");
	return 2;
}

string text = File.ReadAllText(args[1]);
int minSamples = int.Parse(args[2]);
KdlDocument doc;
try
{
	doc = KdlDocument.Parse(text);
}
catch (Exception e)
{
	Console.Error.WriteLine($"parse error: {e.Message}");
	return 1;
}
Console.WriteLine($"nodes: {Count(doc.Nodes)}");

long bytes = System.Text.Encoding.UTF8.GetByteCount(text);
(double median, int samples, bool converged) result;
if (args[0] == "parse")
	result = Measure(minSamples, () => GC.KeepAlive(KdlDocument.Parse(text)));
else
{
	string output = "";
	result = Measure(minSamples, () => output = doc.ToKdlString());
	bytes = System.Text.Encoding.UTF8.GetByteCount(output);
}
double ms = result.median / 1e6;
Console.WriteLine($"{ms:F3} ms/op {bytes / 1048576.0 / (ms / 1000.0):F1} MB/s (n={result.samples}, {(result.converged ? "converged" : "capped")})");
return 0;

static long Count(IList<KdlNode> nodes) => nodes.Sum(n => 1 + Count(n.Children));

// Warm up for at least 1 s (at least one run), then time single runs until at least minSamples were
// taken and at least 60% lie within ±10% of their median, or 10 s / 1000 samples have passed.
static (double MedianNs, int Samples, bool Converged) Measure(int minSamples, Action op)
{
	var warm = Stopwatch.StartNew();
	do
		op();
	while (warm.Elapsed.TotalSeconds < 1);
	var start = Stopwatch.StartNew();
	var samples = new List<double>();
	while (true)
	{
		long t0 = Stopwatch.GetTimestamp();
		op();
		samples.Add(Stopwatch.GetElapsedTime(t0).TotalMilliseconds * 1e6);
		var sorted = samples.Order().ToList();
		int n = sorted.Count;
		double median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
		if (n >= minSamples && samples.Count(s => s >= median * 0.9 && s <= median * 1.1) >= 0.6 * n)
			return (median, n, true);
		if (n >= 1000 || start.Elapsed.TotalSeconds >= 10)
			return (median, n, false);
	}
}

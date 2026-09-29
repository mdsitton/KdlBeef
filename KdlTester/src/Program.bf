using System;
using KdlBeef;

namespace KdlTester;

/// Command-line harness for the official test suite and benchmarks (see docs/plan.md, "KdlTester").
/// Planned: read KDL from stdin and print it in the test suite's canonical form (tests/kdl-spec
/// expected_kdl rules), exiting 1 on a parse error; `-bench N` for timings under the shared rule.
class Program
{
	public static int Main(String[] args)
	{
		Console.Error.WriteLine("KdlTester: not implemented yet (see docs/plan.md)");
		return 2;
	}
}

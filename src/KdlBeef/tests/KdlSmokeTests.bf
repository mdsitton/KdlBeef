using System;
using KdlBeef;

namespace KdlBeef;

static class KdlSmokeTests
{
	/// The workspace builds and the test runner finds tests. Replace with real tests as the parser lands.
	[Test]
	public static void Workspace_Builds()
	{
		Test.Assert(KdlVersion.V2 != KdlVersion.V1);
	}
}

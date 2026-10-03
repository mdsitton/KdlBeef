using System;
using KdlBeef;

namespace Other;

/// A second project using KdlBeef, unrelated to Fixtures: with two dependents, KdlBeef's old
/// ApplyToType-time lookups no longer saw the converters Fixtures registers (OkRegisteredConverter).
[KdlObject]
class OtherThing
{
	public int32 count;
}

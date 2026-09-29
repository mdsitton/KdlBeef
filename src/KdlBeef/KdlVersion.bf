namespace KdlBeef;

/// @brief The KDL specification version a document is read or written as.
public enum KdlVersion
{
	/// @brief KDL 1.0.0 (legacy: `true`/`false`/`null` keywords, `r"raw"` strings).
	V1,
	/// @brief KDL 2.0.0, the current specification and the default.
	V2
}

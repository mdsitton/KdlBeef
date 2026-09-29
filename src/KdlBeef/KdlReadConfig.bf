using System;

namespace KdlBeef;

/// @brief What a KdlDocument records about the source while reading.
public enum KdlMetadataMode : uint8
{
	/// @brief Nothing beyond the content.
	None,
	/// @brief Where each node and entry came from (`KdlNode.TryGetSourceRange`,
	/// `KdlEntry.TryGetSourceRange`), for diagnostics such as "button at main.kdl:12:5". The document
	/// is still written in canonical form.
	Positions
}

/// Settings for reading KDL: metadata, the source name for errors, and resource limits for untrusted
/// input. Used by KdlReader (limits and source name) and KdlDocument (all of it).
public struct KdlReadConfig
{
	/// @brief What the document records about the source (KdlDocument only).
	public KdlMetadataMode MetadataMode = .None;
	/// @brief Name of the input for error messages and source ranges, typically its file path
	/// (ReadFile uses the path when this is empty). Only read during the call; copies are kept.
	public StringView SourceName = default;

	/// @brief Maximum node nesting depth: 1 allows top-level nodes only. 0 = unlimited.
	public int MaxDepth = 256;
	/// @brief Maximum input size in bytes. 0 = unlimited.
	public int MaxInputBytes = 0;
	/// @brief Maximum number of nodes in the document, slashdashed ones included. 0 = unlimited.
	public int MaxNodes = 0;
	/// @brief Maximum number of arguments and properties on one node, slashdashed ones included.
	/// 0 = unlimited.
	public int MaxEntriesPerNode = 0;
	/// @brief Maximum length in bytes of any string (a name, key, annotation or value, after
	/// unescaping). 0 = unlimited.
	public int MaxStringBytes = 0;

	/// @brief Buffer size in bytes for reading a Stream. 0 = default (64 KiB); values below 16 are
	/// raised to 16. Setting it also makes KdlDocument.ReadFile stream the file through a buffer of
	/// this size instead of loading it whole.
	public int StreamBufferBytes = 0;
	/// @brief Streams only: the longest construct (a node's head or an entry, with any comments inside
	/// it; a string of any length) the reader may hold in memory at once. Longer ones grow the buffer,
	/// bounded otherwise only by MaxInputBytes and MaxStringBytes. 0 = unlimited.
	public int MaxTokenBytes = 0;
}

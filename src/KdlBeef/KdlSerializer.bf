using System;
using System.IO;

namespace KdlBeef;

/// @brief One-call reading and writing of whole documents as [KdlObject] types (see KdlObjectAttribute):
/// the object's fields are the document's top-level nodes (scalars as `name value` nodes). Each call is
/// a scoped KdlDocument, its Read/ReadFile or Write, and the object's KdlRead or KdlWrite on the
/// document's Root. Use the document API directly to bind an object to one node
/// (`obj.KdlRead(node)`), mix typed and hand-written data, or update a document read with
/// PreserveStyle in place (`obj.KdlWrite(doc.Root)`, then `doc.Write`).
public static class KdlSerializer
{
	/// @brief Parse `text` and fill `target` from it. Errors (parse errors, missing required values,
	/// wrong types) are located in the source.
	/// @param text The KDL text.
	/// @param target The object to fill; fields whose values are absent keep theirs.
	/// @param config Read settings; metadata below Positions is raised to Positions, for error locations.
	/// @param allocator Where created Strings, objects and Lists come from (for example a
	/// `scope BumpAllocator`), or null for the heap, when the object owns them.
	/// @return .Ok, or the first error.
	public static Result<void, KdlParseError> Read<T>(StringView text, T target, KdlReadConfig config = .(), ITypedAllocator allocator = null) where T : class, IKdlSerializable
	{
		let doc = scope KdlDocument();
		Try!(Detached(doc.Read(text, WithPositions(config))));
		return target.KdlRead(doc.Root, allocator);
	}

	/// @brief Parse `text` and fill the struct `target`; see the class overload.
	/// @param text The KDL text.
	/// @param target The struct to fill.
	/// @param config Read settings.
	/// @param allocator Where created objects come from, or null for the heap.
	/// @return .Ok, or the first error.
	public static Result<void, KdlParseError> Read<T>(StringView text, ref T target, KdlReadConfig config = .(), ITypedAllocator allocator = null) where T : struct, IKdlSerializable
	{
		let doc = scope KdlDocument();
		Try!(Detached(doc.Read(text, WithPositions(config))));
		return target.KdlRead(doc.Root, allocator);
	}

	/// @brief Parse the file at `path` and fill `target`. Errors name the file:
	/// `ui.kdl:3:8: button: width: expected integer, found string`.
	/// @param path The file to read.
	/// @param target The object to fill.
	/// @param config Read settings.
	/// @param allocator Where created objects come from, or null for the heap.
	/// @return .Ok, or the first error.
	public static Result<void, KdlParseError> ReadFile<T>(StringView path, T target, KdlReadConfig config = .(), ITypedAllocator allocator = null) where T : class, IKdlSerializable
	{
		let doc = scope KdlDocument();
		Try!(Detached(doc.ReadFile(path, WithPositions(config))));
		return target.KdlRead(doc.Root, allocator);
	}

	/// @brief Write `source` as a new KDL document, appending to `output`.
	/// @param source The object to write.
	/// @param output Receives the KDL text.
	/// @return .Ok, or an error.
	public static Result<void, KdlParseError> Write<T>(T source, String output) where T : IKdlSerializable
	{
		let doc = scope KdlDocument();
		Try!(source.KdlWrite(doc.Root));
		doc.Write(output);
		return .Ok;
	}

	/// @brief Write `source` as a new KDL document to the file at `path`, replacing it. To update an
	/// existing file and keep its comments, read it with PreserveStyle and use KdlWrite on its Root.
	/// @param source The object to write.
	/// @param path The file to write.
	/// @return .Ok, or an error (IoError if the file cannot be written).
	public static Result<void, KdlParseError> WriteFile<T>(T source, StringView path) where T : IKdlSerializable
	{
		let output = scope String();
		Try!(Write(source, output));
		if (File.WriteAllText(path, output) case .Err)
		{
			var error = KdlParseError(.IoError, "Cannot write the file", 0, 0, 0, 0);
			error.SetSource(path);
			return .Err(error);
		}
		return .Ok;
	}

	/// A read's error made independent of the scoped document about to be destroyed: with CollectErrors
	/// its message and source name are the document's own text.
	static Result<void, KdlParseError> Detached(Result<void, KdlParseError> result)
	{
		if (result case .Err(var error))
		{
			error.Detach();
			return .Err(error);
		}
		return .Ok;
	}

	static KdlReadConfig WithPositions(KdlReadConfig config)
	{
		var config;
		if (config.MetadataMode == .None)
			config.MetadataMode = .Positions;
		return config;
	}
}

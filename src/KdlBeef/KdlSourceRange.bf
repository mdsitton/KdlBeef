using System;

namespace KdlBeef;

/// Where a node or entry came from in the source (see KdlMetadataMode.Positions).
public struct KdlSourceRange
{
	/// @brief Name of the source (KdlReadConfig.SourceName, or the path for ReadFile); empty if unnamed.
	/// Borrowed from the document: valid until it is cleared, read again or deleted.
	public StringView mSource;
	/// @brief 1-based line of the start.
	public int mLine;
	/// @brief 1-based column of the start, in code points.
	public int mColumn;
	/// @brief Byte offset of the start.
	public int mOffset;
	/// @brief Length in bytes: a node from its annotation (or `/-`) to its last token (its name, last
	/// entry or children block's `}`); an entry from its key or annotation to the end of its value.
	public int mLength;

	public this(int line, int column, int offset, int length, StringView source = default)
	{
		mSource = source;
		mLine = line;
		mColumn = column;
		mOffset = offset;
		mLength = length;
	}

	/// @brief Formats the position as `source:line:column`, or `line:column` without a source name.
	/// @param strBuffer The string to append to.
	public override void ToString(String strBuffer)
	{
		if (!mSource.IsEmpty)
		{
			strBuffer.Append(mSource);
			strBuffer.Append(':');
		}
		strBuffer.AppendF("{}:{}", mLine, mColumn);
	}
}

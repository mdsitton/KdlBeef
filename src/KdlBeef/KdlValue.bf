using System;

namespace KdlBeef;

/// A KDL value: a tagged union of the value types. It owns nothing: strings and number lexemes are
/// views whose storage belongs to whoever produced the value (a reader event or a document).
public enum KdlValue
{
	/// `#null`.
	case Null;
	/// `#true` or `#false`.
	case Bool(bool v);
	/// An integer within int64, whatever its radix. `text` is the number as written (`0xFF_00_FF`,
	/// `+007`) when it was read, so writers can keep its radix and spelling, and empty for computed
	/// values.
	case Integer(int64 v, StringView text);
	/// A decimal with a fraction or exponent, or `#inf`, `#-inf`, `#nan`. `v` is the nearest double
	/// (infinite or zero when the exponent is out of range); `text` is the number as written
	/// (underscores and all) when it was read, which is how `1.0` and `1e10` keep their spelling, and
	/// empty for keywords and computed values.
	case Float(double v, StringView text);
	/// An integer outside int64 (`0xABCDEF0123456789abcdef`), kept as written.
	case BigInteger(StringView text);
	/// A string (identifier, quoted or raw), unescaped.
	case String(StringView s);

	public bool IsNull       => this case .Null;
	public bool IsBool       => this case .Bool;
	public bool IsInteger    => this case .Integer;
	public bool IsFloat      => this case .Float;
	public bool IsBigInteger => this case .BigInteger;
	public bool IsString     => this case .String;
	/// @brief Whether this is any kind of number (integer, big integer or float).
	public bool IsNumber     => IsInteger || IsFloat || IsBigInteger;

	/// @brief The name of this value's type as used in error messages: "null", "boolean", "integer",
	/// "float", "big integer" or "string".
	public StringView TypeName
	{
		get
		{
			switch (this)
			{
			case .Null:       return "null";
			case .Bool:       return "boolean";
			case .Integer:    return "integer";
			case .Float:      return "float";
			case .BigInteger: return "big integer";
			case .String:     return "string";
			}
		}
	}

	/// @brief Get the string, if this is a string.
	/// @param value Receives the string.
	/// @return Whether this is a string.
	public bool TryGetString(out StringView value)
	{
		if (this case .String(let s))
		{
			value = s;
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Get the integer, if this is an integer within int64.
	/// @param value Receives the integer.
	/// @return Whether this is an int64 integer.
	public bool TryGetInt64(out int64 value)
	{
		if (this case .Integer(let v, ?))
		{
			value = v;
			return true;
		}
		value = 0;
		return false;
	}

	/// @brief Get the value as a double: a float, or an integer converted (possibly rounding).
	/// @param value Receives the number.
	/// @return Whether this is a float or an int64 integer.
	public bool TryGetDouble(out double value)
	{
		switch (this)
		{
		case .Float(let v, ?):
			value = v;
			return true;
		case .Integer(let v, ?):
			value = (double)v;
			return true;
		default:
			value = 0;
			return false;
		}
	}

	/// @brief Get the boolean, if this is one.
	/// @param value Receives the boolean.
	/// @return Whether this is a boolean.
	public bool TryGetBool(out bool value)
	{
		if (this case .Bool(let v))
		{
			value = v;
			return true;
		}
		value = false;
		return false;
	}
}

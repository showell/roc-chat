## This module writes bytes as lowercase hexadecimal digits, two to a byte,
## and reads them back. A secret is shown that way (`Secret`) and a secret's
## hash is kept that way (`SecretHash`). Only the spelling `to_hex` writes is
## read back, so each list of bytes has exactly one spelling.
Hex :: [].{

	## The bytes as lowercase hex digits, two to a byte: `[0x0a, 0xff]` is
	## `0aff`.
	to_hex : List(U8) -> Str
	to_hex = |bytes| {
		digits = bytes.join_map(|b| [digit_of(b // 16), digit_of(b % 16)])
		Str.from_utf8(digits) ?? crash "Hex.to_hex: hex digits are ASCII"
	}

	## The bytes `text` spells, two lowercase hex digits to a byte; unless it
	## holds anything else, an odd count of digits, or an uppercase one
	## (`NotHex`).
	from_hex : Str -> Try(List(U8), [NotHex])
	from_hex = |text| from_hex_onto({ out: [], rest: text.to_utf8() })
}

## The bytes of `rest`, read two digits at a time, after `out`.
from_hex_onto : { out : List(U8), rest : List(U8) } -> Try(List(U8), [NotHex])
from_hex_onto = |{ out, rest }|
	match rest {
		[] => Ok(out)
		[high, low, .. as after] =>
			match (value_of(high), value_of(low)) {
				(Ok(h), Ok(l)) => from_hex_onto({ out: out.append(h * 16 + l), rest: after })
				_ => Err(NotHex)
			}
		[_] => Err(NotHex)
	}

## The digit for `n`, which is below 16.
digit_of : U8 -> U8
digit_of = |n| if (n < 10) '0' + n else 'a' + n - 10

## The value of one lowercase hex digit.
value_of : U8 -> Try(U8, [NotHex])
value_of = |digit|
	if (digit >= '0' and digit <= '9')
		Ok(digit - '0')
	else if (digit >= 'a' and digit <= 'f')
		Ok(digit - 'a' + 10)
	else
		Err(NotHex)

# ── tests
expect Hex.to_hex([0x0a, 0xff, 0x00, 0x90]) == "0aff0090"
expect Hex.to_hex([]) == ""
expect Hex.from_hex("0aff0090") == Ok([0x0a, 0xff, 0x00, 0x90])
expect Hex.from_hex("") == Ok([])
# Every byte reads back as it was written.
expect {
	every_byte = List.from_iter(U8.to(0, 255))
	Hex.from_hex(Hex.to_hex(every_byte)) == Ok(every_byte)
}
# An odd count, an uppercase digit, and the bytes beside each range refused.
expect
	[
		"a",
		"0aF0",
		"0A",
		"/0",
		":0",
		"`0",
		"g0",
		"0 ",
		"0x",
	].all(|text| Hex.from_hex(text) == Err(NotHex))

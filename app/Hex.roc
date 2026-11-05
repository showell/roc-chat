## This module writes bytes as lowercase hexadecimal digits, two to a byte,
## and reads hexadecimal digits back. A secret is shown that way (`Secret`),
## a secret's hash is kept that way (`SecretHash`), an uploaded image is named
## that way (`UploadedImage`), and JSON escapes a control byte that way
## (`JsonOut`). `from_hex` reads back only the spelling `to_hex` writes, so
## each list of bytes has exactly one spelling; a form's `%XX` escape takes
## either case (`UrlEncodedForm`, through `digit_value`).
import Ascii

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

	## The value of one hex digit, `0` to `9`, `a` to `f` or `A` to `F`.
	digit_value : U8 -> Try(U8, [NotAHexDigit])
	digit_value = |digit|
		if (Ascii.is_digit(digit))
			Ok(digit - '0')
		else if (digit >= 'a' and digit <= 'f')
			Ok(digit - 'a' + 10)
		else if (digit >= 'A' and digit <= 'F')
			Ok(digit - 'A' + 10)
		else
			Err(NotAHexDigit)

	## Is `digit` one of `0` to `9` or `a` to `f`, the digits `to_hex` writes?
	is_lower_digit : U8 -> Bool
	is_lower_digit = |digit| Ascii.is_digit(digit) or (digit >= 'a' and digit <= 'f')
}

## The bytes of `rest`, read two lowercase digits at a time, after `out`.
from_hex_onto : { out : List(U8), rest : List(U8) } -> Try(List(U8), [NotHex])
from_hex_onto = |{ out, rest }|
	match rest {
		[] => Ok(out)
		[high, low, .. as after] =>
			match (lower_digit_value(high), lower_digit_value(low)) {
				(Ok(h), Ok(l)) => from_hex_onto({ out: out.append(h * 16 + l), rest: after })
				_ => Err(NotHex)
			}
		[_] => Err(NotHex)
	}

## The value of one lowercase hex digit.
lower_digit_value : U8 -> Try(U8, [NotAHexDigit])
lower_digit_value = |digit|
	if (Hex.is_lower_digit(digit)) Hex.digit_value(digit) else Err(NotAHexDigit)

## The lowercase digit for `n`, which is below 16.
digit_of : U8 -> U8
digit_of = |n| if (n < 10) '0' + n else 'a' + n - 10

# ── tests
# Each byte's two digits, at both ends of each half.
expect
	[
		(0x00, "00"),
		(0x09, "09"),
		(0x0a, "0a"),
		(0x0f, "0f"),
		(0x90, "90"),
		(0xa0, "a0"),
		(0xff, "ff"),
	].all(|(byte, digits)| Hex.to_hex([byte]) == digits)
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
# Each range's ends, and the byte just outside each.
expect
	[
		('0', Ok(0)),
		('9', Ok(9)),
		('a', Ok(10)),
		('f', Ok(15)),
		('A', Ok(10)),
		('F', Ok(15)),
		('/', Err(NotAHexDigit)),
		(':', Err(NotAHexDigit)),
		('`', Err(NotAHexDigit)),
		('g', Err(NotAHexDigit)),
		('@', Err(NotAHexDigit)),
		('G', Err(NotAHexDigit)),
	].all(|(digit, expected)| Hex.digit_value(digit) == expected)
expect ['0', '9', 'a', 'f'].all(Hex.is_lower_digit)
expect
	[
		'A',
		'F',
		'/',
		':',
		'`',
		'g',
		'@',
		'G',
	].all(|digit| !Hex.is_lower_digit(digit))
# Every byte: the lowercase digits are the sixteen `to_hex` writes, and
# `digit_value` takes those and their six uppercase letters.
expect List.from_iter(U8.to(0, 255)).keep_if(Hex.is_lower_digit) == "0123456789abcdef".to_utf8()
expect List.from_iter(
	U8.to(0, 255),
).keep_if(|b| Hex.digit_value(b).is_ok()) == "0123456789ABCDEFabcdef".to_utf8()

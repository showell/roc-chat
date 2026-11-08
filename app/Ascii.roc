## This module answers questions about single ASCII bytes: is it a digit,
## is it a letter, is it a space. Strict names, user ids and timestamps are
## checked a byte at a time with these, so no other module writes out a
## byte range. It also trims ASCII spaces off the ends of bytes, for the
## formats whose spaces are ASCII alone, and reads a number spelled the one
## way each number is written: decimal digits with no leading `0`
## (`canonical_number`), the rule a user id, a serial number and a session's
## second share.
##
## The checks are safe on UTF-8 text: every byte of a multi-byte character
## is 128 or more, and no check answers `Bool.True` for such a byte. So a
## caller can check the bytes of `Str.to_utf8` as they are.
Ascii :: [].{

	## Is `c` one of `0` to `9`?
	is_digit : U8 -> Bool
	is_digit = |c| c >= '0' and c <= '9'

	## Is `c` one of `A` to `Z` or `a` to `z`?
	is_letter : U8 -> Bool
	is_letter = |c| (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')

	## Is `c` a space, a tab, a CR or an LF? These are the four the Zig
	## chat's formats trim, not `Str.trim`'s Unicode spaces.
	is_space : U8 -> Bool
	is_space = |c| c == ' ' or c == '\t' or c == '\r' or c == '\n'

	## `bytes` with the spaces (`is_space`) off both ends.
	trim_spaces : List(U8) -> List(U8)
	trim_spaces = |bytes|
		match (
			bytes.find_first_index(|b| !Ascii.is_space(b)),
			bytes.find_last_index(|b| !Ascii.is_space(b)),
		) {
			(Ok(first), Ok(last)) => bytes.sublist({ start: first, len: last - first + 1 })
			_ => []
		}

	## The number `bytes` spell: one to `most_digits` decimal digits, the
	## first not `0`, so each number has one spelling and 0 has none; unless
	## they are anything else (`NotCanonical`). A caller checks its own range.
	## `most_digits` is at most 19, so every number read fits a `U64`.
	canonical_number : List(U8), { most_digits : U64 } -> Try(U64, [NotCanonical])
	canonical_number = |bytes, { most_digits }|
		if most_digits > 19 {
			crash "Ascii.canonical_number: 20 digits can pass a U64's highest"
		} else {
			match bytes {
				[] => Err(NotCanonical)
				['0', ..] => Err(NotCanonical)
				_ if bytes.len() > most_digits or !bytes.all(Ascii.is_digit) => Err(NotCanonical)
				_ => Ok(bytes.fold(0, |so_far, b| so_far * 10 + (b - '0').to_u64()))
			}
		}
}

# ── tests
all_bytes : List(U8)
all_bytes = List.from_iter(U8.to(0, 255))

# Each check, over all 256 bytes, keeps exactly the members written out.
expect all_bytes.len() == 256
expect all_bytes.keep_if(Ascii.is_digit) == "0123456789".to_utf8()
expect
	all_bytes.keep_if(Ascii.is_letter)
		== "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".to_utf8()
expect all_bytes.keep_if(Ascii.is_space) == "\t\n\r ".to_utf8()
# The bytes on each side of every range.
expect
	[
		('/', Bool.False),
		('0', Bool.True),
		('9', Bool.True),
		(':', Bool.False),
	].all(|(byte, expected)| Ascii.is_digit(byte) == expected)
expect
	[
		('@', Bool.False),
		('A', Bool.True),
		('Z', Bool.True),
		('[', Bool.False),
		('`', Bool.False),
		('a', Bool.True),
		('z', Bool.True),
		('{', Bool.False),
	].all(|(byte, expected)| Ascii.is_letter(byte) == expected)
# A byte of a multi-byte character is none of them: `é` is 0xC3 0xA9.
expect
	"é".to_utf8()
		.all(|byte| !Ascii.is_digit(byte) and !Ascii.is_letter(byte) and !Ascii.is_space(byte))
# A canonical number, at one digit, at the most digits allowed, and at the
# largest 19 digits spell.
expect
	[
		("1", 1),
		("9", 9),
		("10", 10),
		("99999", 99999),
	].all(|(text, number)| Ascii.canonical_number(text.to_utf8(), { most_digits: 5 }) == Ok(number))
expect
	Ascii.canonical_number("9999999999999999999".to_utf8(), { most_digits: 19 })
		== Ok(9999999999999999999)
# None, zero, a leading `0`, one digit too many, a sign, a space, a letter,
# Roc's other number forms, and a digit that isn't ASCII's.
expect
	[
		"",
		"0",
		"00",
		"01",
		"100000",
		"+1",
		"-1",
		" 1",
		"1 ",
		"1a",
		"1_000",
		"0x10",
		"\u(661)",
	].all(|text| Ascii.canonical_number(text.to_utf8(), { most_digits: 5 }) == Err(NotCanonical))
# A trim takes every space off each end, keeps those inside, and leaves a
# no-break space, which is no ASCII space; spaces alone trim to nothing.
expect
	[
		("x", "x"),
		(" \t\r\nx y\n\r\t ", "x y"),
		("\u(a0)x\u(a0)", "\u(a0)x\u(a0)"),
		(" \t\r\n", ""),
		("", ""),
	].all(|(text, expected)| Ascii.trim_spaces(text.to_utf8()) == expected.to_utf8())

## This module answers questions about single ASCII bytes: is it a digit,
## is it a letter. Strict names, user ids and timestamps are checked a byte
## at a time with these, so no other module writes out a byte range.
##
## The checks are safe on UTF-8 text: every byte of a multi-byte character
## is 128 or more, and no check answers `Bool.True` for such a byte. So a
## caller can check the bytes of `Str.to_utf8` as they are.
##
## roc-chat keeps its own copy of this module (`app/Ascii.roc`), on purpose,
## until there is a package both can share.
Ascii :: [].{

	## Is `c` one of `0` to `9`?
	is_digit : U8 -> Bool
	is_digit = |c| c >= '0' and c <= '9'

	## Is `c` one of `A` to `Z` or `a` to `z`?
	is_letter : U8 -> Bool
	is_letter = |c| (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')
}

# ── tests
all_bytes : List(U8)
all_bytes = List.from_iter(U8.to(0, 255))

# Each check, over all 256 bytes, keeps exactly the members written out.
expect all_bytes.len() == 256
expect all_bytes.keep_if(Ascii.is_digit) == "0123456789".to_utf8()
expect all_bytes.keep_if(Ascii.is_letter) == "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".to_utf8()
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
# A byte of a multi-byte character is neither: `é` is 0xC3 0xA9.
expect "é".to_utf8().all(|byte| !Ascii.is_digit(byte) and !Ascii.is_letter(byte))

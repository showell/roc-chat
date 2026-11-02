## **ASCII BYTE CHECKS**: the byte classes the strict names and the
## timestamp's form are made of, each with one home here, so no other module
## writes a byte range. Cribbed from roc-chat's `app/Ascii.roc`, which keeps
## its own copy, on purpose, until a package both can share exists.
##
## **ONE BYTE AT A TIME, SAFE ON UTF-8 BY CONSTRUCTION.** Every byte of a
## multi-byte UTF-8 character is 128 or above, and every check here answers
## `Bool.False` for it, so these run over `Str.to_utf8` bytes as they are,
## never splitting a character.
Ascii :: [].{

	## `0`-`9` (48-57). Zig `isDigit`, Rust `is_ascii_digit`, C `isdigit`.
	is_digit : U8 -> Bool
	is_digit = |c| c >= '0' and c <= '9'

	## `A`-`Z` and `a`-`z` (65-90, 97-122). Zig `isAlphabetic`, Rust
	## `is_ascii_alphabetic`, C `isalpha`; `é` (bytes 195 169) is no letter.
	is_letter : U8 -> Bool
	is_letter = |c| (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')

	## 0-31 and DEL (127): every ASCII byte that is not printable. Zig
	## `isControl`, Rust `is_ascii_control`, C `iscntrl`.
	is_control : U8 -> Bool
	is_control = |c| c < ' ' or c == del
}

## DEL, the one control byte above the printable ones. Roc's character
## literals have no escape for it.
del : U8
del = 127

# ── tests
# Each set is written out as its members, not as the ranges the code tests,
# and every check is held to it over all 256 bytes.
all_bytes : List(U8)
all_bytes = List.from_iter(U8.to(0, 255))

controls : List(U8)
controls = List.from_iter(U8.until(0, ' ')).append(del)

expect all_bytes.len() == 256
expect all_bytes.keep_if(Ascii.is_digit) == "0123456789".to_utf8()
expect all_bytes.keep_if(Ascii.is_letter) == "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".to_utf8()
expect all_bytes.keep_if(Ascii.is_control) == controls
expect controls.len() == 33
# The bytes on each side of every range: of each probe, the members.
expect "/09:".to_utf8().keep_if(Ascii.is_digit) == "09".to_utf8()
expect "@AZ[`az{".to_utf8().keep_if(Ascii.is_letter) == "AZaz".to_utf8()
expect [
	0,
	31,
	' ',
	'~',
	127,
	128,
	255,
].keep_if(Ascii.is_control) == [
	0,
	31,
	127,
]

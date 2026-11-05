## This module writes bytes in base64url, RFC 4648's alphabet for URLs and
## cookies (`A` to `Z`, `a` to `z`, `0` to `9`, `-` and `_`), with no `=`
## padding, and reads them back. A session's cookie carries its user's id
## and its signature this way (`Session`). Only the spelling `encode`
## writes is read back: a length no encoding has, or a last character whose
## unused bits are not zero, is refused, so each list of bytes has exactly
## one spelling.
Base64Url :: [].{

	## The bytes in base64url, unpadded: four characters for every three
	## bytes, and two or three for a last one or two.
	encode : List(U8) -> Str
	encode = |bytes| {
		characters = bytes.chunks_of(3).join_map(encode_group)
		Str.from_utf8(characters) ?? crash "Base64Url.encode: the alphabet is ASCII"
	}

	## The bytes `text` spells as `encode` writes them; unless it holds a
	## character outside the alphabet, a length no encoding has, or a last
	## character with bits that encode nothing set (`NotBase64Url`).
	decode : Str -> Try(List(U8), [NotBase64Url])
	decode = |text| {
		characters = text.to_utf8()
		if characters.len() % 4 == 1 {
			Err(NotBase64Url)
		} else {
			values = characters.map_try(value_of)?
			values.chunks_of(4).map_try(decode_group).map_ok(List.join)
		}
	}
}

## The alphabet, by value.
alphabet : List(U8)
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".to_utf8()

## The character for a value below 64.
character_of : U8 -> U8
character_of = |value|
	alphabet.get(value.to_u64()) ?? crash "Base64Url.character_of: a value is below 64"

## The value of one character of the alphabet.
value_of : U8 -> Try(U8, [NotBase64Url])
value_of = |c|
	if c >= 'A' and c <= 'Z' {
		Ok(c - 'A')
	} else if c >= 'a' and c <= 'z' {
		Ok(c - 'a' + 26)
	} else if c >= '0' and c <= '9' {
		Ok(c - '0' + 52)
	} else if c == '-' {
		Ok(62)
	} else if c == '_' {
		Ok(63)
	} else {
		Err(NotBase64Url)
	}

## One to three bytes as two to four characters.
encode_group : List(U8) -> List(U8)
encode_group = |group|
	match group {
		[a, b, c] => [
			a // 4,
			(a % 4) * 16 + b // 16,
			(b % 16) * 4 + c // 64,
			c % 64,
		].map(character_of)
		[a, b] => [
			a // 4,
			(a % 4) * 16 + b // 16,
			(b % 16) * 4,
		].map(character_of)
		[a] => [a // 4, (a % 4) * 16].map(character_of)
		_ => crash "Base64Url.encode_group: a group is one to three bytes"
	}

## Two to four values as one to three bytes; unless the last value has
## bits set that encode nothing.
decode_group : List(U8) -> Try(List(U8), [NotBase64Url])
decode_group = |group|
	match group {
		[a, b, c, d] => Ok([
			a * 4 + b // 16,
			(b % 16) * 16 + c // 4,
			(c % 4) * 64 + d,
		])
		[
			a,
			b,
			c,
		] => if c % 4 == 0 {
			Ok([a * 4 + b // 16, (b % 16) * 16 + c // 4])
		} else {
			Err(NotBase64Url)
		}
		[a, b] => if b % 16 == 0 {
			Ok([a * 4 + b // 16])
		} else {
			Err(NotBase64Url)
		}
		_ => crash "Base64Url.decode_group: a group is two to four values"
	}

# ── tests
# RFC 4648's test vectors, unpadded, each both ways.
expect
	[
		("", ""),
		("f", "Zg"),
		("fo", "Zm8"),
		("foo", "Zm9v"),
		("foob", "Zm9vYg"),
		("fooba", "Zm9vYmE"),
		("foobar", "Zm9vYmFy"),
	].all(
		|
			(plain, encoded),
		| Base64Url.encode(plain.to_utf8())
			== encoded and Base64Url.decode(encoded) == Ok(plain.to_utf8()),
	)
# The two characters that differ from base64's: 62 is `-`, 63 is `_`.
expect Base64Url.encode([0xfb, 0xff]) == "-_8"
expect Base64Url.decode("-_8") == Ok([0xfb, 0xff])
# Every byte reads back as it was written, at each length of last group.
expect {
	every_byte = List.from_iter(U8.to(0, 255))
	[
		every_byte,
		every_byte.drop_last(1),
		every_byte.drop_last(2),
	].all(|bytes| Base64Url.decode(Base64Url.encode(bytes)) == Ok(bytes))
}
# Base64's own `+`, `/` and `=`, a space, a length of one past a group, and
# a last character with unused bits set: refused.
expect
	[
		"+_8",
		"-/8",
		"Zg==",
		"Zm 9",
		"Z",
		"Zm9vY",
		"Zh",
		"Zm9",
	].all(|text| Base64Url.decode(text) == Err(NotBase64Url))
# The near misses of the unused bits: their own last characters are read.
expect Base64Url.decode("Zg") == Ok("f".to_utf8())
expect Base64Url.decode("Zm8") == Ok("fo".to_utf8())

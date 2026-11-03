## A secret is 32 random bytes from the host's secure source: the part of
## an agent's API key, or of an invite's one-time code, that proves who holds
## it. It is shown once, as 64 lowercase hex digits, and never kept: the chat
## keeps only its hash (`SecretHash`), and `FileSystem` takes no `Secret`.
##
## The type is opaque. Its ways in are `from_random_bytes`, for a secret just
## made, and `from_hex`, for one a client sent back, which reads only the
## spelling `to_hex` writes.
import Hex

Secret :: List(U8).{

	## How many bytes a secret holds.
	length : U64
	length = 32

	## The secret the host's random bytes make. Any other count of bytes is
	## the caller's bug, and crashes.
	from_random_bytes : List(U8) -> Secret
	from_random_bytes = |bytes|
		if (bytes.len() == Secret.length)
			Secret.(bytes)
		else
			crash "Secret.from_random_bytes: a secret is ${Secret.length.to_str()} bytes, not ${bytes.len().to_str()}"

	## The secret `text` spells as `to_hex` writes it: exactly 64 lowercase
	## hex digits; unless it is anything else (`NotASecret`).
	from_hex : Str -> Try(Secret, [NotASecret])
	from_hex = |text|
		match Hex.from_hex(text) {
			Ok(bytes) if bytes.len() == Secret.length => Ok(Secret.(bytes))
			Ok(_) => Err(NotASecret)
			Err(NotHex) => Err(NotASecret)
		}

	## The secret as it is shown once: 64 lowercase hex digits.
	to_hex : Secret -> Str
	to_hex = |Secret.(bytes)| Hex.to_hex(bytes)

	## The secret's bytes, for the host to hash (`AgentsRoute`) and for
	## nothing else.
	bytes_to_hash : Secret -> List(U8)
	bytes_to_hash = |Secret.(bytes)| bytes
}

# ── tests
## The secret whose every byte is `b`.
secret_of : U8 -> Secret
secret_of = |b| Secret.from_random_bytes(List.repeat(b, 32))

expect secret_of(0xab).to_hex() == "ab".repeat(32)
expect Secret.from_hex("ab".repeat(32)).map_ok(Secret.to_hex) == Ok("ab".repeat(32))
expect Secret.from_hex("0a".repeat(32)).map_ok(Secret.bytes_to_hash) == Ok(List.repeat(0x0a, 32))
# One digit pair short or over, odd, uppercase, or no hex: refused.
expect
	[
		"ab".repeat(31),
		"ab".repeat(33),
		"${"ab".repeat(31)}a",
		"AB".repeat(32),
		"zz".repeat(32),
		"",
	].all(|text| Secret.from_hex(text).map_ok(|_| {}) == Err(NotASecret))

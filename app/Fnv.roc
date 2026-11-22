## This module hashes bytes by FNV-1a, 64 bits: a small, fast hash that is
## no secret's guard, only a name for bytes that changes when they do. A
## script the pages load is named by its hash (`Script.url_path`), so a
## browser keeps it for good and fetches a changed one under its new name.
import Hex

Fnv :: [].{

	## The FNV-1a hash of `bytes`, 64 bits.
	fnv_1a_64 : List(U8) -> U64
	fnv_1a_64 = |bytes|
		bytes.fold(
			offset_basis,
			|hash, byte| U64.bitwise_xor(hash, byte.to_u64()).times_wrap(prime),
		)

	## The FNV-1a hash of `bytes` as 16 lowercase hex digits, the most
	## significant first.
	fnv_1a_64_hex : List(U8) -> Str
	fnv_1a_64_hex = |bytes| {
		hash = Fnv.fnv_1a_64(bytes)
		Hex.to_hex([56, 48, 40, 32, 24, 16, 8, 0].map(|shift| hash.shr_wrap(shift).to_u8_wrap()))
	}
}

## FNV's 64-bit offset basis, the hash of no bytes.
offset_basis : U64
offset_basis = 14695981039346656037

## FNV's 64-bit prime.
prime : U64
prime = 1099511628211

# ── tests
# FNV's own test vectors (the IETF draft's, draft-eastlake-fnv), and both
# ends of the digits.
expect Fnv.fnv_1a_64([]) == 0xcbf29ce484222325
expect Fnv.fnv_1a_64_hex([]) == "cbf29ce484222325"
expect Fnv.fnv_1a_64_hex("a".to_utf8()) == "af63dc4c8601ec8c"
expect Fnv.fnv_1a_64_hex("foobar".to_utf8()) == "85944171f73967e8"
# One byte changed, the hash changed.
expect Fnv.fnv_1a_64("foobas".to_utf8()) != Fnv.fnv_1a_64("foobar".to_utf8())

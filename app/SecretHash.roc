## A secret's hash: the SHA-256 digest of a `Secret`'s bytes, which the host
## computes (`Host.sha256_of_bytes!`, asked by `SecretHashing.hash_secret!`).
## The chat keeps this in place of every secret it hands out, so a file on
## disk proves nothing to whoever reads it: an agent's key and an invite's
## code are checked by hashing what the client sent and comparing hashes.
##
## A hash is kept in a file as 64 lowercase hex digits, and only that
## spelling is read back.
import FactFile
import Hex

SecretHash :: List(U8).{

	## The hash the host's SHA-256 `digest` of a secret is. A digest of any
	## length but 32 bytes is the host's bug, and crashes.
	of_digest : List(U8) -> SecretHash
	of_digest = |digest|
		if digest.len() == 32 {
			SecretHash.(digest)
		} else {
			crash "SecretHash.of_digest: a SHA-256 digest is 32 bytes, not ${digest.len().to_str()}"
		}

	## The hash a file holds: 64 lowercase hex digits, with any spaces, tabs
	## and line ends around them taken off (`FactFile`); unless it holds
	## anything else (`NotAHash`).
	from_file : List(U8) -> Try(SecretHash, [NotAHash])
	from_file = |bytes|
		match Str.from_utf8(FactFile.word_from_file(bytes)) {
			Ok(text) =>
				match Hex.from_hex(text) {
					Ok(digest) if digest.len() == 32 => Ok(SecretHash.(digest))
					Ok(_) => Err(NotAHash)
					Err(NotHex) => Err(NotAHash)
				}
			Err(_) => Err(NotAHash)
		}

	## The hash as its file keeps it: 64 lowercase hex digits.
	to_file : SecretHash -> List(U8)
	to_file = |SecretHash.(digest)| Hex.to_hex(digest).to_utf8()

	is_eq : _
}

# ── tests
## The hash whose every byte is `b`, as a test builds one from its file.
hash_of : U8 -> SecretHash
hash_of = |b| SecretHash.from_file(
	Hex.to_hex(List.repeat(b, 32)).to_utf8(),
) ?? crash "SecretHash's tests: 32 bytes are a hash"

expect hash_of(0x5a).to_file() == "5a".repeat(32).to_utf8()
expect SecretHash.of_digest(List.repeat(0x5a, 32)) == hash_of(0x5a)
expect SecretHash.from_file("${"5a".repeat(32)}\n".to_utf8()) == Ok(hash_of(0x5a))
expect hash_of(0x5a) != hash_of(0x5b)
expect
	[
		"5a".repeat(31),
		"5a".repeat(33),
		"5A".repeat(32),
		"",
	].all(|text| SecretHash.from_file(text.to_utf8()) == Err(NotAHash))
expect SecretHash.from_file([0xff]) == Err(NotAHash)

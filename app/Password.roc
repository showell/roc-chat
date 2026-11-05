## A password as a human types it into the sign-in form: 1 to 72 bytes,
## the most bcrypt reads whole. It is checked only by the host, against the
## bcrypt hash its user's password file keeps (`SignInRoute`), and never
## kept or shown.
##
## Text from a request becomes a password through `UnvalidatedString`.
Password :: List(U8).{

	## The most bytes a password may be.
	most_bytes : U64
	most_bytes = 72

	## The password `text` is; unless it is empty or longer than
	## `most_bytes` (`NotAPassword`).
	from_str : Str -> Try(Password, [NotAPassword])
	from_str = |text| {
		bytes = text.to_utf8()
		if bytes.is_empty() or bytes.len() > Password.most_bytes {
			Err(NotAPassword)
		} else {
			Ok(Password.(bytes))
		}
	}

	## The password's bytes, for the host to check and for nothing else.
	bytes_to_check : Password -> List(U8)
	bytes_to_check = |Password.(bytes)| bytes
}

# ── tests
# One byte to 72 is a password, its bytes as typed; none, or 73, is not.
expect Password.from_str("hunter2").map_ok(Password.bytes_to_check) == Ok("hunter2".to_utf8())
expect Password.from_str("x").map_ok(Password.bytes_to_check) == Ok("x".to_utf8())
expect
	Password.from_str("x".repeat(72)).map_ok(Password.bytes_to_check)
		== Ok("x".repeat(72).to_utf8())
expect [
	"",
	"x".repeat(73),
	"é".repeat(37),
].all(|text| Password.from_str(text).map_ok(|_| {}) == Err(NotAPassword))

## A secret token names a user and carries a secret: the user's id, a `-`,
## and the secret's 64 hex digits, such as `7-0a1b...`. An agent's API key
## is one, sent as `Authorization: Bearer <token>`; so is an agent's
## invite's one-time code, which the agent redeems for its key, and a
## human's invite's, which the invited human redeems for a password and a
## session. The id says whose keys or invites to look in; the secret is
## checked against their hashes (`AgentKey`, `AgentInvite`, `HumanInvite`).
##
## Text from a request becomes a token through `UnvalidatedString`.
import Secret
import UserId

SecretToken :: { user : UserId, secret : Secret }.{

	## The token for the user `user`, carrying `secret`.
	of : { user : UserId, secret : Secret } -> SecretToken
	of = |token| SecretToken.(token)

	## The user the token names.
	user : SecretToken -> UserId
	user = |SecretToken.(token)| token.user

	## The secret it carries.
	secret : SecretToken -> Secret
	secret = |SecretToken.(token)| token.secret

	## The token as it is shown once and sent back: the id, `-`, the
	## secret's hex digits.
	to_str : SecretToken -> Str
	to_str = |SecretToken.(token)| "${token.user.to_str()}-${token.secret.to_hex()}"

	## The token `text` spells as `to_str` writes it; unless it is anything
	## else (`NotAToken`).
	from_str : Str -> Try(SecretToken, [NotAToken])
	from_str = |text|
		match text.split_on("-") {
			[id, hex] =>
				match (UserId.from_str(id), Secret.from_hex(hex)) {
					(Ok(named), Ok(carried)) => Ok(SecretToken.({ user: named, secret: carried }))
					_ => Err(NotAToken)
				}
			_ => Err(NotAToken)
		}

	## The token an `Authorization` header's value names: `Bearer `, then
	## the token, as `to_str` writes it; unless it is anything else
	## (`NotABearer`), another scheme included.
	from_bearer : Str -> Try(SecretToken, [NotABearer])
	from_bearer = |value|
		if (value.starts_with(bearer_prefix))
			SecretToken.from_str(value.drop_prefix(bearer_prefix)).map_err(|NotAToken| NotABearer)
		else
			Err(NotABearer)
}

bearer_prefix : Str
bearer_prefix = "Bearer "

# ── tests
## The token for user `id`, its secret's every byte `b`, as `to_str`
## writes it.
token_text : { id : Str, b : U8 } -> Str
token_text = |{ id, b }|
	SecretToken.of({
		user: UserId.from_str(id) ?? crash "SecretToken's tests: an id",
		secret: Secret.from_random_bytes(List.repeat(b, 32)),
	}).to_str()

expect token_text({ id: "7", b: 0x0a }) == "7-${"0a".repeat(32)}"
expect SecretToken.from_str(
	token_text({
		id: "255",
		b: 0xff,
	}),
).map_ok(SecretToken.to_str) == Ok(token_text({ id: "255", b: 0xff }))
expect SecretToken.from_str(token_text({ id: "7", b: 1 })).map_ok(|t| t.user().to_str()) == Ok("7")
# No `-`, a bad id, a bad secret, a second `-`, or a space: refused.
expect
	[
		"0a".repeat(32),
		"0-${"0a".repeat(32)}",
		"07-${"0a".repeat(32)}",
		"7-${"0a".repeat(31)}",
		"7-${"0A".repeat(32)}",
		"7--${"0a".repeat(32)}",
		"7 -${"0a".repeat(32)}",
		"7-",
		"",
	].all(|text| SecretToken.from_str(text).map_ok(|_| {}) == Err(NotAToken))
# A bearer: exactly `Bearer ` and a token; any other scheme or spelling refused.
expect
	SecretToken.from_bearer("Bearer ${token_text({ id: "7", b: 1 })}").map_ok(SecretToken.to_str)
		== Ok(
			token_text({
				id: "7",
				b: 1,
			}),
		)
expect
	[
		"bearer ${token_text({ id: "7", b: 1 })}",
		"Bearer  ${token_text({ id: "7", b: 1 })}",
		"Basic ${token_text({ id: "7", b: 1 })}",
		token_text({ id: "7", b: 1 }),
		"Bearer ",
		"Bearer 7-xyz",
	].all(|value| SecretToken.from_bearer(value).map_ok(|_| {}) == Err(NotABearer))

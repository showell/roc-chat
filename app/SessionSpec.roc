## These are the tests of `Session`: a cookie's value and the bytes it is
## signed over, each kind of human's material, a claim read back from a
## `Cookie` header or refused, whom a claim admits and when, and the
## `Set-Cookie` values.
import Base64Url
import GitHubSessionWord
import Name
import PasswordHash
import Seconds
import Session
import Timestamp
import UserId
import Users

SessionSpec :: [].{}

## The start of the session cookie's pair in a `Cookie` header.
cookie_prefix_text : Str
cookie_prefix_text = "${Session.cookie_name}="

## The users of the tests: Steve, a human, and his agent CC.
tests_users : Users
tests_users = {
	founded = Users.with_founder(Name.from_str("Steve") ?? crash "SessionSpec: Steve is a name")
	owner =
		(founded.user(UserId.chat_owner) ?? crash "SessionSpec: Steve is id 1").as_human()
			?? crash "SessionSpec: Steve is a human"
	(
		founded.add_agent({
			name: Name.from_str("CC") ?? crash "SessionSpec: CC is a name",
			owner,
		}) ?? crash "SessionSpec: CC joins"
	).users
}

## The id `text` spells.
id_of : Str -> UserId
id_of = |text| UserId.from_str(text) ?? crash "SessionSpec: an id"

## A signature of 32 bytes, each `byte`.
mac_of : U8 -> List(U8)
mac_of = |byte| List.repeat(byte, 32)

## The cookie header holding the session for `id` at `signed_at`, its
## signature every byte `byte`.
cookie_for : {
	id : Str,
	signed_at : Timestamp,
	byte : U8,
} -> List(U8)
cookie_for = |{ id, signed_at, byte }| {
	cookie_value = Session.cookie_value({
		id: id_of(id),
		signed_at,
		origin: Ordinary,
		mac: mac_of(byte),
	})
	"${cookie_prefix_text}${cookie_value}".to_utf8()
}

## The material of a human whose password file keeps `text`.
password_material : Str -> Session.Material
password_material = |text|
	Session.Material.from_password({
		password_hash: PasswordHash.from_file(text.to_utf8()),
		github: NoGitHub,
	})

## The GitHub word made of 32 bytes, each `byte`: 64 hex digits, `byte`'s
## pair repeated.
word_of : U8 -> GitHubSessionWord
word_of = |byte| GitHubSessionWord.of_random_bytes(List.repeat(byte, 32))

## What `header` claims, as a test reads it: the bytes its signature is
## over, its human's password file keeping `h`, and the signature.
claim_text : List(U8) -> Try((Str, List(U8)), [NoSession, BadSession])
claim_text = |header| Session.claim_from_cookie_header(header).map_ok(
	|claim| (Str.from_utf8_lossy(claim.signed_bytes(password_material("h"))), claim.mac()),
)

# The value: the id, the second and the signature, each in its spelling.
expect Session.cookie_value({
	id: UserId.chat_owner,
	signed_at: Timestamp.at_second(1700000000),
	origin: Ordinary,
	mac: mac_of(0),
}) == "MQ.1700000000.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
expect Session.signed_bytes({
	id: UserId.chat_owner,
	signed_at: Timestamp.at_second(1700000000),
	origin: Ordinary,
	material: password_material("$2b$10$x"),
}) == "1\n1700000000\n$2b$10$x".to_utf8()
# Another hash, or none, is other bytes: a password rewritten ends its
# sessions.
expect
	["$2b$10$y", ""].all(
		|password_hash| Session.signed_bytes({
			id: UserId.chat_owner,
			signed_at: Timestamp.at_second(1700000000),
			origin: Ordinary,
			material: password_material(password_hash),
		})
			!= "1\n1700000000\n$2b$10$x".to_utf8(),
	)
# The material of each kind of human, in its bytes.
expect password_material("h").bytes_to_sign() == "h".to_utf8()
expect
	Session.Material.from_password({
		password_hash: PasswordHash.from_file("h".to_utf8()),
		github: GitHub(word_of(0xab)),
	}).bytes_to_sign()
		== "h\n${"ab".repeat(32)}".to_utf8()
expect
	Session.Material.from_github_alone(word_of(0xab)).bytes_to_sign()
		== "\n${"ab".repeat(32)}".to_utf8()
# A word rewritten, or a word with no password beside it, is other bytes,
# so rewriting either file ends the session.
expect {
	both = |word| Session.Material.from_password({
		password_hash: PasswordHash.from_file("h".to_utf8()),
		github: GitHub(word),
	}).bytes_to_sign()
	both(word_of(0xab)) != both(word_of(0xcd))
		and both(word_of(0xab)) != password_material("h").bytes_to_sign()
		and both(word_of(0xab)) != Session.Material.from_github_alone(word_of(0xab)).bytes_to_sign()
		and Session.Material.from_github_alone(word_of(0xab)).bytes_to_sign()
			!= Session.Material.from_github_alone(word_of(0xcd)).bytes_to_sign()
}
# A claim read back from its cookie, among others or alone; its signed bytes
# and its signature as written.
expect claim_text(
	cookie_for({
		id: "1",
		signed_at: Timestamp.at_second(1700000000),
		byte: 7,
	}),
) == Ok(("1\n1700000000\nh", mac_of(7)))
expect {
	cookie = cookie_for({
		id: "42",
		signed_at: Timestamp.at_second(0),
		byte: 1,
	})
	claim_text("theme=dark; ${Str.from_utf8_lossy(cookie)} ;x=y".to_utf8())
		== Ok(("42\n0\nh", mac_of(1)))
}
# No session cookie: none, another, or one whose name only starts the same.
expect
	[
		"",
		"theme=dark",
		"__Host-gopher_auth_old=x",
		"gopher_auth=x",
	].all(|header| claim_text(header.to_utf8()) == Err(NoSession))
# Two session cookies, or a value that is no claim: three parts of an id, a
# second and 32 bytes, each in its one spelling.
expect {
	one = Str.from_utf8_lossy(
		cookie_for({
			id: "1",
			signed_at: Timestamp.at_second(1700000000),
			byte: 7,
		}),
	)
	signature = Base64Url.encode(mac_of(7))
	[
		"${one}; ${one}",
		"${cookie_prefix_text}",
		"${cookie_prefix_text}MQ.1700000000",
		"${cookie_prefix_text}MQ.1700000000.${signature}.x",
		"${cookie_prefix_text}MA.1700000000.${signature}",
		"${cookie_prefix_text}MDE.1700000000.${signature}",
		"${cookie_prefix_text}eA.1700000000.${signature}",
		"${cookie_prefix_text}M.1700000000.${signature}",
		"${cookie_prefix_text}MQ.01700000000.${signature}",
		"${cookie_prefix_text}MQ.-1.${signature}",
		"${cookie_prefix_text}MQ.+1.${signature}",
		"${cookie_prefix_text}MQ.9223372036854775808.${signature}",
		"${cookie_prefix_text}MQ..${signature}",
		"${cookie_prefix_text}MQ.1700000000.${Base64Url.encode(List.repeat(7, 31))}",
		"${cookie_prefix_text}MQ.1700000000.${Base64Url.encode(List.repeat(7, 33))}",
		"${cookie_prefix_text}MQ.1700000000.${signature}=",
	].all(|header| claim_text(header.to_utf8()) == Err(BadSession))
}
expect
	claim_text("${cookie_prefix_text}MQ.9223372036854775807.${Base64Url.encode(mac_of(7))}".to_utf8())
		== Ok(("1\n9223372036854775807\nh", mac_of(7)))

## Whom the session for `id` at `signed_at` admits at `now`, with the
## host's `verdict`, as a test reads it.
admitted_at : {
	id : Str,
	signed_at : Timestamp,
	now : Timestamp,
	verdict : [DoesNotMatch, Matches],
} -> Try(Str, [SessionRefused, BadSession, NoSession])
admitted_at = |{ id, signed_at, now, verdict }| {
	claim = Session.claim_from_cookie_header(cookie_for({ id, signed_at, byte: 7 }))?
	admitted = Session.admit({ claim, verdict, now, users: tests_users })?
	Ok(admitted.human().user().name().to_str())
}

# A matching signature admits its human, at its second, a year after, and
# five minutes before it; one second past either edge, or a mismatch, or an
# agent, or no such user, admits no one.
expect admitted_at({
	id: "1",
	signed_at: Timestamp.at_second(1700000000),
	now: Timestamp.at_second(1700000000),
	verdict: Matches,
}) == Ok("Steve")
expect admitted_at({
	id: "1",
	signed_at: Timestamp.at_second(1700000000),
	now: Timestamp.at_second(1700000000).plus(Session.longest_seconds),
	verdict: Matches,
}) == Ok("Steve")
expect admitted_at({
	id: "1",
	signed_at: Timestamp.at_second(1700000000),
	now: Timestamp.at_second(1700000000).plus(Session.longest_seconds).plus(Seconds.of(1)),
	verdict: Matches,
}) == Err(SessionRefused)
expect admitted_at({
	id: "1",
	signed_at: Timestamp.at_second(1700000000).plus(Session.clock_skew_seconds),
	now: Timestamp.at_second(1700000000),
	verdict: Matches,
}) == Ok("Steve")
expect admitted_at({
	id: "1",
	signed_at: Timestamp.at_second(1700000000).plus(Session.clock_skew_seconds).plus(Seconds.of(1)),
	now: Timestamp.at_second(1700000000),
	verdict: Matches,
}) == Err(SessionRefused)
expect admitted_at({
	id: "1",
	signed_at: Timestamp.at_second(1700000000),
	now: Timestamp.at_second(1700000000),
	verdict: DoesNotMatch,
}) == Err(SessionRefused)
expect admitted_at({
	id: "2",
	signed_at: Timestamp.at_second(1700000000),
	now: Timestamp.at_second(1700000000),
	verdict: Matches,
}) == Err(SessionRefused)
expect admitted_at({
	id: "3",
	signed_at: Timestamp.at_second(1700000000),
	now: Timestamp.at_second(1700000000),
	verdict: Matches,
}) == Err(SessionRefused)
expect admitted_at({
	id: "1",
	signed_at: Timestamp.at_second(9223372036854775807),
	now: Timestamp.at_second(1700000000),
	verdict: Matches,
}) == Err(SessionRefused)
expect admitted_at({
	id: "1",
	signed_at: Timestamp.at_second(0),
	now: Timestamp.at_second(1700000000),
	verdict: Matches,
}) == Err(SessionRefused)
# The cookie set for a year, and cleared, each with its defences.
expect
	Session.set_cookie_text("v")
		== "__Host-gopher_auth=v; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax"
expect
	Session.clear_cookie_text
		== "__Host-gopher_auth=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax"

## A session keeps a human signed in: a cookie the server signs when they
## give their password or GitHub vouches for them (`SignInRoute`), and checks
## on every request after.
##
## The cookie is `__Host-gopher_auth`, and its value is three parts joined by
## `.`: the user's id in base64url (`Base64Url`), the second it was signed
## at, in decimal, and the HMAC-SHA256 of the id, a line feed, that second,
## a line feed and the human's `Material`, in base64url. The host signs and
## checks the HMAC with the server's secret
## (`Host.hmac_sha256_with_server_secret!`), which the app never holds. A
## session admits its human for a year from its second, and one signed more
## than five minutes ahead of the clock admits no one.
##
## The `Material` is what the human's sign-in files hold: the bcrypt hash of
## their password, and for a human tied to GitHub, the random word in
## `github-session-secret`. A human with no password has only the word.
## Because the material is signed and not sent, rewriting or removing any of
## those files ends every session of theirs, and keeping it costs nothing.
##
## The cookie is `HttpOnly`, so no script reads it; `Secure`, so a browser
## sends it only over HTTPS or to this machine; `SameSite=Lax`, so another
## site's form never carries it; and `__Host-`, so it names this host alone
## and no other site under the same domain can set one.
##
## A `Session.Admitted` is made only by `admit`, from a claim whose
## signature the host said matches, and only `SignedIn.by_session` takes
## one: that is the session's door into `SignedIn`.
import Ascii
import Base64Url
import Name
import UserId
import Users

Session :: [].{

	## The cookie's name.
	cookie_name : Str
	cookie_name = "__Host-gopher_auth"

	## How long a session admits its human, in seconds: a year.
	longest_seconds : I64
	longest_seconds = 365 * 24 * 60 * 60

	## How far ahead of the clock a session's second may be: a clock a
	## little behind the one that signed it.
	clock_skew_seconds : I64
	clock_skew_seconds = 5 * 60

	## What a cookie claims before its signature is checked: whose it is,
	## the second it says it was signed at, and its signature.
	Claim :: {
		id : UserId,
		signed_at : I64,
		mac : List(U8),
	}.{

		## The bytes its signature is over, when its human's sign-in files
		## hold `material`: the id's digits, a line feed, the second's
		## digits, a line feed, the material.
		signed_bytes : Session.Claim, Session.Material -> List(U8)
		signed_bytes = |Session.Claim.(claim), material| Session.signed_bytes({
			id: claim.id,
			signed_at: claim.signed_at,
			material,
		})

		## The signature it carries, for the host to check.
		mac : Session.Claim -> List(U8)
		mac = |Session.Claim.(claim)| claim.mac

		## The user it names.
		id : Session.Claim -> UserId
		id = |Session.Claim.(claim)| claim.id

		## The second it says it was signed at.
		signed_at : Session.Claim -> I64
		signed_at = |Session.Claim.(claim)| claim.signed_at
	}

	## What a human's sessions are signed over: the password hash as it is;
	## the hash, a line feed and the GitHub word; or a line feed and the word
	## for a human with no password. A hash and a word hold no line feed, so
	## no two of these are the same bytes.
	Material :: List(U8).{

		## The material of a human with a password, whose file keeps
		## `password_hash`.
		from_password : {
			password_hash : List(U8),
			github : [NoGitHub, GitHub(List(U8))],
		} -> Session.Material
		from_password = |{ password_hash, github }|
			match github {
				NoGitHub => Session.Material.(password_hash)
				GitHub(word) => Session.Material.(password_hash.append('\n').concat(word))
			}

		## The material of a human with no password, whose
		## `github-session-secret` file keeps `word`.
		from_github_alone : List(U8) -> Session.Material
		from_github_alone = |word| Session.Material.(['\n'].concat(word))

		## The material's bytes, to sign.
		bytes_to_sign : Session.Material -> List(U8)
		bytes_to_sign = |Session.Material.(bytes)| bytes
	}

	## The bytes a session for `id`, signed at `signed_at`, is signed over,
	## its human's sign-in files holding `material`.
	signed_bytes : {
		id : UserId,
		signed_at : I64,
		material : Session.Material,
	} -> List(U8)
	signed_bytes = |
		{
			id,
			signed_at,
			material,
		},
	| "${id.to_str()}\n${signed_at.to_str()}\n".to_utf8().concat(material.bytes_to_sign())

	## The claim of the request's `Cookie` header, `header`; unless it holds
	## no session cookie (`NoSession`), or one that is no claim, or more than
	## one (`BadSession`).
	claim_from_cookie_header : List(U8) -> Try(Session.Claim, [NoSession, BadSession])
	claim_from_cookie_header = |header| {
		named =
			header.split_on(';')
				.map(Ascii.trim_spaces)
				.keep_if(|pair| pair.starts_with(cookie_prefix))
		match named {
			[] => Err(NoSession)
			[only] => claim_from_value(only.drop_first(cookie_prefix.len()))
			_ => Err(BadSession)
		}
	}

	## A session, the human it admits; only `admit` makes one.
	Admitted :: Users.Human.{

		## The human it admits.
		human : Session.Admitted -> Users.Human
		human = |Session.Admitted.(human)| human
	}

	## The human `claim` admits, at `now`, among `users`: when the host's
	## `verdict` on its signature is `Matches`, its second is at most a year
	## past and at most `clock_skew_seconds` ahead, and its id is a human's;
	## else `SessionRefused`.
	admit : {
		claim : Session.Claim,
		verdict : [DoesNotMatch, Matches],
		now : I64,
		users : Users,
	} -> Try(Session.Admitted, [SessionRefused])
	admit = |
		{
			claim,
			verdict,
			now,
			users,
		},
	|
		match verdict {
			DoesNotMatch => Err(SessionRefused)
			Matches =>
				if is_outside_window({ now, signed_at: claim.signed_at() }) {
					Err(SessionRefused)
				} else {
					match users.user(claim.id()) {
						Err(NoSuchUser) => Err(SessionRefused)
						Ok(user) =>
							match user.as_human() {
								Ok(human) => Ok(Session.Admitted.(human))
								Err(Agent(_)) => Err(SessionRefused)
							}
					}
				}
		}

	## The cookie's value for `id`, signed at `signed_at`, its signature
	## `mac`, the host's HMAC of `signed_bytes`.
	cookie_value : {
		id : UserId,
		signed_at : I64,
		mac : List(U8),
	} -> Str
	cookie_value = |
		{
			id,
			signed_at,
			mac,
		},
	| "${Base64Url.encode(id.to_str().to_utf8())}.${signed_at.to_str()}.${Base64Url.encode(mac)}"

	## The `Set-Cookie` header's value that sets the session's cookie to
	## `value`, for a year.
	set_cookie_text : Str -> Str
	set_cookie_text = |value|
		"${cookie_prefix_text}${value}; Path=/; Max-Age=${Session.longest_seconds.to_str()}; ${cookie_attributes}"

	## The `Set-Cookie` header's value that has a browser forget the
	## session's cookie.
	clear_cookie_text : Str
	clear_cookie_text = "${cookie_prefix_text}; Path=/; Max-Age=0; ${cookie_attributes}"
}

cookie_prefix_text : Str
cookie_prefix_text = "${Session.cookie_name}="

cookie_prefix : List(U8)
cookie_prefix = cookie_prefix_text.to_utf8()

cookie_attributes : Str
cookie_attributes = "HttpOnly; Secure; SameSite=Lax"

## Whether a claim's `signed_at` is older than a session lasts, or further
## ahead of `now` than the clock's skew allows.
is_outside_window : { now : I64, signed_at : I64 } -> Bool
is_outside_window = |{ now, signed_at }|
	now - signed_at > Session.longest_seconds or signed_at - now > Session.clock_skew_seconds

## The claim a cookie's value spells; unless it is not three parts, an id
## that is no user's id, a second that is not its digits, or a signature
## that is not 32 bytes (`BadSession`).
claim_from_value : List(U8) -> Try(Session.Claim, [BadSession])
claim_from_value = |value|
	match value.split_on('.') {
		[
			id_part,
			second_part,
			mac_part,
		] => {
			id_bytes = Base64Url.decode(Str.from_utf8(id_part) ? |_| BadSession) ? |_| BadSession
			id_text = Str.from_utf8(id_bytes) ? |_| BadSession
			id = UserId.from_str(id_text) ? |_| BadSession
			signed_at = second_from_digits(second_part) ? |_| BadSession
			mac = Base64Url.decode(Str.from_utf8(mac_part) ? |_| BadSession) ? |_| BadSession
			if (mac.len() == 32) Ok(
				Session.Claim.(
					{
						id,
						signed_at,
						mac,
					},
				),
			) else Err(BadSession)
		}
		_ => Err(BadSession)
	}

## The second `digits` spell: decimal digits with no leading `0`, at most
## the largest `I64`; so each second has one spelling, the one `to_str`
## writes and the signature is over.
second_from_digits : List(U8) -> Try(I64, [NotASecond])
second_from_digits = |digits|
	match digits {
		[] => Err(NotASecond)
		['0'] => Ok(0)
		['0', ..] => Err(NotASecond)
		_ if digits.len() > 19 or !digits.all(Ascii.is_digit) => Err(NotASecond)
		_ => {
			number = U64.from_int_digits(digits.map(|b| b - '0')) ? |_| NotASecond
			if (number > I64.highest.to_u64_wrap()) Err(NotASecond) else Ok(number.to_i64_wrap())
		}
	}

# ── tests
## The users of the tests: Steve, a human, and his agent CC.
tests_users : Users
tests_users = {
	founded = Users.with_founder(Name.from_str("Steve") ?? crash "Session's tests: Steve is a name")
	owner =
		(founded.user(UserId.steve) ?? crash "Session's tests: Steve is id 1").as_human()
			?? crash "Session's tests: Steve is a human"
	(
		founded.add_agent({
			name: Name.from_str("CC") ?? crash "Session's tests: CC is a name",
			owner,
		}) ?? crash "Session's tests: CC joins"
	).users
}

## The id `text` spells.
id_of : Str -> UserId
id_of = |text| UserId.from_str(text) ?? crash "Session's tests: an id"

## A signature of 32 bytes, each `b`.
mac_of : U8 -> List(U8)
mac_of = |b| List.repeat(b, 32)

## The cookie header holding the session for `id` at `signed_at`, its
## signature every byte `b`.
cookie_for : {
	id : Str,
	signed_at : I64,
	b : U8,
} -> List(U8)
cookie_for = |
	{
		id,
		signed_at,
		b,
	},
| {
	cookie_value = Session.cookie_value({
		id: id_of(id),
		signed_at,
		mac: mac_of(b),
	})
	"${cookie_prefix_text}${cookie_value}".to_utf8()
}

## The material of a human whose password file keeps `text`.
password_material : Str -> Session.Material
password_material = |text|
	Session.Material.from_password({ password_hash: text.to_utf8(), github: NoGitHub })

## What `header` claims, as a test reads it: the bytes its signature is
## over, its human's password file keeping `h`, and the signature.
claim_text : List(U8) -> Try((Str, List(U8)), [NoSession, BadSession])
claim_text = |header| Session.claim_from_cookie_header(header).map_ok(
	|claim| (
		Str.from_utf8_lossy(claim.signed_bytes(password_material("h"))),
		claim.mac(),
	),
)

# The value: the id, the second and the signature, each in its spelling.
expect Session.cookie_value({
	id: UserId.steve,
	signed_at: 1700000000,
	mac: mac_of(0),
}) == "MQ.1700000000.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
expect Session.signed_bytes({
	id: UserId.steve,
	signed_at: 1700000000,
	material: password_material("$2b$10$x"),
}) == "1\n1700000000\n$2b$10$x".to_utf8()
# Another hash, or none, is other bytes: a password rewritten ends its
# sessions.
expect
	[
		"$2b$10$y",
		"",
	].all(
		|password_hash| Session.signed_bytes({
			id: UserId.steve,
			signed_at: 1700000000,
			material: password_material(password_hash),
		})
			!= "1\n1700000000\n$2b$10$x".to_utf8(),
	)
# The material of each kind of human, in its bytes.
expect password_material("h").bytes_to_sign() == "h".to_utf8()
expect
	Session.Material.from_password({ password_hash: "h".to_utf8(), github: GitHub("w".to_utf8()) })
		.bytes_to_sign()
		== "h\nw".to_utf8()
expect Session.Material.from_github_alone("w".to_utf8()).bytes_to_sign() == "\nw".to_utf8()
# A word rewritten, or a word with no password beside it, is other bytes,
# so rewriting either file ends the session.
expect {
	both = |word| Session.Material.from_password({
		password_hash: "h".to_utf8(),
		github: GitHub(word.to_utf8()),
	}).bytes_to_sign()
	both("w") != both("v")
		and both("w") != password_material("h").bytes_to_sign()
		and both("w") != Session.Material.from_github_alone("w".to_utf8()).bytes_to_sign()
		and Session.Material.from_github_alone("w".to_utf8()).bytes_to_sign()
			!= Session.Material.from_github_alone("v".to_utf8()).bytes_to_sign()
}
# A claim read back from its cookie, among others or alone; its signed bytes
# and its signature as written.
expect claim_text(
	cookie_for({
		id: "1",
		signed_at: 1700000000,
		b: 7,
	}),
) == Ok(("1\n1700000000\nh", mac_of(7)))
expect
	claim_text("theme=dark; ${Str.from_utf8_lossy(cookie_for({ id: "42", signed_at: 0, b: 1 }))} ;x=y".to_utf8())
		== Ok(("42\n0\nh", mac_of(1)))
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
			signed_at: 1700000000,
			b: 7,
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
		== Ok((
			"1\n9223372036854775807\nh",
			mac_of(7),
		))

## Whom the session for `id` at `signed_at` admits at `now`, with the
## host's `verdict`, as a test reads it.
admitted_at : {
	id : Str,
	signed_at : I64,
	now : I64,
	verdict : [DoesNotMatch, Matches],
} -> Try(Str, [SessionRefused, BadSession, NoSession])
admitted_at = |
	{
		id,
		signed_at,
		now,
		verdict,
	},
| {
	claim = Session.claim_from_cookie_header(
		cookie_for({
			id,
			signed_at,
			b: 7,
		}),
	)?
	admitted = Session.admit({
		claim,
		verdict,
		now,
		users: tests_users,
	})?
	Ok(admitted.human().user().name().to_str())
}

# A matching signature admits its human, at its second, a year after, and
# five minutes before it; one second past either edge, or a mismatch, or an
# agent, or no such user, admits no one.
expect admitted_at({
	id: "1",
	signed_at: 1700000000,
	now: 1700000000,
	verdict: Matches,
}) == Ok("Steve")
expect admitted_at({
	id: "1",
	signed_at: 1700000000,
	now: 1700000000 + Session.longest_seconds,
	verdict: Matches,
}) == Ok("Steve")
expect admitted_at({
	id: "1",
	signed_at: 1700000000,
	now: 1700000000 + Session.longest_seconds + 1,
	verdict: Matches,
}) == Err(SessionRefused)
expect admitted_at({
	id: "1",
	signed_at: 1700000000,
	now: 1700000000 - Session.clock_skew_seconds,
	verdict: Matches,
}) == Ok("Steve")
expect admitted_at({
	id: "1",
	signed_at: 1700000000,
	now: 1700000000 - Session.clock_skew_seconds - 1,
	verdict: Matches,
}) == Err(SessionRefused)
expect admitted_at({
	id: "1",
	signed_at: 1700000000,
	now: 1700000000,
	verdict: DoesNotMatch,
}) == Err(SessionRefused)
expect admitted_at({
	id: "2",
	signed_at: 1700000000,
	now: 1700000000,
	verdict: Matches,
}) == Err(SessionRefused)
expect admitted_at({
	id: "3",
	signed_at: 1700000000,
	now: 1700000000,
	verdict: Matches,
}) == Err(SessionRefused)
expect admitted_at({
	id: "1",
	signed_at: 9223372036854775807,
	now: 1700000000,
	verdict: Matches,
}) == Err(SessionRefused)
expect admitted_at({
	id: "1",
	signed_at: 0,
	now: 1700000000,
	verdict: Matches,
}) == Err(SessionRefused)
# The cookie set for a year, and cleared, each with its defences.
expect
	Session.set_cookie_text("v")
		== "__Host-gopher_auth=v; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax"
expect
	Session.clear_cookie_text
		== "__Host-gopher_auth=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax"

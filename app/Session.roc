## A session keeps a human signed in: a cookie the server signs when they
## give their password or GitHub vouches for them (`SignInRoute`), and checks
## on every request after.
##
## The cookie is `__Host-gopher_auth`, and its value is three parts joined by
## `.`, and a fourth, `d`, for a session a device code started: the user's
## id in base64url (`Base64Url`), the second it was signed at, in decimal,
## and the HMAC-SHA256 of `signed_bytes`, in base64url. The host signs and
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
## A session started by a device code (`Origin`'s `ByDeviceCode`) says so in
## its cookie, a fourth part `d` and its device key's number (`d3`), and in
## what it is signed over, so the mark and the number can't be added, changed
## or taken off; such a session may not link GitHub or make agents or their
## invites (`SignedIn.check_full_session`), and admits its human only while
## its key is active (`DeviceKey`, checked by `SignInRoute`). A fourth part
## of `d` alone, as such sessions were before device keys, is no session.
##
## A human's `session-generation` file, a count their "Sign out other
## devices" raises, is part of the material once it is above 0, so raising
## it ends every session signed before.
##
## A `Session.Admitted` is made only by `admit`, from a claim whose
## signature the host said matches, and only `SignedIn.by_session` takes
## one: that is the session's door into `SignedIn`.
import Ascii
import Base64Url
import DeviceKey
import GitHubSessionWord
import PasswordHash
import Seconds
import Timestamp
import UserId
import Users

Session :: [].{

	## The cookie's name.
	cookie_name : Str
	cookie_name = "__Host-gopher_auth"

	## How long a session admits its human, in seconds: a year.
	longest_seconds : Seconds
	longest_seconds = Seconds.of(365 * 24 * 60 * 60)

	## How far ahead of the clock a session's second may be: a clock a
	## little behind the one that signed it.
	clock_skew_seconds : Seconds
	clock_skew_seconds = Seconds.of(5 * 60)

	## How a session was started: by a password, GitHub or an invite
	## (`Ordinary`), or by a device code from another device of the human's
	## (`ByDeviceCode`, bound to the device key its redemption made).
	Origin : [Ordinary, ByDeviceCode(DeviceKey.Id)]

	## What a cookie claims before its signature is checked: whose it is,
	## the second it says it was signed at, how the session was started,
	## and its signature.
	Claim :: {
		id : UserId,
		signed_at : Timestamp,
		origin : Session.Origin,
		mac : List(U8),
	}.{

		## The bytes the host checks its signature against, when its human's
		## sign-in files hold `material` (`Session.signed_bytes` of its fields).
		bytes_to_verify : Session.Claim, Session.Material -> List(U8)
		bytes_to_verify = |Session.Claim.(claim), material| Session.signed_bytes({
			id: claim.id,
			signed_at: claim.signed_at,
			origin: claim.origin,
			material,
		})

		## How the session it claims was started.
		origin : Session.Claim -> Session.Origin
		origin = |Session.Claim.(claim)| claim.origin

		## The signature it carries, for the host to check.
		mac : Session.Claim -> List(U8)
		mac = |Session.Claim.(claim)| claim.mac

		## The user it names.
		id : Session.Claim -> UserId
		id = |Session.Claim.(claim)| claim.id

		## The second it says it was signed at.
		signed_at : Session.Claim -> Timestamp
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
			password_hash : PasswordHash,
			github : [NoGitHub, GitHub(GitHubSessionWord)],
		} -> Session.Material
		from_password = |{ password_hash, github }|
			match github {
				NoGitHub => Session.Material.(password_hash.bytes())
				GitHub(word) => {
					with_line_feed = password_hash.bytes().append('\n')
					Session.Material.(List.concat(with_line_feed, word.bytes()))
				}
			}

		## The material of a human with no password, whose
		## `github-session-secret` file keeps `word`.
		from_github_alone : GitHubSessionWord -> Session.Material
		from_github_alone = |word| Session.Material.(List.concat(['\n'], word.bytes()))

		## The material with the human's session generation, `generation`:
		## the same bytes at 0, and else a line feed, `generation ` and its
		## digits after them, which no hash or word holds.
		with_generation : Session.Material, U64 -> Session.Material
		with_generation = |Session.Material.(bytes), generation|
			if generation == 0 {
				Session.Material.(bytes)
			} else {
				Session.Material.(
					List.concat(bytes, "\ngeneration ${generation.to_str()}".to_utf8()),
				)
			}

		## The material's bytes, to sign.
		bytes_to_sign : Session.Material -> List(U8)
		bytes_to_sign = |Session.Material.(bytes)| bytes
	}

	## The bytes a session for `id`, signed at `signed_at`, started as
	## `origin` says, is signed over, its human's sign-in files holding
	## `material`: the id's digits, a line feed, the second's digits, a line
	## feed, for a session started by a device code `by-device-code`, a
	## space, its key's number and a line feed, then the material, which
	## starts with `$` or a line feed.
	signed_bytes : {
		id : UserId,
		signed_at : Timestamp,
		origin : Session.Origin,
		material : Session.Material,
	} -> List(U8)
	signed_bytes = |{ id, signed_at, origin, material }| {
		mark =
			match origin {
				Ordinary => ""
				ByDeviceCode(key) => "by-device-code ${key.to_str()}\n"
			}
		head = "${id.to_str()}\n${signed_at.to_str()}\n${mark}"
		List.concat(head.to_utf8(), material.bytes_to_sign())
	}

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

	## A session, the human it admits and how it was started; only `admit`
	## makes one.
	Admitted :: { human : Users.Human, origin : Session.Origin }.{

		## The human it admits.
		human : Session.Admitted -> Users.Human
		human = |Session.Admitted.(admitted)| admitted.human

		## How it was started.
		origin : Session.Admitted -> Session.Origin
		origin = |Session.Admitted.(admitted)| admitted.origin
	}

	## The human `claim` admits, at `now`, among `users`: when the host's
	## `verdict` on its signature is `Matches`, its second is at most a year
	## past and at most `clock_skew_seconds` ahead, and its id is a human's;
	## else `SessionRefused`.
	admit : {
		claim : Session.Claim,
		verdict : [DoesNotMatch, Matches],
		now : Timestamp,
		users : Users,
	} -> Try(Session.Admitted, [SessionRefused])
	admit = |{ claim, verdict, now, users }|
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
								Ok(human) => Ok(
									Session.Admitted.({ human, origin: claim.origin() }),
								)
								Err(Agent(_)) => Err(SessionRefused)
							}
					}
				}
		}

	## The cookie's value for `id`, signed at `signed_at`, started as
	## `origin` says, its signature `mac`, the host's HMAC of
	## `signed_bytes`: three parts, and a fourth, `d` and its key's number,
	## for a session started by a device code.
	cookie_value : {
		id : UserId,
		signed_at : Timestamp,
		origin : Session.Origin,
		mac : List(U8),
	} -> Str
	cookie_value = |{ id, signed_at, origin, mac }| {
		id_part = Base64Url.encode(id.to_str().to_utf8())
		parts = "${id_part}.${signed_at.to_str()}.${Base64Url.encode(mac)}"
		match origin {
			Ordinary => parts
			ByDeviceCode(key) => "${parts}.d${key.to_str()}"
		}
	}

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
is_outside_window : { now : Timestamp, signed_at : Timestamp } -> Bool
is_outside_window = |{ now, signed_at }|
	now.seconds_since(signed_at).is_more_than(Session.longest_seconds)
		or signed_at.seconds_since(now).is_more_than(Session.clock_skew_seconds)

## The claim a cookie's value spells; unless it is not three parts, or
## four whose last is `d` and a device key's number, an id that is no
## user's id, a second that is not its digits, or a signature that is not
## 32 bytes (`BadSession`).
claim_from_value : List(U8) -> Try(Session.Claim, [BadSession])
claim_from_value = |value|
	match value.split_on('.') {
		[id_part, second_part, mac_part] => claim_from_parts({
			id_part,
			second_part,
			mac_part,
			origin: Ordinary,
		})
		[id_part, second_part, mac_part, mark] => {
			key = device_key_of_mark(mark)?
			claim_from_parts({
				id_part,
				second_part,
				mac_part,
				origin: ByDeviceCode(key),
			})
		}
		_ => Err(BadSession)
	}

## The device key a cookie's fourth part, `mark`, names: `d` and the key's
## number; unless it is anything else (`BadSession`), a bare `d` among them.
device_key_of_mark : List(U8) -> Try(DeviceKey.Id, [BadSession])
device_key_of_mark = |mark|
	match mark {
		['d', .. as key_digits] => {
			key_text = Str.from_utf8(key_digits) ? |_| BadSession
			DeviceKey.Id.from_str(key_text).map_err(|NotADeviceKeyId| BadSession)
		}
		_ => Err(BadSession)
	}

## The claim a cookie's parts spell, started as `origin` says; unless they
## are an id that is no user's, a second that is not its digits, or a
## signature that is not 32 bytes (`BadSession`).
claim_from_parts : {
	id_part : List(U8),
	second_part : List(U8),
	mac_part : List(U8),
	origin : Session.Origin,
} -> Try(Session.Claim, [BadSession])
claim_from_parts = |{ id_part, second_part, mac_part, origin }| {
	id_bytes = Base64Url.decode(Str.from_utf8(id_part) ? |_| BadSession) ? |_| BadSession
	id_text = Str.from_utf8(id_bytes) ? |_| BadSession
	id = UserId.from_str(id_text) ? |_| BadSession
	signed_at = second_from_digits(second_part) ? |_| BadSession
	mac = Base64Url.decode(Str.from_utf8(mac_part) ? |_| BadSession) ? |_| BadSession
	if mac.len() == 32 {
		Ok(Session.Claim.({ id, signed_at, origin, mac }))
	} else {
		Err(BadSession)
	}
}

## The second `digits` spell: `0`, or a canonical number
## (`Ascii.canonical_number`) at most the largest `I64`; so each second has
## one spelling, the one `to_str` writes and the signature is over.
second_from_digits : List(U8) -> Try(Timestamp, [NotASecond])
second_from_digits = |digits|
	match digits {
		['0'] => Ok(Timestamp.at_second(0))
		_ =>
			match Ascii.canonical_number(digits, { most_digits: 19 }) {
				Ok(number) if number <= I64.highest.to_u64_wrap() =>
					Ok(Timestamp.at_second(number.to_i64_wrap()))
				_ => Err(NotASecond)
			}
	}

## The GitHub state is what stops another site signing a browser in to the
## wrong account. A sign-in sends GitHub a token holding a random nonce, the
## second it was issued and where to go after, signed by the host with the
## server's secret, and sets the same nonce in a cookie for this browser.
## GitHub hands the token back. The return is good when the signature
## matches, the cookie holds the token's nonce, and the token is under ten
## minutes old, so a code GitHub gave someone else can't be planted on a
## browser: its state would name another browser's nonce.
##
## The token is the nonce in base64url, the second in decimal, and the path
## in base64url, joined by `.`, and then a `.` and the signature. What is
## signed starts `github-state`, and a session's signed bytes start with a
## user's digits, so neither signature can stand for the other.
##
## A state also says what the trip to GitHub is for (`Errand`), so GitHub's
## answer can't serve as anything else: a sign-in, or a signed-in human
## linking GitHub to their account, which names that human.
##
## This module is the pure part. The host makes the nonce and the signature
## (`GitHubRoute` asks it), and `GitHubSignIn` calls `check`.
import Ascii
import Base64Url
import FactFile
import Html
import UserId

GitHubState :: {
	nonce : List(U8),
	issued_at : I64,
	next : Html.SitePath,
	errand : GitHubState.Errand,
}.{

	## What a trip to GitHub is for: to sign in, or to link GitHub to the
	## human with this id.
	Errand : [SignIn, Link(UserId)]

	## How long a state lasts: time to sign in at GitHub, and short enough
	## that a leaked one goes stale.
	lifetime_seconds : I64
	lifetime_seconds = 10 * 60

	## How many random bytes a nonce holds.
	nonce_bytes : U64
	nonce_bytes = 32

	## What a GitHub sign-in's cookies say beside their value. `SameSite=Lax`
	## lets GitHub's redirect back carry one, as a top-level navigation.
	cookie_attributes : Str
	cookie_attributes = "HttpOnly; Secure; SameSite=Lax"

	## A new state for `errand`, issued at `now`, going to `next` after. A
	## nonce of any other length than `nonce_bytes` is the caller's bug, and
	## crashes.
	issue : {
		nonce : List(U8),
		now : I64,
		next : Html.SitePath,
		errand : GitHubState.Errand,
	} -> GitHubState
	issue = |
		{
			nonce,
			now,
			next,
			errand,
		},
	|
		if (nonce.len() == GitHubState.nonce_bytes)
			GitHubState.(
				{
					nonce,
					issued_at: now,
					next,
					errand,
				},
			)
		else
			crash "GitHubState.issue: a nonce is ${GitHubState.nonce_bytes.to_str()} bytes, not ${nonce.len().to_str()}"

	## The bytes the host signs for this state.
	signed_bytes : GitHubState -> List(U8)
	signed_bytes = |state| bytes_signed_of(payload_of(state))

	## The token for this state, its signature `mac`.
	token : GitHubState, List(U8) -> Str
	token = |state, mac| "${payload_of(state)}.${Base64Url.encode(mac)}"

	## Where to go once signed in.
	next : GitHubState -> Html.SitePath
	next = |GitHubState.(state)| state.next

	## What the trip to GitHub is for.
	errand : GitHubState -> GitHubState.Errand
	errand = |GitHubState.(state)| state.errand

	## What a token claims before its signature is checked.
	Claim :: { payload : Str, mac : List(U8) }.{

		## The claim `text` spells; unless it is no token's shape
		## (`NotAClaim`).
		from_str : Str -> Try(GitHubState.Claim, [NotAClaim])
		from_str = |text|
			match text.split_on(".") {
				[
					nonce_part,
					second_part,
					next_part,
					errand_part,
					mac_part,
				] =>
					match Base64Url.decode(mac_part) {
						Ok(mac) => Ok(
							GitHubState.Claim.(
								{
									payload: Str.join_with(
										[
											nonce_part,
											second_part,
											next_part,
											errand_part,
										],
										".",
									),
									mac,
								},
							),
						)
						Err(NotBase64Url) => Err(NotAClaim)
					}
				_ => Err(NotAClaim)
			}

		## The bytes its signature must be over.
		signed_bytes : GitHubState.Claim -> List(U8)
		signed_bytes = |GitHubState.Claim.(claim)| bytes_signed_of(claim.payload)

		## The signature it carries, for the host to check.
		mac : GitHubState.Claim -> List(U8)
		mac = |GitHubState.Claim.(claim)| claim.mac
	}

	## The state `claim` holds, when the host's `verdict` on its signature is
	## `Matches`; else `Unsigned`. What the signature covers is the server's
	## own writing, so a payload that doesn't read is `Unsigned` too.
	from_claim : {
		claim : GitHubState.Claim,
		verdict : [DoesNotMatch, Matches],
	} -> [Signed(GitHubState), Unsigned]
	from_claim = |{ claim, verdict }| {
		GitHubState.Claim.(held) = claim
		match verdict {
			DoesNotMatch => Unsigned
			Matches =>
				match state_from_payload(held.payload) {
					Ok(state) => Signed(state)
					Err(BadPayload) => Unsigned
				}
		}
	}

	## What `check` says of a state.
	Verdict : [
		Valid,
		Expired,
		Mismatched,
	]

	## Whether this state is good, from this browser, at `now`: `Mismatched`
	## when the browser's cookie is missing or holds another nonce, said
	## first, as a state from another browser is a forgery however old it is;
	## `Expired` at `lifetime_seconds` old or more, or issued after `now`;
	## else `Valid`. The sums are in `I128`, so no second a token carries
	## overflows them.
	check : GitHubState, { cookie : GitHubState.Cookie, now : I64 } -> GitHubState.Verdict
	check = |GitHubState.(state), { cookie, now }| {
		age = now.to_i128() - state.issued_at.to_i128()
		match cookie {
			Unsent => Mismatched
			Sent(nonce) if nonce != state.nonce => Mismatched
			Sent(_) if age < 0 or age >= GitHubState.lifetime_seconds.to_i128() => Expired
			Sent(_) => Valid
		}
	}

	## The state cookie as a browser sent it: its nonce, or none.
	Cookie : [Sent(List(U8)), Unsent]

	## The state cookie in a request's `Cookie` header, `Unsent` for none,
	## for two, or for one whose value is no base64url.
	cookie_from_header : List(U8) -> GitHubState.Cookie
	cookie_from_header = |header| {
		named =
			header.split_on(';')
				.map(Ascii.trim_spaces)
				.keep_if(|pair| pair.starts_with(cookie_prefix))
		match named {
			[only] =>
				match Str.from_utf8(only.drop_first(cookie_prefix.len())) {
					Ok(text) =>
						match Base64Url.decode(text) {
							Ok(nonce) => Sent(nonce)
							Err(NotBase64Url) => Unsent
						}
					Err(_) => Unsent
				}
			_ => Unsent
		}
	}

	## The `Set-Cookie` header's value that sets this state's cookie for its
	## lifetime.
	set_cookie_text : GitHubState -> Str
	set_cookie_text = |GitHubState.(state)| {
		value = Base64Url.encode(state.nonce)
		age = GitHubState.lifetime_seconds.to_str()
		"${cookie_prefix_text}${value}; Path=/; Max-Age=${age}; ${GitHubState.cookie_attributes}"
	}

	## The `Set-Cookie` header's value that has a browser forget the state's
	## cookie, so a state is used once from a browser.
	clear_cookie_text : Str
	clear_cookie_text = "${cookie_prefix_text}; Path=/; Max-Age=0; ${GitHubState.cookie_attributes}"

	is_eq : _
}

cookie_prefix_text : Str
cookie_prefix_text = "__Host-gopher_github_state="

cookie_prefix : List(U8)
cookie_prefix = cookie_prefix_text.to_utf8()

## What is signed: a word no session's bytes start with, then the payload.
bytes_signed_of : Str -> List(U8)
bytes_signed_of = |payload| "github-state\n${payload}".to_utf8()

## The nonce, the second, the path and the errand, as a token holds them.
payload_of : GitHubState -> Str
payload_of = |GitHubState.(state)| {
	path = Base64Url.encode(state.next.to_str().to_utf8())
	nonce = Base64Url.encode(state.nonce)
	"${nonce}.${state.issued_at.to_str()}.${path}.${errand_text(state.errand)}"
}

## An errand as a token spells it.
errand_text : GitHubState.Errand -> Str
errand_text = |errand|
	match errand {
		SignIn => "sign-in"
		Link(human) => "${link_prefix}${human.to_str()}"
	}

link_prefix : Str
link_prefix = "link-"

## The errand a token's part spells; unless it spells none (`BadPayload`).
errand_from_text : Str -> Try(GitHubState.Errand, [BadPayload])
errand_from_text = |text|
	if (text == "sign-in")
		Ok(SignIn)
	else if (text.starts_with(link_prefix))
		match UserId.from_str(text.drop_prefix(link_prefix)) {
			Ok(human) => Ok(Link(human))
			Err(NotAUserId) => Err(BadPayload)
		}
	else
		Err(BadPayload)

## The state a payload holds; unless any part doesn't read (`BadPayload`).
state_from_payload : Str -> Try(GitHubState, [BadPayload])
state_from_payload = |payload|
	match payload.split_on(".") {
		[
			nonce_part,
			second_part,
			next_part,
			errand_part,
		] => {
			nonce = Base64Url.decode(nonce_part) ? |_| BadPayload
			issued_at = FactFile.seconds_from_file(second_part.to_utf8()) ? |_| BadPayload
			path_bytes = Base64Url.decode(next_part) ? |_| BadPayload
			path_text = Str.from_utf8(path_bytes) ? |_| BadPayload
			next = Html.SitePath.from_str(path_text) ? |_| BadPayload
			errand = errand_from_text(errand_part)?
			Ok(
				GitHubState.(
					{
						nonce,
						issued_at,
						next,
						errand,
					},
				),
			)
		}
		_ => Err(BadPayload)
	}

# ── tests
agents_path : Html.SitePath
agents_path = Html.SitePath.from_str("/agents") ?? crash "GitHubState's tests: a site path"

nonce_held : List(U8)
nonce_held = List.repeat('n', 32)

## A state issued at 1000: its window is 1000 to 1599.
issued : GitHubState
issued = GitHubState.issue({
	nonce: nonce_held,
	now: 1000,
	next: agents_path,
	errand: SignIn,
})

## The same state, sent to link GitHub to Steve.
issued_to_link : GitHubState
issued_to_link = GitHubState.issue({
	nonce: nonce_held,
	now: 1000,
	next: agents_path,
	errand: Link(UserId.steve),
})

## What `check` says of `issued`, back with `cookie` at `now`.
back : { cookie : GitHubState.Cookie, now : I64 } -> GitHubState.Verdict
back = |asked| issued.check(asked)

# Valid at the window's two ends and inside it.
expect
	[
		1000,
		1300,
		1599,
	].all(|now| back({ cookie: Sent(nonce_held), now }) == Valid)
# Expired at the lifetime, past it, and before it was issued.
expect
	[
		1600,
		99999,
		999,
	].all(|now| back({ cookie: Sent(nonce_held), now }) == Expired)
# Mismatched: no cookie, or another nonce, one byte short or over included;
# and that is said before the time.
expect
	[
		Unsent,
		Sent([]),
		Sent(List.repeat('m', 32)),
		Sent(List.repeat('n', 31)),
		Sent(List.repeat('n', 33)),
	].all(|cookie| back({ cookie, now: 1300 }) == Mismatched)
expect back({ cookie: Unsent, now: 99999 }) == Mismatched
expect back({ cookie: Sent([]), now: 999 }) == Mismatched
# A token read back: the signature, the bytes signed, the state.
expect {
	mac = List.repeat(7, 32)
	claimed = GitHubState.Claim.from_str(issued.token(mac)) ?? crash "GitHubState's tests: a token"
	claimed.mac() == mac
		and claimed.signed_bytes() == issued.signed_bytes()
		and GitHubState.from_claim({ claim: claimed, verdict: Matches }) == Signed(issued)
		and GitHubState.from_claim({ claim: claimed, verdict: DoesNotMatch }) == Unsigned
}
# Each errand reads back, and two errands are signed apart.
expect {
	mac = List.repeat(7, 32)
	read_back = |state| {
		claim = GitHubState.Claim.from_str(state.token(mac)) ?? crash "GitHubState's tests: a token"
		GitHubState.from_claim({ claim, verdict: Matches })
	}
	read_back(issued_to_link) == Signed(issued_to_link)
		and issued_to_link.errand() == Link(UserId.steve)
		and read_back(issued) == Signed(issued)
		and issued.errand() == SignIn
		and issued_to_link.signed_bytes() != issued.signed_bytes()
}
# What is signed starts with a word no session's bytes start with.
expect issued.signed_bytes().starts_with("github-state\n".to_utf8())
# No token: too few parts, too many, or a signature that is no base64url.
expect
	[
		"",
		"a.b.c.d",
		"a.b.c.d.e.f",
		"a.b.c.d.!",
	].all(|text| GitHubState.Claim.from_str(text).map_ok(|_| {}) == Err(NotAClaim))
# A payload that doesn't read is unsigned even under a good signature.
expect {
	unread = |text| {
		claim = GitHubState.Claim.from_str(text) ?? crash "GitHubState's tests: a token's shape"
		GitHubState.from_claim({ claim, verdict: Matches })
	}
	path = Base64Url.encode("/agents".to_utf8())
	bad_path = Base64Url.encode("//evil.example".to_utf8())
	[
		"bm9uY2U.x.${path}.sign-in.AAAA",
		"bm9uY2U.1000.${bad_path}.sign-in.AAAA",
		"!.1000.${path}.sign-in.AAAA",
		"bm9uY2U.1000.${path}.sign-out.AAAA",
		"bm9uY2U.1000.${path}.link-.AAAA",
		"bm9uY2U.1000.${path}.link-0.AAAA",
		"bm9uY2U.1000.${path}.link-x.AAAA",
	].all(|text| unread(text) == Unsigned)
}
# The cookie, set and read back, among others; none for two, or a bad value.
expect
	issued.set_cookie_text()
		== "__Host-gopher_github_state=${Base64Url.encode(nonce_held)}; Path=/; Max-Age=600; HttpOnly; Secure; SameSite=Lax"
expect
	GitHubState.cookie_from_header("a=b; ${cookie_prefix_text}${Base64Url.encode(nonce_held)}; c=d".to_utf8())
		== Sent(nonce_held)
expect
	[
		"",
		"a=b",
		"__Host-gopher_auth=x",
		"${cookie_prefix_text}!",
		"${cookie_prefix_text}AA; ${cookie_prefix_text}AA",
	].all(|header| GitHubState.cookie_from_header(header.to_utf8()) == Unsent)
expect
	GitHubState.clear_cookie_text
		== "__Host-gopher_github_state=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax"

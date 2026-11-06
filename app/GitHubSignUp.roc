## A GitHub sign-up carries a new human from GitHub's answer to the name they
## choose. GitHub has said who they are, no account holds that yet, and the
## name comes in a later request. So the server hands their browser a token
## holding the GitHub id, the second it was issued and where to go after,
## signed by the host with the server's secret, in a cookie that lasts ten
## minutes. A browser that rewrites the id breaks the signature, and another
## site can't set a `__Host-` cookie, so no one can plant their own sign-up on
## someone else's browser.
##
## The token is the id and the second in decimal, and the path in base64url,
## joined by `.`, and then a `.` and the signature. What is signed starts
## `github-sign-up`, so a state's or a session's signature can't stand for
## one.
##
## This module is the pure part. The host makes the signature (`GitHubRoute`
## asks it), and `GitHubSignIn` calls `check`. A token is not spent: once its
## id has an account, `GitHubSignIn` refuses it, so it makes one account.
import Ascii
import Base64Url
import GitHubId
import GitHubState
import Html
import Timestamp

GitHubSignUp :: {
	github : GitHubId,
	issued_at : Timestamp,
	next : Html.SitePath,
}.{

	## A new sign-up for the GitHub account `github`, issued at `now`, going to
	## `next` once its human has a name.
	issue : {
		github : GitHubId,
		now : Timestamp,
		next : Html.SitePath,
	} -> GitHubSignUp
	issue = |{ github, now, next }|
		GitHubSignUp.({ github, issued_at: now, next })

	## The bytes the host signs for this sign-up.
	signed_bytes : GitHubSignUp -> List(U8)
	signed_bytes = |sign_up| bytes_signed_of(payload_of(sign_up))

	## The GitHub account it proves.
	github : GitHubSignUp -> GitHubId
	github = |GitHubSignUp.(sign_up)| sign_up.github

	## Where to go once signed in.
	next : GitHubSignUp -> Html.SitePath
	next = |GitHubSignUp.(sign_up)| sign_up.next

	## What a cookie claims before its signature is checked.
	Claim :: { payload : Str, mac : List(U8) }.{

		## The claim the sign-up cookie in a request's `Cookie` header makes;
		## unless there is none, there are two, or it is no token's shape
		## (`NotAClaim`).
		from_cookie_header : List(U8) -> Try(GitHubSignUp.Claim, [NotAClaim])
		from_cookie_header = |header| {
			named =
				header.split_on(';')
					.map(Ascii.trim_spaces)
					.keep_if(|pair| pair.starts_with(cookie_prefix))
			match named {
				[only] =>
					match Str.from_utf8(only.drop_first(cookie_prefix.len())) {
						Ok(text) => claim_from_token(text)
						Err(_) => Err(NotAClaim)
					}
				_ => Err(NotAClaim)
			}
		}

		## The bytes its signature must be over.
		signed_bytes : GitHubSignUp.Claim -> List(U8)
		signed_bytes = |GitHubSignUp.Claim.(claim)| bytes_signed_of(claim.payload)

		## The signature it carries, for the host to check.
		mac : GitHubSignUp.Claim -> List(U8)
		mac = |GitHubSignUp.Claim.(claim)| claim.mac
	}

	## The sign-up `claim` holds, when the host's `verdict` on its signature is
	## `Matches`; else `Unsigned`. What the signature covers is the server's
	## own writing, so a payload that doesn't read is `Unsigned` too.
	from_claim : {
		claim : GitHubSignUp.Claim,
		verdict : [DoesNotMatch, Matches],
	} -> [Signed(GitHubSignUp), Unsigned]
	from_claim = |{ claim, verdict }| {
		GitHubSignUp.Claim.(held) = claim
		match verdict {
			DoesNotMatch => Unsigned
			Matches =>
				match sign_up_from_payload(held.payload) {
					Ok(sign_up) => Signed(sign_up)
					Err(BadPayload) => Unsigned
				}
		}
	}

	## Whether this sign-up is in time at `now`: `Expired` at a state's
	## lifetime old or more, or issued after `now`; else `Valid`.
	check : GitHubSignUp, Timestamp -> [Valid, Expired]
	check = |GitHubSignUp.(sign_up), now|
		if GitHubState.is_stale({ issued_at: sign_up.issued_at, now }) {
			Expired
		} else {
			Valid
		}

	## The `Set-Cookie` header's value that sets this sign-up's cookie, its
	## signature `mac`, for its lifetime.
	set_cookie_text : GitHubSignUp, List(U8) -> Str
	set_cookie_text = |sign_up, mac| {
		value = "${payload_of(sign_up)}.${Base64Url.encode(mac)}"
		age = GitHubState.lifetime_seconds.to_str()
		"${cookie_prefix_text}${value}; Path=/; Max-Age=${age}; ${GitHubState.cookie_attributes}"
	}

	## The `Set-Cookie` header's value that has a browser forget the sign-up.
	clear_cookie_text : Str
	clear_cookie_text = "${cookie_prefix_text}; Path=/; Max-Age=0; ${GitHubState.cookie_attributes}"

	is_eq : _
}

cookie_prefix_text : Str
cookie_prefix_text = "__Host-gopher_github_sign_up="

cookie_prefix : List(U8)
cookie_prefix = cookie_prefix_text.to_utf8()

## What is signed: a word no state's or session's bytes start with, then the
## payload.
bytes_signed_of : Str -> List(U8)
bytes_signed_of = |payload| "github-sign-up\n${payload}".to_utf8()

## The id, the second and the path, as a token holds them.
payload_of : GitHubSignUp -> Str
payload_of = |GitHubSignUp.(sign_up)| {
	path = Base64Url.encode(sign_up.next.to_str().to_utf8())
	"${sign_up.github.to_str()}.${sign_up.issued_at.to_str()}.${path}"
}

## The claim `text` spells; unless it is no token's shape (`NotAClaim`).
claim_from_token : Str -> Try(GitHubSignUp.Claim, [NotAClaim])
claim_from_token = |text|
	match text.split_on(".") {
		[github_part, second_part, next_part, mac_part] =>
			match Base64Url.decode(mac_part) {
				Ok(mac) => Ok(
					GitHubSignUp.Claim.(
						{ payload: "${github_part}.${second_part}.${next_part}", mac },
					),
				)
				Err(NotBase64Url) => Err(NotAClaim)
			}
		_ => Err(NotAClaim)
	}

## The sign-up a payload holds; unless any part doesn't read (`BadPayload`).
sign_up_from_payload : Str -> Try(GitHubSignUp, [BadPayload])
sign_up_from_payload = |payload|
	match payload.split_on(".") {
		[github_part, second_part, next_part] => {
			github = GitHubId.from_file(github_part.to_utf8()) ? |_| BadPayload
			issued_at = Timestamp.from_file(second_part.to_utf8()) ? |_| BadPayload
			path_bytes = Base64Url.decode(next_part) ? |_| BadPayload
			path_text = Str.from_utf8(path_bytes) ? |_| BadPayload
			next = Html.SitePath.from_str(path_text) ? |_| BadPayload
			Ok(GitHubSignUp.({ github, issued_at, next }))
		}
		_ => Err(BadPayload)
	}

# ── tests
agents_path : Html.SitePath
agents_path = Html.SitePath.from_str("/agents") ?? crash "GitHubSignUp's tests: a site path"

github_id : GitHubId
github_id = GitHubId.from_u64(583231) ?? crash "GitHubSignUp's tests: an id"

## A sign-up issued at 1000: its window is 1000 to 1599.
issued : GitHubSignUp
issued = GitHubSignUp.issue({
	github: github_id,
	now: Timestamp.at_second(1000),
	next: agents_path,
})

## A signature, as the host's is 32 bytes.
tests_mac : List(U8)
tests_mac = List.repeat(7, 32)

## What the cookie of `issued` sets, as a browser sends it back.
sent_cookie : Str
sent_cookie = {
	whole = issued.set_cookie_text(tests_mac)
	whole.split_on(";").first() ?? crash "GitHubSignUp's tests: a cookie has a value"
}

# What it holds.
expect issued.github() == github_id and issued.next() == agents_path
# Valid at the window's two ends and inside it.
expect
	[1000, 1300, 1599].map(Timestamp.at_second).all(|now| issued.check(now) == Valid)
# Expired at the lifetime, past it, and before it was issued.
expect
	[1600, 99999, 999].map(Timestamp.at_second).all(|now| issued.check(now) == Expired)
# The cookie, set for ten minutes and read back among others: the signature,
# the bytes signed, the sign-up.
expect
	issued.set_cookie_text(tests_mac)
		== "${cookie_prefix_text}583231.1000.${Base64Url.encode("/agents".to_utf8())}.${Base64Url.encode(tests_mac)}; Path=/; Max-Age=600; HttpOnly; Secure; SameSite=Lax"
expect {
	claimed =
		GitHubSignUp.Claim.from_cookie_header("a=b; ${sent_cookie}; c=d".to_utf8())
			?? crash "GitHubSignUp's tests: a cookie"
	claimed.mac() == tests_mac
		and claimed.signed_bytes() == issued.signed_bytes()
		and GitHubSignUp.from_claim({ claim: claimed, verdict: Matches }) == Signed(issued)
		and GitHubSignUp.from_claim({ claim: claimed, verdict: DoesNotMatch }) == Unsigned
}
# What is signed starts with a word no state's or session's bytes start with.
expect issued.signed_bytes().starts_with("github-sign-up\n".to_utf8())
# No claim: no cookie, two, too few parts, too many, or a signature that is no
# base64url.
expect
	[
		"",
		"a=b",
		"__Host-gopher_auth=x",
		"${sent_cookie}; ${sent_cookie}",
		"${cookie_prefix_text}a.b.c",
		"${cookie_prefix_text}a.b.c.d.e",
		"${cookie_prefix_text}a.b.c.!",
	].all(
		|header| {
			claimed = GitHubSignUp.Claim.from_cookie_header(header.to_utf8())
			claimed.map_ok(|_| {}) == Err(NotAClaim)
		},
	)
# A payload that doesn't read is unsigned even under a good signature.
expect {
	unread = |text| {
		claim =
			GitHubSignUp.Claim.from_cookie_header("${cookie_prefix_text}${text}".to_utf8())
				?? crash "GitHubSignUp's tests: a token's shape"
		GitHubSignUp.from_claim({ claim, verdict: Matches })
	}
	path = Base64Url.encode("/agents".to_utf8())
	bad_path = Base64Url.encode("//evil.example".to_utf8())
	[
		"x.1000.${path}.AAAA",
		"0.1000.${path}.AAAA",
		"7.x.${path}.AAAA",
		"7.1000.${bad_path}.AAAA",
		"7.1000.!.AAAA",
	].all(|text| unread(text) == Unsigned)
}
expect
	GitHubSignUp.clear_cookie_text
		== "__Host-gopher_github_sign_up=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax"

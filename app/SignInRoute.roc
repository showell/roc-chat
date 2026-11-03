## This module answers the sign-in routes (`Route` lists them) and checks
## a request's session before any route.
##
## - `GET /login` is the sign-in page: a name and a password, and `next`,
##   where to go after, from the query (`?next=<path>`), `/agents` when
##   there is none.
## - `POST /login` checks the password: the user named must be a human,
##   their password file must hold a bcrypt hash, and the host must say the
##   password matches it (`Host.password_matches_bcrypt_hash!`). Then the
##   answer signs a session (`Session`) and sends the browser to `next`
##   with its cookie (a 303). A wrong name or password, or a human with no
##   password, is one 401 that says no more, on the sign-in page again.
##   Neither answer may be kept by a browser or a proxy.
## - `POST /logout` has the browser forget the cookie, and sends it to the
##   sign-in page.
## - A human invite's redemption (`HumanInvitesRoute`) starts a session the
##   same way, once it has set the invited human's password
##   (`start_session_by_invite!`, which takes only what
##   `HumanInvite.redeem` makes).
##
## `sign_in_by_session!` is the check a request with a session cookie, and
## no `Authorization` header, passes before any route (main's
## `load_actor!`): the host checks the signature, `Session.admit` decides,
## and the human must still have a password, so removing a password file
## ends every session of its human. `SignedIn.by_session` is its one door.
import pf.Host
import pf.Http
import FactFile
import FileSystem
import Html
import HttpAnswer
import HumanInvite
import Page
import Session
import SignedIn
import UnvalidatedString
import UrlEncodedForm
import Users

SignInRoute :: [].{

	## The human the session in the `Cookie` header `cookie` admits, among
	## `users`, at `now`; unless it holds no session (`NoSession`), one that
	## is no session's spelling (`BadSession`), or one that admits no one
	## (`SessionRefused`: its signature, its date or its user), or its human
	## has no password (`NoPassword`), or the password's file could not be
	## read (`FileSystem`).
	sign_in_by_session! : {
		cookie : List(U8),
		users : Users,
		now : I64,
	} => Try(
		SignedIn,
		[
			NoSession,
			BadSession,
			SessionRefused,
			NoPassword,
			FileSystem(FileSystem.Fault),
		],
	)
	sign_in_by_session! = |
		{
			cookie,
			users,
			now,
		},
	| {
		claim = Session.claim_from_cookie_header(cookie)?
		verdict = Host.hmac_sha256_with_server_secret_matches!(claim.signed_bytes(), claim.mac())
		admitted = Session.admit({
			claim,
			verdict,
			now,
			users,
		})?
		match FileSystem.read_password_hash!(admitted.human().id()) {
			Ok(File(_)) => Ok(SignedIn.by_session(admitted))
			Ok(NoFile) => Err(NoPassword)
			Err(fault) => Err(FileSystem(fault))
		}
	}

	## A GET of `/login`: the sign-in page for `viewer`, going to the
	## query's `next` once signed in; a 400 when the query is anything but
	## none or `next=<path>`.
	show_login : { viewer : SignedIn.Actor, query : List(U8) } -> Http.Response
	show_login = |{ viewer, query }|
		match next_from_query(query) {
			Ok(next) => HttpAnswer.page(
				200,
				Page.login({
					viewer,
					next,
					problem: NoProblem,
				}),
			)
			Err(BadNext) => bad_next_answer
		}

	## A POST of `/login`, from `viewer`, of the form `body`, at `now`: a
	## session for the human the name and password admit, and a 303 to the
	## form's `next`; or the sign-in page again, a 401, saying no more than
	## that the two don't match. A request with an API key may not sign in.
	## Never stored.
	sign_in! : {
		viewer : SignedIn.Actor,
		users : Users,
		body : List(U8),
		now : I64,
	} => Http.Response
	sign_in! = |
		{
			viewer,
			users,
			body,
			now,
		},
	| {
		answer =
			match next_from_form(body) {
				Err(BadNext) => bad_next_answer
				Ok(next) =>
					match find_human_by_password!({
						viewer,
						users,
						body,
					}) {
						Ok(human) =>
							HttpAnswer.with_header(
								HttpAnswer.see_other(next.to_str()),
								sign_session_cookie!({ human, now }),
							)
						Err(NoMatch) => HttpAnswer.page(
							401,
							Page.login({
								viewer,
								next,
								problem: Problem(no_match_words),
							}),
						)
						Err(ByApiKey) => HttpAnswer.page(
							403,
							Page.notice({ title: "Refused", text: "An API key never signs in." }),
						)
						Err(NotABcryptHash) => HttpAnswer.page(
							500,
							Page.notice({
								title: "Failed",
								text: "The password's file holds no bcrypt hash.",
							}),
						)
						Err(FileSystem(fault)) => HttpAnswer.page(
							500,
							Page.notice({ title: "Failed", text: FileSystem.fault_words(fault) }),
						)
					}
			}
		HttpAnswer.never_stored(answer)
	}

	## The answer to a human invite redeemed at `now`: a session for the
	## human its admission admits, and a 303 to `default_next` with its
	## cookie. The redemption has set their password, which the session
	## needs (`sign_in_by_session!`). Never stored.
	start_session_by_invite! : HumanInvite.Admission, I64 => Http.Response
	start_session_by_invite! = |admission, now| {
		cookie = sign_session_cookie!({ human: admission.human(), now })
		onward = HttpAnswer.see_other(default_next.to_str())
		HttpAnswer.never_stored(HttpAnswer.with_header(onward, cookie))
	}

	## A POST of `/logout`: the browser forgets the session's cookie, and goes
	## to the sign-in page. Never stored.
	sign_out : Http.Response
	sign_out = HttpAnswer.never_stored(
		HttpAnswer.with_header(
			HttpAnswer.see_other("/login"),
			set_cookie_header(Session.clear_cookie_text),
		),
	)

	## A 303 to the sign-in page, which goes on to `next` once signed in: a
	## page asked for by no one signed in.
	login_redirect : Html.SitePath -> Http.Response
	login_redirect = |next| HttpAnswer.see_other("/login?next=${next.to_str()}")
}

## The `Set-Cookie` header of a session for `human`, signed at `now` by the
## host's HMAC under the server's secret.
sign_session_cookie! : { human : Users.Human, now : I64 } => Http.Header
sign_session_cookie! = |{ human, now }| {
	mac = Host.hmac_sha256_with_server_secret!(
		Session.signed_bytes({
			id: human.id(),
			signed_at: now,
		}),
	)
	cookie = Session.cookie_value({
		id: human.id(),
		signed_at: now,
		mac,
	})
	set_cookie_header(Session.set_cookie_text(cookie))
}

## A `Set-Cookie` header of `text`.
set_cookie_header : Str -> Http.Header
set_cookie_header = |text| { name: "set-cookie".to_utf8(), value: text.to_utf8() }

## Where to go once signed in when nothing says.
default_next : Html.SitePath
default_next = Html.SitePath.from_str("/agents") ?? crash "SignInRoute.default_next: /agents is a site path"

## The sign-in's words when a name and a password don't match.
no_match_words : Str
no_match_words = "The name and the password don't match a human's."

## The 400 for a `next` that is no path on this site.
bad_next_answer : Http.Response
bad_next_answer = HttpAnswer.page(
	400,
	Page.notice({
		title: "Refused",
		text: "Where to go after signing in is no path on this site.",
	}),
)

## The `next` a sign-in page's `query` names: none, `default_next`; or
## `next=` and a path on this site; else `BadNext`.
next_from_query : List(U8) -> Try(Html.SitePath, [BadNext])
next_from_query = |query|
	if (query.is_empty())
		Ok(default_next)
	else if query.starts_with(next_prefix) {
		unchecked = UnvalidatedString.from_utf8(query.drop_first(next_prefix.len())) ? |NotUtf8| BadNext
		unchecked.site_path().map_err(|NotASitePath| BadNext)
	} else
		Err(BadNext)

next_prefix : List(U8)
next_prefix = "next=".to_utf8()

## The `next` a sign-in form `body` holds: none, `default_next`; or a path
## on this site; else `BadNext`.
next_from_form : List(U8) -> Try(Html.SitePath, [BadNext])
next_from_form = |body|
	match UrlEncodedForm.field({ body, name: "next" }) {
		Err(MissingField) => Ok(default_next)
		Err(_) => Err(BadNext)
		Ok(unchecked) => unchecked.site_path().map_err(|NotASitePath| BadNext)
	}

## The human whose name and password the form `body` holds, among `users`;
## unless they don't match a human's (`NoMatch`: no such name, an agent's,
## no password, or another password), `viewer` holds an API key
## (`ByApiKey`), or the password's file is not a hash or can't be read.
find_human_by_password! : {
	viewer : SignedIn.Actor,
	users : Users,
	body : List(U8),
} => Try(
	Users.Human,
	[
		NoMatch,
		ByApiKey,
		NotABcryptHash,
		FileSystem(FileSystem.Fault),
	],
)
find_human_by_password! = |
	{
		viewer,
		users,
		body,
	},
| {
	_ =
		match viewer {
			SignedIn(acting) =>
				match acting.credential() {
					ApiKey(_) => Err(ByApiKey)
					Session => Ok({})
				}
			Anonymous => Ok({})
		}?
	name_text = UrlEncodedForm.field({ body, name: "name" }) ? |_| NoMatch
	name = name_text.name() ? |_| NoMatch
	password_text = UrlEncodedForm.field({ body, name: "password" }) ? |_| NoMatch
	password = password_text.password() ? |NotAPassword| NoMatch
	user = users.user_by_name(name) ? |NoSuchUser| NoMatch
	human = user.as_human() ? |Agent(_)| NoMatch
	hash =
		match FileSystem.read_password_hash!(human.id()) {
			Ok(File(bytes)) => Ok(FactFile.word_from_file(bytes))
			Ok(NoFile) => Err(NoMatch)
			Err(fault) => Err(FileSystem(fault))
		}?
	match Host.password_matches_bcrypt_hash!(password.bytes_to_check(), hash) {
		Matches => Ok(human)
		DoesNotMatch => Err(NoMatch)
		NotABcryptHash => Err(NotABcryptHash)
	}
}

# ── tests
## The `next` a query or a form names, as a test reads it.
next_text : Try(Html.SitePath, [BadNext]) -> Try(Str, [BadNext])
next_text = |next| next.map_ok(Html.SitePath.to_str)

# A query's `next`: none is /agents; a path on this site is itself; any
# other path, another field, or bytes that are no text, refused.
expect next_text(next_from_query([])) == Ok("/agents")
expect next_text(next_from_query("next=/chat/dm/1_1/plans".to_utf8())) == Ok("/chat/dm/1_1/plans")
expect
	[
		"next=",
		"next=//evil.example",
		"next=https://evil.example",
		"next=/a?b",
		"next=/a/../b",
		"to=/agents",
		"next=/agents&x=1",
	].all(|query| next_from_query(query.to_utf8()) == Err(BadNext))
expect next_from_query("next=/".to_utf8().concat([0xff])) == Err(BadNext)
# A form's `next`: none is /agents; a path on this site, decoded, is itself;
# any other, or two, refused.
expect next_text(next_from_form("name=Steve".to_utf8())) == Ok("/agents")
expect next_text(next_from_form("next=%2Fchat%2Fdm%2F1_1%2Fplans&name=Steve".to_utf8())) == Ok("/chat/dm/1_1/plans")
expect
	[
		"next=%2F%2Fevil.example",
		"next=",
		"next=/a&next=/b",
		"next=%G0",
	].all(|body| next_from_form(body.to_utf8()) == Err(BadNext))
# The redirect to sign in carries where to go after; signing out forgets the
# cookie and is never stored.
expect
	SignInRoute.login_redirect(Html.SitePath.from_str("/chat/dm/1_1/plans") ?? crash "SignInRoute's tests: a site path").headers
		== [{ name: "location".to_utf8(), value: "/login?next=/chat/dm/1_1/plans".to_utf8() }]
expect
	SignInRoute.sign_out.status == 303
		and SignInRoute.sign_out.headers
			== [
				{ name: "location".to_utf8(), value: "/login".to_utf8() },
				set_cookie_header(Session.clear_cookie_text),
				{ name: "cache-control".to_utf8(), value: "no-store".to_utf8() },
			]
# The page, both sides of its query: 200 with a good one, 400 with a bad one.
expect SignInRoute.show_login({ viewer: Anonymous, query: [] }).status == 200
expect SignInRoute.show_login({ viewer: Anonymous, query: "next=x".to_utf8() }).status == 400

## This module answers the sign-in routes (`Route` lists them) and checks
## a request's session before any route.
##
## - `GET /login` is the sign-in page: a name and a password, and `next`,
##   where to go after, from the query (`?next=<path>`), or Browse (`/chat`)
##   when there is none (`SignInRequest` reads it); and a link to sign in
##   with GitHub, when the server has GitHub's settings (`GitHubRoute`).
## - `POST /login` checks the password: the user named must be a human,
##   their password file must hold a bcrypt hash, and the host must say the
##   password matches it (`Host.password_matches_bcrypt_hash!`). Then the
##   answer signs a session (`Session`) and sends the browser to `next`
##   with its cookie (a 303). A wrong name or password, a human with no
##   password, or one whose file holds no hash the host checks, is one 401
##   that says no more, on the sign-in page again. Each of those runs one
##   bcrypt check, against `dummy_hash` where there is no hash, so how long
##   the answer takes says nothing of which names exist. When the host has
##   run as many checks as it lets run for now, the answer is a 429, at once.
##   No answer may be kept by a browser or a proxy.
## - `POST /logout` has the browser forget the cookie and clear the site's
##   cache and storage, and sends it to the sign-in page.
## - A human invite's redemption (`HumanInvitesRoute`) starts a session the
##   same way, once it has set the invited human's password
##   (`start_session_by_invite!`, which takes only what
##   `HumanInvite.redeem` makes).
## - A GitHub sign-in (`GitHubRoute`) does too (`start_session_by_github!`,
##   which takes only what `GitHubSignIn` admits), and so does linking GitHub
##   to an account (`start_session_by_github_link!`).
##
## `sign_in_by_session!` is the check a request with a session cookie, and
## no `Authorization` header, passes before any route
## (`Actor.load_actor!`): the host checks the signature over what the human's
## sign-in files hold now (`Session.Material`), and `Session.admit` decides.
## So rewriting or removing any of those files ends every session of its
## human. `SignedIn.by_session` is its one door.
import pf.Host
import pf.Http
import AccountFiles
import DeviceCode
import DeviceKey
import FileFacts
import GitHubSignIn
import Html
import HttpAnswer
import HumanInvite
import PageKit
import Password
import PasswordHash
import Session
import SignInFiles
import SignInPage
import SignInRequest
import SignedIn
import Timestamp
import Users
import UserStreams

SignInRoute :: [].{

	## The human the session in the `Cookie` header `cookie` admits, among
	## `users`, at `now`; unless it holds no session (`NoSession`), one that
	## is no session's spelling (`BadSession`), or one that admits no one
	## (`SessionRefused`: its signature, its date, its user, a human whose
	## `session-generation` file holds no count, logged, or a device code's
	## session whose device key is not active), or its human has
	## nothing a session is signed over (`NoMaterial`), or a sign-in file
	## could not be read (`AccountFiles`).
	sign_in_by_session! : {
		cookie : List(U8),
		users : Users,
		now : Timestamp,
	} => Try(
		SignedIn,
		[
			NoSession,
			BadSession,
			SessionRefused,
			NoMaterial,
			FileSystem(FileFacts.Fault),
		],
	)
	sign_in_by_session! = |{ cookie, users, now }| {
		claim = Session.claim_from_cookie_header(cookie)?
		material = SignInFiles.load_material!(claim.id()) ? |why| refusal_of_material(why)
		verdict = Host.hmac_sha256_with_server_secret_matches!(
			claim.signed_bytes(material),
			claim.mac(),
		)
		admitted = Session.admit({ claim, verdict, now, users })?
		SignInFiles.check_session_key!(claim.id(), admitted.origin())?
		Ok(SignedIn.by_session(admitted))
	}

	## A GET of `/login`: the sign-in page for `viewer`, going to the
	## query's `next` once signed in, offering GitHub as `github` says; a 400
	## when the query is anything but none or `next=<path>`.
	show_login : {
		viewer : SignedIn.Actor,
		query : List(U8),
		github : SignInPage.GitHubOffer,
	} -> Http.Response
	show_login = |{ viewer, query, github }|
		match SignInRequest.next_from_query(query) {
			Ok(next) => HttpAnswer.page(
				200,
				SignInPage.login({ viewer, next, problem: NoProblem, github }),
			)
			Err(BadNext) => SignInRoute.bad_next_answer
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
		now : Timestamp,
		github : SignInPage.GitHubOffer,
	} => Http.Response
	sign_in! = |{ viewer, users, body, now, github }| {
		answer =
			match SignInRequest.next_from_form(body) {
				Err(BadNext) => SignInRoute.bad_next_answer
				Ok(next) =>
					match find_human_by_password!({ viewer, users, body }) {
						Ok({ human, material }) =>
							HttpAnswer.with_header(
								HttpAnswer.see_other(next.to_str()),
								sign_session_cookie!({ human, origin: Ordinary, material, now }),
							)
						Err(NoMatch) => HttpAnswer.page(
							401,
							SignInPage.login({
								viewer,
								next,
								problem: Problem(no_match_words),
								github,
							}),
						)
						Err(ByApiKey) => SignInRoute.by_api_key_answer
						Err(TooManyChecks) => HttpAnswer.page(
							429,
							PageKit.notice({ title: "Too many sign-ins", text: too_many_words }),
						)
						Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
					}
			}
		HttpAnswer.never_stored(answer)
	}

	## The answer to a human invite redeemed at `now`: a session for the
	## human its admission admits, signed over `password_hash`, the hash the
	## redemption wrote to their password file, and a 303 to `next` with its
	## cookie. Every session signed over the hash the file held
	## before stops admitting them (`sign_in_by_session!`). A 500 when their
	## GitHub files can't be read. Never stored.
	start_session_by_invite! : {
		admission : HumanInvite.Admission,
		password_hash : PasswordHash,
		next : Html.SitePath,
	},
	Timestamp => Http.Response
	start_session_by_invite! = |{ admission, password_hash, next }, now|
		match SignInFiles.load_material_with_password!({
			id: admission.human().id(),
			password_hash,
		}) {
			Err(FileSystem(fault)) => HttpAnswer.never_stored(SignInRoute.fault_answer(fault))
			Err(GenerationDamaged) => HttpAnswer.never_stored(SignInRoute.fault_answer(Damaged))
			Ok(material) => {
				cookie = sign_session_cookie!({
					human: admission.human(),
					origin: Ordinary,
					material,
					now,
				})
				onward = HttpAnswer.see_other(next.to_str())
				HttpAnswer.never_stored(HttpAnswer.with_header(onward, cookie))
			}
		}

	## The answer to a GitHub sign-in admitted at `now`: a session for the
	## human its admission admits, and a 303 to where it goes, with its
	## cookie. The human's first GitHub sign-in writes their
	## `github-session-secret`. A 500 when their files can't be read or
	## written. Never stored.
	start_session_by_github! : GitHubSignIn.Admission, Timestamp => Http.Response
	start_session_by_github! = |admission, now| {
		human = admission.human()
		started =
			match SignInFiles.make_github_session_secret!(human.id()) {
				Err(FileSystem(fault)) => Err(FileSystem(fault))
				Ok({}) => SignInFiles.load_material!(human.id())
			}
		answer =
			match started {
				Err(NoMaterial) => HttpAnswer.page(
					500,
					PageKit.notice({ title: "Failed", text: no_material_words }),
				)
				Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
				Err(GenerationDamaged) => SignInRoute.fault_answer(Damaged)
				Ok(material) =>
					HttpAnswer.with_header(
						HttpAnswer.see_other(admission.next().to_str()),
						sign_session_cookie!({ human, origin: Ordinary, material, now }),
					)
			}
		HttpAnswer.never_stored(answer)
	}

	## The answer to a GitHub account linked at `now`: the id bound to the
	## human, their open streams ended, and a 303 onward with a new session's
	## cookie. Sessions are signed over `github-session-secret`, made anew, once
	## `github-id` is there, so these files end every session of theirs (an
	## earlier binding's too) and each stream reconnects on the new one or is
	## refused. A 500 when a file can't be written. Never stored.
	start_session_by_github_link! : GitHubSignIn.Linked, Timestamp => Http.Response
	start_session_by_github_link! = |linked, now|
		match SignInFiles.write_github_link!(linked) {
			Ok({}) => {
				UserStreams.end_every_stream!(linked.human().id())
				SignInRoute.start_session_by_github!(linked.admission(), now)
			}
			Err(FileSystem(fault)) => HttpAnswer.never_stored(SignInRoute.fault_answer(fault))
		}

	## The answer to a device code redeemed at `now`: a session for the human
	## it signs in, bound to the device key `key` its redemption made, signed
	## over what their sign-in files hold now, as a password's is, and a 303 to
	## `next` with its cookie. A 500 when their files can't be read, or hold
	## nothing to sign a session over. Never stored.
	start_session_by_device_code! : DeviceCode.Redemption,
	{
		key : DeviceKey.Id,
		next : Html.SitePath,
		now : Timestamp,
	} => Http.Response
	start_session_by_device_code! = |redemption, { key, next, now }| {
		human = redemption.owner()
		answer =
			match SignInFiles.load_material!(human.id()) {
				Err(NoMaterial) => HttpAnswer.page(
					500,
					PageKit.notice({
						title: "Failed",
						text: "This account has nothing to sign a session over.",
					}),
				)
				Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
				Err(GenerationDamaged) => SignInRoute.fault_answer(Damaged)
				Ok(material) =>
					HttpAnswer.with_header(
						HttpAnswer.see_other(next.to_str()),
						sign_session_cookie!({
							human,
							origin: ByDeviceCode(key),
							material,
							now,
						}),
					)
			}
		HttpAnswer.never_stored(answer)
	}

	## The `Set-Cookie` header of a new session for `human`, started as
	## `origin` says, signed at `now` over what their sign-in files hold now:
	## the session of the device that signed every other out, signed again
	## over the material that ended theirs; unless the files hold nothing to
	## sign over, or can't be read.
	sign_session_again! : {
		human : Users.Human,
		origin : Session.Origin,
		now : Timestamp,
	} => Try(Http.Header, [NoMaterial, GenerationDamaged, FileSystem(FileFacts.Fault)])
	sign_session_again! = |{ human, origin, now }| {
		material = SignInFiles.load_material!(human.id())?
		Ok(sign_session_cookie!({ human, origin, material, now }))
	}

	## A POST of `/logout`: the browser forgets the session's cookie, clears
	## what it keeps of the site (`clear_site_data_header`), and goes to the
	## sign-in page. Never stored.
	sign_out : Http.Response
	sign_out = {
		forgotten = HttpAnswer.with_header(
			HttpAnswer.see_other("/login"),
			set_cookie_header(Session.clear_cookie_text),
		)
		HttpAnswer.never_stored(HttpAnswer.with_header(forgotten, clear_site_data_header))
	}

	## A 303 to the sign-in page, which goes on to `next` once signed in: a
	## page asked for by no one signed in.
	login_redirect : Html.SitePath -> Http.Response
	login_redirect = |next| HttpAnswer.see_other("/login?next=${next.to_str()}")

	## A GET of `/login/code`, where the device code's form posts: a 303 to
	## the sign-in page, so Enter in the address bar there shows the form.
	return_to_login : Http.Response
	return_to_login = HttpAnswer.see_other("/login")

	## The 400 for a `next` that is no path on this site.
	bad_next_answer : Http.Response
	bad_next_answer = HttpAnswer.page(
		400,
		PageKit.notice({
			title: "Refused",
			text: "Where to go after signing in is no path on this site.",
		}),
	)

	## The 403 for a sign-in by a request with an API key.
	by_api_key_answer : Http.Response
	by_api_key_answer = HttpAnswer.page(
		403,
		PageKit.notice({ title: "Refused", text: "An API key never signs in." }),
	)

	## The 500 for a file system's `fault`.
	fault_answer : FileFacts.Fault -> Http.Response
	fault_answer = |fault|
		HttpAnswer.page(
			500,
			PageKit.notice({ title: "Failed", text: FileFacts.fault_words(fault) }),
		)
}

## The `Set-Cookie` header of a session for `human`, started as `origin`
## says, signed at `now` by the host's HMAC under the server's secret, over
## `material`.
sign_session_cookie! : {
	human : Users.Human,
	origin : Session.Origin,
	material : Session.Material,
	now : Timestamp,
} => Http.Header
sign_session_cookie! = |{ human, origin, material, now }| {
	signed_at = now
	mac = Host.hmac_sha256_with_server_secret!(
		Session.signed_bytes({ id: human.id(), signed_at, origin, material }),
	)
	cookie = Session.cookie_value({ id: human.id(), signed_at, origin, mac })
	set_cookie_header(Session.set_cookie_text(cookie))
}

## A `Set-Cookie` header of `text`.
set_cookie_header : Str -> Http.Header
set_cookie_header = |text| { name: "set-cookie".to_utf8(), value: text.to_utf8() }

## The header that has a signed-out browser clear the site's cache (its
## pages and the scripts') and its storage (localStorage and the rest,
## which hold the theme and the sidebar's collapsed places), so the next
## person on the device finds none of them. Not "cookies": that clears
## every cookie of the registrable domain, lynrummy.com's other sites'
## too, and the session's own is already cleared by its `Set-Cookie`.
clear_site_data_header : Http.Header
clear_site_data_header = { name: "clear-site-data".to_utf8(), value: "\"cache\", \"storage\"".to_utf8() }

## The sign-in's words when a name and a password don't match.
no_match_words : Str
no_match_words = "The name and the password don't match a human's."

## The sign-in's words when the host has run as many checks as it lets run
## for now.
too_many_words : Str
too_many_words = "Too many sign-ins are being tried. Wait a few seconds, then try again."

## A bcrypt hash at the cost `roc-chat hash-password` writes, of a password
## nobody knows, checked where there is no hash to check, so that a sign-in
## takes as long for a name that is no human's as for a wrong password.
dummy_hash : List(U8)
dummy_hash = "$2b$10$v5yDSgBNCAzrmaBwxRL5GuCqhQGND3Nw3mq3QGBC1d2MZltsLFCJ6".to_utf8()

## The sign-in's words when a human GitHub vouched for has nothing to sign a
## session over: a `github-session-secret` file emptied by hand, and no
## password.
no_material_words : Str
no_material_words = "This account has nothing to sign a session over: its github-session-secret file is empty."

## The human whose name and password the form `body` holds, among `users`,
## and what their session is signed over, which holds the hash the password
## was checked against; unless they don't match a human's (`NoMatch`: no such name,
## an agent's, no password, a password file holding no hash, or another
## password), `viewer` holds an API key (`ByApiKey`), the host refuses the
## check (`TooManyChecks`), or a sign-in file can't be read.
find_human_by_password! : {
	viewer : SignedIn.Actor,
	users : Users,
	body : List(U8),
} => Try(
	{ human : Users.Human, material : Session.Material },
	[NoMatch, ByApiKey, TooManyChecks, FileSystem(FileFacts.Fault)],
)
find_human_by_password! = |request| {
	claim = SignInRequest.password_claim(request)?
	match claim.claimant {
		NoHuman => Err(check_against_dummy_hash!(claim.password))
		Human(human) => check_password_of!({ human, password: claim.password })
	}
}

## `human` and what their session is signed over, when `password` is the one
## the hash their password file keeps was made from; unless it isn't, they
## have no file or one holding no hash the host checks (`NoMatch`), the host
## refuses the check (`TooManyChecks`), or a sign-in file can't be read.
check_password_of! : { human : Users.Human, password : Password } => Try(
	{ human : Users.Human, material : Session.Material },
	[NoMatch, TooManyChecks, FileSystem(FileFacts.Fault)],
)
check_password_of! = |{ human, password }|
	match AccountFiles.read_password_hash!(human.id()) {
		Err(fault) => Err(FileSystem(fault))
		Ok(NoFile) => Err(check_against_dummy_hash!(password))
		Ok(File(password_hash)) => {
			verdict = Host.password_matches_bcrypt_hash!(
				password.bytes_to_check(),
				password_hash.bytes(),
			)
			match verdict {
				Matches =>
					match SignInFiles.load_material_with_password!({
						id: human.id(),
						password_hash,
					}) {
						Ok(material) => Ok({ human, material })
						Err(FileSystem(fault)) => Err(FileSystem(fault))
						Err(GenerationDamaged) => Err(FileSystem(Damaged))
					}
				DoesNotMatch => Err(NoMatch)
				NotABcryptHash => Err(check_against_dummy_hash!(password))
				TooManyChecks => Err(TooManyChecks)
			}
		}
	}

## Why a session's material couldn't be had, as a session's check answers:
## a human whose `session-generation` file holds no count has their
## sessions refused, not every request of theirs failed.
refusal_of_material : [NoMaterial, GenerationDamaged, FileSystem(FileFacts.Fault)] -> [
	NoMaterial,
	SessionRefused,
	FileSystem(FileFacts.Fault),
]
refusal_of_material = |why|
	match why {
		NoMaterial => NoMaterial
		GenerationDamaged => SessionRefused
		FileSystem(fault) => FileSystem(fault)
	}

## `password` checked against `dummy_hash`, which no sign-in may match: the
## time a check takes, spent where there is no hash to check (`NoMatch`);
## unless the host refuses the check (`TooManyChecks`).
check_against_dummy_hash! : Password => [NoMatch, TooManyChecks]
check_against_dummy_hash! = |password|
	match Host.password_matches_bcrypt_hash!(password.bytes_to_check(), dummy_hash) {
		Matches => NoMatch
		DoesNotMatch => NoMatch
		NotABcryptHash =>
			crash "SignInRoute.check_against_dummy_hash!: dummy_hash is a bcrypt hash at cost 10, which the host checks"
		TooManyChecks => TooManyChecks
	}

# ── tests
# The redirect to sign in carries where to go after, and clears nothing;
# /login/code's GET is a 303 to the bare sign-in page; signing out forgets
# the cookie, clears the site's cache and storage, and is never stored.
expect
	SignInRoute.login_redirect(Html.SitePath.from_str("/chat/dm/1_1/plans") ?? crash "SignInRoute's tests: a site path")
		.headers
		== [{ name: "location".to_utf8(), value: "/login?next=/chat/dm/1_1/plans".to_utf8() }]
expect SignInRoute.return_to_login == HttpAnswer.see_other("/login")
expect
	SignInRoute.sign_out.status == 303
		and SignInRoute.sign_out.headers
			== [
				{ name: "location".to_utf8(), value: "/login".to_utf8() },
				set_cookie_header(Session.clear_cookie_text),
				{ name: "clear-site-data".to_utf8(), value: "\"cache\", \"storage\"".to_utf8() },
				{ name: "cache-control".to_utf8(), value: "no-store".to_utf8() },
			]
# The page, both sides of its query: 200 with a good one, 400 with a bad one.
expect
	SignInRoute.show_login({ viewer: Anonymous, query: [], github: NotOffered }).status == 200
expect
	SignInRoute.show_login({
		viewer: Anonymous,
		query: "next=x".to_utf8(),
		github: NotOffered,
	}).status == 400
# A human whose `session-generation` file holds no count has their sessions
# refused, not every request of theirs failed; every other reason is as it
# was.
expect refusal_of_material(GenerationDamaged) == SessionRefused
expect refusal_of_material(NoMaterial) == NoMaterial
expect refusal_of_material(FileSystem(Failed)) == FileSystem(Failed)

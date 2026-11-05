## This module answers the sign-in routes (`Route` lists them) and checks
## a request's session before any route.
##
## - `GET /login` is the sign-in page: a name and a password, and `next`,
##   where to go after, from the query (`?next=<path>`), `/agents` when
##   there is none; and a link to sign in with GitHub, when the server has
##   GitHub's settings (`GitHubRoute`).
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
## - `POST /logout` has the browser forget the cookie, and sends it to the
##   sign-in page.
## - A human invite's redemption (`HumanInvitesRoute`) starts a session the
##   same way, once it has set the invited human's password
##   (`start_session_by_invite!`, which takes only what
##   `HumanInvite.redeem` makes).
## - A GitHub sign-in (`GitHubRoute`) does too (`start_session_by_github!`,
##   which takes only what `GitHubSignIn` admits), and so does linking GitHub
##   to an account (`start_session_by_github_link!`).
##
## `sign_in_by_session!` is the check a request with a session cookie, and
## no `Authorization` header, passes before any route (main's
## `load_actor!`): the host checks the signature over what the human's
## sign-in files hold now (`Session.Material`), and `Session.admit` decides.
## So rewriting or removing any of those files ends every session of its
## human. `SignedIn.by_session` is its one door.
import pf.Host
import pf.Http
import FactFile
import FileSystem
import GitHubSignIn
import Hex
import Html
import HttpAnswer
import HumanInvite
import Page
import Password
import Secret
import Session
import SignedIn
import UnvalidatedString
import UrlEncodedForm
import UserId
import Users

SignInRoute :: [].{

	## The human the session in the `Cookie` header `cookie` admits, among
	## `users`, at `now`; unless it holds no session (`NoSession`), one that
	## is no session's spelling (`BadSession`), or one that admits no one
	## (`SessionRefused`: its signature, its date or its user), or its human
	## has nothing a session is signed over (`NoMaterial`), or a sign-in file
	## could not be read (`FileSystem`).
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
			NoMaterial,
			FileSystem(FileSystem.Fault),
		],
	)
	sign_in_by_session! = |{ cookie, users, now }| {
		claim = Session.claim_from_cookie_header(cookie)?
		material = load_material!(claim.id())?
		verdict = Host.hmac_sha256_with_server_secret_matches!(
			claim.signed_bytes(material),
			claim.mac(),
		)
		admitted = Session.admit({ claim, verdict, now, users })?
		Ok(SignedIn.by_session(admitted))
	}

	## A GET of `/login`: the sign-in page for `viewer`, going to the
	## query's `next` once signed in, offering GitHub as `github` says; a 400
	## when the query is anything but none or `next=<path>`.
	show_login : {
		viewer : SignedIn.Actor,
		query : List(U8),
		github : Page.GitHubOffer,
	} -> Http.Response
	show_login = |{ viewer, query, github }|
		match SignInRoute.next_from_query(query) {
			Ok(next) => HttpAnswer.page(
				200,
				Page.login({ viewer, next, problem: NoProblem, github }),
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
		now : I64,
		github : Page.GitHubOffer,
	} => Http.Response
	sign_in! = |{ viewer, users, body, now, github }| {
		answer =
			match next_from_form(body) {
				Err(BadNext) => SignInRoute.bad_next_answer
				Ok(next) =>
					match find_human_by_password!({ viewer, users, body }) {
						Ok({ human, material }) =>
							HttpAnswer.with_header(
								HttpAnswer.see_other(next.to_str()),
								sign_session_cookie!({ human, material, now }),
							)
						Err(NoMatch) => HttpAnswer.page(
							401,
							Page.login({
								viewer,
								next,
								problem: Problem(no_match_words),
								github,
							}),
						)
						Err(ByApiKey) => SignInRoute.by_api_key_answer
						Err(TooManyChecks) => HttpAnswer.page(
							429,
							Page.notice({ title: "Too many sign-ins", text: too_many_words }),
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
		password_hash : List(U8),
		next : Html.SitePath,
	},
	I64 => Http.Response
	start_session_by_invite! = |{ admission, password_hash, next }, now|
		match load_material_with_password!({ id: admission.human().id(), password_hash }) {
			Err(FileSystem(fault)) => HttpAnswer.never_stored(SignInRoute.fault_answer(fault))
			Ok(material) => {
				cookie = sign_session_cookie!({ human: admission.human(), material, now })
				onward = HttpAnswer.see_other(next.to_str())
				HttpAnswer.never_stored(HttpAnswer.with_header(onward, cookie))
			}
		}

	## The answer to a GitHub sign-in admitted at `now`: a session for the
	## human its admission admits, and a 303 to where it goes, with its
	## cookie. The human's first GitHub sign-in writes their
	## `github-session-secret`. A 500 when their files can't be read or
	## written. Never stored.
	start_session_by_github! : GitHubSignIn.Admission, I64 => Http.Response
	start_session_by_github! = |admission, now| {
		human = admission.human()
		started =
			match make_github_session_secret!(human.id()) {
				Err(FileSystem(fault)) => Err(FileSystem(fault))
				Ok({}) => load_material!(human.id())
			}
		answer =
			match started {
				Err(NoMaterial) => HttpAnswer.page(
					500,
					Page.notice({ title: "Failed", text: no_material_words }),
				)
				Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
				Ok(material) =>
					HttpAnswer.with_header(
						HttpAnswer.see_other(admission.next().to_str()),
						sign_session_cookie!({ human, material, now }),
					)
			}
		HttpAnswer.never_stored(answer)
	}

	## The answer to a GitHub account linked at `now`: the id bound to the
	## human, and a 303 to where they go, with a new session's cookie. A
	## session is signed over `github-session-secret` once `github-id` is
	## there, so these two files end every session of this human, the one that
	## asked to link included, and only the new one here admits them. The
	## secret is made anew even if an old one lies there, so a session from an
	## earlier binding can't come back. A 500 when a file can't be written.
	## Never stored.
	start_session_by_github_link! : GitHubSignIn.Linked, I64 => Http.Response
	start_session_by_github_link! = |linked, now|
		match write_github_link!(linked) {
			Ok({}) => SignInRoute.start_session_by_github!(linked.admission(), now)
			Err(FileSystem(fault)) => HttpAnswer.never_stored(SignInRoute.fault_answer(fault))
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

	## Where to go once signed in when nothing says.
	default_next : Html.SitePath
	default_next =
		Html.SitePath.from_str("/chat") ?? crash "SignInRoute.default_next: /chat is a site path"

	## A 303 to the sign-in page, which goes on to `next` once signed in: a
	## page asked for by no one signed in.
	login_redirect : Html.SitePath -> Http.Response
	login_redirect = |next| HttpAnswer.see_other("/login?next=${next.to_str()}")

	## The `next` a sign-in page's `query` names: none, `/agents`; or `next=`
	## and a path on this site; else `BadNext`.
	next_from_query : List(U8) -> Try(Html.SitePath, [BadNext])
	next_from_query = |query|
		if query.is_empty() {
			Ok(SignInRoute.default_next)
		} else if query.starts_with(next_prefix) {
			unchecked =
				UnvalidatedString.from_utf8(query.drop_first(next_prefix.len())) ? |NotUtf8| BadNext
			unchecked.site_path().map_err(|NotASitePath| BadNext)
		} else {
			Err(BadNext)
		}

	## The 400 for a `next` that is no path on this site.
	bad_next_answer : Http.Response
	bad_next_answer = HttpAnswer.page(
		400,
		Page.notice({
			title: "Refused",
			text: "Where to go after signing in is no path on this site.",
		}),
	)

	## `Ok` unless `viewer` holds an API key (`ByApiKey`), which never signs in.
	check_not_by_api_key : SignedIn.Actor -> Try({}, [ByApiKey])
	check_not_by_api_key = |viewer|
		match viewer {
			SignedIn(acting) =>
				match acting.credential() {
					ApiKey(_) => Err(ByApiKey)
					Session => Ok({})
				}
			Anonymous => Ok({})
		}

	## The 403 for a sign-in by a request with an API key.
	by_api_key_answer : Http.Response
	by_api_key_answer = HttpAnswer.page(
		403,
		Page.notice({ title: "Refused", text: "An API key never signs in." }),
	)

	## The 500 for a file system's `fault`.
	fault_answer : FileSystem.Fault -> Http.Response
	fault_answer = |fault|
		HttpAnswer.page(500, Page.notice({ title: "Failed", text: FileSystem.fault_words(fault) }))
}

## What the sessions of the user `id` are signed over now, from their sign-in
## files; unless they hold nothing to sign over (`NoMaterial`), or a file
## can't be read.
load_material! : UserId => Try(Session.Material, [NoMaterial, FileSystem(FileSystem.Fault)])
load_material! = |id| {
	github = load_github_word!(id)?
	match (FileSystem.read_password_hash!(id), github) {
		(Err(fault), _) => Err(FileSystem(fault))
		(Ok(File(bytes)), _) => Ok(
			Session.Material.from_password({
				password_hash: FactFile.word_from_file(bytes),
				github,
			}),
		)
		(Ok(NoFile), GitHub(word)) => Ok(Session.Material.from_github_alone(word))
		(Ok(NoFile), NoGitHub) => Err(NoMaterial)
	}
}

## What a session of the user `id` is signed over when it starts from
## `password_hash`, just checked or just written, not what the file holds by
## now: a password rewritten meanwhile leaves a session that admits no one.
load_material_with_password! : { id : UserId, password_hash : List(U8) } => Try(
	Session.Material,
	[FileSystem(FileSystem.Fault)],
)
load_material_with_password! = |{ id, password_hash }| {
	github = load_github_word!(id)?
	Ok(Session.Material.from_password({ password_hash, github }))
}

## The word in the user `id`'s `github-session-secret`, read only while their
## `github-id` ties them to GitHub, so removing that file ends their sessions
## too. An empty file holds no word.
load_github_word! : UserId => Try([NoGitHub, GitHub(List(U8))], [FileSystem(FileSystem.Fault)])
load_github_word! = |id|
	match FileSystem.read_github_id_file!(id) {
		Err(fault) => Err(FileSystem(fault))
		Ok(NoFile) => Ok(NoGitHub)
		Ok(File(_)) =>
			match FileSystem.read_github_session_secret!(id) {
				Err(fault) => Err(FileSystem(fault))
				Ok(NoFile) => Ok(NoGitHub)
				Ok(File(bytes)) => {
					word = FactFile.word_from_file(bytes)
					Ok(
						if word.is_empty() {
							NoGitHub
						} else {
							GitHub(word)
						},
					)
				}
			}
	}

## The user `id`'s `github-session-secret`, made first when there is none: 32
## random bytes as 64 hex digits. Sessions are signed over it under the
## server's secret, so whoever reads the file can't forge one; it needs only
## to change when its owner rewrites it.
make_github_session_secret! : UserId => Try({}, [FileSystem(FileSystem.Fault)])
make_github_session_secret! = |id|
	match FileSystem.read_github_session_secret!(id) {
		Err(fault) => Err(FileSystem(fault))
		Ok(File(_)) => Ok({})
		Ok(NoFile) => {
			bytes = Host.fill_with_random_bytes!(Secret.length)
			match FileSystem.create_github_session_secret!(id, Hex.to_hex(bytes).to_utf8()) {
				Ok({}) => Ok({})
				Err(fault) => Err(FileSystem(fault))
			}
		}
	}

## The files that tie `linked`'s human to GitHub: a new `github-session-secret`,
## which says nothing until `github-id` is there, and then the `github-id`, so
## a link cut short between the two binds no one.
write_github_link! : GitHubSignIn.Linked => Try({}, [FileSystem(FileSystem.Fault)])
write_github_link! = |linked| {
	id = linked.human().id()
	word = Hex.to_hex(Host.fill_with_random_bytes!(Secret.length)).to_utf8()
	FileSystem.replace_github_session_secret!(id, word) ? |fault| FileSystem(fault)
	FileSystem.create_github_id!(id, linked.github()) ? |fault| FileSystem(fault)
	Ok({})
}

## The `Set-Cookie` header of a session for `human`, signed at `now` by the
## host's HMAC under the server's secret, over `material`.
sign_session_cookie! : {
	human : Users.Human,
	material : Session.Material,
	now : I64,
} => Http.Header
sign_session_cookie! = |{ human, material, now }| {
	mac = Host.hmac_sha256_with_server_secret!(
		Session.signed_bytes({ id: human.id(), signed_at: now, material }),
	)
	cookie = Session.cookie_value({ id: human.id(), signed_at: now, mac })
	set_cookie_header(Session.set_cookie_text(cookie))
}

## A `Set-Cookie` header of `text`.
set_cookie_header : Str -> Http.Header
set_cookie_header = |text| { name: "set-cookie".to_utf8(), value: text.to_utf8() }

## The sign-in's words when a name and a password don't match.
no_match_words : Str
no_match_words = "The name and the password don't match a human's."

## The sign-in's words when the host has run as many checks as it lets run
## for now.
too_many_words : Str
too_many_words = "Too many sign-ins are being tried. Wait a few seconds, then try again."

## A bcrypt hash at the cost `gopher-roc hash-password` writes, of a password
## nobody knows, checked where there is no hash to check, so that a sign-in
## takes as long for a name that is no human's as for a wrong password.
dummy_hash : List(U8)
dummy_hash = "$2b$10$v5yDSgBNCAzrmaBwxRL5GuCqhQGND3Nw3mq3QGBC1d2MZltsLFCJ6".to_utf8()

## The sign-in's words when a human GitHub vouched for has nothing to sign a
## session over: a `github-session-secret` file emptied by hand, and no
## password.
no_material_words : Str
no_material_words = "This account has nothing to sign a session over: its github-session-secret file is empty."

next_prefix : List(U8)
next_prefix = "next=".to_utf8()

## The `next` a sign-in form `body` holds: none, `SignInRoute.default_next`;
## or a path on this site; else `BadNext`.
next_from_form : List(U8) -> Try(Html.SitePath, [BadNext])
next_from_form = |body|
	match UrlEncodedForm.field({ body, name: "next" }) {
		Err(MissingField) => Ok(SignInRoute.default_next)
		Err(_) => Err(BadNext)
		Ok(unchecked) => unchecked.site_path().map_err(|NotASitePath| BadNext)
	}

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
	[NoMatch, ByApiKey, TooManyChecks, FileSystem(FileSystem.Fault)],
)
find_human_by_password! = |{ viewer, users, body }| {
	SignInRoute.check_not_by_api_key(viewer)?
	name_text = UrlEncodedForm.field({ body, name: "name" }) ? |_| NoMatch
	name = name_text.name() ? |_| NoMatch
	password_text = UrlEncodedForm.field({ body, name: "password" }) ? |_| NoMatch
	password = password_text.password() ? |NotAPassword| NoMatch
	match users.user_by_name(name) {
		Err(NoSuchUser) => Err(check_against_dummy_hash!(password))
		Ok(user) =>
			match user.as_human() {
				Err(Agent(_)) => Err(check_against_dummy_hash!(password))
				Ok(human) => check_password_of!({ human, password })
			}
	}
}

## `human` and what their session is signed over, when `password` is the one
## the hash their password file keeps was made from; unless it isn't, they
## have no file or one holding no hash the host checks (`NoMatch`), the host
## refuses the check (`TooManyChecks`), or a sign-in file can't be read.
check_password_of! : { human : Users.Human, password : Password } => Try(
	{ human : Users.Human, material : Session.Material },
	[NoMatch, TooManyChecks, FileSystem(FileSystem.Fault)],
)
check_password_of! = |{ human, password }|
	match FileSystem.read_password_hash!(human.id()) {
		Err(fault) => Err(FileSystem(fault))
		Ok(NoFile) => Err(check_against_dummy_hash!(password))
		Ok(File(bytes)) => {
			password_hash = FactFile.word_from_file(bytes)
			match Host.password_matches_bcrypt_hash!(password.bytes_to_check(), password_hash) {
				Matches =>
					match load_material_with_password!({ id: human.id(), password_hash }) {
						Ok(material) => Ok({ human, material })
						Err(FileSystem(fault)) => Err(FileSystem(fault))
					}
				DoesNotMatch => Err(NoMatch)
				NotABcryptHash => Err(check_against_dummy_hash!(password))
				TooManyChecks => Err(TooManyChecks)
			}
		}
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
## The `next` a query or a form names, as a test reads it.
next_text : Try(Html.SitePath, [BadNext]) -> Try(Str, [BadNext])
next_text = |next| next.map_ok(Html.SitePath.to_str)

# A query's `next`: none is /agents; a path on this site is itself; any
# other path, another field, or bytes that are no text, refused.
expect next_text(SignInRoute.next_from_query([])) == Ok("/chat")
expect
	next_text(SignInRoute.next_from_query("next=/chat/dm/1_1/plans".to_utf8()))
		== Ok("/chat/dm/1_1/plans")
expect
	[
		"next=",
		"next=//evil.example",
		"next=https://evil.example",
		"next=/a?b",
		"next=/a/../b",
		"to=/agents",
		"next=/agents&x=1",
	].all(|query| SignInRoute.next_from_query(query.to_utf8()) == Err(BadNext))
expect SignInRoute.next_from_query("next=/".to_utf8().concat([0xff])) == Err(BadNext)
# A form's `next`: none is /agents; a path on this site, decoded, is itself;
# any other, or two, refused.
expect next_text(next_from_form("name=Steve".to_utf8())) == Ok("/chat")
expect
	next_text(next_from_form("next=%2Fchat%2Fdm%2F1_1%2Fplans&name=Steve".to_utf8()))
		== Ok("/chat/dm/1_1/plans")
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
	SignInRoute.login_redirect(Html.SitePath.from_str("/chat/dm/1_1/plans") ?? crash "SignInRoute's tests: a site path")
		.headers
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
expect
	SignInRoute.show_login({ viewer: Anonymous, query: [], github: NotOffered }).status == 200
expect
	SignInRoute.show_login({
		viewer: Anonymous,
		query: "next=x".to_utf8(),
		github: NotOffered,
	}).status == 400

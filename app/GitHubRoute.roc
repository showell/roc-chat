## This module answers the routes of a GitHub sign-in (`Route` lists them).
## Every decision is `GitHubSignIn`'s or `GitHubState`'s; here are the facts
## asked of the host, and the answers made.
##
## - `GET /login/github/start` makes a state, has the host sign it, sets its
##   nonce in this browser's cookie, and sends the browser to GitHub.
## - `GET /login/github` is GitHub's way back: the state checked, the code
##   exchanged by the host, the human found, and a session started
##   (`SignInRoute.start_session_by_github!`). An id no human holds is asked
##   for a name instead, with a signed sign-up in its browser's cookie. A
##   refusal is the sign-in page again, saying why in plain words.
## - `POST /login/github/name` is that name: the sign-up checked, the account
##   made, and a session started. The counter of ids is written first, then
##   `github-id`, then `name`, all in one turn, so two submits can't both
##   see the id free. A name refused is the form again, the sign-up still
##   good.
##
## A server with no GitHub settings answers them with the 404 any other path
## gets, so running without GitHub takes nothing. The client secret and
## GitHub's token never reach this module: the host keeps them, and answers
## only GitHub's id and login (`Host.github_identity_for_code!`). No answer
## here may be kept by a browser or a proxy.
import pf.Host
import pf.Http
import Ascii
import Directory
import FileSystem
import GitHubCode
import GitHubSignIn
import GitHubSignUp
import GitHubState
import Hex
import Html
import HttpAnswer
import HumanInvites
import Name
import Page
import RequestHeader
import SignInRoute
import SignedIn
import UrlEncodedForm
import Users

GitHubRoute :: [].{

	## Whether this server offers GitHub on its sign-in page.
	load_offer! : {} => Page.GitHubOffer
	load_offer! = |{}|
		match Host.github_sign_in_settings!({}).status {
			Configured => Offered
			NotConfigured => NotOffered
		}

	## A GET of `/login/github/start`: the browser sent to GitHub to authorize
	## this server, back to `origin`, going to the query's `next` after.
	serve_start! : {
		viewer : SignedIn.Actor,
		query : List(U8),
		origin : Str,
		now : I64,
	} => Http.Response
	serve_start! = |
		{
			viewer,
			query,
			origin,
			now,
		},
	| {
		settings = Host.github_sign_in_settings!({})
		answer =
			match (settings.status, SignInRoute.check_not_by_api_key(viewer)) {
				(NotConfigured, _) => not_found
				(Configured, Err(ByApiKey)) => SignInRoute.by_api_key_answer
				(Configured, Ok({})) =>
					match SignInRoute.next_from_query(query) {
						Err(BadNext) => SignInRoute.bad_next_answer
						Ok(next) => {
							state = GitHubState.issue({
								nonce: Host.fill_with_random_bytes!(GitHubState.nonce_bytes),
								now,
								next,
							})
							mac = Host.hmac_sha256_with_server_secret!(state.signed_bytes())
							location = authorize_url({
								authorize_base: settings.authorize_base,
								client_id: settings.client_id,
								origin,
								state_token: state.token(mac),
							})
							HttpAnswer.with_header(
								HttpAnswer.see_other(location),
								set_cookie_header(state.set_cookie_text()),
							)
						}
					}
			}
		HttpAnswer.never_stored(answer)
	}

	## A GET of `/login/github`, GitHub's way back: a session for the human
	## GitHub vouched for, and a 303 to where the sign-in began; for an id no
	## human holds, the form that asks a name; or the sign-in page saying why
	## not. It forgets the state's cookie every way.
	serve_return! : {
		viewer : SignedIn.Actor,
		directory : Directory,
		query : List(U8),
		headers : List(Http.Header),
		now : I64,
	} => Http.Response
	serve_return! = |
		{
			viewer,
			directory,
			query,
			headers,
			now,
		},
	| {
		settings = Host.github_sign_in_settings!({})
		answer =
			match (settings.status, SignInRoute.check_not_by_api_key(viewer)) {
				(NotConfigured, _) => not_found
				(Configured, Err(ByApiKey)) => SignInRoute.by_api_key_answer
				(Configured, Ok({})) => {
					resolved = resolve!({
						users: directory.users(),
						query,
						headers,
						now,
					})
					with_state_forgotten(
						match resolved {
							Ok(Known(admission)) =>
								SignInRoute.start_session_by_github!(admission, now)
							Ok(Unknown(new_human)) => ask_for_name!({
								new_human,
								directory,
								now,
							})
							Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
							Err(Refused(why)) => refusal_answer({ viewer, why })
						},
					)
				}
			}
		HttpAnswer.never_stored(answer)
	}

	## A POST of `/login/github/name`: the account the browser's sign-up makes
	## under the form's `name`, a session for its human, and a 303 to where the
	## sign-in began; for a name refused, the form again, the sign-up still
	## good; or the sign-in page saying why not, the sign-up forgotten.
	serve_sign_up! : {
		viewer : SignedIn.Actor,
		directory : Directory,
		body : List(U8),
		headers : List(Http.Header),
		now : I64,
	} => Http.Response
	serve_sign_up! = |request| {
		settings = Host.github_sign_in_settings!({})
		answer =
			match (settings.status, SignInRoute.check_not_by_api_key(request.viewer)) {
				(NotConfigured, _) => not_found
				(Configured, Err(ByApiKey)) => SignInRoute.by_api_key_answer
				(Configured, Ok({})) =>
					match sign_up!({
						directory: request.directory,
						body: request.body,
						headers: request.headers,
						now: request.now,
					}) {
						Ok(admission) =>
							with_sign_up_forgotten(
								SignInRoute.start_session_by_github!(admission, request.now),
							)
						Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
						Err(Refused(why)) =>
							with_sign_up_forgotten(refusal_answer({ viewer: request.viewer, why }))
						Err(NameRefused({ name, why })) => name_refusal_answer({ name, why })
					}
			}
		HttpAnswer.never_stored(answer)
	}

	## Any other method at a GitHub route: a 405 saying which it takes, or the
	## 404 a server with no GitHub settings answers there.
	refuse_method! : [GetAndPost, GetOnly, PostOnly] => Http.Response
	refuse_method! = |allowed|
		match Host.github_sign_in_settings!({}).status {
			NotConfigured => not_found
			Configured => HttpAnswer.method_not_allowed(allowed)
		}
}

## The 404 a path gets when nothing is here.
not_found : Http.Response
not_found = HttpAnswer.page(404, Page.notice({ title: "Not found", text: "Nothing is here." }))

## GitHub's page that asks its human to authorize this server.
authorize_url : {
	authorize_base : List(U8),
	client_id : List(U8),
	origin : Str,
	state_token : Str,
} -> Str
authorize_url = |
	{
		authorize_base,
		client_id,
		origin,
		state_token,
	},
| {
	base = Str.from_utf8(authorize_base) ?? crash "GitHubRoute.authorize_url: the host's base URL is ASCII"
	id = percent_encoded(client_id)
	back = percent_encoded("${origin}/login/github".to_utf8())
	"${base}/login/oauth/authorize?client_id=${id}&redirect_uri=${back}&state=${state_token}"
}

## `bytes` as a URL's query value: letters, digits and `-_.~` as they are,
## any other byte `%` and its hex digits.
percent_encoded : List(U8) -> Str
percent_encoded = |bytes| {
	spelled = bytes.map(
		|byte|
			if (is_unreserved(byte))
				Str.from_utf8([byte]) ?? crash "GitHubRoute.percent_encoded: ASCII is UTF-8"
			else
				"%${Hex.to_hex([byte])}",
	)
	Str.join_with(spelled, "")
}

is_unreserved : U8 -> Bool
is_unreserved = |byte|
	Ascii.is_letter(byte) or Ascii.is_digit(byte) or "-_.~".to_utf8().contains(byte)

## Whose sign-in the query and the cookie prove, each step from the host's
## fact; or why not.
resolve! : {
	users : Users,
	query : List(U8),
	headers : List(Http.Header),
	now : I64,
} => Try(
	[Known(GitHubSignIn.Admission), Unknown(GitHubSignIn.NewHuman)],
	[Refused(GitHubSignIn.Refusal), FileSystem(FileSystem.Fault)],
)
resolve! = |
	{
		users,
		query,
		headers,
		now,
	},
| {
	came =
		GitHubSignIn.CameBack.came_back({
			state: load_signed_state!(query),
			answer: answer_of(query),
		}) ? |why| Refused(why)
	checked = came.check({ cookie: cookie_of(headers), now }) ? |why| Refused(why)
	heard = Host.github_identity_for_code!(checked.code_bytes())
	known = checked.identify(heard) ? |why| Refused(why)
	files = FileSystem.read_github_id_files!(users) ? |fault| FileSystem(fault)
	known.resolve({ files, users }).map_err(|why| Refused(why))
}

## The form that asks `new_human` for a name, offering what `directory` leaves
## free, with their signed sign-up in this browser's cookie.
ask_for_name! : {
	new_human : GitHubSignIn.NewHuman,
	directory : Directory,
	now : I64,
} => Http.Response
ask_for_name! = |
	{
		new_human,
		directory,
		now,
	},
| {
	sign_up = new_human.sign_up(now)
	mac = Host.hmac_sha256_with_server_secret!(sign_up.signed_bytes())
	suggested =
		match new_human.suggested_name(directory) {
			Suggested(name) => Named(name)
			NoSuggestion => NoName
		}
	HttpAnswer.with_header(
		HttpAnswer.page(200, Page.github_sign_up({ name: suggested, problem: NoProblem })),
		set_cookie_header(sign_up.set_cookie_text(mac)),
	)
}

## The admission of the human the browser's sign-up and the form `body` make,
## their account written; or why not. The counter goes first, so an id is
## never given twice. The caller's `directory` and these files were read in
## this turn, which holds to the last write.
sign_up! : {
	directory : Directory,
	body : List(U8),
	headers : List(Http.Header),
	now : I64,
} => Try(GitHubSignIn.Admission, _)
sign_up! = |
	{
		directory,
		body,
		headers,
		now,
	},
| {
	resumed = GitHubSignIn.SignUpResumed.resume({
		sign_up: load_signed_sign_up!(headers),
		now,
	}) ? |why| Refused(why)
	name = HumanInvites.name_from_form(body) ? |why| NameRefused({ name: NoName, why })
	files = FileSystem.read_github_id_files!(directory.users()) ? |fault| FileSystem(fault)
	made = resumed.create_account({
		name,
		files,
		directory,
	}) ? |why| account_refusal({ name, why })
	FileSystem.replace_user_counter!(made.directory.users()) ? |fault| FileSystem(fault)
	FileSystem.create_github_account!({
		human: made.human,
		github: made.github,
	}) ? |fault| FileSystem(fault)
	Ok(made.admission)
}

## Why `name` made no account: a sign-up that ends here, or a name to try
## again.
account_refusal : {
	name : Name,
	why : [
		AccountExists,
		DuplicateAccount,
		NameTaken,
		Full,
	],
} -> [
	Refused(GitHubSignIn.Refusal),
	NameRefused({ name : Page.NameField, why : HumanInvites.Refusal }),
]
account_refusal = |{ name, why }|
	match why {
		AccountExists => Refused(AccountExists)
		DuplicateAccount => Refused(DuplicateAccount)
		NameTaken => NameRefused({ name: Named(name), why: NameTaken })
		Full => NameRefused({ name: Named(name), why: Full })
	}

## The sign-up the request's cookie holds: `Signed` when the host says its
## signature matches, else `Unsigned`, none at all included.
load_signed_sign_up! : List(Http.Header) => [Signed(GitHubSignUp), Unsigned]
load_signed_sign_up! = |headers|
	match RequestHeader.header_value(headers, "cookie") {
		Unsent => Unsigned
		Repeated => Unsigned
		Sent(header) =>
			match GitHubSignUp.Claim.from_cookie_header(header) {
				Err(NotAClaim) => Unsigned
				Ok(claim) =>
					GitHubSignUp.from_claim({
						claim,
						verdict: Host.hmac_sha256_with_server_secret_matches!(
							claim.signed_bytes(),
							claim.mac(),
						),
					})
			}
	}

## The state the query holds: `Signed` when the host says its signature
## matches, else `Unsigned`, none at all included.
load_signed_state! : List(U8) => [Signed(GitHubState), Unsigned]
load_signed_state! = |query|
	match UrlEncodedForm.field({ body: query, name: "state" }) {
		Err(_) => Unsigned
		Ok(text) =>
			match text.github_state_claim() {
				Err(NotAClaim) => Unsigned
				Ok(claim) =>
					GitHubState.from_claim({
						claim,
						verdict: Host.hmac_sha256_with_server_secret_matches!(
							claim.signed_bytes(),
							claim.mac(),
						),
					})
			}
	}

## What GitHub answered in the query: a code, none, or one it wouldn't send.
answer_of : List(U8) -> GitHubSignIn.Answer
answer_of = |query|
	match UrlEncodedForm.field({ body: query, name: "code" }) {
		Err(MissingField) => NoCode
		Err(_) => BadCode
		Ok(text) =>
			match text.github_code() {
				Ok(code) => Code(code)
				Err(NotACode) => BadCode
			}
	}

## The state's cookie among `headers`.
cookie_of : List(Http.Header) -> GitHubState.Cookie
cookie_of = |headers|
	match RequestHeader.header_value(headers, "cookie") {
		Sent(header) => GitHubState.cookie_from_header(header)
		Unsent => Unsent
		Repeated => Unsent
	}

## `answer`, which has the browser forget the state's cookie.
with_state_forgotten : Http.Response -> Http.Response
with_state_forgotten = |answer|
	HttpAnswer.with_header(answer, set_cookie_header(GitHubState.clear_cookie_text))

## `answer`, which has the browser forget the sign-up's cookie.
with_sign_up_forgotten : Http.Response -> Http.Response
with_sign_up_forgotten = |answer|
	HttpAnswer.with_header(answer, set_cookie_header(GitHubSignUp.clear_cookie_text))

## A `Set-Cookie` header of `text`.
set_cookie_header : Str -> Http.Header
set_cookie_header = |text| { name: "set-cookie".to_utf8(), value: text.to_utf8() }

## The sign-in page saying why GitHub's sign-in was refused, under its status.
refusal_answer : { viewer : SignedIn.Actor, why : GitHubSignIn.Refusal } -> Http.Response
refusal_answer = |{ viewer, why }| {
	said = refusal_said(why)
	HttpAnswer.page(
		said.status,
		Page.login({
			viewer,
			next: start_again_next,
			problem: Problem(said.words),
			github: Offered,
		}),
	)
}

## The form again, saying why the name `name` was refused, under its status.
name_refusal_answer : { name : Page.NameField, why : HumanInvites.Refusal } -> Http.Response
name_refusal_answer = |{ name, why }| {
	notice = HumanInvites.refusal_notice(why)
	HttpAnswer.page(
		notice.status,
		Page.github_sign_up({ name, problem: Problem(notice.said) }),
	)
}

## Where a sign-in started over goes when nothing says.
start_again_next : Html.SitePath
start_again_next =
	Html.SitePath.from_str("/agents") ?? crash "GitHubRoute.start_again_next: /agents is a site path"

## A refusal's status and its words. Nothing here says more than the human
## needs: what went wrong, and what to do.
refusal_said : GitHubSignIn.Refusal -> { status : U16, words : Str }
refusal_said = |why|
	match why {
		StateForged => { status: 403, words: start_again_words }
		StateMismatched => { status: 403, words: start_again_words }
		StateExpired => { status: 403, words: "That sign-in took too long. Please try again." }
		GitHubDenied => { status: 403, words: "GitHub did not sign you in." }
		NotACode => { status: 403, words: start_again_words }
		CodeRefused => { status: 403, words: "GitHub refused that sign-in. Please try again." }
		GitHubUnreachable => { status: 502, words: "GitHub did not answer. Please try again." }
		BadIdentity => { status: 502, words: "GitHub's answer made no sense. Please try again." }
		DuplicateAccount =>
			{ status: 403, words: "That GitHub account is tied to more than one account here." }
		SignUpForged => { status: 403, words: "That sign-up did not start in this browser. Please try again." }
		SignUpExpired => { status: 403, words: "That sign-up took too long. Please try again." }
		AccountExists => { status: 403, words: "That GitHub account has an account here. Sign in with GitHub." }
	}

start_again_words : Str
start_again_words = "That sign-in did not start in this browser. Please try again."

# ── tests
expect percent_encoded("aZ09-_.~".to_utf8()) == "aZ09-_.~"
expect percent_encoded("a b&c=/".to_utf8()) == "a%20b%26c%3d%2f"
expect
	authorize_url({
		authorize_base: "https://github.com".to_utf8(),
		client_id: "Iv1 x".to_utf8(),
		origin: "https://chat.example.com",
		state_token: "a.1.b.c",
	})
		== "https://github.com/login/oauth/authorize?client_id=Iv1%20x&redirect_uri=https%3a%2f%2fchat.example.com%2flogin%2fgithub&state=a.1.b.c"
# The query's answer: a code, none, or one GitHub wouldn't send.
expect answer_of("state=x".to_utf8()) == NoCode
expect
	[
		"code=a%20b",
		"code=a&code=b",
		"code=",
	].all(|query| answer_of(query.to_utf8()) == BadCode)
expect
	match answer_of("code=abc&state=x".to_utf8()) {
		Code(code) => code.bytes_to_exchange() == "abc".to_utf8()
		_ => Bool.False
	}
# The cookie: this one, none, or two headers.
expect
	cookie_of([{ name: "Cookie".to_utf8(), value: "__Host-gopher_github_state=AA".to_utf8() }])
		== Sent([0])
expect cookie_of([]) == Unsent
expect
	cookie_of([
		{ name: "cookie".to_utf8(), value: "__Host-gopher_github_state=AA".to_utf8() },
		{ name: "cookie".to_utf8(), value: "__Host-gopher_github_state=AA".to_utf8() },
	]) == Unsent
# Every refusal has words, and a 5xx only when GitHub is at fault.
expect
	[
		StateForged,
		StateMismatched,
		StateExpired,
		GitHubDenied,
		NotACode,
		CodeRefused,
		DuplicateAccount,
		SignUpForged,
		SignUpExpired,
		AccountExists,
	].all(|why| refusal_said(why).status == 403)
expect [GitHubUnreachable, BadIdentity].all(|why| refusal_said(why).status == 502)

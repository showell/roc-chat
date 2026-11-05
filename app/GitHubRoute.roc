## This module answers the routes of a GitHub sign-in (`Route` lists them).
## Every decision is `GitHubSignIn`'s or `GitHubState`'s; here are the facts
## asked of the host, and the answers made.
##
## - `GET /login/github/start` makes a state, has the host sign it, sets its
##   nonce in this browser's cookie, and sends the browser to GitHub.
## - `GET /login/github` is GitHub's way back: the state checked, the code
##   exchanged by the host, the human found, and a session started
##   (`SignInRoute.start_session_by_github!`). A refusal is the sign-in page
##   again, saying why in plain words.
##
## A server with no GitHub settings answers both with the 404 any other path
## gets, so running without GitHub takes nothing. The client secret and
## GitHub's token never reach this module: the host keeps them, and answers
## only GitHub's id and login (`Host.github_identity_for_code!`). No answer
## here may be kept by a browser or a proxy.
import pf.Host
import pf.Http
import Ascii
import FileSystem
import GitHubCode
import GitHubLogin
import GitHubSignIn
import GitHubState
import Hex
import Html
import HttpAnswer
import Page
import RequestHeader
import SignInRoute
import SignedIn
import UrlEncodedForm
import Users

GitHubRoute :: [].{

	## Whether this server offers GitHub on its sign-in page.
	offer! : {} => Page.GitHubOffer
	offer! = |{}|
		match Host.github_sign_in_settings!({}).status {
			Configured => Offered
			NotConfigured => NotOffered
		}

	## A GET of `/login/github/start`: the browser sent to GitHub to authorize
	## this server, back to `origin`, going to the query's `next` after.
	start! : {
		viewer : SignedIn.Actor,
		query : List(U8),
		origin : Str,
		now : I64,
	} => Http.Response
	start! = |
		{
			viewer,
			query,
			origin,
			now,
		},
	| {
		settings = Host.github_sign_in_settings!({})
		answer =
			match (settings.status, SignInRoute.check_not_by_api_key(viewer), SignInRoute.next_from_query(query)) {
				(NotConfigured, _, _) => not_found
				(Configured, Err(ByApiKey), _) => SignInRoute.by_api_key_answer
				(Configured, Ok({}), Err(BadNext)) => SignInRoute.bad_next_answer
				(Configured, Ok({}), Ok(next)) => {
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
		HttpAnswer.never_stored(answer)
	}

	## A GET of `/login/github`, GitHub's way back: a session for the human
	## GitHub vouched for, and a 303 to where the sign-in began; or the
	## sign-in page saying why not. It forgets the state's cookie either way.
	finish! : {
		viewer : SignedIn.Actor,
		users : Users,
		query : List(U8),
		headers : List(Http.Header),
		now : I64,
	} => Http.Response
	finish! = |
		{
			viewer,
			users,
			query,
			headers,
			now,
		},
	| {
		answer =
			match (Host.github_sign_in_settings!({}).status, SignInRoute.check_not_by_api_key(viewer)) {
				(NotConfigured, _) => not_found
				(Configured, Err(ByApiKey)) => SignInRoute.by_api_key_answer
				(Configured, Ok({})) => {
					admitted = admit!({
						users,
						query,
						headers,
						now,
					})
					with_state_forgotten(
						match admitted {
							Ok(admission) => SignInRoute.start_session_by_github!(admission, now)
							Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
							Err(Refused(why)) => refusal_answer({ viewer, why })
						},
					)
				}
			}
		HttpAnswer.never_stored(answer)
	}

	## Any other method at a GitHub route: a 405 allowing GET, or the 404 a
	## server with no GitHub settings answers there.
	refuse_method! : {} => Http.Response
	refuse_method! = |{}|
		match Host.github_sign_in_settings!({}).status {
			NotConfigured => not_found
			Configured => HttpAnswer.method_not_allowed(GetOnly)
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

## The admission the query and the cookie earn, each step from the host's
## fact; or why not.
admit! : {
	users : Users,
	query : List(U8),
	headers : List(Http.Header),
	now : I64,
} => Try(
	GitHubSignIn.Admission,
	[Refused(GitHubSignIn.Refusal), FileSystem(FileSystem.Fault)],
)
admit! = |
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
	known.admit({ files, users }).map_err(|why| Refused(why))
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
answer_of : List(U8) -> [Code(GitHubCode), NoCode, BadCode]
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
		UnknownAccount(login) =>
			{ status: 403, words: "The GitHub account ${login.to_str()} has no account here." }
		DuplicateAccount =>
			{ status: 403, words: "That GitHub account is tied to more than one account here." }
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
	].all(|why| refusal_said(why).status == 403)
expect [GitHubUnreachable, BadIdentity].all(|why| refusal_said(why).status == 502)
expect {
	login = GitHubLogin.from_utf8("stranger".to_utf8()) ?? crash "GitHubRoute's tests: a login"
	refusal_said(UnknownAccount(login))
		== { status: 403, words: "The GitHub account stranger has no account here." }
}

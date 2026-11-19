## This module answers the routes of a GitHub sign-in (`Route` lists them).
## Every decision is `GitHubSignIn`'s, `GitHubState`'s or `GitHubTrip`'s;
## here are the facts asked of the host, and the answers made.
##
## - `GET /login/github/start` makes a state, has the host sign it, sets its
##   nonce in this browser's cookie, and sends the browser to GitHub; a
##   browser signed in already goes to `/agents`, to link by its button.
## - `GET /login/github` is GitHub's way back: the state checked, the code
##   exchanged by the host, the human found, and a session started
##   (`SignInRoute.start_session_by_github!`). An id no human holds is asked
##   for a name instead, with a signed sign-up in its browser's cookie; a human
##   signed in already links it instead. A refusal is the sign-in page again,
##   saying why in plain words.
## - `POST /login/github/name` is that name, which `GitHubSignUpRoute`
##   answers.
## - `POST /login/github/link` is a signed-in human asking to link GitHub to
##   their account: a trip to GitHub like a sign-in's, whose state names them.
##   It comes back to `GET /login/github`, which binds the id to them and
##   starts their session afresh (`SignInRoute.start_session_by_github_link!`).
##   It is a POST so that no other site's page can send a browser on it, and
##   a signed-in route (`Route`), so `Dispatch` answers no one with its 401.
##
## A server with no GitHub settings answers them with the 404 any other path
## gets, so running without GitHub takes nothing. The client secret and
## GitHub's token never reach this module: the host keeps them, and answers
## only GitHub's id and login (`Host.github_identity_for_code!`). No answer
## here may be kept by a browser or a proxy.
import pf.Host
import pf.Http
import AccountFiles
import AgentsPage
import Directory
import FileFacts
import GitHubRefusal
import GitHubSignIn
import GitHubSignUpRoute
import GitHubState
import GitHubTrip
import Html
import HttpAnswer
import PageKit
import RequestHeader
import SignInPage
import SignInRequest
import SignInRoute
import SignedIn
import Timestamp
import TrustedHtml
import UserId
import Users

GitHubRoute :: [].{

	## Whether this server offers GitHub on its sign-in page.
	load_offer! : {} => SignInPage.GitHubOffer
	load_offer! = |{}|
		match Host.github_sign_in_settings!({}).status {
			Configured => Offered
			NotConfigured => NotOffered
		}

	## Whether the `/agents` page of the human `human` offers to link GitHub:
	## on a server with GitHub's settings, to a human with no `github-id` file.
	load_link_offer! : UserId => Try(
		AgentsPage.GitHubLinkOffer,
		[Damaged, NotUtf8, PathRefused, Failed],
	)
	load_link_offer! = |human|
		match Host.github_sign_in_settings!({}).status {
			NotConfigured => Ok(LinkNotOffered)
			Configured =>
				match AccountFiles.read_github_link!(human)? {
					NotLinked => Ok(LinkOffered)
					Linked(_) => Ok(LinkNotOffered)
				}
		}

	## A GET of `/login/github/start`: the browser sent to GitHub to authorize
	## this server, back to `origin`, going to the query's `next` after. A
	## browser signed in already is sent to `/agents` instead, whose button
	## links GitHub by a POST, so no other site's link can start a link.
	serve_start! : {
		viewer : SignedIn.Actor,
		query : List(U8),
		origin : Str,
		now : Timestamp,
	} => Http.Response
	serve_start! = |{ viewer, query, origin, now }| {
		settings = Host.github_sign_in_settings!({})
		answer =
			match (settings.status, SignInRequest.check_not_by_api_key(viewer)) {
				(NotConfigured, _) => not_found
				(Configured, Err(ByApiKey)) => SignInRoute.by_api_key_answer
				(Configured, Ok({})) if viewer != Anonymous => HttpAnswer.see_other("/agents")
				(Configured, Ok({})) =>
					match SignInRequest.next_from_query(query) {
						Err(BadNext) => SignInRoute.bad_next_answer
						Ok(next) => send_to_github!({
							authorize_base: settings.authorize_base,
							client_id: settings.client_id,
							origin,
							now,
							next,
							errand: SignIn,
						})
					}
			}
		HttpAnswer.never_stored(answer)
	}

	## A POST of `/login/github/link`, by `acting`, someone signed in (`Dispatch`
	## refuses anyone else): the browser sent to GitHub to link it to the
	## human signed in, back to `origin`, going to `SignInRequest.default_next`
	## (Browse) after; or why not, before the trip.
	serve_link_start! : {
		acting : SignedIn,
		origin : Str,
		now : Timestamp,
	} => Http.Response
	serve_link_start! = |{ acting, origin, now }| {
		settings = Host.github_sign_in_settings!({})
		answer =
			match settings.status {
				NotConfigured => not_found
				Configured =>
					match load_human_to_link!(acting) {
						Err(why) => link_refusal_answer(why)
						Ok(human) => send_to_github!({
							authorize_base: settings.authorize_base,
							client_id: settings.client_id,
							origin,
							now,
							next: SignInRequest.default_next,
							errand: Link(human.id()),
						})
					}
			}
		HttpAnswer.never_stored(answer)
	}

	## A GET of `/login/github`, GitHub's way back: a session for the human
	## GitHub vouched for, and a 303 to where the sign-in began; for an id no
	## human holds, the form that asks a name; for a link, the id bound and a
	## new session; or the sign-in page saying why not. It forgets the state's
	## cookie every way.
	serve_return! : {
		viewer : SignedIn.Actor,
		directory : Directory,
		query : List(U8),
		headers : List(Http.Header),
		now : Timestamp,
	} => Http.Response
	serve_return! = |{ viewer, directory, query, headers, now }| {
		settings = Host.github_sign_in_settings!({})
		answer =
			match (settings.status, SignInRequest.check_not_by_api_key(viewer)) {
				(NotConfigured, _) => not_found
				(Configured, Err(ByApiKey)) => SignInRoute.by_api_key_answer
				(Configured, Ok({})) => {
					resolved = resolve!({
						users: directory.users(),
						viewer,
						query,
						headers,
						now,
					})
					with_state_forgotten(
						match resolved {
							Ok(Known(admission)) =>
								SignInRoute.start_session_by_github!(admission, now)
							Ok(Unknown(new_human)) =>
								GitHubSignUpRoute.ask_for_name!({ viewer, new_human, directory, now })
							Ok(Linking(linked)) =>
								SignInRoute.start_session_by_github_link!(linked, now)
							Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
							Err(Refused(why)) => page_answer(
								GitHubTrip.refusal_page({ viewer, why }),
							)
						},
					)
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

## The 404 any path gets when nothing is here.
not_found : Http.Response
not_found = HttpAnswer.page(404, PageKit.not_found)

## The 303 that sends a browser to GitHub for `errand`, with a state issued at
## `now` and its nonce in this browser's cookie.
send_to_github! : {
	authorize_base : List(U8),
	client_id : List(U8),
	origin : Str,
	now : Timestamp,
	next : Html.SitePath,
	errand : GitHubState.Errand,
} => Http.Response
send_to_github! = |
	{
		authorize_base,
		client_id,
		origin,
		now,
		next,
		errand,
	},
| {
	state = GitHubState.issue({
		nonce: Host.fill_with_random_bytes!(GitHubState.nonce_bytes),
		now,
		next,
		errand,
	})
	mac = Host.hmac_sha256_with_server_secret!(state.signed_bytes())
	location = GitHubTrip.authorize_url({
		authorize_base,
		client_id,
		origin,
		state_token: state.token(mac),
	})
	HttpAnswer.with_header(
		HttpAnswer.see_other(location),
		set_cookie_header(state.set_cookie_text()),
	)
}

## The human `viewer`, who may link GitHub now; or why not. The way back asks
## again, as the human may have linked in another tab meanwhile.
load_human_to_link! : SignedIn => Try(
	Users.Human,
	[
		ByApiKey,
		Agent(UserId),
		AlreadyLinked,
		FileSystem(FileFacts.Fault),
	],
)
load_human_to_link! = |acting| {
	human = acting.human_in_session()?
	match AccountFiles.read_github_link!(human.id()) {
		Ok(NotLinked) => Ok(human)
		Ok(Linked(_)) => Err(AlreadyLinked)
		Err(fault) => Err(FileSystem(fault))
	}
}

## The answer to a link refused before the trip to GitHub.
link_refusal_answer : [
	ByApiKey,
	Agent(UserId),
	AlreadyLinked,
	FileSystem(FileFacts.Fault),
] -> Http.Response
link_refusal_answer = |why|
	match why {
		ByApiKey => SignInRoute.by_api_key_answer
		Agent(_) => link_refusal_page(403, "An agent can't link GitHub.")
		AlreadyLinked => {
			said = GitHubRefusal.refusal_said(AlreadyLinked)
			link_refusal_page(said.status, said.words)
		}
		FileSystem(fault) => SignInRoute.fault_answer(fault)
	}

## A page saying why a link was refused.
link_refusal_page : U16, Str -> Http.Response
link_refusal_page = |status, text| HttpAnswer.page(
	status,
	PageKit.notice({ title: "Refused", text }),
)

## Whose sign-in the query and the cookie prove, each step from the host's
## fact; or why not.
resolve! : {
	users : Users,
	viewer : SignedIn.Actor,
	query : List(U8),
	headers : List(Http.Header),
	now : Timestamp,
} => Try(
	[
		Known(GitHubSignIn.Admission),
		Unknown(GitHubSignIn.NewHuman),
		Linking(GitHubSignIn.Linked),
	],
	[Refused(GitHubSignIn.Refusal), FileSystem(FileFacts.Fault)],
)
resolve! = |{ users, viewer, query, headers, now }| {
	came =
		GitHubSignIn.CameBack.came_back({
			state: load_signed_state!(query),
			answer: GitHubTrip.answer_in_query(query),
		}) ? |why| Refused(why)
	checked = came.check({ cookie: cookie_of(headers), now }) ? |why| Refused(why)
	heard = Host.github_identity_for_code!(checked.code_bytes())
	known = checked.identify(heard) ? |why| Refused(why)
	links = AccountFiles.read_github_links!({}) ? |fault| FileSystem(fault)
	known.resolve({ links, users, viewer }).map_err(|why| Refused(why))
}

## The state the query holds: `Signed` when the host says its signature
## matches, else `Unsigned`, none at all included.
load_signed_state! : List(U8) => [Signed(GitHubState), Unsigned]
load_signed_state! = |query|
	match GitHubTrip.state_claim_in_query(query) {
		Err(NoClaim) => Unsigned
		Ok(claim) =>
			GitHubState.from_claim({
				claim,
				verdict: Host.hmac_sha256_with_server_secret_matches!(
					claim.signed_bytes(),
					claim.mac(),
				),
			})
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

## `page` under `status`, as an answer.
page_answer : { status : U16, page : TrustedHtml } -> Http.Response
page_answer = |{ status, page }| HttpAnswer.page(status, page)

# ── tests
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
# A link refused before the trip, each way.
expect [ByApiKey, Agent(UserId.chat_owner)].all(|why| link_refusal_answer(why).status == 403)
expect link_refusal_answer(AlreadyLinked).status == 409
expect [Failed, Damaged].all(|fault| link_refusal_answer(FileSystem(fault)).status == 500)

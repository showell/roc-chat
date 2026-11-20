## This module answers a new human's name after a GitHub sign-in (`Route`
## lists it). Every decision is `GitHubSignIn`'s, `GitHubTrip`'s or
## `SignUpLimits`'; here are the facts asked of the host, and the answers
## made. `GitHubRoute` answers the trip there and back.
##
## - The way back from GitHub, for an id no human holds, sets a signed
##   sign-up in its browser's cookie and sends it on to `GET
##   /login/github/name` (`ask_for_name!`), unless a limit on new accounts
##   is reached (`SignUpLimits`).
## - `GET /login/github/name` is the form that asks the name, from that
##   cookie, so a reload asks again rather than saying the state is spent.
## - `POST /login/github/name` is that name: the sign-up checked, the limits
##   checked again, the account made, and a session started. The account is
##   judged against the directory with any lapsed invitee who holds a name
##   like the new one released (`NameRelease`, which reads and plans), so a
##   sign-up refused (an id with an account already, a name refused) frees
##   nothing. Then that release is written, if any (the channels that held
##   them, then their `name-released`), then the counter of ids, then the new
##   human's `Welcome`, then `github-id`, then `name`, then
##   the default channel's members, and last the sign-up's slot in the day's
##   window, all in one turn, so two submits can't both see
##   the id free or the last slot open. The welcome goes before the account,
##   so no account lacks one: a failure there spends an id and binds nothing,
##   and the same sign-up tries again. They land where `FirstPage` says. A
##   name refused is the form again, the sign-up still good.
##
## A limit reached is a 503 saying sign-ups are paused, and a line in the
## server's log. No answer here may be kept by a browser or a proxy.
import pf.Host
import pf.Http
import AccountFiles
import Directory
import DirectoryFiles
import FileFacts
import FirstPage
import GitHubSignIn
import GitHubSignUp
import GitHubTrip
import HttpAnswer
import HumanInvites
import Name
import NameRelease
import PageKit
import RequestHeader
import SignInPage
import SignInRequest
import SignInRoute
import SignUpLimits
import SignedIn
import Timestamp
import TranscriptFiles
import TrustedHtml

GitHubSignUpRoute :: [].{

	## The way back from GitHub for `new_human`: their signed sign-up in this
	## browser's cookie, and a 303 to the form that asks their name, so a
	## reload of that form asks again; or, when a limit on new accounts is
	## reached, the sign-in page saying sign-ups are paused.
	ask_for_name! : {
		viewer : SignedIn.Actor,
		new_human : GitHubSignIn.NewHuman,
		directory : Directory,
		now : Timestamp,
	} => Http.Response
	ask_for_name! = |{ viewer, new_human, directory, now }|
		match check_limits!(directory, now) {
			Err(limit) => refuse_as_paused!(viewer, limit)
			Ok(_) => {
				sign_up = new_human.sign_up(now)
				mac = Host.hmac_sha256_with_server_secret!(sign_up.signed_bytes())
				HttpAnswer.with_header(
					HttpAnswer.see_other("/login/github/name"),
					set_cookie_header(sign_up.set_cookie_text(mac)),
				)
			}
		}

	## A request at `/login/github/name`: its GET's form (`ShowForm`), or its
	## POST's name (`SubmitName`).
	serve! : {
		step : [ShowForm, SubmitName],
		viewer : SignedIn.Actor,
		directory : Directory,
		body : List(U8),
		headers : List(Http.Header),
		now : Timestamp,
	} => Http.Response
	serve! = |
		{
			step,
			viewer,
			directory,
			body,
			headers,
			now,
		},
	|
		match step {
			ShowForm => serve_name_form!({ viewer, directory, headers, now })
			SubmitName => serve_sign_up!({ viewer, directory, body, headers, now })
		}
}

## A GET of `/login/github/name`: the form that asks the name of the human
## the browser's sign-up holds, offering their GitHub login when it is a
## name `directory` leaves free, else saying why not; or the sign-in page
## saying why not, the sign-up forgotten.
serve_name_form! : {
	viewer : SignedIn.Actor,
	directory : Directory,
	headers : List(Http.Header),
	now : Timestamp,
} => Http.Response
serve_name_form! = |{ viewer, directory, headers, now }| {
	settings = Host.github_sign_in_settings!({})
	answer =
		match (settings.status, SignInRequest.check_not_by_api_key(viewer)) {
			(NotConfigured, _) => not_found
			(Configured, Err(ByApiKey)) => SignInRoute.by_api_key_answer
			(Configured, Ok({})) =>
				match GitHubSignIn.SignUpResumed.resume({
					sign_up: load_signed_sign_up!(headers),
					viewer,
					now,
				}) {
					Err(why) => with_sign_up_forgotten(
						page_answer(GitHubTrip.refusal_page({ viewer, why })),
					)
					Ok(resumed) =>
						match check_limits!(directory, now) {
							Err(limit) => with_sign_up_forgotten(refuse_as_paused!(viewer, limit))
							Ok(_) =>
								match load_offer_directory!({ resumed, directory, now }) {
									Ok(offered) => HttpAnswer.page(200, name_form(resumed, offered))
									Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
								}
						}
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
	now : Timestamp,
} => Http.Response
serve_sign_up! = |request| {
	settings = Host.github_sign_in_settings!({})
	answer =
		match (settings.status, SignInRequest.check_not_by_api_key(request.viewer)) {
			(NotConfigured, _) => not_found
			(Configured, Err(ByApiKey)) => SignInRoute.by_api_key_answer
			(Configured, Ok({})) =>
				match sign_up!(request) {
					Ok(admission) =>
						with_sign_up_forgotten(
							SignInRoute.start_session_by_github!(admission, request.now),
						)
					Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
					Err(Paused(limit)) => with_sign_up_forgotten(
						refuse_as_paused!(request.viewer, limit),
					)
					Err(Refused(why)) =>
						with_sign_up_forgotten(
							page_answer(GitHubTrip.refusal_page({ viewer: request.viewer, why })),
						)
					Err(NameRefused(refusal)) =>
						page_answer(GitHubTrip.name_refusal_page(refusal))
				}
		}
	HttpAnswer.never_stored(answer)
}

## The 404 any path gets when nothing is here.
not_found : Http.Response
not_found = HttpAnswer.page(404, PageKit.not_found)

## The directory the name form's offer of `resumed`'s GitHub login is judged
## against at `now`: with any lapsed invitee in its way released, as a submit
## of it would find it (`NameRelease.plan_release!`). Nothing is written.
load_offer_directory! : {
	resumed : GitHubSignIn.SignUpResumed,
	directory : Directory,
	now : Timestamp,
} => Try(Directory, [FileSystem(FileFacts.Fault)])
load_offer_directory! = |{ resumed, directory, now }|
	match resumed.login() {
		NoLogin => Ok(directory)
		Login(login) =>
			match Name.from_str(login.to_str()) {
				Err(_) => Ok(directory)
				Ok(name) =>
					NameRelease.plan_release!(directory, { name, leaving: NoOne, now })
						.map_ok(|planned| planned.directory)
			}
	}

## The form that asks the name of the human `resumed` signs up.
name_form : GitHubSignIn.SignUpResumed, Directory -> TrustedHtml
name_form = |resumed, directory|
	match GitHubTrip.name_offer(resumed, directory) {
		Suggested(name) => SignInPage.github_sign_up({
			name: Named(name),
			problem: NoProblem,
			login_note: NoNote,
		})
		NotSuggested(why) => SignInPage.github_sign_up({
			name: NoName,
			problem: NoProblem,
			login_note: NotOffered(why),
		})
	}

## The admission of the human the browser's sign-up and the form `body` make,
## their account written; or why not. The counter goes first, so an id is
## never given twice, and the day's slot last, so a sign-up that fails spends
## none. The caller's `directory` and these files were read in this turn,
## which holds to the last write.
sign_up! : {
	viewer : SignedIn.Actor,
	directory : Directory,
	body : List(U8),
	headers : List(Http.Header),
	now : Timestamp,
} => Try(GitHubSignIn.Admission, _)
sign_up! = |{ viewer, directory, body, headers, now }| {
	resumed = GitHubSignIn.SignUpResumed.resume({
		sign_up: load_signed_sign_up!(headers),
		viewer,
		now,
	}) ? |why| Refused(why)
	slot = check_limits!(directory, now) ? |limit| Paused(limit)
	name = HumanInvites.name_from_form(body) ? |why| NameRefused({ name: NoName, why })
	links = AccountFiles.read_github_links!({}) ? |fault| FileSystem(fault)
	planned = NameRelease.plan_release!(
		directory,
		{ name, leaving: NoOne, now },
	) ? |FileSystem(fault)| FileSystem(fault)
	{ made, welcome } =
		match GitHubTrip.new_account({
			resumed,
			name,
			links,
			directory: planned.directory,
			now,
		}) {
			Ok(account) => account
			Err(Refused(SignUpsPaused)) => return Err(Paused(ChatFull))
			Err(why) => return Err(why)
		}
	human = made.admission.human()
	NameRelease.write_release!(planned.pending, now) ? |FileSystem(fault)| FileSystem(fault)
	AccountFiles.replace_user_counter!(made.directory.users()) ? |fault| FileSystem(fault)
	TranscriptFiles.append_message!(
		welcome.key(),
		welcome.first_record(),
	) ? |fault| FileSystem(fault)
	landing = FirstPage.load!({ directory: made.directory, human, wanted: made.admission.next() })?
	AccountFiles.create_github_account!({
		human: made.human,
		github: made.github,
		joined: now,
	}) ? |fault| FileSystem(fault)
	DirectoryFiles.replace_channel_members!(made.channel) ? |fault| FileSystem(fault)
	_ = Host.replace_second_kept_under_key!(slot, now.to_seconds_since_epoch())
	Ok(made.admission.going_to(landing))
}

## The day's slot a GitHub sign-up at `now` would take in `directory`; or the
## limit on new accounts that is reached.
check_limits! : Directory, Timestamp => Try(List(U8), [DayFull, ChatFull])
check_limits! = |directory, now| {
	_ = SignUpLimits.check_room(directory.users())?
	var $slots = []
	for key in SignUpLimits.slot_keys {
		kept = Host.read_second_kept_under_key!(key)
		slot =
			match kept.status {
				Missing => NeverUsed
				Found => UsedAt(Timestamp.at_second(kept.second))
			}
		$slots = $slots.append(slot)
	}
	SignUpLimits.slot_for_sign_up($slots, now)
}

## The sign-in page saying sign-ups are paused, its limit in the server's log.
refuse_as_paused! : SignedIn.Actor, [DayFull, ChatFull] => Http.Response
refuse_as_paused! = |viewer, limit| {
	Host.write_line_to_server_log!(SignUpLimits.paused_log_line(limit))
	page_answer(GitHubTrip.refusal_page({ viewer, why: SignUpsPaused }))
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

## `answer`, which has the browser forget the sign-up's cookie.
with_sign_up_forgotten : Http.Response -> Http.Response
with_sign_up_forgotten = |answer|
	HttpAnswer.with_header(answer, set_cookie_header(GitHubSignUp.clear_cookie_text))

## A `Set-Cookie` header of `text`.
set_cookie_header : Str -> Http.Header
set_cookie_header = |text| { name: "set-cookie".to_utf8(), value: text.to_utf8() }

## `page` under `status`, as an answer.
page_answer : { status : U16, page : TrustedHtml } -> Http.Response
page_answer = |{ status, page }| HttpAnswer.page(status, page)

## This module answers the human invites' routes (`Route` lists them),
## moving data between the web interface and the file system, as
## `AgentsRoute` does for agents. What each route may do is
## `HumanInvites`' to decide; this module reads, writes and answers. An invite
## refused by one of those rules is the invites page again, saying why.
##
## Inviting someone writes, in order: the counter of ids, the new human's
## `Welcome`, their account (`inviter`, then `name`), the default channel's
## members, then the invite (its `hash` last). The welcome goes before the
## account, so no account lacks one: a failure there spends an id and holds no
## name, and the inviter tries again. A failure after it leaves an account
## holding the name with no code, which its inviter invites again, never a
## code for a half-made account. The page shows the link that joins by the
## code, `<origin>/join#<code>`, where the origin is the one the inviter's
## request came to; it is never stored by a browser or a proxy. No browser
## sends what follows a `#`, so the code reaches no log.
##
## The join routes answer a request that proves no one (`SignedIn.Actor`'s
## `Anonymous`), as `/agents/redeem` does: the invite's code is their
## credential. A request with an API key, or from a browser signed in
## already, is refused, and any refusal of the code is one 401 that says
## no more. `GET /join` is the join page (`Page.join`); its script asks
## `POST /join/name` for the name the invite holds, a line of JSON. `POST
## /join` redeems: the code is judged, then the name; a name refused
## spends nothing. Then the name is written, if it changed, so the name it
## leaves is free; the invite is spent before the password is written, so
## a code redeems once even when that write fails; then the human's
## password's bcrypt hash, made by the host at its standard cost, replaces
## any before it, and a session starts
## (`SignInRoute.start_session_by_invite!`), landing where `FirstPage` says.
import pf.Host
import pf.Http
import AgentsRoute
import Directory
import FileSystem
import FirstPage
import Html
import HttpAnswer
import HumanInvite
import HumanInvites
import JsonOut
import Name
import PeoplePages
import Page
import Secret
import SecretToken
import SignInRoute
import SignedIn
import TrustedHtml
import UserId
import Users
import Welcome

HumanInvitesRoute :: [].{

	## A GET of `/invites`: a form that invites someone, and each human the
	## acting human may invite again, with their invites as they stand at
	## `now`.
	show! : {
		acting : SignedIn,
		directory : Directory,
		now : I64,
	} => Http.Response
	show! = |{ acting, directory, now }|
		match load_invites_page!({
			acting,
			directory,
			shown: NoLink,
			problem: NoProblem,
			now,
		}) {
			Ok(html) => HttpAnswer.page(200, html)
			Err(why) => refusal_page(why)
		}

	## A POST of `/invites`: a new human named by the form's `name`, and an
	## invite for them, at `now`; then the invites page, showing the link
	## that joins by it, at `origin`, this once.
	invite! : {
		acting : SignedIn,
		directory : Directory,
		body : List(U8),
		origin : Str,
		now : I64,
	} => Http.Response
	invite! = |request|
		match invite_human!(request) {
			Ok(html) => HttpAnswer.never_stored(HttpAnswer.page(200, html))
			Err(why) => answer_refused_invite!({
				acting: request.acting,
				directory: request.directory,
				now: request.now,
				why,
			})
		}

	## A POST of `/invites/<id>/again`: a new invite for the human `human`,
	## at `now`; then the invites page, showing the link that joins by it,
	## at `origin`, this once.
	invite_again! : {
		acting : SignedIn,
		directory : Directory,
		human : UserId,
		origin : Str,
		now : I64,
	} => Http.Response
	invite_again! = |request|
		match invite_human_again!(request) {
			Ok(html) => HttpAnswer.never_stored(HttpAnswer.page(200, html))
			Err(why) => answer_refused_invite!({
				acting: request.acting,
				directory: request.directory,
				now: request.now,
				why,
			})
		}

	## A GET of `/join`: the join page, the same for every invite. A human who
	## is signed in has no use for it, and goes to Browse.
	join_page : SignedIn.Actor -> Http.Response
	join_page = |actor|
		match HumanInvites.admit_joiner(actor) {
			Err(SignedInAlready) => HttpAnswer.see_other(SignInRoute.default_next.to_str())
			Ok({}) | Err(ByApiKey) => HttpAnswer.page(200, Page.join)
		}

	## A POST of `/join/name`, by `actor`, who may join: the name the human
	## the form's `code` names holds, while the invite is open at `now`, as
	## JSON, `{"name":...}`; or the refusal, a line of text. Never stored.
	serve_join_name! : {
		actor : SignedIn.Actor,
		directory : Directory,
		body : List(U8),
		now : I64,
	} => Http.Response
	serve_join_name! = |request| {
		answer =
			match load_join_name!(request) {
				Ok(name) => HttpAnswer.json(
					JsonOut.json_object([("name", JsonOut.string(name.to_str()))]),
				)
				Err(why) => {
					notice = failure_notice(why)
					HttpAnswer.text(notice.status, notice.said)
				}
			}
		HttpAnswer.never_stored(answer)
	}

	## A POST of `/join`, by `actor`, who may join: the invite the form's
	## `code` names spent at `now`, its human named by the form's `name`,
	## their password set to the form's `password`, and a session started.
	join! : {
		actor : SignedIn.Actor,
		directory : Directory,
		body : List(U8),
		now : I64,
	} => Http.Response
	join! = |request|
		match join_by_invite!(request) {
			Ok(joined) => SignInRoute.start_session_by_invite!(joined, request.now)
			Err(why) => HttpAnswer.never_stored(refusal_page(why))
		}
}

## Why a route here refused: one of `HumanInvites`' refusals, a stored
## `inviter` that names no one, a clock that can't date a welcome, or the file
## system's fault.
Failure : [
	Refused(HumanInvites.Refusal),
	BadInviter(UserId),
	ClockOutOfRange,
	FileSystem(FileSystem.Fault),
]

## A failure in words, with its status.
failure_notice : Failure -> { status : U16, said : Str }
failure_notice = |why|
	match why {
		Refused(refusal) => HumanInvites.refusal_notice(refusal)
		BadInviter(id) => {
			status: 500,
			said: "The inviter file of user ${id.to_str()} names no user.",
		}
		ClockOutOfRange => { status: 500, said: "The server's clock is out of range." }
		FileSystem(fault) => { status: 500, said: FileSystem.fault_words(fault) }
	}

## A failure as a page, with its status.
refusal_page : Failure -> Http.Response
refusal_page = |why| {
	notice = failure_notice(why)
	HttpAnswer.page(notice.status, Page.notice({ title: "Refused", text: notice.said }))
}

## The answer to an invite that failed for `why`: the invites page again,
## saying why, with the refusal's status; or the refusal alone, for a failure
## no rule decided, or for an asker that page isn't for.
answer_refused_invite! : {
	acting : SignedIn,
	directory : Directory,
	now : I64,
	why : Failure,
} => Http.Response
answer_refused_invite! = |{ acting, directory, now, why }|
	match why {
		Refused(refusal) => {
			notice = HumanInvites.refusal_notice(refusal)
			match load_invites_page!({
				acting,
				directory,
				shown: NoLink,
				problem: Problem(notice.said),
				now,
			}) {
				Ok(html) => HttpAnswer.page(notice.status, html)
				Err(_) => refusal_page(why)
			}
		}
		BadInviter(_) | ClockOutOfRange | FileSystem(_) => refusal_page(why)
	}

## The invites page for `acting` at `now`, saying `problem`, with `shown`'s link
## if an invite was just made: every human `acting` may invite again, each with
## their invites.
load_invites_page! : {
	acting : SignedIn,
	directory : Directory,
	shown : [NoLink, Link({ human : Users.User, link : Str })],
	problem : [NoProblem, Problem(Str)],
	now : I64,
} => Try(TrustedHtml, _)
load_invites_page! = |{ acting, directory, shown, problem, now }| {
	_ = acting.human_in_session() ? |why| Refused(why)
	var $invited = []
	for user in humans_of(directory) {
		inviter = load_inviter!(user.id())?
		if HumanInvites.is_theirs_to_invite_again(acting, inviter) {
			invites = FileSystem.read_human_invites!(user.id()) ? |fault| FileSystem(fault)
			$invited = $invited.append({ human: user, invites })
		}
	}
	Ok(
		PeoplePages.invites({
			viewer: acting,
			users: directory.users(),
			invited: $invited,
			shown,
			problem,
			now,
		}),
	)
}

invite_human! : {
	acting : SignedIn,
	directory : Directory,
	body : List(U8),
	origin : Str,
	now : I64,
} => Try(TrustedHtml, _)
invite_human! = |{ acting, directory, body, origin, now }| {
	open = count_open_invites!(directory, { by: acting.user().id(), now })?
	made = HumanInvites.invite(directory, { acting, body, open }) ? |why| Refused(why)
	human = made.human.as_human() ?? crash "HumanInvitesRoute.invite_human!: an invite makes a human"
	welcome = Welcome.make({ directory: made.directory, human, now })?
	FileSystem.replace_user_counter!(made.directory.users()) ? |fault| FileSystem(fault)
	FileSystem.append_message!(welcome.key(), welcome.first_record()) ? |fault| FileSystem(fault)
	FileSystem.create_invited_account!({
		human: made.human,
		inviter: made.inviter.id(),
	}) ? |fault| FileSystem(fault)
	FileSystem.replace_channel_members!(made.channel) ? |fault| FileSystem(fault)
	code = issue_invite!({ human: made.human.id(), by: made.inviter.id(), now })?
	load_invites_page!({
		acting,
		directory: made.directory,
		shown: Link({ human: made.human, link: join_link({ origin, code }) }),
		problem: NoProblem,
		now,
	})
}

invite_human_again! : {
	acting : SignedIn,
	directory : Directory,
	human : UserId,
	origin : Str,
	now : I64,
} => Try(TrustedHtml, _)
invite_human_again! = |{ acting, directory, human, origin, now }| {
	inviter = load_inviter!(human)?
	open = count_open_invites!(directory, { by: acting.user().id(), now })?
	again = HumanInvites.reinvite(directory, { acting, human, inviter, open }) ? |why| Refused(why)
	code = issue_invite!({ human, by: again.by.id(), now })?
	load_invites_page!({
		acting,
		directory,
		shown: Link({ human: again.human.user(), link: join_link({ origin, code }) }),
		problem: NoProblem,
		now,
	})
}

## A new invite for the human `human`, made by `by` at `now`, written, its
## code's hash last; and its code, to show once.
issue_invite! : {
	human : UserId,
	by : UserId,
	now : I64,
} => Try(SecretToken, _)
issue_invite! = |{ human, by, now }| {
	id = FileSystem.find_next_human_invite_id!(human) ? |why| full_or_fault(why)
	secret = Secret.from_random_bytes(Host.fill_with_random_bytes!(Secret.length))
	invite = HumanInvite.make({
		id,
		hash: AgentsRoute.hash_secret!(secret),
		now,
		by,
	})
	FileSystem.create_human_invite!(human, invite) ? |fault| FileSystem(fault)
	Ok(SecretToken.of({ user: human, secret }))
}

## The link that joins by `code`, at `origin`: the code after `#`, so no
## browser sends it.
join_link : { origin : Str, code : SecretToken } -> Str
join_link = |{ origin, code }| "${origin}/join#${code.to_str()}"

## The code a join's form `body` holds, the invites of the human it names,
## and its secret's hash, at `now`; once `actor` may join.
load_join_code! : {
	actor : SignedIn.Actor,
	directory : Directory,
	body : List(U8),
	now : I64,
} => Try(HumanInvites.JoinCode, _)
load_join_code! = |{ actor, directory, body, now }| {
	HumanInvites.admit_joiner(actor) ? |why| Refused(why)
	token = HumanInvites.code_from_form(body) ? |why| Refused(why)
	invites =
		match directory.users().user(token.user()) {
			Ok(user) =>
				match user.role() {
					Human => FileSystem.read_human_invites!(user.id()) ? |fault| FileSystem(fault)
					Agent(_) => []
				}
			Err(NoSuchUser) => []
		}
	Ok({
		token,
		invites,
		hash: AgentsRoute.hash_secret!(token.secret()),
		now,
	})
}

## The name the invite a join's form names holds, for the join page.
load_join_name! : {
	actor : SignedIn.Actor,
	directory : Directory,
	body : List(U8),
	now : I64,
} => Try(Name, _)
load_join_name! = |request| {
	code = load_join_code!(request)?
	found = HumanInvites.find_invitee(request.directory, code) ? |why| Refused(why)
	Ok(found.human.user().name())
}

## The join: the form read, the name decided, then written if it changed,
## the invite spent, and the password written; then the admission, the hash
## written, which the session is signed over, and where the human lands.
join_by_invite! : {
	actor : SignedIn.Actor,
	directory : Directory,
	body : List(U8),
	now : I64,
} => Try(
	{
		admission : HumanInvite.Admission,
		password_hash : List(U8),
		next : Html.SitePath,
	},
	_,
)
join_by_invite! = |request| {
	code = load_join_code!(request)?
	name = HumanInvites.name_from_form(request.body) ? |why| Refused(why)
	password = HumanInvites.password_from_form(request.body) ? |why| Refused(why)
	joined = HumanInvites.join(request.directory, { code, name }) ? |why| Refused(why)
	human = joined.admission.human()
	next = FirstPage.load!({
		directory: request.directory,
		human,
		wanted: SignInRoute.default_next,
	})?
	_ =
		match joined.name {
			Kept => Ok({})
			Changed => FileSystem.replace_account_name!(human.user())
		} ? |fault| FileSystem(fault)
	FileSystem.replace_human_invite_state!(human.id(), joined.spent) ? |fault| FileSystem(fault)
	hash = Host.bcrypt_hash_of_password!(password.bytes_to_check())
	FileSystem.replace_password_hash!(human.id(), hash) ? |fault| FileSystem(fault)
	Ok({ admission: joined.admission, password_hash: hash, next })
}

## Every human of `directory`.
humans_of : Directory -> List(Users.User)
humans_of = |directory|
	directory.users().to_list().keep_if(
		|user|
			match user.role() {
				Human => Bool.True
				Agent(_) => Bool.False
			},
	)

## Who invited the human `id`, as their `inviter` file says.
load_inviter! : UserId => Try(HumanInvites.Inviter, _)
load_inviter! = |id| {
	file = FileSystem.read_inviter_file!(id) ? |fault| FileSystem(fault)
	HumanInvites.inviter_from_file(file).map_err(|NotAnInviter| BadInviter(id))
}

## How many invites `by` made that are open at `now`, among every human's.
count_open_invites! : Directory, { by : UserId, now : I64 } => Try(U64, _)
count_open_invites! = |directory, { by, now }| {
	var $open = 0
	for user in humans_of(directory) {
		invites = FileSystem.read_human_invites!(user.id()) ? |fault| FileSystem(fault)
		$open = $open + HumanInvites.open_count(invites, { by, now })
	}
	Ok($open)
}

## A next number refused: the human's folder is full, or the file system's
## fault.
full_or_fault : [Full, NotUtf8, PathRefused, Failed] -> Failure
full_or_fault = |why|
	match why {
		Full => Refused(Full)
		NotUtf8 => FileSystem(NotUtf8)
		PathRefused => FileSystem(PathRefused)
		Failed => FileSystem(Failed)
	}

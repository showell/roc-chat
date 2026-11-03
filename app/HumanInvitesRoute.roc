## This module answers the human invites' routes (`Route` lists them),
## moving data between the web interface and the file system, as
## `AgentsRoute` does for agents. What each route may do is
## `HumanInvites`' to decide; this module reads, writes and answers.
##
## Inviting someone writes, in order: the counter of ids, the new human's
## account (`inviter`, then `name`), then the invite (its `hash` last). A
## failure part way leaves an account holding the name with no code, which
## its inviter invites again, never a code for a half-made account. The
## page that shows a code is never stored by a browser or a proxy.
##
## The redemption is the one route here that answers a request that proves
## no one (`SignedIn.Actor`'s `Anonymous`), as `/agents/redeem` is: the
## invite's code is its credential, a request with an API key is refused,
## and any refusal of the code is one 401 that says no more. The invite is
## spent before the password is written, so a code redeems once even when
## the write fails; then the human's password's bcrypt hash, made by the
## host at its standard cost, replaces any before it, and a session starts
## (`SignInRoute.start_session_by_invite!`).
import pf.Host
import pf.Http
import AgentsRoute
import Directory
import FileSystem
import HttpAnswer
import HumanInvite
import HumanInvites
import PeoplePages
import Page
import Secret
import SecretToken
import SignInRoute
import SignedIn
import TrustedHtml
import UserId
import Users

HumanInvitesRoute :: [].{

	## A GET of `/invites`: a form that invites someone, and each human the
	## acting human may invite again, with their invites.
	show! : { acting : SignedIn, directory : Directory } => Http.Response
	show! = |{ acting, directory }|
		match load_invites_page!({
			acting,
			directory,
			shown: NoCode,
		}) {
			Ok(html) => HttpAnswer.page(200, html)
			Err(why) => refusal_page(why)
		}

	## A POST of `/invites`: a new human named by the form's `name`, and an
	## invite for them, at `now`; then the invites page, showing its code
	## this once.
	invite! : {
		acting : SignedIn,
		directory : Directory,
		body : List(U8),
		now : I64,
	} => Http.Response
	invite! = |request|
		match invite_human!(request) {
			Ok(html) => HttpAnswer.never_stored(HttpAnswer.page(200, html))
			Err(why) => refusal_page(why)
		}

	## A POST of `/invites/<id>/again`: a new invite for the human `human`,
	## at `now`; then the invites page, showing its code this once.
	invite_again! : {
		acting : SignedIn,
		directory : Directory,
		human : UserId,
		now : I64,
	} => Http.Response
	invite_again! = |request|
		match invite_human_again!(request) {
			Ok(html) => HttpAnswer.never_stored(HttpAnswer.page(200, html))
			Err(why) => refusal_page(why)
		}

	## A POST of `/invites/redeem`, by `actor`, anyone but a request with an
	## API key: the invite the form's `code` names spent at `now`, its
	## human's password set to the form's `password`, and a session started.
	redeem! : {
		actor : SignedIn.Actor,
		directory : Directory,
		body : List(U8),
		now : I64,
	} => Http.Response
	redeem! = |request|
		match redeem_invite!(request) {
			Ok(redeemed) => SignInRoute.start_session_by_invite!(redeemed, request.now)
			Err(why) => HttpAnswer.never_stored(refusal_page(why))
		}
}

## Why a route here refused: one of `HumanInvites`' refusals, a stored
## `inviter` that names no one, or the file system's fault.
Failure : [
	Refused(HumanInvites.Refusal),
	BadInviter(UserId),
	FileSystem(FileSystem.Fault),
]

## A failure as a page, with its status.
refusal_page : Failure -> Http.Response
refusal_page = |why| {
	notice =
		match why {
			Refused(refusal) => HumanInvites.refusal_notice(refusal)
			BadInviter(id) => { status: 500, said: "The inviter file of user ${id.to_str()} names no user." }
			FileSystem(fault) => { status: 500, said: FileSystem.fault_words(fault) }
		}
	HttpAnswer.page(notice.status, Page.notice({ title: "Refused", text: notice.said }))
}

## The invites page for `acting`, with `shown`'s code if one was just made:
## every human `acting` may invite again, each with their invites.
load_invites_page! : {
	acting : SignedIn,
	directory : Directory,
	shown : [NoCode, Code({ human : Users.User, code : SecretToken })],
} => Try(TrustedHtml, _)
load_invites_page! = |
	{
		acting,
		directory,
		shown,
	},
| {
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
			invited: $invited,
			shown,
		}),
	)
}

invite_human! : {
	acting : SignedIn,
	directory : Directory,
	body : List(U8),
	now : I64,
} => Try(TrustedHtml, _)
invite_human! = |
	{
		acting,
		directory,
		body,
		now,
	},
| {
	open = count_open_invites!(directory, { by: acting.user().id(), now })?
	made = HumanInvites.invite(
		directory,
		{
			acting,
			body,
			open,
		},
	) ? |why| Refused(why)
	FileSystem.replace_user_counter!(made.directory.users()) ? |fault| FileSystem(fault)
	FileSystem.create_invited_account!({ human: made.human, inviter: made.inviter.id() }) ? |fault| FileSystem(fault)
	code = issue_invite!({
		human: made.human.id(),
		by: made.inviter.id(),
		now,
	})?
	load_invites_page!({
		acting,
		directory: made.directory,
		shown: Code({ human: made.human, code }),
	})
}

invite_human_again! : {
	acting : SignedIn,
	directory : Directory,
	human : UserId,
	now : I64,
} => Try(TrustedHtml, _)
invite_human_again! = |
	{
		acting,
		directory,
		human,
		now,
	},
| {
	inviter = load_inviter!(human)?
	open = count_open_invites!(directory, { by: acting.user().id(), now })?
	again = HumanInvites.reinvite(
		directory,
		{
			acting,
			human,
			inviter,
			open,
		},
	) ? |why| Refused(why)
	code = issue_invite!({
		human,
		by: again.by.id(),
		now,
	})?
	load_invites_page!({
		acting,
		directory,
		shown: Code({ human: again.human.user(), code }),
	})
}

## A new invite for the human `human`, made by `by` at `now`, written, its
## code's hash last; and its code, to show once.
issue_invite! : {
	human : UserId,
	by : UserId,
	now : I64,
} => Try(SecretToken, _)
issue_invite! = |
	{
		human,
		by,
		now,
	},
| {
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

## The redemption: the form read, the invite spent, the password written;
## then the admission, and the hash written, which the session is signed
## over.
redeem_invite! : {
	actor : SignedIn.Actor,
	directory : Directory,
	body : List(U8),
	now : I64,
} => Try({ admission : HumanInvite.Admission, password_hash : List(U8) }, _)
redeem_invite! = |
	{
		actor,
		directory,
		body,
		now,
	},
| {
	_ =
		match actor {
			Anonymous => Ok({})
			SignedIn(acting) =>
				match acting.credential() {
					ApiKey(_) => Err(Refused(ByApiKey))
					Session => Ok({})
				}
		}?
	token = HumanInvites.code_from_form(body) ? |why| Refused(why)
	password = HumanInvites.password_from_form(body) ? |why| Refused(why)
	invites =
		match directory.users().user(token.user()) {
			Ok(user) =>
				match user.role() {
					Human => FileSystem.read_human_invites!(user.id()) ? |fault| FileSystem(fault)
					Agent(_) => []
				}
			Err(NoSuchUser) => []
		}
	redeemed = HumanInvites.redeem(
		directory,
		{
			token,
			invites,
			hash: AgentsRoute.hash_secret!(token.secret()),
			now,
		},
	) ? |why| Refused(why)
	FileSystem.replace_human_invite_state!(token.user(), redeemed.spent) ? |fault| FileSystem(fault)
	hash = Host.bcrypt_hash_of_password!(password.bytes_to_check())
	FileSystem.replace_password_hash!(token.user(), hash) ? |fault| FileSystem(fault)
	Ok({ admission: redeemed.admission, password_hash: hash })
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

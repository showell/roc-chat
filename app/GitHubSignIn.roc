## Signing in with GitHub is a run of states, each an opaque type this module
## alone makes, and each step a pure function of the state before it and the
## facts the host gave. No step can be skipped: there is no code to exchange
## until the state is checked, and no account until GitHub has said who this
## is.
##
##     GET /login/github    `CameBack`        the state and GitHub's code
##                          `StateChecked`    this browser's, and in time
##     (the host asks)      `IdentityKnown`   GitHub's id and login
##                          `Admission`       the human that id belongs to, or
##                          `NewHuman`        an id no human holds, or
##                          `Linked`          the human who is linking it
##     POST /login/github/name
##                          `SignUpResumed`   that id, back from its browser
##                          `Admission`       the account made for it
##
## Sign-up is open: any GitHub account makes an account here. The human whose
## `github-id` file holds the id GitHub answered signs in
## (`IdentityKnown.resolve`). An id no human holds is a new human, who chooses
## a name, which makes their account (`SignUpResumed.create_account`). An id
## two humans hold is refused, as no one can say whose sign-in it is. The
## login is only what GitHub calls the account now, so a rename signs in as
## before, and a login someone else took signs in no one.
##
## A human signed in by their own session may link GitHub to their account
## once. The trip is the same, but its state names them (`GitHubState.Errand`),
## so `IdentityKnown.resolve` answers `Linking` and makes no account. The
## session that comes back must be that human's, they must have no `github-id`
## yet, and nobody may hold the id.
##
## A human signed in already who comes back from any GitHub trip links too, so
## `IdentityKnown.resolve` makes no second account for them, and a human holding
## an id never holds another. The name form is for no one signed in
## (`SignUpResumed.resume`). So one GitHub id reaches one account, and one
## account holds one id.
##
## Between the two requests the id travels as a `GitHubSignUp`, signed by the
## server. It isn't spent: making the account binds the id, so
## `create_account` refuses a sign-up whose id has an account now, and a
## double submit, a second tab or a replay makes no second account and signs
## no one in.
##
## An `Admission` is the only way from here to a session
## (`SignInRoute.start_session_by_github!` takes nothing else), so no handler
## mints a session by calling a constructor. This module is a trust boundary
## with `SignedIn`, `AgentKey`, `AgentInvite` and `HumanInvite`. The client
## secret and GitHub's token stay in the host (host/github_client.zig).
import Channels
import Directory
import GitHubCode
import GitHubId
import GitHubLogin
import GitHubRefusal
import GitHubSignUp
import GitHubState
import Html
import Name
import SignedIn
import Timestamp
import UserId
import Users

GitHubSignIn :: [].{

	## Why a sign-in is refused, as `GitHubRoute` says it.
	Refusal : GitHubRefusal.Reason

	## What GitHub sent the browser back with: a code, none, as when its
	## human says no, or one it wouldn't send.
	Answer : [Code(GitHubCode), NoCode, BadCode]

	## GitHub sent the browser back.
	CameBack :: { state : GitHubState, code : GitHubCode }.{

		## From the facts of the return: the state, if its signature held,
		## and GitHub's answer. A state not signed by this server is said
		## first, whatever GitHub answered.
		came_back : {
			state : [Signed(GitHubState), Unsigned],
			answer : GitHubSignIn.Answer,
		} -> Try(
			GitHubSignIn.CameBack,
			[StateForged, GitHubDenied, NotACode],
		)
		came_back = |{ state, answer }|
			match (state, answer) {
				(Unsigned, _) => Err(StateForged)
				(Signed(_), NoCode) => Err(GitHubDenied)
				(Signed(_), BadCode) => Err(NotACode)
				(Signed(signed), Code(code)) =>
					Ok(GitHubSignIn.CameBack.({ state: signed, code }))
			}

		## The state held to this browser's `cookie` at `now`
		## (`GitHubState.check`).
		check : GitHubSignIn.CameBack,
		{ cookie : GitHubState.Cookie, now : Timestamp } -> Try(
			GitHubSignIn.StateChecked,
			[StateMismatched, StateExpired],
		)
		check = |GitHubSignIn.CameBack.(came), asked|
			match came.state.check(asked) {
				Mismatched => Err(StateMismatched)
				Expired => Err(StateExpired)
				Valid => Ok(
					GitHubSignIn.StateChecked.(
						{
							code: came.code,
							next: came.state.next(),
							errand: came.state.errand(),
						},
					),
				)
			}
	}

	## The state is good, and the code may be exchanged now.
	StateChecked :: {
		code : GitHubCode,
		next : Html.SitePath,
		errand : GitHubState.Errand,
	}.{

		## The code's bytes, for the host to exchange at GitHub.
		code_bytes : GitHubSignIn.StateChecked -> List(U8)
		code_bytes = |GitHubSignIn.StateChecked.(checked)| checked.code.bytes_to_exchange()

		## From what the host heard of GitHub: who this is, or why not.
		identify : GitHubSignIn.StateChecked,
		{
			status : [Denied, Failed, Identified],
			github_id : U64,
			login : List(U8),
		} -> Try(
			GitHubSignIn.IdentityKnown,
			[CodeRefused, GitHubUnreachable, BadIdentity],
		)
		identify = |GitHubSignIn.StateChecked.(checked), { status, github_id, login }|
			match status {
				Denied => Err(CodeRefused)
				Failed => Err(GitHubUnreachable)
				Identified =>
					match (GitHubId.from_u64(github_id), GitHubLogin.from_utf8(login)) {
						(Ok(github), Ok(known)) => Ok(
							GitHubSignIn.IdentityKnown.(
								{
									github,
									login: known,
									next: checked.next,
									errand: checked.errand,
								},
							),
						)
						_ => Err(BadIdentity)
					}
			}
	}

	## GitHub has said who this is.
	IdentityKnown :: {
		github : GitHubId,
		login : GitHubLogin,
		next : Html.SitePath,
		errand : GitHubState.Errand,
	}.{

		## What this answer of GitHub's means, among `users`, for `viewer`, who
		## came back with it. `links` is every user's GitHub account as their
		## `github-id` files were read.
		##
		## For a sign-in by no one signed in: `Known`, the admission of the human
		## linked to this id, or `Unknown`, a new human, when none is. An agent's
		## link, or one of a user no one is, admits no one.
		##
		## For a link: `Linking`, the human it binds the id to, or why not
		## (`linked_to`). A sign-in by a human signed in is one too, unless the
		## id is theirs already (`signed_in_return`).
		resolve : GitHubSignIn.IdentityKnown,
		{
			links : List({ user : UserId, github : GitHubId }),
			users : Users,
			viewer : SignedIn.Actor,
		} -> Try(
			[
				Known(GitHubSignIn.Admission),
				Unknown(GitHubSignIn.NewHuman),
				Linking(GitHubSignIn.Linked),
			],
			[DuplicateAccount, LinkNotYours, AlreadyLinked, GitHubIdTaken],
		)
		resolve = |GitHubSignIn.IdentityKnown.(known), { links, users, viewer }|
			match (known.errand, GitHubSignIn.human_to_link(viewer)) {
				(Link(id), _) =>
					linked_to({
						id,
						github: known.github,
						next: known.next,
						links,
						viewer,
					}).map_ok(|linked| Linking(linked))
				(SignIn, Ok(human)) =>
					signed_in_return({
						human,
						github: known.github,
						next: known.next,
						links,
						users,
						viewer,
					})
				(SignIn, Err(NotSignedIn)) =>
					match humans_holding({ github: known.github, links, users }) {
						[] => Ok(
							Unknown(
								GitHubSignIn.NewHuman.(
									{
										github: known.github,
										login: known.login,
										next: known.next,
									},
								),
							),
						)
						[human] => Ok(Known(GitHubSignIn.Admission.({ human, next: known.next })))
						_ => Err(DuplicateAccount)
					}
				(SignIn, Err(_)) => Err(LinkNotYours)
			}
	}

	## GitHub has said who this is, and that id goes to `human`.
	Linked :: {
		human : Users.Human,
		github : GitHubId,
		next : Html.SitePath,
	}.{

		## The human it binds the id to.
		human : GitHubSignIn.Linked -> Users.Human
		human = |GitHubSignIn.Linked.(linked)| linked.human

		## The GitHub account it binds.
		github : GitHubSignIn.Linked -> GitHubId
		github = |GitHubSignIn.Linked.(linked)| linked.github

		## The admission that starts their session once the id is written.
		admission : GitHubSignIn.Linked -> GitHubSignIn.Admission
		admission = |GitHubSignIn.Linked.(linked)|
			GitHubSignIn.Admission.({ human: linked.human, next: linked.next })
	}

	## The human `viewer` starts linking GitHub for: a human, by their own
	## session; unless no one is signed in (`NotSignedIn`), or the request came
	## with an API key (`ByApiKey`), or from an agent (`Agent`).
	human_to_link : SignedIn.Actor -> Try(Users.Human, [NotSignedIn, ByApiKey, Agent(UserId)])
	human_to_link = |viewer|
		match viewer {
			Anonymous => Err(NotSignedIn)
			SignedIn(acting) => acting.human_in_session()
		}

	## GitHub has said who this is, and no human holds the id.
	NewHuman :: {
		github : GitHubId,
		login : GitHubLogin,
		next : Html.SitePath,
	}.{

		## What GitHub calls this human's account now.
		login : GitHubSignIn.NewHuman -> GitHubLogin
		login = |GitHubSignIn.NewHuman.(new_human)| new_human.login

		## What carries this human to the name they choose, issued at `now`.
		sign_up : GitHubSignIn.NewHuman, Timestamp -> GitHubSignUp
		sign_up = |GitHubSignIn.NewHuman.(new_human), now|
			GitHubSignUp.issue({ github: new_human.github, now, next: new_human.next })

		## The name to offer this human: their login, when it is a name and
		## free in `directory`; else `NoSuggestion`.
		suggested_name : GitHubSignIn.NewHuman, Directory -> [Suggested(Name), NoSuggestion]
		suggested_name = |GitHubSignIn.NewHuman.(new_human), directory|
			match Name.from_str(new_human.login.to_str()) {
				Err(_) => NoSuggestion
				Ok(name) =>
					match directory.add_human(name) {
						Ok(_) => Suggested(name)
						Err(NameTaken) => NoSuggestion
						Err(Full) => NoSuggestion
					}
			}
	}

	## A sign-up back from its browser, signed and in time.
	SignUpResumed :: { github : GitHubId, next : Html.SitePath }.{

		## From the facts of the request: the sign-up, if its signature held,
		## who sent it, and the time. A browser that has signed in since the
		## form was shown is refused (`SignedInAlready`), as its human links
		## GitHub to the account they have.
		resume : {
			sign_up : [Signed(GitHubSignUp), Unsigned],
			viewer : SignedIn.Actor,
			now : Timestamp,
		} -> Try(
			GitHubSignIn.SignUpResumed,
			[SignUpForged, SignUpExpired, SignedInAlready],
		)
		resume = |{ sign_up, viewer, now }|
			match (sign_up, viewer) {
				(Unsigned, _) => Err(SignUpForged)
				(Signed(_), SignedIn(_)) => Err(SignedInAlready)
				(Signed(signed), Anonymous) =>
					match signed.check(now) {
						Expired => Err(SignUpExpired)
						Valid => Ok(
							GitHubSignIn.SignUpResumed.(
								{ github: signed.github(), next: signed.next() },
							),
						)
					}
			}

		## The account this sign-up makes, named `name`, in `directory`; `links`
		## is each user's GitHub account as their `github-id` files were read. An id any human
		## holds now is refused first (`AccountExists`, or `DuplicateAccount`),
		## and then the name (`NameTaken`), so a refused name leaves the
		## sign-up good, and the human tries another. The human starts in the
		## default channel, whose members file `channel` is for the caller to
		## write.
		create_account : GitHubSignIn.SignUpResumed,
		{
			name : Name,
			links : List({ user : UserId, github : GitHubId }),
			directory : Directory,
		} -> Try(
			{
				directory : Directory,
				human : Users.User,
				channel : Channels.Channel,
				github : GitHubId,
				admission : GitHubSignIn.Admission,
			},
			[AccountExists, DuplicateAccount, NameTaken, Full, NoDefaultChannel],
		)
		create_account = |GitHubSignIn.SignUpResumed.(resumed), { name, links, directory }|
			match humans_holding({ github: resumed.github, links, users: directory.users() }) {
				[_] => Err(AccountExists)
				[_, _, ..] => Err(DuplicateAccount)
				[] => {
					addition = directory.add_new_human(name)?
					human =
						addition.user.as_human()
							?? crash "GitHubSignIn.create_account: add_new_human makes a human"
					Ok({
						directory: addition.directory,
						human: addition.user,
						channel: addition.channel,
						github: resumed.github,
						admission: GitHubSignIn.Admission.({ human, next: resumed.next }),
					})
				}
			}
	}

	## A human GitHub vouched for, for `SignInRoute` to start a session.
	Admission :: { human : Users.Human, next : Html.SitePath }.{

		## The human it admits.
		human : GitHubSignIn.Admission -> Users.Human
		human = |GitHubSignIn.Admission.(admission)| admission.human

		## Where they go once signed in.
		next : GitHubSignIn.Admission -> Html.SitePath
		next = |GitHubSignIn.Admission.(admission)| admission.next

		## The same admission, going to `landing` instead.
		going_to : GitHubSignIn.Admission, Html.SitePath -> GitHubSignIn.Admission
		going_to = |GitHubSignIn.Admission.(admission), landing|
			GitHubSignIn.Admission.({ ..admission, next: landing })
	}
}

## What GitHub's answer means for `human`, signed in as `viewer`, who came back
## from a sign-in: the admission of the human they are when the id is theirs,
## else the link of the id to them (`linked_to`).
signed_in_return : {
	human : Users.Human,
	github : GitHubId,
	next : Html.SitePath,
	links : List({ user : UserId, github : GitHubId }),
	users : Users,
	viewer : SignedIn.Actor,
} -> Try(
	[
		Known(GitHubSignIn.Admission),
		Unknown(GitHubSignIn.NewHuman),
		Linking(GitHubSignIn.Linked),
	],
	[DuplicateAccount, LinkNotYours, AlreadyLinked, GitHubIdTaken],
)
signed_in_return = |
	{
		human,
		github,
		next,
		links,
		users,
		viewer,
	},
|
	match humans_holding({ github, links, users }) {
		[holder] if holder.id() == human.id() => Ok(Known(GitHubSignIn.Admission.({ human, next })))
		[_, _, ..] => Err(DuplicateAccount)
		_ =>
			linked_to({
				id: human.id(),
				github,
				next,
				links,
				viewer,
			}).map_ok(|linked| Linking(linked))
	}

## The link of `github` to the human `id`: `viewer` must be that human, by
## their own session (`LinkNotYours`), with no GitHub account of their own
## (`AlreadyLinked`), and no user may be linked to the id (`GitHubIdTaken`),
## an agent included, as nothing about a stray file says who it is for.
linked_to : {
	id : UserId,
	github : GitHubId,
	next : Html.SitePath,
	links : List({ user : UserId, github : GitHubId }),
	viewer : SignedIn.Actor,
} -> Try(
	GitHubSignIn.Linked,
	[LinkNotYours, AlreadyLinked, GitHubIdTaken],
)
linked_to = |{ id, github, next, links, viewer }|
	match GitHubSignIn.human_to_link(viewer) {
		Ok(human) if human.id() == id =>
			if links.any(|link| link.user == id) {
				Err(AlreadyLinked)
			} else if links.any(|link| link.github == github) {
				Err(GitHubIdTaken)
			} else {
				Ok(GitHubSignIn.Linked.({ human, github, next }))
			}
		_ => Err(LinkNotYours)
	}

## The humans among `users` whom `links` links to the id `github`.
humans_holding : {
	github : GitHubId,
	links : List({ user : UserId, github : GitHubId }),
	users : Users,
} -> List(Users.Human)
humans_holding = |{ github, links, users }|
	links
		.keep_if(|link| link.github == github)
		.keep_oks(|link| users.user(link.user))
		.keep_oks(|user| user.as_human())

# ── tests
# The tests of every other step are in `GitHubSignInSpec`. This one reads
# what a resumed sign-up holds, which nothing outside the module can.

## A sign-up of the id 300, going to /agents, issued at 1000 and resumed at 1300.
resumed_up : GitHubSignIn.SignUpResumed
resumed_up = {
	github = GitHubId.from_u64(300) ?? crash "GitHubSignIn's tests: a GitHub id"
	next = Html.SitePath.from_str("/agents") ?? crash "GitHubSignIn's tests: a site path"
	GitHubSignIn.SignUpResumed.resume({
		sign_up: Signed(GitHubSignUp.issue({ github, now: Timestamp.at_second(1000), next })),
		viewer: Anonymous,
		now: Timestamp.at_second(1300),
	}) ?? crash "GitHubSignIn's tests: a sign-up in time"
}

## The id and the path a resumed sign-up holds, as a test reads it.
resumed_text : GitHubSignIn.SignUpResumed -> (Str, Str)
resumed_text = |GitHubSignIn.SignUpResumed.(resumed)| (
	resumed.github.to_str(),
	resumed.next.to_str(),
)

# A sign-up keeps the id and where to go.
expect resumed_text(resumed_up) == ("300", "/agents")

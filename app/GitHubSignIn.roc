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
import GitHubSignUp
import GitHubState
import Html
import Name
import SignedIn
import UserId
import Users

GitHubSignIn :: [].{

	## Why a sign-in is refused, as `GitHubRoute` says it.
	Refusal : [
		## The state did not come back signed by this server.
		StateForged,

		## The state is not this browser's: another site's doing, or a
		## browser that lost its cookie.
		StateMismatched,

		## The state is out of its window (`GitHubState.lifetime_seconds`).
		StateExpired,

		## GitHub sent the browser back with no code: the human said no.
		GitHubDenied,

		## The code is not one GitHub would send.
		NotACode,

		## GitHub refused the code: spent, expired, or the client's
		## credentials are wrong.
		CodeRefused,

		## GitHub didn't answer, or its answer made no sense.
		GitHubUnreachable,

		## GitHub's answer is no identity: an id of 0, or a login that isn't.
		BadIdentity,

		## More than one human holds the id.
		DuplicateAccount,

		## The sign-up did not come back signed by this server.
		SignUpForged,

		## The sign-up is out of its window (`GitHubSignUp.check`).
		SignUpExpired,

		## The sign-up's id has an account now, which signs in with GitHub.
		AccountExists,

		## The default channel is gone, so a new human has nowhere to start.
		NoDefaultChannel,

		## The session that came back is not the human the link's state names.
		LinkNotYours,

		## The human linking has a `github-id` already.
		AlreadyLinked,

		## Someone holds the id the human tried to link.
		GitHubIdTaken,

		## A sign-up came back from a browser signed in by then, whose human
		## links GitHub rather than making an account.
		SignedInAlready,

		## The server's clock can't date a new human's welcome.
		ClockOutOfRange,
	]

	## What GitHub sent the browser back with: a code, none, as when its
	## human says no, or one it wouldn't send.
	Answer : [
		Code(GitHubCode),
		NoCode,
		BadCode,
	]

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
			[
				StateForged,
				GitHubDenied,
				NotACode,
			],
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
		{ cookie : GitHubState.Cookie, now : I64 } -> Try(
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
			id : U64,
			login : List(U8),
		} -> Try(
			GitHubSignIn.IdentityKnown,
			[
				CodeRefused,
				GitHubUnreachable,
				BadIdentity,
			],
		)
		identify = |
			GitHubSignIn.StateChecked.(checked),
			{
				status,
				id,
				login,
			},
		|
			match status {
				Denied => Err(CodeRefused)
				Failed => Err(GitHubUnreachable)
				Identified =>
					match (GitHubId.from_u64(id), GitHubLogin.from_utf8(login)) {
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
		## came back with it. `files` is every user's `github-id` file as it
		## was read.
		##
		## For a sign-in by no one signed in: `Known`, the admission of the human
		## whose file holds this id, or `Unknown`, a new human, when none does.
		## A file that holds no id, or an agent's, admits no one and fails only
		## itself.
		##
		## For a link: `Linking`, the human it binds the id to, or why not
		## (`linked_to`). A sign-in by a human signed in is one too, unless the
		## id is theirs already (`signed_in_return`).
		resolve : GitHubSignIn.IdentityKnown,
		{
			files : List({ user : UserId, file : List(U8) }),
			users : Users,
			viewer : SignedIn.Actor,
		} -> Try(
			[
				Known(GitHubSignIn.Admission),
				Unknown(GitHubSignIn.NewHuman),
				Linking(GitHubSignIn.Linked),
			],
			[
				DuplicateAccount,
				LinkNotYours,
				AlreadyLinked,
				GitHubIdTaken,
			],
		)
		resolve = |
			GitHubSignIn.IdentityKnown.(known),
			{
				files,
				users,
				viewer,
			},
		|
			match (known.errand, GitHubSignIn.human_to_link(viewer)) {
				(Link(id), _) =>
					linked_to({
						id,
						github: known.github,
						next: known.next,
						files,
						viewer,
					}).map_ok(|linked| Linking(linked))
				(SignIn, Ok(human)) =>
					signed_in_return({
						human,
						github: known.github,
						next: known.next,
						files,
						users,
						viewer,
					})
				(SignIn, Err(NotSignedIn)) =>
					match humans_holding({
						github: known.github,
						files,
						users,
					}) {
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
	human_to_link : SignedIn.Actor -> Try(
		Users.Human,
		[
			NotSignedIn,
			ByApiKey,
			Agent(UserId),
		],
	)
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

		## What carries this human to the name they choose, issued at `now`.
		sign_up : GitHubSignIn.NewHuman, I64 -> GitHubSignUp
		sign_up = |GitHubSignIn.NewHuman.(new_human), now|
			GitHubSignUp.issue({
				github: new_human.github,
				now,
				next: new_human.next,
			})

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
			now : I64,
		} -> Try(
			GitHubSignIn.SignUpResumed,
			[
				SignUpForged,
				SignUpExpired,
				SignedInAlready,
			],
		)
		resume = |
			{
				sign_up,
				viewer,
				now,
			},
		|
			match (sign_up, viewer) {
				(Unsigned, _) => Err(SignUpForged)
				(Signed(_), SignedIn(_)) => Err(SignedInAlready)
				(Signed(signed), Anonymous) =>
					match signed.check(now) {
						Expired => Err(SignUpExpired)
						Valid => Ok(
							GitHubSignIn.SignUpResumed.(
								{
									github: signed.github(),
									next: signed.next(),
								},
							),
						)
					}
			}

		## The account this sign-up makes, named `name`, in `directory`; `files`
		## is each human's `github-id` file as it was read. An id any human
		## holds now is refused first (`AccountExists`, or `DuplicateAccount`),
		## and then the name (`NameTaken`), so a refused name leaves the
		## sign-up good, and the human tries another. The human starts in the
		## default channel, whose members file `channel` is for the caller to
		## write.
		create_account : GitHubSignIn.SignUpResumed,
		{
			name : Name,
			files : List({ user : UserId, file : List(U8) }),
			directory : Directory,
		} -> Try(
			{
				directory : Directory,
				human : Users.User,
				channel : Channels.Channel,
				github : GitHubId,
				admission : GitHubSignIn.Admission,
			},
			[
				AccountExists,
				DuplicateAccount,
				NameTaken,
				Full,
				NoDefaultChannel,
			],
		)
		create_account = |
			GitHubSignIn.SignUpResumed.(resumed),
			{
				name,
				files,
				directory,
			},
		|
			match humans_holding({
				github: resumed.github,
				files,
				users: directory.users(),
			}) {
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
	files : List({ user : UserId, file : List(U8) }),
	users : Users,
	viewer : SignedIn.Actor,
} -> Try(
	[
		Known(GitHubSignIn.Admission),
		Unknown(GitHubSignIn.NewHuman),
		Linking(GitHubSignIn.Linked),
	],
	[
		DuplicateAccount,
		LinkNotYours,
		AlreadyLinked,
		GitHubIdTaken,
	],
)
signed_in_return = |
	{
		human,
		github,
		next,
		files,
		users,
		viewer,
	},
|
	match humans_holding({
		github,
		files,
		users,
	}) {
		[holder] if holder.id() == human.id() => Ok(Known(GitHubSignIn.Admission.({ human, next })))
		[_, _, ..] => Err(DuplicateAccount)
		_ =>
			linked_to({
				id: human.id(),
				github,
				next,
				files,
				viewer,
			}).map_ok(|linked| Linking(linked))
	}

## The link of `github` to the human `id`: `viewer` must be that human, by
## their own session (`LinkNotYours`), with no `github-id` file of their own
## (`AlreadyLinked`), and no user's file may hold the id (`GitHubIdTaken`),
## an agent's included, as nothing about a stray file says who it is for.
linked_to : {
	id : UserId,
	github : GitHubId,
	next : Html.SitePath,
	files : List({ user : UserId, file : List(U8) }),
	viewer : SignedIn.Actor,
} -> Try(
	GitHubSignIn.Linked,
	[
		LinkNotYours,
		AlreadyLinked,
		GitHubIdTaken,
	],
)
linked_to = |
	{
		id,
		github,
		next,
		files,
		viewer,
	},
|
	match GitHubSignIn.human_to_link(viewer) {
		Ok(human) if human.id() == id =>
			if (files.any(|held| held.user == id))
				Err(AlreadyLinked)
			else if (files.any(|held| GitHubId.from_file(held.file) == Ok(github)))
				Err(GitHubIdTaken)
			else
				Ok(
					GitHubSignIn.Linked.(
						{
							human,
							github,
							next,
						},
					),
				)
		_ => Err(LinkNotYours)
	}

## The humans among `users` whose file in `files` holds the id `github`.
humans_holding : {
	github : GitHubId,
	files : List({ user : UserId, file : List(U8) }),
	users : Users,
} -> List(Users.Human)
humans_holding = |
	{
		github,
		files,
		users,
	},
|
	files
		.keep_if(|held| GitHubId.from_file(held.file) == Ok(github))
		.keep_oks(|held| users.user(held.user))
		.keep_oks(|user| user.as_human())

# ── tests
agents_path : Html.SitePath
agents_path = Html.SitePath.from_str("/agents") ?? crash "GitHubSignIn's tests: a site path"

nonce_held : List(U8)
nonce_held = List.repeat('n', 32)

## A state issued at 1000.
issued : GitHubState
issued = GitHubState.issue({
	nonce: nonce_held,
	now: 1000,
	next: agents_path,
	errand: SignIn,
})

good_code : GitHubCode
good_code = GitHubCode.from_str("good") ?? crash "GitHubSignIn's tests: a code"

tests_name : Str -> Name
tests_name = |text| Name.from_str(text) ?? crash "GitHubSignIn's tests: a name"

## Steve, 1, Apoorva, 2, and Steve's agent CC, 3, with no channel.
tests_directory_of_no_channel : Directory
tests_directory_of_no_channel = {
	founded = Directory.with_founder(tests_name("Steve"))
	steve = founded.chat_owner()
	with_apoorva = (founded.add_human(tests_name("Apoorva")) ?? crash "GitHubSignIn's tests: room").directory
	(
		with_apoorva.add_agent({
			name: tests_name("CC"),
			owner: steve,
		}) ?? crash "GitHubSignIn's tests: room"
	).directory
}

## Those users, with Steve in the default channel.
tests_directory : Directory
tests_directory = {
	channels =
		Channels.from_files([{ name: Channels.default_name, members: "1\n".to_utf8() }])
			?? crash "GitHubSignIn's tests: a members file"
	Directory.from_files({ users: tests_directory_of_no_channel.users(), channels })
		?? crash "GitHubSignIn's tests: Steve is a user"
}

tests_users : Users
tests_users = tests_directory.users()

## The user id `text` spells.
id_of : Str -> UserId
id_of = |text| UserId.from_str(text) ?? crash "GitHubSignIn's tests: an id"

## The `github-id` files of the tests: Steve is 100, Apoorva 200.
bound_files : List({ user : UserId, file : List(U8) })
bound_files = [
	{ user: UserId.chat_owner, file: "100\n".to_utf8() },
	{ user: id_of("2"), file: "200".to_utf8() },
]

## What a return comes to, as a test reads it: the human admitted and where
## they go, the login of a new human, or the human linked and the id.
Landing : [
	Admitted(Str, Str),
	NewHumanNamed(Str),
	LinkedTo(Str, Str),
]

## Every step from a return, at `now`, with this `cookie`, GitHub's `heard`
## and these files, as a test reads it: where it lands, or the refusal.
round_trip : {
	state : [Signed(GitHubState), Unsigned],
	answer : GitHubSignIn.Answer,
	cookie : GitHubState.Cookie,
	now : I64,
	heard : {
		status : [Denied, Failed, Identified],
		id : U64,
		login : List(U8),
	},
	files : List({ user : UserId, file : List(U8) }),
	viewer : SignedIn.Actor,
} -> Try(Landing, _)
round_trip = |
	{
		state,
		answer,
		cookie,
		now,
		heard,
		files,
		viewer,
	},
| {
	came = GitHubSignIn.CameBack.came_back({ state, answer })?
	checked = came.check({ cookie, now })?
	known = checked.identify(heard)?
	match known.resolve({
		files,
		users: tests_users,
		viewer,
	})? {
		Known(admission) =>
			Ok(Admitted(admission.human().user().name().to_str(), admission.next().to_str()))
		Unknown(GitHubSignIn.NewHuman.(new_human)) => Ok(NewHumanNamed(new_human.login.to_str()))
		Linking(linked) => {
			name = linked.admission().human().user().name().to_str()
			Ok(LinkedTo(name, linked.github().to_str()))
		}
	}
}

## GitHub's answer naming the account `id`, `login`.
github_answer : U64,
Str -> {
	status : [Denied, Failed, Identified],
	id : U64,
	login : List(U8),
}
github_answer = |id, login| {
	status: Identified,
	id,
	login: login.to_utf8(),
}

## A return that goes well all the way.
good_return = {
	state: Signed(issued),
	answer: Code(good_code),
	cookie: Sent(nonce_held),
	now: 1300,
	heard: github_answer(100, "showell"),
	files: bound_files,
	viewer: Anonymous,
}

# A good round trip admits the human holding the id, and goes to `next`,
# whatever login GitHub calls them now.
expect round_trip(good_return) == Ok(Admitted("Steve", "/agents"))
expect
	round_trip({ ..good_return, heard: github_answer(100, "renamed") })
		== Ok(Admitted("Steve", "/agents"))
expect
	round_trip({ ..good_return, heard: github_answer(200, "apoorva") })
		== Ok(Admitted("Apoorva", "/agents"))
# An account no human holds is a new human; no file means no account.
expect
	round_trip({ ..good_return, heard: github_answer(300, "stranger") })
		== Ok(NewHumanNamed("stranger"))
expect round_trip({ ..good_return, files: [] }) == Ok(NewHumanNamed("showell"))
# The login names no account: a stranger who took `showell` is still a stranger.
expect
	round_trip({ ..good_return, heard: github_answer(300, "showell") })
		== Ok(NewHumanNamed("showell"))
# A damaged file, an agent's, and a file of a user no one is admit no one.
expect
	[
		{ user: UserId.chat_owner, file: "x".to_utf8() },
		{ user: id_of("3"), file: "100".to_utf8() },
		{ user: id_of("9"), file: "100".to_utf8() },
	].all(|file| round_trip({ ..good_return, files: [file] }) == Ok(NewHumanNamed("showell")))
# A damaged file beside a good one fails only itself.
expect
	round_trip({
		..good_return,
		files: bound_files.append({ user: id_of("3"), file: "x".to_utf8() }),
	}) == Ok(Admitted("Steve", "/agents"))
# Two humans holding one id: neither is signed in.
expect
	round_trip({
		..good_return,
		files: [
			{ user: UserId.chat_owner, file: "100".to_utf8() },
			{ user: id_of("2"), file: "100".to_utf8() },
		],
	}) == Err(DuplicateAccount)
# A state not signed by this server is refused, whatever GitHub answered.
expect
	[
		Code(good_code),
		NoCode,
		BadCode,
	].all(
		|answer|
			round_trip({
				..good_return,
				state: Unsigned,
				answer,
			}) == Err(StateForged),
	)
# A good state with no code, or a code GitHub wouldn't send.
expect round_trip({ ..good_return, answer: NoCode }) == Err(GitHubDenied)
expect round_trip({ ..good_return, answer: BadCode }) == Err(NotACode)
# Another browser's state, and one out of its window.
expect round_trip({ ..good_return, cookie: Unsent }) == Err(StateMismatched)
expect round_trip({ ..good_return, cookie: Sent(List.repeat('m', 32)) }) == Err(StateMismatched)
expect round_trip({ ..good_return, now: 1599 }) == Ok(Admitted("Steve", "/agents"))
expect round_trip({ ..good_return, now: 1600 }) == Err(StateExpired)
# What the host heard of GitHub, each way it can go wrong.
expect
	round_trip({ ..good_return, heard: { ..github_answer(0, ""), status: Denied } })
		== Err(CodeRefused)
expect
	round_trip({ ..good_return, heard: { ..github_answer(0, ""), status: Failed } })
		== Err(GitHubUnreachable)
expect round_trip({ ..good_return, heard: github_answer(0, "showell") }) == Err(BadIdentity)
expect round_trip({ ..good_return, heard: github_answer(100, "not a login") }) == Err(BadIdentity)

## The user `text` names, signed in by a session.
viewer_of : Str -> SignedIn.Actor
viewer_of = |text| {
	user = tests_users.user(id_of(text)) ?? crash "GitHubSignIn's tests: a user"
	SignedIn(SignedIn.dangerously_assume(user))
}

## A return that links the id 300 to Apoorva, who holds none, signed in.
good_link = {
	..good_return,
	state: Signed(
		GitHubState.issue({
			nonce: nonce_held,
			now: 1000,
			next: agents_path,
			errand: Link(id_of("2")),
		}),
	),
	heard: github_answer(300, "apoorva-gh"),
	files: [{ user: UserId.chat_owner, file: "100".to_utf8() }],
	viewer: viewer_of("2"),
}

# A link binds the id to the human the state names, and makes no account.
expect round_trip(good_link) == Ok(LinkedTo("Apoorva", "300"))
# Only that human's session may finish it.
expect
	[
		Anonymous,
		viewer_of("1"),
		viewer_of("3"),
	].all(|viewer| round_trip({ ..good_link, viewer }) == Err(LinkNotYours))
# A human with a `github-id` already, whatever it holds, the same id included.
expect
	[
		"100",
		"300",
		"damaged",
	].all(
		|held|
			round_trip({ ..good_link, files: [{ user: id_of("2"), file: held.to_utf8() }] })
				== Err(AlreadyLinked),
	)
# An id anyone else holds, an agent included; a damaged file holds no id.
expect round_trip({ ..good_link, heard: github_answer(100, "someone") }) == Err(GitHubIdTaken)
expect
	round_trip({ ..good_link, files: [{ user: id_of("3"), file: "300".to_utf8() }] })
		== Err(GitHubIdTaken)
expect
	round_trip({ ..good_link, files: [{ user: UserId.chat_owner, file: "x".to_utf8() }] })
		== Ok(LinkedTo("Apoorva", "300"))
# A human signed in who comes back from a sign-in links: a free id binds to
# them, and goes where the sign-in was going. No account is made.
expect
	round_trip({
		..good_return,
		heard: github_answer(300, "stranger"),
		files: [{ user: UserId.chat_owner, file: "100".to_utf8() }],
		viewer: viewer_of("2"),
	})
		== Ok(LinkedTo("Apoorva", "300"))
# Their own id signs them in again, and links nothing.
expect round_trip({ ..good_return, viewer: viewer_of("1") }) == Ok(Admitted("Steve", "/agents"))
# An id someone else holds, and a second id for a human who holds one.
expect round_trip({ ..good_return, viewer: viewer_of("2") }) == Err(AlreadyLinked)
expect
	round_trip({
		..good_return,
		files: [{ user: UserId.chat_owner, file: "100".to_utf8() }],
		viewer: viewer_of("2"),
	})
		== Err(GitHubIdTaken)
expect
	round_trip({ ..good_return, heard: github_answer(300, "stranger"), viewer: viewer_of("1") })
		== Err(AlreadyLinked)
# Two humans holding the id, the viewer among them.
expect
	round_trip({
		..good_return,
		files: [
			{ user: UserId.chat_owner, file: "100".to_utf8() },
			{ user: id_of("2"), file: "100".to_utf8() },
		],
		viewer: viewer_of("2"),
	})
		== Err(DuplicateAccount)
# An agent is no one to link, and never reaches a new account.
expect
	round_trip({ ..good_return, heard: github_answer(300, "stranger"), viewer: viewer_of("3") })
		== Err(LinkNotYours)
# A link never skips the state's own checks.
expect round_trip({ ..good_link, state: Unsigned }) == Err(StateForged)
expect round_trip({ ..good_link, cookie: Unsent }) == Err(StateMismatched)
expect round_trip({ ..good_link, now: 1600 }) == Err(StateExpired)

# Who may start a link: a human by session; no one else.
expect GitHubSignIn.human_to_link(Anonymous).map_ok(|_| {}) == Err(NotSignedIn)
expect GitHubSignIn.human_to_link(viewer_of("2")).map_ok(|human| human.id()) == Ok(id_of("2"))
expect GitHubSignIn.human_to_link(viewer_of("3")).map_ok(|_| {}) == Err(Agent(id_of("3")))

## The new human GitHub calls `login`, of the id 300.
new_human_called : Str -> GitHubSignIn.NewHuman
new_human_called = |login| {
	github = GitHubId.from_u64(300) ?? crash "GitHubSignIn's tests: an id"
	known = GitHubLogin.from_utf8(login.to_utf8()) ?? crash "GitHubSignIn's tests: a login"
	GitHubSignIn.NewHuman.(
		{
			github,
			login: known,
			next: agents_path,
		},
	)
}

# The login is offered when it is a name and free, as GitHub spells it.
expect
	new_human_called("Zoe").suggested_name(tests_directory) == Suggested(tests_name("Zoe"))
# A login that is no name, one taken in any case, and a chat that is full,
# offer nothing.
expect
	[
		"person9",
		"mona-lisa",
		"Steve",
		"sTeVe",
		"cc",
	].all(|login| new_human_called(login).suggested_name(tests_directory) == NoSuggestion)
expect new_human_called("Zoe").suggested_name(full_directory) == NoSuggestion

## The tests' directory, its every id spent, as the counter says.
full_directory : Directory
full_directory = {
	accounts = tests_users.to_list().map(
		|user| { id: user.id(), files: Users.account_files(user) },
	)
	users =
		Users.from_files({ counter: "65536\n".to_utf8(), accounts })
			?? crash "GitHubSignIn's tests: the users' files read back"
	Directory.from_files({ users, channels: tests_directory.channels() })
		?? crash "GitHubSignIn's tests: the names are free"
}

## A sign-up of the id 300, as `new_human_called` issues one at 1000.
signed_up : GitHubSignUp
signed_up = new_human_called("Zoe").sign_up(1000)

## The sign-up resumed at 1300.
resumed_up : GitHubSignIn.SignUpResumed
resumed_up =
	resumed_at(1300) ?? crash "GitHubSignIn's tests: a sign-up in time"

## The sign-up resumed at `now` by a browser signed in as no one.
resumed_at : I64 -> Try(GitHubSignIn.SignUpResumed, _)
resumed_at = |now|
	GitHubSignIn.SignUpResumed.resume({
		sign_up: Signed(signed_up),
		viewer: Anonymous,
		now,
	})

## The id and the path a resumed sign-up holds, as a test reads it.
resumed_text : GitHubSignIn.SignUpResumed -> (Str, Str)
resumed_text = |GitHubSignIn.SignUpResumed.(resumed)| (
	resumed.github.to_str(),
	resumed.next.to_str(),
)

# A sign-up keeps the id and where to go.
expect resumed_text(resumed_up) == ("300", "/agents")
# A forged sign-up, and one out of its window at either end; in time at both.
expect
	GitHubSignIn.SignUpResumed.resume({
		sign_up: Unsigned,
		viewer: Anonymous,
		now: 1300,
	}).map_ok(|_| {})
		== Err(SignUpForged)
expect [999, 1600].all(|now| resumed_at(now).map_ok(|_| {}) == Err(SignUpExpired))
expect [1000, 1599].all(|now| resumed_at(now).map_ok(|_| {}) == Ok({}))
# A browser signed in by then makes no account, whoever it is; a forged
# sign-up says so first.
expect
	["1", "2"].all(
		|id|
			GitHubSignIn.SignUpResumed.resume({
				sign_up: Signed(signed_up),
				viewer: viewer_of(id),
				now: 1300,
			}).map_ok(|_| {})
				== Err(SignedInAlready),
	)
expect
	GitHubSignIn.SignUpResumed.resume({
		sign_up: Unsigned,
		viewer: viewer_of("2"),
		now: 1300,
	}).map_ok(|_| {})
		== Err(SignUpForged)

## What `create_account` makes of `name` with these `files` in `directory`, as
## a test reads it: the new human's id and name, where they go, the bound id,
## and the counter; or the refusal.
account_made : {
	name : Str,
	files : List({ user : UserId, file : List(U8) }),
	directory : Directory,
} -> Try(
	{
		id : Str,
		name : Str,
		next : Str,
		github : Str,
		counter : List(U8),
		members : List(U8),
	},
	_,
)
account_made = |
	{
		name,
		files,
		directory,
	},
| {
	made = resumed_up.create_account({
		name: tests_name(name),
		files,
		directory,
	})?
	Ok({
		id: made.admission.human().id().to_str(),
		name: made.human.name().to_str(),
		next: made.admission.next().to_str(),
		github: made.github.to_str(),
		counter: made.directory.users().counter_file(),
		members: made.channel.members_file(),
	})
}

## A sign-up under `name` in the tests' directory, the id 300 free.
account_named : Str -> Try(_, _)
account_named = |name|
	account_made({
		name,
		files: bound_files,
		directory: tests_directory,
	})

# A free name makes the next human, admitted, with the id bound, the counter
# past them and the default channel holding them. Their name need not be their
# login.
expect
	account_named("Zoë Ann")
		== Ok({
			id: "4",
			name: "Zoë Ann",
			next: "/agents",
			github: "300",
			counter: "5\n".to_utf8(),
			members: "1\n4\n".to_utf8(),
		})
# A chat whose default channel is gone makes no account.
expect
	account_made({
		name: "Zoe",
		files: bound_files,
		directory: tests_directory_of_no_channel,
	})
		== Err(NoDefaultChannel)
# A name another has, in any case, an agent's included, is refused and makes
# nothing, and the same sign-up then takes a free one.
expect
	[
		"Steve",
		"sTeVe",
		"Apoorva",
		"cc",
	].all(|name| account_named(name) == Err(NameTaken))
# A chat with no id left.
expect
	account_made({
		name: "Zoe",
		files: bound_files,
		directory: full_directory,
	})
		== Err(Full)
# An id a human holds now, whichever name is asked for: a second submit of
# one sign-up, or a sign-up from a second tab.
expect
	[
		"Zoe",
		"Steve",
	].all(
		|name|
			account_made({
				name,
				files: [{ user: id_of("2"), file: "300".to_utf8() }],
				directory: tests_directory,
			})
				== Err(AccountExists),
	)
# Two humans holding it.
expect
	account_made({
		name: "Zoe",
		files: [
			{ user: UserId.chat_owner, file: "300".to_utf8() },
			{ user: id_of("2"), file: "300".to_utf8() },
		],
		directory: tests_directory,
	})
		== Err(DuplicateAccount)
# A damaged file, an agent's, and a file of a user no one is hold nothing.
expect
	[
		{ user: UserId.chat_owner, file: "x".to_utf8() },
		{ user: id_of("3"), file: "300".to_utf8() },
		{ user: id_of("9"), file: "300".to_utf8() },
	].all(
		|file|
			account_made({
				name: "Zoe",
				files: [file],
				directory: tests_directory,
			}).map_ok(|made| made.id)
				== Ok("4"),
	)

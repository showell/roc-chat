## Signing in with GitHub is a run of states, each an opaque type this module
## alone makes, and each step a pure function of the state before it and the
## facts the host gave. No step can be skipped: there is no code to exchange
## until the state is checked, and no account until GitHub has said who this
## is.
##
##     GET /login/github    `CameBack`        the state and GitHub's code
##                          `StateChecked`    this browser's, and in time
##     (the host asks)      `IdentityKnown`   GitHub's id and login
##                          `Admission`       the human that id belongs to
##
## Who may sign in is said by `IdentityKnown.admit`: the human whose
## `github-id` file holds the id GitHub answered, and nobody else. An id no
## human holds is refused, and so is one two humans hold, as no one can say
## whose sign-in it is. The login is only what GitHub calls the account now,
## so a rename signs in as before, and a login someone else took signs in no
## one.
##
## An `Admission` is the only way from here to a session
## (`SignInRoute.start_session_by_github!` takes nothing else), so no handler
## mints a session by calling a constructor. This module is a trust boundary
## with `SignedIn`, `AgentKey`, `AgentInvite` and `HumanInvite`. The client
## secret and GitHub's token stay in the host (host/github_client.zig).
import GitHubCode
import GitHubId
import GitHubLogin
import GitHubState
import Html
import Name
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

		## No human holds the id GitHub answered. This is who it called them.
		UnknownAccount(GitHubLogin),

		## More than one human holds the id.
		DuplicateAccount,
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
				Valid => {
					next = came.state.next()
					Ok(GitHubSignIn.StateChecked.({ code: came.code, next }))
				}
			}
	}

	## The state is good, and the code may be exchanged now.
	StateChecked :: { code : GitHubCode, next : Html.SitePath }.{

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
	}.{

		## The admission of the human among `users` whose `github-id` file
		## holds this id. `files` is each human's file as it was read. A file
		## that holds no id, or an agent's, admits no one and fails only
		## itself.
		admit : GitHubSignIn.IdentityKnown,
		{
			files : List({ user : UserId, file : List(U8) }),
			users : Users,
		} -> Try(
			GitHubSignIn.Admission,
			[UnknownAccount(GitHubLogin), DuplicateAccount],
		)
		admit = |GitHubSignIn.IdentityKnown.(known), { files, users }| {
			holders =
				files
					.keep_if(|held| GitHubId.from_file(held.file) == Ok(known.github))
					.keep_oks(|held| users.user(held.user))
					.keep_oks(|user| user.as_human())
			match holders {
				[] => Err(UnknownAccount(known.login))
				[human] => Ok(GitHubSignIn.Admission.({ human, next: known.next }))
				_ => Err(DuplicateAccount)
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
	}
}

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
})

good_code : GitHubCode
good_code = GitHubCode.from_str("good") ?? crash "GitHubSignIn's tests: a code"

tests_name : Str -> Name
tests_name = |text| Name.from_str(text) ?? crash "GitHubSignIn's tests: a name"

## Steve, 1, Apoorva, 2, and Steve's agent CC, 3.
tests_users : Users
tests_users = {
	founded = Users.with_founder(tests_name("Steve"))
	steve = (founded.user(UserId.steve) ?? crash "GitHubSignIn's tests: Steve is 1").as_human()
		?? crash "GitHubSignIn's tests: Steve is a human"
	with_apoorva = (founded.add_human(tests_name("Apoorva")) ?? crash "GitHubSignIn's tests: room").users
	(
		with_apoorva.add_agent({
			name: tests_name("CC"),
			owner: steve,
		}) ?? crash "GitHubSignIn's tests: room"
	).users
}

## The user id `text` spells.
id_of : Str -> UserId
id_of = |text| UserId.from_str(text) ?? crash "GitHubSignIn's tests: an id"

## The `github-id` files of the tests: Steve is 100, Apoorva 200.
bound_files : List({ user : UserId, file : List(U8) })
bound_files = [
	{ user: UserId.steve, file: "100\n".to_utf8() },
	{ user: id_of("2"), file: "200".to_utf8() },
]

## Every step from a return, at `now`, with this `cookie`, GitHub's `heard`
## and these files, as a test reads it: the name of the human admitted and
## where they go, or the refusal.
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
} -> Try((Str, Str), _)
round_trip = |
	{
		state,
		answer,
		cookie,
		now,
		heard,
		files,
	},
| {
	came = GitHubSignIn.CameBack.came_back({ state, answer })?
	checked = came.check({ cookie, now })?
	known = checked.identify(heard)?
	admission = known.admit({ files, users: tests_users })?
	Ok((admission.human().user().name().to_str(), admission.next().to_str()))
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
}

# A good round trip admits the human holding the id, and goes to `next`,
# whatever login GitHub calls them now.
expect round_trip(good_return) == Ok(("Steve", "/agents"))
expect round_trip({ ..good_return, heard: github_answer(100, "renamed") }) == Ok(("Steve", "/agents"))
expect
	round_trip({ ..good_return, heard: github_answer(200, "apoorva") })
		== Ok(("Apoorva", "/agents"))
# An account no human holds is refused, naming it; no file means no account.
expect
	round_trip({ ..good_return, heard: github_answer(300, "stranger") })
		== Err(UnknownAccount(GitHubLogin.from_utf8("stranger".to_utf8()) ?? crash "a login"))
expect
	round_trip({ ..good_return, files: [] })
		== Err(UnknownAccount(GitHubLogin.from_utf8("showell".to_utf8()) ?? crash "a login"))
# The login names no account: a stranger who took `showell` is still a stranger.
expect
	round_trip({ ..good_return, heard: github_answer(300, "showell") })
		== Err(UnknownAccount(GitHubLogin.from_utf8("showell".to_utf8()) ?? crash "a login"))
# A damaged file, an agent's, and a file of a user no one is admit no one.
expect
	[
		{ user: UserId.steve, file: "x".to_utf8() },
		{ user: id_of("3"), file: "100".to_utf8() },
		{ user: id_of("9"), file: "100".to_utf8() },
	].all(
		|file|
			round_trip({ ..good_return, files: [file] })
				== Err(UnknownAccount(GitHubLogin.from_utf8("showell".to_utf8()) ?? crash "a login")),
	)
# A damaged file beside a good one fails only itself.
expect
	round_trip({
		..good_return,
		files: bound_files.append({ user: id_of("3"), file: "x".to_utf8() }),
	}) == Ok(("Steve", "/agents"))
# Two humans holding one id: neither is signed in.
expect
	round_trip({
		..good_return,
		files: [
			{ user: UserId.steve, file: "100".to_utf8() },
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
expect round_trip({ ..good_return, now: 1599 }) == Ok(("Steve", "/agents"))
expect round_trip({ ..good_return, now: 1600 }) == Err(StateExpired)
# What the host heard of GitHub, each way it can go wrong.
expect
	round_trip({ ..good_return, heard: { ..github_answer(0, ""), status: Denied } }) == Err(CodeRefused)
expect
	round_trip({ ..good_return, heard: { ..github_answer(0, ""), status: Failed } })
		== Err(GitHubUnreachable)
expect round_trip({ ..good_return, heard: github_answer(0, "showell") }) == Err(BadIdentity)
expect round_trip({ ..good_return, heard: github_answer(100, "not a login") }) == Err(BadIdentity)

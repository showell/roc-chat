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
##                          `NewHuman`        an id no human holds
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
import Directory
import GitHubCode
import GitHubId
import GitHubLogin
import GitHubSignUp
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

		## More than one human holds the id.
		DuplicateAccount,

		## The sign-up did not come back signed by this server.
		SignUpForged,

		## The sign-up is out of its window (`GitHubSignUp.check`).
		SignUpExpired,

		## The sign-up's id has an account now, which signs in with GitHub.
		AccountExists,
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

		## Whose sign-in this is, among `users`: `Known`, the admission of the
		## human whose `github-id` file holds this id, or `Unknown`, a new
		## human, when none does. `files` is each human's file as it was read.
		## A file that holds no id, or an agent's, admits no one and fails
		## only itself.
		resolve : GitHubSignIn.IdentityKnown,
		{
			files : List({ user : UserId, file : List(U8) }),
			users : Users,
		} -> Try(
			[Known(GitHubSignIn.Admission), Unknown(GitHubSignIn.NewHuman)],
			[DuplicateAccount],
		)
		resolve = |GitHubSignIn.IdentityKnown.(known), { files, users }|
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
		## and the time.
		resume : {
			sign_up : [Signed(GitHubSignUp), Unsigned],
			now : I64,
		} -> Try(
			GitHubSignIn.SignUpResumed,
			[SignUpForged, SignUpExpired],
		)
		resume = |{ sign_up, now }|
			match sign_up {
				Unsigned => Err(SignUpForged)
				Signed(signed) =>
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
		## sign-up good, and the human tries another.
		create_account : GitHubSignIn.SignUpResumed,
		{
			name : Name,
			files : List({ user : UserId, file : List(U8) }),
			directory : Directory,
		} -> Try(
			{
				directory : Directory,
				human : Users.User,
				github : GitHubId,
				admission : GitHubSignIn.Admission,
			},
			[
				AccountExists,
				DuplicateAccount,
				NameTaken,
				Full,
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
					addition = directory.add_human(name)?
					human =
						addition.user.as_human()
							?? crash "GitHubSignIn.create_account: add_human makes a human"
					Ok({
						directory: addition.directory,
						human: addition.user,
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
	}
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
})

good_code : GitHubCode
good_code = GitHubCode.from_str("good") ?? crash "GitHubSignIn's tests: a code"

tests_name : Str -> Name
tests_name = |text| Name.from_str(text) ?? crash "GitHubSignIn's tests: a name"

## Steve, 1, Apoorva, 2, and Steve's agent CC, 3.
tests_directory : Directory
tests_directory = {
	founded = Directory.with_founder(tests_name("Steve"))
	steve = founded.founder().as_human() ?? crash "GitHubSignIn's tests: Steve is a human"
	with_apoorva = (founded.add_human(tests_name("Apoorva")) ?? crash "GitHubSignIn's tests: room").directory
	(
		with_apoorva.add_agent({
			name: tests_name("CC"),
			owner: steve,
		}) ?? crash "GitHubSignIn's tests: room"
	).directory
}

tests_users : Users
tests_users = tests_directory.users()

## The user id `text` spells.
id_of : Str -> UserId
id_of = |text| UserId.from_str(text) ?? crash "GitHubSignIn's tests: an id"

## The `github-id` files of the tests: Steve is 100, Apoorva 200.
bound_files : List({ user : UserId, file : List(U8) })
bound_files = [
	{ user: UserId.steve, file: "100\n".to_utf8() },
	{ user: id_of("2"), file: "200".to_utf8() },
]

## What a return comes to, as a test reads it: the human admitted and where
## they go, or the login of a new human.
Landing : [Admitted(Str, Str), NewHumanNamed(Str)]

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
} -> Try(Landing, _)
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
	match known.resolve({ files, users: tests_users })? {
		Known(admission) =>
			Ok(Admitted(admission.human().user().name().to_str(), admission.next().to_str()))
		Unknown(GitHubSignIn.NewHuman.(new_human)) => Ok(NewHumanNamed(new_human.login.to_str()))
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
		{ user: UserId.steve, file: "x".to_utf8() },
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

## Users until every id is taken, each named by the letters of its number.
full_directory : Directory
full_directory =
	List.from_iter(U64.until(0, 252)).fold(
		tests_directory,
		|directory, at|
			(directory.add_human(tests_name("Filler ${letters_of(at)}"))
				?? crash "GitHubSignIn's tests: room").directory,
	)

## `number` in the letters a name may hold: its decimal digits, each a letter.
letters_of : U64 -> Str
letters_of = |number| {
	spelled = number.to_str().to_utf8().map(|digit| digit - '0' + 'a')
	Str.from_utf8(spelled) ?? crash "GitHubSignIn's tests: letters are UTF-8"
}

## A sign-up of the id 300, as `new_human_called` issues one at 1000.
signed_up : GitHubSignUp
signed_up = new_human_called("Zoe").sign_up(1000)

## The sign-up resumed at 1300.
resumed_up : GitHubSignIn.SignUpResumed
resumed_up =
	GitHubSignIn.SignUpResumed.resume({ sign_up: Signed(signed_up), now: 1300 })
		?? crash "GitHubSignIn's tests: a sign-up in time"

## The id and the path a resumed sign-up holds, as a test reads it.
resumed_text : GitHubSignIn.SignUpResumed -> (Str, Str)
resumed_text = |GitHubSignIn.SignUpResumed.(resumed)| (resumed.github.to_str(), resumed.next.to_str())

# A sign-up keeps the id and where to go.
expect resumed_text(resumed_up) == ("300", "/agents")
# A forged sign-up, and one out of its window at either end; in time at both.
expect
	GitHubSignIn.SignUpResumed.resume({ sign_up: Unsigned, now: 1300 }).map_ok(|_| {})
		== Err(SignUpForged)
expect
	[999, 1600].all(
		|now|
			GitHubSignIn.SignUpResumed.resume({ sign_up: Signed(signed_up), now }).map_ok(|_| {})
				== Err(SignUpExpired),
	)
expect
	[1000, 1599].all(
		|now|
			GitHubSignIn.SignUpResumed.resume({ sign_up: Signed(signed_up), now }).map_ok(|_| {})
				== Ok({}),
	)

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

# A free name makes the next human, admitted, with the id bound and the
# counter past them. Their name need not be their login.
expect
	account_named("Zoë Ann")
		== Ok({
			id: "4",
			name: "Zoë Ann",
			next: "/agents",
			github: "300",
			counter: "5\n".to_utf8(),
		})
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
			{ user: UserId.steve, file: "300".to_utf8() },
			{ user: id_of("2"), file: "300".to_utf8() },
		],
		directory: tests_directory,
	})
		== Err(DuplicateAccount)
# A damaged file, an agent's, and a file of a user no one is hold nothing.
expect
	[
		{ user: UserId.steve, file: "x".to_utf8() },
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

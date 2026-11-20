## These are the tests of `GitHubSignIn`: every step of a return from GitHub,
## a link of GitHub to a human signed in, who may start a link, the name a new
## human is offered, a sign-up resumed, and the account it makes.
import Channels
import Directory
import GitHubCode
import GitHubId
import GitHubSignIn
import GitHubSignUp
import GitHubState
import Html
import Name
import SignedIn
import Timestamp
import UserId
import Users

GitHubSignInSpec :: [].{}

agents_path : Html.SitePath
agents_path = Html.SitePath.from_str("/agents") ?? crash "GitHubSignInSpec: a site path"

nonce_held : List(U8)
nonce_held = List.repeat('n', 32)

## A state issued at 1000.
issued : GitHubState
issued = GitHubState.issue({
	nonce: nonce_held,
	now: Timestamp.at_second(1000),
	next: agents_path,
	errand: SignIn,
})

good_code : GitHubCode
good_code = GitHubCode.from_str("good") ?? crash "GitHubSignInSpec: a code"

tests_name : Str -> Name
tests_name = |text| Name.from_str(text) ?? crash "GitHubSignInSpec: a name"

## Steve, 1, Apoorva, 2, and Steve's agent CC, 3, with no channel.
tests_directory_of_no_channel : Directory
tests_directory_of_no_channel = {
	founded = Directory.with_founder(tests_name("Steve"))
	steve = founded.chat_owner()
	with_apoorva = (founded.add_human(tests_name("Apoorva")) ?? crash "GitHubSignInSpec: room").directory
	(
		with_apoorva.add_agent({
			name: tests_name("CC"),
			owner: steve,
		}) ?? crash "GitHubSignInSpec: room"
	).directory
}

## Those users, with Steve in the default channel.
tests_directory : Directory
tests_directory = {
	channels =
		Channels.from_stored([{ name: Channels.default_name, members: "1\n".to_utf8() }])
			?? crash "GitHubSignInSpec: a members file"
	Directory.from_stored({ users: tests_directory_of_no_channel.users(), channels })
		?? crash "GitHubSignInSpec: Steve is a user"
}

tests_users : Users
tests_users = tests_directory.users()

## The user id `text` spells.
id_of : Str -> UserId
id_of = |text| UserId.from_str(text) ?? crash "GitHubSignInSpec: an id"

## The GitHub id `number`.
github_of : U64 -> GitHubId
github_of = |number| GitHubId.from_u64(number) ?? crash "GitHubSignInSpec: a GitHub id"

## The user `text` spells, linked to the GitHub id `number`.
link_of : Str, U64 -> { user : UserId, github : GitHubId }
link_of = |text, number| { user: id_of(text), github: github_of(number) }

## The GitHub links of the tests: Steve is 100, Apoorva 200.
bound_links : List({ user : UserId, github : GitHubId })
bound_links = [link_of("1", 100), link_of("2", 200)]

## What a return comes to, as a test reads it: the human admitted and where
## they go, the login of a new human, or the human linked and the id.
Landing : [
	Admitted(Str, Str),
	NewHumanNamed(Str),
	LinkedTo(Str, Str),
]

## Every step from a return, at `now`, with this `cookie`, GitHub's `heard`
## and these links, as a test reads it: where it lands, or the refusal.
round_trip : {
	state : [Signed(GitHubState), Unsigned],
	answer : GitHubSignIn.Answer,
	cookie : GitHubState.Cookie,
	now : Timestamp,
	heard : {
		status : [Busy, Denied, Failed, Identified],
		github_id : U64,
		login : List(U8),
	},
	links : List({ user : UserId, github : GitHubId }),
	viewer : SignedIn.Actor,
} -> Try(Landing, _)
round_trip = |
	{
		state,
		answer,
		cookie,
		now,
		heard,
		links,
		viewer,
	},
| {
	came = GitHubSignIn.CameBack.came_back({ state, answer })?
	checked = came.check({ cookie, now })?
	known = checked.identify(heard)?
	match known.resolve({ links, users: tests_users, viewer })? {
		Known(admission) =>
			Ok(Admitted(admission.human().user().name().to_str(), admission.next().to_str()))
		Unknown(new_human) =>
			match new_human.login() {
				Login(login) => Ok(NewHumanNamed(login.to_str()))
				NoLogin => Ok(NewHumanNamed(""))
			}
		Linking(linked) => {
			name = linked.admission().human().user().name().to_str()
			Ok(LinkedTo(name, linked.github().to_str()))
		}
	}
}

## GitHub's answer naming the account `id`, `login`.
github_answer : U64,
Str -> {
	status : [Busy, Denied, Failed, Identified],
	github_id : U64,
	login : List(U8),
}
github_answer = |github_id, login| { status: Identified, github_id, login: login.to_utf8() }

## A return that goes well all the way.
good_return = {
	state: Signed(issued),
	answer: Code(good_code),
	cookie: Sent(nonce_held),
	now: Timestamp.at_second(1300),
	heard: github_answer(100, "showell"),
	links: bound_links,
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
# An account no human holds is a new human; no link means no account.
expect
	round_trip({ ..good_return, heard: github_answer(300, "stranger") })
		== Ok(NewHumanNamed("stranger"))
expect round_trip({ ..good_return, links: [] }) == Ok(NewHumanNamed("showell"))
# The login names no account: a stranger who took `showell` is still a stranger.
expect
	round_trip({ ..good_return, heard: github_answer(300, "showell") })
		== Ok(NewHumanNamed("showell"))
# An agent's link, and one of a user no one is, admit no one.
expect
	[link_of("3", 100), link_of("9", 100)].all(
		|link| round_trip({ ..good_return, links: [link] }) == Ok(NewHumanNamed("showell")),
	)
# Two humans holding one id: neither is signed in.
expect
	round_trip({ ..good_return, links: [link_of("1", 100), link_of("2", 100)] })
		== Err(DuplicateAccount)
# A state not signed by this server is refused, whatever GitHub answered.
expect
	[Code(good_code), NoCode, BadCode].all(
		|answer|
			round_trip({ ..good_return, state: Unsigned, answer }) == Err(StateForged),
	)
# A good state with no code, or a code GitHub wouldn't send.
expect round_trip({ ..good_return, answer: NoCode }) == Err(GitHubDenied)
expect round_trip({ ..good_return, answer: BadCode }) == Err(NotACode)
# Another browser's state, and one out of its window.
expect round_trip({ ..good_return, cookie: Unsent }) == Err(StateMismatched)
expect round_trip({ ..good_return, cookie: Sent(List.repeat('m', 32)) }) == Err(StateMismatched)
expect round_trip({
	..good_return,
	now: Timestamp.at_second(1599),
}) == Ok(Admitted("Steve", "/agents"))
expect round_trip({ ..good_return, now: Timestamp.at_second(1600) }) == Err(StateExpired)
# What the host heard of GitHub, each way it can go wrong.
expect
	round_trip({ ..good_return, heard: { ..github_answer(0, ""), status: Denied } })
		== Err(CodeRefused)
expect
	round_trip({ ..good_return, heard: { ..github_answer(0, ""), status: Failed } })
		== Err(GitHubUnreachable)
expect round_trip({
	..good_return,
	heard: { ..github_answer(0, ""), status: Busy },
}) == Err(GitHubBusy)
expect round_trip({ ..good_return, heard: github_answer(0, "showell") }) == Err(BadIdentity)
# A login that is no login (`GitHubLogin`) still signs in, and a new human
# with one is offered no name.
expect round_trip({
	..good_return,
	heard: github_answer(100, "not a login"),
}) == Ok(Admitted("Steve", "/agents"))
expect round_trip({
	..good_return,
	heard: github_answer(300, "x".repeat(40)),
}) == Ok(NewHumanNamed(""))

## The user `text` names, signed in by a session.
viewer_of : Str -> SignedIn.Actor
viewer_of = |text| {
	user = tests_users.user(id_of(text)) ?? crash "GitHubSignInSpec: a user"
	SignedIn(SignedIn.dangerously_assume(user))
}

## A return that links the id 300 to Apoorva, who holds none, signed in.
good_link = {
	..good_return,
	state: Signed(
		GitHubState.issue({
			nonce: nonce_held,
			now: Timestamp.at_second(1000),
			next: agents_path,
			errand: Link(id_of("2")),
		}),
	),
	heard: github_answer(300, "apoorva-gh"),
	links: [link_of("1", 100)],
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
# A human linked already, to any id, the same id included.
expect
	[100, 300].all(
		|held| round_trip({ ..good_link, links: [link_of("2", held)] }) == Err(AlreadyLinked),
	)
# An id anyone else holds, an agent included.
expect round_trip({ ..good_link, heard: github_answer(100, "someone") }) == Err(GitHubIdTaken)
expect round_trip({ ..good_link, links: [link_of("3", 300)] }) == Err(GitHubIdTaken)
# A human signed in who comes back from a sign-in links: a free id binds to
# them, and goes where the sign-in was going. No account is made.
expect
	round_trip({
		..good_return,
		heard: github_answer(300, "stranger"),
		links: [link_of("1", 100)],
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
		links: [link_of("1", 100)],
		viewer: viewer_of("2"),
	})
		== Err(GitHubIdTaken)
expect
	round_trip({
		..good_return,
		heard: github_answer(300, "stranger"),
		viewer: viewer_of("1"),
	})
		== Err(AlreadyLinked)
# Two humans holding the id, the viewer among them.
expect
	round_trip({
		..good_return,
		links: [link_of("1", 100), link_of("2", 100)],
		viewer: viewer_of("2"),
	})
		== Err(DuplicateAccount)
# An agent is no one to link, and never reaches a new account.
expect
	round_trip({
		..good_return,
		heard: github_answer(300, "stranger"),
		viewer: viewer_of("3"),
	})
		== Err(LinkNotYours)
# A link never skips the state's own checks.
expect round_trip({ ..good_link, state: Unsigned }) == Err(StateForged)
expect round_trip({ ..good_link, cookie: Unsent }) == Err(StateMismatched)
expect round_trip({ ..good_link, now: Timestamp.at_second(1600) }) == Err(StateExpired)

# Who may start a link: a human by session; no one else.
expect GitHubSignIn.human_to_link(Anonymous).map_ok(|_| {}) == Err(NotSignedIn)
expect GitHubSignIn.human_to_link(viewer_of("2")).map_ok(|human| human.id()) == Ok(id_of("2"))
expect GitHubSignIn.human_to_link(viewer_of("3")).map_ok(|_| {}) == Err(Agent(id_of("3")))

## The new human GitHub calls `login`, of the id 300.
new_human_called : Str -> GitHubSignIn.NewHuman
new_human_called = |login|
	new_human_of(login) ?? crash "GitHubSignInSpec: a new human"

## The new human a good return with no links meets, GitHub calling them
## `login`, of the id 300.
new_human_of : Str -> Try(GitHubSignIn.NewHuman, _)
new_human_of = |login| {
	came = GitHubSignIn.CameBack.came_back({ state: Signed(issued), answer: Code(good_code) })?
	checked = came.check({ cookie: Sent(nonce_held), now: Timestamp.at_second(1300) })?
	known = checked.identify(github_answer(300, login))?
	match known.resolve({ links: [], users: tests_users, viewer: Anonymous })? {
		Unknown(new_human) => Ok(new_human)
		Known(_) => Err(NotNew)
		Linking(_) => Err(NotNew)
	}
}

## The tests' directory, its every id spent, as the counter says.
full_directory : Directory
full_directory = {
	accounts = tests_users.to_list().map(Users.account_facts)
	users =
		Users.from_stored({ counter: "65536\n".to_utf8(), accounts })
			?? crash "GitHubSignInSpec: the users' files read back"
	Directory.from_stored({ users, channels: tests_directory.channels() })
		?? crash "GitHubSignInSpec: the names are free"
}

## A sign-up of the id 300, as `new_human_called` issues one at 1000.
signed_up : GitHubSignUp
signed_up = new_human_called("Zoe").sign_up(Timestamp.at_second(1000))

## The sign-up resumed at 1300.
resumed_up : GitHubSignIn.SignUpResumed
resumed_up =
	resumed_at(Timestamp.at_second(1300)) ?? crash "GitHubSignInSpec: a sign-up in time"

## The sign-up resumed at `now` by a browser signed in as no one.
resumed_at : Timestamp -> Try(GitHubSignIn.SignUpResumed, _)
resumed_at = |now|
	GitHubSignIn.SignUpResumed.resume({
		sign_up: Signed(signed_up),
		viewer: Anonymous,
		now,
	})

# A forged sign-up, and one out of its window at either end; in time at both.
expect
	GitHubSignIn.SignUpResumed.resume({
		sign_up: Unsigned,
		viewer: Anonymous,
		now: Timestamp.at_second(1300),
	}).map_ok(|_| {})
		== Err(SignUpForged)
expect [
	999,
	1600,
].map(Timestamp.at_second).all(|now| resumed_at(now).map_ok(|_| {}) == Err(SignUpExpired))
expect [1000, 1599].map(Timestamp.at_second).all(|now| resumed_at(now).map_ok(|_| {}) == Ok({}))
# A browser signed in by then makes no account, whoever it is; a forged
# sign-up says so first.
expect
	["1", "2"].all(
		|id|
			GitHubSignIn.SignUpResumed.resume({
				sign_up: Signed(signed_up),
				viewer: viewer_of(id),
				now: Timestamp.at_second(1300),
			}).map_ok(|_| {})
				== Err(SignedInAlready),
	)
expect
	GitHubSignIn.SignUpResumed.resume({
		sign_up: Unsigned,
		viewer: viewer_of("2"),
		now: Timestamp.at_second(1300),
	}).map_ok(|_| {})
		== Err(SignUpForged)

## What `create_account` makes of `name` with these `links` in `directory`, as
## a test reads it: the new human's id and name, where they go, the bound id,
## and the counter; or the refusal.
account_made : {
	name : Str,
	links : List({ user : UserId, github : GitHubId }),
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
account_made = |{ name, links, directory }| {
	made = resumed_up.create_account({ name: tests_name(name), links, directory })?
	Ok({
		id: made.admission.human().id().to_str(),
		name: made.human.name().to_str(),
		next: made.admission.next().to_str(),
		github: made.github.to_str(),
		counter: made.directory.users().counter_bytes(),
		members: made.channel.members_bytes(),
	})
}

## A sign-up under `name` in the tests' directory, the id 300 free.
account_named : Str -> Try(_, _)
account_named = |name|
	account_made({ name, links: bound_links, directory: tests_directory })

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
		links: bound_links,
		directory: tests_directory_of_no_channel,
	})
		== Err(NoDefaultChannel)
# A name another has, in any case, an agent's included, is refused and makes
# nothing, and the same sign-up then takes a free one.
expect
	["Steve", "sTeVe", "Apoorva", "cc"].all(|name| account_named(name) == Err(NameTaken))
# A chat with no id left.
expect
	account_made({
		name: "Zoe",
		links: bound_links,
		directory: full_directory,
	})
		== Err(Full)
# An id a human holds now, whichever name is asked for: a second submit of
# one sign-up, or a sign-up from a second tab.
expect
	["Zoe", "Steve"].all(
		|name|
			account_made({
				name,
				links: [link_of("2", 300)],
				directory: tests_directory,
			})
				== Err(AccountExists),
	)
# Two humans holding it.
expect
	account_made({
		name: "Zoe",
		links: [link_of("1", 300), link_of("2", 300)],
		directory: tests_directory,
	})
		== Err(DuplicateAccount)
# An agent's link, and one of a user no one is, hold nothing.
expect
	[link_of("3", 300), link_of("9", 300)].all(
		|link|
			account_made({
				name: "Zoe",
				links: [link],
				directory: tests_directory,
			}).map_ok(|made| made.id)
				== Ok("4"),
	)

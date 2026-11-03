## These are the tests of `Users`: humans and agents numbered in one count,
## an agent owned only by a human of the same users, a human told from an
## agent, and an id and a name held to match.
import Sample
import UserId
import Users

UsersSpec :: [].{}

## A user's id, name and role, as a test compares them.
summary : Users.User -> {
	id : Str,
	name : Str,
	role : Str,
}
summary = |u| {
	id: u.id().to_str(),
	name: u.name().to_str(),
	role: role_in_words(u),
}

role_in_words : Users.User -> Str
role_in_words = |u|
	match u.role() {
		Human => "human"
		Agent({ owner }) => "agent of ${owner.to_str()}"
	}

## The id `count` places after Steve's.
after_steve : U64 -> UserId
after_steve = |count| List.repeat({}, count).fold(
	UserId.steve,
	|at, {}| at.next() ?? crash "UsersSpec: a test's id fits",
)

## The sample's first id that belongs to no user.
stranger : UserId
stranger = after_steve(3)

sample : Users
sample = Sample.directory.users()

## Zed is id 1 of other users, so no human of the sample's.
zed : Users.Human
zed = (Users.founded_by(Sample.name("Zed")).user(UserId.steve) ?? crash "UsersSpec: Zed is id 1").as_human() ?? crash "UsersSpec: Zed is a human"

## Who a human named `name` would be, added to `users`, or why not.
human_added : Users,
Str -> Try(
	{
		id : Str,
		name : Str,
		role : Str,
	},
	[Full],
)
human_added = |users, name| users.add_human(Sample.name(name)).map_ok(|grown| summary(grown.user))

## Who an agent named `name` would be, added to `users`, or why not.
agent_added : Users,
{ name : Str, owner : Users.Human } -> Try(
	{
		id : Str,
		name : Str,
		role : Str,
	},
	[NoSuchOwner, Full],
)
agent_added = |users, { name, owner }| users.add_agent({
	name: Sample.name(name),
	owner,
}).map_ok(|grown| summary(grown.user))

# Steve starts every Users, a human, id 1.
expect Users.founded_by(Sample.name("Steve Howell")).to_list().map(summary) == [
	{
		id: "1",
		name: "Steve Howell",
		role: "human",
	},
]
# Each user takes the next id, humans and agents in one count.
expect
	sample.to_list().map(summary)
		== [
			{
				id: "1",
				name: "Steve",
				role: "human",
			},
			{
				id: "2",
				name: "Apoorva",
				role: "human",
			},
			{
				id: "3",
				name: "CC",
				role: "agent of 1",
			},
		]
expect human_added(sample, "Damian") == Ok({
	id: "4",
	name: "Damian",
	role: "human",
})
# An agent's owner: any human of these users, Steve or another.
expect
	[
		(Sample.human("Steve"), "agent of 1"),
		(Sample.human("Apoorva"), "agent of 2"),
	].all(
		|(owner, role)|
			agent_added(sample, { name: "Bot", owner }).map_ok(|user| user.role) == Ok(role),
	)
# A human of other users is no owner here: one whose id is no user's, and
# one whose id is a user's of another name.
expect
	[
		(Sample.crowded(1).users().user(stranger) ?? crash "UsersSpec: the crowded sample has id 4").as_human() ?? crash "UsersSpec: a filler is a human",
		zed,
	].all(|owner| agent_added(sample, { name: "Bot", owner }) == Err(NoSuchOwner))
# The users alone take a name twice: `Directory` keeps names unique.
expect human_added(sample, "Apoorva").map_ok(|user| user.id) == Ok("4")
# A human, or an agent refused as one, by id.
expect
	["Steve", "Apoorva"].all(
		|text| Sample.user(text).as_human().map_ok(|human| human.user().name().to_str()) == Ok(text),
	)
expect Sample.user("CC").as_human() == Err(Agent(after_steve(2)))
expect Sample.human("Apoorva").id() == after_steve(1)
expect Sample.human("Apoorva").author().to_str() == "Apoorva"
expect Sample.human("Apoorva").user() == Sample.user("Apoorva")
# The next id at, under and over the highest: 254 users take one more,
# the 255th, and then none, human or agent. The owner is asked before
# `Full`.
expect {
	almost = Sample.crowded(251).users()
	full = (almost.add_human(Sample.name("Last")) ?? crash "UsersSpec: the 255th user fits").users
	almost.to_list().len() == 254
		and almost.next_id().map_ok(UserId.to_str) == Ok("255")
		and human_added(almost, "Last") == Ok({
			id: "255",
			name: "Last",
			role: "human",
		})
		and agent_added(almost, { name: "Bot", owner: Sample.human("Steve") }) == Ok({
			id: "255",
			name: "Bot",
			role: "agent of 1",
		})
		and full.to_list().len() == 255
		and full.next_id() == Err(Full)
		and human_added(full, "Zoë") == Err(Full)
		and agent_added(full, { name: "Bot", owner: Sample.human("Steve") }) == Err(Full)
		and agent_added(full, { name: "Bot", owner: zed }) == Err(NoSuchOwner)
}
# A user found by id, or none.
expect sample.user(UserId.steve).map_ok(|u| u.name().to_str()) == Ok("Steve")
expect sample.user(after_steve(2)).map_ok(|u| u.name().to_str()) == Ok("CC")
expect sample.user(stranger) == Err(NoSuchUser)
# An id and a name together: theirs exactly, or refused, case included.
expect sample.check({ id: UserId.steve, name: Sample.name("Steve") }) == Ok(Sample.steve)
expect
	[
		Sample.name("steve"),
		Sample.name("Apoorva"),
		Sample.name("Steve Howell"),
	].all(|name| sample.check({ id: UserId.steve, name }) == Err(NameMismatch))
expect sample.check({ id: stranger, name: Sample.name("Steve") }) == Err(NoSuchUser)
# A user as an author, and their files' stem.
expect sample.to_list().map(|u| (u.author().to_str(), u.stem())) == [
	("Steve", "steve-1"),
	("Apoorva", "apoorva-2"),
	("CC", "cc-3"),
]

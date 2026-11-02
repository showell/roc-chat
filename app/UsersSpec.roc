## **USERS' TESTS**: humans and agents numbered in one count, an agent
## owned only by a human of the same users, a human told from an agent,
## and a name and an id held to match.
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
	role: role_of(u),
}

## A user's role, in words.
role_of : Users.User -> Str
role_of = |u|
	match u.role() {
		Human => "human"
		Agent({ owner }) => "agent of ${owner.to_str()}"
	}

## The id `count` after Steve's.
after_steve : U64 -> UserId
after_steve = |count| List.repeat({}, count).fold(
	UserId.steve,
	|at, {}| at.next() ?? crash "UsersSpec: a test's id fits",
)

## The sample's first id that is no user's.
stranger : UserId
stranger = after_steve(3)

## The sample directory's users.
sample : Users
sample = Sample.directory.users()

## **A HUMAN OF OTHER USERS**: Zed, id 1 of their own, so no human of the
## sample's.
zed : Users.Human
zed = (Users.founded_by(Sample.name("Zed")).user(UserId.steve) ?? crash "UsersSpec: Zed is id 1").as_human() ?? crash "UsersSpec: Zed is a human"

## Who `name` would be, joining `users` as `joining`, or why not.
joined : Users,
{ name : Str, joining : Users.Joining } -> Try(
	{
		id : Str,
		name : Str,
		role : Str,
	},
	[NoSuchOwner, Full],
)
joined = |users, { name, joining }| users.add({
	name: Sample.name(name),
	joining,
}).map_ok(|grown| summary(grown.added))

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
expect joined(sample, { name: "Damian", joining: Human }) == Ok({
	id: "4",
	name: "Damian",
	role: "human",
})
# An agent's owner: any human of these users, Steve or another.
expect
	[Sample.human("Steve"), Sample.human("Apoorva")].map(
		|owner| joined(
			sample,
			{
				name: "Bot",
				joining: AgentOf(owner),
			},
		).map_ok(|added| added.role),
	)
		== [Ok("agent of 1"), Ok("agent of 2")]
# A human of other users is no owner here: one whose id is no user's, and
# one whose id is a user's of another name.
expect
	[
		(Sample.crowded(1).users().user(stranger) ?? crash "UsersSpec: the crowded sample has id 4").as_human() ?? crash "UsersSpec: a filler is a human",
		zed,
	].map(
		|owner| joined(
			sample,
			{
				name: "Bot",
				joining: AgentOf(owner),
			},
		),
	)
		== [Err(NoSuchOwner), Err(NoSuchOwner)]
# Names are not this module's: unique names in the namespace are
# `Directory`'s, so the users alone take a name twice.
expect joined(sample, { name: "Apoorva", joining: Human }).map_ok(|added| added.id) == Ok("4")
# A human, or an agent refused as one, by id.
expect
	[
		"Steve",
		"Apoorva",
		"CC",
	].map(|text| Sample.user(text).as_human().map_ok(|human| human.user().name().to_str()))
		== [
			Ok("Steve"),
			Ok("Apoorva"),
			Err(Agent(after_steve(2))),
		]
expect {
	apoorva = Sample.human("Apoorva")
	(
		apoorva.id(),
		apoorva.author().to_str(),
		apoorva.user(),
	) == (
		after_steve(1),
		"Apoorva",
		Sample.user("Apoorva"),
	)
}
# The next id at, under and over the highest: 254 users take one more,
# the 255th, and then none, human or agent. The owner is asked before
# `Full`.
expect {
	almost = Sample.crowded(251).users()
	full = (
		almost.add({
			name: Sample.name("Last"),
			joining: Human,
		}) ?? crash "UsersSpec: the 255th user fits"
	).users
	{
		count: almost.to_list().len(),
		next: almost.next_id().map_ok(UserId.to_str),
		last: joined(almost, { name: "Last", joining: Human }),
		full_count: full.to_list().len(),
		full_next: full.next_id(),
		human: joined(full, { name: "Zoë", joining: Human }),
		agent: joined(full, { name: "Bot", joining: AgentOf(Sample.human("Steve")) }),
		no_owner: joined(full, { name: "Bot", joining: AgentOf(zed) }),
	}
		== {
			count: 254,
			next: Ok("255"),
			last: Ok({
				id: "255",
				name: "Last",
				role: "human",
			}),
			full_count: 255,
			full_next: Err(Full),
			human: Err(Full),
			agent: Err(Full),
			no_owner: Err(NoSuchOwner),
		}
}
# A user found by id, or none.
expect [
	UserId.steve,
	after_steve(2),
].map(|id| sample.user(id).map_ok(|u| u.name().to_str())) == [Ok("Steve"), Ok("CC")]
expect sample.user(stranger) == Err(NoSuchUser)
# A name and an id together: theirs exactly, or refused, case included.
expect sample.check({ id: UserId.steve, name: Sample.name("Steve") }) == Ok(Sample.steve)
expect
	[
		Sample.name("steve"),
		Sample.name("Apoorva"),
		Sample.name("Steve Howell"),
	].map(|name| sample.check({ id: UserId.steve, name }))
		== List.repeat(Err(NameMismatch), 3)
expect sample.check({ id: stranger, name: Sample.name("Steve") }) == Err(NoSuchUser)
# A user as an author, and their files' stem.
expect sample.to_list().map(|u| (u.author().to_str(), u.stem())) == [
	("Steve", "steve-1"),
	("Apoorva", "apoorva-2"),
	("CC", "cc-3"),
]

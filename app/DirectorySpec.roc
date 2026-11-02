## **DIRECTORY'S TESTS**: users numbered and named in one namespace with
## the channels, agents owned only by humans, a name and an id held to
## match, and channels shaped by an admin.
import Admin
import ChannelName
import Directory
import Sample
import UserId

DirectorySpec :: [].{}

## A user's id, name and role, as a test compares them.
summary : Directory.User -> {
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
role_of : Directory.User -> Str
role_of = |u|
	match u.role() {
		Human => "human"
		Agent({ owner }) => "agent of ${owner.to_str()}"
	}

## The id `count` after Steve's.
after_steve : U64 -> UserId
after_steve = |count| List.repeat({}, count).fold(
	UserId.steve,
	|at, {}| at.next() ?? crash "DirectorySpec: a test's id fits",
)

## The sample directory's first id that is no user's.
stranger : UserId
stranger = after_steve(3)

## The channel named `text`, which a test's always is.
channel_name : Str -> ChannelName
channel_name = |text| ChannelName.from_str(text) ?? crash "DirectorySpec: a test's channel name is one"

## Steve, as an admin.
admin : Admin
admin = Admin.of(UserId.steve) ?? crash "DirectorySpec: Steve is an admin"

## The sample directory with an empty channel, `plans`.
with_plans : Directory
with_plans = (
	Sample.directory.create_channel({
		by: admin,
		name: channel_name("plans"),
	}) ?? crash "DirectorySpec: plans is free"
).directory

## Who `text` would be, added as a human to `directory`, or why not.
human_added : Directory,
Str -> Try(
	{
		id : Str,
		name : Str,
		role : Str,
	},
	[Full, NameTaken],
)
human_added = |
	directory,
	text,
| directory.add_human(Sample.name(text)).map_ok(|grown| summary(grown.added))

## Who `text` would be, added to `directory` as an agent of `owner`, or why
## not.
agent_added : Directory,
{ name : Str, owner : UserId } -> Try(
	{
		id : Str,
		name : Str,
		role : Str,
	},
	[
		NoSuchOwner,
		OwnerIsAgent,
		Full,
		NameTaken,
	],
)
agent_added = |directory, { name, owner }| directory.add_agent({
	name: Sample.name(name),
	owner,
}).map_ok(|grown| summary(grown.added))

# Steve starts every directory, a human, id 1.
expect Directory.founded_by(Sample.name("Steve Howell")).users().map(summary) == [
	{
		id: "1",
		name: "Steve Howell",
		role: "human",
	},
]
# Each user takes the next id, humans and agents in one count.
expect
	Sample.directory.users().map(summary)
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
expect human_added(Sample.directory, "Damian") == Ok({
	id: "4",
	name: "Damian",
	role: "human",
})
expect agent_added(Sample.directory, { name: "LC", owner: UserId.steve }) == Ok({
	id: "4",
	name: "LC",
	role: "agent of 1",
})
# A name taken by a human or an agent, in any case, is refused; a name
# that differs by more than case is not.
expect
	[
		"Apoorva",
		"apoorva",
		"APOORVA",
		"CC",
		"cC",
		"sTEVE",
	].map(|text| human_added(Sample.directory, text))
		== List.repeat(Err(NameTaken), 6)
expect
	[
		"Apoorva2",
		"Apoorv",
		"C C",
	].map(|text| human_added(Sample.directory, text).map_ok(|added| added.name))
		== [
			Ok("Apoorva2"),
			Ok("Apoorv"),
			Ok("C C"),
		]
expect agent_added(Sample.directory, { name: "apoorva", owner: UserId.steve }) == Err(NameTaken)
# A channel's name is in the same namespace: a user can't take it, in any
# case, and a channel can't take a user's.
expect
	["plans", "Plans", "PLANS"].map(|text| human_added(with_plans, text))
		== [
			Err(NameTaken),
			Err(NameTaken),
			Err(NameTaken),
		]
expect agent_added(with_plans, { name: "Plans", owner: UserId.steve }) == Err(NameTaken)
expect human_added(with_plans, "plans-2") == Ok({
	id: "4",
	name: "plans-2",
	role: "human",
})
expect
	[
		"Steve",
		"steve",
		"apoorva",
		"cc",
	].map(
		|text| Sample.directory.create_channel({
			by: admin,
			name: channel_name(text),
		}).map_ok(|grown| grown.created.name()),
	)
		== List.repeat(Err(NameTaken), 4)
expect
	["plans", "Plans"].map(
		|text| with_plans.create_channel({
			by: admin,
			name: channel_name(text),
		}).map_ok(|grown| grown.created.name()),
	)
		== [Err(NameTaken), Err(NameTaken)]
expect
	with_plans.create_channel({
		by: admin,
		name: channel_name("general"),
	}).map_ok(|grown| grown.created.name().to_str())
		== Ok("general")
# An agent's owner is a user, and a human, checked before its name.
expect
	agent_added(Sample.directory, { name: "Bot", owner: Sample.user("Apoorva").id() })
		== Ok({
			id: "4",
			name: "Bot",
			role: "agent of 2",
		})
expect agent_added(Sample.directory, { name: "Bot", owner: stranger }) == Err(NoSuchOwner)
expect agent_added(
	Sample.directory,
	{ name: "Bot", owner: Sample.user("CC").id() },
) == Err(OwnerIsAgent)
expect agent_added(
	Sample.directory,
	{ name: "CC", owner: Sample.user("CC").id() },
) == Err(OwnerIsAgent)
expect agent_added(Sample.directory, { name: "CC", owner: stranger }) == Err(NoSuchOwner)
# The last id at, under and over the highest: 254 users take one more,
# the 255th, and then none, human or agent. `Full` is asked before the
# name and after the owner.
## `directory` with `count` more humans, each named for their place.
filled : Directory, U64 -> Directory
filled = |directory, count|
	List.from_iter(U64.until(0, count)).fold(
		directory,
		|so_far, at| (so_far.add_human(Sample.name("filler-${at.to_str()}")) ?? crash "DirectorySpec: a filler's name is free").directory,
	)

expect {
	almost = filled(Sample.directory, 251)
	full = (almost.add_human(Sample.name("Last")) ?? crash "DirectorySpec: the 255th user fits").directory
	{
		count: almost.users().len(),
		last: human_added(almost, "Last"),
		full_count: full.users().len(),
		human: human_added(full, "Zoë"),
		agent: agent_added(full, { name: "Bot", owner: UserId.steve }),
		taken: human_added(full, "Steve"),
		no_owner: agent_added(full, { name: "Bot", owner: Sample.user("CC").id() }),
	}
		== {
			count: 254,
			last: Ok({
				id: "255",
				name: "Last",
				role: "human",
			}),
			full_count: 255,
			human: Err(Full),
			agent: Err(Full),
			taken: Err(Full),
			no_owner: Err(OwnerIsAgent),
		}
}
# A user found by id, or none.
expect [
	UserId.steve,
	after_steve(2),
].map(|id| Sample.directory.user(id).map_ok(summary).map_ok(|s| s.name)) == [Ok("Steve"), Ok("CC")]
expect Sample.directory.user(stranger) == Err(NoSuchUser)
# A name and an id together: theirs exactly, or refused, case included.
expect Sample.directory.check({ id: UserId.steve, name: Sample.name("Steve") }) == Ok(Sample.steve)
expect
	[
		Sample.name("steve"),
		Sample.name("Apoorva"),
		Sample.name("Steve Howell"),
	].map(|name| Sample.directory.check({ id: UserId.steve, name }))
		== List.repeat(Err(NameMismatch), 3)
expect Sample.directory.check({ id: stranger, name: Sample.name("Steve") }) == Err(NoSuchUser)
# A user as an author, and their files' stem.
expect Sample.directory.users().map(|u| (u.author().to_str(), u.stem())) == [
	("Steve", "steve-1"),
	("Apoorva", "apoorva-2"),
	("CC", "cc-3"),
]
# A channel starts empty, and is found by its exact name.
expect
	Sample.directory.create_channel({ by: admin, name: channel_name("plans") }).map_ok(
		|grown| (
			grown.created.name().to_str(),
			grown.created.members(),
		),
	)
		== Ok(("plans", []))
expect with_plans.channel(channel_name("plans")).map_ok(|c| c.name().to_str()) == Ok("plans")
expect with_plans.channel(channel_name("Plans")) == Err(NoSuchChannel)
expect Sample.directory.channel(channel_name("plans")) == Err(NoSuchChannel)
# Admitting: humans and agents, each once; the members in id order.
## `directory`'s `plans` with each of `ids` admitted in turn.
admitted : Directory, List(UserId) -> Directory
admitted = |directory, ids|
	ids.fold(
		directory,
		|so_far, member| so_far.admit({
			by: admin,
			channel: channel_name("plans"),
			member,
		}) ?? crash "DirectorySpec: a test's member is admitted",
	)

## The sample's `plans`, with all three of its users.
everyone : Directory
everyone = admitted(
	with_plans,
	[
		after_steve(2),
		after_steve(1),
		UserId.steve,
	],
)

## The ids of `directory`'s `plans`'s members.
members_of : Directory -> Try(List(Str), [NoSuchChannel])
members_of = |directory| directory.channel(channel_name("plans")).map_ok(|c| c.members().map(UserId.to_str))

expect members_of(everyone) == Ok(["1", "2", "3"])
expect members_of(admitted(with_plans, [after_steve(2)])) == Ok(["3"])
expect
	everyone.channel(channel_name("plans")).map_ok(
		|c| (
			c.has_member(UserId.steve),
			c.has_member(stranger),
		),
	)
		== Ok((Bool.True, Bool.False))
expect
	[
		everyone.admit({
			by: admin,
			channel: channel_name("plans"),
			member: UserId.steve,
		}),
		with_plans.admit({
			by: admin,
			channel: channel_name("general"),
			member: UserId.steve,
		}),
		with_plans.admit({
			by: admin,
			channel: channel_name("plans"),
			member: stranger,
		}),
		with_plans.admit({
			by: admin,
			channel: channel_name("general"),
			member: stranger,
		}),
	].map(|answer| answer.map_ok(members_of))
		== [
			Err(AlreadyMember),
			Err(NoSuchChannel),
			Err(NoSuchUser),
			Err(NoSuchChannel),
		]
# Removing: a member goes, once; the rest stay.
expect
	everyone.remove({
		by: admin,
		channel: channel_name("plans"),
		member: after_steve(1),
	}).map_ok(members_of)
		== Ok(Ok(["1", "3"]))
expect
	[
		with_plans.remove({
			by: admin,
			channel: channel_name("plans"),
			member: UserId.steve,
		}),
		everyone.remove({
			by: admin,
			channel: channel_name("general"),
			member: UserId.steve,
		}),
		everyone.remove({
			by: admin,
			channel: channel_name("plans"),
			member: stranger,
		}),
		everyone.remove({
			by: admin,
			channel: channel_name("general"),
			member: stranger,
		}),
	].map(|answer| answer.map_ok(members_of))
		== [
			Err(NotMember),
			Err(NoSuchChannel),
			Err(NoSuchUser),
			Err(NoSuchChannel),
		]

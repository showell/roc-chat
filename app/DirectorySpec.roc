## **DIRECTORY'S TESTS**: one namespace for humans, agents and channels,
## each name refused when taken in any case by any kind; the order of the
## refusals; and the users and channels it holds, changed through it.
import Admin
import ChannelName
import Directory
import Sample
import UserId
import Users

DirectorySpec :: [].{}

## The channel named `text`, which a test's always is.
channel_name : Str -> ChannelName
channel_name = |text| ChannelName.from_str(text) ?? crash "DirectorySpec: a test's channel name is one"

## Steve, as an admin.
admin : Admin
admin = Sample.admin

## The sample directory with an empty channel, `plans`.
with_plans : Directory
with_plans = (
	Sample.directory.create_channel({
		by: admin,
		name: channel_name("plans"),
	}) ?? crash "DirectorySpec: plans is free"
).directory

## **A HUMAN OF ANOTHER DIRECTORY**: Zed, id 1 of their own.
zed : Users.Human
zed = (Directory.founded_by(Sample.name("Zed")).users().user(UserId.steve) ?? crash "DirectorySpec: Zed is id 1").as_human() ?? crash "DirectorySpec: Zed is a human"

## The id and name of who `text` would be, added as a human to
## `directory`, or why not.
human_added : Directory, Str -> Try((Str, Str), [Full, NameTaken])
human_added = |directory, text|
	directory.add_human(Sample.name(text)).map_ok(
		|grown| (
			grown.added.id().to_str(),
			grown.added.name().to_str(),
		),
	)

## The id and name of who `name` would be, added to `directory` as an
## agent of `owner`, or why not.
agent_added : Directory,
{ name : Str, owner : Users.Human } -> Try(
	(Str, Str),
	[
		NoSuchOwner,
		Full,
		NameTaken,
	],
)
agent_added = |directory, { name, owner }|
	directory.add_agent({ name: Sample.name(name), owner }).map_ok(
		|grown| (
			grown.added.id().to_str(),
			grown.added.name().to_str(),
		),
	)

## The name of the channel `text` would be, created in `directory`, or why
## not.
channel_created : Directory, Str -> Try(Str, [NameTaken])
channel_created = |directory, text|
	directory.create_channel({
		by: admin,
		name: channel_name(text),
	}).map_ok(|grown| grown.created.name().to_str())

# Steve starts every directory, a human, id 1, and no channels; his name
# is taken from the start.
expect {
	founded = Directory.founded_by(Sample.name("Steve Howell"))
	(founded.users().to_list().map(|u| u.name().to_str()), founded.channels().to_list())
		== (["Steve Howell"], [])
}
expect human_added(
	Directory.founded_by(Sample.name("Steve Howell")),
	"steve howell",
) == Err(NameTaken)
# A user joins at the users' next id, a human or an agent.
expect human_added(Sample.directory, "Damian") == Ok(("4", "Damian"))
expect agent_added(
	Sample.directory,
	{ name: "LC", owner: Sample.human("Steve") },
) == Ok(("4", "LC"))
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
	["Apoorvaa", "Apoorv", "C C"].map(|text| human_added(Sample.directory, text))
		== [
			Ok(("4", "Apoorvaa")),
			Ok(("4", "Apoorv")),
			Ok(("4", "C C")),
		]
expect agent_added(
	Sample.directory,
	{ name: "apoorva", owner: Sample.human("Steve") },
) == Err(NameTaken)
# A channel's name is in the same namespace: a user can't take it, in any
# case, and a channel can't take a user's or another channel's.
expect
	["plans", "Plans", "PLANS"].map(|text| human_added(with_plans, text))
		== List.repeat(Err(NameTaken), 3)
expect agent_added(with_plans, { name: "Plans", owner: Sample.human("Steve") }) == Err(NameTaken)
expect human_added(with_plans, "Plansy") == Ok(("4", "Plansy"))
expect
	["Steve", "steve", "apoorva", "cc"].map(|text| channel_created(Sample.directory, text))
		== List.repeat(Err(NameTaken), 4)
expect ["plans", "Plans"].map(|text| channel_created(with_plans, text)) == [
	Err(NameTaken),
	Err(NameTaken),
]
expect channel_created(with_plans, "general") == Ok("general")
# An agent's owner must be one of the directory's humans.
expect agent_added(Sample.directory, { name: "Bot", owner: zed }) == Err(NoSuchOwner)
# The order of refusals, on a directory with no id left: the owner, then
# `Full`, then the name. A name that is taken is not reached.
expect {
	almost = Sample.crowded(251)
	full = (almost.add_human(Sample.name("Last")) ?? crash "DirectorySpec: the 255th user fits").directory
	{
		last: human_added(almost, "Last"),
		human: human_added(full, "Zoë"),
		taken: human_added(full, "Steve"),
		agent: agent_added(full, { name: "Bot", owner: Sample.human("Steve") }),
		agent_taken: agent_added(full, { name: "Steve", owner: Sample.human("Steve") }),
		no_owner: agent_added(full, { name: "Bot", owner: zed }),
		no_owner_taken: agent_added(full, { name: "Steve", owner: zed }),
	}
		== {
			last: Ok(("255", "Last")),
			human: Err(Full),
			taken: Err(Full),
			agent: Err(Full),
			agent_taken: Err(Full),
			no_owner: Err(NoSuchOwner),
			no_owner_taken: Err(NoSuchOwner),
		}
}
# Members change through the directory, as its channels change them.
expect {
	admitted = with_plans.admit({
		by: admin,
		channel: channel_name("plans"),
		member: Sample.user("CC"),
	}) ?? crash "DirectorySpec: CC joins plans"
	removed = admitted.remove({
		by: admin,
		channel: channel_name("plans"),
		member: Sample.user("CC"),
	}) ?? crash "DirectorySpec: CC leaves plans"
	[
		admitted,
		removed,
	].map(|d| d.channels().channel(channel_name("plans")).map_ok(|c| c.members().map(UserId.to_str)))
		== [Ok(["3"]), Ok([])]
}
expect
	(
		with_plans.admit({
			by: admin,
			channel: channel_name("general"),
			member: Sample.steve,
		}),
		with_plans.remove({
			by: admin,
			channel: channel_name("plans"),
			member: Sample.steve,
		}),
	)
		== (Err(NoSuchChannel), Err(NotMember))

## These are the tests of `Directory`: one namespace for humans, agents
## and channels, with each name refused when any kind has taken it in any
## case; the order of the refusals; the users and channels it holds,
## changed through it; and the place a channel's name or a DM's pair
## names.
import Admin
import ChannelName
import Directory
import Place
import Sample
import UserId
import UserPair
import Users

DirectorySpec :: [].{}

## The channel named `text`, which a test's always is.
channel_name : Str -> ChannelName
channel_name = |text| ChannelName.from_str(text) ?? crash "DirectorySpec: a test's channel name is one"

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

## Zed is id 1 of another directory, so no human of the sample's.
zed : Users.Human
zed = (Directory.with_founder(Sample.name("Zed")).users().user(UserId.steve) ?? crash "DirectorySpec: Zed is id 1").as_human() ?? crash "DirectorySpec: Zed is a human"

## The id and name of who `text` would be, added as a human to
## `directory`, or why not.
human_added : Directory, Str -> Try((Str, Str), [Full, NameTaken])
human_added = |directory, text|
	directory.add_human(Sample.name(text)).map_ok(
		|grown| (
			grown.user.id().to_str(),
			grown.user.name().to_str(),
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
			grown.user.id().to_str(),
			grown.user.name().to_str(),
		),
	)

## The name of the channel `text` would be, created in `directory`, or why
## not.
channel_created : Directory, Str -> Try(Str, [NameTaken])
channel_created = |directory, text|
	directory.create_channel({
		by: admin,
		name: channel_name(text),
	}).map_ok(|grown| grown.channel.name().to_str())

# Steve starts every directory, a human, id 1, and no channels; his name
# is taken from the start.
expect {
	founded = Directory.with_founder(Sample.name("Steve Howell"))
	founded.users().to_list().map(|u| u.name().to_str()) == ["Steve Howell"]
		and founded.channels().to_list() == []
}
expect human_added(
	Directory.with_founder(Sample.name("Steve Howell")),
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
	].all(|text| human_added(Sample.directory, text) == Err(NameTaken))
expect human_added(Sample.directory, "Apoorvaa") == Ok(("4", "Apoorvaa"))
expect human_added(Sample.directory, "Apoorv") == Ok(("4", "Apoorv"))
expect human_added(Sample.directory, "C C") == Ok(("4", "C C"))
expect agent_added(
	Sample.directory,
	{ name: "apoorva", owner: Sample.human("Steve") },
) == Err(NameTaken)
# A channel's name is in the same namespace: a user can't take it, in any
# case, and a channel can't take a user's or another channel's.
expect ["plans", "Plans", "PLANS"].all(|text| human_added(with_plans, text) == Err(NameTaken))
expect agent_added(with_plans, { name: "Plans", owner: Sample.human("Steve") }) == Err(NameTaken)
expect human_added(with_plans, "Plansy") == Ok(("4", "Plansy"))
expect
	["Steve", "steve", "apoorva", "cc"].all(
		|text| channel_created(Sample.directory, text) == Err(NameTaken),
	)
expect channel_created(with_plans, "plans") == Err(NameTaken)
expect channel_created(with_plans, "Plans") == Err(NameTaken)
expect channel_created(with_plans, "general") == Ok("general")
# An agent's owner must be one of the directory's humans.
expect agent_added(Sample.directory, { name: "Bot", owner: zed }) == Err(NoSuchOwner)
# The order of refusals, on a directory with no id left: the owner, then
# `Full`, then the name. A name that is taken is not reached.
expect {
	almost = Sample.crowded_directory(251)
	full = (almost.add_human(Sample.name("Last")) ?? crash "DirectorySpec: the 255th user fits").directory
	steve = Sample.human("Steve")
	[
		(human_added(almost, "Last"), Ok(("255", "Last"))),
		(human_added(full, "Zoë"), Err(Full)),
		(human_added(full, "Steve"), Err(Full)),
		(agent_added(full, { name: "Bot", owner: steve }), Err(Full)),
		(agent_added(full, { name: "Steve", owner: steve }), Err(Full)),
		(agent_added(full, { name: "Bot", owner: zed }), Err(NoSuchOwner)),
		(agent_added(full, { name: "Steve", owner: zed }), Err(NoSuchOwner)),
	].all(|(answer, expected)| answer == expected)
}
# Members change through the directory, as its channels change them.
expect {
	admitted = with_plans.add_member({
		by: admin,
		channel: channel_name("plans"),
		member: Sample.user("CC"),
	}) ?? crash "DirectorySpec: CC joins plans"
	removed = admitted.remove_member({
		by: admin,
		channel: channel_name("plans"),
		member: Sample.user("CC"),
	}) ?? crash "DirectorySpec: CC leaves plans"
	plans_members = |d| d.channels().channel(channel_name("plans")).map_ok(|c| c.members().map(UserId.to_str))
	plans_members(admitted) == Ok(["3"]) and plans_members(removed) == Ok([])
}
expect
	with_plans.add_member({
		by: admin,
		channel: channel_name("general"),
		member: Sample.steve,
	})
		== Err(NoSuchChannel)
expect
	with_plans.remove_member({
		by: admin,
		channel: channel_name("plans"),
		member: Sample.steve,
	})
		== Err(NotMember)
expect
	with_plans.remove_member({
		by: admin,
		channel: channel_name("general"),
		member: Sample.steve,
	})
		== Err(NoSuchChannel)
expect {
	admitted = with_plans.add_member({
		by: admin,
		channel: channel_name("plans"),
		member: Sample.steve,
	}) ?? crash "DirectorySpec: Steve joins plans"
	admitted.add_member({
		by: admin,
		channel: channel_name("plans"),
		member: Sample.steve,
	})
		== Err(AlreadyMember)
}

## The place `named` names in `with_plans`, as its folder's name, or why
## there is none.
place_named : [Channel(ChannelName), Dm(UserPair)] -> Try(Str, [NoSuchChannel, NoSuchHuman])
place_named = |named| with_plans.place(named).map_ok(Place.to_str)

## The pair `low` and `high` spell, which a test's always do.
pair : Str -> UserPair
pair = |text| UserPair.from_str(text) ?? crash "DirectorySpec: a test's pair is one"

# A place: a channel it holds, and a DM of two humans or one human's own;
# no such channel, and a DM with an agent (CC, 3) or nobody (4) in it.
expect place_named(Channel(channel_name("plans"))) == Ok("plans")
expect place_named(Channel(channel_name("other"))) == Err(NoSuchChannel)
expect place_named(Dm(pair("1_2"))) == Ok("1_2")
expect place_named(Dm(pair("2_2"))) == Ok("2_2")
expect
	[
		"1_3",
		"3_3",
		"1_4",
		"4_4",
	].all(|text| place_named(Dm(pair(text))) == Err(NoSuchHuman))

## Apoorva renamed `text` in `directory`: her id and her name after, and
## then whether her old name, `Apoorva`, is free to a new human; or why not.
apoorva_renamed : Directory, Str -> Try((Str, Str, Str), [NameTaken, NoSuchHuman])
apoorva_renamed = |directory, text| {
	done = directory.rename_human({ human: Sample.human("Apoorva"), name: Sample.name(text) })?
	freed =
		match human_added(done.directory, "Apoorva") {
			Ok(_) => "Apoorva free"
			Err(_) => "Apoorva taken"
		}
	Ok((done.human.id().to_str(), done.human.user().name().to_str(), freed))
}

# A human renamed keeps their id, and the name they leave is free again; a
# new name another user or a channel has, in any case, is refused; their
# own name in another case is theirs to take, and so it stays taken.
expect apoorva_renamed(Sample.directory, "Debbie") == Ok(("2", "Debbie", "Apoorva free"))
expect apoorva_renamed(Sample.directory, "APOORVA") == Ok(("2", "APOORVA", "Apoorva taken"))
expect apoorva_renamed(Sample.directory, "Apoorva") == Ok(("2", "Apoorva", "Apoorva taken"))
expect ["Steve", "steve", "cc"].all(|text| apoorva_renamed(Sample.directory, text) == Err(NameTaken))
expect ["plans", "PLANS"].all(|text| apoorva_renamed(with_plans, text) == Err(NameTaken))
expect {
	done = Sample.directory.rename_human({ human: Sample.human("Apoorva"), name: Sample.name("Debbie") }) ?? crash "DirectorySpec: Debbie is free"
	human_added(done.directory, "debbie") == Err(NameTaken)
		and done.directory.users().user_by_name(Sample.name("Debbie")).map_ok(|u| u.id().to_str()) == Ok("2")
		and done.directory.users().user_by_name(Sample.name("Apoorva")).map_ok(|_| {}) == Err(NoSuchUser)
}
# A human of another directory is none of this one's.
expect Sample.directory.rename_human({ human: zed, name: Sample.name("Debbie") }).map_ok(|_| {}) == Err(NoSuchHuman)

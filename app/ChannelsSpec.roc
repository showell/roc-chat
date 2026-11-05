## These are the tests of `Channels`: a channel starts empty, is found by
## its exact name, and gains and loses members, humans and agents, each
## once, by an admin.
import Admin
import ChannelName
import Channels
import Sample
import UserId
import Users

ChannelsSpec :: [].{}

## The channel named `text`, which a test's always is.
channel_name : Str -> ChannelName
channel_name = |text|
	ChannelName.from_str(text) ?? crash "ChannelsSpec: a test's channel name is one"

admin : Admin
admin = Sample.admin

## An empty channel, `plans`, alone.
with_plans : Channels
with_plans = Channels.empty.create({ by: admin, name: channel_name("plans") }).channels

## The default channel, holding Steve, and `plans`.
with_default : Channels
with_default =
	Channels.from_files([
		{ name: Channels.default_name, members: "1\n".to_utf8() },
		{ name: channel_name("plans"), members: "1\n".to_utf8() },
	]) ?? crash "ChannelsSpec: the members files read"

# The default channel is the one the chat starts with.
expect Channels.default_name.to_str() == "general"
# A new human joins it, with no admin, and no other channel.
expect {
	joined =
		with_default.add_new_human(Sample.human("Apoorva")) ?? crash "ChannelsSpec: it is there"
	plans = joined.channels.channel(channel_name("plans")) ?? crash "ChannelsSpec: plans is there"
	joined.channel.name() == Channels.default_name
		and joined.channel.members_file() == "1\n2\n".to_utf8()
		and plans.members_file() == "1\n".to_utf8()
}
# With no default channel there is nowhere to join.
expect with_plans.add_new_human(Sample.human("Apoorva")).map_ok(|_| {}) == Err(NoDefaultChannel)

## `channels` with `change` made to `plans` by the admin.
apply_change : Channels,
[Add(Users.User), Remove(Users.User)] -> Try(
	Channels,
	[
		NoSuchChannel,
		AlreadyMember,
		NotMember,
	],
)
apply_change = |channels, change|
	match change {
		Add(member) => channels.add_member({
			by: admin,
			channel: channel_name("plans"),
			member,
		})
		Remove(member) => channels.remove_member({
			by: admin,
			channel: channel_name("plans"),
			member,
		})
	}

## `channels` with each change made in turn, which a test's always can be.
all_changed : Channels, List([Add(Users.User), Remove(Users.User)]) -> Channels
all_changed = |channels, changes|
	changes.fold(
		channels,
		|
			so_far,
			change,
		| apply_change(so_far, change) ?? crash "ChannelsSpec: a test's change is made",
	)

## `plans` with all three of the sample's users.
everyone : Channels
everyone = all_changed(
	with_plans,
	[
		Add(Sample.user("CC")),
		Add(Sample.user("Apoorva")),
		Add(Sample.steve),
	],
)

## The ids of `plans`'s members.
members_of : Channels -> Try(List(Str), [NoSuchChannel])
members_of = |channels|
	channels.channel(channel_name("plans")).map_ok(|c| c.members().map(UserId.to_str))

# A channel starts empty, and is found by its exact name.
expect {
	channel = Channels.empty.create({ by: admin, name: channel_name("plans") }).channel
	channel.name().to_str() == "plans" and channel.members() == []
}
expect with_plans.channel(channel_name("plans")).map_ok(|c| c.name().to_str()) == Ok("plans")
expect with_plans.channel(channel_name("Plans")) == Err(NoSuchChannel)
expect Channels.empty.channel(channel_name("plans")) == Err(NoSuchChannel)
expect Channels.empty.to_list() == []
expect with_plans.to_list().map(|c| c.name().to_str()) == ["plans"]
# Adding: humans and agents, each once; the members in id order.
expect members_of(everyone) == Ok(["1", "2", "3"])
expect members_of(all_changed(with_plans, [Add(Sample.user("CC"))])) == Ok(["3"])
expect
	everyone.channel(channel_name("plans")).map_ok(|c| c.has_member(Sample.steve)) == Ok(Bool.True)
expect
	everyone.channel(channel_name("plans")).map_ok(|c| c.has_member(Sample.user("CC")))
		== Ok(Bool.True)
expect
	with_plans.channel(channel_name("plans")).map_ok(|c| c.has_member(Sample.steve))
		== Ok(Bool.False)
expect apply_change(everyone, Add(Sample.steve)).map_ok(members_of) == Err(AlreadyMember)
expect
	with_plans.add_member({
		by: admin,
		channel: channel_name("general"),
		member: Sample.steve,
	}).map_ok(members_of)
		== Err(NoSuchChannel)
expect
	everyone.add_member({
		by: admin,
		channel: channel_name("general"),
		member: Sample.steve,
	}).map_ok(members_of)
		== Err(NoSuchChannel)
# Removing: a member goes, once; the rest stay.
expect apply_change(
	everyone,
	Remove(Sample.user("Apoorva")),
).map_ok(members_of) == Ok(Ok(["1", "3"]))
expect apply_change(with_plans, Remove(Sample.steve)).map_ok(members_of) == Err(NotMember)
expect
	everyone.remove_member({
		by: admin,
		channel: channel_name("general"),
		member: Sample.steve,
	}).map_ok(members_of)
		== Err(NoSuchChannel)
expect
	with_plans.remove_member({
		by: admin,
		channel: channel_name("general"),
		member: Sample.steve,
	}).map_ok(members_of)
		== Err(NoSuchChannel)
# A member removed can be added again, and removed again.
expect
	members_of(
		all_changed(
			everyone,
			[
				Remove(Sample.user("Apoorva")),
				Add(Sample.user("Apoorva")),
			],
		),
	)
		== Ok(["1", "2", "3"])
expect
	members_of(
		all_changed(
			everyone,
			[
				Remove(Sample.user("Apoorva")),
				Add(Sample.user("Apoorva")),
				Remove(Sample.user("Apoorva")),
			],
		),
	)
		== Ok(["1", "3"])
# A change to one channel leaves the others as they were.
expect {
	both = Channels.empty.create({ by: admin, name: channel_name("plans") }).channels.create({
		by: admin,
		name: channel_name("general"),
	}).channels
	grown = apply_change(both, Add(Sample.steve)) ?? crash "ChannelsSpec: Steve joins plans"
	members_of(grown) == Ok(["1"])
		and grown.channel(channel_name("general")).map_ok(|c| c.members()) == Ok([])
		and grown.to_list().map(|c| c.name().to_str()) == ["plans", "general"]
}
# The members are in the ids' numeric order, not their text's: 9 before 10.
expect {
	users = Sample.crowded_directory(7).users()
	user_at = |text|
		users.user(UserId.from_str(text) ?? crash "ChannelsSpec: a test's id is an id")
			?? crash "ChannelsSpec: the crowded sample has ten users"
	members_of(
		all_changed(
			with_plans,
			[
				Add(user_at("10")),
				Add(user_at("9")),
				Add(user_at("1")),
			],
		),
	)
		== Ok(["1", "9", "10"])
}

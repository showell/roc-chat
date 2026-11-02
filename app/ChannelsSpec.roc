## **CHANNELS' TESTS**: a channel starts empty, is found by its exact
## name, and takes and loses members, humans and agents, each once, by an
## admin.
import Admin
import ChannelName
import Channels
import Sample
import UserId
import Users

ChannelsSpec :: [].{}

## The channel named `text`, which a test's always is.
channel_name : Str -> ChannelName
channel_name = |text| ChannelName.from_str(text) ?? crash "ChannelsSpec: a test's channel name is one"

## Steve, as an admin.
admin : Admin
admin = Sample.admin

## An empty channel, `plans`, alone.
with_plans : Channels
with_plans = Channels.empty.create({ by: admin, name: channel_name("plans") }).channels

## `channels` with `change` made to `plans` by the admin.
changed : Channels,
[Admit(Users.User), Remove(Users.User)] -> Try(
	Channels,
	[
		NoSuchChannel,
		AlreadyMember,
		NotMember,
	],
)
changed = |channels, change|
	match change {
		Admit(member) => channels.admit({
			by: admin,
			channel: channel_name("plans"),
			member,
		})
		Remove(member) => channels.remove({
			by: admin,
			channel: channel_name("plans"),
			member,
		})
	}

## `channels` with each change made in turn, which a test's always can be.
all_changed : Channels, List([Admit(Users.User), Remove(Users.User)]) -> Channels
all_changed = |channels, changes|
	changes.fold(
		channels,
		|so_far, change| changed(so_far, change) ?? crash "ChannelsSpec: a test's change is made",
	)

## `plans` with all three of the sample's users.
everyone : Channels
everyone = all_changed(
	with_plans,
	[
		Admit(Sample.user("CC")),
		Admit(Sample.user("Apoorva")),
		Admit(Sample.steve),
	],
)

## The ids of `plans`'s members.
members_of : Channels -> Try(List(Str), [NoSuchChannel])
members_of = |channels| channels.channel(channel_name("plans")).map_ok(|c| c.members().map(UserId.to_str))

# A channel starts empty, and is found by its exact name.
expect {
	created = Channels.empty.create({ by: admin, name: channel_name("plans") }).created
	(created.name().to_str(), created.members()) == ("plans", [])
}
expect with_plans.channel(channel_name("plans")).map_ok(|c| c.name().to_str()) == Ok("plans")
expect with_plans.channel(channel_name("Plans")) == Err(NoSuchChannel)
expect Channels.empty.channel(channel_name("plans")) == Err(NoSuchChannel)
expect Channels.empty.to_list() == []
expect with_plans.to_list().map(|c| c.name().to_str()) == ["plans"]
# Admitting: humans and agents, each once; the members in id order.
expect members_of(everyone) == Ok(["1", "2", "3"])
expect members_of(all_changed(with_plans, [Admit(Sample.user("CC"))])) == Ok(["3"])
expect
	everyone.channel(channel_name("plans")).map_ok(
		|c| (
			c.has_member(Sample.steve),
			c.has_member(Sample.user("CC")),
		),
	)
		== Ok((Bool.True, Bool.True))
expect
	with_plans.channel(channel_name("plans")).map_ok(|c| c.has_member(Sample.steve))
		== Ok(Bool.False)
expect
	[
		changed(everyone, Admit(Sample.steve)),
		with_plans.admit({
			by: admin,
			channel: channel_name("general"),
			member: Sample.steve,
		}),
		everyone.admit({
			by: admin,
			channel: channel_name("general"),
			member: Sample.steve,
		}),
	].map(|answer| answer.map_ok(members_of))
		== [
			Err(AlreadyMember),
			Err(NoSuchChannel),
			Err(NoSuchChannel),
		]
# Removing: a member goes, once; the rest stay.
expect changed(everyone, Remove(Sample.user("Apoorva"))).map_ok(members_of) == Ok(Ok(["1", "3"]))
expect
	[
		changed(with_plans, Remove(Sample.steve)),
		everyone.remove({
			by: admin,
			channel: channel_name("general"),
			member: Sample.steve,
		}),
		with_plans.remove({
			by: admin,
			channel: channel_name("general"),
			member: Sample.steve,
		}),
	].map(|answer| answer.map_ok(members_of))
		== [
			Err(NotMember),
			Err(NoSuchChannel),
			Err(NoSuchChannel),
		]
# A member removed can be admitted again, and removed again.
expect
	[
		all_changed(everyone, [Remove(Sample.user("Apoorva")), Admit(Sample.user("Apoorva"))]),
		all_changed(
			everyone,
			[
				Remove(Sample.user("Apoorva")),
				Admit(Sample.user("Apoorva")),
				Remove(Sample.user("Apoorva")),
			],
		),
	].map(members_of)
		== [Ok(["1", "2", "3"]), Ok(["1", "3"])]

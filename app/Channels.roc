## This module holds the chat's channels. A channel has a name and a set of
## members, who may be humans or agents. Only an admin may create a channel
## or change its members, so each of those functions asks for an `Admin`,
## which only `Admin.of` makes.
##
## Channel names are not checked for clashes here. `Directory` holds the
## channels with the users, and keeps every name unique across both.
import Admin
import ChannelName
import UserId
import Users

Channels :: List(Channels.Channel).{

	## A channel: its name and its members' ids.
	Channel :: {
		name : ChannelName,
		members : Set(UserId),
	}.{

		name : Channels.Channel -> ChannelName
		name = |Channels.Channel.(c)| c.name

		## The members' ids, lowest first.
		members : Channels.Channel -> List(UserId)
		members = |Channels.Channel.(c)| c.members.to_list().sort_with(UserId.compare)

		has_member : Channels.Channel, Users.User -> Bool
		has_member = |Channels.Channel.(c), user| c.members.contains(user.id())

		is_eq : _
	}

	## An admin's change to one channel's members: the admin, the channel,
	## and the user who joins or leaves it.
	MemberChange : {
		by : Admin,
		channel : ChannelName,
		member : Users.User,
	}

	## The channels after a channel was created, and the channel.
	Created : { channels : Channels, channel : Channels.Channel }

	empty : Channels
	empty = Channels.([])

	## The channels with an empty channel named `name` added, and that
	## channel.
	create : Channels, { by : Admin, name : ChannelName } -> Channels.Created
	create = |Channels.(all), { by: _, name }| {
		channel = Channels.Channel.({ name, members: Set.empty() })
		{ channels: Channels.(all.append(channel)), channel }
	}

	## The channel named exactly `name`, if there is one.
	channel : Channels, ChannelName -> Try(Channels.Channel, [NoSuchChannel])
	channel = |Channels.(all), name|
		match all.find_first(|candidate| candidate.name() == name) {
			Ok(found) => Ok(found)
			Err(NotFound) => Err(NoSuchChannel)
		}

	## The channels with the change's member added to its channel. The
	## channel must exist (`NoSuchChannel`), and then the user must not be
	## a member already (`AlreadyMember`).
	add_member : Channels, Channels.MemberChange -> Try(Channels, [NoSuchChannel, AlreadyMember])
	add_member = |channels, change| {
		Channels.Channel.(c) = channels.channel(change.channel)?
		member = change.member.id()
		if (c.members.contains(member))
			Err(AlreadyMember)
		else
			Ok(
				with_channel(
					channels,
					Channels.Channel.({ ..c, members: c.members.insert(member) }),
				),
			)
	}

	## The channels with the change's member removed from its channel. The
	## channel must exist (`NoSuchChannel`), and then the user must be a
	## member (`NotMember`).
	remove_member : Channels, Channels.MemberChange -> Try(Channels, [NoSuchChannel, NotMember])
	remove_member = |channels, change| {
		Channels.Channel.(c) = channels.channel(change.channel)?
		member = change.member.id()
		if (c.members.contains(member))
			Ok(
				with_channel(
					channels,
					Channels.Channel.({ ..c, members: c.members.remove(member) }),
				),
			)
		else
			Err(NotMember)
	}

	## Every channel, in the order they were created.
	to_list : Channels -> List(Channels.Channel)
	to_list = |Channels.(all)| all

	is_eq : _
}

## The channels with `changed` in place of the channel of the same name.
with_channel : Channels, Channels.Channel -> Channels
with_channel = |Channels.(all), changed| {
	name = changed.name()
	Channels.(all.map(|c| if (c.name() == name) changed else c))
}

## **THE CHANNELS**: each named set of members, humans and agents. Opaque,
## so it changes only by its own functions, and each asks for an `Admin`,
## the proof `Admin.of` alone makes: only an admin creates a channel and
## chooses its members. A channel's name unique in the namespace it shares
## with the users is `Directory`'s, which holds the chat's channels.
##
## **TELL, DON'T ASK**: `add_member` and `remove_member` take the `User` itself, which
## the caller already holds, never an id to look up.
import Admin
import ChannelName
import UserId
import Users

Channels :: List(Channels.Channel).{

	## **A CHANNEL**: its name and its members, humans and agents. A view
	## only this module makes.
	Channel :: {
		name : ChannelName,
		members : Set(UserId),
	}.{

		## Its name.
		name : Channels.Channel -> ChannelName
		name = |Channels.Channel.(c)| c.name

		## Its members' ids, lowest first.
		members : Channels.Channel -> List(UserId)
		members = |Channels.Channel.(c)| c.members.to_list().sort_with(UserId.compare)

		## Is `user` one of its members?
		has_member : Channels.Channel, Users.User -> Bool
		has_member = |Channels.Channel.(c), user| c.members.contains(user.id())

		is_eq : _
	}

	## **A CHANGE TO A CHANNEL'S MEMBERS**, by an admin: who joins or
	## leaves which channel.
	Membership : {
		by : Admin,
		channel : ChannelName,
		member : Users.User,
	}

	## **A CHANNEL CREATED**: the channels that hold it, and the channel.
	Created : { channels : Channels, channel : Channels.Channel }

	## No channels.
	empty : Channels
	empty = Channels.([])

	## The channels with an empty channel named `name`, created by an
	## admin, and that channel.
	create : Channels, { by : Admin, name : ChannelName } -> Channels.Created
	create = |Channels.(all), { by: _, name }| {
		channel = Channels.Channel.({ name, members: Set.empty() })
		{ channels: Channels.(all.append(channel)), channel }
	}

	## The channel named `name`, exactly, unless there is none.
	channel : Channels, ChannelName -> Try(Channels.Channel, [NoSuchChannel])
	channel = |Channels.(all), name|
		match all.find_first(|candidate| candidate.name() == name) {
			Ok(found) => Ok(found)
			Err(NotFound) => Err(NoSuchChannel)
		}

	## The channels with `member` admitted to `channel` by an admin;
	## unless, in this order, there is no such channel, or they are
	## already a member.
	add_member : Channels, Channels.Membership -> Try(Channels, [NoSuchChannel, AlreadyMember])
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

	## The channels with `member` removed from `channel` by an admin;
	## unless, in this order, there is no such channel, or they are not a
	## member.
	remove_member : Channels, Channels.Membership -> Try(Channels, [NoSuchChannel, NotMember])
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

## `channels` with `changed` in place of its channel of that name, which
## it holds: `add_member` and `remove_member` found it there.
with_channel : Channels, Channels.Channel -> Channels
with_channel = |Channels.(all), changed| {
	name = changed.name()
	Channels.(all.map(|c| if (c.name() == name) changed else c))
}

## This module holds the chat's channels. A channel has a name and a set of
## members, who may be humans or agents. Only an admin may create a channel
## or change its members, so each of those functions asks for an `Admin`,
## which only `Admin.of` makes.
##
## Channel names are not checked for clashes here. `Directory` holds the
## channels with the users, and keeps every name unique across both.
##
## A channel's members are kept (`FileSystem`) in a file per channel, `chat/channel/<name>.channel`, beside the channel's
## folder of topics, holding one member's id a line. The admin changes the
## members on a channel's page (`ChannelMembersRoute`), or by editing the
## file. `members_file` writes it, and `from_files` reads
## it back: each line's spaces off, a blank line or one
## starting `#` skipped, and any other line exactly an id, once.
import Admin
import Ascii
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

		## The channel's members file: each member's id and a line end,
		## lowest first.
		members_file : Channels.Channel -> List(U8)
		members_file = |channel| channel.members().join_map(|id| "${id.to_str()}\n".to_utf8())

		is_eq : _
	}

	## A channel's members file as it was read, with the name its file is
	## named by.
	StoredChannel : { name : ChannelName, members : List(U8) }

	## The channels the members files hold, in the order given. Refused
	## when a line is no id, or an id twice (`BadMembers`, naming the
	## channel).
	from_files : List(Channels.StoredChannel) -> Try(Channels, [BadMembers(ChannelName)])
	from_files = |stored|
		stored.map_try(
			|{ name, members }| {
				ids = members_from_file(members) ? |_| BadMembers(name)
				Ok(Channels.Channel.({ name, members: Set.from_list(ids) }))
			},
		).map_ok(|all| Channels.(all))

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

## The members a members file names, one id a line, each once.
members_from_file : List(U8) -> Try(List(UserId), [NotAMembersFile])
members_from_file = |bytes| {
	lines = bytes.split_on('\n').map(Ascii.trim_spaces).drop_if(|line| line.is_empty() or line.starts_with(['#']))
	ids = lines.map_try(
		|line|
			match Str.from_utf8(line) {
				Ok(text) => UserId.from_str(text).map_err(|NotAUserId| NotAMembersFile)
				Err(_) => Err(NotAMembersFile)
			},
	)?
	if (Set.from_list(ids).len() == ids.len()) Ok(ids) else Err(NotAMembersFile)
}

## The channels with `changed` in place of the channel of the same name.
with_channel : Channels, Channels.Channel -> Channels
with_channel = |Channels.(all), changed| {
	name = changed.name()
	Channels.(all.map(|c| if (c.name() == name) changed else c))
}

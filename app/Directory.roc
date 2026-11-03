## This module holds the chat's users and channels together, because they
## share one namespace: no human, agent or channel may take a name that
## another already has, in any case. Each way in refuses such a name with
## `NameTaken`, so a directory holding two names that differ only in case
## can't be built.
##
## The directory checks names and nothing else. What each kind keeps besides
## its name (ids and owners, members) is checked by `Users` and `Channels`.
import Admin
import ChannelName
import Channels
import Name
import Users

Directory :: {
	users : Users,
	channels : Channels,
	keys : Set(Name.Key),
}.{

	## The directory after a user joined it, and the user.
	Joined : { directory : Directory, user : Users.User }

	## The directory after a channel was created in it, and the channel.
	Created : { directory : Directory, channel : Channels.Channel }

	## A new directory, holding no channels and one user: Steve, id 1, as a
	## human named `name`.
	founded_by : Name -> Directory
	founded_by = |name|
		Directory.(
			{
				users: Users.founded_by(name),
				channels: Channels.empty,
				keys: Set.empty().insert(name.key()),
			},
		)

	## The directory with a human named `name` added, and that human. The
	## users are asked first, so a full directory answers `Full` even when
	## the name is also taken.
	add_human : Directory, Name -> Try(Directory.Joined, [Full, NameTaken])
	add_human = |directory, name| {
		grown = directory.users().add_human(name)?
		joined(directory, grown)
	}

	## The directory with an agent named `name`, owned by `owner`, added,
	## and that agent. The users are asked first (`NoSuchOwner`, then
	## `Full`), and then the name.
	add_agent : Directory,
	{ name : Name, owner : Users.Human } -> Try(
		Directory.Joined,
		[
			NoSuchOwner,
			Full,
			NameTaken,
		],
	)
	add_agent = |directory, { name, owner }| {
		grown = directory.users().add_agent({ name, owner })?
		joined(directory, grown)
	}

	## The directory with an empty channel named `name`, created by an
	## admin, and that channel.
	create_channel : Directory,
	{
		by : Admin,
		name : ChannelName,
	} -> Try(Directory.Created, [NameTaken])
	create_channel = |Directory.(d), { by, name }| {
		keys = claimed(d.keys, name.key())?
		grown = d.channels.create({ by, name })
		Ok({
			directory: Directory.(
				{
					..d,
					channels: grown.channels,
					keys,
				},
			),
			channel: grown.channel,
		})
	}

	## The directory with a member added to a channel, as
	## `Channels.add_member` adds them.
	add_member : Directory, Channels.MemberChange -> Try(Directory, [NoSuchChannel, AlreadyMember])
	add_member = |Directory.(d), change| {
		channels = d.channels.add_member(change)?
		Ok(Directory.({ ..d, channels }))
	}

	## The directory with a member removed from a channel, as
	## `Channels.remove_member` removes them.
	remove_member : Directory, Channels.MemberChange -> Try(Directory, [NoSuchChannel, NotMember])
	remove_member = |Directory.(d), change| {
		channels = d.channels.remove_member(change)?
		Ok(Directory.({ ..d, channels }))
	}

	users : Directory -> Users
	users = |Directory.(d)| d.users

	channels : Directory -> Channels
	channels = |Directory.(d)| d.channels

	is_eq : _
}

## The directory holding `grown`'s users, and the user who joined them;
## unless that user's name is already taken.
joined : Directory, Users.Joined -> Try(Directory.Joined, [NameTaken])
joined = |Directory.(d), grown| {
	keys = claimed(d.keys, grown.user.name().key())?
	Ok({
		directory: Directory.(
			{
				..d,
				users: grown.users,
				keys,
			},
		),
		user: grown.user,
	})
}

## The taken names' keys with `key` added; unless it is already there.
claimed : Set(Name.Key), Name.Key -> Try(Set(Name.Key), [NameTaken])
claimed = |keys, key| if (keys.contains(key)) Err(NameTaken) else Ok(keys.insert(key))

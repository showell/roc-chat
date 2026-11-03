## This module holds the chat's users and channels together, because they
## share one namespace: no human, agent or channel may take a name that
## another already has, in any case. Each way in refuses such a name with
## `NameTaken`, so a directory holding two names that differ only in case
## can't be built.
##
## The directory checks names and nothing else. What each kind keeps besides
## its name (ids and owners, members) is checked by `Users` and `Channels`.
## It also finds the place a channel's name or a DM's pair names (`place`),
## since only the directory knows which channels and humans exist.
import Admin
import ChannelName
import Channels
import Dm
import Name
import Place
import UserPair
import Users

Directory :: {
	users : Users,
	channels : Channels,
	keys : Set(Name.Key),
}.{

	## What adding a user gives: the directory that holds them, and the user.
	Addition : { directory : Directory, user : Users.User }

	## The directory after a channel was created in it, and the channel.
	Created : { directory : Directory, channel : Channels.Channel }

	## The chat's directory at the start, when the only user is the founder:
	## the first human, id 1, named `name`. It holds no channels.
	with_founder : Name -> Directory
	with_founder = |name|
		Directory.(
			{
				users: Users.with_founder(name),
				channels: Channels.empty,
				keys: Set.empty().insert(name.key()),
			},
		)

	## The directory with a human named `name` added, and that human. The
	## users are asked first, so a full directory answers `Full` even when
	## the name is also taken.
	add_human : Directory, Name -> Try(Directory.Addition, [Full, NameTaken])
	add_human = |directory, name| {
		grown = directory.users().add_human(name)?
		admit_new_user(directory, grown)
	}

	## The directory with an agent named `name`, owned by `owner`, added,
	## and that agent. The users are asked first (`NoSuchOwner`, then
	## `Full`), and then the name.
	add_agent : Directory,
	{ name : Name, owner : Users.Human } -> Try(
		Directory.Addition,
		[
			NoSuchOwner,
			Full,
			NameTaken,
		],
	)
	add_agent = |directory, { name, owner }| {
		grown = directory.users().add_agent({ name, owner })?
		admit_new_user(directory, grown)
	}

	## The directory with an empty channel named `name`, created by an
	## admin, and that channel.
	create_channel : Directory,
	{
		by : Admin,
		name : ChannelName,
	} -> Try(Directory.Created, [NameTaken])
	create_channel = |Directory.(d), { by, name }| {
		keys = claim_key(d.keys, name.key())?
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

	## The place a channel's name or a DM's pair names, if the directory
	## holds it: a channel it holds (else `NoSuchChannel`), or a DM whose
	## every member is a human it holds (else `NoSuchHuman`), since an agent
	## can't be in a DM.
	place : Directory, [Channel(ChannelName), Dm(UserPair)] -> Try(Place, [NoSuchChannel, NoSuchHuman])
	place = |Directory.(d), named|
		match named {
			Channel(name) => {
				channel = d.channels.channel(name)?
				Ok(Place.channel(channel))
			}
			Dm(pair) => {
				humans = pair.members().map_try(
					|id|
						match d.users.user(id) {
							Ok(user) => user.as_human().map_err(|_| NoSuchHuman)
							Err(NoSuchUser) => Err(NoSuchHuman)
						},
				)?
				match humans {
					[alone] => Ok(Place.dm(Dm.between({ a: alone, b: alone })))
					[a, b] => Ok(Place.dm(Dm.between({ a, b })))
					_ => crash "Directory.place: a pair has one member or two"
				}
			}
		}

	users : Directory -> Users
	users = |Directory.(d)| d.users

	channels : Directory -> Channels
	channels = |Directory.(d)| d.channels

	is_eq : _
}

## The directory holding `grown`'s users, and the user who joined them;
## unless that user's name is already taken.
admit_new_user : Directory, Users.Addition -> Try(Directory.Addition, [NameTaken])
admit_new_user = |Directory.(d), grown| {
	keys = claim_key(d.keys, grown.user.name().key())?
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
claim_key : Set(Name.Key), Name.Key -> Try(Set(Name.Key), [NameTaken])
claim_key = |keys, key| if (keys.contains(key)) Err(NameTaken) else Ok(keys.insert(key))

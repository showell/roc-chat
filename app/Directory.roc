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
import UserId
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

	## What making a new human's account gives: the directory that holds them,
	## the human, and the default channel, which they are in.
	NewHuman : {
		directory : Directory,
		user : Users.User,
		channel : Channels.Channel,
	}

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

	## The directory with a new human's account, named `name`: `add_human`, and
	## them in the default channel (`Channels.add_new_human`), so the chat has
	## a page for them. This is how a sign-up or an invite makes a human.
	add_new_human : Directory, Name -> Try(Directory.NewHuman, [Full, NameTaken, NoDefaultChannel])
	add_new_human = |directory, name| {
		addition = directory.add_human(name)?
		human =
			addition.user.as_human() ?? crash "Directory.add_new_human: add_human makes a human"
		Directory.(d) = addition.directory
		joined = d.channels.add_new_human(human)?
		Ok({
			directory: Directory.({ ..d, channels: joined.channels }),
			user: addition.user,
			channel: joined.channel,
		})
	}

	## The directory with an agent named `name`, owned by `owner`, added,
	## and that agent. The users are asked first (`NoSuchOwner`, then
	## `Full`), and then the name.
	add_agent : Directory,
	{ name : Name, owner : Users.Human } -> Try(
		Directory.Addition,
		[NoSuchOwner, Full, NameTaken],
	)
	add_agent = |directory, { name, owner }| {
		grown = directory.users().add_agent({ name, owner })?
		admit_new_user(directory, grown)
	}

	## The directory with the human `human` named `name` instead, and that
	## human as renamed; unless another user or a channel has the name, in
	## any case (`NameTaken`), or `human` is not among its users
	## (`NoSuchHuman`). The human's own name is theirs, so they may keep it
	## in another case, and the name they leave is free again.
	rename_human : Directory,
	{ human : Users.Human, name : Name } -> Try(
		{ directory : Directory, human : Users.Human },
		[NameTaken, NoSuchHuman],
	)
	rename_human = |Directory.(d), { human, name }| {
		renamed = d.users.rename_human({ human, name })?
		keys = claim_key(d.keys.remove(human.user().name().key()), name.key())?
		Ok({ directory: Directory.({ ..d, users: renamed.users, keys }), human: renamed.human })
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
			directory: Directory.({ ..d, channels: grown.channels, keys }),
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
	place : Directory,
	[Channel(ChannelName), Dm(UserPair)] -> Try(
		Place,
		[NoSuchChannel, NoSuchHuman],
	)
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

	## The directory of `users` and `channels`, as their files hold them;
	## unless two of their names are the same name (`NameTaken`), or a
	## channel has a member no user is (`UnknownMember`, naming it).
	from_files : { users : Users, channels : Channels } -> Try(
		Directory,
		[NameTaken, UnknownMember(ChannelName)],
	)
	from_files = |{ users, channels }| {
		all_keys =
			users.to_list()
				.map(|user| user.name().key())
				.concat(channels.to_list().map(|channel| channel.name().key()))
		keys = Set.from_list(all_keys)
		if keys.len() != all_keys.len() {
			Err(NameTaken)
		} else {
			match channels.to_list().find_first(
				|channel| !channel.members().all(|id| is_user(users, id)),
			) {
				Ok(stray) => Err(UnknownMember(stray.name()))
				Err(NotFound) => Ok(Directory.({ users, channels, keys }))
			}
		}
	}

	## The chat's owner: the first human, id 1, and its admin. This is the one
	## way to find them, so their name is read, never written in.
	chat_owner : Directory -> Users.Human
	chat_owner = |Directory.(d)| {
		found =
			d.users.user(UserId.chat_owner)
				?? crash "Directory.chat_owner: every directory holds its owner, id 1"
		found.as_human() ?? crash "Directory.chat_owner: id 1 is a human"
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
	Ok({ directory: Directory.({ ..d, users: grown.users, keys }), user: grown.user })
}

## Whether `users` holds the user `id`.
is_user : Users, UserId -> Bool
is_user = |users, id|
	match users.user(id) {
		Ok(_) => Bool.True
		Err(NoSuchUser) => Bool.False
	}

## The taken names' keys with `key` added; unless it is already there.
claim_key : Set(Name.Key), Name.Key -> Try(Set(Name.Key), [NameTaken])
claim_key = |keys, key| if keys.contains(key) {
	Err(NameTaken)
} else {
	Ok(keys.insert(key))
}

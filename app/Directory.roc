## **THE DIRECTORY**: the one namespace that humans, agents and channels
## share, holding the chat's `Users` and `Channels`. It is the one place a
## name's key (`Name.key`, `ChannelName.key`) is written and checked
## across kinds: each way in refuses a name already taken, in any case, by
## a human, an agent or a channel. Opaque, so it grows only by its own
## functions, and a directory with two names alike but for case can't be
## built. What each kind keeps besides (ids and owners, members) is its
## own module's.
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

	## **A USER JOINED**: the directory they joined, and the user.
	Joined : { directory : Directory, added : Users.User }

	## **A CHANNEL CREATED**: the directory that holds it, and the channel.
	Created : { directory : Directory, created : Channels.Channel }

	## **A DIRECTORY'S START: STEVE, ALWAYS ID 1**, named `name`, a human,
	## and no channels.
	founded_by : Name -> Directory
	founded_by = |name|
		Directory.(
			{
				users: Users.founded_by(name),
				channels: Channels.empty,
				keys: Set.empty().insert(name.key()),
			},
		)

	## The directory with the human named `name` added, at the next id, and
	## that user; unless every id is taken (`Full`, asked first), or the
	## name is, in any case (`NameTaken`).
	add_human : Directory, Name -> Try(Directory.Joined, [Full, NameTaken])
	add_human = |directory, name|
		added({
			directory,
			name,
			joining: Human,
		}).map_err(
			|why|
				match why {
					NoSuchOwner => crash "Directory.add_human: a human has no owner to miss"
					Full => Full
					NameTaken => NameTaken
				},
		)

	## The directory with the agent named `name`, owned by `owner`, added at
	## the next id, and that user; unless, in this order, the owner is not
	## one of its users (`NoSuchOwner`), every id is taken (`Full`), or the
	## name is, in any case (`NameTaken`).
	add_agent : Directory,
	{ name : Name, owner : Users.Human } -> Try(
		Directory.Joined,
		[
			NoSuchOwner,
			Full,
			NameTaken,
		],
	)
	add_agent = |directory, { name, owner }| added({
		directory,
		name,
		joining: AgentOf(owner),
	})

	## The directory with an empty channel named `name`, and that channel,
	## created by an admin; unless the name is taken, in any case, by a
	## user or a channel.
	create_channel : Directory,
	{
		by : Admin,
		name : ChannelName,
	} -> Try(Directory.Created, [NameTaken])
	create_channel = |Directory.(d), { by, name }| {
		key = name.key()
		if (d.keys.contains(key))
			Err(NameTaken)
		else {
			grown = d.channels.create({ by, name })
			Ok({
				directory: Directory.(
					{
						..d,
						channels: grown.channels,
						keys: d.keys.insert(key),
					},
				),
				created: grown.created,
			})
		}
	}

	## The directory with a member admitted to a channel by an admin, as
	## `Channels.admit` admits them, or its refusal.
	admit : Directory, Channels.Membership -> Try(Directory, [NoSuchChannel, AlreadyMember])
	admit = |Directory.(d), change| {
		channels = d.channels.admit(change)?
		Ok(Directory.({ ..d, channels }))
	}

	## The directory with a member removed from a channel by an admin, as
	## `Channels.remove` removes them, or its refusal.
	remove : Directory, Channels.Membership -> Try(Directory, [NoSuchChannel, NotMember])
	remove = |Directory.(d), change| {
		channels = d.channels.remove(change)?
		Ok(Directory.({ ..d, channels }))
	}

	## Its users.
	users : Directory -> Users
	users = |Directory.(d)| d.users

	## Its channels.
	channels : Directory -> Channels
	channels = |Directory.(d)| d.channels

	is_eq : _
}

## **THE ONE WAY A USER JOINS**: `directory` with the user named `name`
## added as `joining`, and that user; unless the users refuse them
## (`NoSuchOwner`, `Full`), or the name is taken, in any case
## (`NameTaken`). The users are asked first, so `Full` comes before the
## name.
added : {
	directory : Directory,
	name : Name,
	joining : Users.Joining,
} -> Try(Directory.Joined, [NoSuchOwner, Full, NameTaken])
added = |
	{
		directory: Directory.(d),
		name,
		joining,
	},
| {
	grown = d.users.add({ name, joining })?
	key = name.key()
	if (d.keys.contains(key))
		Err(NameTaken)
	else
		Ok({
			directory: Directory.(
				{
					..d,
					users: grown.users,
					keys: d.keys.insert(key),
				},
			),
			added: grown.added,
		})
}

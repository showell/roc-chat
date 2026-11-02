## **THE DIRECTORY**: every user and every channel, in one namespace, the
## one home of who and what exists. Opaque, so it grows only by its own
## functions: `founded_by` starts it with Steve, id 1; `add_human` and
## `add_agent` number each user by the next id; `create_channel` names a
## channel; and each refuses a name already taken, in any case, by a human,
## an agent or a channel (`Name.key`). So a directory with two users of one
## id, two names alike but for case, or an agent whose owner is not one of
## its humans, can't be built.
##
## **WHAT IT HANDS OUT IS UNFORGEABLE**: a `User` and a `Channel` are views
## only this module makes, so holding one is proof a directory made it.
## Names, ids and roles are permanent, so a user's view never goes stale.
## What comes in from outside is an id, or an id with a name, which `check`
## holds to match.
##
## **ONLY AN ADMIN SHAPES A CHANNEL**: creating one, and admitting or
## removing a member, each asks for an `Admin`, the proof `Admin.of` alone
## makes.
import Admin
import Author
import ChannelName
import Name
import UserId
import UserStem

Directory :: {
	users : List(Directory.User),
	channels : List(Directory.Channel),
	keys : Set(Name.Key),
}.{

	## **A USER**: a human or an agent whose identity the edge has checked,
	## as this directory numbered and named them.
	User :: {
		id : UserId,
		name : Name,
		role : Directory.Role,
	}.{

		## Its id.
		id : Directory.User -> UserId
		id = |Directory.User.(u)| u.id

		## Its permanent name.
		name : Directory.User -> Name
		name = |Directory.User.(u)| u.name

		## A human, or an agent and its owner.
		role : Directory.User -> Directory.Role
		role = |Directory.User.(u)| u.role

		## The user in the role of writing, as a message records them.
		author : Directory.User -> Author
		author = |Directory.User.(u)| Author.of(u.name)

		## Its files' stem (`UserStem`).
		stem : Directory.User -> Str
		stem = |Directory.User.(u)| UserStem.of({ name: u.name, id: u.id })

		is_eq : _
	}

	## **A HUMAN, OR AN AGENT AND ITS OWNER**: every agent has exactly one
	## owner, always a human in the same directory.
	Role : [Human, Agent({ owner : UserId })]

	## **A CHANNEL**: its name and its members, humans and agents.
	Channel :: {
		name : ChannelName,
		members : Set(UserId),
	}.{

		## Its name.
		name : Directory.Channel -> ChannelName
		name = |Directory.Channel.(c)| c.name

		## Its members' ids, lowest first.
		members : Directory.Channel -> List(UserId)
		members = |Directory.Channel.(c)| c.members.to_list().sort_with(UserId.compare)

		## Is `id` one of its members?
		has_member : Directory.Channel, UserId -> Bool
		has_member = |Directory.Channel.(c), id| c.members.contains(id)

		is_eq : _
	}

	## **A USER JOINED**: the directory they joined, and the user.
	Joined : { directory : Directory, added : Directory.User }

	## **A CHANNEL CREATED**: the directory that holds it, and the channel.
	Created : { directory : Directory, created : Directory.Channel }

	## **A NAME AND AN ID, TOGETHER**, as a URL, a file's stem or a
	## session gives them: `check` holds them to match.
	Identity : { id : UserId, name : Name }

	## **A CHANGE TO A CHANNEL'S MEMBERS**, by an admin: who joins or
	## leaves which channel.
	Membership : {
		by : Admin,
		channel : ChannelName,
		member : UserId,
	}

	## **A DIRECTORY'S START: STEVE, ALWAYS ID 1**, named `name`, a human,
	## and no channels.
	founded_by : Name -> Directory
	founded_by = |name|
		Directory.(
			{
				users: [
					Directory.User.(
						{
							id: UserId.steve,
							name,
							role: Human,
						},
					),
				],
				channels: [],
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
			role: Human,
		})

	## The directory with the agent named `name`, owned by `owner`, added at
	## the next id, and that user; unless, in this order, the owner is no
	## user (`NoSuchOwner`) or is an agent (`OwnerIsAgent`), or the agent
	## can't be added as a human can't (`Full`, `NameTaken`).
	add_agent : Directory, { name : Name, owner : UserId } -> Try(Directory.Joined, _)
	add_agent = |directory, { name, owner }| {
		found = directory.user(owner) ? |NoSuchUser| NoSuchOwner
		match found.role() {
			Agent(_) => Err(OwnerIsAgent)
			Human =>
				added({
					directory,
					name,
					role: Agent({ owner: owner }),
				}).map_err(
					|why|
						match why {
							Full => Full
							NameTaken => NameTaken
						},
				)
		}
	}

	## The user `id`, unless there is none.
	user : Directory, UserId -> Try(Directory.User, [NoSuchUser])
	user = |Directory.(d), id|
		match d.users.find_first(|Directory.User.(u)| u.id == id) {
			Ok(found) => Ok(found)
			Err(NotFound) => Err(NoSuchUser)
		}

	## **WHERE A NAME AND AN ID COME TOGETHER, THEY MATCH**: the user `id`,
	## if `name` is theirs exactly (names are case-sensitive); unless there
	## is no such user, or the name is another's spelling.
	check : Directory, Directory.Identity -> Try(Directory.User, [NoSuchUser, NameMismatch])
	check = |directory, { id, name }| {
		found = directory.user(id)?
		if (found.name() == name) Ok(found) else Err(NameMismatch)
	}

	## Every user, in id order.
	users : Directory -> List(Directory.User)
	users = |Directory.(d)| d.users

	## The directory with an empty channel named `name`, and that channel,
	## created by an admin; unless the name is taken, in any case, by a
	## user or a channel.
	create_channel : Directory, { by : Admin, name : ChannelName } -> Try(Directory.Created, [NameTaken])
	create_channel = |Directory.(d), { by: _, name }| {
		key = name.name().key()
		if (d.keys.contains(key))
			Err(NameTaken)
		else {
			created = Directory.Channel.({ name, members: Set.empty() })
			Ok({
				directory: Directory.(
					{
						..d,
						channels: d.channels.append(created),
						keys: d.keys.insert(key),
					},
				),
				created,
			})
		}
	}

	## The channel named `name`, exactly, unless there is none.
	channel : Directory, ChannelName -> Try(Directory.Channel, [NoSuchChannel])
	channel = |Directory.(d), name|
		match d.channels.find_first(|Directory.Channel.(c)| c.name == name) {
			Ok(found) => Ok(found)
			Err(NotFound) => Err(NoSuchChannel)
		}

	## The directory with the user `member` admitted to `channel` by an
	## admin; unless, in this order, there is no such channel, no such
	## user, or they are already a member.
	admit : Directory, Directory.Membership -> Try(Directory, _)
	admit = |directory, change| {
		Directory.Channel.(c) = directory.channel(change.channel)?
		member = directory.user(change.member)?.id()
		if (c.members.contains(member))
			Err(AlreadyMember)
		else
			Ok(
				with_channel(
					directory,
					Directory.Channel.({ ..c, members: c.members.insert(member) }),
				),
			)
	}

	## The directory with the user `member` removed from `channel` by an
	## admin; unless, in this order, there is no such channel, no such
	## user, or they are not a member.
	remove : Directory, Directory.Membership -> Try(Directory, _)
	remove = |directory, change| {
		Directory.Channel.(c) = directory.channel(change.channel)?
		member = directory.user(change.member)?.id()
		if (c.members.contains(member))
			Ok(
				with_channel(
					directory,
					Directory.Channel.({ ..c, members: c.members.remove(member) }),
				),
			)
		else
			Err(NotMember)
	}

	is_eq : _
}

## `directory` with `changed` in place of its channel of that name, which
## it holds: `admit` and `remove` found it there.
with_channel : Directory, Directory.Channel -> Directory
with_channel = |Directory.(d), changed| {
	name = changed.name()
	Directory.({ ..d, channels: d.channels.map(|c| if (c.name() == name) changed else c) })
}

## **THE ONE WAY A USER JOINS**: `directory` with the user named `name`,
## in `role`, at the next id, and that user; unless every id is taken
## (`Full`), or the name is, in any case (`NameTaken`).
added : {
	directory : Directory,
	name : Name,
	role : Directory.Role,
} -> Try(Directory.Joined, [Full, NameTaken])
added = |
	{
		directory: Directory.(d),
		name,
		role,
	},
| {
	latest = d.users.last() ?? crash "Directory.added: Steve, its first user, is in every directory"
	id = latest.id().next()?
	key = name.key()
	if (d.keys.contains(key))
		Err(NameTaken)
	else {
		user = Directory.User.(
			{
				id,
				name,
				role,
			},
		)
		Ok({
			directory: Directory.(
				{
					..d,
					users: d.users.append(user),
					keys: d.keys.insert(key),
				},
			),
			added: user,
		})
	}
}

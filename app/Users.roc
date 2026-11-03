## This module holds every user of the chat, human or agent, and gives each
## one an id. Ids count up from Steve's, 1, in one count shared by humans
## and agents. An agent always has an owner, and the owner is always a human
## among the same users.
##
## The users can only grow through `add_human` and `add_agent`, so two
## users with one id, or an agent owned by a stranger, can't be built. The
## `User` and `Human` values handed out are made only here. Holding a `User`
## proves that this module made it, but not who is acting; that proof is a
## `SignedIn`.
##
## Names are not checked for clashes here. `Directory` holds the users with
## the channels, and keeps every name unique across both.
import Author
import Name
import UserId
import UserStem

Users :: List(Users.User).{

	## A human or an agent, with the id and name these users gave them.
	User :: {
		id : UserId,
		name : Name,
		role : Users.Role,
	}.{

		id : Users.User -> UserId
		id = |Users.User.(u)| u.id

		name : Users.User -> Name
		name = |Users.User.(u)| u.name

		role : Users.User -> Users.Role
		role = |Users.User.(u)| u.role

		## The user as the author of a message.
		author : Users.User -> Author
		author = |Users.User.(u)| Author.of(u.name)

		## The stem of the user's file names, such as `apoorva-2`.
		stem : Users.User -> Str
		stem = |Users.User.(u)| UserStem.of({ name: u.name, id: u.id })

		## The user as a human; an agent is refused, by its id.
		as_human : Users.User -> Try(Users.Human, [Agent(UserId)])
		as_human = |user|
			match user.role() {
				Human => Ok(Users.Human.(user))
				Agent(_) => Err(Agent(user.id()))
			}

		is_eq : _
	}

	## A user who is known not to be an agent. Only `User.as_human` makes
	## one, so a function that only a human may use, such as owning an
	## agent or joining a DM, asks for a `Human` in its type.
	Human :: Users.User.{

		user : Users.Human -> Users.User
		user = |Users.Human.(known)| known

		id : Users.Human -> UserId
		id = |Users.Human.(known)| known.id()

		## The human as the author of a message.
		author : Users.Human -> Author
		author = |Users.Human.(known)| known.author()

		is_eq : _
	}

	## A user is a human, or an agent with the id of its human owner.
	Role : [Human, Agent({ owner : UserId })]

	## The users after someone joined, and the user who joined.
	Joined : { users : Users, user : Users.User }

	## An id and a name that arrived together, as a URL, a file's name or a
	## session gives them. `check` holds them to match.
	Identity : { id : UserId, name : Name }

	## New users, holding only Steve, id 1, as a human named `name`.
	founded_by : Name -> Users
	founded_by = |name|
		Users.(
			[
				Users.User.(
					{
						id: UserId.steve,
						name,
						role: Human,
					},
				),
			],
		)

	## The id the next user will get: the one after the latest user's,
	## unless every id is taken.
	next_id : Users -> Try(UserId, [Full])
	next_id = |Users.(all)| {
		latest = all.last() ?? crash "Users.next_id: Steve, the first user, is in every Users"
		latest.id().next()
	}

	## The users with a human named `name` added at the next id, and that
	## human; unless every id is taken.
	add_human : Users, Name -> Try(Users.Joined, [Full])
	add_human = |users, name| added(users, { name, role: Human })

	## The users with an agent named `name`, owned by `owner`, added at the
	## next id, and that agent. The owner is checked first: they must be a
	## human of these users, with the same id and name (`NoSuchOwner`).
	## Then the agent needs a free id (`Full`).
	add_agent : Users, { name : Name, owner : Users.Human } -> Try(Users.Joined, [NoSuchOwner, Full])
	add_agent = |users, { name, owner }|
		if (users.user(owner.id()) == Ok(owner.user()))
			added(users, { name, role: Agent({ owner: owner.id() }) })
		else
			Err(NoSuchOwner)

	## The user with the id `id`, if there is one.
	user : Users, UserId -> Try(Users.User, [NoSuchUser])
	user = |Users.(all), id|
		match all.find_first(|candidate| candidate.id() == id) {
			Ok(found) => Ok(found)
			Err(NotFound) => Err(NoSuchUser)
		}

	## The user with the identity's id, if the identity's name is exactly
	## theirs. Names are case-sensitive, so `steve` is not `Steve`.
	check : Users, Users.Identity -> Try(Users.User, [NoSuchUser, NameMismatch])
	check = |users, { id, name }| {
		found = users.user(id)?
		if (found.name() == name) Ok(found) else Err(NameMismatch)
	}

	## Every user, in id order.
	to_list : Users -> List(Users.User)
	to_list = |Users.(all)| all

	is_eq : _
}

## The users with a user named `name` added in the role `role`, at the next
## id, and that user; unless every id is taken.
added : Users, { name : Name, role : Users.Role } -> Try(Users.Joined, [Full])
added = |users, { name, role }| {
	id = users.next_id()?
	user = Users.User.(
		{
			id,
			name,
			role,
		},
	)
	Users.(all) = users
	Ok({ users: Users.(all.append(user)), user })
}

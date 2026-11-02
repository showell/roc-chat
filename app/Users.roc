## **THE USERS**: every human and agent, numbered in one count, the one
## home of ids and of who owns which agent. Opaque, so it grows only by
## `add`: `founded_by` starts it with Steve, id 1, and `add` numbers each
## user by `next_id` and gives an agent only a human of these users as its
## owner. So two users of one id, or an agent whose owner is not one of
## its humans, can't be built. Names unique in the namespace the users
## share with the channels are `Directory`'s, which holds the chat's users.
##
## **WHAT IT HANDS OUT IS UNFORGEABLE**: a `User` and a `Human` are views
## only this module makes. Holding a `User` proves only that a `Users`
## made it, never who is acting: that is `SignedIn`'s. Names, ids and
## roles are permanent, so a view never goes stale. What comes in from
## outside is an id, or an id with a name, which `check` holds to match.
import Author
import Name
import UserId
import UserStem

Users :: List(Users.User).{

	## **A USER**: a human or an agent, as a `Users` numbered and named
	## them. It proves only that a `Users` made it.
	User :: {
		id : UserId,
		name : Name,
		role : Users.Role,
	}.{

		## Its id.
		id : Users.User -> UserId
		id = |Users.User.(u)| u.id

		## Its permanent name.
		name : Users.User -> Name
		name = |Users.User.(u)| u.name

		## A human, or an agent and its owner.
		role : Users.User -> Users.Role
		role = |Users.User.(u)| u.role

		## The user in the role of writing, as a message records them.
		author : Users.User -> Author
		author = |Users.User.(u)| Author.of(u.name)

		## Its files' stem (`UserStem`).
		stem : Users.User -> Str
		stem = |Users.User.(u)| UserStem.of({ name: u.name, id: u.id })

		## The user as a human; unless they are an agent (`Agent`, naming
		## them).
		as_human : Users.User -> Try(Users.Human, [Agent(UserId)])
		as_human = |user|
			match user.role() {
				Human => Ok(Users.Human.(user))
				Agent(_) => Err(Agent(user.id()))
			}

		is_eq : _
	}

	## **A HUMAN**: a user known to be no agent. Opaque, so
	## `User.as_human` is the only way in, and what only a human may be (a
	## DM's member, an agent's owner) asks for one in its type.
	Human :: Users.User.{

		## The user.
		user : Users.Human -> Users.User
		user = |Users.Human.(known)| known

		## Its id.
		id : Users.Human -> UserId
		id = |Users.Human.(known)| known.id()

		## The human in the role of writing.
		author : Users.Human -> Author
		author = |Users.Human.(known)| known.author()

		is_eq : _
	}

	## **A HUMAN, OR AN AGENT AND ITS OWNER**: every agent has exactly one
	## owner, always a human of the same users.
	Role : [Human, Agent({ owner : UserId })]

	## **WHO JOINS**: a human, or an agent of a human already here.
	Joining : [Human, AgentOf(Users.Human)]

	## **A USER JOINED**: the users they joined, and the user.
	Joined : { users : Users, added : Users.User }

	## **A NAME AND AN ID, TOGETHER**, as a URL, a file's stem or a
	## session gives them: `check` holds them to match.
	Identity : { id : UserId, name : Name }

	## **THE USERS' START: STEVE, ALWAYS ID 1**, named `name`, a human.
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

	## **THE NEXT USER'S ID, ITS ONE HOME**: the one after the latest's,
	## unless every id is taken.
	next_id : Users -> Try(UserId, [Full])
	next_id = |Users.(all)| {
		latest = all.last() ?? crash "Users.next_id: Steve, the first user, is in every Users"
		latest.id().next()
	}

	## The users with `name` added as `joining`, at the next id, and that
	## user; unless, in this order, an agent's owner is not one of these
	## users (`NoSuchOwner`), or every id is taken (`Full`).
	add : Users, { name : Name, joining : Users.Joining } -> Try(Users.Joined, [NoSuchOwner, Full])
	add = |users, { name, joining }| {
		role = role_of({ users, joining })?
		id = users.next_id()?
		user = Users.User.(
			{
				id,
				name,
				role,
			},
		)
		Users.(all) = users
		Ok({ users: Users.(all.append(user)), added: user })
	}

	## The user `id`, unless there is none.
	user : Users, UserId -> Try(Users.User, [NoSuchUser])
	user = |Users.(all), id|
		match all.find_first(|candidate| candidate.id() == id) {
			Ok(found) => Ok(found)
			Err(NotFound) => Err(NoSuchUser)
		}

	## **WHERE A NAME AND AN ID COME TOGETHER, THEY MATCH**: the user `id`,
	## if `name` is theirs exactly (names are case-sensitive); unless there
	## is no such user, or the name is another's spelling.
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

## The role of the user `joining` `users`; unless an agent's owner is not
## one of them, exactly: the same id, name and role.
role_of : { users : Users, joining : Users.Joining } -> Try(Users.Role, [NoSuchOwner])
role_of = |{ users, joining }|
	match joining {
		Human => Ok(Human)
		AgentOf(owner) =>
			if (users.user(owner.id()) == Ok(owner.user()))
				Ok(Agent({ owner: owner.id() }))
			else
				Err(NoSuchOwner)
	}

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
##
## The users are kept on disk (`FileSystem`) as small files under the auth
## root: the counter of the next id, `auth/next-id.txt`, its digits and a
## line end (`65536` when every id is taken); and a folder per user, `auth/<id>/`, holding the
## user's name, exactly as given, in `name`, and an agent's owner's id, its
## digits, in `owner`. A human has no `owner` file. `from_files` reads them
## back, and `account_files` and `counter_file` write them.
import Author
import FactFile
import Name
import UserId
import UserStem

Users :: { everyone : List(Users.User), next : [Next(UserId), Full] }.{

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

	## What adding a user gives: the users that hold them, and the user.
	Addition : { users : Users, user : Users.User }

	## An id and a name that arrived together, as a URL, a file's name or a
	## session gives them. `check` holds them to match.
	Identity : { id : UserId, name : Name }

	## The chat's users at the start, when the only user is the founder: the
	## first human, id 1, named `name`.
	with_founder : Name -> Users
	with_founder = |name|
		Users.(
			{
				everyone: [Users.User.({ id: UserId.chat_owner, name, role: Human })],
				next: next_after(UserId.chat_owner),
			},
		)

	## The id the next user will get, unless every id is taken. It is never
	## one given before, as the counter on disk holds it.
	next_id : Users -> Try(UserId, [Full])
	next_id = |Users.(users)|
		match users.next {
			Next(id) => Ok(id)
			Full => Err(Full)
		}

	## One user's files as `auth/<id>/` holds them: the name's bytes, and an
	## agent's owner's id, its digits (`NoFile` for a human).
	AccountFiles : { name : List(U8), owner : [NoFile, File(List(U8))] }

	## A user's files as they were read, with the id their folder is named
	## by.
	StoredAccount : { id : UserId, files : Users.AccountFiles }

	## The user's files, as `from_files` reads them back.
	account_files : Users.User -> Users.AccountFiles
	account_files = |user| {
		name: user.name().to_str().to_utf8(),
		owner: match user.role() {
			Human => NoFile
			Agent({ owner }) => File(owner.to_str().to_utf8())
		},
	}

	## The counter file: the next id's digits and a line end,
	## `UserId.past_highest`'s when every id is taken.
	counter_file : Users -> List(U8)
	counter_file = |Users.(users)| {
		digits =
			match users.next {
				Next(id) => id.to_str()
				Full => UserId.past_highest.to_str()
			}
		"${digits}\n".to_utf8()
	}

	## The users the files hold: the counter `counter`, and each account
	## folder read, in any order. Refused when the counter is no id after
	## the first (`BadCounter`); when a name is no name (`BadName`) or an
	## owner no id (`BadOwner`), each naming the user; when there is no
	## founder, a human with id 1 (`NoFounder`); when an id is at or past
	## the counter (`CounterBehind`); or when an agent's owner is no human
	## among them (`BadOwner`).
	from_files : { counter : List(U8), accounts : List(Users.StoredAccount) } -> Try(
		Users,
		[
			BadCounter,
			BadName(UserId),
			BadOwner(UserId),
			NoFounder,
			CounterBehind,
		],
	)
	from_files = |{ counter, accounts }| {
		next = next_from_file(counter)?
		all = accounts.sort_with(|a, b| a.id.compare(b.id)).map_try(user_from_files)?
		founder_is_human =
			match all.first() {
				Ok(first) => first.id() == UserId.chat_owner and first.role() == Human
				Err(ListWasEmpty) => Bool.False
			}
		if !founder_is_human {
			Err(NoFounder)
		} else {
			match (next, all.last()) {
				(Next(id), Ok(latest)) if latest.id().compare(id) != Before => Err(CounterBehind)
				_ =>
					match all.find_first(|user| !has_human_owner(all, user)) {
						Ok(stray) => Err(BadOwner(stray.id()))
						Err(NotFound) => Ok(Users.({ everyone: all, next }))
					}
			}
		}
	}

	## The users with a human named `name` added at the next id, and that
	## human; unless every id is taken.
	add_human : Users, Name -> Try(Users.Addition, [Full])
	add_human = |users, name| add_user(users, { name, role: Human })

	## The users with an agent named `name`, owned by `owner`, added at the
	## next id, and that agent. The owner is checked first: they must be a
	## human of these users, with the same id and name (`NoSuchOwner`).
	## Then the agent needs a free id (`Full`).
	add_agent : Users,
	{ name : Name, owner : Users.Human } -> Try(
		Users.Addition,
		[NoSuchOwner, Full],
	)
	add_agent = |users, { name, owner }|
		if users.user(owner.id()) == Ok(owner.user()) {
			add_user(users, { name, role: Agent({ owner: owner.id() }) })
		} else {
			Err(NoSuchOwner)
		}

	## The users with the human `human` named `name` instead, and that human
	## as renamed; unless `human` is not one of these users, by the same id
	## and name (`NoSuchHuman`). `Directory` keeps the new name unique.
	rename_human : Users,
	{ human : Users.Human, name : Name } -> Try(
		{ users : Users, human : Users.Human },
		[NoSuchHuman],
	)
	rename_human = |users, { human, name }|
		if users.user(human.id()) == Ok(human.user()) {
			renamed = Users.User.({ id: human.id(), name, role: Human })
			Users.(held) = users
			everyone = held.everyone.map(
				|user| if user.id() == human.id() {
					renamed
				} else {
					user
				},
			)
			Ok({ users: Users.({ ..held, everyone }), human: Users.Human.(renamed) })
		} else {
			Err(NoSuchHuman)
		}

	## The user with the id `id`, if there is one.
	user : Users, UserId -> Try(Users.User, [NoSuchUser])
	user = |Users.(users), id|
		match users.everyone.find_first(|candidate| candidate.id() == id) {
			Ok(found) => Ok(found)
			Err(NotFound) => Err(NoSuchUser)
		}

	## The user named `name`, if there is one. Names are case-sensitive, so
	## `steve` is not `Steve`.
	user_by_name : Users, Name -> Try(Users.User, [NoSuchUser])
	user_by_name = |Users.(users), name|
		match users.everyone.find_first(|candidate| candidate.name() == name) {
			Ok(found) => Ok(found)
			Err(NotFound) => Err(NoSuchUser)
		}

	## The user with the identity's id, if the identity's name is exactly
	## theirs. Names are case-sensitive, so `steve` is not `Steve`.
	check : Users, Users.Identity -> Try(Users.User, [NoSuchUser, NameMismatch])
	check = |users, { id, name }| {
		found = users.user(id)?
		if found.name() == name {
			Ok(found)
		} else {
			Err(NameMismatch)
		}
	}

	## Every user, in id order.
	to_list : Users -> List(Users.User)
	to_list = |Users.(users)| users.everyone

	is_eq : _
}

## The counter's place after `id`, unless `id` is the highest.
next_after : UserId -> [Next(UserId), Full]
next_after = |id|
	match id.next() {
		Ok(next) => Next(next)
		Err(Full) => Full
	}

## The next id a counter file holds: the digits of an id after the first, or
## `UserId.past_highest`'s when every id is taken.
next_from_file : List(U8) -> Try([Next(UserId), Full], [BadCounter])
next_from_file = |bytes| {
	number = FactFile.number_from_file(bytes) ? |NotANumber| BadCounter
	if number == UserId.past_highest {
		Ok(Full)
	} else {
		match UserId.from_str(number.to_str()) {
			Ok(id) if id != UserId.chat_owner => Ok(Next(id))
			_ => Err(BadCounter)
		}
	}
}

## The user an account folder's files make.
user_from_files : Users.StoredAccount -> Try(Users.User, [BadName(UserId), BadOwner(UserId)])
user_from_files = |{ id, files }| {
	written = Str.from_utf8(FactFile.word_from_file(files.name)) ? |_| BadName(id)
	name = Name.from_str(written) ? |_| BadName(id)
	role = role_from_file(files.owner) ? |NotAnOwner| BadOwner(id)
	Ok(Users.User.({ id, name, role }))
}

## The role an `owner` file gives: none, a human; an id's digits, an agent
## of that owner.
role_from_file : [NoFile, File(List(U8))] -> Try(Users.Role, [NotAnOwner])
role_from_file = |owner_file|
	match owner_file {
		NoFile => Ok(Human)
		File(bytes) =>
			match Str.from_utf8(FactFile.word_from_file(bytes)) {
				Ok(digits) =>
					match UserId.from_str(digits) {
						Ok(owner) => Ok(Agent({ owner: owner }))
						Err(NotAUserId) => Err(NotAnOwner)
					}
				Err(_) => Err(NotAnOwner)
			}
	}

## Whether `user` is a human, or an agent whose owner is a human of `all`.
has_human_owner : List(Users.User), Users.User -> Bool
has_human_owner = |all, user|
	match user.role() {
		Human => Bool.True
		Agent({ owner }) =>
			all.any(|candidate| candidate.id() == owner and candidate.role() == Human)
	}

## The users with a user named `name` added in the role `role`, at the next
## id, and that user; unless every id is taken.
add_user : Users, { name : Name, role : Users.Role } -> Try(Users.Addition, [Full])
add_user = |users, { name, role }| {
	id = users.next_id()?
	user = Users.User.({ id, name, role })
	Users.(held) = users
	Ok({ users: Users.({ everyone: held.everyone.append(user), next: next_after(id) }), user })
}

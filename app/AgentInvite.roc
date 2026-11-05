## An invite is how an agent gets its key. Its owner, a human signed in by
## a session, makes it, and is shown its one-time code once; the agent
## redeems the code, with no other credential, for a key (`AgentKey`) of
## the scope the invite names. The chat keeps the code's hash, never the
## code. An invite lives ten minutes (`lifetime_seconds`), redeems once, and
## can be revoked while it is live.
##
## `FileSystem` keeps each fact in a file of its own, in the agent's folder
## under `invites/<number>/`: `created` and `expires` (seconds since the
## epoch), `state` (`live`, `spent` or `revoked`), `read` and `post`
## (`KeyScope`'s words), and `hash` (the code's hash), written last.
##
## This module and `AgentKey` are one trust boundary with `SignedIn`: an
## invite's code is a credential for exactly one key.
import FactFile
import KeyScope
import SecretHash
import SerialNumber

AgentInvite :: {
	id : AgentInvite.Id,
	hash : SecretHash,
	created : I64,
	expires : I64,
	state : AgentInvite.State,
	scope : KeyScope,
}.{

	## An invite's number among its agent's invites (`SerialNumber`).
	Id :: U32.{

		## The number `text` spells, as a folder's name and a URL carry it.
		from_str : Str -> Try(AgentInvite.Id, [NotAnInviteId])
		from_str = |text|
			SerialNumber.from_str(text)
				.map_ok(|n| AgentInvite.Id.(n))
				.map_err(|NotASerialNumber| NotAnInviteId)

		## The number after the highest of `given`, 1 for none.
		next_after : List(AgentInvite.Id) -> Try(AgentInvite.Id, [Full])
		next_after = |given|
			SerialNumber.next_after(given.map(|AgentInvite.Id.(n)| n))
				.map_ok(|n| AgentInvite.Id.(n))

		to_str : AgentInvite.Id -> Str
		to_str = |AgentInvite.Id.(n)| n.to_str()

		is_eq : _
	}

	## Whether an invite may still be redeemed: `Live` until it is redeemed
	## (`Spent`) or revoked (`Revoked`).
	State : [Live, Spent, Revoked]

	## An invite's facts as their files hold them, one file each.
	Files : {
		created : List(U8),
		expires : List(U8),
		state : List(U8),
		read : List(U8),
		post : List(U8),
		hash : List(U8),
	}

	## How long an invite lives: ten minutes, roc-chat's.
	lifetime_seconds : I64
	lifetime_seconds = 10 * 60

	## A new invite, live from `now` for `lifetime_seconds`, its code's hash
	## `hash`, for a key of `scope`.
	make : {
		id : AgentInvite.Id,
		hash : SecretHash,
		now : I64,
		scope : KeyScope,
	} -> AgentInvite
	make = |{ id, hash, now, scope }|
		AgentInvite.(
			{
				id,
				hash,
				created: now,
				expires: now + AgentInvite.lifetime_seconds,
				state: Live,
				scope,
			},
		)

	## The invite among `invites` whose code's hash is `hash`, redeemed at
	## `now`: spent, for its scope's key. Refused when none has the hash
	## (`NoSuchInvite`), when it is spent (`Spent`) or revoked (`Revoked`),
	## or when `now` is at or past its expiry, or before its making
	## (`Expired`).
	redeem : {
		invites : List(AgentInvite),
		hash : SecretHash,
		now : I64,
	} -> Try(AgentInvite, [NoSuchInvite, Spent, Revoked, Expired])
	redeem = |{ invites, hash, now }|
		match invites.find_first(|AgentInvite.(invite)| invite.hash == hash) {
			Err(NotFound) => Err(NoSuchInvite)
			Ok(AgentInvite.(invite)) =>
				match invite.state {
					Spent => Err(Spent)
					Revoked => Err(Revoked)
					Live if now < invite.created or now >= invite.expires => Err(Expired)
					Live => Ok(AgentInvite.({ ..invite, state: Spent }))
				}
		}

	## The invite revoked, while it is live; a spent one is `Spent`, and one
	## already revoked `AlreadyRevoked`.
	revoke : AgentInvite -> Try(AgentInvite, [Spent, AlreadyRevoked])
	revoke = |AgentInvite.(invite)|
		match invite.state {
			Live => Ok(AgentInvite.({ ..invite, state: Revoked }))
			Spent => Err(Spent)
			Revoked => Err(AlreadyRevoked)
		}

	id : AgentInvite -> AgentInvite.Id
	id = |AgentInvite.(invite)| invite.id

	state : AgentInvite -> AgentInvite.State
	state = |AgentInvite.(invite)| invite.state

	expires : AgentInvite -> I64
	expires = |AgentInvite.(invite)| invite.expires

	scope : AgentInvite -> KeyScope
	scope = |AgentInvite.(invite)| invite.scope

	## The invite's facts as their files keep them.
	to_files : AgentInvite -> AgentInvite.Files
	to_files = |AgentInvite.(invite)| {
		created: FactFile.seconds_to_file(invite.created),
		expires: FactFile.seconds_to_file(invite.expires),
		state: state_to_file(invite.state),
		read: KeyScope.reach_to_file(invite.scope.read()),
		post: KeyScope.reach_to_file(invite.scope.post()),
		hash: invite.hash.to_file(),
	}

	## The invite numbered `id` whose facts `files` hold; unless one of them
	## holds no such fact (`BadFact`, naming the file).
	from_files : AgentInvite.Id, AgentInvite.Files -> Try(AgentInvite, [BadFact(Str)])
	from_files = |number, files| {
		made_at = FactFile.seconds_from_file(files.created) ? |_| BadFact("created")
		ends_at = FactFile.seconds_from_file(files.expires) ? |_| BadFact("expires")
		held_state = state_from_file(files.state) ? |_| BadFact("state")
		read = KeyScope.reach_from_file(files.read) ? |_| BadFact("read")
		post = KeyScope.reach_from_file(files.post) ? |_| BadFact("post")
		hash = SecretHash.from_file(files.hash) ? |_| BadFact("hash")
		Ok(
			AgentInvite.(
				{
					id: number,
					hash,
					created: made_at,
					expires: ends_at,
					state: held_state,
					scope: KeyScope.of({ read, post }),
				},
			),
		)
	}

	is_eq : _
}

state_to_file : AgentInvite.State -> List(U8)
state_to_file = |state|
	match state {
		Live => "live".to_utf8()
		Spent => "spent".to_utf8()
		Revoked => "revoked".to_utf8()
	}

state_from_file : List(U8) -> Try(AgentInvite.State, [NotAState])
state_from_file = |bytes| {
	word = FactFile.word_from_file(bytes)
	if (word == "live".to_utf8())
		Ok(Live)
	else if (word == "spent".to_utf8())
		Ok(Spent)
	else if (word == "revoked".to_utf8())
		Ok(Revoked)
	else
		Err(NotAState)
}

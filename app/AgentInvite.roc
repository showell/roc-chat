## An invite is how an agent gets its key. Its owner, a human signed in by
## a session, makes it, and is shown its one-time code once; the agent
## redeems the code, with no other credential, for a key (`AgentKey`) of
## the scope the invite names. The chat keeps the code's hash, never the
## code. An invite lives ten minutes (`lifetime_seconds`), redeems once, and
## can be revoked while it is live.
##
## `AgentFiles` keeps each fact in a file of its own, in the agent's folder
## under `invites/<number>/`: `created` and `expires` (seconds since the
## epoch), `state` (`live`, `spent` or `revoked`), `read` and `post`
## (`KeyScope`'s words), and `hash` (the code's hash), written last.
##
## This module and `AgentKey` are one trust boundary with `SignedIn`: an
## invite's code is a credential for exactly one key.
import KeyScope
import Seconds
import SecretHash
import SerialNumber
import Timestamp

AgentInvite :: {
	id : AgentInvite.Id,
	hash : SecretHash,
	created : Timestamp,
	expires : Timestamp,
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

	## An invite's facts, all but its number, as plain values: what a store
	## keeps of it.
	Facts : {
		created : Timestamp,
		expires : Timestamp,
		state : AgentInvite.State,
		scope : KeyScope,
		hash : SecretHash,
	}

	## How long an invite lives: ten minutes.
	lifetime_seconds : Seconds
	lifetime_seconds = Seconds.of(10 * 60)

	## A new invite, live from `now` for `lifetime_seconds`, its code's hash
	## `hash`, for a key of `scope`.
	make : {
		id : AgentInvite.Id,
		hash : SecretHash,
		now : Timestamp,
		scope : KeyScope,
	} -> AgentInvite
	make = |{ id, hash, now, scope }|
		AgentInvite.(
			{
				id,
				hash,
				created: now,
				expires: now.plus(AgentInvite.lifetime_seconds),
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
		now : Timestamp,
	} -> Try(AgentInvite, [NoSuchInvite, Spent, Revoked, Expired])
	redeem = |{ invites, hash, now }|
		match invites.find_first(|AgentInvite.(invite)| invite.hash == hash) {
			Err(NotFound) => Err(NoSuchInvite)
			Ok(AgentInvite.(invite)) => {
				lifetime = { from: invite.created, until: invite.expires }
				match invite.state {
					Spent => Err(Spent)
					Revoked => Err(Revoked)
					Live if !now.is_during(lifetime) => Err(Expired)
					Live => Ok(AgentInvite.({ ..invite, state: Spent }))
				}
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

	expires : AgentInvite -> Timestamp
	expires = |AgentInvite.(invite)| invite.expires

	scope : AgentInvite -> KeyScope
	scope = |AgentInvite.(invite)| invite.scope

	## The invite's facts, all but its number.
	to_facts : AgentInvite -> AgentInvite.Facts
	to_facts = |AgentInvite.(invite)| {
		created: invite.created,
		expires: invite.expires,
		state: invite.state,
		scope: invite.scope,
		hash: invite.hash,
	}

	## The invite numbered `id` whose facts are `facts`.
	from_facts : AgentInvite.Id, AgentInvite.Facts -> AgentInvite
	from_facts = |number, facts|
		AgentInvite.(
			{
				id: number,
				hash: facts.hash,
				created: facts.created,
				expires: facts.expires,
				state: facts.state,
				scope: facts.scope,
			},
		)

	is_eq : _
}

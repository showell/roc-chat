## An agent's API key, as the chat keeps it: its number among the agent's
## keys, its secret's hash (never the secret), when it was made and when it
## expires, whether it is active or revoked, and its scope (`KeyScope`). An
## agent may hold several keys, and each may be revoked on its own.
##
## A key comes only from redeeming an invite (`AgentInvite`): humans never
## pass a durable secret around. `mint` makes one for that redemption, and
## `admit` is the check an agent's request passes: the hash of the secret it
## sent matches an active key of its own that has not expired. Only `admit`
## makes an `AgentKey.Admitted`, and only an `Admitted` makes a `SignedIn`
## by key (`SignedIn.by_api_key`). The two modules together are the trust
## boundary that says which agent is acting.
##
## `FileSystem` keeps each fact in a file of its own, in the agent's folder
## under `keys/<number>/`: `created` and `expires` (seconds since the epoch,
## `FactFile`'s digits), `state` (`active` or `revoked`), `read` and `post`
## (`KeyScope`'s words), and `hash` (`SecretHash`'s 64 hex digits), written
## last, so a key cut short by a crash never admits anyone.
import FactFile
import KeyScope
import SecretHash
import SerialNumber
import Users

AgentKey :: {
	id : AgentKey.Id,
	hash : SecretHash,
	created : I64,
	expires : I64,
	state : AgentKey.State,
	scope : KeyScope,
}.{

	## A key's number among its agent's keys (`SerialNumber`).
	Id :: U32.{

		## The number `text` spells, as a folder's name and a URL carry it.
		from_str : Str -> Try(AgentKey.Id, [NotAKeyId])
		from_str = |text|
			SerialNumber.from_str(text)
				.map_ok(|n| AgentKey.Id.(n))
				.map_err(|NotASerialNumber| NotAKeyId)

		## The number after the highest of `given`, 1 for none.
		next_after : List(AgentKey.Id) -> Try(AgentKey.Id, [Full])
		next_after = |given|
			SerialNumber.next_after(given.map(|AgentKey.Id.(n)| n)).map_ok(|n| AgentKey.Id.(n))

		to_str : AgentKey.Id -> Str
		to_str = |AgentKey.Id.(n)| n.to_str()

		is_eq : _
	}

	## Whether a key still admits its agent.
	State : [Active, Revoked]

	## A key's facts as their files hold them, one file each.
	Files : {
		created : List(U8),
		expires : List(U8),
		state : List(U8),
		read : List(U8),
		post : List(U8),
		hash : List(U8),
	}

	## How long a key lives: a year, roc-chat's longest.
	lifetime_seconds : I64
	lifetime_seconds = 365 * 24 * 60 * 60

	## A new key, active from `now` for `lifetime_seconds`, its secret's
	## hash `hash`.
	mint : {
		id : AgentKey.Id,
		hash : SecretHash,
		now : I64,
		scope : KeyScope,
	} -> AgentKey
	mint = |{ id, hash, now, scope }|
		AgentKey.(
			{
				id,
				hash,
				created: now,
				expires: now + AgentKey.lifetime_seconds,
				state: Active,
				scope,
			},
		)

	## The key revoked, unless it already is (`AlreadyRevoked`).
	revoke : AgentKey -> Try(AgentKey, [AlreadyRevoked])
	revoke = |AgentKey.(key)|
		match key.state {
			Active => Ok(AgentKey.({ ..key, state: Revoked }))
			Revoked => Err(AlreadyRevoked)
		}

	## The agent `user`, admitted by the key among its own `keys` whose hash
	## is `hash`, at `now`: with that key's scope. Refused when `user` is no
	## agent (`NotAnAgent`: a human holds no key), when no key has the hash
	## (`NoSuchKey`), when that key is revoked (`Revoked`), or when `now` is
	## at or past its expiry, or before its making (`Expired`).
	admit : {
		user : Users.User,
		keys : List(AgentKey),
		hash : SecretHash,
		now : I64,
	} -> Try(AgentKey.Admitted, [NotAnAgent, NoSuchKey, Revoked, Expired])
	admit = |{ user, keys, hash, now }|
		match user.role() {
			Human => Err(NotAnAgent)
			Agent(_) =>
				match keys.find_first(|AgentKey.(key)| key.hash == hash) {
					Err(NotFound) => Err(NoSuchKey)
					Ok(AgentKey.(key)) =>
						match key.state {
							Revoked => Err(Revoked)
							Active if now < key.created or now >= key.expires => Err(Expired)
							Active => Ok(AgentKey.Admitted.({ user, scope: key.scope }))
						}
				}
		}

	## An agent a key admitted, and that key's scope. Only `admit` makes one.
	Admitted :: { user : Users.User, scope : KeyScope }.{

		user : AgentKey.Admitted -> Users.User
		user = |AgentKey.Admitted.(admitted)| admitted.user

		scope : AgentKey.Admitted -> KeyScope
		scope = |AgentKey.Admitted.(admitted)| admitted.scope
	}

	id : AgentKey -> AgentKey.Id
	id = |AgentKey.(key)| key.id

	state : AgentKey -> AgentKey.State
	state = |AgentKey.(key)| key.state

	expires : AgentKey -> I64
	expires = |AgentKey.(key)| key.expires

	scope : AgentKey -> KeyScope
	scope = |AgentKey.(key)| key.scope

	## The key's facts as their files keep them.
	to_files : AgentKey -> AgentKey.Files
	to_files = |AgentKey.(key)| {
		created: FactFile.seconds_to_file(key.created),
		expires: FactFile.seconds_to_file(key.expires),
		state: state_to_file(key.state),
		read: KeyScope.reach_to_file(key.scope.read()),
		post: KeyScope.reach_to_file(key.scope.post()),
		hash: key.hash.to_file(),
	}

	## The key numbered `id` whose facts `files` hold; unless one of them
	## holds no such fact (`BadFact`, naming the file).
	from_files : AgentKey.Id, AgentKey.Files -> Try(AgentKey, [BadFact(Str)])
	from_files = |number, files| {
		made_at = FactFile.seconds_from_file(files.created) ? |_| BadFact("created")
		ends_at = FactFile.seconds_from_file(files.expires) ? |_| BadFact("expires")
		held_state = state_from_file(files.state) ? |_| BadFact("state")
		read = KeyScope.reach_from_file(files.read) ? |_| BadFact("read")
		post = KeyScope.reach_from_file(files.post) ? |_| BadFact("post")
		hash = SecretHash.from_file(files.hash) ? |_| BadFact("hash")
		Ok(
			AgentKey.(
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

state_to_file : AgentKey.State -> List(U8)
state_to_file = |state|
	match state {
		Active => "active".to_utf8()
		Revoked => "revoked".to_utf8()
	}

state_from_file : List(U8) -> Try(AgentKey.State, [NotAState])
state_from_file = |bytes| {
	word = FactFile.word_from_file(bytes)
	if word == "active".to_utf8() {
		Ok(Active)
	} else if word == "revoked".to_utf8() {
		Ok(Revoked)
	} else {
		Err(NotAState)
	}
}

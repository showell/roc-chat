## This module keeps each agent's API keys and the invites that mint them
## on disk. It reads and writes them through `FileFacts`, and builds every
## path from the agent's id and the key's or invite's number, so no caller
## names a file.
##
## An agent's keys are kept in its account folder (`AccountFiles`) under
## `keys/<number>/` (`AgentKey`), and its invites under `invites/<number>/`
## (`AgentInvite`). A key and an invite have the same facts, one file each
## (`KeyFiles`): `created` and `expires` (seconds since the epoch,
## `FactFile`'s digits), `read` and `post` (`KeyScope`'s words), `state`
## (a key's `active` or `revoked`, an invite's `live`, `spent` or
## `revoked`) and `hash` (`SecretHash`'s 64 hex digits). Each is
## written one file at a time, each made once, its `hash` last, so a key or
## an invite cut short by a crash is never whole and admits no one.
import AccountFiles
import AccountFolder
import AgentInvite
import AgentKey
import FactFile
import FileFacts
import KeyScope
import SecretHash
import Timestamp
import UserId

AgentFiles :: [].{

	## A key's or an invite's facts as their files hold them, one file each.
	KeyFiles : {
		created : List(U8),
		expires : List(U8),
		state : List(U8),
		read : List(U8),
		post : List(U8),
		hash : List(U8),
	}

	## The key's facts as their files keep them.
	key_files : AgentKey -> AgentFiles.KeyFiles
	key_files = |key| {
		facts = key.to_facts()
		{
			created: facts.created.to_file(),
			expires: facts.expires.to_file(),
			state: key_state_word(facts.state),
			read: KeyScope.reach_to_file(facts.scope.read()),
			post: KeyScope.reach_to_file(facts.scope.post()),
			hash: facts.hash.to_file(),
		}
	}

	## The key numbered `id` whose facts `files` hold; unless one of them
	## holds no such fact (`BadFact`, naming the file).
	key_from_files : AgentKey.Id, AgentFiles.KeyFiles -> Try(AgentKey, [BadFact(Str)])
	key_from_files = |id, files| {
		created = Timestamp.from_file(files.created) ? |_| BadFact("created")
		expires = Timestamp.from_file(files.expires) ? |_| BadFact("expires")
		state = key_state_from_word(files.state) ? |_| BadFact("state")
		read = KeyScope.reach_from_file(files.read) ? |_| BadFact("read")
		post = KeyScope.reach_from_file(files.post) ? |_| BadFact("post")
		hash = SecretHash.from_file(files.hash) ? |_| BadFact("hash")
		scope = KeyScope.of({ read, post })
		Ok(AgentKey.from_facts(id, { created, expires, state, scope, hash }))
	}

	## The invite's facts as their files keep them.
	invite_files : AgentInvite -> AgentFiles.KeyFiles
	invite_files = |invite| {
		facts = invite.to_facts()
		{
			created: facts.created.to_file(),
			expires: facts.expires.to_file(),
			state: invite_state_word(facts.state),
			read: KeyScope.reach_to_file(facts.scope.read()),
			post: KeyScope.reach_to_file(facts.scope.post()),
			hash: facts.hash.to_file(),
		}
	}

	## The invite numbered `id` whose facts `files` hold; unless one of them
	## holds no such fact (`BadFact`, naming the file).
	invite_from_files : AgentInvite.Id, AgentFiles.KeyFiles -> Try(AgentInvite, [BadFact(Str)])
	invite_from_files = |id, files| {
		created = Timestamp.from_file(files.created) ? |_| BadFact("created")
		expires = Timestamp.from_file(files.expires) ? |_| BadFact("expires")
		state = invite_state_from_word(files.state) ? |_| BadFact("state")
		read = KeyScope.reach_from_file(files.read) ? |_| BadFact("read")
		post = KeyScope.reach_from_file(files.post) ? |_| BadFact("post")
		hash = SecretHash.from_file(files.hash) ? |_| BadFact("hash")
		scope = KeyScope.of({ read, post })
		Ok(AgentInvite.from_facts(id, { created, expires, state, scope, hash }))
	}

	## The keys in `agent`'s account folder, each whole. A key whose files
	## are not all there, or don't each hold their fact, is left out: it
	## admits no one, and fails only itself.
	read_agent_keys! : UserId => Try(List(AgentKey), [NotUtf8, PathRefused, Failed])
	read_agent_keys! = |agent| {
		names = FileFacts.list_names_in!(keys_folder_path(agent))?
		ids = names.keep_oks(AgentKey.Id.from_str)
		var $keys = []
		for id in ids {
			match read_record_facts!(key_folder_path(agent, id)) {
				Ok(files) =>
					match AgentFiles.key_from_files(id, files) {
						Ok(key) => {
							$keys = $keys.append(key)
						}
						Err(BadFact(_)) => {}
					}
				Err(Missing) => {}
				Err(NotUtf8) => return Err(NotUtf8)
				Err(PathRefused) => return Err(PathRefused)
				Err(Failed) => return Err(Failed)
			}
		}
		Ok($keys)
	}

	## The number the next key of `agent`'s will have: after every key
	## folder's, a key cut short included, so no number is given twice.
	find_next_agent_key_id! : UserId => Try(AgentKey.Id, [Full, FileSystem(FileFacts.Fault)])
	find_next_agent_key_id! = |agent| {
		names = FileFacts.list_names_in!(keys_folder_path(agent)) ? |fault| FileSystem(fault)
		AgentKey.Id.next_after(names.keep_oks(AgentKey.Id.from_str))
	}

	## The number the next invite of `agent`'s will have, as a key's is.
	find_next_agent_invite_id! : UserId => Try(AgentInvite.Id, [Full, FileSystem(FileFacts.Fault)])
	find_next_agent_invite_id! = |agent| {
		names = FileFacts.list_names_in!(invites_folder_path(agent)) ? |fault| FileSystem(fault)
		AgentInvite.Id.next_after(names.keep_oks(AgentInvite.Id.from_str))
	}

	## A new key in `agent`'s account folder, made once, its hash last.
	create_agent_key! : UserId,
	AgentKey => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_agent_key! = |agent, key| FileFacts.create_facts!(
		key_folder_path(agent, key.id()),
		record_facts(AgentFiles.key_files(key)),
	)

	## A key's state, written over the one before, as `key` holds it.
	replace_agent_key_state! : UserId,
	AgentKey => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_agent_key_state! = |agent, key| FileFacts.replace_fact!(
		"${key_folder_path(agent, key.id())}/${state_fact}",
		key_state_word(key.state()),
	)

	## The invites in `agent`'s account folder, each whole; one cut short
	## or damaged is left out, as a key is.
	read_agent_invites! : UserId => Try(List(AgentInvite), [NotUtf8, PathRefused, Failed])
	read_agent_invites! = |agent| {
		names = FileFacts.list_names_in!(invites_folder_path(agent))?
		ids = names.keep_oks(AgentInvite.Id.from_str)
		var $invites = []
		for id in ids {
			match read_record_facts!(invite_folder_path(agent, id)) {
				Ok(files) =>
					match AgentFiles.invite_from_files(id, files) {
						Ok(invite) => {
							$invites = $invites.append(invite)
						}
						Err(BadFact(_)) => {}
					}
				Err(Missing) => {}
				Err(NotUtf8) => return Err(NotUtf8)
				Err(PathRefused) => return Err(PathRefused)
				Err(Failed) => return Err(Failed)
			}
		}
		Ok($invites)
	}

	## A new invite in `agent`'s account folder, made once, its hash last.
	create_agent_invite! : UserId,
	AgentInvite => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_agent_invite! = |agent, invite| FileFacts.create_facts!(
		invite_folder_path(agent, invite.id()),
		record_facts(AgentFiles.invite_files(invite)),
	)

	## An invite's state, written over the one before, as `invite` holds it.
	replace_agent_invite_state! : UserId,
	AgentInvite => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_agent_invite_state! = |agent, invite| FileFacts.replace_fact!(
		"${invite_folder_path(agent, invite.id())}/${state_fact}",
		invite_state_word(invite.state()),
	)
}

## The fact file of a key's or an invite's state.
state_fact : Str
state_fact = "state"

## The folder of an agent's keys.
keys_folder_path : UserId -> Str
keys_folder_path = |agent| "${AccountFiles.account_folder_path(AccountFolder.of(agent))}/keys"

## The folder of one of an agent's keys.
key_folder_path : UserId, AgentKey.Id -> Str
key_folder_path = |agent, id| "${keys_folder_path(agent)}/${id.to_str()}"

## The folder of an agent's invites.
invites_folder_path : UserId -> Str
invites_folder_path = |agent| "${AccountFiles.account_folder_path(AccountFolder.of(agent))}/invites"

## The folder of one of an agent's invites.
invite_folder_path : UserId, AgentInvite.Id -> Str
invite_folder_path = |agent, id| "${invites_folder_path(agent)}/${id.to_str()}"

## The fact files of a key or an invite, in the order they are written: the
## hash last, so a record cut short is never whole. An agent's invite has the
## same files as its keys.
record_facts : AgentFiles.KeyFiles -> List((Str, List(U8)))
record_facts = |files| [
	("created", files.created),
	("expires", files.expires),
	("read", files.read),
	("post", files.post),
	(state_fact, files.state),
	("hash", files.hash),
]

## The fact files of the key or invite in `folder`; unless one is missing or
## the host's read failed.
read_record_facts! : Str => Try(AgentFiles.KeyFiles, _)
read_record_facts! = |folder| {
	hash = FileFacts.read_needed_fact!("${folder}/hash")?
	created = FileFacts.read_needed_fact!("${folder}/created")?
	expires = FileFacts.read_needed_fact!("${folder}/expires")?
	state = FileFacts.read_needed_fact!("${folder}/${state_fact}")?
	read = FileFacts.read_needed_fact!("${folder}/read")?
	post = FileFacts.read_needed_fact!("${folder}/post")?
	Ok({
		created,
		expires,
		state,
		read,
		post,
		hash,
	})
}

## A key's state, as its `state` file holds it.
key_state_word : AgentKey.State -> List(U8)
key_state_word = |state|
	match state {
		Active => "active".to_utf8()
		Revoked => "revoked".to_utf8()
	}

## The state a key's `state` file holds; unless it holds none.
key_state_from_word : List(U8) -> Try(AgentKey.State, [NotAState])
key_state_from_word = |bytes| {
	word = FactFile.word_from_file(bytes)
	if word == "active".to_utf8() {
		Ok(Active)
	} else if word == "revoked".to_utf8() {
		Ok(Revoked)
	} else {
		Err(NotAState)
	}
}

## An invite's state, as its `state` file holds it.
invite_state_word : AgentInvite.State -> List(U8)
invite_state_word = |state|
	match state {
		Live => "live".to_utf8()
		Spent => "spent".to_utf8()
		Revoked => "revoked".to_utf8()
	}

## The state an invite's `state` file holds; unless it holds none.
invite_state_from_word : List(U8) -> Try(AgentInvite.State, [NotAState])
invite_state_from_word = |bytes| {
	word = FactFile.word_from_file(bytes)
	if word == "live".to_utf8() {
		Ok(Live)
	} else if word == "spent".to_utf8() {
		Ok(Spent)
	} else if word == "revoked".to_utf8() {
		Ok(Revoked)
	} else {
		Err(NotAState)
	}
}

# ── tests
# The paths each builder makes, under the auth root.
expect {
	agent = UserId.from_str("12") ?? crash "AgentFiles' tests: an id"
	key = AgentKey.Id.from_str("3") ?? crash "AgentFiles' tests: a key's number"
	invite = AgentInvite.Id.from_str("4") ?? crash "AgentFiles' tests: an invite's number"
	keys_folder_path(agent) == "auth/12/keys"
		and key_folder_path(agent, key) == "auth/12/keys/3"
		and invites_folder_path(agent) == "auth/12/invites"
		and invite_folder_path(agent, invite) == "auth/12/invites/4"
}

## The hash whose every byte is `b`.
hash_of : U8 -> SecretHash
hash_of = |byte| SecretHash.of_digest(List.repeat(byte, 32))

## A key's number, `n`.
key_id : Str -> AgentKey.Id
key_id = |text| AgentKey.Id.from_str(text) ?? crash "AgentFiles' tests: a key's number"

## An invite's number, `n`.
invite_id : Str -> AgentInvite.Id
invite_id = |text| AgentInvite.Id.from_str(text) ?? crash "AgentFiles' tests: an invite's number"

## When the tests' keys and invites are made.
made_at : Timestamp
made_at = Timestamp.at_second(1_761_600_000)

## Key 1, its hash every byte 0x5a, made at `made_at` for every reach.
key_one : AgentKey
key_one = AgentKey.mint({
	id: key_id("1"),
	hash: hash_of(0x5a),
	now: made_at,
	scope: KeyScope.everywhere,
})

## Key 2, its hash every byte 0x6b, reading only.
key_two : AgentKey
key_two = AgentKey.mint({
	id: key_id("2"),
	hash: hash_of(0x6b),
	now: made_at,
	scope: KeyScope.of({ read: Everywhere, post: Off }),
})

## Invite 1, its code's hash every byte 0x7c, made at `made_at`, posting
## nothing.
invite_one : AgentInvite
invite_one = AgentInvite.make({
	id: invite_id("1"),
	hash: hash_of(0x7c),
	now: made_at,
	scope: KeyScope.of({ read: Everywhere, post: Off }),
})

## Invite 2, its code's hash every byte 0x8d, for every reach.
invite_two : AgentInvite
invite_two = AgentInvite.make({
	id: invite_id("2"),
	hash: hash_of(0x8d),
	now: made_at,
	scope: KeyScope.everywhere,
})

# A key's files, exactly, and read back as the same key.
expect
	AgentFiles.key_files(key_two)
		== {
			created: "1761600000".to_utf8(),
			expires: "1793136000".to_utf8(),
			state: "active".to_utf8(),
			read: "everywhere".to_utf8(),
			post: "off".to_utf8(),
			hash: "6b".repeat(32).to_utf8(),
		}
expect AgentFiles.key_from_files(key_id("2"), AgentFiles.key_files(key_two)) == Ok(key_two)
expect {
	revoked = key_one.revoke() ?? crash "AgentFiles' tests: an active key revokes"
	AgentFiles.key_files(revoked).state == "revoked".to_utf8() and AgentFiles.key_from_files(
		key_id("1"),
		AgentFiles.key_files(revoked),
	) == Ok(revoked)
}
# Each fact that is no fact, refused by its file's name.
expect {
	files = AgentFiles.key_files(key_one)
	[
		({ ..files, created: "-1".to_utf8() }, "created"),
		({ ..files, expires: "soon".to_utf8() }, "expires"),
		({ ..files, state: "Active".to_utf8() }, "state"),
		({ ..files, read: "on".to_utf8() }, "read"),
		({ ..files, post: "".to_utf8() }, "post"),
		({ ..files, hash: "5a".repeat(31).to_utf8() }, "hash"),
	].all(|(bad, name)| AgentFiles.key_from_files(key_id("1"), bad) == Err(BadFact(name)))
}
# An invite's files, exactly, and read back; each state's word.
expect
	AgentFiles.invite_files(invite_one)
		== {
			created: "1761600000".to_utf8(),
			expires: "1761600600".to_utf8(),
			state: "live".to_utf8(),
			read: "everywhere".to_utf8(),
			post: "off".to_utf8(),
			hash: "7c".repeat(32).to_utf8(),
		}
expect AgentFiles.invite_from_files(
	invite_id("1"),
	AgentFiles.invite_files(invite_one),
) == Ok(invite_one)
expect {
	spent = AgentInvite.redeem({
		invites: [invite_one],
		hash: hash_of(0x7c),
		now: made_at,
	}) ?? crash "AgentFiles' tests: invite 1 redeems"
	revoked = invite_two.revoke() ?? crash "AgentFiles' tests: a live invite revokes"
	AgentFiles.invite_files(spent).state == "spent".to_utf8()
		and AgentFiles.invite_files(revoked).state == "revoked".to_utf8()
		and AgentFiles.invite_from_files(
			invite_id("1"),
			AgentFiles.invite_files(spent),
		) == Ok(spent)
		and AgentFiles.invite_from_files(
			invite_id("2"),
			AgentFiles.invite_files(revoked),
		) == Ok(revoked)
}
expect {
	files = AgentFiles.invite_files(invite_one)
	[
		({ ..files, created: "x".to_utf8() }, "created"),
		({ ..files, expires: "".to_utf8() }, "expires"),
		({ ..files, state: "used".to_utf8() }, "state"),
		({ ..files, read: "off off".to_utf8() }, "read"),
		({ ..files, post: "On".to_utf8() }, "post"),
		({ ..files, hash: "zz".repeat(32).to_utf8() }, "hash"),
	].all(|(bad, name)| AgentFiles.invite_from_files(invite_id("1"), bad) == Err(BadFact(name)))
}

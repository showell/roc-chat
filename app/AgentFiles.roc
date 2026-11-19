## This module keeps each agent's API keys and the invites that mint them
## on disk. It reads and writes them through `FileFacts`, and builds every
## path from the agent's id and the key's or invite's number, so no caller
## names a file.
##
## An agent's keys are kept in its account folder (`AccountFiles`) under
## `keys/<number>/` (`AgentKey`), and its invites under `invites/<number>/`
## (`AgentInvite`). A key and an invite have the same facts, one file each:
## `created`, `expires`, `read`, `post`, `state` and `hash`. Each is
## written one file at a time, each made once, its `hash` last, so a key or
## an invite cut short by a crash is never whole and admits no one.
import AccountFiles
import AccountFolder
import AgentInvite
import AgentKey
import FileFacts
import UserId

AgentFiles :: [].{

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
					match AgentKey.from_files(id, files) {
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
		record_facts(key.to_files()),
	)

	## A key's state, written over the one before, as `key` holds it.
	replace_agent_key_state! : UserId,
	AgentKey => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_agent_key_state! = |agent, key| FileFacts.replace_fact!(
		"${key_folder_path(agent, key.id())}/${state_fact}",
		key.to_files().state,
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
					match AgentInvite.from_files(id, files) {
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
		record_facts(invite.to_files()),
	)

	## An invite's state, written over the one before, as `invite` holds it.
	replace_agent_invite_state! : UserId,
	AgentInvite => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_agent_invite_state! = |agent, invite| FileFacts.replace_fact!(
		"${invite_folder_path(agent, invite.id())}/${state_fact}",
		invite.to_files().state,
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
## same files as its keys (`AgentInvite.Files` is this record too).
record_facts : AgentKey.Files -> List((Str, List(U8)))
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
read_record_facts! : Str => Try(AgentKey.Files, _)
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

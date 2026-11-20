## This module keeps each human's device keys (`DeviceKey`) on disk, in
## their account folder under `device-keys/<number>/`, and builds every
## path from the human's id and the key's number, so no caller names a
## file. A key is two facts, one file each: `created`, the second it was
## made (`FactFile`'s digits), and `state`, `active` or `revoked`.
##
## The write orders, as storage's rule asks (docs/design.md, "Storage"):
## a new key is written `created` then `state`, each made once, so a key a
## crash cut short has no state and admits no one; its number comes after
## every folder's there, a cut-short one's included, so none is given
## twice. A revoke rewrites `state` alone, atomically (a temporary file,
## then a rename), and only once that write has returned does the
## sign-out tell anyone the key is gone (`SignOutRoute`).
import AccountFiles
import AccountFolder
import DeviceKey
import FileFacts
import Timestamp
import UserId

DeviceKeyFiles :: [].{

	## A new key for the human `id`, made at `now`, active: the next number,
	## its `created`, then its `state` last; unless the folder holds the last
	## number already (`Full`), or a file fails.
	create_device_key! : UserId, Timestamp => Try(DeviceKey.Id, [Full, FileSystem(FileFacts.Fault)])
	create_device_key! = |id, now| {
		names = FileFacts.list_names_in!(keys_folder_path(id)) ? |fault| FileSystem(fault)
		key = DeviceKey.Id.next_after(names.keep_oks(DeviceKey.Id.from_str))?
		facts = [("created", now.to_file()), (state_fact, DeviceKey.state_to_file(Active))]
		FileFacts.create_facts!(key_folder_path(id, key), facts) ? |fault| FileSystem(fault)
		Ok(key)
	}

	## The state of the human `id`'s key `key`, or `NoKey` when it has no
	## `state` file (never made, or cut short); unless the file holds no
	## state (`Damaged`), or the host's read failed.
	read_device_key_state! : UserId, DeviceKey.Id => Try([NoKey, Key(DeviceKey.State)], [FileSystem(FileFacts.Fault)])
	read_device_key_state! = |id, key|
		match FileFacts.read_fact!(state_path(id, key)) {
			Ok(NoFile) => Ok(NoKey)
			Ok(File(bytes)) =>
				match DeviceKey.state_from_file(bytes) {
					Ok(state) => Ok(Key(state))
					Err(NotAState) => Err(FileSystem(Damaged))
				}
			Err(NotUtf8) => Err(FileSystem(NotUtf8))
			Err(PathRefused) => Err(FileSystem(PathRefused))
			Err(Failed) => Err(FileSystem(Failed))
		}

	## The human `id`'s key `key` revoked: its `state` rewritten whole,
	## atomically, so it never admits again; unless the host refused, and
	## then the file is as it was. A key with no folder is `Missing`.
	revoke_device_key! : UserId, DeviceKey.Id => Try({}, [FileSystem(FileFacts.Fault)])
	revoke_device_key! = |id, key|
		match FileFacts.replace_fact!(state_path(id, key), DeviceKey.state_to_file(Revoked)) {
			Ok({}) => Ok({})
			Err(MissingDirectory) => Err(FileSystem(Missing))
			Err(NotUtf8) => crash "DeviceKeyFiles.revoke_device_key!: a state's word is ASCII"
			Err(PathRefused) => Err(FileSystem(PathRefused))
			Err(Failed) => Err(FileSystem(Failed))
		}
}

## The fact file of a key's state.
state_fact : Str
state_fact = "state"

## The folder of the human `id`'s device keys.
keys_folder_path : UserId -> Str
keys_folder_path = |id| "${AccountFiles.account_folder_path(AccountFolder.of(id))}/device-keys"

## The folder of one of the human `id`'s device keys.
key_folder_path : UserId, DeviceKey.Id -> Str
key_folder_path = |id, key| "${keys_folder_path(id)}/${key.to_str()}"

## The `state` file of one of the human `id`'s device keys.
state_path : UserId, DeviceKey.Id -> Str
state_path = |id, key| "${key_folder_path(id, key)}/${state_fact}"

# ── tests
# The paths, under the accounts root.
expect {
	key = DeviceKey.Id.from_str("3") ?? crash "DeviceKeyFiles' tests: a key's number"
	keys_folder_path(UserId.chat_owner) == "auth/1/device-keys"
		and key_folder_path(UserId.chat_owner, key) == "auth/1/device-keys/3"
		and state_path(UserId.chat_owner, key) == "auth/1/device-keys/3/state"
}

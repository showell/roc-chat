## This module is the chat's only way to its files: the one module that
## calls the host's file primitives (platform/Host.roc). Each function turns
## domain values into a path and calls one or two primitives, so the chat's
## rules are here and the host's stay general.
##
## Callers never pass a path. A path is built here from a typed key
## (`ConversationKey`, whose parts are the layout's one home), so no caller
## can name a file outside the layout.
##
## The transcript's types are `Transcript`'s making. A read answers a whole
## `Utf8Transcript`, untrusted until `Transcript.decode` reads it, and an
## append takes one message's `Utf8TranscriptMessage`, which only
## `Transcript` makes.
##
## A file that may not exist yet is read as `NoFile` or `File(...)`. Every
## failure is named (`Fault`): `Missing` (no such file, for a read that
## needs one), `AlreadyExists` (a name taken), and the host's own, passed
## on as it said them (`NotUtf8`, `PathRefused`, `MissingDirectory`,
## `Failed`). Each function answers only the ones it can meet. Every one but `Missing` is a
## bug or a broken disk, and the caller answers it loudly, in `fault_words`.
##
## A conversation's uploaded images are kept in its folder, under
## `uploads/`, each by its own name (`UploadedImage`), as bytes.
##
## A user's own facts are kept in their folder (`UserFolder`), one small
## file per fact: their upload total (`UploadTotal`) is `upload-bytes`.
##
## Who a user is, and how they prove it, is kept apart under the auth root
## (`AccountFolder`): the counter
## of user ids, `auth/next-id.txt`, and each user's `auth/<id>/` (`Users`),
## with an agent's keys under `keys/<number>/` (`AgentKey`) and its invites
## under `invites/<number>/` (`AgentInvite`); an invited human's inviter in
## `inviter`, their invites under `human-invites/<number>/` (`HumanInvite`),
## their password's bcrypt hash in `password`, the GitHub account that may sign
## in as them in `github-id`, and what their sessions are signed over beside
## it in `github-session-secret`; one file per fact. A record
## of several files is written one file at a time, each made once, the
## file that makes it count written last. A channel's members are its file
## beside its folder of topics (`Channels`).
import pf.Host
import AccountFolder
import AgentInvite
import AgentKey
import ChannelName
import Channels
import ConversationKey
import Directory
import GitHubId
import HumanInvite
import Name
import Topic
import Transcript
import UploadTotal
import UnvalidatedString
import UploadedImage
import UserFolder
import UserId
import Users

FileSystem :: [].{

	## The files the directory is kept in, as read: the counter of user ids,
	## every account folder's, and every channel's members file.
	DirectoryFiles : {
		counter : [NoFile, File(List(U8))],
		accounts : List(Users.StoredAccount),
		channels : List(Channels.StoredChannel),
	}

	## Every failure a function here answers, as `fault_words` takes it.
	Fault : [
		Missing,
		AlreadyExists,
		NotUtf8,
		PathRefused,
		MissingDirectory,
		Failed,
	]

	## What the file system answered, in words for a refusal. The host's
	## log says which file, and why.
	fault_words : FileSystem.Fault -> Str
	fault_words = |fault| "The file system answered ${fault_name(fault)}."

	## A conversation's transcript, the whole file, unchecked, or `NoFile`
	## when there is none yet; unless the host's read failed.
	read_transcript! : ConversationKey => Try(
		[NoFile, File(Transcript.Utf8Transcript)],
		[
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	read_transcript! = |key| {
		read = Host.read_utf8_bytes_from_file!(transcript_path(key))
		match read.status {
			Found => Ok(File(Transcript.Utf8Transcript.unchecked_from_file(read.bytes)))
			Missing => Ok(NoFile)
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## One message's record, added at the end of its conversation's
	## transcript: the conversation's folder made as needed, then the record
	## appended (the file made when it is the first); unless the host
	## refused.
	append_message! : ConversationKey,
	Transcript.Utf8TranscriptMessage => Try(
		{},
		[
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	append_message! = |key, record| {
		make_folder!(folder_path(key))?
		match Host.append_utf8_bytes_to_file!(transcript_path(key), record.to_utf8_bytes()) {
			Appended => Ok({})
			MissingDirectory => Err(MissingDirectory)
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## An uploaded image's bytes, kept in its conversation's uploads folder
	## under its name, the folders made as needed; unless the host refused.
	## A name already there is `AlreadyExists`, and nothing is changed.
	store_uploaded_image! : ConversationKey,
	{ image : UploadedImage, bytes : List(U8) } => Try(
		{},
		[
			AlreadyExists,
			MissingDirectory,
			PathRefused,
			Failed,
		],
	)
	store_uploaded_image! = |key, { image, bytes }| {
		make_folder!(uploads_folder_path(key))?
		match Host.create_file_with_binary_bytes_unless_it_exists!(
			uploaded_image_path(key, image),
			bytes,
		) {
			Created => Ok({})
			AlreadyExists => Err(AlreadyExists)
			MissingDirectory => Err(MissingDirectory)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## An uploaded image's bytes, as kept; unless the conversation has no
	## image of its name (`Missing`), or the host's read failed.
	read_uploaded_image! : ConversationKey,
	UploadedImage => Try(
		List(U8),
		[
			Missing,
			PathRefused,
			Failed,
		],
	)
	read_uploaded_image! = |key, image| {
		read = Host.read_binary_bytes_from_file!(uploaded_image_path(key, image))
		match read.status {
			Found => Ok(read.bytes)
			Missing => Err(Missing)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## A user's upload total, as their folder keeps it, read by
	## `UploadTotal.from_file`; unless the host's read failed.
	read_upload_total! : UserFolder => Try(
		UploadTotal,
		[
			NotANumber,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	read_upload_total! = |folder| {
		read = Host.read_utf8_bytes_from_file!(upload_total_path(folder))
		match read.status {
			Found => UploadTotal.from_file(File(read.bytes))
			Missing => UploadTotal.from_file(NoFile)
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## A user's upload total, written whole over the one before, their folder
	## made as needed; unless the host refused, and then the file is as it
	## was.
	replace_upload_total! : UserFolder,
	UploadTotal => Try(
		{},
		[
			MissingDirectory,
			PathRefused,
			Failed,
		],
	)
	replace_upload_total! = |folder, total| {
		make_folder!(user_folder_path(folder))?
		match Host.replace_file_with_utf8_bytes_atomically!(
			upload_total_path(folder),
			total.to_file(),
		) {
			Replaced => Ok({})
			MissingDirectory => Err(MissingDirectory)
			NotUtf8 => crash "FileSystem.replace_upload_total!: a total's digits are UTF-8"
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## The files the directory is kept in, unchecked, for `Users.from_files`
	## and `Channels.from_files` to read: the counter of user ids (`NoFile`
	## before the first start), each account folder's facts (a folder whose
	## name is no id is not an account), and each
	## channel's members file. No auth root, or no folder of channels, holds
	## none. An account folder with no `name` is no account: it is one cut
	## short as it was made, and the counter of ids was advanced before it,
	## so its id is never given again.
	read_directory_files! : {} => Try(
		FileSystem.DirectoryFiles,
		[
			Missing,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	read_directory_files! = |{}| {
		counter = read_fact!(user_counter_path)?
		account_ids = list_names_in!(AccountFolder.auth_root)?.keep_oks(UserId.from_str)
		var $accounts = []
		for id in account_ids {
			folder = account_folder_path(AccountFolder.of(id))
			match read_fact!("${folder}/name")? {
				NoFile => {}
				File(name) => {
					owner = read_fact!("${folder}/owner")?
					$accounts = $accounts.append({ id, files: { name, owner } })
				}
			}
		}
		channel_names = list_names_in!(channels_folder_path)?.keep_oks(
			|file_name|
				if (file_name.ends_with(channel_members_suffix))
					ChannelName.from_str(file_name.drop_suffix(channel_members_suffix))
				else
					Err(NotAMembersFile),
		)
		var $channels = []
		for name in channel_names {
			members = read_needed_fact!(channel_members_path(name))?
			$channels = $channels.append({ name, members })
		}
		Ok({
			counter,
			accounts: $accounts,
			channels: $channels,
		})
	}

	## A new user's account folder, made once: an agent's `owner`, then the
	## `name`, whose file makes the folder an account. The counter of ids is
	## the caller's to advance first (`replace_user_counter!`), so an id is
	## never given twice.
	create_account! : Users.User => Try(
		{},
		[
			AlreadyExists,
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	create_account! = |user| {
		files = Users.account_files(user)
		owner_fact =
			match files.owner {
				NoFile => []
				File(bytes) => [("owner", bytes)]
			}
		folder = account_folder_path(AccountFolder.of(user.id()))
		create_facts!(folder, owner_fact.append(("name", files.name)))
	}

	## A new invited human's account folder, made once: the id of the human
	## who invited them, `inviter`, then the `name`, whose file makes the
	## folder an account. The counter of ids is the caller's to advance
	## first, as for any account.
	create_invited_account! : { human : Users.User, inviter : UserId } => Try(
		{},
		[
			AlreadyExists,
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	create_invited_account! = |{ human, inviter }| {
		files = Users.account_files(human)
		folder = account_folder_path(AccountFolder.of(human.id()))
		create_facts!(
			folder,
			[
				("inviter", inviter.to_str().to_utf8()),
				("name", files.name),
			],
		)
	}

	## A new human's account folder, made once as they sign up with GitHub:
	## the GitHub account that signs them in, `github-id`, then the `name`,
	## whose file makes the folder an account, so one cut short binds no one.
	## The counter of ids is the caller's to advance first, as for any account.
	create_github_account! : { human : Users.User, github : GitHubId } => Try(
		{},
		[
			AlreadyExists,
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	create_github_account! = |{ human, github }| {
		files = Users.account_files(human)
		folder = account_folder_path(AccountFolder.of(human.id()))
		create_facts!(
			folder,
			[
				("github-id", github.to_str().to_utf8()),
				("name", files.name),
			],
		)
	}

	## The user's `name` file written whole over the one before, atomically:
	## the name an invited human chose as they joined.
	replace_account_name! : Users.User => Try(
		{},
		[
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	replace_account_name! = |user|
		replace_fact!(
			"${account_folder_path(AccountFolder.of(user.id()))}/name",
			Users.account_files(user).name,
		)

	## The `inviter` file of the human `id`, as it is, or `NoFile` when they
	## have none; unless the host's read failed.
	read_inviter_file! : UserId => Try([NoFile, File(List(U8))], [NotUtf8, PathRefused, Failed])
	read_inviter_file! = |id| read_fact!("${account_folder_path(AccountFolder.of(id))}/inviter")

	## The human `id`'s password's bcrypt hash written whole over the one
	## before, atomically: a redeemed invite's choice. The hash is the
	## host's (`Host.bcrypt_hash_of_password!`); the password is never kept.
	replace_password_hash! : UserId,
	List(U8) => Try(
		{},
		[
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	replace_password_hash! = |id, hash| replace_fact!(password_path(id), hash)

	## The invites in the human `human`'s account folder, each whole; one cut
	## short or damaged is left out, as an agent's is.
	read_human_invites! : UserId => Try(List(HumanInvite), [NotUtf8, PathRefused, Failed])
	read_human_invites! = |human| {
		ids = list_names_in!(human_invites_folder_path(human))?.keep_oks(HumanInvite.Id.from_str)
		var $invites = []
		for id in ids {
			match read_human_invite_facts!(human_invite_folder_path(human, id)) {
				Ok(files) =>
					match HumanInvite.from_files(id, files) {
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

	## The number the next invite of the human `human` will have: after every
	## invite folder's, one cut short included, so no number is given twice.
	find_next_human_invite_id! : UserId => Try(HumanInvite.Id, [Full, NotUtf8, PathRefused, Failed])
	find_next_human_invite_id! = |human| {
		ids = list_names_in!(human_invites_folder_path(human))?.keep_oks(HumanInvite.Id.from_str)
		HumanInvite.Id.next_after(ids)
	}

	## A new invite in the human `human`'s account folder, made once, its
	## hash last.
	create_human_invite! : UserId,
	HumanInvite => Try(
		{},
		[
			AlreadyExists,
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	create_human_invite! = |human, invite| {
		files = invite.to_files()
		create_facts!(
			human_invite_folder_path(human, invite.id()),
			[
				("created", files.created),
				("expires", files.expires),
				("by", files.by),
				("state", files.state),
				("hash", files.hash),
			],
		)
	}

	## A human invite's state, written over the one before, as `invite`
	## holds it.
	replace_human_invite_state! : UserId,
	HumanInvite => Try(
		{},
		[
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	replace_human_invite_state! = |human, invite| replace_fact!(
		"${human_invite_folder_path(human, invite.id())}/state",
		invite.to_files().state,
	)

	## The bcrypt hash of the user `id`'s password, as its file keeps it,
	## or `NoFile` when they have none; unless the host's read failed. Only
	## the hash is ever kept, and the server's owner writes it
	## (docs/design.md, "Storage").
	read_password_hash! : UserId => Try([NoFile, File(List(U8))], [NotUtf8, PathRefused, Failed])
	read_password_hash! = |id| read_fact!(password_path(id))

	## The `github-id` file of each account folder that has one, as it is
	## (docs/design.md, "Storage"). It lists the folders rather than taking a
	## `Users`, as a human can sign up while the host waits on GitHub, and a
	## `Users` read before that wait doesn't hold them.
	read_github_id_files! : {} => Try(
		List({ user : UserId, file : List(U8) }),
		[NotUtf8, PathRefused, Failed],
	)
	read_github_id_files! = |{}| {
		ids = list_names_in!(AccountFolder.auth_root)?.keep_oks(UserId.from_str)
		var $files = []
		for id in ids {
			match FileSystem.read_github_id_file!(id)? {
				NoFile => {}
				File(file) => {
					$files = $files.append({ user: id, file })
				}
			}
		}
		Ok($files)
	}

	## The user `id`'s `github-id` file, as it is, or `NoFile`; unless the
	## host's read failed.
	read_github_id_file! : UserId => Try([NoFile, File(List(U8))], [NotUtf8, PathRefused, Failed])
	read_github_id_file! = |id| read_fact!("${account_folder_path(AccountFolder.of(id))}/github-id")

	## The user `id`'s `github-session-secret` file, as it is, or `NoFile`;
	## unless the host's read failed.
	read_github_session_secret! : UserId => Try(
		[NoFile, File(List(U8))],
		[NotUtf8, PathRefused, Failed],
	)
	read_github_session_secret! = |id| read_fact!(github_session_secret_path(id))

	## The user `id`'s `github-session-secret` file made holding `bytes`, once;
	## `AlreadyExists`, nothing changed, when it is there.
	create_github_session_secret! : UserId,
	List(U8) => Try(
		{},
		[
			AlreadyExists,
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	create_github_session_secret! = |id, bytes| create_fact!(github_session_secret_path(id), bytes)

	## The user `id`'s `github-session-secret` file written whole over any
	## before it, atomically.
	replace_github_session_secret! : UserId,
	List(U8) => Try(
		{},
		[
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	replace_github_session_secret! = |id, bytes|
		replace_fact!(github_session_secret_path(id), bytes)

	## The human `id`'s `github-id` file made holding `github`, once;
	## `AlreadyExists`, nothing changed, when it is there.
	create_github_id! : UserId,
	GitHubId => Try(
		{},
		[
			AlreadyExists,
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	create_github_id! = |id, github|
		create_fact!("${account_folder_path(AccountFolder.of(id))}/github-id", github.to_str().to_utf8())

	## The counter of user ids, written whole as `users` holds it.
	replace_user_counter! : Users => Try({}, [MissingDirectory, NotUtf8, PathRefused, Failed])
	replace_user_counter! = |users| {
		make_folder!(AccountFolder.auth_root)?
		replace_fact!(user_counter_path, users.counter_file())
	}

	## A channel's members file, written whole as `channel` holds them.
	replace_channel_members! : Channels.Channel => Try(
		{},
		[
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	replace_channel_members! = |channel| {
		make_folder!(channels_folder_path)?
		replace_fact!(channel_members_path(channel.name()), channel.members_file())
	}

	## The topics of the channel `name`'s conversations, by its folders; a
	## folder whose name is no topic is left out. A channel with no
	## conversation yet has none.
	list_channel_topics! : ChannelName => Try(List(Topic), [NotUtf8, PathRefused, Failed])
	list_channel_topics! = |name| {
		names = list_names_in!(channel_folder_path(name))?
		Ok(names.keep_oks(Topic.from_str))
	}

	## The keys in `agent`'s account folder, each whole. A key whose files
	## are not all there, or don't each hold their fact, is left out: it
	## admits no one, and fails only itself.
	read_agent_keys! : UserId => Try(List(AgentKey), [NotUtf8, PathRefused, Failed])
	read_agent_keys! = |agent| {
		ids = list_names_in!(keys_folder_path(agent))?.keep_oks(AgentKey.Id.from_str)
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
	find_next_agent_key_id! : UserId => Try(AgentKey.Id, [Full, NotUtf8, PathRefused, Failed])
	find_next_agent_key_id! = |agent| {
		ids = list_names_in!(keys_folder_path(agent))?.keep_oks(AgentKey.Id.from_str)
		AgentKey.Id.next_after(ids)
	}

	## The number the next invite of `agent`'s will have, as a key's is.
	find_next_agent_invite_id! : UserId => Try(AgentInvite.Id, [Full, NotUtf8, PathRefused, Failed])
	find_next_agent_invite_id! = |agent| {
		ids = list_names_in!(invites_folder_path(agent))?.keep_oks(AgentInvite.Id.from_str)
		AgentInvite.Id.next_after(ids)
	}

	## A new key in `agent`'s account folder, made once, its hash last.
	create_agent_key! : UserId,
	AgentKey => Try(
		{},
		[
			AlreadyExists,
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	create_agent_key! = |agent, key| create_facts!(
		key_folder_path(agent, key.id()),
		record_facts(key.to_files()),
	)

	## A key's state, written over the one before, as `key` holds it.
	replace_agent_key_state! : UserId,
	AgentKey => Try(
		{},
		[
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	replace_agent_key_state! = |agent, key| replace_fact!(
		"${key_folder_path(agent, key.id())}/state",
		key.to_files().state,
	)

	## The invites in `agent`'s account folder, each whole; one cut short
	## or damaged is left out, as a key is.
	read_agent_invites! : UserId => Try(List(AgentInvite), [NotUtf8, PathRefused, Failed])
	read_agent_invites! = |agent| {
		ids = list_names_in!(invites_folder_path(agent))?.keep_oks(AgentInvite.Id.from_str)
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
		[
			AlreadyExists,
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	create_agent_invite! = |agent, invite| create_facts!(
		invite_folder_path(agent, invite.id()),
		record_facts(invite.to_files()),
	)

	## An invite's state, written over the one before, as `invite` holds it.
	replace_agent_invite_state! : UserId,
	AgentInvite => Try(
		{},
		[
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	replace_agent_invite_state! = |agent, invite| replace_fact!(
		"${invite_folder_path(agent, invite.id())}/state",
		invite.to_files().state,
	)
}

## A fact file's bytes, or `NoFile` when there is none; unless the host's
## read failed.
read_fact! : Str => Try([NoFile, File(List(U8))], [NotUtf8, PathRefused, Failed])
read_fact! = |path| {
	read = Host.read_utf8_bytes_from_file!(path.to_utf8())
	match read.status {
		Found => Ok(File(read.bytes))
		Missing => Ok(NoFile)
		NotUtf8 => Err(NotUtf8)
		PathRefused => Err(PathRefused)
		Failed => Err(Failed)
	}
}

## A fact file a record needs: its bytes, or `Missing`.
read_needed_fact! : Str => Try(List(U8), _)
read_needed_fact! = |path|
	match read_fact!(path)? {
		File(bytes) => Ok(bytes)
		NoFile => Err(Missing)
	}

## The names in the folder `path`, as text, or none when there is no such
## folder.
list_names_in! : Str => Try(List(Str), [NotUtf8, PathRefused, Failed])
list_names_in! = |path| {
	listed = Host.list_names_in_directory!(path.to_utf8())
	match listed.status {
		Found => Ok(listed.names.keep_oks(|name| Str.from_utf8(name)))
		Missing => Ok([])
		NotUtf8 => Err(NotUtf8)
		PathRefused => Err(PathRefused)
		Failed => Err(Failed)
	}
}

## A fact file made holding `bytes`, once: one already there is
## `AlreadyExists`, and nothing is changed.
create_fact! : Str, List(U8) => Try({}, _)
create_fact! = |path, bytes|
	match Host.create_file_with_utf8_bytes_unless_it_exists!(path.to_utf8(), bytes) {
		Created => Ok({})
		AlreadyExists => Err(AlreadyExists)
		MissingDirectory => Err(MissingDirectory)
		NotUtf8 => Err(NotUtf8)
		PathRefused => Err(PathRefused)
		Failed => Err(Failed)
	}

## A fact file written whole over the one before, atomically.
replace_fact! : Str, List(U8) => Try({}, [MissingDirectory, NotUtf8, PathRefused, Failed])
replace_fact! = |path, bytes|
	match Host.replace_file_with_utf8_bytes_atomically!(path.to_utf8(), bytes) {
		Replaced => Ok({})
		MissingDirectory => Err(MissingDirectory)
		NotUtf8 => Err(NotUtf8)
		PathRefused => Err(PathRefused)
		Failed => Err(Failed)
	}

## Each of `facts`, a name and its bytes, made once in the folder `folder`,
## in order, the folder made first; stopping at the first that fails.
create_facts! : Str, List((Str, List(U8))) => Try({}, _)
create_facts! = |folder, facts| {
	make_folder!(folder)?
	create_facts_from!({ folder, facts })
}

create_facts_from! : { folder : Str, facts : List((Str, List(U8))) } => Try({}, _)
create_facts_from! = |{ folder, facts }|
	match facts {
		[] => Ok({})
		[(name, bytes), .. as rest] => {
			create_fact!("${folder}/${name}", bytes)?
			create_facts_from!({ folder, facts: rest })
		}
	}

## The account folder's path.
account_folder_path : AccountFolder -> Str
account_folder_path = |folder| Str.join_with(folder.parts(), "/")

## The path of the user `id`'s password's hash.
password_path : UserId -> Str
password_path = |id| "${account_folder_path(AccountFolder.of(id))}/password"

## The path of what the user `id`'s sessions are signed over beside their
## password's hash, once they have signed in with GitHub.
github_session_secret_path : UserId -> Str
github_session_secret_path = |id|
	"${account_folder_path(AccountFolder.of(id))}/github-session-secret"

## The path of the counter of user ids.
user_counter_path : Str
user_counter_path = "${AccountFolder.auth_root}/next-id.txt"

## The folder of an agent's keys.
keys_folder_path : UserId -> Str
keys_folder_path = |agent| "${account_folder_path(AccountFolder.of(agent))}/keys"

## The folder of one of an agent's keys.
key_folder_path : UserId, AgentKey.Id -> Str
key_folder_path = |agent, id| "${keys_folder_path(agent)}/${id.to_str()}"

## The folder of an agent's invites.
invites_folder_path : UserId -> Str
invites_folder_path = |agent| "${account_folder_path(AccountFolder.of(agent))}/invites"

## The folder of one of an agent's invites.
invite_folder_path : UserId, AgentInvite.Id -> Str
invite_folder_path = |agent, id| "${invites_folder_path(agent)}/${id.to_str()}"

## The folder of a human's invites.
human_invites_folder_path : UserId -> Str
human_invites_folder_path = |human| "${account_folder_path(AccountFolder.of(human))}/human-invites"

## The folder of one of a human's invites.
human_invite_folder_path : UserId, HumanInvite.Id -> Str
human_invite_folder_path = |human, id| "${human_invites_folder_path(human)}/${id.to_str()}"

## The fact files of the human invite in `folder`; unless one is missing or
## the host's read failed.
read_human_invite_facts! : Str => Try(HumanInvite.Files, _)
read_human_invite_facts! = |folder| {
	hash = read_needed_fact!("${folder}/hash")?
	created = read_needed_fact!("${folder}/created")?
	expires = read_needed_fact!("${folder}/expires")?
	state = read_needed_fact!("${folder}/state")?
	by = read_needed_fact!("${folder}/by")?
	Ok({
		created,
		expires,
		state,
		by,
		hash,
	})
}

## The folder of the channels: what holds each channel's folder and its
## members file.
channels_folder_path : Str
channels_folder_path = Str.join_with(ConversationKey.channels_folder_parts, "/")

## The channel `name`'s folder, which holds its conversations' folders.
channel_folder_path : ChannelName -> Str
channel_folder_path = |name| Str.join_with(ConversationKey.channel_folder_parts(name), "/")

## The channel `name`'s members file, beside its folder.
channel_members_path : ChannelName -> Str
channel_members_path = |name| "${channel_folder_path(name)}${channel_members_suffix}"

channel_members_suffix : Str
channel_members_suffix = ".channel"

## The fact files of a key or an invite, in the order they are written: the
## hash last, so a record cut short is never whole.
record_facts : {
	created : List(U8),
	expires : List(U8),
	state : List(U8),
	read : List(U8),
	post : List(U8),
	hash : List(U8),
} -> List((Str, List(U8)))
record_facts = |files| [
	("created", files.created),
	("expires", files.expires),
	("read", files.read),
	("post", files.post),
	("state", files.state),
	("hash", files.hash),
]

## The fact files of the record in `folder`; unless one is missing or the
## host's read failed.
read_record_facts! : Str => Try(
	{
		created : List(U8),
		expires : List(U8),
		state : List(U8),
		read : List(U8),
		post : List(U8),
		hash : List(U8),
	},
	_,
)
read_record_facts! = |folder| {
	hash = read_needed_fact!("${folder}/hash")?
	created = read_needed_fact!("${folder}/created")?
	expires = read_needed_fact!("${folder}/expires")?
	state = read_needed_fact!("${folder}/state")?
	read = read_needed_fact!("${folder}/read")?
	post = read_needed_fact!("${folder}/post")?
	Ok({
		created,
		expires,
		state,
		read,
		post,
		hash,
	})
}

## A user's folder: its parts.
user_folder_path : UserFolder -> Str
user_folder_path = |folder| Str.join_with(folder.parts(), "/")

## The path of a user's upload total.
upload_total_path : UserFolder -> List(U8)
upload_total_path = |folder| "${user_folder_path(folder)}/upload-bytes".to_utf8()

## The folder a conversation's uploaded images are kept in.
uploads_folder_path : ConversationKey -> Str
uploads_folder_path = |key| "${folder_path(key)}/uploads"

## The path of an uploaded image of the conversation.
uploaded_image_path : ConversationKey, UploadedImage -> List(U8)
uploaded_image_path = |key, image| "${uploads_folder_path(key)}/${image.name()}".to_utf8()

## A conversation's folder: its key's parts. Its transcript is the file
## `transcript` in it.
folder_path : ConversationKey -> Str
folder_path = |key| Str.join_with(key.parts(), "/")

## The path of the conversation's transcript.
transcript_path : ConversationKey -> List(U8)
transcript_path = |key| "${folder_path(key)}/transcript".to_utf8()

## The folder `path`, and those above it, made as needed.
make_folder! : Str => Try({}, [PathRefused, Failed])
make_folder! = |path|
	match Host.make_directory_and_its_parents!(path.to_utf8()) {
		Made => Ok({})
		PathRefused => Err(PathRefused)
		Failed => Err(Failed)
	}

## A fault, by its tag's name.
fault_name : FileSystem.Fault -> Str
fault_name = |fault|
	match fault {
		Missing => "Missing"
		AlreadyExists => "AlreadyExists"
		NotUtf8 => "NotUtf8"
		PathRefused => "PathRefused"
		MissingDirectory => "MissingDirectory"
		Failed => "Failed"
	}

# ── tests
# The paths each builder makes, under the auth root, the users' folders
# and a conversation's folder.
## The key of `path`, a conversation's URL path, in the first start's
## directory.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8())
		?? crash "FileSystem's tests: a path is UTF-8",
	directory: Directory.with_founder(Name.from_str("Steve") ?? crash "FileSystem's tests: a name"),
}).map_ok(|found| found.key) ?? crash "FileSystem's tests: a conversation's path"

expect account_folder_path(AccountFolder.of(UserId.chat_owner)) == "auth/1"
expect password_path(UserId.chat_owner) == "auth/1/password"
expect github_session_secret_path(UserId.chat_owner) == "auth/1/github-session-secret"
expect user_counter_path == "auth/next-id.txt"
expect {
	agent = UserId.from_str("12") ?? crash "FileSystem's tests: an id"
	key = AgentKey.Id.from_str("3") ?? crash "FileSystem's tests: a key's number"
	invite = AgentInvite.Id.from_str("4") ?? crash "FileSystem's tests: an invite's number"
	keys_folder_path(agent) == "auth/12/keys"
		and key_folder_path(agent, key) == "auth/12/keys/3"
		and invites_folder_path(agent) == "auth/12/invites"
		and invite_folder_path(agent, invite) == "auth/12/invites/4"
}
expect {
	human = UserId.from_str("7") ?? crash "FileSystem's tests: an id"
	invite = HumanInvite.Id.from_str("2") ?? crash "FileSystem's tests: an invite's number"
	human_invites_folder_path(human) == "auth/7/human-invites" and human_invite_folder_path(
		human,
		invite,
	) == "auth/7/human-invites/2"
}
expect channels_folder_path == "chat/channel"
expect {
	general = ChannelName.from_str("general") ?? crash "FileSystem's tests: a channel's name"
	channel_folder_path(general)
		== "chat/channel/general" and channel_members_path(general)
		== "chat/channel/general.channel"
}
expect user_folder_path(UserFolder.of(UserId.chat_owner)) == "users/1"
expect upload_total_path(UserFolder.of(UserId.chat_owner)) == "users/1/upload-bytes".to_utf8()
expect {
	key = key_at("/chat/dm/1_1/plans")
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png")
			?? crash "FileSystem's tests: an image's name"
	folder_path(key) == "chat/dm/1_1/plans"
		and transcript_path(key) == "chat/dm/1_1/plans/transcript".to_utf8()
		and uploads_folder_path(key) == "chat/dm/1_1/plans/uploads"
		and uploaded_image_path(
			key,
			image,
		) == "chat/dm/1_1/plans/uploads/${"0a".repeat(16)}.png".to_utf8()
}
# Every fault, in words.
expect
	[
		(Missing, "Missing"),
		(AlreadyExists, "AlreadyExists"),
		(NotUtf8, "NotUtf8"),
		(PathRefused, "PathRefused"),
		(MissingDirectory, "MissingDirectory"),
		(Failed, "Failed"),
	].all(|(fault, name)| FileSystem.fault_words(fault) == "The file system answered ${name}.")

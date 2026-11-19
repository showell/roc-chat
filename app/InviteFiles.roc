## This module keeps the invites a human makes for other humans on disk. It
## reads and writes them through `FileFacts`, and builds every path from
## the inviting human's id and the invite's number, so no caller names a
## file.
##
## A human's invites are kept in their account folder (`AccountFiles`),
## under `human-invites/<number>/` (`HumanInvite`), one file per fact:
## `created`, `expires`, `by`, `state` and `hash`. An invite is written one
## file at a time, each made once, its `hash` last, so an invite cut short
## by a crash is never whole and admits no one.
import AccountFiles
import AccountFolder
import FileFacts
import HumanInvite
import UserId

InviteFiles :: [].{

	## The invites in the human `human`'s account folder, each whole; one cut
	## short or damaged is left out, as an agent's is.
	read_human_invites! : UserId => Try(List(HumanInvite), [NotUtf8, PathRefused, Failed])
	read_human_invites! = |human| {
		names = FileFacts.list_names_in!(human_invites_folder_path(human))?
		ids = names.keep_oks(HumanInvite.Id.from_str)
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
	find_next_human_invite_id! : UserId => Try(HumanInvite.Id, [Full, FileSystem(FileFacts.Fault)])
	find_next_human_invite_id! = |human| {
		folder = human_invites_folder_path(human)
		names = FileFacts.list_names_in!(folder) ? |fault| FileSystem(fault)
		HumanInvite.Id.next_after(names.keep_oks(HumanInvite.Id.from_str))
	}

	## A new invite in the human `human`'s account folder, made once, its
	## hash last.
	create_human_invite! : UserId,
	HumanInvite => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_human_invite! = |human, invite| {
		files = invite.to_files()
		FileFacts.create_facts!(
			human_invite_folder_path(human, invite.id()),
			[
				("created", files.created),
				("expires", files.expires),
				("by", files.by),
				(state_fact, files.state),
				("hash", files.hash),
			],
		)
	}

	## A human invite's state, written over the one before, as `invite`
	## holds it.
	replace_human_invite_state! : UserId,
	HumanInvite => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_human_invite_state! = |human, invite| FileFacts.replace_fact!(
		"${human_invite_folder_path(human, invite.id())}/${state_fact}",
		invite.to_files().state,
	)
}

## The fact file of an invite's state.
state_fact : Str
state_fact = "state"

## The folder of a human's invites.
human_invites_folder_path : UserId -> Str
human_invites_folder_path = |human| "${AccountFiles.account_folder_path(AccountFolder.of(human))}/human-invites"

## The folder of one of a human's invites.
human_invite_folder_path : UserId, HumanInvite.Id -> Str
human_invite_folder_path = |human, id| "${human_invites_folder_path(human)}/${id.to_str()}"

## The fact files of the human invite in `folder`; unless one is missing or
## the host's read failed.
read_human_invite_facts! : Str => Try(HumanInvite.Files, _)
read_human_invite_facts! = |folder| {
	hash = FileFacts.read_needed_fact!("${folder}/hash")?
	created = FileFacts.read_needed_fact!("${folder}/created")?
	expires = FileFacts.read_needed_fact!("${folder}/expires")?
	state = FileFacts.read_needed_fact!("${folder}/${state_fact}")?
	by = FileFacts.read_needed_fact!("${folder}/by")?
	Ok({ created, expires, state, by, hash })
}

# ── tests
# The paths each builder makes, under the auth root.
expect {
	human = UserId.from_str("7") ?? crash "InviteFiles' tests: an id"
	invite = HumanInvite.Id.from_str("2") ?? crash "InviteFiles' tests: an invite's number"
	human_invites_folder_path(human) == "auth/7/human-invites" and human_invite_folder_path(
		human,
		invite,
	) == "auth/7/human-invites/2"
}

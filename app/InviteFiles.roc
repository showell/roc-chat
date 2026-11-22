## This module keeps the invites a human makes for other humans on disk. It
## reads and writes them through `FileFacts`, and builds every path from
## the inviting human's id and the invite's number, so no caller names a
## file.
##
## A human's invites are kept in their account folder (`AccountFiles`),
## under `human-invites/<number>/` (`HumanInvite`), one file per fact
## (`HumanInviteFiles`): `created` and `expires` (seconds since the epoch),
## `state` (`live` or `spent`), `by` (the id of the human who made it) and
## `hash` (the code's hash). An invite is written one
## file at a time, each made once, its `hash` last, so an invite cut short
## by a crash is never whole and admits no one.
import AccountFiles
import AccountFolder
import FactFile
import FileFacts
import HumanClaim
import HumanInvite
import SecretHash
import Timestamp
import UserId

InviteFiles :: [].{

	## A human invite's facts as their files hold them, one file each.
	HumanInviteFiles : {
		created : List(U8),
		expires : List(U8),
		state : List(U8),
		by : List(U8),
		hash : List(U8),
	}

	## The invite's facts as their files keep them.
	human_invite_files : HumanInvite -> InviteFiles.HumanInviteFiles
	human_invite_files = |invite| {
		facts = invite.to_facts()
		{
			created: facts.created.to_file(),
			expires: facts.expires.to_file(),
			state: state_word(facts.state),
			by: facts.by.to_file(),
			hash: facts.hash.to_file(),
		}
	}

	## The invite numbered `id` whose facts `files` hold; unless one of them
	## holds no such fact (`BadFact`, naming the file).
	human_invite_from_files : HumanInvite.Id,
	InviteFiles.HumanInviteFiles -> Try(
		HumanInvite,
		[BadFact(Str)],
	)
	human_invite_from_files = |id, files| {
		created = Timestamp.from_file(files.created) ? |_| BadFact("created")
		expires = Timestamp.from_file(files.expires) ? |_| BadFact("expires")
		state = state_from_word(files.state) ? |_| BadFact("state")
		by = UserId.from_file(files.by) ? |_| BadFact("by")
		hash = SecretHash.from_file(files.hash) ? |_| BadFact("hash")
		Ok(HumanInvite.from_facts(id, { created, expires, state, by, hash }))
	}

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
					match InviteFiles.human_invite_from_files(id, files) {
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

	## A new invite in the account folder of `unclaimed`, a human who has
	## claimed nothing (`HumanClaim`), made once, its hash last.
	create_human_invite! : HumanClaim.Unclaimed,
	HumanInvite => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_human_invite! = |unclaimed, invite| {
		files = InviteFiles.human_invite_files(invite)
		FileFacts.create_facts!(
			human_invite_folder_path(unclaimed.human().id(), invite.id()),
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
		state_word(invite.state()),
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
read_human_invite_facts! : Str => Try(InviteFiles.HumanInviteFiles, _)
read_human_invite_facts! = |folder| {
	hash = FileFacts.read_needed_fact!("${folder}/hash")?
	created = FileFacts.read_needed_fact!("${folder}/created")?
	expires = FileFacts.read_needed_fact!("${folder}/expires")?
	state = FileFacts.read_needed_fact!("${folder}/${state_fact}")?
	by = FileFacts.read_needed_fact!("${folder}/by")?
	Ok({ created, expires, state, by, hash })
}

## An invite's state, as its `state` file holds it.
state_word : HumanInvite.State -> List(U8)
state_word = |state|
	match state {
		Live => "live".to_utf8()
		Spent => "spent".to_utf8()
	}

## The state an invite's `state` file holds; unless it holds none.
state_from_word : List(U8) -> Try(HumanInvite.State, [NotAState])
state_from_word = |bytes| {
	word = FactFile.word_from_file(bytes)
	if word == "live".to_utf8() {
		Ok(Live)
	} else if word == "spent".to_utf8() {
		Ok(Spent)
	} else {
		Err(NotAState)
	}
}

# ── tests
# The paths each builder makes, under the accounts root.
expect {
	human = UserId.from_str("7") ?? crash "InviteFiles' tests: an id"
	invite = HumanInvite.Id.from_str("2") ?? crash "InviteFiles' tests: an invite's number"
	human_invites_folder_path(human) == "auth/7/human-invites" and human_invite_folder_path(
		human,
		invite,
	) == "auth/7/human-invites/2"
}

## Zoe's invite numbered `number`, made by `by` at 1000, its code's hash
## every byte `number`.
invite_made : { number : U32, by : Str } -> HumanInvite
invite_made = |{ number, by }|
	HumanInvite.make({
		id: HumanInvite.Id.from_str(number.to_str()) ?? crash "InviteFiles' tests: an invite's number",
		hash: SecretHash.of_digest(List.repeat(number.to_u8_wrap(), 32)),
		now: Timestamp.at_second(1000),
		by: UserId.from_str(by) ?? crash "InviteFiles' tests: an id",
	})

# Its facts to their files and back; each fact that holds no such fact
# refused, naming its file.
expect {
	made = invite_made({ number: 3, by: "2" })
	files = InviteFiles.human_invite_files(made)
	files.by == "2".to_utf8()
		and files.state == "live".to_utf8()
		and files.created == "1000".to_utf8()
		and InviteFiles.human_invite_from_files(made.id(), files) == Ok(made)
}
expect {
	made = invite_made({ number: 3, by: "2" })
	files = InviteFiles.human_invite_files(made)
	[
		({ ..files, created: "x".to_utf8() }, "created"),
		({ ..files, expires: "".to_utf8() }, "expires"),
		({ ..files, state: "revoked".to_utf8() }, "state"),
		({ ..files, by: "0".to_utf8() }, "by"),
		({ ..files, hash: "00".to_utf8() }, "hash"),
	].all(
		|(bad, fact)|
			InviteFiles.human_invite_from_files(
				made.id(),
				bad,
			).map_ok(|_| {}) == Err(BadFact(fact)),
	)
}

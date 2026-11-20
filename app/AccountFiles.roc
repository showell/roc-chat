## This module keeps who each user is, and how they prove it, on disk: the
## counter of user ids, each user's account folder, their password's hash,
## their GitHub link and what their sessions are signed over. It reads and
## writes them through `FileFacts`, and builds every path from a typed key,
## so no caller names a file.
##
## They are kept apart from the users' own folders, under the accounts root
## (`AccountFolder`): the counter of user ids, `auth/next-id.txt`, and each
## user's `auth/<id>/` (`Users`), one file per fact. An agent's `owner` and
## an invited human's `inviter` hold a user's id; `name` holds the user's
## name, and its file, written last, makes the folder an account. A human's
## password's bcrypt hash is in `password`, the GitHub account that may sign
## in as them in `github-id`, and what their sessions are signed over beside
## it in `github-session-secret`. An agent's keys and invites
## (`AgentFiles`) and a human's invites (`InviteFiles`) are folders inside
## the account folder, which `account_folder_path` names for them.
import AccountFolder
import FactFile
import FileFacts
import GitHubId
import GitHubSessionWord
import PasswordHash
import UserId
import Users

AccountFiles :: [].{

	## The account folder's path.
	account_folder_path : AccountFolder -> Str
	account_folder_path = |folder| Str.join_with(folder.parts(), "/")

	## The counter of user ids, as its file holds it, or `NoFile` before the
	## first start; unless the host's read failed.
	read_user_counter! : {} => Try([NoFile, File(List(U8))], [NotUtf8, PathRefused, Failed])
	read_user_counter! = |{}| FileFacts.read_fact!(user_counter_path)

	## Each account folder's facts, unchecked, for `Users.from_stored` to
	## read: a folder whose name is no id is not an account, and no accounts root
	## holds none. An account folder with no `name` is no account: it is one
	## cut short as it was made, and the counter of ids was advanced before
	## it, so its id is never given again.
	read_accounts! : {} => Try(List(Users.AccountFacts), [NotUtf8, PathRefused, Failed])
	read_accounts! = |{}| {
		account_ids =
			FileFacts.list_names_in!(AccountFolder.accounts_root)?.keep_oks(UserId.from_str)
		var $accounts = []
		for id in account_ids {
			folder = AccountFiles.account_folder_path(AccountFolder.of(id))
			match FileFacts.read_fact!("${folder}/${name_fact}")? {
				NoFile => {}
				File(name) => {
					owner =
						match FileFacts.read_fact!("${folder}/owner")? {
							NoFile => NoOwner
							File(bytes) => Owner(bytes)
						}
					$accounts = $accounts.append({ id, name, owner })
				}
			}
		}
		Ok($accounts)
	}

	## A new user's account folder, made once: an agent's `owner`, then the
	## `name`, whose file makes the folder an account. The counter of ids is
	## the caller's to advance first (`replace_user_counter!`), so an id is
	## never given twice.
	create_account! : Users.User => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_account! = |user| {
		facts = Users.account_facts(user)
		owner_fact =
			match facts.owner {
				NoOwner => []
				Owner(bytes) => [("owner", bytes)]
			}
		folder = AccountFiles.account_folder_path(AccountFolder.of(user.id()))
		FileFacts.create_facts!(folder, owner_fact.append((name_fact, facts.name)))
	}

	## A new invited human's account folder, made once: the id of the human
	## who invited them, `inviter`, then the `name`, whose file makes the
	## folder an account. The counter of ids is the caller's to advance
	## first, as for any account.
	create_invited_account! : { human : Users.User, inviter : UserId } => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_invited_account! = |{ human, inviter }| {
		facts = Users.account_facts(human)
		folder = AccountFiles.account_folder_path(AccountFolder.of(human.id()))
		FileFacts.create_facts!(folder, [("inviter", inviter.to_file()), (name_fact, facts.name)])
	}

	## A new human's account folder, made once as they sign up with GitHub:
	## the GitHub account that signs them in, `github-id`, then the `name`,
	## whose file makes the folder an account, so one cut short binds no one.
	## The counter of ids is the caller's to advance first, as for any account.
	create_github_account! : { human : Users.User, github : GitHubId } => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_github_account! = |{ human, github }| {
		facts = Users.account_facts(human)
		folder = AccountFiles.account_folder_path(AccountFolder.of(human.id()))
		FileFacts.create_facts!(
			folder,
			[(github_id_fact, github.to_file()), (name_fact, facts.name)],
		)
	}

	## The user's `name` file written whole over the one before, atomically:
	## the name an invited human chose as they joined.
	replace_account_name! : Users.User => Try({}, [MissingDirectory, NotUtf8, PathRefused, Failed])
	replace_account_name! = |user| {
		folder = AccountFiles.account_folder_path(AccountFolder.of(user.id()))
		FileFacts.replace_fact!("${folder}/${name_fact}", Users.account_facts(user).name)
	}

	## The `inviter` file of the human `id`, as it is, or `NoFile` when they
	## have none; unless the host's read failed.
	read_inviter_file! : UserId => Try([NoFile, File(List(U8))], [NotUtf8, PathRefused, Failed])
	read_inviter_file! = |id|
		FileFacts.read_fact!("${AccountFiles.account_folder_path(AccountFolder.of(id))}/inviter")

	## The human `id`'s password's bcrypt hash written whole over the one
	## before, atomically: a redeemed invite's choice. The hash is the
	## host's (`Host.bcrypt_hash_of_password!`); the password is never kept.
	replace_password_hash! : UserId,
	PasswordHash => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_password_hash! = |id, hash| FileFacts.replace_fact!(password_path(id), hash.bytes())

	## The bcrypt hash of the user `id`'s password, as its file keeps it,
	## or `NoFile` when they have none; unless the host's read failed. Only
	## the hash is ever kept, and the server's owner writes it
	## (docs/design.md, "Storage").
	read_password_hash! : UserId => Try(
		[NoFile, File(PasswordHash)],
		[NotUtf8, PathRefused, Failed],
	)
	read_password_hash! = |id|
		match FileFacts.read_fact!(password_path(id))? {
			NoFile => Ok(NoFile)
			File(bytes) => Ok(File(PasswordHash.from_file(bytes)))
		}

	## The GitHub account of each account folder whose `github-id` file
	## names one (docs/design.md, "Storage"). It lists the folders rather than
	## taking a `Users`, as a human can sign up while the host waits on GitHub,
	## and a `Users` read before that wait doesn't hold them. One damaged file
	## fails the whole read rather than being left out: left out, its human
	## would be no one to a GitHub sign-in, which would make them a second
	## account, while their own pages say they are linked.
	read_github_links! : {} => Try(
		List({ user : UserId, github : GitHubId }),
		[Damaged, NotUtf8, PathRefused, Failed],
	)
	read_github_links! = |{}| {
		ids = FileFacts.list_names_in!(AccountFolder.accounts_root)?.keep_oks(UserId.from_str)
		var $links = []
		for id in ids {
			match AccountFiles.read_github_link!(id)? {
				NotLinked => {}
				Linked(github) => {
					$links = $links.append({ user: id, github })
				}
			}
		}
		Ok($links)
	}

	## The GitHub account that signs in as the user `id`: `NotLinked` when
	## they have no `github-id` file; unless the file holds no id (`Damaged`),
	## or the host's read failed.
	read_github_link! : UserId => Try(
		[NotLinked, Linked(GitHubId)],
		[Damaged, NotUtf8, PathRefused, Failed],
	)
	read_github_link! = |id| github_link(FileFacts.read_fact!(github_id_path(id))?)

	## The word the user `id`'s `github-session-secret` file holds, or
	## `Empty`, or `NoFile`; unless the file holds no word (`Damaged`), or
	## the host's read failed.
	read_github_session_secret! : UserId => Try(
		[NoFile, File([Empty, Word(GitHubSessionWord)])],
		[Damaged, NotUtf8, PathRefused, Failed],
	)
	read_github_session_secret! = |id|
		match FileFacts.read_fact!(github_session_secret_path(id))? {
			NoFile => Ok(NoFile)
			File(bytes) =>
				match GitHubSessionWord.from_file(bytes) {
					Ok(held) => Ok(File(held))
					Err(NotAWord) => Err(Damaged)
				}
		}

	## The user `id`'s `github-session-secret` file made holding `word`, once;
	## `AlreadyExists`, nothing changed, when it is there.
	create_github_session_secret! : UserId,
	GitHubSessionWord => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_github_session_secret! = |id, word|
		FileFacts.create_fact!(github_session_secret_path(id), word.bytes())

	## The user `id`'s `github-session-secret` file written whole over any
	## before it, atomically.
	replace_github_session_secret! : UserId,
	GitHubSessionWord => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_github_session_secret! = |id, word|
		FileFacts.replace_fact!(github_session_secret_path(id), word.bytes())

	## The human `id`'s `github-id` file made holding `github`, once;
	## `AlreadyExists`, nothing changed, when it is there.
	create_github_id! : UserId,
	GitHubId => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_github_id! = |id, github| FileFacts.create_fact!(github_id_path(id), github.to_file())

	## The human `id`'s session generation, how many times they have signed
	## their other devices out, which their sessions are signed over once it
	## is above 0: 0 when there is no file; unless the file holds anything
	## but its digits (`Damaged`), or the host's read failed.
	read_session_generation! : UserId => Try(U64, [Damaged, NotUtf8, PathRefused, Failed])
	read_session_generation! = |id|
		match FileFacts.read_fact!(session_generation_path(id))? {
			NoFile => Ok(0)
			File(bytes) => FactFile.number_from_file(bytes).map_err(|NotANumber| Damaged)
		}

	## The human `id`'s session generation written whole as `generation`,
	## atomically: every session signed over the one before ends.
	replace_session_generation! : UserId,
	U64 => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_session_generation! = |id, generation|
		FileFacts.replace_fact!(session_generation_path(id), FactFile.number_to_file(generation))

	## The counter of user ids, written whole as `users` holds it.
	replace_user_counter! : Users => Try({}, [MissingDirectory, NotUtf8, PathRefused, Failed])
	replace_user_counter! = |users| {
		FileFacts.make_folder!(AccountFolder.accounts_root)?
		FileFacts.replace_fact!(user_counter_path, users.counter_bytes())
	}
}

## The path of the user `id`'s password's hash.
password_path : UserId -> Str
password_path = |id| "${AccountFiles.account_folder_path(AccountFolder.of(id))}/password"

## The fact file of a user's name, whose making makes their folder an
## account.
name_fact : Str
name_fact = "name"

## The fact file of the GitHub account that signs in as a user.
github_id_fact : Str
github_id_fact = "github-id"

## The path of the GitHub account that signs in as the user `id`.
github_id_path : UserId -> Str
github_id_path = |id| "${AccountFiles.account_folder_path(AccountFolder.of(id))}/${github_id_fact}"

## What a `github-id` fact file says: none, `NotLinked`; an id, `Linked`;
## anything else, `Damaged`.
github_link : [NoFile, File(List(U8))] -> Try([NotLinked, Linked(GitHubId)], [Damaged])
github_link = |fact|
	match fact {
		NoFile => Ok(NotLinked)
		File(bytes) =>
			match GitHubId.from_file(bytes) {
				Ok(github) => Ok(Linked(github))
				Err(NotAGitHubId) => Err(Damaged)
			}
	}

## The path of what the user `id`'s sessions are signed over beside their
## password's hash, once they have signed in with GitHub.
github_session_secret_path : UserId -> Str
github_session_secret_path = |id|
	"${AccountFiles.account_folder_path(AccountFolder.of(id))}/github-session-secret"

## The path of the user `id`'s session generation.
session_generation_path : UserId -> Str
session_generation_path = |id|
	"${AccountFiles.account_folder_path(AccountFolder.of(id))}/session-generation"

## The path of the counter of user ids.
user_counter_path : Str
user_counter_path = "${AccountFolder.accounts_root}/next-id.txt"

# ── tests
# The paths each builder makes, under the accounts root.
expect AccountFiles.account_folder_path(AccountFolder.of(UserId.chat_owner)) == "auth/1"
expect password_path(UserId.chat_owner) == "auth/1/password"
expect github_session_secret_path(UserId.chat_owner) == "auth/1/github-session-secret"
expect user_counter_path == "auth/next-id.txt"
expect session_generation_path(UserId.chat_owner) == "auth/1/session-generation"
expect github_id_path(UserId.chat_owner) == "auth/1/github-id"
# A `github-id` fact: none links no one, an id links it, anything else is
# damaged, never read as either.
expect github_link(NoFile) == Ok(NotLinked)
expect github_link(File("583231\n".to_utf8())) == GitHubId.from_u64(583231).map_ok(|github| Linked(github))
expect
	["", "0", "x", "-1", "583231x"].all(|text| github_link(File(text.to_utf8())) == Err(Damaged))

## This module keeps when each human became a member: the file `joined` in
## their account folder (`AccountFiles.joined_fact`), the second they
## joined, in seconds since 1970, its digits and no line end
## (`Timestamp.to_file`), as a key's `created` is written.
##
## It is written once, when the account becomes a person's:
##
## - by GitHub sign-up, inside the account's own making, between its
##   `github-id` and its `name` (`AccountFiles.create_github_account!`), so
##   no account made so lacks it;
## - by an invite, at a join by a human with no `password` file yet, their
##   first, before the password is written (`record_first_join!`), so a
##   join cut short writes its `joined` again when it is tried again. A
##   human who has a password never joins again (`HumanClaim`), and the
##   check stays, so a join never makes an older account new: not one that
##   joined before this file, which has none and stays established.
##
## Making an invite writes none. The first start's owner and agents have
## none. A `joined` file left empty by a crash as it was made reads as
## damaged; the next first join replaces it.
import AccountFiles
import AccountFolder
import FileFacts
import Timestamp
import UserId

JoinedFiles :: [].{

	## When the human `id` joined, or `NoFile` when their account has none;
	## unless the file holds no time (`Damaged`), or the host's read failed.
	read_joined! : UserId => Try(
		[NoFile, Joined(Timestamp)],
		[Damaged, NotUtf8, PathRefused, Failed],
	)
	read_joined! = |id|
		match FileFacts.read_fact!(joined_path(id))? {
			NoFile => Ok(NoFile)
			File(bytes) =>
				match Timestamp.from_file(bytes) {
					Ok(at) => Ok(Joined(at))
					Err(NotATime) => Err(Damaged)
				}
		}

	## The human `id`'s first join by an invite, at `now`, recorded: their
	## `joined` file made, when they have no `password` file yet; nothing
	## when they have one, as this join only sets a new one.
	record_first_join! : UserId,
	Timestamp => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	record_first_join! = |id, now|
		match AccountFiles.read_password_hash!(id)? {
			File(_) => Ok({})
			NoFile => record_joined!(id, now)
		}
}

## The human `id`'s `joined` file made holding `now`; one already there is
## kept, unless it holds no time, which is replaced.
record_joined! : UserId, Timestamp => Try({}, [MissingDirectory, NotUtf8, PathRefused, Failed])
record_joined! = |id, now|
	match FileFacts.create_fact!(joined_path(id), now.to_file()) {
		Ok({}) => Ok({})
		Err(AlreadyExists) =>
			match JoinedFiles.read_joined!(id) {
				Ok(_) => Ok({})
				Err(Damaged) => FileFacts.replace_fact!(joined_path(id), now.to_file())
				Err(NotUtf8) => Err(NotUtf8)
				Err(PathRefused) => Err(PathRefused)
				Err(Failed) => Err(Failed)
			}
		Err(MissingDirectory) => Err(MissingDirectory)
		Err(NotUtf8) => Err(NotUtf8)
		Err(PathRefused) => Err(PathRefused)
		Err(Failed) => Err(Failed)
	}

## The path of the human `id`'s `joined` file.
joined_path : UserId -> Str
joined_path = |id| {
	folder = AccountFiles.account_folder_path(AccountFolder.of(id))
	"${folder}/${AccountFiles.joined_fact}"
}

# ── tests
expect joined_path(UserId.chat_owner) == "auth/1/joined"

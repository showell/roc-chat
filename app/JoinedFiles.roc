## This module keeps when each human became a member: the file `joined` in
## their account folder (`AccountFiles.account_folder_path`), the second
## they joined, in seconds since 1970, its digits and no line end
## (`Timestamp.to_file`), as a key's `created` is written.
##
## It is written once, when the account becomes a person's: when an invited
## human first joins (`HumanInvitesRoute`), not when the invite is made, and
## when a GitHub sign-up gets its name (`GitHubSignUpRoute`). A later join,
## by an invite again, keeps the first (`AlreadyExists` is no failure), so a
## new password never makes an old account new. The first start's owner,
## an agent, and every account made before this file have none.
import AccountFiles
import AccountFolder
import FileFacts
import Timestamp
import UserId

JoinedFiles :: [].{

	## When the human `id` joined, or `NoFile` when their account has none;
	## unless the file holds no time (`Damaged`), or the host's read failed.
	read_joined! : UserId => Try([NoFile, Joined(Timestamp)], [Damaged, NotUtf8, PathRefused, Failed])
	read_joined! = |id|
		match FileFacts.read_fact!(joined_path(id))? {
			NoFile => Ok(NoFile)
			File(bytes) => Timestamp.from_file(bytes).map_ok(|at| Joined(at)).map_err(|NotATime| Damaged)
		}

	## The human `id`'s `joined` file made holding `now`, unless they have
	## one already, which is kept.
	record_joined! : UserId, Timestamp => Try({}, [MissingDirectory, NotUtf8, PathRefused, Failed])
	record_joined! = |id, now|
		match FileFacts.create_fact!(joined_path(id), now.to_file()) {
			Ok({}) => Ok({})
			Err(AlreadyExists) => Ok({})
			Err(MissingDirectory) => Err(MissingDirectory)
			Err(NotUtf8) => Err(NotUtf8)
			Err(PathRefused) => Err(PathRefused)
			Err(Failed) => Err(Failed)
		}
}

## The path of the human `id`'s `joined` file.
joined_path : UserId -> Str
joined_path = |id| "${AccountFiles.account_folder_path(AccountFolder.of(id))}/joined"

# ── tests
expect joined_path(UserId.chat_owner) == "auth/1/joined"

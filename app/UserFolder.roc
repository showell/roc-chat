## This module names a user's private folder, `users/<id>`, where the chat
## keeps what it knows of one user as one small file per fact. A user's
## upload total (`UploadTotal`) is one such file. The folder is named by the
## user's id alone.
##
## It is the one home of that folder's place in the data root, as
## `ConversationKey` is for a conversation's: `FileSystem` builds every path
## in it from `parts`, and no caller names a path.
import UserId

UserFolder :: UserId.{

	## The folder of the user `id`.
	of : UserId -> UserFolder
	of = |id| UserFolder.(id)

	## Its parts, as its path spells them: `users`, then the id's digits.
	parts : UserFolder -> List(Str)
	parts = |UserFolder.(id)| ["users", id.to_str()]

	is_eq : _
}

# ── tests
expect UserFolder.of(UserId.steve).parts() == ["users", "1"]
expect
	UserFolder.of(UserId.from_str("65535") ?? crash "UserFolder's tests: 65535 is an id").parts() == [
		"users",
		"65535",
	]

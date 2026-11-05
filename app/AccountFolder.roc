## This module names a user's account folder, `auth/<id>`, under the auth
## root, where the chat keeps who a user is and how they prove it: the
## user's name and an agent's owner
## (`Users`), and an agent's keys and invites (`AgentKey`, `AgentInvite`),
## each fact a small file. Those are kept apart from what a user has done,
## such as their upload total, in their private folder (`UserFolder`): a
## mistake in the one can't touch the other.
##
## It is the one home of the account folder's place in the data root:
## `FileSystem` builds every path in it from `parts`, and no caller names a
## path.
import UserId

AccountFolder :: UserId.{

	## The folder of the user `id`.
	of : UserId -> AccountFolder
	of = |id| AccountFolder.(id)

	## Its parts, as its path spells them: the auth root, then the id's
	## digits.
	parts : AccountFolder -> List(Str)
	parts = |AccountFolder.(id)| [AccountFolder.auth_root, id.to_str()]

	## The auth root's name, which also holds the counter of user ids.
	auth_root : Str
	auth_root = "auth"

	is_eq : _
}

# ── tests
expect AccountFolder.of(UserId.steve).parts() == ["auth", "1"]
expect
	AccountFolder.of(UserId.from_str("255") ?? crash "AccountFolder's tests: 255 is an id").parts()
		== [
			"auth",
			"255",
		]

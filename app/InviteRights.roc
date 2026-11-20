## This module reads what a human's files say of their place among
## inviters, for `HumanInvitesRoute`: how their account was made, which
## decides whether they may invite (`HumanInvites.check_inviter_origin`), and
## who invited them, which decides who may invite them again. Its failures
## are the route's: a refusal, a file that says no fact, or the file system's
## fault.
import AccountFiles
import HumanInvites
import SignedIn
import UserId

InviteRights :: [].{

	## Whether `acting`, a human by their session, may invite anyone: never a
	## human whose account was made by GitHub sign-up (`SignedUpByGitHub`, a
	## 403), nor a key or an agent.
	check_may_invite! : SignedIn => Try({}, _)
	check_may_invite! = |acting| {
		_ = acting.human_in_session() ? |why| Refused(why)
		made = InviteRights.load_origin!(acting.user().id())?
		HumanInvites.check_inviter_origin(made) ? |why| Refused(why)
		Ok({})
	}

	## How the human `id`'s account was made, as their `sign-up` file says.
	load_origin! : UserId => Try(HumanInvites.AccountMaking, _)
	load_origin! = |id| {
		file = AccountFiles.read_sign_up_file!(id) ? |fault| FileSystem(fault)
		HumanInvites.origin_from_file(file).map_err(|NotAnOrigin| BadSignUp(id))
	}

	## Who invited the human `id`, as their `inviter` file says.
	load_inviter! : UserId => Try(HumanInvites.Inviter, _)
	load_inviter! = |id| {
		file = AccountFiles.read_inviter_file!(id) ? |fault| FileSystem(fault)
		HumanInvites.inviter_from_file(file).map_err(|NotAnInviter| BadInviter(id))
	}
}

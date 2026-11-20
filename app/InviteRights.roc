## This module reads what a human's files say of their place among
## inviters, for `HumanInvitesRoute`: who invited them, which decides who may
## invite them again. Its failures are the route's: a file that says no
## fact, or the file system's fault.
import AccountFiles
import HumanInvites
import UserId

InviteRights :: [].{

	## Who invited the human `id`, as their `inviter` file says.
	load_inviter! : UserId => Try(HumanInvites.Inviter, _)
	load_inviter! = |id| {
		file = AccountFiles.read_inviter_file!(id) ? |fault| FileSystem(fault)
		HumanInvites.inviter_from_file(file).map_err(|NotAnInviter| BadInviter(id))
	}
}

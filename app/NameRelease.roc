## This module frees a name a lapsed invitee holds (`LapsedInvitee`) when a
## new human asks for it, by an invite, a GitHub sign-up or a joiner's new
## name. Expiry is checked at that moment, so no background job runs: a
## lapsed invitee whose name nobody asks for keeps it, and their inviter may
## still invite them again.
##
## Freeing is done only when it lets the name through: every human whose name
## looks like it (`Directory.humans_alike_list`) that is a lapsed invitee is
## released, and only when the name then passes
## `Directory.check_new_human_name`. Releasing writes, in order, each channel
## that held one of them without them (so no channel names a member who is no
## user), then each one's `name-released` (`AccountFiles`), after which their
## folder is no account. A failure between leaves a lapsed invitee in fewer
## channels, still holding the name, and the next ask tries again. Their id
## is never given again, as the counter of ids never goes back, and nothing
## of theirs is removed.
import pf.Host
import AccountFiles
import Directory
import DirectoryFiles
import FileFacts
import HumanInvites
import InviteFiles
import LapsedInvitee
import Name
import Timestamp
import UserId
import Users

NameRelease :: [].{

	## `directory` with every lapsed invitee whose name looks like `name`
	## released, and their release written, when that frees `name` for a
	## human (`leaving` their own name, if they hold one); else `directory`
	## as it is, nothing written.
	free_name! : Directory,
	{
		name : Name,
		leaving : [NoOne, Leaving(UserId)],
		now : Timestamp,
	} => Try(Directory, [FileSystem(FileFacts.Fault)])
	free_name! = |directory, { name, leaving, now }| {
		alike = directory.humans_alike_list(name).drop_if(
			|human|
				match leaving {
					NoOne => Bool.False
					Leaving(id) => human.id() == id
				},
		)
		var $lapsed = []
		for human in alike {
			if load_lapse!(human, now)? {
				$lapsed = $lapsed.append(human)
			}
		}
		if $lapsed.is_empty() {
			Ok(directory)
		} else {
			released = directory.release_humans($lapsed)
			match released.directory.check_new_human_name({ name, leaving }) {
				Err(_) => Ok(directory)
				Ok({}) => {
					for channel in released.changed {
						DirectoryFiles.replace_channel_members!(channel) ? |fault| FileSystem(fault)
					}
					for human in $lapsed {
						match AccountFiles.create_name_released!(human.id(), now) {
							Ok({}) | Err(AlreadyExists) => {}
							Err(MissingDirectory) => return Err(FileSystem(MissingDirectory))
							Err(NotUtf8) => return Err(FileSystem(NotUtf8))
							Err(PathRefused) => return Err(FileSystem(PathRefused))
							Err(Failed) => return Err(FileSystem(Failed))
						}
						Host.write_line_to_server_log!(
							"the name of user ${human.id().to_str()}, invited and never joined, is free again".to_utf8(),
						)
					}
					Ok(released.directory)
				}
			}
		}
	}
}

## Whether `human` is a lapsed invitee at `now`, as their files say. A file
## that doesn't read as its fact (an inviter or a GitHub link that is none)
## keeps them as they are: only a human known to be lapsed is released.
load_lapse! : Users.Human, Timestamp => Try(Bool, [FileSystem(FileFacts.Fault)])
load_lapse! = |human, now| {
	id = human.id()
	inviter_file = AccountFiles.read_inviter_file!(id) ? |fault| FileSystem(fault)
	match HumanInvites.inviter_from_file(inviter_file) {
		Err(NotAnInviter) => Ok(Bool.False)
		Ok(NoInviter) => Ok(Bool.False)
		Ok(inviter) => {
			password_file = AccountFiles.read_password_hash!(id) ? |fault| FileSystem(fault)
			password =
				match password_file {
					NoFile => NoPassword
					File(_) => HasPassword
				}
			github =
				match AccountFiles.read_github_link!(id) {
					Ok(NotLinked) => Ok(NotLinked)
					Ok(Linked(_)) | Err(Damaged) => Ok(Linked)
					Err(NotUtf8) => Err(FileSystem(NotUtf8))
					Err(PathRefused) => Err(FileSystem(PathRefused))
					Err(Failed) => Err(FileSystem(Failed))
				}?
			invites = InviteFiles.read_human_invites!(id) ? |fault| FileSystem(fault)
			Ok(LapsedInvitee.is_lapsed({ inviter, invites, password, github, now }))
		}
	}
}

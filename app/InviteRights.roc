## This module reads what a human's files say of their place among
## inviters, for `HumanInvitesRoute`: who invited them, which decides who may
## invite them again, and, for a person in their first day, how many new
## invites they made since they joined (`NewcomerInvites`). Its failures are
## the route's: a refusal, a file that says no fact, or the file system's
## fault.
import AccountFiles
import Directory
import HumanInvites
import InviteFiles
import JoinedFiles
import NewcomerInvites
import SignedIn
import Timestamp
import UserId

InviteRights :: [].{

	## Who invited the human `id`, as their `inviter` file says.
	load_inviter! : UserId => Try(HumanInvites.Inviter, _)
	load_inviter! = |id| {
		file = AccountFiles.read_inviter_file!(id) ? |fault| FileSystem(fault)
		HumanInvites.inviter_from_file(file).map_err(|NotAnInviter| BadInviter(id))
	}

	## Whether `acting` may make a new invite at `now` by the first day's
	## limit (`NewcomerInvites.check`): their `joined` file, and the new
	## invites they made since, among every human's of `directory`. Past it,
	## `FirstDayFull`, a 403 saying when they may again.
	check_first_day! : {
		acting : SignedIn,
		directory : Directory,
		now : Timestamp,
	} => Try({}, _)
	check_first_day! = |{ acting, directory, now }| {
		by = acting.user().id()
		joined = JoinedFiles.read_joined!(by) ? |fault| FileSystem(fault)
		made =
			match joined {
				NoFile => 0
				Joined(since) => {
					invites = load_every_humans_invites!(directory)?
					NewcomerInvites.count_made(invites, { by, since: NewcomerInvites.counted_since(since, now) })
				}
			}
		NewcomerInvites.check({
			by,
			joined,
			made,
			now,
		}) ? |FirstDayFull(until)| Refused(FirstDayFull(until))
		Ok({})
	}

	## What the invites page offers `acting` at `now`: the form, or, past the
	## first day's limit, the line saying when they may invite again.
	load_offer! : {
		acting : SignedIn,
		directory : Directory,
		now : Timestamp,
	} => Try([MayInvite, MayNotInvite(Str)], _)
	load_offer! = |request|
		match InviteRights.check_first_day!(request) {
			Ok({}) => Ok(MayInvite)
			Err(Refused(FirstDayFull(until))) => Ok(MayNotInvite(NewcomerInvites.full_words(until)))
			Err(FileSystem(fault)) => Err(FileSystem(fault))
			Err(BadInviter(id)) => Err(BadInviter(id))
		}
}

## Each human of `directory`, as the first day's count reads them: who
## invited them, and their invites.
load_every_humans_invites! : Directory => Try(List(NewcomerInvites.Invitee), _)
load_every_humans_invites! = |directory| {
	var $invitees = []
	for user in directory.users().to_list() {
		match user.as_human() {
			Ok(human) => {
				inviter = InviteRights.load_inviter!(human.id())?
				invites = InviteFiles.read_human_invites!(human.id()) ? |fault| FileSystem(fault)
				$invitees = $invitees.append({ inviter, invites })
			}
			Err(Agent(_)) => {}
		}
	}
	Ok($invitees)
}

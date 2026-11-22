## This module reads what a human's files say of their place among
## inviters, for `HumanInvitesRoute`: who invited them, which decides who may
## invite them again; how many of a human's invites are open, which the cap
## of open invites counts; and, for a person in their first day, how many new
## invites they made since they joined (`NewcomerInvites`); and whether a
## human has claimed their account (`HumanClaim`), which decides whether an
## invite may be made or redeemed for them. Its failures are
## the route's: a refusal, a file that says no fact, or the file system's
## fault.
import AccountFiles
import Directory
import HumanClaim
import HumanInvite
import HumanInvites
import InviteFiles
import JoinedFiles
import NewcomerInvites
import SignedIn
import Timestamp
import UserId
import Users

InviteRights :: [].{

	## Who invited the human `id`, as their `inviter` file says.
	load_inviter! : UserId => Try(HumanInvites.Inviter, _)
	load_inviter! = |id| {
		file = AccountFiles.read_inviter_file!(id) ? |fault| FileSystem(fault)
		HumanInvites.inviter_from_file(file).map_err(|NotAnInviter| BadInviter(id))
	}

	## Whether `human` has claimed their account, as their files say
	## (`HumanClaim.judge`): a password, a GitHub link, or an invite spent. A
	## GitHub link that holds no id counts as one, so a damaged file never
	## lets an invite through.
	load_claim! : Users.Human => Try([Unclaimed(HumanClaim.Unclaimed), Claimed], _)
	load_claim! = |human| {
		invites = InviteFiles.read_human_invites!(human.id()) ? |fault| FileSystem(fault)
		load_claim_given!(human, invites)
	}

	## Whether `human` has claimed their account (`load_claim!`), as the
	## invites page says it: they have joined.
	load_joined! : Users.Human => Try(Bool, _)
	load_joined! = |human|
		match InviteRights.load_claim!(human)? {
			Unclaimed(_) => Ok(Bool.False)
			Claimed => Ok(Bool.True)
		}

	## `human`, who has claimed nothing, for a new invite of theirs; or, for a
	## human who has, the refusal `Joined`.
	load_unclaimed! : Users.Human => Try(HumanClaim.Unclaimed, _)
	load_unclaimed! = |human|
		match InviteRights.load_claim!(human)? {
			Unclaimed(unclaimed) => Ok(unclaimed)
			Claimed => Err(Refused(Joined))
		}

	## The invitee whose invite a join's `code` opens, who has claimed
	## nothing; for any other, a code refused (`CodeRefused`), the one
	## refusal of a code, so an invite never sets a joined human's password.
	load_unclaimed_invitee! : Directory,
	HumanInvites.JoinCode => Try(
		{ human : Users.Human, unclaimed : HumanClaim.Unclaimed },
		_,
	)
	load_unclaimed_invitee! = |directory, code| {
		invitee = HumanInvites.find_invitee(directory, code) ? |why| Refused(why)
		match InviteRights.load_claim!(invitee.human)? {
			Unclaimed(unclaimed) => Ok({ human: invitee.human, unclaimed })
			Claimed => Err(Refused(CodeRefused))
		}
	}

	## How many invites `by` made that are open at `now`, among every human's
	## of `directory`, a joined human's counting none (`HumanInvites.open_count`).
	count_open_invites! : Directory, { by : UserId, now : Timestamp } => Try(U64, _)
	count_open_invites! = |directory, { by, now }| {
		var $open = 0
		for human in directory.users().to_list().keep_oks(|user| user.as_human()) {
			invites = InviteFiles.read_human_invites!(human.id()) ? |fault| FileSystem(fault)
			claim = load_claim_given!(human, invites)?
			$open = $open + HumanInvites.open_count(invites, { by, now, claim })
		}
		Ok($open)
	}

	## Whether `acting` may make a new invite at `now` by the first day's
	## limit (`NewcomerInvites.check`): their `joined` file, and, for a
	## person in their first day (`NewcomerInvites.standing`), the new
	## invites they made since, among every human's of `directory`, which no
	## one else's request reads. Past it, `FirstDayFull`, a 403 saying when
	## they may again.
	check_first_day! : {
		acting : SignedIn,
		directory : Directory,
		now : Timestamp,
	} => Try({}, _)
	check_first_day! = |{ acting, directory, now }| {
		by = acting.user().id()
		joined = JoinedFiles.read_joined!(by) ? |fault| FileSystem(fault)
		made =
			match NewcomerInvites.standing({ by, joined, now }) {
				Unlimited => 0
				FirstDay(since) => {
					invites = load_every_humans_invites!(directory)?
					NewcomerInvites.count_made(
						invites,
						{ by, since: NewcomerInvites.counted_since(since, now) },
					)
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

## Whether `human`, whose invites are `invites`, has claimed their account,
## as `InviteRights.load_claim!` says: their password and GitHub link read
## beside the invites.
load_claim_given! : Users.Human,
List(HumanInvite) => Try(
	[Unclaimed(HumanClaim.Unclaimed), Claimed],
	_,
)
load_claim_given! = |human, invites| {
	id = human.id()
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
	states = invites.map(|invite| invite.state())
	Ok(HumanClaim.judge(human, { password, github, invites: states }))
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

## Whether an invited human has claimed their account: joined by an invite,
## or holds a password or a GitHub link. An invite sets a password only for a
## human who has claimed nothing (`Unclaimed`): one who has signs in with their
## own proof, their session, their password or their GitHub link, and no
## inviter's link changes it (Steve, 2026-11-22: an invite again "means
## NOTHING for a human who has already joined"). This module decides it with
## no effects; `InviteRights.load_claim!` reads the facts from the human's
## files.
import Users

HumanClaim :: [].{

	## What decides it, as the human's files hold them: each invite's state
	## (`HumanInvite.State`).
	Facts : {
		password : [NoPassword, HasPassword],
		github : [NotLinked, Linked],
		invites : List([Live, Spent]),
	}

	## A human with no password, no GitHub link and every invite live: the only
	## human an invite is made for, or redeems for. Only `judge` makes one.
	Unclaimed :: Users.Human.{

		## The human who has claimed nothing.
		human : HumanClaim.Unclaimed -> Users.Human
		human = |HumanClaim.Unclaimed.(unclaimed)| unclaimed
	}

	## Whether `human`, whose files say `facts`, is `Unclaimed`, or has
	## `Claimed` their account. Unclaimed is one shape, named once: no
	## password, no GitHub link, and every invite live. Any other is claimed.
	judge : Users.Human, HumanClaim.Facts -> [Unclaimed(HumanClaim.Unclaimed), Claimed]
	judge = |human, { password, github, invites }|
		match (password, github) {
			(NoPassword, NotLinked) if invites.all(is_live) => Unclaimed(HumanClaim.Unclaimed.(human))
			(NoPassword, NotLinked) | (HasPassword, _) | (_, Linked) => Claimed
		}
}

## Whether an invite in `state` leaves its human unclaimed: a live one does,
## and a spent one was their join.
is_live : [Live, Spent] -> Bool
is_live = |state|
	match state {
		Live => Bool.True
		Spent => Bool.False
	}

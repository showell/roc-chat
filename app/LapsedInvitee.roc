## An invite holds its name from the moment it is made: the invited human's
## account has it at once (`HumanInvites`). An invited human who never
## joined, and whose every invite has expired, is a lapsed invitee: nothing
## of theirs can ever sign in, and their name is free again for a new invite
## or a GitHub sign-up. This module decides who is one, with no effects;
## `NameRelease` frees their name when a new human asks for it, so there is no
## background job, and a lapsed invitee whose name nobody wants stays as they
## are, for their inviter to invite again.
##
## A lapsed invitee is a human who
##
## - was invited (has an `inviter`), so never the founder, a GitHub sign-up
##   or a human made by hand;
## - has at least one invite, so an account whose first invite is still being
##   written is never one;
## - has spent none of them, so never joined;
## - has none open: each is past its expiry at `now`;
## - and has no password and no GitHub link, so nothing signs in as them.
import HumanInvite
import HumanInvites
import Timestamp

LapsedInvitee :: [].{

	## What decides it, as the human's files hold them.
	Facts : {
		inviter : HumanInvites.Inviter,
		invites : List(HumanInvite),
		password : [NoPassword, HasPassword],
		github : [NotLinked, Linked],
		now : Timestamp,
	}

	## Whether the human these facts describe is a lapsed invitee at `now`.
	is_lapsed : LapsedInvitee.Facts -> Bool
	is_lapsed = |{ inviter, invites, password, github, now }| {
		was_invited =
			match inviter {
				InvitedBy(_) => Bool.True
				NoInviter => Bool.False
			}
		was_invited
			and password == NoPassword
			and github == NotLinked
			and !invites.is_empty()
			and invites.all(|invite| invite.state() == Live and has_expired(invite, now))
	}
}

## Whether `invite` is past its expiry at `now`.
has_expired : HumanInvite, Timestamp -> Bool
has_expired = |invite, now| now.to_seconds_since_epoch() >= invite.expires().to_seconds_since_epoch()

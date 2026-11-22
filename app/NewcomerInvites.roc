## This module is the first day's limit on invites (Steve, 2026-11-20: "We
## need GH users to be first class users. They can send invites. Let's gate
## it to at most 3 in the first day of a user's existence."). A person whose
## `joined` file (`JoinedFiles`) is under a day old may make at most `most`
## invites in that day, counting the invites they made since they joined.
##
## - Only a new invite counts, one that makes an account (`InviteHuman`).
##   Inviting someone again (`InviteHumanAgain`) is a new link for the same
##   person, so it makes no one new, and it neither counts nor is refused
##   here; the cap of open invites (`HumanInvites.open_most`) still holds.
## - The owner, agents (who never invite), and a person with no `joined`
##   file, an account older than the file, have no limit. A `joined` ahead
##   of the clock is new, as `NewAccountUploads.standing_at` holds, and every
##   invite of theirs counts (`counted_since`).
## - Past the limit, inviting is a 403 that says when they may invite again:
##   a day after they joined.
##
## A new invite is the first invite of its human: their account was made by
## it. So the count is, among every human's invites, the first of each,
## where it was made by this person at or after the second they joined.
## This module decides, with no effects; `InviteRights` reads the files.
import DateTime
import HumanInvite
import Seconds
import Timestamp
import UserId

NewcomerInvites :: [].{

	## The most invites a person makes in their first day.
	most : U64
	most = 3

	## How long a person is new: a day.
	first_day : Seconds
	first_day = Seconds.of(24 * 60 * 60)

	## Whether the person `by`, whose `joined` file says `joined`, may make a
	## new invite at `now`, having made `made` since they joined: yes with no
	## file, for the owner, from a day after joining, or under `most`; else
	## the moment they may again (`FirstDayFull`).
	check : {
		by : UserId,
		joined : [NoFile, Joined(Timestamp)],
		made : U64,
		now : Timestamp,
	} -> Try({}, [FirstDayFull(Timestamp)])
	check = |{ by, joined, made, now }|
		match NewcomerInvites.standing({ by, joined, now }) {
			Unlimited => Ok({})
			FirstDay(at) =>
				if made < NewcomerInvites.most {
					Ok({})
				} else {
					Err(FirstDayFull(at.plus(NewcomerInvites.first_day)))
				}
		}

	## Whether the first day's limit holds the person `by`, whose `joined`
	## file says `joined`, at `now`: `Unlimited` with no file, for the
	## owner, and from a day after joining; else `FirstDay`, with when they
	## joined, so the invites they made since must be counted. Deciding this
	## first spares everyone else that count, which reads every human's
	## invites.
	standing : {
		by : UserId,
		joined : [NoFile, Joined(Timestamp)],
		now : Timestamp,
	} -> [Unlimited, FirstDay(Timestamp)]
	standing = |{ by, joined, now }|
		match joined {
			NoFile => Unlimited
			Joined(_) if by == UserId.chat_owner => Unlimited
			Joined(at) =>
				if now.seconds_since(at).is_at_least(NewcomerInvites.first_day) {
					Unlimited
				} else {
					FirstDay(at)
				}
		}

	## The second a newcomer's invites are counted from, when they joined at
	## `at` and it is `now`: `at`; or, with `joined` ahead of the clock,
	## from the start, so every invite of theirs counts and a clock set back
	## frees no one from the limit.
	counted_since : Timestamp, Timestamp -> Timestamp
	counted_since = |at, now|
		if now.seconds_since(at).to_i128() < 0 {
			Timestamp.at_second(0)
		} else {
			at
		}

	## One human as the count reads them: who invited them, and their
	## invites, those whose record is whole.
	Invitee : { inviter : [InvitedBy(UserId), NoInviter], invites : List(HumanInvite) }

	## How many new invites `by` made at or after `since`, among `invitees`:
	## each human whose first invite, by when it was made, `by` made then;
	## and each human `by` invited who has no whole invite, an account whose
	## invite was cut short as it was written, which inviting them again
	## would otherwise turn into an uncounted new person.
	count_made : List(NewcomerInvites.Invitee), { by : UserId, since : Timestamp } -> U64
	count_made = |invitees, { by, since }|
		invitees.count_if(
			|{ inviter, invites }|
				match first_made(invites) {
					Ok(first) =>
						first.invite_maker() == by
							and first.made_at().seconds_since(since).to_i128() >= 0
					Err(ListWasEmpty) => inviter == InvitedBy(by)
				},
		)

	## The refusal's words: the limit, and when they may invite again.
	full_words : Timestamp -> Str
	full_words = |until| {
		when =
			match DateTime.from_timestamp(until) {
				Ok(time) => time.to_str()
				Err(OutOfRange) => "${until.to_str()} seconds"
			}
		"In your first day here you can make at most ${NewcomerInvites.most.to_str()} invites. You can invite again from ${when} (UTC)."
	}
}

## The invite of `invites` made first; or none.
first_made : List(HumanInvite) -> Try(HumanInvite, [ListWasEmpty])
first_made = |invites|
	invites.fold(
		Err(ListWasEmpty),
		|found, invite|
			match found {
				Err(ListWasEmpty) => Ok(invite)
				Ok(earlier) =>
					if invite.made_at().seconds_since(earlier.made_at()).to_i128() < 0 {
						Ok(invite)
					} else {
						found
					}
			},
	)

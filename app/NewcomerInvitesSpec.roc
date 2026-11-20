## These are the tests of `NewcomerInvites`: in a person's first day, at most
## three new invites; none counted from before they joined, and inviting
## someone again never counted; no limit with no `joined` file, for the
## owner, or from a day after joining.
import HumanInvite
import HumanInvites
import NewcomerInvites
import PeoplePages
import Sample
import SecretHash
import SignedIn
import Timestamp
import UserId

NewcomerInvitesSpec :: [].{}

## The id `text` spells, which a test's always does.
id : Str -> UserId
id = |text| UserId.from_str(text) ?? crash "NewcomerInvitesSpec: an id"

## Joined at 1000: new until 87400.
joined : [NoFile, Joined(Timestamp)]
joined = Joined(Timestamp.at_second(1000))

## Whether user 7, joined at 1000, may make a new invite at `second`,
## having made `made`.
may_at : U64, I64 -> Try({}, [FirstDayFull(Timestamp)])
may_at = |made, second| NewcomerInvites.check({
	by: id("7"),
	joined,
	made,
	now: Timestamp.at_second(second),
})

# Under three, a new invite; at three, none, until a day after joining.
expect [0, 1, 2].all(|made| may_at(made, 1000) == Ok({}))
expect [3, 4].all(|made| may_at(made, 1000) == Err(FirstDayFull(Timestamp.at_second(87400))))
expect may_at(3, 87399) == Err(FirstDayFull(Timestamp.at_second(87400)))
# From the second a day after joining, no limit; a second before joining,
# which a clock set back would say, is still new.
expect may_at(3, 87400) == Ok({})
expect may_at(10, 999999) == Ok({})
expect may_at(3, 999) == Err(FirstDayFull(Timestamp.at_second(87400)))
# No `joined` file, an account older than it, has no limit; nor the owner.
expect NewcomerInvites.check({
	by: id("7"),
	joined: NoFile,
	made: 50,
	now: Timestamp.at_second(1000),
}) == Ok({})
expect NewcomerInvites.check({
	by: UserId.chat_owner,
	joined,
	made: 50,
	now: Timestamp.at_second(1000),
}) == Ok({})
# The refusal: a 403 saying the limit and when they may invite again.
expect {
	notice = HumanInvites.refusal_notice(FirstDayFull(Timestamp.at_second(87400)))
	notice.status == 403
		and notice.said.contains("at most 3 invites")
		and notice.said.contains("1970-01-02T00:16:40Z")
}

## Invite `number` of a human, made by `by` at `second`.
invite : {
	number : U64,
	by : Str,
	second : I64,
} -> HumanInvite
invite = |{ number, by, second }|
	HumanInvite.make({
		id: HumanInvite.Id.from_str(number.to_str()) ?? crash "NewcomerInvitesSpec: a number",
		hash: SecretHash.of_digest(List.repeat(number.to_u8_wrap(), 32)),
		now: Timestamp.at_second(second),
		by: id(by),
	})

## How many new invites user 7 made since 1000, among `invites`.
made_by_seven : List(List(HumanInvite)) -> U64
made_by_seven = |invites| NewcomerInvites.count_made(
	invites.map(|theirs| { inviter: InvitedBy(id("1")), invites: theirs }),
	{ by: id("7"), since: Timestamp.at_second(1000) },
)

# A human user 7 invited whose invite was cut short as it was written (no
# whole invite) counts, so inviting them again makes no uncounted person; one
# someone else invited, or no one, doesn't.
expect
	NewcomerInvites.count_made(
		[
			{ inviter: InvitedBy(id("7")), invites: [] },
			{ inviter: InvitedBy(id("1")), invites: [] },
			{ inviter: NoInviter, invites: [] },
		],
		{ by: id("7"), since: Timestamp.at_second(1000) },
	)
		== 1
# A `joined` ahead of the clock is new: the limit holds, until a day after
# it; and every invite counts, from the start.
expect may_at(3, 500) == Err(FirstDayFull(Timestamp.at_second(87400)))
expect may_at(2, 500) == Ok({})
expect NewcomerInvites.counted_since(
	Timestamp.at_second(1000),
	Timestamp.at_second(500),
) == Timestamp.at_second(0)
expect NewcomerInvites.counted_since(
	Timestamp.at_second(1000),
	Timestamp.at_second(1000),
) == Timestamp.at_second(1000)
expect NewcomerInvites.counted_since(
	Timestamp.at_second(1000),
	Timestamp.at_second(5000),
) == Timestamp.at_second(1000)

# Each human whose first invite user 7 made since joining counts once.
expect
	made_by_seven([
		[
			invite({
				number: 1,
				by: "7",
				second: 1000,
			}),
		],
		[
			invite({
				number: 1,
				by: "7",
				second: 2000,
			}),
		],
		[
			invite({
				number: 1,
				by: "7",
				second: 3000,
			}),
		],
	])
		== 3
# Inviting the same human again counts nothing more, whoever does it.
expect
	made_by_seven([
		[
			invite({
				number: 1,
				by: "7",
				second: 1000,
			}),
			invite({
				number: 2,
				by: "7",
				second: 1500,
			}),
			invite({
				number: 3,
				by: "1",
				second: 1600,
			}),
		],
	])
		== 1
# Another's invites, invites from before joining, and a human with none
# count nothing.
expect
	made_by_seven([
		[
			invite({
				number: 1,
				by: "1",
				second: 2000,
			}),
		],
		[
			invite({
				number: 1,
				by: "7",
				second: 999,
			}),
		],
		[],
		[
			invite({
				number: 1,
				by: "1",
				second: 500,
			}),
			invite({
				number: 2,
				by: "7",
				second: 2000,
			}),
		],
	])
		== 0
# Past the limit, the invites page has no form, and says when they may
# invite again; within it, the form.
expect {
	page = |may_invite|
		Str.from_utf8_lossy(
			PeoplePages.invites({
				viewer: SignedIn.dangerously_assume(Sample.user("Apoorva")),
				users: Sample.directory.users(),
				invited: [],
				github: Offered,
				may_invite,
				shown: NoLink,
				problem: NoProblem,
				now: Timestamp.at_second(0),
			}).to_utf8(),
		)
	words = NewcomerInvites.full_words(Timestamp.at_second(87400))
	refused = page(MayNotInvite(words))
	allowed = page(MayInvite)
	!refused.contains("action=\"/invites\"")
		and refused.contains("In your first day here")
		and allowed.contains("action=\"/invites\"")
		and !allowed.contains("In your first day here")
}

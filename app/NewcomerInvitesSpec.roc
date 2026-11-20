## These are the tests of `NewcomerInvites`: in a person's first day, at most
## three new invites; none counted from before they joined, and inviting
## someone again never counted; no limit with no `joined` file, for the
## owner, or from a day after joining.
import HumanInvite
import HumanInvites
import NewcomerInvites
import SecretHash
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
may_at = |made, second| NewcomerInvites.check({ by: id("7"), joined, made, now: Timestamp.at_second(second) })

# Under three, a new invite; at three, none, until a day after joining.
expect [0, 1, 2].all(|made| may_at(made, 1000) == Ok({}))
expect [3, 4].all(|made| may_at(made, 1000) == Err(FirstDayFull(Timestamp.at_second(87400))))
expect may_at(3, 87399) == Err(FirstDayFull(Timestamp.at_second(87400)))
# From the second a day after joining, no limit; nor before joining, which
# a clock set back would say.
expect may_at(3, 87400) == Ok({})
expect may_at(10, 999999) == Ok({})
expect may_at(3, 999) == Ok({})
# No `joined` file, an account older than it, has no limit; nor the owner.
expect NewcomerInvites.check({ by: id("7"), joined: NoFile, made: 50, now: Timestamp.at_second(1000) }) == Ok({})
expect NewcomerInvites.check({ by: UserId.chat_owner, joined, made: 50, now: Timestamp.at_second(1000) }) == Ok({})
# The refusal: a 403 saying the limit and when they may invite again.
expect {
	notice = HumanInvites.refusal_notice(FirstDayFull(Timestamp.at_second(87400)))
	notice.status == 403
		and notice.said.contains("at most 3 invites")
		and notice.said.contains("1970-01-02T00:16:40Z")
}

## Invite `number` of a human, made by `by` at `second`.
invite : { number : U64, by : Str, second : I64 } -> HumanInvite
invite = |{ number, by, second }|
	HumanInvite.make({
		id: HumanInvite.Id.from_str(number.to_str()) ?? crash "NewcomerInvitesSpec: a number",
		hash: SecretHash.of_digest(List.repeat(number.to_u8_wrap(), 32)),
		now: Timestamp.at_second(second),
		by: id(by),
	})

## How many new invites user 7 made since 1000, among `invites`.
made_by_seven : List(List(HumanInvite)) -> U64
made_by_seven = |invites| NewcomerInvites.count_made(invites, { by: id("7"), since: Timestamp.at_second(1000) })

# Each human whose first invite user 7 made since joining counts once.
expect
	made_by_seven([
		[invite({ number: 1, by: "7", second: 1000 })],
		[invite({ number: 1, by: "7", second: 2000 })],
		[invite({ number: 1, by: "7", second: 3000 })],
	])
		== 3
# Inviting the same human again counts nothing more, whoever does it.
expect
	made_by_seven([
		[
			invite({ number: 1, by: "7", second: 1000 }),
			invite({ number: 2, by: "7", second: 1500 }),
			invite({ number: 3, by: "1", second: 1600 }),
		],
	])
		== 1
# Another's invites, invites from before joining, and a human with none
# count nothing.
expect
	made_by_seven([
		[invite({ number: 1, by: "1", second: 2000 })],
		[invite({ number: 1, by: "7", second: 999 })],
		[],
		[invite({ number: 1, by: "1", second: 500 }), invite({ number: 2, by: "7", second: 2000 })],
	])
		== 0

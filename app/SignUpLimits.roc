## This module holds the two limits on new accounts, and decides each with
## no effects. Sign-up by GitHub is open to anyone, so without them a script
## with many GitHub accounts could fill the chat's ids and its disk before
## its owner heard of it.
##
## - At most `github_sign_ups_per_day_most` accounts are made by GitHub
##   sign-up in any 24 hours, server-wide. Each one made is remembered in
##   the server's memory, one key a slot (`slot_keys`), so a
##   restart forgets the window and allows that many again; the second limit
##   still holds.
## - At most `accounts_most` accounts in all, humans and agents together,
##   for every way an account is made, an invite's included
##   (`Directory.add_new_human`).
##
## Either refuses with `paused_words`, and the route that refuses logs
## `paused_log_line`, so the server's owner hears of it.
import Seconds
import Timestamp
import Users

SignUpLimits :: [].{

	## The most accounts GitHub sign-up makes in any 24 hours: a small
	## group's growth on a good day, and few enough that a flood is a day's
	## nuisance the owner can clean up by hand.
	github_sign_ups_per_day_most : U64
	github_sign_ups_per_day_most = 20

	## The most accounts in all: far past a small group, and far below what
	## the disk, the ids (`UserId`) and a directory read on every request
	## bear.
	accounts_most : U64
	accounts_most = 2000

	## The window GitHub sign-ups are counted over.
	github_sign_up_window : Seconds
	github_sign_up_window = Seconds.of(24 * 60 * 60)

	## What a refused sign-up or invite says.
	paused_words : Str
	paused_words = "Sign-ups are paused for now; please try again later."

	## The line the server's log gets for a refusal: which limit was reached.
	paused_log_line : [DayFull, ChatFull] -> List(U8)
	paused_log_line = |limit|
		match limit {
			DayFull => "sign-ups paused: ${github_sign_ups_per_day_most.to_str()} GitHub sign-ups in the last 24 hours".to_utf8()
			ChatFull => "sign-ups paused: ${accounts_most.to_str()} accounts, the most".to_utf8()
		}

	## Whether `users` has room for one more account.
	check_room : Users -> Try({}, [ChatFull])
	check_room = |users| room_for(users.to_list().len())

	## The keys the server's memory holds the GitHub sign-ups' seconds
	## under, one a slot.
	slot_keys : List(List(U8))
	slot_keys =
		List.repeat({}, SignUpLimits.github_sign_ups_per_day_most)
			.map_with_index(|{}, slot| "github-sign-up/${slot.to_str()}".to_utf8())

	## The slot a GitHub sign-up at `now` takes, among `slots` in key order,
	## each when its last sign-up was: the first never used, else the
	## oldest, while that one is out of the window; else `DayFull`.
	slot_for_sign_up : List([NeverUsed, UsedAt(Timestamp)]), Timestamp -> Try(List(U8), [DayFull])
	slot_for_sign_up = |slots, now| {
		ages =
			slots.map_with_index(
				|slot, index|
					match slot {
						NeverUsed => { index, age: Never }
						UsedAt(at) => { index, age: Ago(now.seconds_since(at)) }
					},
			)
		match ages.first() {
			Err(ListWasEmpty) => crash "SignUpLimits.slot_for_sign_up: one slot a key, and some keys"
			Ok(first) => {
				oldest = ages.drop_first(1).fold(first, older_slot)
				if is_out_of_window(oldest.age) {
					Ok(SignUpLimits.slot_keys.get(oldest.index) ?? crash "SignUpLimits: one key a slot")
				} else {
					Err(DayFull)
				}
			}
		}
	}
}

## Whether a slot of `age` is free: never used, or used a window ago or more.
is_out_of_window : [Never, Ago(Seconds)] -> Bool
is_out_of_window = |age|
	match age {
		Never => Bool.True
		Ago(seconds) => seconds.is_at_least(SignUpLimits.github_sign_up_window)
	}

## Whether a slot of age `one` is strictly older than one of `other`, a slot
## never used older than any used.
is_older : [Never, Ago(Seconds)], [Never, Ago(Seconds)] -> Bool
is_older = |one, other|
	match (one, other) {
		(Never, Never) => Bool.False
		(Never, Ago(_)) => Bool.True
		(Ago(_), Never) => Bool.False
		(Ago(one_age), Ago(other_age)) => one_age.is_more_than(other_age)
	}

## A slot by its place among the keys, and how long ago it was used.
SlotAge : { index : U64, age : [Never, Ago(Seconds)] }

## Of `kept` and `slot`, the older; `kept` when they are as old.
older_slot : SlotAge, SlotAge -> SlotAge
older_slot = |kept, slot|
	if is_older(slot.age, kept.age) {
		slot
	} else {
		kept
	}

## Whether a chat of `count` accounts has room for one more.
room_for : U64 -> Try({}, [ChatFull])
room_for = |count|
	if count >= SignUpLimits.accounts_most {
		Err(ChatFull)
	} else {
		Ok({})
	}

# ── tests
## The slots as the memory would hold them: each second ago at `now`, or
## never used for none.
at_noon : Timestamp
at_noon = Timestamp.at_second(1_000_000)

slots_aged : List([Never, Ago(I64)]) -> List([NeverUsed, UsedAt(Timestamp)])
slots_aged = |ages|
	ages.map(
		|age|
			match age {
				Never => NeverUsed
				Ago(seconds) => UsedAt(Timestamp.at_second(1_000_000 - seconds))
			},
	)

key_of : U64 -> Try(List(U8), [DayFull])
key_of = |slot| Ok("github-sign-up/${slot.to_str()}".to_utf8())

## The slot a sign-up at noon takes, the slots aged as `ages` says.
slot_taken : List([Never, Ago(I64)]) -> Try(List(U8), [DayFull])
slot_taken = |ages| SignUpLimits.slot_for_sign_up(slots_aged(ages), at_noon)

## A day in seconds.
day : I64
day = 24 * 60 * 60

# Twenty keys, one a slot.
expect SignUpLimits.slot_keys.len() == 20
expect SignUpLimits.slot_keys.first() == Ok("github-sign-up/0".to_utf8())
expect SignUpLimits.slot_keys.last() == Ok("github-sign-up/19".to_utf8())
# A slot never used is taken first, the first of them.
expect slot_taken(List.repeat(Never, 20)) == key_of(0)
expect {
	recent = List.repeat(Ago(9), 17)
	slot_taken(List.concat([Ago(5), Never, Never], recent)) == key_of(1)
}
# Twenty in the window: the twenty-first is refused, at the window's last
# second too.
expect slot_taken(List.repeat(Ago(60), 20)) == Err(DayFull)
expect slot_taken(List.repeat(Ago(day - 1), 20)) == Err(DayFull)
# One a whole window old frees its slot; the oldest of those is taken.
expect {
	recent = List.repeat(Ago(60), 18)
	slot_taken(List.concat(recent, [Ago(day), Ago(day + 6 * 60 * 60)])) == key_of(19)
}
expect slot_taken(List.repeat(Ago(60), 19).append(Ago(day))) == key_of(19)
# The chat's room: under the most, at it, past it.
expect room_for(0) == Ok({}) and room_for(1999) == Ok({})
expect room_for(2000) == Err(ChatFull) and room_for(2001) == Err(ChatFull)
expect SignUpLimits.paused_words == "Sign-ups are paused for now; please try again later."
expect {
	day_full = "sign-ups paused: 20 GitHub sign-ups in the last 24 hours"
	SignUpLimits.paused_log_line(DayFull) == day_full.to_utf8()
}
expect SignUpLimits.paused_log_line(ChatFull) == "sign-ups paused: 2000 accounts, the most".to_utf8()

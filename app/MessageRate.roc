## This module holds the limit on how fast one person posts: at most
## `per_window_most` messages in a window of `window_seconds` (a minute),
## for each user, humans and agents alike. It is a backstop against a
## script flooding a conversation, far above a person typing; an edit
## counts as a message, as it is one (`Edit`). No agent has a limit of its
## own in this server, so agents are held to this one.
##
## The window starts at a user's first message after the last window
## ended, and counts the messages since; the `per_window_most + 1`th inside
## it is refused (`TooManyMessages`), until the window ends. So no minute
## that starts a window holds more than `per_window_most` messages, and two
## windows back to back hold at most twice that across their seam.
##
## The tally is two seconds the host keeps in memory
## (`Host.replace_second_kept_under_key!`), a count and the window's start,
## each under its own key, as `DeviceCodeLimit`'s are; a restart forgets
## them. Two keys a user, so the memory holds at most 2 × 2,000 of them
## (`SignUpLimits.accounts_most`).
##
## The post route asks `check_rate!` once a message has been judged and
## before its record is written, so a refused message writes nothing; and
## it tells `record_message!` only once the record is appended, so a write
## that fails leaves the tally as it was. Nothing runs between the two, as
## the app makes one call at a time (the host's turn).
import pf.Host
import Seconds
import Timestamp
import UserId

MessageRate :: [].{

	## The most messages one user posts in a window.
	per_window_most : I64
	per_window_most = 30

	## How long a window lasts: a minute.
	window_seconds : Seconds
	window_seconds = Seconds.of(60)

	## What a refused message says.
	too_many_words : Str
	too_many_words = "Too many messages: at most ${MessageRate.per_window_most.to_str()} a minute. Wait a moment, then send it again."

	## The key a user's count is kept under.
	count_key : UserId -> List(U8)
	count_key = |user| "message-rate/count/${user.to_str()}".to_utf8()

	## The key a user's window's start is kept under.
	since_key : UserId -> List(U8)
	since_key = |user| "message-rate/since/${user.to_str()}".to_utf8()

	## A tally: how many messages were posted since its window started.
	MessageTally : { count : I64, since : Timestamp }

	## The tally at `now` from what the host keeps under the two keys: a
	## fresh one, of no messages from `now`, when either is missing or the
	## window has ended.
	tally_of : {
		count : { second : I64, status : [Found, Missing] },
		since : { second : I64, status : [Found, Missing] },
		now : Timestamp,
	} -> MessageRate.MessageTally
	tally_of = |{ count, since, now }| {
		fresh = { count: 0, since: now }
		match (count.status, since.status) {
			(Found, Found) => {
				started = Timestamp.at_second(since.second)
				window = { from: started, until: started.plus(MessageRate.window_seconds) }
				if now.is_during(window) {
					{ count: count.second, since: started }
				} else {
					fresh
				}
			}
			(Found, Missing) | (Missing, Found) | (Missing, Missing) => fresh
		}
	}

	## The tally after one more message; unless `tally` already holds the
	## most (`TooManyMessages`).
	tally_with_message : MessageRate.MessageTally -> Try(
		MessageRate.MessageTally,
		[TooManyMessages],
	)
	tally_with_message = |tally|
		if tally.count >= MessageRate.per_window_most {
			Err(TooManyMessages)
		} else {
			Ok({ ..tally, count: tally.count + 1 })
		}

	## The tally `user`'s message at `now` would leave, nothing kept yet;
	## unless their window already holds the most.
	check_rate! : UserId, Timestamp => Try(MessageRate.MessageTally, [TooManyMessages])
	check_rate! = |user, now| {
		tally = MessageRate.tally_of({
			count: Host.read_second_kept_under_key!(MessageRate.count_key(user)),
			since: Host.read_second_kept_under_key!(MessageRate.since_key(user)),
			now,
		})
		MessageRate.tally_with_message(tally)
	}

	## `user`'s tally kept as `counted`, the one `check_rate!` gave, once
	## their message is written.
	record_message! : UserId, MessageRate.MessageTally => {}
	record_message! = |user, counted| {
		_ = Host.replace_second_kept_under_key!(MessageRate.count_key(user), counted.count)
		started = counted.since.to_seconds_since_epoch()
		_ = Host.replace_second_kept_under_key!(MessageRate.since_key(user), started)
		{}
	}
}

# ── tests
noon : Timestamp
noon = Timestamp.at_second(1_000_000)

## What the host keeps under a key: `Found` with `second`.
kept_second : I64 -> { second : I64, status : [Found, Missing] }
kept_second = |second| { second, status: Found }

## A key the host keeps nothing under.
missing_second : { second : I64, status : [Found, Missing] }
missing_second = { second: 0, status: Missing }

## A fresh tally at noon, of no messages.
fresh_at_noon : MessageRate.MessageTally
fresh_at_noon = { count: 0, since: noon }

## The tally at noon of `count` messages in a window that started
## `ago` seconds before.
tally_at_noon : { count : I64, ago : I64 } -> MessageRate.MessageTally
tally_at_noon = |{ count, ago }|
	MessageRate.tally_of({
		count: kept_second(count),
		since: kept_second(1_000_000 - ago),
		now: noon,
	})

expect MessageRate.per_window_most == 30
expect MessageRate.count_key(UserId.chat_owner) == "message-rate/count/1".to_utf8()
expect MessageRate.since_key(UserId.chat_owner) == "message-rate/since/1".to_utf8()
# Nothing kept, or half of it: a fresh window from now.
expect
	[
		(missing_second, missing_second),
		(kept_second(7), missing_second),
		(missing_second, kept_second(999_990)),
	].all(|(count, since)| MessageRate.tally_of({ count, since, now: noon }) == fresh_at_noon)
# Inside the window its count holds, at its last second too; a whole window
# on, it is fresh.
expect tally_at_noon({ count: 12, ago: 0 }) == { count: 12, since: noon }
expect tally_at_noon({ count: 12, ago: 59 }) == { count: 12, since: Timestamp.at_second(999_941) }
expect tally_at_noon({ count: 30, ago: 60 }) == { count: 0, since: noon }
# The thirtieth message in a window passes; the thirty-first is refused.
expect MessageRate.tally_with_message({ count: 29, since: noon }) == Ok({ count: 30, since: noon })
expect MessageRate.tally_with_message({ count: 30, since: noon }) == Err(TooManyMessages)
expect MessageRate.tally_with_message({ count: 0, since: noon }) == Ok({ count: 1, since: noon })
# Thirty in a window that is ending: the next refused at its last second, and
# taken a second later, in a fresh window.
expect MessageRate.tally_with_message(tally_at_noon({ count: 30, ago: 59 })) == Err(TooManyMessages)
expect
	MessageRate.tally_with_message(tally_at_noon({ count: 30, ago: 60 }))
		== Ok({ count: 1, since: noon })
expect MessageRate.too_many_words == "Too many messages: at most 30 a minute. Wait a moment, then send it again."

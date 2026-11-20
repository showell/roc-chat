## This module orders a channel's members for its card, the popup its name
## opens in the sidebar (app/sidebar-popups.js), by participation (Steve,
## 2026-11-20: "Showing membership is absolutely useful. Participation is
## even better."). The members who posted in the channel lately come first,
## the latest first, each with when, in a few quiet words ("posted 2 hours
## ago"); then the rest by name, with no words. An agent is marked as one.
##
## Lately is within `window` (14 days) of the page's drawing, among the last
## `most_per_topic` (100) messages of each of the channel's topics: the
## page already reads each topic's transcript to order the sidebar, and
## `Transcript.recent_posts` reads those messages' heads back from its end,
## so a long topic costs no more than its last hundred. A member whose last
## post is further back than either counts as not posting lately. The
## words are "posted ... ago", and not a count ("3 messages this week"),
## since one time a member costs nothing to keep, and the latest is what
## says who is around. Nothing here is stored: it is worked out as the page
## is drawn.
import Channels
import DateTime
import Dm
import Place
import Presence
import Seconds
import Timestamp
import Transcript
import UserId
import Users

ChannelRoster :: [].{

	## How far back a post counts as lately: 14 days.
	window : Seconds
	window = Seconds.of(14 * 24 * 60 * 60)

	## How many of each topic's last messages are read, at most.
	most_per_topic : U64
	most_per_topic = 100

	## A member as the card lists them: their id and name, whether they are
	## a human or an agent, the place of the viewer's DM with them (a
	## human's; their card is that DM's), and when they last posted lately,
	## in words.
	Row : {
		id : UserId,
		name : Str,
		kind : [Human(Place), Agent],
		posted : [NotLately, Posted(Str)],
	}

	## A channel's members in the card's order, by its place.
	Roster : { place : Place, rows : List(ChannelRoster.Row) }

	## The earliest time a post counts as lately at `now`, which
	## `Transcript.recent_posts` stops at; the epoch when the window starts
	## before it.
	since : Timestamp -> DateTime
	since = |now| {
		start = now.plus(Seconds.of(0 - ChannelRoster.window.to_i128()))
		match DateTime.from_timestamp(start) {
			Ok(time) => time
			Err(OutOfRange) =>
				DateTime.from_timestamp(Timestamp.at_second(0))
					?? crash "ChannelRoster.since: the epoch is a time"
		}
	}

	## The roster of `channel` for `viewer` at `now`: each member found among
	## `users`, ordered by `posts`, the posts read from the channel's topics
	## in any order.
	roster : {
		channel : Channels.Channel,
		users : Users,
		viewer : Users.Human,
		posts : List(Transcript.Post),
		now : Timestamp,
	} -> ChannelRoster.Roster
	roster = |{ channel, users, viewer, posts, now }| {
		members = channel.members().keep_oks(|id| users.user(id))
		{
			place: Place.channel(channel),
			rows: ChannelRoster.rows({ members, viewer, posts, now }),
		}
	}

	## `members` in the card's order at `now`: those with a post among
	## `posts` within `window`, latest first, each with its words; then the
	## rest by name, in any case. Two posted in the same second, by name.
	rows : {
		members : List(Users.User),
		viewer : Users.Human,
		posts : List(Transcript.Post),
		now : Timestamp,
	} -> List(ChannelRoster.Row)
	rows = |{ members, viewer, posts, now }| {
		start = ChannelRoster.since(now)
		lately = posts.keep_if(|post| DateTime.compare(post.time, start) != Before)
		timed = members.map(
			|member| {
				member,
				last: lately.keep_if(|post| post.author.name() == member.name()).fold(
					NotLately,
					|so_far, post| later(so_far, post.time),
				),
			},
		)
		posted = timed.keep_if(|one| one.last != NotLately).sort_with(by_latest)
		quiet = timed.keep_if(|one| one.last == NotLately).sort_with(|one, other| by_name(one.member, other.member))
		List.concat(posted, quiet).map(|one| row({ member: one.member, last: one.last, viewer, now }))
	}

	## How long ago `quiet` is, as a member's words say: "posted just now"
	## under a minute (or a time ahead of the clock), else "posted 5 minutes
	## ago", "posted 1 hour ago", "posted 3 days ago".
	words : Seconds -> Str
	words = |quiet|
		if quiet.is_at_least(Seconds.of(60)) {
			"posted ${Presence.time_ago(quiet)} ago"
		} else {
			"posted just now"
		}
}

## A member's last post lately, if any.
Last : [NotLately, At(DateTime)]

## The later of `so_far` and `time`.
later : Last, DateTime -> Last
later = |so_far, time|
	match so_far {
		At(held) if DateTime.compare(held, time) != Before => so_far
		_ => At(time)
	}

## Latest first, then by name.
by_latest : { member : Users.User, last : Last }, { member : Users.User, last : Last } -> [Before, Same, After]
by_latest = |one, other|
	match (one.last, other.last) {
		(At(one_time), At(other_time)) =>
			match DateTime.compare(one_time, other_time) {
				After => Before
				Before => After
				Same => by_name(one.member, other.member)
			}
		_ => by_name(one.member, other.member)
	}

## By name, in any case of ASCII's letters, then as written.
by_name : Users.User, Users.User -> [Before, Same, After]
by_name = |one, other| {
	one_name = one.name().to_str()
	other_name = other.name().to_str()
	match byte_order(one_name.with_ascii_lowercased().to_utf8(), other_name.with_ascii_lowercased().to_utf8()) {
		Same => byte_order(one_name.to_utf8(), other_name.to_utf8())
		order => order
	}
}

## The order of two texts' bytes, by the first that differs, a text that
## runs out first before.
byte_order : List(U8), List(U8) -> [Before, Same, After]
byte_order = |bytes, others|
	match (bytes, others) {
		([byte, .. as rest], [other, .. as rest_of_others]) =>
			if byte == other {
				byte_order(rest, rest_of_others)
			} else if byte < other {
				Before
			} else {
				After
			}
		([], [_, ..]) => Before
		([_, ..], []) => After
		([], []) => Same
	}

## `member`'s row for `viewer` at `now`, posted lately at `last`.
row : { member : Users.User, last : Last, viewer : Users.Human, now : Timestamp } -> ChannelRoster.Row
row = |{ member, last, viewer, now }| {
	kind =
		match member.as_human() {
			Ok(human) => Human(Place.dm(Dm.between({ one: viewer, other: human })))
			Err(Agent(_)) => Agent
		}
	posted =
		match last {
			At(time) => Posted(ChannelRoster.words(now.seconds_since(time.to_timestamp())))
			NotLately => NotLately
		}
	{ id: member.id(), name: member.name().to_str(), kind, posted }
}

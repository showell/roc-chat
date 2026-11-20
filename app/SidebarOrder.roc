## This module decides the order of a sidebar's places and topics, and which
## places start open, so that what a person will likely click next is at the
## top. The page's own place comes first, open. On a DM page with another
## human, the viewer's own DM comes next, collapsed, since people rarely
## write to themselves. The other places follow newest first, by the last
## message in any of their topics, and each place's topics are newest first
## too. A place or topic with no messages comes after those with some, in the
## order it was given (Browse's, and topics' byte order), as do two of the
## same second.
##
## Of the places after the page's own (and the viewer's own DM), the
## `open_recent_most` newest that have a message start open; the rest start
## collapsed, and the viewer's own DM always does. A person's own choice to
## collapse or open a place outlasts this (app/sidebar.js keeps it), except
## for the page's own place, which always opens.
##
## The order is decided once, when the page is drawn. `Sidebar` writes it.
import ConversationKey
import DateTime
import Place
import Topic
import UserId

SidebarOrder :: [].{

	## When a conversation, or any of a place's, last had a message.
	Latest : [NoMessages, At(DateTime)]

	## A topic of a place, and when its conversation last had a message.
	TimedTopic : { topic : Topic, latest : SidebarOrder.Latest }

	## A place the sidebar lists, by the name it shows, with its topics.
	TimedPlace : {
		label : Str,
		place : Place,
		topics : List(SidebarOrder.TimedTopic),
	}

	## How a place starts when the page loads. `AlwaysOpen` is the page's
	## own place, open whatever the person chose before; `Open` and
	## `Collapsed` hold until the person chooses.
	Opening : [AlwaysOpen, Open, Collapsed]

	## A place in the sidebar's order, its topics in theirs.
	OrderedPlace : {
		label : Str,
		place : Place,
		topics : List(Topic),
		opening : SidebarOrder.Opening,
	}

	## How many places after the page's own start open, at most.
	open_recent_most : U64
	open_recent_most = 3

	## `places` in the order the sidebar shows them to `viewer` on a page of
	## `shown`, each with how it starts. The page's own topic is listed in
	## its place, after the others, even before its first message.
	order : {
		places : List(SidebarOrder.TimedPlace),
		shown : [Conversation(ConversationKey), NoConversation],
		viewer : UserId,
	} -> List(SidebarOrder.OrderedPlace)
	order = |{ places, shown, viewer }| {
		dated = places.map_with_index(
			|listed, at| { listed, at, latest: place_latest(listed.topics) },
		)
		is_here = |listed|
			match shown {
				Conversation(key) => listed.place == key.place()
				NoConversation => Bool.False
			}
		own_next =
			match shown {
				Conversation(key) => is_dm_with_another(key.place(), viewer)
				NoConversation => Bool.False
			}
		is_second = |listed| own_next and is_own_dm(listed.place, viewer)
		here = dated.keep_if(|d| is_here(d.listed))
		second = dated.keep_if(|d| is_second(d.listed))
		rest =
			dated
				.drop_if(|d| is_here(d.listed) or is_second(d.listed))
				.sort_with(|one, other| newest_first((one.latest, one.at), (other.latest, other.at)))
		var $after = []
		var $rank = 0
		for d in rest {
			own = is_own_dm(d.listed.place, viewer)
			opening = rest_opening({ own, latest: d.latest, rank: $rank })
			$after = $after.append(ordered_place({ listed: d.listed, opening, shown }))
			$rank = if own {
				$rank
			} else {
				$rank + 1
			}
		}
		List.concat(
			List.concat(
				here.map(|d| ordered_place({ listed: d.listed, opening: AlwaysOpen, shown })),
				second.map(|d| ordered_place({ listed: d.listed, opening: Collapsed, shown })),
			),
			$after,
		)
	}
}

## Whether `place` is `viewer`'s DM with themself.
is_own_dm : Place, UserId -> Bool
is_own_dm = |place, viewer|
	match place.which() {
		Dm(pair) => pair.members() == [viewer]
		Channel(_) => Bool.False
	}

## Whether `place` is a DM of `viewer`'s with someone else.
is_dm_with_another : Place, UserId -> Bool
is_dm_with_another = |place, viewer|
	match place.which() {
		Dm(pair) => pair.members() != [viewer]
		Channel(_) => Bool.False
	}

## How a place after the page's own starts: the viewer's own DM collapsed,
## and another open while it has a message and `rank` places other than the
## viewer's own DM come before it among the rest.
rest_opening : { own : Bool, latest : SidebarOrder.Latest, rank : U64 } -> SidebarOrder.Opening
rest_opening = |{ own, latest, rank }|
	match latest {
		At(_) if !own and rank < SidebarOrder.open_recent_most => Open
		_ => Collapsed
	}

## The newest of a place's topics' last messages.
place_latest : List(SidebarOrder.TimedTopic) -> SidebarOrder.Latest
place_latest = |topics| topics.fold(NoMessages, |so_far, timed| newer(so_far, timed.latest))

## The later of `one` and `other`.
newer : SidebarOrder.Latest, SidebarOrder.Latest -> SidebarOrder.Latest
newer = |one, other|
	match (one, other) {
		(At(a), At(b)) if DateTime.compare(a, b) == Before => other
		(NoMessages, _) => other
		_ => one
	}

## Newest first, then those with no messages; two alike by where they were
## given (`at`).
newest_first : (SidebarOrder.Latest, U64), (SidebarOrder.Latest, U64) -> [Before, Same, After]
newest_first = |(one, one_at), (other, other_at)|
	match (one, other) {
		(At(a), At(b)) =>
			match DateTime.compare(a, b) {
				After => Before
				Before => After
				Same => given_order(one_at, other_at)
			}
		(At(_), NoMessages) => Before
		(NoMessages, At(_)) => After
		(NoMessages, NoMessages) => given_order(one_at, other_at)
	}

## `one` and `other` in the order they were given.
given_order : U64, U64 -> [Before, Same, After]
given_order = |one, other|
	if one < other {
		Before
	} else if one > other {
		After
	} else {
		Same
	}

## `listed`, starting as `opening`, its topics newest first, and the page's
## own topic after them when its place is this one and it isn't listed yet.
ordered_place : {
	listed : SidebarOrder.TimedPlace,
	opening : SidebarOrder.Opening,
	shown : [Conversation(ConversationKey), NoConversation],
} -> SidebarOrder.OrderedPlace
ordered_place = |{ listed, opening, shown }| {
	sorted =
		listed.topics
			.map_with_index(|timed, at| { timed, at })
			.sort_with(|one, other| newest_first((one.timed.latest, one.at), (other.timed.latest, other.at)))
			.map(|d| d.timed.topic)
	topics =
		match shown {
			Conversation(key) if key.place() == listed.place and !sorted.contains(key.topic()) =>
				sorted.append(key.topic())
			_ => sorted
		}
	{ label: listed.label, place: listed.place, topics, opening }
}

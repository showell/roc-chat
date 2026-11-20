## This module decides the order of a sidebar's places and topics, and which
## places start open, so that what a person will likely click next is at the
## top. The page's own place comes first, open. The viewer's own DM comes
## next, whatever its time (Steve, 2026-11-20: "don't demote Steve below
## other users for Steve! Steve comes second for Steve, beneath his
## conversation partner."), so in the DMs group it is first on a channel's
## page and second on a DM's. The other places follow newest first, by the last
## message in any of their topics, and each place's topics are newest first
## too. A place or topic with no messages comes after those with some, in the
## order it was given (Browse's, and topics' byte order), as do two of the
## same second.
##
## Only the page's own place starts open; every other starts collapsed to
## its name's row (Steve, 2026-11-20: "I'm usually only DM'ing with one
## person, so a tiny bit of friction to go to a new conversation is
## acceptable. Collapse topics for everybody but the current partner. We
## mostly care about the away bubbles for other people when we're DMing.
## Likewise for chat."). A person may open one by its triangle, for that
## page alone: app/sidebar.js keeps no place's choice, so the next page is
## as uncluttered.
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

	## How a place starts when the page loads: `AlwaysOpen` is the page's
	## own place, and every other is `Collapsed`.
	Opening : [AlwaysOpen, Collapsed]

	## A place in the sidebar's order, its topics in theirs, and when any
	## of them last had a message.
	OrderedPlace : {
		label : Str,
		place : Place,
		topics : List(Topic),
		opening : SidebarOrder.Opening,
		latest : SidebarOrder.Latest,
	}

	## `places` in the order the sidebar shows them to `viewer` on a page of
	## `shown`, each with how it starts. The page's own topic is listed in
	## its place, after the others, even before its first message.
	ordered_places : {
		places : List(SidebarOrder.TimedPlace),
		shown : [Conversation(ConversationKey), NoConversation],
		viewer : UserId,
	} -> List(SidebarOrder.OrderedPlace)
	ordered_places = |{ places, shown, viewer }| {
		dated = places.map_with_index(
			|listed, at| { listed, at, latest: place_latest(listed.topics) },
		)
		is_here = |listed|
			match shown {
				Conversation(key) => listed.place == key.place()
				NoConversation => Bool.False
			}
		is_second = |listed| !is_here(listed) and is_own_dm(listed.place, viewer)
		here = dated.keep_if(|d| is_here(d.listed))
		second = dated.keep_if(|d| is_second(d.listed))
		by_latest = |one, other| newest_first((one.latest, one.at), (other.latest, other.at))
		rest = dated.drop_if(|d| is_here(d.listed) or is_second(d.listed)).sort_with(by_latest)
		after = rest.map(|d| ordered_place({ listed: d.listed, opening: Collapsed, shown }))
		List.concat(
			List.concat(
				here.map(|d| ordered_place({ listed: d.listed, opening: AlwaysOpen, shown })),
				second.map(|d| ordered_place({ listed: d.listed, opening: Collapsed, shown })),
			),
			after,
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

## The newest of a place's topics' last messages.
place_latest : List(SidebarOrder.TimedTopic) -> SidebarOrder.Latest
place_latest = |topics| topics.fold(NoMessages, |so_far, timed| newer(so_far, timed.latest))

## The later of `one` and `other`.
newer : SidebarOrder.Latest, SidebarOrder.Latest -> SidebarOrder.Latest
newer = |one, other|
	match (one, other) {
		(At(one_time), At(other_time)) if DateTime.compare(one_time, other_time) == Before => other
		(NoMessages, _) => other
		_ => one
	}

## Newest first, then those with no messages; two alike by where they were
## given (`at`).
newest_first : (SidebarOrder.Latest, U64), (SidebarOrder.Latest, U64) -> [Before, Same, After]
newest_first = |(one, one_at), (other, other_at)|
	match (one, other) {
		(At(one_time), At(other_time)) =>
			match DateTime.compare(one_time, other_time) {
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
	by_topic_latest = |one, other|
		newest_first((one.timed.latest, one.at), (other.timed.latest, other.at))
	sorted =
		listed.topics
			.map_with_index(|timed, at| { timed, at })
			.sort_with(by_topic_latest)
			.map(|d| d.timed.topic)
	topics =
		match shown {
			Conversation(key) if key.place() == listed.place and !sorted.contains(key.topic()) =>
				sorted.append(key.topic())
			_ => sorted
		}
	{
		label: listed.label,
		place: listed.place,
		topics,
		opening,
		latest: place_latest(listed.topics),
	}
}

## These are the tests of `SidebarOrder`: the order of a sidebar's places
## and topics, and how each place starts, on a DM's page, a channel's, the
## viewer's own DM's and a page of no conversation.
import Browse
import ConversationKey
import DateTime
import Directory
import Sample
import SidebarOrder
import SignedIn
import Topic
import UnvalidatedString

SidebarOrderSpec :: [].{}

## The sample's users and three more humans (ids 4, 5 and 6), with the
## channel `general`, which holds Steve.
directory : Directory
directory = Sample.with_default_channel(Sample.crowded_directory(3))

## Steve, signed in by a session.
steve : SignedIn
steve = SignedIn.dangerously_assume(Sample.user("Steve"))

## The topic `text` names.
topic : Str -> Topic
topic = |text| Topic.from_str(text) ?? crash "SidebarOrderSpec: a topic's name"

## The time `text` spells, on 2026-11-20.
latest_at : Str -> SidebarOrder.Latest
latest_at = |text| At(DateTime.from_str("2026-11-20T${text}Z") ?? crash "SidebarOrderSpec: a time")

## The conversation at `path`.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "SidebarOrderSpec: a path is UTF-8",
	directory,
}).map_ok(|found| found.key) ?? crash "SidebarOrderSpec: a conversation's path"

## Steve's places, in Browse's order (his own DM, Apoorva's, the three
## others', then `general`), each with the topics `topics_of` gives its URL
## path, and when each last had a message.
places_with : (Str -> List((Str, SidebarOrder.Latest))) -> List(SidebarOrder.TimedPlace)
places_with = |topics_of| {
	listed = Browse.places_for({ acting: steve, directory }) ?? crash "SidebarOrderSpec: Steve browses"
	listed.map(
		|{ label, place }| {
			label,
			place,
			topics: topics_of(ConversationKey.place_url_path(place)).map(
				|(name, latest)| { topic: topic(name), latest },
			),
		},
	)
}

## Steve's sidebar, a line a place: its path, how it starts, and its topics.
sidebar_lines : {
	shown : [Conversation(ConversationKey), NoConversation],
	topics_of : Str -> List((Str, SidebarOrder.Latest)),
} -> List(Str)
sidebar_lines = |{ shown, topics_of }|
	SidebarOrder.ordered_places({
		places: places_with(topics_of),
		shown,
		viewer: steve.user().id(),
	}).map(
		|ordered| {
			opening =
				match ordered.opening {
					AlwaysOpen => "always"
					Collapsed => "collapsed"
				}
			names = Str.join_with(ordered.topics.map(|one| one.to_str()), ",")
			"${ConversationKey.place_url_path(ordered.place)} ${opening} ${names}"
		},
	)

## Topics in a few places: `general` newest, then Steve's own DM, then the
## DM with 5; Apoorva's DM has the oldest message; 4 and 6 have none.
some_topics : Str -> List((Str, SidebarOrder.Latest))
some_topics = |path|
	match path {
		"/chat/dm/1_1" => [("notes", latest_at("11:00:00"))]
		"/chat/dm/1_2" => [("plans", latest_at("08:00:00")), ("lunch", latest_at("09:00:00"))]
		"/chat/dm/1_5" => [("hello", latest_at("10:00:00"))]
		"/chat/channel/general" => [("roc", latest_at("12:00:00"))]
		_ => []
	}

# A DM's page: the partner first, open always; Steve's own DM next,
# though it is newer than most; then the rest newest first, and those with
# no message in Browse's order; all but the partner collapsed. The
# partner's topics are newest first.
expect
	sidebar_lines({ shown: Conversation(key_at("/chat/dm/1_2/plans")), topics_of: some_topics })
		== [
			"/chat/dm/1_2 always lunch,plans",
			"/chat/dm/1_1 collapsed notes",
			"/chat/channel/general collapsed roc",
			"/chat/dm/1_5 collapsed hello",
			"/chat/dm/1_4 collapsed ",
			"/chat/dm/1_6 collapsed ",
		]
# A channel's page: the channel first, then Steve's own DM, whatever its
# time (Steve, 2026-11-20: "Steve comes second for Steve"), so it leads the
# DMs group; collapsed.
expect
	sidebar_lines({ shown: Conversation(key_at("/chat/channel/general/roc")), topics_of: some_topics })
		== [
			"/chat/channel/general always roc",
			"/chat/dm/1_1 collapsed notes",
			"/chat/dm/1_5 collapsed hello",
			"/chat/dm/1_2 collapsed lunch,plans",
			"/chat/dm/1_4 collapsed ",
			"/chat/dm/1_6 collapsed ",
		]
# Steve's own DM's page: it comes first and opens always, as any page's own
# place does.
expect
	sidebar_lines({ shown: Conversation(key_at("/chat/dm/1_1/notes")), topics_of: some_topics })
		== [
			"/chat/dm/1_1 always notes",
			"/chat/channel/general collapsed roc",
			"/chat/dm/1_5 collapsed hello",
			"/chat/dm/1_2 collapsed lunch,plans",
			"/chat/dm/1_4 collapsed ",
			"/chat/dm/1_6 collapsed ",
		]
# A page of no conversation (Browse's, Recent's): no place opens always,
# and Steve's own DM comes first.
expect
	sidebar_lines({ shown: NoConversation, topics_of: some_topics })
		== [
			"/chat/dm/1_1 collapsed notes",
			"/chat/channel/general collapsed roc",
			"/chat/dm/1_5 collapsed hello",
			"/chat/dm/1_2 collapsed lunch,plans",
			"/chat/dm/1_4 collapsed ",
			"/chat/dm/1_6 collapsed ",
		]
# Only the page's own place starts open: every other is collapsed, however
# new its last message (Steve, 2026-11-20: "Collapse topics for everybody
# but the current partner").
expect {
	four = |path|
		match path {
			"/chat/dm/1_4" => [("a", latest_at("09:00:00"))]
			"/chat/dm/1_5" => [("b", latest_at("10:00:00"))]
			"/chat/dm/1_6" => [("c", latest_at("11:00:00"))]
			"/chat/channel/general" => [("d", latest_at("12:00:00"))]
			_ => []
		}
	sidebar_lines({ shown: Conversation(key_at("/chat/dm/1_2/plans")), topics_of: four })
		== [
			"/chat/dm/1_2 always plans",
			"/chat/dm/1_1 collapsed ",
			"/chat/channel/general collapsed d",
			"/chat/dm/1_6 collapsed c",
			"/chat/dm/1_5 collapsed b",
			"/chat/dm/1_4 collapsed a",
		]
}
# Ties: places whose newest messages are of one second keep Browse's order,
# and so do topics of one second; topics with no message come after those
# with one, in the order given.
expect {
	tied = |path|
		match path {
			"/chat/dm/1_4" => [
				("x", NoMessages),
				("y", latest_at("10:00:00")),
				("w", latest_at("10:00:00")),
			]
			"/chat/dm/1_5" => [("z", latest_at("10:00:00"))]
			_ => []
		}
	sidebar_lines({ shown: NoConversation, topics_of: tied })
		== [
			"/chat/dm/1_1 collapsed ",
			"/chat/dm/1_4 collapsed y,w,x",
			"/chat/dm/1_5 collapsed z",
			"/chat/dm/1_2 collapsed ",
			"/chat/dm/1_6 collapsed ",
			"/chat/channel/general collapsed ",
		]
}
# A new human with nothing yet: the page's own place first with its topic,
# before its first message gives it a folder; every other place collapsed,
# in Browse's order.
expect
	sidebar_lines({ shown: Conversation(key_at("/chat/channel/general/welcome")), topics_of: |_| [] })
		== [
			"/chat/channel/general always welcome",
			"/chat/dm/1_1 collapsed ",
			"/chat/dm/1_2 collapsed ",
			"/chat/dm/1_4 collapsed ",
			"/chat/dm/1_5 collapsed ",
			"/chat/dm/1_6 collapsed ",
		]
# The page's own topic, before its first message, comes after its place's
# other topics; once it has a message it is ordered as they are, listed
# once.
expect
	sidebar_lines({ shown: Conversation(key_at("/chat/dm/1_2/fresh")), topics_of: some_topics }).first()
		== Ok("/chat/dm/1_2 always lunch,plans,fresh")
		and sidebar_lines({ shown: Conversation(key_at("/chat/dm/1_2/plans")), topics_of: some_topics }).first()
			== Ok("/chat/dm/1_2 always lunch,plans")
# The partner's place comes first even when it is the oldest.
expect {
	partner_oldest = |path|
		match path {
			"/chat/dm/1_2" => [("plans", latest_at("01:00:00"))]
			"/chat/channel/general" => [("roc", latest_at("12:00:00"))]
			_ => []
		}
	sidebar_lines({ shown: Conversation(key_at("/chat/dm/1_2/plans")), topics_of: partner_oldest }).take_first(3)
		== [
			"/chat/dm/1_2 always plans",
			"/chat/dm/1_1 collapsed ",
			"/chat/channel/general collapsed roc",
		]
}
# No places: nothing to order.
expect
	SidebarOrder.ordered_places({
		places: [],
		shown: NoConversation,
		viewer: steve.user().id(),
	}).is_empty()
# Steve's own DM comes second on a channel's page even when it is the
# oldest place, and leads the DMs.
expect {
	own_oldest = |path|
		match path {
			"/chat/dm/1_1" => [("notes", latest_at("01:00:00"))]
			"/chat/dm/1_2" => [("plans", latest_at("08:00:00"))]
			_ => []
		}
	sidebar_lines({ shown: Conversation(key_at("/chat/channel/general/roc")), topics_of: own_oldest }).take_first(3)
		== [
			"/chat/channel/general always roc",
			"/chat/dm/1_1 collapsed notes",
			"/chat/dm/1_2 collapsed plans",
		]
}

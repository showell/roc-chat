## These are the tests of `DmShortlist`: which of Steve's DMs his sidebar
## shows, and which wait behind its "more" row, at the edge of the window,
## past the cap, on the page of an old DM, and with nothing to show.
import Browse
import ConversationKey
import DateTime
import Directory
import DmShortlist
import Place
import Sample
import Seconds
import SidebarOrder
import SignedIn
import Timestamp
import Topic
import UnvalidatedString

DmShortlistSpec :: [].{}

## The sample's users and three more humans (ids 4, 5 and 6), with the
## channel `general`, which holds Steve.
directory : Directory
directory = Sample.with_default_channel(Sample.crowded_directory(3))

## Steve, signed in by a session.
steve : SignedIn
steve = SignedIn.dangerously_assume(Sample.user("Steve"))

## When the tests draw the sidebar: 2026-11-20T12:00:00Z, so the window
## starts at 2026-11-06T12:00:00Z.
now : Timestamp
now = Timestamp.at_second(1795176000)

## The time `text` spells, in November 2026.
latest_on : Str -> SidebarOrder.Latest
latest_on = |text| At(DateTime.from_str("2026-11-${text}Z") ?? crash "DmShortlistSpec: a time")

## The conversation at `path`.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "DmShortlistSpec: a path is UTF-8",
	directory,
}).map_ok(|found| found.key) ?? crash "DmShortlistSpec: a conversation's path"

## Steve's DMs on the page of `shown`, in the sidebar's order, each place
## with one topic whose last message is `latest_of` its URL path, as lines:
## the DM's path and whether it is `shown` or `waiting`.
shortlist_lines : {
	shown : ConversationKey,
	latest_of : Str -> SidebarOrder.Latest,
} -> List(Str)
shortlist_lines = |{ shown, latest_of }| {
	listed = Browse.places_for({ acting: steve, directory }) ?? crash "DmShortlistSpec: Steve browses"
	places = listed.map(
		|{ label, place }| {
			label,
			place,
			topics: [
				{
					topic: Topic.from_str("talk") ?? crash "DmShortlistSpec: a topic's name",
					latest: latest_of(ConversationKey.place_url_path(place)),
				},
			],
		},
	)
	dms = SidebarOrder.ordered_places({ places, shown: Conversation(shown), viewer: steve.user().id() })
		.drop_if(|ordered| is_channel(ordered.place))
	split = DmShortlist.split({ dms, current: shown.place(), now })
	List.concat(
		split.shown.map(|ordered| "${ConversationKey.place_url_path(ordered.place)} shown"),
		split.waiting.map(|ordered| "${ConversationKey.place_url_path(ordered.place)} waiting"),
	)
}

## Whether `place` is a channel.
is_channel : Place -> Bool
is_channel = |place|
	match place.which() {
		Channel(_) => Bool.True
		Dm(_) => Bool.False
	}

## The page of a topic in `general`, which is no DM.
general_page : ConversationKey
general_page = key_at("/chat/channel/general/roc")

# The window is 14 days, its edge inside: a DM whose last message is at the
# window's first second shows, and one a second older waits, as does a DM
# with no message at all. Those that wait keep the sidebar's order, newest
# first, then those with no message.
expect {
	edge = |path|
		match path {
			"/chat/dm/1_2" => latest_on("06T12:00:00")
			"/chat/dm/1_4" => latest_on("06T11:59:59")
			_ => NoMessages
		}
	DmShortlist.recent_window == Seconds.of(1209600)
		and shortlist_lines({ shown: general_page, latest_of: edge })
			== [
				"/chat/dm/1_2 shown",
				"/chat/dm/1_4 waiting",
				"/chat/dm/1_1 waiting",
				"/chat/dm/1_5 waiting",
				"/chat/dm/1_6 waiting",
			]
}
# At most three show: of four DMs with a recent message, the oldest waits;
# those shown are newest first, as the sidebar orders them.
expect {
	four = |path|
		match path {
			"/chat/dm/1_2" => latest_on("19T09:00:00")
			"/chat/dm/1_4" => latest_on("19T10:00:00")
			"/chat/dm/1_5" => latest_on("19T11:00:00")
			"/chat/dm/1_6" => latest_on("19T12:00:00")
			_ => NoMessages
		}
	DmShortlist.shown_most == 3
		and shortlist_lines({ shown: general_page, latest_of: four })
			== [
				"/chat/dm/1_6 shown",
				"/chat/dm/1_5 shown",
				"/chat/dm/1_4 shown",
				"/chat/dm/1_2 waiting",
				"/chat/dm/1_1 waiting",
			]
}
# The page's own DM always shows, though its last message is a month old,
# and takes no one's place: the three recent DMs show as on any other page.
# Steve's own DM, second on another's DM page, is held to the window too.
expect {
	old_partner = |path|
		match path {
			"/chat/dm/1_1" => latest_on("01T08:00:00")
			"/chat/dm/1_2" => latest_on("19T09:00:00")
			"/chat/dm/1_5" => latest_on("19T11:00:00")
			"/chat/dm/1_6" => latest_on("19T12:00:00")
			_ => At(DateTime.from_str("2026-10-20T12:00:00Z") ?? crash "DmShortlistSpec: a time")
		}
	shortlist_lines({ shown: key_at("/chat/dm/1_4/talk"), latest_of: old_partner })
		== [
			"/chat/dm/1_4 shown",
			"/chat/dm/1_6 shown",
			"/chat/dm/1_5 shown",
			"/chat/dm/1_2 shown",
			"/chat/dm/1_1 waiting",
		]
}
# Nothing recent: on a channel's page no DM shows and all wait; on a DM's
# page only that DM shows. With no DMs at all, nothing shows or waits.
expect {
	quiet = shortlist_lines({ shown: general_page, latest_of: |_| NoMessages })
	on_dm = shortlist_lines({ shown: key_at("/chat/dm/1_2/talk"), latest_of: |_| NoMessages })
	none = DmShortlist.split({ dms: [], current: general_page.place(), now })
	quiet.all(|line| line.ends_with(" waiting"))
		and quiet.len() == 5
		and on_dm.first() == Ok("/chat/dm/1_2 shown")
		and on_dm.drop_first(1).all(|line| line.ends_with(" waiting"))
		and none.shown.is_empty()
		and none.waiting.is_empty()
}

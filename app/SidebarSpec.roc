## These are the tests of `Sidebar`: a conversation page's sidebar, byte for
## byte, and the page around it.
import Author
import Browse
import ChannelRoster
import Channels
import Conversation
import ConversationKey
import ConversationPage
import Directory
import Reactions
import Sample
import Seconds
import Sidebar
import SidebarOrder
import SignedIn
import Timestamp
import Topic
import UnvalidatedString

SidebarSpec :: [].{}

## The sample's users, with the channel `general`, which holds Steve.
directory : Directory
directory = Sample.with_default_channel(Sample.directory)

## Steve, signed in by a session.
steve : SignedIn
steve = SignedIn.dangerously_assume(Sample.user("Steve"))

## When the tests draw the sidebar: 2026-11-02T19:11:32Z, the sample's
## time.
now : Timestamp
now = Timestamp.at_second(1793646692)

## The conversation at `path`, in `directory`.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "SidebarSpec: a path is UTF-8",
	directory,
}).map_ok(|found| found.key) ?? crash "SidebarSpec: a conversation's path"

## The places Browse lists for Steve, each with the topics `topics_of`
## gives its URL path, none of them with a message yet.
places_with : (Str -> List(Topic)) -> List(SidebarOrder.TimedPlace)
places_with = |topics_of| {
	listed = Browse.places_for({ acting: steve, directory }) ?? crash "SidebarSpec: Steve browses"
	listed.map(
		|{ label, place }| {
			label,
			place,
			topics: topics_of(ConversationKey.place_url_path(place)).map(
				|topic| { topic, latest: NoMessages },
			),
		},
	)
}

## Steve's sidebar on the page of the conversation at `current`, his places'
## topics given by `topics_of`.
sidebar_at : { current : Str, topics_of : Str -> List(Topic) } -> Str
sidebar_at = |{ current, topics_of }|
	Str.from_utf8_lossy(
		Sidebar.nav({
			places: places_with(topics_of),
			current: key_at(current),
			viewer: steve.user().id(),
			online_humans: [],
			now,
			rosters: [],
		}).to_utf8(),
	)

## The form that starts a topic at `path`, suggesting `general` when
## `suggests` is.
form_at : Str, [Suggests, NoSuggestion] -> Str
form_at = |path, suggests| {
	value =
		match suggests {
			Suggests => " value=\"general\""
			NoSuggestion => ""
		}
	"<form method=\"post\" action=\"${path}\"><p>New topic <input type=\"text\" name=\"topic\" required${value}></p>\n<button>Add topic</button></form>\n"
}

## One place: `name`, its button that offers a new topic, at `path`,
## starting as `opening`, holding `rows`, then its form. Steve's DM with
## Apoorva names her, offline, as the tests draw it.
place_html : {
	name : Str,
	path : Str,
	opening : Str,
	rows : Str,
	suggests : [Suggests, NoSuggestion],
} -> Str
place_html = |{ name, path, opening, rows, suggests }| {
	person =
		if path == "/chat/dm/1_2" {
			" data-person=\"2\" data-presence=\"offline\""
		} else {
			""
		}
	"<div class=\"sidebar-place\" data-section=\"${path}\" data-opening=\"${opening}\"${person}><p class=\"sidebar-place-name\">${name}</p>\n<button class=\"sidebar-new-topic\">New topic in ${name}</button>\n<ul class=\"sidebar-topics\">\n${rows}</ul>\n${form_at(path, suggests)}</div>\n"
}

## The places that wait behind a group's "more" row, under its `words`.
more_html : { words : Str, places : Str } -> Str
more_html = |{ words, places }|
	"<div class=\"sidebar-more\">\n<p class=\"sidebar-more-name\">${words}</p>\n${places}</div>\n"

## The group `group` headed `heading`, holding `places`.
group_html : {
	group : Str,
	heading : Str,
	places : Str,
} -> Str
group_html = |{ group, heading, places }|
	"<div class=\"sidebar-section\" data-group=\"${group}\"><p class=\"sidebar-section-name\">${heading}</p>\n${places}</div>\n"

# The DMs under their heading, then the channels under theirs, each group in
# `SidebarOrder`'s order: the page's own place first, always open, then the
# others (with no messages yet, in Browse's order), collapsed. Apoorva's DM,
# with no message, waits behind the DMs' "more" row (`DmShortlist`). Each
# place's topics are under it, only the page's own topic
# marked: `plans` in Steve's own DM, and not `plans` in `general`, a topic
# of the same name in another place. A place with no topics lists none and
# suggests its first.
expect
	sidebar_at({
		current: "/chat/dm/1_1/plans",
		topics_of: |path|
			match path {
				"/chat/dm/1_1" => [Sample.other, Sample.plans]
				"/chat/channel/general" => [Sample.plans]
				_ => []
			},
	})
		== "<nav class=\"sidebar\">\n${
			group_html({
				group: "dms",
				heading: "DMs",
				places: Str.concat(
					place_html({
						name: "Steve",
						path: "/chat/dm/1_1",
						opening: "always",
						rows: "<li><a href=\"/chat/dm/1_1/other\">other</a></li>\n<li><a class=\"current\" href=\"/chat/dm/1_1/plans\">plans</a></li>\n",
						suggests: NoSuggestion,
					}),
					more_html({
						words: "1 more person…",
						places: place_html({
							name: "Apoorva",
							path: "/chat/dm/1_2",
							opening: "collapsed",
							rows: "",
							suggests: Suggests,
						}),
					}),
				),
			})
		}${
			group_html({
				group: "channels",
				heading: "Channels",
				places: place_html({
					name: "#general",
					path: "/chat/channel/general",
					opening: "collapsed",
					rows: "<li><a href=\"/chat/channel/general/plans\">plans</a></li>\n",
					suggests: NoSuggestion,
				}),
			})
		}</nav>\n"
# On a DM's page, the partner's place comes first, and Steve's own DM next,
# collapsed, waiting behind the "more" row, as it has no message. The
# page's own topic, before its first message gives it a folder, is listed
# in its place after the others, marked, and its place's form then
# suggests nothing.
expect
	sidebar_at({
		current: "/chat/dm/1_2/plans",
		topics_of: |path|
			match path {
				"/chat/dm/1_1" => [Sample.other]
				_ => []
			},
	})
		== "<nav class=\"sidebar\">\n${
			group_html({
				group: "dms",
				heading: "DMs",
				places: Str.concat(
					place_html({
						name: "Apoorva",
						path: "/chat/dm/1_2",
						opening: "always",
						rows: "<li><a class=\"current\" href=\"/chat/dm/1_2/plans\">plans</a></li>\n",
						suggests: NoSuggestion,
					}),
					more_html({
						words: "1 more person…",
						places: place_html({
							name: "Steve",
							path: "/chat/dm/1_1",
							opening: "collapsed",
							rows: "<li><a href=\"/chat/dm/1_1/other\">other</a></li>\n",
							suggests: NoSuggestion,
						}),
					}),
				),
			})
		}${
			group_html({
				group: "channels",
				heading: "Channels",
				places: place_html({
					name: "#general",
					path: "/chat/channel/general",
					opening: "collapsed",
					rows: "",
					suggests: Suggests,
				}),
			})
		}</nav>\n"
# On a channel's page, the Channels group comes first, its place open, and
# the DMs follow; on a DM's page (above) the DMs come first. Each group's
# markup is the same either way, so a group's kept state holds across the
# swap. With no message in any DM, none shows: both wait behind the "more"
# row, which the group still holds.
expect
	sidebar_at({ current: "/chat/channel/general/plans", topics_of: |_| [] })
		== "<nav class=\"sidebar\">\n${
			group_html({
				group: "channels",
				heading: "Channels",
				places: place_html({
					name: "#general",
					path: "/chat/channel/general",
					opening: "always",
					rows: "<li><a class=\"current\" href=\"/chat/channel/general/plans\">plans</a></li>\n",
					suggests: NoSuggestion,
				}),
			})
		}${
			group_html({
				group: "dms",
				heading: "DMs",
				places: more_html({
					words: "2 more people…",
					places: Str.concat(
						place_html({
							name: "Steve",
							path: "/chat/dm/1_1",
							opening: "collapsed",
							rows: "",
							suggests: Suggests,
						}),
						place_html({
							name: "Apoorva",
							path: "/chat/dm/1_2",
							opening: "collapsed",
							rows: "",
							suggests: Suggests,
						}),
					),
				}),
			})
		}</nav>\n"
# A place with a message starts collapsed too, as every place but the
# page's own does: here `general`, and Apoorva's DM, which has none. On
# this DM's page the DMs come first.
expect {
	dated = places_with(|_| []).map(
		|listed|
			if ConversationKey.place_url_path(listed.place) == "/chat/channel/general" {
				{ ..listed, topics: [{ topic: Sample.other, latest: At(Sample.hello.time) }] }
			} else {
				listed
			},
	)
	shown = Str.from_utf8_lossy(
		Sidebar.nav({
			places: dated,
			current: key_at("/chat/dm/1_1/plans"),
			viewer: steve.user().id(),
			online_humans: [],
			now,
			rosters: [],
		}).to_utf8(),
	)
	general = "data-section=\"/chat/channel/general\" data-opening=\"collapsed\">"
	apoorva = "data-section=\"/chat/dm/1_2\" data-opening=\"collapsed\""
	match shown.split_on(general) {
		[before, after] => before.contains(apoorva) and !after.contains(apoorva)
		_ => Bool.False
	}
}
# A DM with another human names them and says whether they are online; the
# viewer's own DM and a channel name no one.
expect {
	drawn = |online_humans|
		Str.from_utf8_lossy(
			Sidebar.nav({
				places: places_with(|_| []),
				current: key_at("/chat/dm/1_1/plans"),
				viewer: steve.user().id(),
				online_humans,
				now,
				rosters: [],
			}).to_utf8(),
		)
	apoorva = Sample.user("Apoorva").id()
	drawn([apoorva]).contains("data-section=\"/chat/dm/1_2\" data-opening=\"collapsed\" data-person=\"2\" data-presence=\"online\">")
		and drawn([]).contains("data-section=\"/chat/dm/1_2\" data-opening=\"collapsed\" data-person=\"2\" data-presence=\"offline\">")
		and drawn([steve.user().id(), apoorva]).contains("data-section=\"/chat/dm/1_1\" data-opening=\"always\">")
		and drawn([apoorva]).contains("data-section=\"/chat/channel/general\" data-opening=\"collapsed\">")
}
# A group with no places is left out: with no channel, no Channels heading.
expect {
	dms_only = places_with(|_| []).drop_if(
		|listed| ConversationKey.place_url_path(listed.place) == "/chat/channel/general",
	)
	shown = Str.from_utf8_lossy(
		Sidebar.nav({
			places: dms_only,
			current: key_at("/chat/dm/1_1/plans"),
			viewer: steve.user().id(),
			online_humans: [],
			now,
			rosters: [],
		}).to_utf8(),
	)
	!shown.contains("Channels") and shown.starts_with("<nav class=\"sidebar\">\n<div class=\"sidebar-section\" data-group=\"dms\"><p class=\"sidebar-section-name\">DMs</p>\n")
}
# The drawer's button.
expect Sidebar.toggle.to_utf8() == "<button class=\"sidebar-toggle\">Conversations</button>\n".to_utf8()

## A conversation's page for Steve, with `sidebar`.
page_with : ConversationPage.SidebarShown -> Str
page_with = |sidebar|
	Str.from_utf8_lossy(
		ConversationPage.conversation({
			conversation: Conversation.empty(Sample.plans),
			reactions: Reactions.empty,
			key: key_at("/chat/dm/1_1/plans"),
			viewer: steve,
			users: directory.users(),
			sidebar,
		}).to_utf8(),
	)

# A human's page: the toggle after the top bar, the sidebar first in the
# layout, and its script after chrome.js; a key's page has none of them.
expect {
	places = places_with(|_| [])
	nav = Str.from_utf8_lossy(
		Sidebar.nav({
			places,
			current: key_at("/chat/dm/1_1/plans"),
			viewer: steve.user().id(),
			online_humans: [],
			now,
			rosters: [],
		}).to_utf8(),
	)
	with_sidebar = page_with(Sidebar({ places, online_humans: [], notice: NoNotice, now, rosters: [] }))
	without = page_with(NoSidebar)
	with_sidebar.contains("</header>\n<button class=\"sidebar-toggle\">Conversations</button>\n<div class=\"layout\">${nav}<div class=\"messages\"")
		and with_sidebar.contains("</a></span> <p class=\"notice-strip\"></p> <div class=\"top-user\">")
		and !without.contains("notice-strip")
		and with_sidebar.contains("<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/sidebar-popups.js\"></script>\n<script src=\"/chat/assets/sidebar.js\"></script>\n<script src=\"/chat/assets/compose.js\"></script>\n")
		and without.contains("</header>\n<div class=\"layout\"><div class=\"messages\"")
		and !without.contains("sidebar")
}
# A channel's members, after its topics and before its form, in its
# roster's order: who posted lately with when, then the rest; a human with
# their presence and the viewer's DM with them, an agent marked as one. A
# DM lists none.
expect {
	everyone_in_general =
		Directory.from_stored({
			users: Sample.directory.users(),
			channels: Channels.from_stored([{ name: Channels.default_name, members: "1\n2\n3\n".to_utf8() }])
				?? crash "SidebarSpec: a members file",
		})
			?? crash "SidebarSpec: the members are users"
	channel =
		everyone_in_general.channels().channel(Channels.default_name)
			?? crash "SidebarSpec: general is a channel"
	roster = ChannelRoster.roster({
		channel,
		users: everyone_in_general.users(),
		viewer: Sample.human("Steve"),
		posts: [{ author: Author.from_str("CC") ?? crash "SidebarSpec: a name", time: Sample.hello.time }],
		now: now.plus(Seconds.of(7200)),
	})
	shown = Str.from_utf8_lossy(
		Sidebar.nav({
			places: places_with(|_| []),
			current: key_at("/chat/dm/1_1/plans"),
			viewer: steve.user().id(),
			online_humans: [Sample.user("Apoorva").id()],
			now,
			rosters: [roster],
		}).to_utf8(),
	)
	members = "<ul class=\"sidebar-members\">\n<li data-person=\"3\" data-kind=\"agent\"><span class=\"sidebar-member-name\">CC</span><span class=\"sidebar-member-words\">posted 2 hours ago</span></li>\n<li data-person=\"2\" data-kind=\"human\" data-presence=\"online\" data-section=\"/chat/dm/1_2\"><span class=\"sidebar-member-name\">Apoorva</span></li>\n<li data-person=\"1\" data-kind=\"human\" data-presence=\"offline\" data-section=\"/chat/dm/1_1\"><span class=\"sidebar-member-name\">Steve</span></li>\n</ul>\n"
	shown.contains("<ul class=\"sidebar-topics\">\n</ul>\n${members}<form method=\"post\" action=\"/chat/channel/general\">")
		and shown.split_on("sidebar-members").len() == 2
}

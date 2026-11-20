## These are the tests of `Sidebar`: a conversation page's sidebar, byte for
## byte, and the page around it.
import Browse
import Conversation
import ConversationKey
import ConversationPage
import Directory
import Reactions
import Sample
import Sidebar
import SidebarOrder
import SignedIn
import Topic
import UnvalidatedString

SidebarSpec :: [].{}

## The sample's users, with the channel `general`, which holds Steve.
directory : Directory
directory = Sample.with_default_channel(Sample.directory)

## Steve, signed in by a session.
steve : SignedIn
steve = SignedIn.dangerously_assume(Sample.user("Steve"))

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

## One place: `name`, at `path`, starting as `opening`, holding `rows`,
## then its form. Steve's DM with Apoorva names her, offline, as the tests
## draw it.
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
	"<div class=\"sidebar-place\" data-section=\"${path}\" data-opening=\"${opening}\"${person}><p class=\"sidebar-place-name\">${name}</p>\n<ul class=\"sidebar-topics\">\n${rows}</ul>\n${form_at(path, suggests)}</div>\n"
}

## A place's row for a place with no topics.
empty_row : Str
empty_row = "<li class=\"sidebar-empty\">No sessions yet</li>\n"

# The page's own place first, always open, then the others in
# `SidebarOrder`'s order (with no messages yet, Browse's), collapsed, with
# no headings. Each place's topics are under it, only the page's own topic
# marked: `plans` in Steve's own DM, and not `plans` in `general`, a topic
# of the same name in another place. A place with no topics says so and
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
		== "<nav class=\"sidebar\">\n${place_html({ name: "Steve", path: "/chat/dm/1_1", opening: "always", rows: "<li><a href=\"/chat/dm/1_1/other\">other</a></li>\n<li><a class=\"current\" href=\"/chat/dm/1_1/plans\">plans</a></li>\n", suggests: NoSuggestion })}${
			place_html({
				name: "Apoorva",
				path: "/chat/dm/1_2",
				opening: "collapsed",
				rows: empty_row,
				suggests: Suggests,
			})
		}${
			place_html({
				name: "#general",
				path: "/chat/channel/general",
				opening: "collapsed",
				rows: "<li><a href=\"/chat/channel/general/plans\">plans</a></li>\n",
				suggests: NoSuggestion,
			})
		}</nav>\n"
# On a DM's page, the partner's place comes first, and Steve's own DM next,
# collapsed. The page's own topic, before its first message gives it a
# folder, is listed in its place after the others, marked, and its place's
# form then suggests nothing.
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
			place_html({
				name: "Apoorva",
				path: "/chat/dm/1_2",
				opening: "always",
				rows: "<li><a class=\"current\" href=\"/chat/dm/1_2/plans\">plans</a></li>\n",
				suggests: NoSuggestion,
			})
		}${
			place_html({
				name: "Steve",
				path: "/chat/dm/1_1",
				opening: "collapsed",
				rows: "<li><a href=\"/chat/dm/1_1/other\">other</a></li>\n",
				suggests: NoSuggestion,
			})
		}${
			place_html({
				name: "#general",
				path: "/chat/channel/general",
				opening: "collapsed",
				rows: empty_row,
				suggests: Suggests,
			})
		}</nav>\n"
# A place with a message comes before those with none, and starts open:
# here `general`, ahead of Apoorva's DM, which Browse lists first.
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
		}).to_utf8(),
	)
	general = "data-section=\"/chat/channel/general\" data-opening=\"open\">"
	apoorva = "data-section=\"/chat/dm/1_2\" data-opening=\"collapsed\""
	match shown.split_on(general) {
		[before, after] => !before.contains(apoorva) and after.contains(apoorva)
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
			}).to_utf8(),
		)
	apoorva = Sample.user("Apoorva").id()
	drawn([apoorva]).contains("data-section=\"/chat/dm/1_2\" data-opening=\"collapsed\" data-person=\"2\" data-presence=\"online\">")
		and drawn([]).contains("data-section=\"/chat/dm/1_2\" data-opening=\"collapsed\" data-person=\"2\" data-presence=\"offline\">")
		and drawn([steve.user().id(), apoorva]).contains("data-section=\"/chat/dm/1_1\" data-opening=\"always\">")
		and drawn([apoorva]).contains("data-section=\"/chat/channel/general\" data-opening=\"collapsed\">")
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
		}).to_utf8(),
	)
	with_sidebar = page_with(Sidebar({ places, online_humans: [], notice: NoNotice }))
	without = page_with(NoSidebar)
	with_sidebar.contains("</header>\n<button class=\"sidebar-toggle\">Conversations</button>\n<p class=\"notice-strip\"></p>\n<div class=\"layout\">${nav}<div class=\"messages\"")
		and with_sidebar.contains("<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/sidebar.js\"></script>\n<script src=\"/chat/assets/compose.js\"></script>\n")
		and without.contains("</header>\n<div class=\"layout\"><div class=\"messages\"")
		and !without.contains("sidebar")
}

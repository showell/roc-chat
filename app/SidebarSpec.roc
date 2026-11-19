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
## gives its URL path.
places_with : (Str -> List(Topic)) -> List(Browse.PlaceWithTopics)
places_with = |topics_of| {
	listed = Browse.places_for({ acting: steve, directory }) ?? crash "SidebarSpec: Steve browses"
	listed.map(
		|{ label, place }| {
			label,
			place,
			topics: topics_of(ConversationKey.place_url_path(place)),
		},
	)
}

## Steve's sidebar on the page of the conversation at `current`, his places'
## topics given by `topics_of`.
sidebar_at : { current : Str, topics_of : Str -> List(Topic) } -> Str
sidebar_at = |{ current, topics_of }|
	Str.from_utf8_lossy(
		Sidebar.nav({ places: places_with(topics_of), current: key_at(current) }).to_utf8(),
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

## One place: `name`, at `path`, holding `rows`, then its form.
place_html : {
	name : Str,
	path : Str,
	rows : Str,
	suggests : [Suggests, NoSuggestion],
} -> Str
place_html = |{ name, path, rows, suggests }|
	"<div class=\"sidebar-place\" data-section=\"${path}\"><p class=\"sidebar-place-name\">${name}</p>\n<ul class=\"sidebar-topics\">\n${rows}</ul>\n${form_at(path, suggests)}</div>\n"

## A place's row for a place with no topics.
empty_row : Str
empty_row = "<li class=\"sidebar-empty\">No sessions yet</li>\n"

# Steve's DMs, then his channels, each place's topics under it, only the
# page's own topic marked: `plans` in his own DM, and not `plans` in
# `general`, a topic of the same name in another place. A place with no
# topics says so and suggests its first.
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
		== "<nav class=\"sidebar\">\n<p class=\"sidebar-heading\">DMs</p>\n${place_html({ name: "Steve", path: "/chat/dm/1_1", rows: "<li><a href=\"/chat/dm/1_1/other\">other</a></li>\n<li><a class=\"current\" href=\"/chat/dm/1_1/plans\">plans</a></li>\n", suggests: NoSuggestion })}${
			place_html({
				name: "Apoorva",
				path: "/chat/dm/1_2",
				rows: empty_row,
				suggests: Suggests,
			})
		}<p class=\"sidebar-heading\">Channels</p>\n${place_html({ name: "#general", path: "/chat/channel/general", rows: "<li><a href=\"/chat/channel/general/plans\">plans</a></li>\n", suggests: NoSuggestion })}</nav>\n"
# The page's own topic, before its first message gives it a folder, is
# listed in its place after the others, marked, and its place's form then
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
		== "<nav class=\"sidebar\">\n<p class=\"sidebar-heading\">DMs</p>\n${place_html({ name: "Steve", path: "/chat/dm/1_1", rows: "<li><a href=\"/chat/dm/1_1/other\">other</a></li>\n", suggests: NoSuggestion })}${
			place_html({
				name: "Apoorva",
				path: "/chat/dm/1_2",
				rows: "<li><a class=\"current\" href=\"/chat/dm/1_2/plans\">plans</a></li>\n",
				suggests: NoSuggestion,
			})
		}<p class=\"sidebar-heading\">Channels</p>\n${place_html({ name: "#general", path: "/chat/channel/general", rows: empty_row, suggests: Suggests })}</nav>\n"
# A group with no places has no heading: here, no channels.
expect {
	dms_only = places_with(|_| []).keep_if(
		|listed| ConversationKey.place_url_path(listed.place) != "/chat/channel/general",
	)
	shown = Str.from_utf8_lossy(
		Sidebar.nav({ places: dms_only, current: key_at("/chat/dm/1_1/plans") }).to_utf8(),
	)
	shown.contains("<p class=\"sidebar-heading\">DMs</p>")
		and !shown.contains("Channels")
		and !shown.contains("/chat/channel")
}
# The drawer's button.
expect Sidebar.toggle.to_utf8() == "<button class=\"sidebar-toggle\">Conversations</button>\n".to_utf8()

## A conversation's page for Steve, with `sidebar`.
page_with : [NoSidebar, Sidebar(List(Browse.PlaceWithTopics))] -> Str
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
		Sidebar.nav({ places, current: key_at("/chat/dm/1_1/plans") }).to_utf8(),
	)
	with_sidebar = page_with(Sidebar(places))
	without = page_with(NoSidebar)
	with_sidebar.contains("</header>\n<button class=\"sidebar-toggle\">Conversations</button>\n<div class=\"layout\">${nav}<div class=\"messages\"")
		and with_sidebar.contains("<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/sidebar.js\"></script>\n<script src=\"/chat/assets/compose.js\"></script>\n")
		and without.contains("</header>\n<div class=\"layout\"><div class=\"messages\"")
		and !without.contains("sidebar")
}

## This module is the one home of the scripts the pages load. Each file is
## compiled into the app, so the server always sends exactly what the file
## holds. Every page loads app/palette.js in its head, which sets the
## colours before the first paint. A conversation's page ends with
## app/chrome.js (its top bar), app/sidebar.js (its sidebar, when it has
## one), app/compose.js (its compose box), app/emoji.js (the emojis, and
## the compose box's autocomplete of them), app/feed.js (its messages) and
## app/cite.js (citations of messages), app/actions.js (each message's
## reactions, quote-reply, citation and edit) and app/search.js (the
## search across every topic).
## Any other signed-in human's page ends with
## app/chrome.js and app/panel.js (the card its parts sit in). The join page
## ends with app/join.js, which reads the invite's code from the link, and
## Recent with app/recent.js, which styles its tiles and their times, and the
## device code page with app/devices.js, which makes it live. `Route` serves each at its
## `url_path`, and `PageKit.script` links to them.
import "palette.js" as palette_source : Str
import "chrome.js" as chrome_source : Str
import "sidebar.js" as sidebar_source : Str
import "compose.js" as compose_source : Str
import "emoji.js" as emoji_source : Str
import "feed.js" as feed_source : Str
import "cite.js" as cite_source : Str
import "actions.js" as actions_source : Str
import "panel.js" as panel_source : Str
import "join.js" as join_source : Str
import "recent.js" as recent_source : Str
import "devices.js" as devices_source : Str
import "search.js" as search_source : Str

Script := [
	Palette,
	Chrome,
	Sidebar,
	Compose,
	Emoji,
	Feed,
	Cite,
	Actions,
	Search,
	Panel,
	Join,
	Recent,
	Devices,
].{

	## Every script the pages load.
	all_scripts : List(Script)
	all_scripts = [
		Script.Palette,
		Script.Chrome,
		Script.Sidebar,
		Script.Compose,
		Script.Emoji,
		Script.Feed,
		Script.Cite,
		Script.Actions,
		Script.Search,
		Script.Panel,
		Script.Join,
		Script.Recent,
		Script.Devices,
	]

	## Where the script is served: `/chat/assets/` and its file's name.
	url_path : Script -> Str
	url_path = |script| "/chat/assets/${file_name(script)}"

	## The script's bytes, exactly as its file holds them.
	bytes : Script -> List(U8)
	bytes = |script| source(script).to_utf8()

	is_eq : _
}

## The name of the script's file in app/.
file_name : Script -> Str
file_name = |script|
	match script {
		Palette => "palette.js"
		Chrome => "chrome.js"
		Sidebar => "sidebar.js"
		Compose => "compose.js"
		Emoji => "emoji.js"
		Feed => "feed.js"
		Cite => "cite.js"
		Actions => "actions.js"
		Search => "search.js"
		Panel => "panel.js"
		Join => "join.js"
		Recent => "recent.js"
		Devices => "devices.js"
	}

## The script's file, as compiled in.
source : Script -> Str
source = |script|
	match script {
		Palette => palette_source
		Chrome => chrome_source
		Sidebar => sidebar_source
		Compose => compose_source
		Emoji => emoji_source
		Feed => feed_source
		Cite => cite_source
		Actions => actions_source
		Search => search_source
		Panel => panel_source
		Join => join_source
		Recent => recent_source
		Devices => devices_source
	}

# ── tests
# Each script at its path, and each its whole file, from its first line to
# its last.
expect
	Script.all_scripts.map(Script.url_path)
		== [
			"/chat/assets/palette.js",
			"/chat/assets/chrome.js",
			"/chat/assets/sidebar.js",
			"/chat/assets/compose.js",
			"/chat/assets/emoji.js",
			"/chat/assets/feed.js",
			"/chat/assets/cite.js",
			"/chat/assets/actions.js",
			"/chat/assets/search.js",
			"/chat/assets/panel.js",
			"/chat/assets/join.js",
			"/chat/assets/recent.js",
			"/chat/assets/devices.js",
		]
expect palette_source.starts_with("// This script runs in the head of every page")
expect
	[
		sidebar_source,
		compose_source,
		emoji_source,
		feed_source,
		cite_source,
		actions_source,
		search_source,
	].all(|text| text.starts_with("// This script runs on a conversation page"))
expect [
	chrome_source,
	panel_source,
].all(|text| text.starts_with("// This script runs on a signed-in"))
expect join_source.starts_with("// This script runs on the join page")
expect recent_source.starts_with("// This script runs on the Recent page")
expect devices_source.starts_with("// This script runs on the device code page")
expect
	[
		palette_source,
		chrome_source,
		sidebar_source,
		compose_source,
		emoji_source,
		feed_source,
		cite_source,
		actions_source,
		search_source,
		panel_source,
		join_source,
		recent_source,
		devices_source,
	].all(|text| text.ends_with("\n})();\n"))
expect
	[
		(Script.Palette, palette_source),
		(Script.Chrome, chrome_source),
		(Script.Sidebar, sidebar_source),
		(Script.Compose, compose_source),
		(Script.Emoji, emoji_source),
		(Script.Feed, feed_source),
		(Script.Cite, cite_source),
		(Script.Actions, actions_source),
		(Script.Search, search_source),
		(Script.Panel, panel_source),
		(Script.Join, join_source),
		(Script.Recent, recent_source),
		(Script.Devices, devices_source),
	].all(|(script, text)| script.bytes() == text.to_utf8())

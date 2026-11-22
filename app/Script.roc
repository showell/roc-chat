## This module is the one home of the scripts the pages load, and of the
## order each page loads them in. Each file is compiled into the app, so the
## server always sends exactly what the file holds. Every page loads
## app/palette.js in its head (`head_script`), which sets the colours before
## the first paint. A conversation's page ends with app/chrome.js (its top
## bar), app/keys.js (its key table and Escape's closers),
## app/sidebar-popups.js and app/sidebar.js (its sidebar and the sidebar's
## popups, when it has one), app/compose.js (its compose box),
## app/emoji.js (the emojis, and the compose box's autocomplete of them),
## app/feed.js (its messages) and app/citation.js (citations of messages),
## app/actions.js (each message's reactions, quote-reply, citation and edit)
## and app/search.js (the search across every topic):
## `conversation_scripts`. Any other signed-in human's page ends with
## app/chrome.js and app/panel.js (the card its parts sit in), Recent with
## app/keys.js, app/recent.js (its tiles and their times) and app/search.js
## between them,
## and the device code page with app/devices.js (which makes it live) before
## them: `panel_scripts`. A signed-out visitor's page (the sign-in page,
## the name a GitHub sign-up chooses) ends with app/sign-in.js, which draws
## it as a card: `signed_out_scripts`. The join page ends with it and
## app/join.js, which reads the invite's code from the link: `join_scripts`.
## `Route` serves each at
## its `url_path`, and `PageKit.script` links to them.
##
## A script uses what the scripts before it on its page give (`Keys`,
## `Compose`, `Viewport`, ...), so tools/check_script_calls.shale reads each
## page's order from the lists here and holds every such use to it.
import "palette.js" as palette_source : Str
import "chrome.js" as chrome_source : Str
import "keys.js" as keys_source : Str
import "sidebar-popups.js" as sidebar_popups_source : Str
import "sidebar.js" as sidebar_source : Str
import "compose.js" as compose_source : Str
import "emoji.js" as emoji_source : Str
import "feed.js" as feed_source : Str
import "citation.js" as citation_source : Str
import "actions.js" as actions_source : Str
import "panel.js" as panel_source : Str
import "join.js" as join_source : Str
import "sign-in.js" as sign_in_source : Str
import "recent.js" as recent_source : Str
import "devices.js" as devices_source : Str
import "search.js" as search_source : Str

Script := [
	Palette,
	Chrome,
	Keys,
	SidebarPopups,
	Sidebar,
	Compose,
	Emoji,
	Feed,
	Citation,
	Actions,
	Search,
	Panel,
	Join,
	SignIn,
	Recent,
	Devices,
].{

	## Every script the pages load.
	all_scripts : List(Script)
	all_scripts = [
		Script.Palette,
		Script.Chrome,
		Script.Keys,
		Script.SidebarPopups,
		Script.Sidebar,
		Script.Compose,
		Script.Emoji,
		Script.Feed,
		Script.Citation,
		Script.Actions,
		Script.Search,
		Script.Panel,
		Script.Join,
		Script.SignIn,
		Script.Recent,
		Script.Devices,
	]

	## The script every page loads in its head: app/palette.js.
	head_script : Script
	head_script = Script.Palette

	## The scripts at the foot of a conversation's page, in the order they
	## run, with its sidebar's or without.
	conversation_scripts : [Alone, WithSidebar] -> List(Script)
	conversation_scripts = |sidebar|
		match sidebar {
			Alone => [
				Script.Chrome,
				Script.Keys,
				Script.Compose,
				Script.Emoji,
				Script.Feed,
				Script.Citation,
				Script.Actions,
				Script.Search,
			]
			WithSidebar => [
				Script.Chrome,
				Script.Keys,
				Script.SidebarPopups,
				Script.Sidebar,
				Script.Compose,
				Script.Emoji,
				Script.Feed,
				Script.Citation,
				Script.Actions,
				Script.Search,
			]
		}

	## The scripts after a signed-in page's panel, in the order they run:
	## a plain page's, Recent's or the device code page's.
	panel_scripts : [PlainPanel, RecentPanel, DeviceCodePanel] -> List(Script)
	panel_scripts = |panel|
		match panel {
			PlainPanel => [Script.Chrome, Script.Panel]
			RecentPanel => [Script.Chrome, Script.Keys, Script.Recent, Script.Search, Script.Panel]
			DeviceCodePanel => [Script.Devices, Script.Chrome, Script.Panel]
		}

	## The scripts at the foot of a signed-out visitor's page.
	signed_out_scripts : List(Script)
	signed_out_scripts = [Script.SignIn]

	## The scripts at the foot of the join page.
	join_scripts : List(Script)
	join_scripts = [Script.SignIn, Script.Join]

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
		Keys => "keys.js"
		SidebarPopups => "sidebar-popups.js"
		Sidebar => "sidebar.js"
		Compose => "compose.js"
		Emoji => "emoji.js"
		Feed => "feed.js"
		Citation => "citation.js"
		Actions => "actions.js"
		Search => "search.js"
		Panel => "panel.js"
		Join => "join.js"
		SignIn => "sign-in.js"
		Recent => "recent.js"
		Devices => "devices.js"
	}

## The script's file, as compiled in.
source : Script -> Str
source = |script|
	match script {
		Palette => palette_source
		Chrome => chrome_source
		Keys => keys_source
		SidebarPopups => sidebar_popups_source
		Sidebar => sidebar_source
		Compose => compose_source
		Emoji => emoji_source
		Feed => feed_source
		Citation => citation_source
		Actions => actions_source
		Search => search_source
		Panel => panel_source
		Join => join_source
		SignIn => sign_in_source
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
			"/chat/assets/keys.js",
			"/chat/assets/sidebar-popups.js",
			"/chat/assets/sidebar.js",
			"/chat/assets/compose.js",
			"/chat/assets/emoji.js",
			"/chat/assets/feed.js",
			"/chat/assets/citation.js",
			"/chat/assets/actions.js",
			"/chat/assets/search.js",
			"/chat/assets/panel.js",
			"/chat/assets/join.js",
			"/chat/assets/sign-in.js",
			"/chat/assets/recent.js",
			"/chat/assets/devices.js",
		]
expect palette_source.starts_with("// This script runs in the head of every page")
expect
	[
		keys_source,
		sidebar_popups_source,
		sidebar_source,
		compose_source,
		emoji_source,
		feed_source,
		citation_source,
		actions_source,
		search_source,
	].all(|text| text.starts_with("// This script runs on a conversation page"))
expect [
	chrome_source,
	panel_source,
].all(|text| text.starts_with("// This script runs on a signed-in"))
expect join_source.starts_with("// This script runs on the join page")
expect sign_in_source.starts_with("// This script runs on a signed-out visitor's page")
expect recent_source.starts_with("// This script runs on the Recent page")
expect devices_source.starts_with("// This script runs on the device code page")
expect
	[
		palette_source,
		chrome_source,
		keys_source,
		sidebar_popups_source,
		sidebar_source,
		compose_source,
		emoji_source,
		feed_source,
		citation_source,
		actions_source,
		search_source,
		panel_source,
		join_source,
		sign_in_source,
		recent_source,
		devices_source,
	].all(|text| text.ends_with("\n})();\n"))
expect
	[
		(Script.Palette, palette_source),
		(Script.Chrome, chrome_source),
		(Script.Keys, keys_source),
		(Script.SidebarPopups, sidebar_popups_source),
		(Script.Sidebar, sidebar_source),
		(Script.Compose, compose_source),
		(Script.Emoji, emoji_source),
		(Script.Feed, feed_source),
		(Script.Citation, citation_source),
		(Script.Actions, actions_source),
		(Script.Search, search_source),
		(Script.Panel, panel_source),
		(Script.Join, join_source),
		(Script.SignIn, sign_in_source),
		(Script.Recent, recent_source),
		(Script.Devices, devices_source),
	].all(|(script, text)| script.bytes() == text.to_utf8())

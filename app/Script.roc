## This module is the one home of the scripts the pages load. Each file is
## compiled into the app, so the server always sends exactly what the file
## holds. Every page loads app/palette.js in its head, which sets the
## colours before the first paint. A conversation's page ends with
## app/chrome.js (its top bar), app/compose.js (its compose box) and
## app/feed.js (its messages). The join page ends with app/join.js, which
## reads the invite's code from the link. `Route` serves each at its
## `url_path`, and `Page` links to them.
import "palette.js" as palette_source : Str
import "chrome.js" as chrome_source : Str
import "compose.js" as compose_source : Str
import "feed.js" as feed_source : Str
import "join.js" as join_source : Str

Script := [Palette, Chrome, Compose, Feed, Join].{

	## Every script the pages load.
	all_scripts : List(Script)
	all_scripts = [
		Script.Palette,
		Script.Chrome,
		Script.Compose,
		Script.Feed,
		Script.Join,
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
		Compose => "compose.js"
		Feed => "feed.js"
		Join => "join.js"
	}

## The script's file, as compiled in.
source : Script -> Str
source = |script|
	match script {
		Palette => palette_source
		Chrome => chrome_source
		Compose => compose_source
		Feed => feed_source
		Join => join_source
	}

# ── tests
# Each script at its path, and each its whole file, from its first line to
# its last.
expect
	Script.all_scripts.map(Script.url_path)
		== [
			"/chat/assets/palette.js",
			"/chat/assets/chrome.js",
			"/chat/assets/compose.js",
			"/chat/assets/feed.js",
			"/chat/assets/join.js",
		]
expect palette_source.starts_with("// This script runs in the head of every page")
expect
	[
		chrome_source,
		compose_source,
		feed_source,
	].all(|text| text.starts_with("// This script runs on a conversation page"))
expect join_source.starts_with("// This script runs on the join page")
expect
	[
		palette_source,
		chrome_source,
		compose_source,
		feed_source,
		join_source,
	].all(|text| text.ends_with("\n})();\n"))
expect
	[
		(Script.Palette, palette_source),
		(Script.Chrome, chrome_source),
		(Script.Compose, compose_source),
		(Script.Feed, feed_source),
		(Script.Join, join_source),
	].all(|(script, text)| script.bytes() == text.to_utf8())

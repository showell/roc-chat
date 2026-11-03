## This module serves the conversation page's message script, app/feed.js.
## The file is compiled into the app, so the server always sends exactly
## what the file holds. `Route` serves it at `url_path`, and `Page` links to
## it.
import "feed.js" as source : Str

FeedScript :: [].{

	url_path : Str
	url_path = "/chat/assets/feed.js"

	bytes : List(U8)
	bytes = source.to_utf8()
}

# ── tests
# The whole file, from its first line to its last.
expect source.starts_with("// This script runs on a conversation page")
expect source.ends_with("\n})();\n")
expect FeedScript.bytes == source.to_utf8()

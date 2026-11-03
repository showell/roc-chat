## This module serves the conversation page's frame script, app/chrome.js.
## The file is compiled into the app, so the server always sends exactly
## what the file holds. `Route` serves it at `url_path`, and `Page` links to
## it.
import "chrome.js" as source : Str

ChromeScript :: [].{

	url_path : Str
	url_path = "/chat/assets/chrome.js"

	bytes : List(U8)
	bytes = source.to_utf8()
}

# ── tests
# The whole file, from its first line to its last.
expect source.starts_with("// This script runs on a conversation page")
expect source.ends_with("\n})();\n")
expect ChromeScript.bytes == source.to_utf8()

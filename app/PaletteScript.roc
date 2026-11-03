## This module serves the pages' colour script, app/palette.js, which every
## page loads in its head so the theme is set before the first paint. The
## file is compiled into the app, so the server always sends exactly what
## the file holds. `Route` serves it at `url_path`, and `Page` links to it.
import "palette.js" as source : Str

PaletteScript :: [].{

	url_path : Str
	url_path = "/chat/assets/palette.js"

	bytes : List(U8)
	bytes = source.to_utf8()
}

# ── tests
# The whole file, from its first line to its last.
expect source.starts_with("// This script runs in the head of every page")
expect source.ends_with("\n})();\n")
expect PaletteScript.bytes == source.to_utf8()

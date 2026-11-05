## This module is the one home of the chat's icon, the picture a browser shows
## on a page's tab. Its file, app/favicon.ico, is compiled into the app, so the
## server always sends exactly what the file holds. A browser asks for
## `url_path` by itself, so no page names it, and it asks on the sign-in page
## too, so `Route` answers it to anyone.
import "favicon.ico" as favicon_file : List(U8)

Favicon :: [].{

	## Where a browser looks for a site's icon.
	url_path : Str
	url_path = "/favicon.ico"

	## The icon's bytes, exactly as its file holds them.
	bytes : List(U8)
	bytes = favicon_file
}

# ── tests
# An icon file holding one image, by the six bytes that open one.
expect Favicon.bytes.take_first(6) == [0, 0, 1, 0, 1, 0]

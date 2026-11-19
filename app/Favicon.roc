## This module is the one home of the chat's icons, the pictures a browser
## shows on a page's tab. Each file is compiled into the app, so the server
## always sends exactly what the file holds.
##
## The site's icon, app/favicon.ico: a browser asks for `url_path` by
## itself, so no page names it, and it asks on the sign-in page too, so
## `Route` answers it to anyone.
##
## The alert icon, app/alert-icon.svg: Gopher Chat's violet tab (chat-client's
## js/notify.js painted a 32-pixel square #8a2be2 when a notice came). A page's
## policy allows images from this site alone, so it is a file served here,
## under `/chat/assets/` beside the scripts, where notify.js drew a data: URL.
## app/sidebar.js names it when a notice arrives, and names `url_path` again
## when the notice's link is followed.
import "favicon.ico" as favicon_file : List(U8)
import "alert-icon.svg" as alert_file : List(U8)
import Script

Favicon :: [].{

	## Where a browser looks for a site's icon.
	url_path : Str
	url_path = "/favicon.ico"

	## The icon's bytes, exactly as its file holds them.
	bytes : List(U8)
	bytes = favicon_file

	## Where the alert icon is served.
	alert_url_path : Str
	alert_url_path = "/chat/assets/alert-icon.svg"

	## The alert icon's bytes, exactly as its file holds them.
	alert_bytes : List(U8)
	alert_bytes = alert_file
}

# ── tests
# An icon file holding one image, by the six bytes that open one.
expect Favicon.bytes.take_first(6) == [0, 0, 1, 0, 1, 0]
# The alert icon: an SVG, a square of Gopher's violet, and small.
expect {
	text = Str.from_utf8_lossy(Favicon.alert_bytes)
	text.starts_with("<svg xmlns=\"http://www.w3.org/2000/svg\"")
		and text.contains("fill=\"#8a2be2\"")
		and Favicon.alert_bytes.len() < 200
}
# app/sidebar.js names both icons by these paths.
expect {
	sidebar = Str.from_utf8_lossy(Script.Sidebar.bytes())
	sidebar.contains("paintTab('${Favicon.alert_url_path}')")
		and sidebar.contains("paintTab('${Favicon.url_path}')")
}

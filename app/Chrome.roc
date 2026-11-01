## **THE BROWSER CLIENT'S FRAME**: the page around Browse and a topic's
## page, as Gopher Chat's chrome draws it (angry-gopher's chat_chrome.zig
## and top_bar.zig): the top bar, then the page's own body in the content
## column.
##
## **THE TOP BAR**: Home, the page's title, and the app's links, then the
## viewer's name and Log out. The links are the old app's in its place
## ("Chat · Docs · Recent · Images · Code"), each as it lands: Browse,
## where Chat was, is the first; Saved, the reading list (the old app's
## lived in Docs), after Recent; the page it names is bold, not a link.
## Log out is the form `/logout` takes (a POST, behind Origin's check),
## where the old app's was a link.
##
## **TWO KINDS OF PAGE**: a plain one in the content column (820px), and
## a chat page, which fills the window and scrolls only its transcript
## (the old chat_page.zig's `chat_css`). **NO STYLE FROM THE SERVER**
## (Steve, DECISIONS.md "The browser client"): the page is structure and
## class names, and js/chrome.js styles the frame, as chat-client's widgets
## each style their own. **THE THEME IS SET BEFORE FIRST PAINT**: the head
## loads js/palette.js (the old colours, dark by default), and the top bar
## carries the old 🌙/☀️ toggle, which chrome.js wires. Its tab says "Chat", as every old chat page's did.
## Pure.
import pf.Chat
import Bytes
import Html
import SignInWeb

Chrome := [].{

	## What the top bar marks as here: Browse, Recent, Saved (the reading
	## list), or none (a topic's page).
	Here : [
		Browse,
		Recent,
		Saved,
		Elsewhere,
	]

	## **A PAGE IN THE FRAME**: its title (escaped already), the viewer's
	## name (escaped already), which link is here, the body's attributes and
	## the body; a chat page fills the window.
	page : {
		title : Html,
		viewer : Html,
		here : Chrome.Here,
		kind : [Plain, Chat],
		body_attrs : Html,
		body : Html,
	} -> Chat.Answer
	page = |
		{
			title,
			viewer,
			here,
			kind,
			body_attrs,
			body,
		},
	|
		Html.respond(
			200,
			Html.join([
				Html.markup("<!doctype html>\n<html lang=en>\n<meta charset=utf-8>\n<meta name=viewport content=\"width=device-width, initial-scale=1\">\n<title>"),
				Html.markup("Chat</title>\n<script src=\"/palette.js\"></script>\n<body"),
				if (kind == Chat) Html.markup(" class=chat-page") else Html.join([]),
				body_attrs,
				Html.markup(">\n<header class=\"app-top chat-top\"><div class=\"chat-top-left\"><a class=\"chat-top-home\" href=\"/\">Home</a><span class=\"chat-top-title\">"),
				title,
				Html.markup("</span><span class=\"chat-top-links\">"),
				if (here == Browse) Html.markup("<strong>Browse</strong>") else Html.markup("<a href=\"/chat/browse\">Browse</a>"),
				Html.markup(" · "),
				if (here == Recent) Html.markup("<strong>Recent</strong>") else Html.markup("<a href=\"/chat/recent\">Recent</a>"),
				Html.markup(" · "),
				if (here == Saved) Html.markup("<strong>Saved</strong>") else Html.markup("<a href=\"/chat/saved\">Saved</a>"),
				Html.markup("</span></div><div class=\"app-top-user\"><button id=chat-theme-toggle type=button title=\"Toggle theme\" aria-label=\"Toggle theme\"></button> · <strong>"),
				viewer,
				Html.markup("</strong> · "),
				Html.markup(SignInWeb.log_out_form),
				Html.markup("</div></header>\n<div class=\"app-body-wrap\">\n"),
				body,
				Html.markup("</div>\n<script src=\"/chrome.js\"></script>\n"),
			]),
		)
}

# The page named here is bold and no link; elsewhere, Browse is a link.
expect {
	html = |here| Chrome.page({
		title: Html.markup("T"),
		viewer: Html.text("<Ann>"),
		here,
		kind: Plain,
		body_attrs: Html.join([]),
		body: Html.join([]),
	}).body
	browse = html(Browse)
	elsewhere = html(Elsewhere)
	Bytes.find(browse, { needle: "<strong>Browse</strong>".to_utf8(), at: 0 }).is_ok()
		and Bytes.find(browse, { needle: "href=\"/chat/browse\"".to_utf8(), at: 0 }).is_err()
		and Bytes.find(
			elsewhere,
			{ needle: "<a href=\"/chat/browse\">Browse</a>".to_utf8(), at: 0 },
		).is_ok()
		and Bytes.find(
			elsewhere,
			{ needle: "<strong>&lt;Ann&gt;</strong>".to_utf8(), at: 0 },
		).is_ok()
}

## **THE BROWSER CLIENT'S FRAME**: the page around Browse and a topic's
## page, as Gopher Chat's chrome draws it (angry-gopher's chat_chrome.zig
## and top_bar.zig): the top bar, then the page's own body in the content
## column. A skin fork is this shell, its stylesheet in place.
##
## **THE TOP BAR**: Home, the page's title, and the app's links, then the
## viewer's name and Log out. The links are the old app's in its place
## ("Chat · Docs · Recent · Images · Code"), each as it lands: Browse,
## where Chat was, is the first; the page it names is bold, not a link.
## Log out is the form `/logout` takes (a POST, behind Origin's check),
## where the old app's was a link.
##
## **TWO KINDS OF PAGE**: a plain one in the content column (820px), and
## a chat page, which fills the window and scrolls only its transcript
## (the old chat_page.zig's `chat_css`). Its stylesheet is embedded, as
## every page's here is. Pure.
import pf.Chat
import Bytes
import Html

Chrome := [].{

	## What the top bar marks as here: Browse, or none (a topic's page).
	Here : [Browse, Elsewhere]

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
				title,
				Html.markup(" · roc-chat</title>\n<style>\n"),
				Html.markup(css),
				Html.markup("</style>\n<body"),
				if (kind == Chat) Html.markup(" class=chat-page") else Html.join([]),
				body_attrs,
				Html.markup(">\n<header class=\"app-top chat-top\"><div class=\"chat-top-left\"><a class=\"chat-top-home\" href=\"/\">Home</a><span class=\"chat-top-title\">"),
				title,
				Html.markup("</span><span class=\"chat-top-links\">"),
				if (here == Browse) Html.markup("<strong>Browse</strong>") else Html.markup("<a href=\"/chat/browse\">Browse</a>"),
				Html.markup("</span></div><div class=\"app-top-user\"><strong>"),
				viewer,
				Html.markup("</strong> · <form class=logout method=post action=\"/logout\"><button>Log out</button></form></div></header>\n<div class=\"app-body-wrap\">\n"),
				body,
				Html.markup("</div>\n"),
			]),
		)
}

## The frame's rules: the old chrome's base and top bar (top_bar.zig, with
## its fallback colours: the colour tokens come with the transcript's
## styling), then the chat page's layout (chat_page.zig's `chat_css`, the
## feed column of middle_pane.js, the right pane of chat_right_sidebar.js).
css : Str
css =
	\\body { font-family: sans-serif; margin: 0; padding: 0; display: flex; flex-direction: column; min-height: 100vh; }
	\\.app-body-wrap { flex: 1; max-width: 820px; margin: 32px auto; padding: 0 24px 60px; width: 100%; box-sizing: border-box; }
	\\.app-top { background: var(--cc-top-bar-bg, #f0ede4); border-bottom: 1px solid var(--cc-top-bar-border, #c9bfa7); padding: 8px 24px; font-family: sans-serif; display: flex; justify-content: space-between; align-items: baseline; position: sticky; top: 0; z-index: 10; }
	\\.app-top-user { font-size: 13px; color: var(--cc-body-muted-fg, #444); }
	\\.app-top-user a { color: var(--cc-accent, #000080); }
	\\.chat-top .chat-top-left { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; min-width: 0; }
	\\.chat-top-home { color: var(--cc-accent, #000080); text-decoration: none; font-size: 13px; }
	\\.chat-top-home:hover { text-decoration: underline; }
	\\.chat-top-title { font-weight: bold; color: var(--cc-accent, #000080); }
	\\.chat-top-links { font-size: 13px; }
	\\.chat-top-links a { color: var(--cc-accent, #000080); text-decoration: none; }
	\\.chat-top-links a:hover { text-decoration: underline; }
	\\form.logout { display: inline; }
	\\form.logout button { font: inherit; color: var(--cc-accent, #000080); background: none; border: none; padding: 0; cursor: pointer; text-decoration: underline; }
	\\h1 { color: var(--cc-accent, #000080); }
	\\a { color: var(--cc-accent, #000080); }
	\\.muted { color: var(--cc-muted-fg, #888); }
	\\html:has(body.chat-page), body.chat-page { height: 100%; }
	\\.chat-page .app-body-wrap { margin: 10px auto; padding: 0 24px 10px; min-height: 0; max-width: none; display: flex; flex-direction: column; }
	\\.chat-layout { display: flex; flex-direction: row; align-items: stretch; gap: 20px; flex: 1; min-height: 0; }
	\\.chat-mp-main { min-width: 0; flex: 1; max-width: 600px; display: flex; flex-direction: column; min-height: 0; }
	\\.chat-mp-nav { margin-bottom: 8px; }
	\\.chat-mp-history { min-width: 0; flex: 1; min-height: 0; overflow-y: auto; border: 1px solid var(--cc-border, #ccc); border-radius: 8px; padding: 12px; }
	\\.chat-mp-history:focus { outline: none; }
	\\.chat-compose { width: 320px; flex: none; display: flex; flex-direction: column; min-height: 0; }
	\\.browse-list { list-style: none; padding: 0; margin: 0 0 18px; font-size: 13px; }
	\\.browse-list li a { display: block; padding: 4px 8px; border-radius: 3px; text-decoration: none; }
	\\.browse-list li.muted { padding: 4px 8px; font-style: italic; }
	\\.browse h2 { font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; color: var(--cc-muted-fg, #888); margin: 0 0 6px; }
	\\

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

## These are the tests of `Page`: each page, byte for byte.
import Conversation
import ConversationKey
import Page
import Sample
import SignedIn
import UnvalidatedString

PageSpec :: [].{}

## `plans` in Steve's own DM, in the sample directory.
plans_key : ConversationKey
plans_key = ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8()) ?? crash "PageSpec: a path is UTF-8",
	directory: Sample.directory,
}).map_ok(|found| found.key) ?? crash "PageSpec: Steve's own DM is a place"

## The page of `conversation` in `plans_key`, for the sample's user named
## `viewer`, its authors found among the sample's users.
page_for : Str, Conversation -> Str
page_for = |viewer, conversation|
	Str.from_utf8_lossy(
		Page.conversation({
			conversation,
			key: plans_key,
			viewer: SignedIn.dangerously_assume(Sample.user(viewer)),
			users: Sample.directory.users(),
		}).to_utf8(),
	)

## What every conversation's page ends with: the compose box, posting to
## `url` and uploading to `url` and `/upload`, its help in words, the end
## of the layout, and the scripts. A frozen answer, so a change to the box
## shows here as a deliberate re-freeze.
foot : Str -> Str
foot = |url| "<div class=\"compose\"><form method=\"post\" action=\"${url}\" data-send=\"${url}/send\" data-upload=\"${url}/upload\" data-image-most=\"10485760\"><textarea name=\"markdown\" required></textarea>\n<button>Send</button></form>\n<p class=\"help\">Markdown supported · attach an image · Ctrl/⌘-Enter to send</p></div>\n</div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/compose.js\"></script>\n<script src=\"/chat/assets/feed.js\"></script>\n"

## A conversation's page as a test expects it, for the viewer `viewer`
## with the id `viewer_id`: the head, the top bar, then the messages'
## pane, naming its stream, the `count` of messages it shows and the
## viewer's id, holding `messages`, then the foot.
plans_page : {
	viewer : Str,
	viewer_id : Str,
	count : Str,
	messages : Str,
} -> Str
plans_page = |
	{
		viewer,
		viewer_id,
		count,
		messages,
	},
|
	"${head("plans")}<header class=\"top-bar\"><span class=\"top-title\">plans</span> <div class=\"top-user\"><span class=\"viewer\">${viewer}</span></div></header>\n<div class=\"layout\"><div class=\"messages\" data-stream=\"/chat/dm/1_1/plans/stream\" data-after=\"${count}\" data-viewer=\"${viewer_id}\">\n${messages}</div>\n${foot("/chat/dm/1_1/plans")}"

## Steve's page of `plans`, showing `count` messages, `messages`.
steves_page : Str, Str -> Str
steves_page = |count, messages|
	plans_page({
		viewer: "Steve",
		viewer_id: "1",
		count,
		messages,
	})

## What every page opens with, titled `title` (already escaped): the
## doctype, the charset, the viewport, the title, and the colour script.
head : Str -> Str
head = |title|
	"<!doctype html>\n<meta charset=utf-8>\n<meta name=viewport content=\"width=device-width, initial-scale=1\">\n<title>${title}</title>\n<script src=\"/chat/assets/palette.js\"></script>\n"

## The sample's hello and reply, as a page shows them: Steve's names his
## id, 1, and CC's, an agent's, names CC's, 3.
hello_and_reply : Str
hello_and_reply = "<article class=\"message\" id=\"msg-1\" data-author=\"1\"><header><span class=\"author\">Steve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"ref\" href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=\"body\"><p>Hello</p>\n</div></article>\n<article class=\"message\" id=\"msg-2\" data-author=\"3\"><header><span class=\"author\">CC</span> <time datetime=\"2026-11-02T19:12:28Z\">2026-11-02T19:12:28Z</time> <a class=\"ref\" href=\"#msg-2\">MSG_plans_2</a></header>\n<div class=\"body\"><p>Hi!</p>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n</div></article>\n"

# No messages: the page says so, and only then.
expect page_for("Steve", Conversation.empty(Sample.plans)) == steves_page("0", "<p class=\"empty\">No messages yet.</p>\n")
expect page_for("Steve", Sample.hello_and_reply) == steves_page("2", hello_and_reply)
# Another viewer: their name in the top bar and their id on the pane; each
# message names its author's id, the same for every viewer.
expect
	page_for("Apoorva", Sample.hello_and_reply)
		== plans_page({
			viewer: "Apoorva",
			viewer_id: "2",
			count: "2",
			messages: hello_and_reply,
		})
# The markdown's own markup kept, and markup typed in it shown as text. A
# name can hold no markup (`Name`), and is escaped as all text is. Eve is no
# user of the chat, so her message names no author's id.
expect
	page_for(
		"Steve",
		Sample.conversation(
			Sample.plans,
			[
				Sample.unnumbered_message({
					author: "Eve",
					time: "2026-11-02T19:11:32Z",
					markdown: "**hi** <b>",
				}),
			],
		),
	)
		== steves_page("1", "<article class=\"message\" id=\"msg-1\"><header><span class=\"author\">Eve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"ref\" href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=\"body\"><p><strong>hi</strong> &lt;b&gt;</p>\n</div></article>\n")
# A refusal's words are text on its page.
expect Page.refusal("it <is> not UTF-8").to_utf8() == "${head("Not a transcript")}<p>Not a transcript: it &lt;is&gt; not UTF-8.</p>".to_utf8()

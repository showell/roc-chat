## **PAGE'S TESTS**: each page, byte for byte.
import Conversation
import ConversationKey
import Page
import Sample
import UnvalidatedString

PageSpec :: [].{}

## `plans` in Steve's own DM, in the sample directory.
plans_key : ConversationKey
plans_key = ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8()) ?? crash "PageSpec: a path is UTF-8",
	directory: Sample.directory,
}) ?? crash "PageSpec: Steve's own DM is a place"

## What every conversation's page ends with: the compose box, posting to
## `url`, its keys in words, and the script. A frozen answer, so a change
## to the box shows here as a deliberate re-freeze.
foot : Str -> Str
foot = |url| "<div class=\"compose\"><form method=\"post\" action=\"${url}\"><textarea name=\"markdown\" required></textarea>\n<button>Send</button></form>\n<p class=\"help\">Ctrl/⌘-Enter to send</p></div>\n<script src=\"/chat/assets/compose.js\"></script>\n"

## A conversation's page as a test expects it: the head, then the messages'
## pane, naming its stream and the `count` of messages it shows, holding
## `messages` under the topic `plans`, then the foot.
plans_page : Str, Str -> Str
plans_page = |count, messages| "${head("plans")}<div class=\"messages\" data-stream=\"/chat/dm/1_1/plans/stream\" data-after=\"${count}\"><h1>plans</h1>\n${messages}</div>\n${foot("/chat/dm/1_1/plans")}"

## What every page opens with, titled `title` (already escaped). Its style
## sheet is a frozen answer, copied from `Page`'s style sheet, so a change to
## the style shows here as a deliberate re-freeze.
head : Str -> Str
head = |title|
	"<!doctype html>\n<meta charset=utf-8>\n<title>${title}</title>\n<style>\nbody{font:16px/1.4 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}\n.message{border-top:1px solid #ccc;padding:.5rem 0}\n.author{font-weight:600}\ntime,.ref{color:#777;font-size:.85em}\n.ref{float:right}\n</style>\n"

# No messages: the page says so, and only then.
expect Page.conversation(Conversation.empty(Sample.plans), plans_key).to_utf8() == plans_page("0", "<p class=\"empty\">No messages yet.</p>\n").to_utf8()
expect
	Page.conversation(Sample.hello_and_reply, plans_key).to_utf8()
		== plans_page("2", "<article class=\"message\" id=\"msg-1\"><header><span class=\"author\">Steve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"ref\" href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=\"body\"><p>Hello</p>\n</div></article>\n<article class=\"message\" id=\"msg-2\"><header><span class=\"author\">CC</span> <time datetime=\"2026-11-02T19:12:28Z\">2026-11-02T19:12:28Z</time> <a class=\"ref\" href=\"#msg-2\">MSG_plans_2</a></header>\n<div class=\"body\"><p>Hi!</p>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n</div></article>\n").to_utf8()
# The markdown's own markup kept, and markup typed in it shown as text. A
# name can hold no markup (`Name`), and is escaped as all text is.
expect
	Page.conversation(
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
		plans_key,
	).to_utf8()
		== plans_page("1", "<article class=\"message\" id=\"msg-1\"><header><span class=\"author\">Eve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"ref\" href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=\"body\"><p><strong>hi</strong> &lt;b&gt;</p>\n</div></article>\n").to_utf8()
# A refusal's words are text on its page.
expect Page.refusal("it <is> not UTF-8").to_utf8() == "${head("Not a transcript")}<p>Not a transcript: it &lt;is&gt; not UTF-8.</p>".to_utf8()

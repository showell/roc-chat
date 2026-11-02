## **PAGE'S TESTS**: a conversation's page, byte for byte.
import Conversation
import Page
import Sample

PageSpec :: [].{}

## What every page opens with, titled `title` (already escaped).
head : Str -> Str
head = |title|
	"<!doctype html>\n<meta charset=utf-8>\n<title>${title}</title>\n<style>\nbody{font:16px/1.4 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}\n.message{border-top:1px solid #ccc;padding:.5rem 0}\n.author{font-weight:600}\ntime,.ref{color:#777;font-size:.85em}\n.ref{float:right}\n</style>\n"

# No messages: the page says so, and only then.
expect Page.conversation(Conversation.empty(Sample.plans)).to_str() == "${head("plans")}<h1>plans</h1>\n<p class=\"empty\">No messages yet.</p>\n"
expect
	Page.conversation(Sample.two).to_str()
		== "${head("plans")}<h1>plans</h1>\n<article class=\"message\" id=\"msg-1\"><header><span class=\"author\">Steve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"ref\" href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=\"body\"><p>Hello</p>\n</div></article>\n<article class=\"message\" id=\"msg-2\"><header><span class=\"author\">CC</span> <time datetime=\"2026-11-02T19:12:28Z\">2026-11-02T19:12:28Z</time> <a class=\"ref\" href=\"#msg-2\">MSG_plans_2</a></header>\n<div class=\"body\"><p>Hi!</p>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n</div></article>\n"
# A name holding markup is text on the page; the markdown's markup is kept.
expect
	Page.conversation(
		Sample.conversation(
			Sample.plans,
			[
				Sample.arrival({
					author: "<Eve>",
					time: "2026-11-02T19:11:32Z",
					markdown: "**hi** <b>",
				}),
			],
		),
	).to_str()
		== "${head("plans")}<h1>plans</h1>\n<article class=\"message\" id=\"msg-1\"><header><span class=\"author\">&lt;Eve&gt;</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"ref\" href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=\"body\"><p><strong>hi</strong> &lt;b&gt;</p>\n</div></article>\n"

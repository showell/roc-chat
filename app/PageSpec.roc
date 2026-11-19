## These are the tests of the pages (`ConversationPage`, `SignInPage`,
## `JoinPage`, `AgentsPage`, `PeoplePages` and `PageKit`'s notices): each
## page, byte for byte.
import AgentsPage
import Conversation
import ConversationKey
import ConversationPage
import Html
import JoinPage
import Message
import MessageNotes
import Name
import PageKit
import PeoplePages
import Reactions
import Sample
import SignInPage
import SignedIn
import Timestamp
import UnvalidatedString
import UserId

PageSpec :: [].{}

## `plans` in Steve's own DM, in the sample directory.
plans_key : ConversationKey
plans_key = ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
		?? crash "PageSpec: a path is UTF-8",
	directory: Sample.directory,
}).map_ok(|found| found.key) ?? crash "PageSpec: Steve's own DM is a place"

## The page of `conversation` in `plans_key`, for the sample's user named
## `viewer`, its authors found among the sample's users, with no sidebar, as
## a key's page has none (`SidebarSpec` holds the sidebar's).
page_for : Str, Conversation -> Str
page_for = |viewer, conversation|
	Str.from_utf8_lossy(
		ConversationPage.conversation({
			conversation,
			reactions: Reactions.empty,
			key: plans_key,
			viewer: SignedIn.dangerously_assume(Sample.user(viewer)),
			users: Sample.directory.users(),
			sidebar: NoSidebar,
		}).to_utf8(),
	)

## What every conversation's page ends with: the compose box, posting to
## `url` and uploading to `url` and `/upload`, its help in words, the end
## of the layout, and the scripts. A frozen answer, so a change to the box
## shows here as a deliberate re-freeze.
foot : Str -> Str
foot = |url|
	"<div class=\"compose\"><form method=\"post\" action=\"${url}\" data-send=\"${url}/send\" data-upload=\"${url}/upload\" data-image-byte-limit=\"10485760\"><textarea name=\"markdown\" required></textarea>\n<button>Send</button></form>\n<p class=\"help\">Markdown supported · attach an image · Ctrl/⌘-Enter to send</p></div>\n</div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/compose.js\"></script>\n<script src=\"/chat/assets/feed.js\"></script>\n<script src=\"/chat/assets/actions.js\"></script>\n"

## How the top bar's right side opens: the Home link (`HomeLink`), and the
## links to Browse and the invites page.
top_links : Str
top_links = "<div class=\"top-user\"><a href=\"https://lynrummy.com/\">Home</a> · <a href=\"/chat\">Browse</a> · <a href=\"/invites\">Invites</a> · "

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
plans_page = |{ viewer, viewer_id, count, messages }|
	"${head("plans")}<header class=\"top-bar\"><span class=\"top-title\">plans</span> ${top_links}<span class=\"viewer\">${viewer}</span></div></header>\n<div class=\"layout\"><div class=\"messages\" data-stream=\"/chat/dm/1_1/plans/stream\" data-after=\"${count}\" data-viewer=\"${viewer_id}\" data-react=\"/chat/dm/1_1/plans/react\" data-raw=\"/chat/dm/1_1/plans/raw\">\n${messages}</div>\n${foot("/chat/dm/1_1/plans")}"

## Steve's page of `plans`, showing `count` messages, `messages`.
steves_page : { count : Str, messages : Str } -> Str
steves_page = |{ count, messages }|
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
hello_and_reply =
	"<article class=\"message\" id=\"msg-1\" data-author=\"1\"><header><span class=\"author\">Steve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"message-reference\" href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=\"body\"><p>Hello</p>\n</div></article>\n<article class=\"message\" id=\"msg-2\" data-author=\"3\"><header><span class=\"author\">CC</span> <time datetime=\"2026-11-02T19:12:28Z\">2026-11-02T19:12:28Z</time> <a class=\"message-reference\" href=\"#msg-2\">MSG_plans_2</a></header>\n<div class=\"body\"><p>Hi!</p>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n</div></article>\n"

# No messages: the page says so, and only then.
expect page_for("Steve", Conversation.empty(Sample.plans)) == steves_page({
	count: "0",
	messages: "<p class=\"empty\">No messages yet.</p>\n",
})
expect page_for("Steve", Sample.hello_and_reply) == steves_page({
	count: "2",
	messages: hello_and_reply,
})
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
		== steves_page({
			count: "1",
			messages: "<article class=\"message\" id=\"msg-1\"><header><span class=\"author\">Eve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"message-reference\" href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=\"body\"><p><strong>hi</strong> &lt;b&gt;</p>\n</div></article>\n",
		})

## The sign-in page as a test expects it, going on to `/agents`, with
## `above`, what comes between its heading and its form.
login_page : Str -> Str
login_page = |above|
	"${head("Sign in")}<h1>Sign in</h1>\n${above}<form method=\"post\" action=\"/login\"><input type=\"hidden\" name=\"next\" value=\"/agents\">\n<p>Name <input type=\"text\" name=\"name\" autocomplete=\"username\" required></p>\n<p>Password <input type=\"password\" name=\"password\" autocomplete=\"current-password\" required></p>\n<button>Sign in</button></form>\n"

## The sign-in page for `viewer`, with `problem`, as a test reads it.
login_for : SignedIn.Actor, [NoProblem, Problem(Str)] -> Str
login_for = |viewer, problem|
	Str.from_utf8_lossy(
		SignInPage.login({
			viewer,
			next: Html.SitePath.from_str("/agents") ?? crash "PageSpec: a site path",
			problem,
			github: NotOffered,
		}).to_utf8(),
	)

# The sign-in page: for no one, the form alone; with a problem, it first;
# for someone signed in, under the top bar, who and the button that signs
# them out, and no form.
expect login_for(Anonymous, NoProblem) == login_page("")
expect login_for(Anonymous, Problem("No <match>.")) == login_page("<p>No &lt;match&gt;.</p>\n")
expect
	login_for(SignedIn(SignedIn.dangerously_assume(Sample.user("Steve"))), NoProblem)
		== "${head("Signed in")}<header class=\"top-bar\"><span class=\"top-title\">Signed in</span> ${top_links}<span class=\"viewer\">Steve</span></div></header>\n<div class=\"layout\"><div class=\"panel\">\n<p>You are signed in as Steve.</p>\n<form method=\"post\" action=\"/logout\"><button>Sign out</button></form>\n</div></div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/panel.js\"></script>\n"
# With GitHub's settings, a link below the form, going on to `next`.
expect
	Str.from_utf8_lossy(
		SignInPage.login({
			viewer: Anonymous,
			next: Html.SitePath.from_str("/chat/dm/1_1/plans") ?? crash "PageSpec: a site path",
			problem: NoProblem,
			github: Offered,
		}).to_utf8(),
	).contains("</form>\n<p><a href=\"/login/github/start?next=/chat/dm/1_1/plans\">Sign in with GitHub</a></p>\n")
# The join page: a hidden field for the code, the name and a new password,
# then the script that reads the code from the link.
expect
	JoinPage.join.to_utf8()
		== "${head("Join")}<h1>Join the chat</h1>\n<p>Someone you know invited you. Keep the name they chose for you, or choose another that no one has; once you join, it is yours. Choose a password: you sign in with your name and it.</p>\n<form method=\"post\" action=\"/join\"><input type=\"hidden\" name=\"code\">\n<p>Your name <input type=\"text\" name=\"name\" autocomplete=\"username\" required></p>\n<p>Your password <input type=\"password\" name=\"password\" autocomplete=\"new-password\" required></p>\n<button>Join</button></form>\n<script src=\"/chat/assets/join.js\"></script>\n".to_utf8()

## The words above the form that asks a new human for a name.
sign_up_words : Str
sign_up_words = "GitHub says who you are, and you have no account here yet. Choose a name that no one has: letters and single spaces. Once you join, it is yours, and you sign in with GitHub."

# The page asking a new human for a name: filled in or empty, and a problem
# above the words when there is one.
expect {
	zoe = Name.from_str("Zoë Ann") ?? crash "PageSpec: a name"
	SignInPage.github_sign_up({ name: Named(zoe), problem: NoProblem }).to_utf8()
		== "${head("Choose your name")}<h1>Choose your name</h1>\n<p>${sign_up_words}</p>\n<form method=\"post\" action=\"/login/github/name\"><p>Your name <input type=\"text\" name=\"name\" autocomplete=\"username\" required value=\"Zoë Ann\"></p>\n<button>Join</button></form>\n".to_utf8()
}
expect
	SignInPage.github_sign_up({ name: NoName, problem: Problem("The <name> is taken.") }).to_utf8()
		== "${head("Choose your name")}<h1>Choose your name</h1>\n<p>The &lt;name&gt; is taken.</p>\n<p>${sign_up_words}</p>\n<form method=\"post\" action=\"/login/github/name\"><p>Your name <input type=\"text\" name=\"name\" autocomplete=\"username\" required></p>\n<button>Join</button></form>\n".to_utf8()
# Every page of someone signed in has the links to Browse and the invites
# page, and no page of no one's has either.
expect {
	steve = SignedIn.dangerously_assume(Sample.user("Steve"))
	[
		ConversationPage.conversation({
			conversation: Conversation.empty(Sample.plans),
			reactions: Reactions.empty,
			key: plans_key,
			viewer: steve,
			users: Sample.directory.users(),
			sidebar: Sidebar([]),
		}),
		AgentsPage.agents({
			viewer: steve,
			agents: [],
			shown: NoCode,
			github_link: LinkOffered,
		}),
		PeoplePages.channels({ viewer: steve, channels: [] }),
		PeoplePages.invites({
			viewer: steve,
			users: Sample.directory.users(),
			invited: [],
			github: NotOffered,
			shown: NoLink,
			problem: NoProblem,
			now: Timestamp.at_second(0),
		}),
	].all(
		|page| {
			text = Str.from_utf8_lossy(page.to_utf8())
			text.contains(top_links) and !text.contains("/join") and !text.contains("Sign in")
		},
	)
		and [
			JoinPage.join,
			PageKit.notice({ title: "t", text: "x" }),
			SignInPage.github_sign_up({ name: NoName, problem: NoProblem }),
			SignInPage.login({
				viewer: Anonymous,
				next: Html.SitePath.from_str("/chat") ?? crash "PageSpec: a site path",
				problem: NoProblem,
				github: Offered,
			}),
		].all(
			|page| {
				text = Str.from_utf8_lossy(page.to_utf8())
				!text.contains("<a href=\"/chat\">Browse</a>") and !text.contains("/invites") and !text.contains("lynrummy.com")
			},
		)
}
# The invites page of someone with no one to invite again: what an invite is
# for, the form, and that nothing is open.
expect
	PeoplePages.invites({
		viewer: SignedIn.dangerously_assume(Sample.user("Steve")),
		users: Sample.directory.users(),
		invited: [],
		github: NotOffered,
		shown: NoLink,
		problem: NoProblem,
		now: Timestamp.at_second(0),
	}).to_utf8()
		== "${head("Invites")}<header class=\"top-bar\"><span class=\"top-title\">Invites</span> ${top_links}<span class=\"viewer\">Steve</span></div></header>\n<div class=\"layout\"><div class=\"panel\">\n<p>An invite brings someone into the chat. They choose a password, and sign in with their name and that password.</p>\n<p>Write the name you know them by, and you get a link to send them. The link works once, for seven days. They can keep the name or choose another.</p>\n<form method=\"post\" action=\"/invites\"><p>Their name <input type=\"text\" name=\"name\" required></p>\n<button>Invite someone</button></form><h1>Open invites</h1>\n<p>No open invites.</p>\n</div></div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/panel.js\"></script>\n".to_utf8()
# A refusal's words are text on its page.
expect
	PageKit.refusal("it <is> not UTF-8").to_utf8()
		== "${head("Not a transcript")}<p>Not a transcript: it &lt;is&gt; not UTF-8.</p>".to_utf8()

# An edited message names its edit, linked, and keeps its markdown, as
# written and escaped, folded away; a message with reactions ends with an
# emoji a button, each naming its reactors' ids and their count; a message
# with neither is drawn as before.
expect {
	conversation = Sample.conversation(
		Sample.plans,
		[
			Sample.unnumbered_message({
				author: "Steve",
				time: "2026-11-02T19:11:32Z",
				markdown: "Helo <b>",
			}),
			Sample.unnumbered_message({
				author: "Steve",
				time: "2026-11-02T19:12:00Z",
				markdown: "Edit of MSG_plans_1\n\nHello",
			}),
		],
	)
	reaction = |user, emoji| {
		message: Message.Id.from_digits("2".to_utf8()) ?? crash "PageSpec: an id",
		user: UserId.from_str(user) ?? crash "PageSpec: a user's id",
		emoji: Reactions.Emoji.from_str(emoji) ?? crash "PageSpec: an emoji",
	}
	reactions = [
		reaction("1", "👍"),
		reaction("3", "👍"),
		reaction("3", "🎉"),
	].fold(
		Reactions.empty,
		|so_far, one| so_far.set({
			reaction: one,
			wanted: On,
		}) ?? crash "PageSpec: a reaction fits",
	)
	drawn = List.map2(
		conversation.messages(),
		MessageNotes.notes_of_messages({ conversation, reactions }),
		|message, notes|
			Str.from_utf8_lossy(
				ConversationPage.message({
					conversation,
					key: plans_key,
					users: Sample.directory.users(),
					message,
					notes,
				}).to_utf8(),
			),
	)
	plain = Str.from_utf8_lossy(
		ConversationPage.message({
			conversation,
			key: plans_key,
			users: Sample.directory.users(),
			message: conversation.messages().first() ?? crash "PageSpec: a message",
			notes: MessageNotes.fresh,
		}).to_utf8(),
	)
	drawn
		== [
			"<article class=\"message\" id=\"msg-1\" data-author=\"1\"><header><span class=\"author\">Steve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"message-reference\" href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=\"body\"><p class=\"edited-note\">Edited in <a class=\"message-reference\" href=\"#msg-2\">MSG_plans_2</a></p><details class=\"edited-original\"><summary>original</summary><div class=\"edited-markdown\">Helo &lt;b&gt;</div></details></div></article>\n",
			"<article class=\"message\" id=\"msg-2\" data-author=\"1\"><header><span class=\"author\">Steve</span> <time datetime=\"2026-11-02T19:12:00Z\">2026-11-02T19:12:00Z</time> <a class=\"message-reference\" href=\"#msg-2\">MSG_plans_2</a></header>\n<div class=\"body\"><p>Edit of <a href=\"#msg-plans_1\" class=\"msg-ref\">MSG_plans_1</a></p>\n<p>Hello</p>\n</div><div class=\"reaction-strip\"><button class=\"reaction-chip\" data-reactors=\"1-3\"><span class=\"reaction-emoji\">👍</span> 2</button><button class=\"reaction-chip\" data-reactors=\"3\"><span class=\"reaction-emoji\">🎉</span> 1</button></div></article>\n",
		]
		and plain.contains("<div class=\"body\"><p>Helo &lt;b&gt;</p>\n</div></article>")
}

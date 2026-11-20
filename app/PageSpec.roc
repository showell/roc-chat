## These are the tests of the pages (`ConversationPage`, `SignInPage`,
## `JoinPage`, `AgentsPage`, `PeoplePages`, `RecentFeed`'s and `PageKit`'s
## notices): each page, byte for byte.
import AgentsPage
import Conversation
import ConversationKey
import DateTime
import ConversationPage
import Html
import JoinPage
import Message
import MessageNotes
import Name
import PageContract
import PageKit
import PeoplePages
import Reactions
import RecentFeed
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
	"<div class=\"compose\"><form method=\"post\" action=\"${url}\" data-send=\"${url}/send\" data-upload=\"${url}/upload\" data-image-byte-limit=\"10485760\"><textarea name=\"markdown\"></textarea>\n<button>Send</button></form>\n<p class=\"help\">Markdown supported · :emoji: autocompletes · paste or Upload an image · Ctrl/⌘-Enter to send</p></div>\n</div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/compose.js\"></script>\n<script src=\"/chat/assets/emoji.js\"></script>\n<script src=\"/chat/assets/feed.js\"></script>\n<script src=\"/chat/assets/citation.js\"></script>\n<script src=\"/chat/assets/actions.js\"></script>\n<script src=\"/chat/assets/search.js\"></script>\n"

## How the top bar's right side opens: the Home link (`HomeLink`), and the
## links to Browse, Recent and the invites page.
top_links : Str
top_links = "<span class=\"top-links\"><a href=\"/chat\">Browse</a> · <a href=\"/chat/recent\">Recent</a> · <a href=\"/invites\">Invites</a> · <a href=\"/devices\">Add a device</a></span> <div class=\"top-user\"><a href=\"https://lynrummy.com/\">Home</a> · "

## `top_links` in a top bar that holds the notice line, empty.
top_links_noticed : Str
top_links_noticed = "<span class=\"top-links\"><a href=\"/chat\">Browse</a> · <a href=\"/chat/recent\">Recent</a> · <a href=\"/invites\">Invites</a> · <a href=\"/devices\">Add a device</a></span> <p class=\"notice-strip\"></p> <div class=\"top-user\"><a href=\"https://lynrummy.com/\">Home</a> · "

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
	"${head("plans")}<header class=\"top-bar\"><span class=\"top-title\"><a href=\"/chat/dm/1_1/plans\">Steve on plans</a></span> ${top_links}<span class=\"viewer\">${viewer}</span> · <form class=\"sign-out\" method=\"post\" action=\"/logout\"><button>Sign out</button></form></div></header>\n<div class=\"layout\"><div class=\"messages\" data-stream=\"/chat/dm/1_1/plans/stream\" data-after=\"${count}\" data-viewer=\"${viewer_id}\" data-react=\"/chat/dm/1_1/plans/react\" data-raw=\"/chat/dm/1_1/plans/raw\" data-download=\"/chat/dm/1_1/plans/download\">\n${messages}</div>\n${foot("/chat/dm/1_1/plans")}"

## Steve's page of `plans`, showing `count` messages, `messages`.
steves_page : { count : Str, messages : Str } -> Str
steves_page = |{ count, messages }|
	plans_page({
		viewer: "Steve",
		viewer_id: "1",
		count,
		messages,
	})

## The page of the empty conversation at `path`, among the sample's users
## and the channel `general`, for the sample's user named `viewer`, with a
## sidebar of no places whose top bar's notice line says `notice`.
empty_page : { path : Str, viewer : Str }, [NoNotice, Notice(Str)] -> Str
empty_page = |{ path, viewer }, notice| {
	directory = Sample.with_default_channel(Sample.directory)
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "PageSpec.empty_page: a path is UTF-8",
		directory,
	}).map_ok(|found| found.key) ?? crash "PageSpec.empty_page: a conversation's path"
	Str.from_utf8_lossy(
		ConversationPage.conversation({
			conversation: Conversation.empty(key.topic()),
			reactions: Reactions.empty,
			key,
			viewer: SignedIn.dangerously_assume(Sample.user(viewer)),
			users: directory.users(),
			sidebar: Sidebar({ places: [], online_humans: [], notice, rosters: [] }),
		}).to_utf8(),
	)
}

## The top bar's title as a page holds it: `words`, linked to the page's
## own `path`.
title_at : { path : Str, words : Str } -> Str
title_at = |{ path, words }|
	"<header class=\"top-bar\"><span class=\"top-title\"><a href=\"${path}\">${words}</a></span> "

# The top bar's title, linked to the page itself, so a click reloads it: a
# DM names the other human "on" the topic, for each of them; a channel's is
# Gopher Chat's; the viewer's own DM names the viewer.
expect
	empty_page({ path: "/chat/dm/1_2/plans", viewer: "Steve" }, NoNotice)
		.contains(title_at({ path: "/chat/dm/1_2/plans", words: "Apoorva on plans" }))
expect
	empty_page({ path: "/chat/dm/1_2/plans", viewer: "Apoorva" }, NoNotice)
		.contains(title_at({ path: "/chat/dm/1_2/plans", words: "Steve on plans" }))
expect
	empty_page({ path: "/chat/channel/general/plans", viewer: "Steve" }, NoNotice)
		.contains(title_at({ path: "/chat/channel/general/plans", words: "#general: plans" }))
expect
	empty_page({ path: "/chat/dm/1_1/plans", viewer: "Steve" }, NoNotice)
		.contains(title_at({ path: "/chat/dm/1_1/plans", words: "Steve on plans" }))

# The top bar's notice line, between the section links and the viewer's
# name, says what it is drawn with, escaped, or nothing.
expect
	empty_page({ path: "/chat/dm/1_2/plans", viewer: "Steve" }, Notice("Apoorva is online."))
		.contains("Add a device</a></span> <p class=\"notice-strip\">Apoorva is online.</p> <div class=\"top-user\">")
expect
	empty_page({ path: "/chat/dm/1_2/plans", viewer: "Steve" }, Notice("<b> is online."))
		.contains("<p class=\"notice-strip\">&lt;b&gt; is online.</p>")
expect
	empty_page({ path: "/chat/dm/1_2/plans", viewer: "Steve" }, NoNotice)
		.contains("<p class=\"notice-strip\"></p>")

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
## `above`, what comes between its heading and its forms: first the
## password's, `name_focus` after its name field's attributes, then the
## device code's, its field labelled, typed in capitals with no correction,
## and `code_focus` after its attributes.
login_page : Str, { name_focus : Str, code_focus : Str } -> Str
login_page = |above, { name_focus, code_focus }|
	"${head("Sign in")}<h1>Sign in</h1>\n${above}<form method=\"post\" action=\"/login\"><input type=\"hidden\" name=\"next\" value=\"/agents\">\n<p>Name <input type=\"text\" name=\"name\" autocomplete=\"username\" required${name_focus}></p>\n<p>Password <input type=\"password\" name=\"password\" autocomplete=\"current-password\" required></p>\n<button>Sign in</button></form>\n<form method=\"post\" action=\"/login/code\"><input type=\"hidden\" name=\"next\" value=\"/agents\">\n<p><label>Have a code from your other device? Type its 8 digits: <input type=\"text\" name=\"code\" autocomplete=\"one-time-code\" inputmode=\"numeric\" pattern=\"[0-9\\s\\-]*\" title=\"The code's 8 digits\" autocorrect=\"off\" spellcheck=\"false\" maxlength=\"20\" required${code_focus}></label></p>\n<button>Sign in with the code</button></form>\n"

## The sign-in page for `viewer`, with `problem`, as a test reads it.
login_for : SignedIn.Actor, SignInPage.Problem -> Str
login_for = |viewer, problem|
	Str.from_utf8_lossy(
		SignInPage.login({
			viewer,
			next: Html.SitePath.from_str("/agents") ?? crash "PageSpec: a site path",
			problem,
			github: NotOffered,
		}).to_utf8(),
	)

# The sign-in page: for no one, the forms alone, the name's field focused;
# with a problem, it first: after a code's, the code's field focused; after
# a password's, neither; for someone signed in, under the top bar, who and
# the button that signs them out, and no form.
expect login_for(Anonymous, NoProblem) == login_page(
	"",
	{ name_focus: " autofocus", code_focus: "" },
)
expect
	login_for(Anonymous, Problem("No <match>."))
		== login_page("<p>No &lt;match&gt;.</p>\n", { name_focus: "", code_focus: "" })
expect
	login_for(Anonymous, CodeProblem("No <code>."))
		== login_page("<p>No &lt;code&gt;.</p>\n", { name_focus: "", code_focus: " autofocus" })
expect
	login_for(SignedIn(SignedIn.dangerously_assume(Sample.user("Steve"))), NoProblem)
		== "${head("Signed in")}<header class=\"top-bar\"><span class=\"top-title\">Signed in</span> ${top_links}<span class=\"viewer\">Steve</span> · <form class=\"sign-out\" method=\"post\" action=\"/logout\"><button>Sign out</button></form></div></header>\n<div class=\"layout\"><div class=\"panel\">\n<p>You are signed in as Steve.</p>\n<form method=\"post\" action=\"/logout\"><button>Sign out</button></form>\n</div></div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/panel.js\"></script>\n"
# With GitHub's settings, a link above the form, going on to `next`, and a
# line for those with a password.
expect
	Str.from_utf8_lossy(
		SignInPage.login({
			viewer: Anonymous,
			next: Html.SitePath.from_str("/chat/dm/1_1/plans") ?? crash "PageSpec: a site path",
			problem: NoProblem,
			github: Offered,
		}).to_utf8(),
	).contains("<h1>Sign in</h1>\n<p><a href=\"/login/github/start?next=/chat/dm/1_1/plans\">Sign in or sign up with GitHub</a></p>\n<p>Already have an account? Sign in with your password, then link GitHub.</p>\n<form method=\"post\" action=\"/login\">")
# The join page: a hidden field for the code, the name and a new password,
# then the script that reads the code from the link.
expect
	JoinPage.join.to_utf8()
		== "${head("Join")}<h1>Join the chat</h1>\n<p>Someone you know invited you. Keep the name they chose for you, or choose another that no one has; once you join, it is yours. Choose a password: you sign in with your name and it.</p>\n<form method=\"post\" action=\"/join\"><input type=\"hidden\" name=\"code\">\n<p>Your name <input type=\"text\" name=\"name\" autocomplete=\"username\" required></p>\n<p>Your password <input type=\"password\" name=\"password\" autocomplete=\"new-password\" required></p>\n<button>Join</button></form>\n<script src=\"/chat/assets/join.js\"></script>\n".to_utf8()

## The words above the form that asks a new human for a name.
sign_up_words : Str
sign_up_words = "GitHub says who you are, and you have no account here yet. Choose a name that no one has: letters and single spaces. Once you join, it is yours, and you sign in with GitHub.</p>\n<p>Everyone here sees this name, and it cannot be changed after you join. This page lasts 10 minutes; after that, sign in with GitHub again."

# The page asking a new human for a name: filled in or empty, and a problem
# above the words when there is one.
expect {
	zoe = Name.from_str("Zoë Ann") ?? crash "PageSpec: a name"
	SignInPage.github_sign_up({
		name: Named(zoe),
		problem: NoProblem,
		login_note: NoNote,
	}).to_utf8()
		== "${head("Choose your name")}<h1>Choose your name</h1>\n<p>${sign_up_words}</p>\n<form method=\"post\" action=\"/login/github/name\"><p>Your name <input type=\"text\" name=\"name\" autocomplete=\"username\" required maxlength=\"60\" value=\"Zoë Ann\"></p>\n<button>Join</button></form>\n".to_utf8()
}
expect
	SignInPage.github_sign_up({
		name: NoName,
		problem: Problem("The <name> is taken."),
		login_note: NoNote,
	}).to_utf8()
		== "${head("Choose your name")}<h1>Choose your name</h1>\n<p>The &lt;name&gt; is taken.</p>\n<p>${sign_up_words}</p>\n<form method=\"post\" action=\"/login/github/name\"><p>Your name <input type=\"text\" name=\"name\" autocomplete=\"username\" required maxlength=\"60\"></p>\n<button>Join</button></form>\n".to_utf8()
# A login not offered says why, above the form.
expect
	[
		(
			NoLogin,
			"<p>GitHub sent no login this chat can show, so no name is filled in.</p>\n<form",
		),
		(
			LoginNotAName,
			"<p>Your GitHub login is not offered: a name here is letters and single spaces, at most 60.</p>\n<form",
		),
		(LoginTaken, "<p>Your GitHub login is not offered: someone here has that name.</p>\n<form"),
		(
			ChatFull,
			"<p>Your GitHub login is not offered: the chat holds as many as it can.</p>\n<form",
		),
	].all(
		|(why, said)|
			Str.from_utf8_lossy(
				SignInPage.github_sign_up({
					name: NoName,
					problem: NoProblem,
					login_note: NotOffered(why),
				}).to_utf8(),
			)
				.contains(said),
	)
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
			sidebar: Sidebar({ places: [], online_humans: [], notice: NoNotice, rosters: [] }),
		}),
		AgentsPage.agents({
			viewer: steve,
			agents: Kept([]),
			shown: NoCode,
			github_link: LinkOffered,
		}),
		PeoplePages.channels({ viewer: steve, channels: [] }),
		PeoplePages.invites({
			viewer: steve,
			users: Sample.directory.users(),
			invited: [],
			github: NotOffered,
			may_invite: MayInvite,
			shown: NoLink,
			problem: NoProblem,
			now: Timestamp.at_second(0),
		}),
	].all(
		|page| {
			text = Str.from_utf8_lossy(page.to_utf8())
			has_links = text.contains(top_links) or text.contains(top_links_noticed)
			has_links and !text.contains("/join") and !text.contains("Sign in")
		},
	)
		and [
			JoinPage.join,
			PageKit.notice({ title: "t", text: "x" }),
			SignInPage.github_sign_up({
				name: NoName,
				problem: NoProblem,
				login_note: NoNote,
			}),
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
# The invites page of someone with no one to invite again: the steps, what an
# invite is for, the form, and that nothing is open.
expect
	PeoplePages.invites({
		viewer: SignedIn.dangerously_assume(Sample.user("Steve")),
		users: Sample.directory.users(),
		invited: [],
		github: NotOffered,
		may_invite: MayInvite,
		shown: NoLink,
		problem: NoProblem,
		now: Timestamp.at_second(0),
	}).to_utf8()
		== "${head("Invites")}<header class=\"top-bar\"><span class=\"top-title\">Invites</span> ${top_links}<span class=\"viewer\">Steve</span> · <form class=\"sign-out\" method=\"post\" action=\"/logout\"><button>Sign out</button></form></div></header>\n<div class=\"layout\"><div class=\"panel\">\n<p>1. Type their name.</p>\n<p>2. Copy the link.</p>\n<p>3. Send it to them; it works once, for 7 days.</p>\n<p class=\"help\">They choose a password when they join, and may keep the name or choose another.</p><form method=\"post\" action=\"/invites\"><p>Their name <input type=\"text\" name=\"name\" required></p>\n<button>Invite someone</button></form><h1>Open invites</h1>\n<p>No open invites.</p>\n</div></div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/panel.js\"></script>\n".to_utf8()
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

# A quote-reply's reference is linked by its label, exactly the quoted
# message's header reference, which app/actions.js follows: roc-markdown's
# link names `#msg-plans_1`, not the message's id, `msg-1`.
expect {
	conversation = Sample.conversation(
		Sample.plans,
		[
			Sample.unnumbered_message({
				author: "Steve",
				time: "2026-11-02T19:11:32Z",
				markdown: "Hello",
			}),
			Sample.unnumbered_message({
				author: "Steve",
				time: "2026-11-02T19:12:00Z",
				markdown: "In MSG_plans_1 I said:\n~~~ quote\nHello\n~~~\n\nyes",
			}),
		],
	)
	drawn = conversation.messages().map(
		|message|
			Str.from_utf8_lossy(
				ConversationPage.message({
					conversation,
					key: plans_key,
					users: Sample.directory.users(),
					message,
					notes: MessageNotes.fresh,
				}).to_utf8(),
			),
	)
	match drawn {
		[quoted, reply] =>
			quoted.contains("<article class=\"message\" id=\"msg-1\"")
				and quoted.contains("<a class=\"message-reference\" href=\"#msg-1\">MSG_plans_1</a></header>")
				and reply.contains("<p>In <a href=\"#msg-plans_1\" class=\"msg-ref\">MSG_plans_1</a> I said:</p>")
		_ => Bool.False
	}
}

## The conversation at `path` in the sample directory with its default
## channel, `general`.
recent_key : Str -> ConversationKey
recent_key = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "PageSpec: a path is UTF-8",
	directory: Sample.with_default_channel(Sample.directory),
}).map_ok(|found| found.key) ?? crash "PageSpec: a conversation's path"

## Steve's Recent page of `tiles`.
steves_recent : List(RecentFeed.Tile) -> Str
steves_recent = |tiles|
	Str.from_utf8_lossy(
		RecentFeed.page({ viewer: SignedIn.dangerously_assume(Sample.steve), tiles }).to_utf8(),
	)

## Steve's Recent page as a test expects it: its top bar's notice line,
## empty, where app/chrome.js shows the notices, then `parts`.
recent_page : Str -> Str
recent_page = |parts|
	"${head("Recent")}<header class=\"top-bar\"><span class=\"top-title\">Recent</span> ${top_links_noticed}<span class=\"viewer\">Steve</span> · <form class=\"sign-out\" method=\"post\" action=\"/logout\"><button>Sign out</button></form></div></header>\n<div class=\"layout\"><div class=\"panel\">\n${parts}\n<script src=\"/chat/assets/recent.js\"></script>\n<script src=\"/chat/assets/search.js\"></script>\n</div></div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/panel.js\"></script>\n"

# Recent with no conversation that has a message says so, above its list,
# empty, which names its stream.
expect
	steves_recent([])
		== recent_page("<p class=\"empty\">Nothing yet.</p>\n<div class=\"recent-list\" data-stream=\"/chat/recent/stream\"></div>")
# A channel's tile names the channel and the topic, a DM's the topic and
# its other human's initial; each spells its place out too ("#general", "DM
# with Apoorva"), and a DM's names its other human and whether they are
# online; each says who sent the last message, by their first name ("You"
# for the viewer), and its excerpt, escaped; a message with no excerpt has
# no preview.
expect {
	time = |text| DateTime.from_str(text) ?? crash "PageSpec: a time"
	steves_recent([
		{
			key: recent_key("/chat/channel/general/plans"),
			label: "#general",
			person: NoPerson,
			time: time("2026-11-03T10:00:00Z"),
			who: "You",
			excerpt: "a < b",
		},
		{
			key: recent_key("/chat/dm/1_2/books"),
			label: "Apoorva",
			person: Person(Sample.user("Apoorva").id(), Online),
			time: time("2026-11-02T19:11:32Z"),
			who: "Apoorva",
			excerpt: "",
		},
	])
		== recent_page(
			"<div class=\"recent-list\" data-stream=\"/chat/recent/stream\"><a class=\"recent-tile\" href=\"/chat/channel/general/plans\"><span class=\"recent-lead\"><span class=\"recent-bar\"></span></span><span class=\"recent-where\"><span class=\"recent-mark\"></span>#general</span><span class=\"recent-body\"><span class=\"recent-top\"><span class=\"recent-context\"><span class=\"recent-place\">#general</span><span class=\"recent-dot\">  ·  </span><span class=\"recent-topic\">plans</span></span><time class=\"recent-ago\" datetime=\"2026-11-03T10:00:00Z\">2026-11-03T10:00:00Z</time></span><span class=\"recent-preview\"><span class=\"recent-who\">You: </span>a &lt; b</span></span></a>\n<a class=\"recent-tile\" href=\"/chat/dm/1_2/books\" data-person=\"2\" data-presence=\"online\"><span class=\"recent-lead\"><span class=\"recent-avatar\">A</span></span><span class=\"recent-where\"><span class=\"recent-mark\"></span>DM with Apoorva</span><span class=\"recent-body\"><span class=\"recent-top\"><span class=\"recent-title\">books</span><time class=\"recent-ago\" datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time></span></span></a>\n</div>",
		)
}

# Every class, each its one spelling.
expect
	[
		(Author, "author"),
		(Body, "body"),
		(BrowsePanes, "browse-panes"),
		(CodeExpiry, "code-expiry"),
		(CodeStatus, "code-status"),
		(Compose, "compose"),
		(Current, "current"),
		(EditedMarkdown, "edited-markdown"),
		(EditedNote, "edited-note"),
		(EditedOriginal, "edited-original"),
		(Empty, "empty"),
		(Help, "help"),
		(InviteCode, "invite-code"),
		(InviteMade, "invite-made"),
		(InviteRow, "invite-row"),
		(SignInCode, "sign-in-code"),
		(SignOut, "sign-out"),
		(Layout, "layout"),
		(Message, "message"),
		(MessageReference, "message-reference"),
		(Messages, "messages"),
		(NoticeStrip, "notice-strip"),
		(Panel, "panel"),
		(Problem, "problem"),
		(ReactionChip, "reaction-chip"),
		(ReactionEmoji, "reaction-emoji"),
		(ReactionStrip, "reaction-strip"),
		(RecentAgo, "recent-ago"),
		(RecentAvatar, "recent-avatar"),
		(RecentBar, "recent-bar"),
		(RecentBody, "recent-body"),
		(RecentContext, "recent-context"),
		(RecentDot, "recent-dot"),
		(RecentLead, "recent-lead"),
		(RecentList, "recent-list"),
		(RecentMark, "recent-mark"),
		(RecentPlace, "recent-place"),
		(RecentPreview, "recent-preview"),
		(RecentTile, "recent-tile"),
		(RecentTitle, "recent-title"),
		(RecentTop, "recent-top"),
		(RecentTopic, "recent-topic"),
		(RecentWhere, "recent-where"),
		(RecentWho, "recent-who"),
		(Sidebar, "sidebar"),
		(SidebarMemberName, "sidebar-member-name"),
		(SidebarMembers, "sidebar-members"),
		(SidebarMemberWords, "sidebar-member-words"),
		(SidebarNewTopic, "sidebar-new-topic"),
		(SidebarPlace, "sidebar-place"),
		(SidebarPlaceName, "sidebar-place-name"),
		(SidebarSection, "sidebar-section"),
		(SidebarSectionName, "sidebar-section-name"),
		(SidebarToggle, "sidebar-toggle"),
		(SidebarTopics, "sidebar-topics"),
		(TopBar, "top-bar"),
		(TopLinks, "top-links"),
		(TopTitle, "top-title"),
		(TopicLink, "topic-link"),
		(TopUser, "top-user"),
		(Viewer, "viewer"),
		(You, "you"),
	].all(
		|
			(chosen, spelled),
		| PageContract.empty_paragraph([PageContract.class(chosen)]) == "<p class=\"${spelled}\"></p>".to_utf8(),
	)

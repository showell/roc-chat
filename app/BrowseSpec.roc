## These are the tests of `Browse`: what a human is shown, and its page, byte
## for byte.
import Browse
import ChannelName
import Channels
import ConversationKey
import Directory
import Html
import Place
import Sample
import SignInPage
import SignedIn
import Topic
import UserId
import UnvalidatedString
import UserPair

BrowseSpec :: [].{}

## The sample's users, Steve (1), Apoorva (2) and his agent CC (3), with a
## third human, Zoe (4), and two channels: `crew`, which holds Steve and CC,
## and `general`, which holds Apoorva.
directory : Directory
directory = {
	with_zoe =
		(Sample.directory.add_human(Sample.name("Zoe")) ?? crash "BrowseSpec: Zoe's name is free").directory
	channels =
		Channels.from_stored([
			{ name: channel_name("crew"), members: "1\n3\n".to_utf8() },
			{ name: channel_name("general"), members: "2\n".to_utf8() },
		]) ?? crash "BrowseSpec: the members files read"
	Directory.from_stored({ users: with_zoe.users(), channels })
		?? crash "BrowseSpec: the channels' members are users"
}

channel_name : Str -> ChannelName
channel_name = |text| ChannelName.from_str(text) ?? crash "BrowseSpec: a channel's name"

## The user of `directory` named `text`, signed in by a session.
signed_in : Str -> SignedIn
signed_in = |text| {
	user = directory.users().user_by_name(Sample.name(text)) ?? crash "BrowseSpec: a user"
	SignedIn.dangerously_assume(user)
}

## What Browse lists for the user named `text`, as a test reads it: each
## place's name and its path.
listed_for : Str -> Try(List((Str, Str)), [ByApiKey, Agent(UserId)])
listed_for = |text|
	Browse.places_for({ acting: signed_in(text), directory }).map_ok(
		|places|
			places.map(|listed| (listed.label, ConversationKey.place_url_path(listed.place))),
	)

# Every human as a DM with the reader, their own included, then the channels
# they belong to and no other: Steve is in `crew` and not `general`, and
# Apoorva the other way round. CC, an agent, is no one's DM.
expect
	listed_for("Steve")
		== Ok([
			("Steve", "/chat/dm/1_1"),
			("Apoorva", "/chat/dm/1_2"),
			("Zoe", "/chat/dm/1_4"),
			("#crew", "/chat/channel/crew"),
		])
expect
	listed_for("Apoorva")
		== Ok([
			("Steve", "/chat/dm/1_2"),
			("Apoorva", "/chat/dm/2_2"),
			("Zoe", "/chat/dm/2_4"),
			("#general", "/chat/channel/general"),
		])
# A human in no channel has their DMs alone, and none of them is another
# pair's.
expect
	listed_for("Zoe")
		== Ok([
			("Steve", "/chat/dm/1_4"),
			("Apoorva", "/chat/dm/2_4"),
			("Zoe", "/chat/dm/4_4"),
		])
# An agent browses nothing, by a session or any other way.
expect listed_for("CC") == Err(Agent(Sample.user("CC").id()))

## The place of the DM between Steve and Apoorva.
steve_and_apoorva : Place
steve_and_apoorva = {
	pair = UserPair.from_str("1_2") ?? crash "BrowseSpec: a pair"
	directory.place(Dm(pair)) ?? crash "BrowseSpec: Steve and Apoorva are humans"
}

## What the page for Steve opens with, the top bar and all, up to its panel's
## parts.
page_head : Str
page_head =
	"<!doctype html>\n<meta charset=utf-8>\n<meta name=viewport content=\"width=device-width, initial-scale=1\">\n<title>Browse</title>\n<script src=\"/chat/assets/palette.js\"></script>\n<header class=\"top-bar\"><span class=\"top-title\">Browse</span> <span class=\"top-links\"><a href=\"/chat\">Browse</a> · <a href=\"/chat/recent\">Recent</a> · <a href=\"/invites\">Invites</a> · <a href=\"/devices\">Add a device</a></span> <div class=\"top-user\"><a href=\"https://lynrummy.com/\">Home</a> · <span class=\"viewer\">Steve</span> · <form class=\"sign-out\" method=\"post\" action=\"/logout\"><button>Sign out</button></form></div></header>\n<div class=\"layout\"><div class=\"panel\">\n"

## The quiet lines for someone new, which every Browse page opens with.
newcomer_lines : Str
newcomer_lines = "<div class=\"help\"><p>New here? Every place you can read is below: open a topic, or start one with its place&#39;s form.</p>\n<p>In a conversation, the sidebar lists your places, and its + starts a topic or a DM.</p>\n<p>Recent shows the newest messages everywhere, as they arrive.</p>\n<p>In a topic, c writes, q quote-replies, and / searches; the keys are listed beside the messages.</p>\n<p>To bring someone in, use Invites in the top bar.</p>\n</div>"

## What the page ends with, after its panel's parts: the panel's end and the
## scripts that style the page.
page_foot : Str
page_foot = "</div></div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/panel.js\"></script>\n"

## The page's two panes, holding `channels` and `dms`, each a place's markup.
panes : Str, Str -> Str
panes = |channels, dms|
	"<div class=\"browse-panes\"><div><h1>Channels</h1>\n${channels}</div><div><h1>Direct messages</h1>\n${dms}</div></div>\n"

## The form of the DM between Steve and Apoorva, its field holding `value`.
apoorva_form : Str -> Str
apoorva_form = |value|
	"<form method=\"post\" action=\"/chat/dm/1_2\"><p>New topic <input type=\"text\" name=\"topic\" required${value}></p>\n<button>Add topic</button></form>\n"

## The page for Steve of one place, with `topics` and `problem`.
page_of : List(Topic), Browse.TopicProblem -> Str
page_of = |topics, problem|
	Str.from_utf8_lossy(
		Browse.page({
			viewer: signed_in("Steve"),
			places: [{ label: "Apoorva", place: steve_and_apoorva, topics }],
			problem,
		}).to_utf8(),
	)

## `text` as a form brings it, typed.
typed_text : Str -> [Typed(UnvalidatedString), NothingTyped]
typed_text = |text|
	Typed(UnvalidatedString.from_utf8(text.to_utf8()) ?? crash "BrowseSpec: typed text is UTF-8")

## The problem at Steve and Apoorva's form, after `text` was typed there.
problem_at_apoorva : Str -> Browse.TopicProblem
problem_at_apoorva = |text|
	Problem({
		place: steve_and_apoorva,
		typed: typed_text(text),
		words: "No <topic>.",
	})

# A place with no topics says so, and suggests its first; a pane with no
# places says so.
expect
	page_of([], NoProblem)
		== "${page_head}${newcomer_lines}${panes("<p>None yet.</p>\n", "<h1>Apoorva</h1>\n<p>No topics yet</p>\n${apoorva_form(" value=\"general\"")}")}${page_foot}"
# A place with topics links each to its page, a row each, and suggests no name.
expect
	page_of([Sample.other, Sample.plans], NoProblem)
		== "${page_head}${newcomer_lines}${panes("<p>None yet.</p>\n", "<h1>Apoorva</h1>\n<p><a class=\"topic-link\" href=\"/chat/dm/1_2/other\">other</a></p>\n<p><a class=\"topic-link\" href=\"/chat/dm/1_2/plans\">plans</a></p>\n${apoorva_form("")}")}${page_foot}"
# A problem is said under its place's form, marked as the problem, and the
# form holds what was typed: a name, or a token.
expect
	page_of([Sample.plans], problem_at_apoorva("two words"))
		== "${page_head}${newcomer_lines}${panes("<p>None yet.</p>\n", "<h1>Apoorva</h1>\n<p><a class=\"topic-link\" href=\"/chat/dm/1_2/plans\">plans</a></p>\n${apoorva_form(" value=\"two words\"")}<p class=\"problem\">No &lt;topic&gt;.</p>\n")}${page_foot}"
expect page_of([], problem_at_apoorva("2plans")).contains(apoorva_form(" value=\"2plans\""))
# What neither a name nor a token spells is not given back: the field is
# empty, and the problem still said.
expect {
	page = page_of([], problem_at_apoorva("plans_2\"><b>"))
	page.contains("${apoorva_form("")}<p class=\"problem\">No &lt;topic&gt;.</p>")
		and !page.contains("<b>")
}
expect
	page_of(
		[],
		Problem({
			place: steve_and_apoorva,
			typed: NothingTyped,
			words: "No field.",
		}),
	)
		.contains("${apoorva_form("")}<p class=\"problem\">No field.</p>")
# A problem whose place isn't listed is said first, never lost.
expect {
	crew = directory.place(Channel(channel_name("crew"))) ?? crash "BrowseSpec: crew is a channel"
	page_of(
		[],
		Problem({
			place: crew,
			typed: NothingTyped,
			words: "No <topic>.",
		}),
	)
		.starts_with("${page_head}<p class=\"problem\">No &lt;topic&gt;.</p>\n${newcomer_lines}")
}
# The channels go in their pane, the DMs in theirs; the reader's own DM is
# their name with a quiet "(you)", and another's DM is not.
expect {
	listed = Browse.places_for({ acting: signed_in("Steve"), directory }) ?? crash "BrowseSpec: Steve browses"
	page = Str.from_utf8_lossy(
		Browse.page({
			viewer: signed_in("Steve"),
			places: listed.map(|{ label, place }| { label, place, topics: [] }),
			problem: NoProblem,
		}).to_utf8(),
	)
	page.contains("<div><h1>Channels</h1>\n<h1>#crew</h1>")
		and page.contains("<div><h1>Direct messages</h1>\n<h1>Steve <span class=\"you\">(you)</span></h1>")
		and page.contains("<h1>Apoorva</h1>")
		and !page.contains("Apoorva <span")
}
# The page has no sign-up or join link, and no link to the invites page,
# which the top bar holds.
expect {
	page = page_of([], NoProblem)
	!page.contains("/join") and !page.contains("/login") and !page.contains("<p><a href=\"/invites\">")
}
# The sign-in page of someone signed in offers no form and no GitHub, even
# with GitHub's settings, and has the top bar's link; of no one, the reverse.
expect {
	next = Html.SitePath.from_str("/chat") ?? crash "BrowseSpec: a site path"
	page = |viewer|
		Str.from_utf8_lossy(
			SignInPage.login({
				viewer,
				next,
				problem: NoProblem,
				github: Offered,
			}).to_utf8(),
		)
	theirs = page(SignedIn(signed_in("Steve")))
	nobodys = page(Anonymous)
	theirs.contains("<a href=\"/chat\">Browse</a>")
		and !theirs.contains("action=\"/login\"")
		and !theirs.contains("/login/github")
		and nobodys.contains("action=\"/login\"")
		and nobodys.contains("/login/github/start")
		and !nobodys.contains("<a href=\"/chat\">Browse</a>")
}

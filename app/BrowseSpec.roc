## These are the tests of `Browse`: what a human is shown, and its page, byte
## for byte.
import Browse
import ChannelName
import Channels
import ConversationKey
import Directory
import Html
import Page
import Place
import Sample
import SignedIn
import Topic
import UserId
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
		Channels.from_files([
			{ name: channel_name("crew"), members: "1\n3\n".to_utf8() },
			{ name: channel_name("general"), members: "2\n".to_utf8() },
		]) ?? crash "BrowseSpec: the members files read"
	Directory.from_files({ users: with_zoe.users(), channels })
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
			places.map(
				|listed| (
					listed.label,
					ConversationKey.place_url_path(listed.place),
				),
			),
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
	"<!doctype html>\n<meta charset=utf-8>\n<meta name=viewport content=\"width=device-width, initial-scale=1\">\n<title>Browse</title>\n<script src=\"/chat/assets/palette.js\"></script>\n<header class=\"top-bar\"><span class=\"top-title\">Browse</span> <div class=\"top-user\"><a href=\"/chat\">Browse</a> · <span class=\"viewer\">Steve</span></div></header>\n<div class=\"layout\"><div class=\"panel\">\n"

## What the page ends with, after its panel's parts: the panel's end and the
## scripts that style the page.
page_foot : Str
page_foot = "</div></div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/panel.js\"></script>\n"

## The page for Steve of one place, with `topics` and `problem`.
page_of : List(Topic), [NoProblem, Problem(Str)] -> Str
page_of = |topics, problem|
	Str.from_utf8_lossy(
		Browse.page({
			viewer: signed_in("Steve"),
			places: [
				{
					label: "Apoorva",
					place: steve_and_apoorva,
					topics,
				},
			],
			problem,
		}).to_utf8(),
	)

# A place with no topics says so, and suggests its first.
expect
	page_of([], NoProblem)
		== "${page_head}<h1>Apoorva</h1>\n<p>No sessions yet</p>\n<form method=\"post\" action=\"/chat/dm/1_2\"><p>New topic <input type=\"text\" name=\"topic\" required value=\"general\"></p>\n<button>Add topic</button></form>\n${page_foot}"
# A place with topics links each to its page, and suggests no name.
expect
	page_of([Sample.other, Sample.plans], NoProblem)
		== "${page_head}<h1>Apoorva</h1>\n<p><a href=\"/chat/dm/1_2/other\">other</a></p>\n<p><a href=\"/chat/dm/1_2/plans\">plans</a></p>\n<form method=\"post\" action=\"/chat/dm/1_2\"><p>New topic <input type=\"text\" name=\"topic\" required></p>\n<button>Add topic</button></form>\n${page_foot}"
# A problem comes first, as text.
expect
	page_of([Sample.plans], Problem("No <topic>."))
		== "${page_head}<p>No &lt;topic&gt;.</p>\n<h1>Apoorva</h1>\n<p><a href=\"/chat/dm/1_2/plans\">plans</a></p>\n<form method=\"post\" action=\"/chat/dm/1_2\"><p>New topic <input type=\"text\" name=\"topic\" required></p>\n<button>Add topic</button></form>\n${page_foot}"
# The page has no sign-up or join link.
expect {
	page = page_of([], NoProblem)
	!page.contains("/join") and !page.contains("/login")
}
# The sign-in page of someone signed in offers no form and no GitHub, even
# with GitHub's settings, and has the top bar's link; of no one, the reverse.
expect {
	next = Html.SitePath.from_str("/chat") ?? crash "BrowseSpec: a site path"
	page = |viewer|
		Str.from_utf8_lossy(
			Page.login({
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

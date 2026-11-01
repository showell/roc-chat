## **BROWSE: WHERE A HUMAN'S TOPICS ARE**, `GET /chat/browse`: the DMs
## and channels the viewer is a member of, each with the topics they may
## read there, each topic a link to its page (TopicPage.roc). Its link is
## the top bar's first (Chrome.roc), where the old app's "Chat" was.
##
## **THE OLD APP HAD NO SUCH PAGE**: its counterpart is the left sidebar's
## lists (chat-client's js/chat_left_sidebar.js, angry-gopher's
## chat_page.zig `buildSidebarJSON`), whose order and words it keeps: DMs,
## then channels by name, each channel `# <name>`; topics in byte order of
## their names; a place with none, "No sessions yet"; nothing at all, "You
## do not have any conversations.". Who reads which topic is Topic.read's,
## as the topics' routes ask it. A page is a browser's: signed out, to
## `/login`; a key, a 403.
import pf.Chat
import Access
import Channel
import Chrome
import Conversations
import Html
import Pages
import Principal
import Store
import Topic
import Topics

Browse := [].{

	## Whether a path is Browse's.
	route : List(U8) -> Try([Browse], [NotBrowse])
	route = |path| if (path == "/chat/browse".to_utf8()) Ok(Browse) else Err(NotBrowse)

	## **ANSWER IT**, to a GET or a HEAD.
	answer! : Chat.Request => Chat.Answer
	answer! = |req|
		if req.method != Get and req.method != Head {
			Chat.not_allowed(Get)
		} else {
			match list!(req.path) {
				Ok(answer) => answer
				Err(answer) => answer
			}
		}
}

## One place the viewer is in: what Browse calls it, the path its topics'
## pages start with, and the topics they read there, in order.
Place : {
	label : Str,
	base : Str,
	topics : List(Topic),
}

list! : List(U8) => Try(Chat.Answer, Chat.Answer)
list! = |path| {
	v = Topics.viewer!({})?
	me =
		match v.viewer.who() {
			SignedOut => Err(Pages.sign_in_first(path))
			Key(_) => Err(Pages.by_key)
			Session(b) => Ok(b)
		}?
	stored = Store.load_channels!({}).map_err(|_| Chat.failed)?
	mine = stored.channels.keep_if(|c| c.membership({ who: me, accounts: v.accounts }) == Member)
	dms = mine.keep_if(|c| c.name().is_dm()).keep_oks(
		|c| dm_place(
			c,
			{ me, accounts: v.accounts },
		),
	).sort_with(
		|a, b| by_bytes(
			a.label.to_utf8(),
			b.label.to_utf8(),
		),
	)
	channels = mine.keep_if(|c| !c.name().is_dm()).sort_with(
		|a, b| by_bytes(
			a.name().key().to_utf8(),
			b.name().key().to_utf8(),
		),
	).map(
		|c| {
			label: "# ${c.name().to_str()}",
			base: "/chat/channel/${c.name().to_str()}",
			channel: c,
		},
	)
	places = List.concat(
		dms.map(
			|d| {
				label: d.label,
				base: d.base,
				channel: d.channel,
			},
		),
		channels,
	)
	shown = with_topics!(
		places,
		[],
		{ viewer: v.viewer, accounts: v.accounts },
	)?
	damaged = stored.damaged
	Ok(
		Chrome.page({
			title: Html.markup("Browse"),
			viewer: Html.text(Conversations.name_of(v.accounts, me.id)),
			here: Browse,
			kind: Plain,
			body_attrs: Html.join([]),
			body: Html.join([
				if (shown.is_empty()) Html.markup("<p>You do not have any conversations.</p>\n") else Html.join([
					Html.markup("<div class=browse>\n"),
					Html.join(shown.map(place_html)),
					Html.markup("</div>\n"),
				]),
				if (damaged == 0) Html.join([]) else Html.join([
					Html.markup("<p id=damaged class=muted>"),
					Html.number(damaged),
					Html.markup(" channel records do not read, and are not listed.</p>\n"),
				]),
				Html.markup("<p class=muted><a href=\"/chat\">Your agents' conversations</a></p>\n"),
			]),
		}),
	)
}

## **A DM, AS BROWSE NAMES IT**: by the other human's name, its pages
## under `/chat/dm/<their id>`. A DM whose other member no account holds
## is left out: nobody is there to talk to.
dm_place : Channel,
{ me : Principal.Bound, accounts : List(Principal) } -> Try(
	{
		label : Str,
		base : Str,
		channel : Channel,
	},
	[NoOther],
)
dm_place = |c, { me, accounts }|
	match c.members(accounts).keep_if(|b| b.id != me.id) {
		[other] =>
			match other.id {
				Human(h) => Ok({
					label: Conversations.name_of(accounts, other.id),
					base: "/chat/dm/${h.to_u64().to_str()}",
					channel: c,
				})
				_ => Err(NoOther)
			}
		_ => Err(NoOther)
	}

## One place: its label, then its topics as links, or "No sessions yet".
place_html : Place -> Html
place_html = |p|
	Html.join([
		Html.markup("<section><h2>"),
		Html.text(p.label),
		Html.markup("</h2>\n<ul class=browse-list>\n"),
		if (p.topics.is_empty()) Html.markup("<li class=muted>No sessions yet</li>\n") else Html.join(
			p.topics.map(
				|t| Html.join([
					Html.markup("<li><a href=\""),
					Html.text(p.base),
					Html.markup("/"),
					Html.text(t.at().topic.to_str()),
					Html.markup("\">"),
					Html.text(t.at().topic.to_str()),
					Html.markup("</a></li>\n"),
				]),
			),
		),
		Html.markup("</ul></section>\n"),
	])

## **EACH PLACE WITH THE TOPICS THE VIEWER READS THERE** (Topic.read, as
## the topics' routes ask it), sorted by name; a channel whose topics do
## not load fails the page, never shows it short.
with_topics! : List(
	{
		label : Str,
		base : Str,
		channel : Channel,
	},
),
List(Place),
{ viewer : Access.Viewer(Topic.At), accounts : List(Principal) } => Try(List(Place), Chat.Answer)
with_topics! = |
	todo,
	done,
	{ viewer, accounts },
|
	match todo {
		[] => Ok(done)
		[p, .. as rest] => {
			listed = Store.load_topics!(p.channel).map_err(|_| Chat.failed)?
			readable = listed.topics.keep_if(
				|t| t.read({
					viewer,
					channel: p.channel,
					accounts,
				}) == Permitted,
			)
			topics = readable.sort_with(
				|a, b| by_bytes(
					a.at().topic.to_str().to_utf8(),
					b.at().topic.to_str().to_utf8(),
				),
			)
			with_topics!(
				rest,
				done.append({
					label: p.label,
					base: p.base,
					topics,
				}),
				{ viewer, accounts },
			)
		}
	}

## Two byte strings' order, byte by byte, a prefix first.
by_bytes : List(U8),
List(U8) -> [
	Before,
	Same,
	After,
]
by_bytes = |x, y|
	match (x, y) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([a, .. as xs], [b, .. as ys]) =>
			if a < b {
				Before
			} else if a > b {
				After
			} else {
				by_bytes(xs, ys)
			}
	}

expect by_bytes("Ann".to_utf8(), "Bea".to_utf8()) == Before
expect by_bytes("Bea".to_utf8(), "Ann".to_utf8()) == After
expect by_bytes("Ann".to_utf8(), "Ann".to_utf8()) == Same
expect by_bytes("An".to_utf8(), "Ann".to_utf8()) == Before
expect by_bytes("Zoe".to_utf8(), "ann".to_utf8()) == Before

# A topic's link is under its place's base; an empty place says so.
expect {
	html = place_html({
		label: "# <Lobby>",
		base: "/chat/channel/Lobby",
		topics: [],
	}).bytes()
	html == "<section><h2># &lt;Lobby&gt;</h2>\n<ul class=browse-list>\n<li class=muted>No sessions yet</li>\n</ul></section>\n".to_utf8()
}

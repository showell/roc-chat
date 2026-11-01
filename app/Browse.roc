## **BROWSE: WHERE A HUMAN'S TOPICS ARE**, `GET /chat/browse`: every other
## human, as a DM, then the channels the viewer is a member of, each with
## the topics they may read there, each topic a link to its page
## (TopicPage.roc). Its link is the top bar's first (Chrome.roc), where the
## old app's "Chat" was.
##
## **THE OLD APP HAD NO SUCH PAGE**: its counterpart is the left sidebar's
## Conversations list (chat-client's js/chat_left_sidebar.js, angry-gopher's
## chat_page.zig `buildSidebarJSON`), whose order and words it keeps: every
## other human by numeric id (users.zig `lessThanByNumericID`), then the
## viewer's channels, each `# <name>`, in byte order of their names
## (`lessThanStr`); topics in byte order of theirs; a place with none, "No
## sessions yet"; nothing at all, "You do not have any conversations.".
## **A HUMAN WITH NO DM YET** has a button that makes it: the old app opened
## the DM on a click, and here a DM is made by a write
## (`POST /chat/dm/<n>`, a form, behind Origin's check), which lands back
## on Browse at that DM. Who reads which topic is Topic.read's, as the
## topics' routes ask it. A page is a browser's: signed out, to `/login`;
## a key, a 403.
import pf.Chat
import Access
import Cast
import Channel
import ChannelName
import Chrome
import Conversations
import Html
import Pages
import Principal
import Store
import Stored
import Topic
import Topics
import Wire

Browse := [].{

	## What a path asks of Browse: the page, or a DM made with a human.
	Route : [List, StartDm(Principal.HumanId)]

	## The route a path names, if it names one.
	route : List(U8) -> Try(Browse.Route, [NotBrowse])
	route = |path|
		if path == "/chat/browse".to_utf8() {
			Ok(List)
		} else {
			match path.split_on('/') {
				[
					[],
					chat,
					dm,
					n,
				] if chat == "chat".to_utf8() and dm == "dm".to_utf8() =>
					Stored.id(
						n,
						{ name: "human", make: Principal.HumanId.from_u64 },
					).map_ok(|h| StartDm(h)).map_err(|_| NotBrowse)
				_ => Err(NotBrowse)
			}
		}

	## **ANSWER IT**: the page to a GET or a HEAD; a DM made to a POST.
	answer! : Chat.Request, Browse.Route => Chat.Answer
	answer! = |req, r| {
		got =
			match r {
				List => if (req.method == Get or req.method == Head) list!(req.path) else Ok(Chat.not_allowed(Get))
				StartDm(other) => if (req.method == Post) start_dm!(other) else Ok(Chat.not_allowed(Post))
			}
		match got {
			Ok(answer) => answer
			Err(answer) => answer
		}
	}
}

## One place on Browse: what it is called, where it lives on the page
## (`id`), and either its topics' links or the button that makes it.
Place : {
	label : Str,
	id : Str,
	shows : [Topics({ base : Str, topics : List(Topic) }), NoDmYet(Principal.HumanId)],
}

list! : List(U8) => Try(Chat.Answer, Chat.Answer)
list! = |path| {
	v = Topics.load_viewer!({})?
	me =
		match v.viewer.who() {
			SignedOut => Err(Pages.to_login(path))
			Key(_) => Err(Pages.key_refused)
			Session(b) => Ok(b)
		}?
	mine =
		match me.id {
			Human(h) => Ok(h.to_u64())
			_ => Err(Pages.key_refused)
		}?
	stored = Store.load_channels!({}).map_err(|_| Chat.failed)?
	member = stored.channels.keep_if(|c| c.membership({ who: me, accounts: v.accounts }) == Member)
	dms = humans_by_id(v.accounts).keep_if(|h| h.to_u64() != mine).map(
		|h| {
			name = ChannelName.dm_of(mine, h.to_u64())
			label = Conversations.name_of(v.accounts, Principal.Id.Human(h))
			id = "dm-${h.to_u64().to_str()}"
			match member.keep_if(|c| c.name() == name) {
				[c, ..] => {
					label,
					id,
					shows: Channel(c, "/chat/dm/${h.to_u64().to_str()}"),
				}
				[] => {
					label,
					id,
					shows: NoDm(h),
				}
			}
		},
	)
	channels = member.keep_if(|c| !c.name().is_dm()).sort_with(
		|a, b| by_bytes(
			a.name().to_str().to_utf8(),
			b.name().to_str().to_utf8(),
		),
	).map(
		|c| {
			label: "# ${c.name().to_str()}",
			id: "channel-${c.name().to_str()}",
			shows: Channel(c, "/chat/channel/${c.name().to_str()}"),
		},
	)
	shown = with_topics!(
		dms.concat(channels),
		[],
		{ viewer: v.viewer, accounts: v.accounts },
	)?
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
				if (stored.damaged == 0) Html.join([]) else Html.join([
					Html.markup("<p id=damaged class=muted>"),
					Html.number(stored.damaged),
					Html.markup(" channel records do not read, and are not listed.</p>\n"),
				]),
				Html.markup("<p class=muted><a href=\"/chat\">Your agents' conversations</a></p>\n"),
			]),
		}),
	)
}

## **EVERY HUMAN, BY NUMERIC ID**, as the old sidebar listed its users.
humans_by_id : List(Principal) -> List(Principal.HumanId)
humans_by_id = |accounts|
	accounts.keep_oks(
		|p|
			match p {
				Human(h) => Ok(h.id)
				_ => Err(NotAHuman)
			},
	).sort_with(
		|
			a,
			b,
		| if (a.to_u64() < b.to_u64()) Before else if (a.to_u64() > b.to_u64()) After else Same,
	)

## **EACH PLACE WITH THE TOPICS THE VIEWER READS THERE** (Topic.read, as
## the topics' routes ask it), sorted by name; a channel whose topics do
## not load fails the page, never shows it short.
with_topics! : List(
	{
		label : Str,
		id : Str,
		shows : [Channel(Channel, Str), NoDm(Principal.HumanId)],
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
			shows =
				match p.shows {
					NoDm(h) => Ok(NoDmYet(h))
					Channel(c, base) => {
						listed = Store.load_topics!(c).map_err(|_| Chat.failed)?
						readable = listed.topics.keep_if(
							|t| t.read({
								viewer,
								channel: c,
								accounts,
							}) == Permitted,
						)
						Ok(
							Topics({
								base,
								topics: readable.sort_with(
									|a, b| by_bytes(
										a.at().topic.to_str().to_utf8(),
										b.at().topic.to_str().to_utf8(),
									),
								),
							}),
						)
					}
				}?
			with_topics!(
				rest,
				done.append({
					label: p.label,
					id: p.id,
					shows,
				}),
				{ viewer, accounts },
			)
		}
	}

## One place: its label, then its topics as links, or "No sessions yet",
## or, for a human with no DM yet, the button that makes one.
place_html : Place -> Html
place_html = |p|
	Html.join([
		Html.markup("<section id=\""),
		Html.text(p.id),
		Html.markup("\"><h2>"),
		Html.text(p.label),
		Html.markup("</h2>\n"),
		match p.shows {
			NoDmYet(h) =>
				Html.join([
					Html.markup("<form class=start-dm method=post action=\"/chat/dm/"),
					Html.number(h.to_u64()),
					Html.markup("\"><button>Start a DM</button></form>\n"),
				])
			Topics({ base, topics }) =>
				Html.join([
					Html.markup("<ul class=browse-list>\n"),
					if (topics.is_empty()) Html.markup("<li class=muted>No sessions yet</li>\n") else Html.join(
						topics.map(
							|t| topic_html(
								base,
								t,
							),
						),
					),
					Html.markup("</ul>\n"),
				])
		},
		Html.markup("</section>\n"),
	])

## A topic's link, under its place's base.
topic_html : Str, Topic -> Html
topic_html = |base, t|
	Html.join([
		Html.markup("<li><a href=\""),
		Html.text(base),
		Html.markup("/"),
		Html.text(t.at().topic.to_str()),
		Html.markup("\">"),
		Html.text(t.at().topic.to_str()),
		Html.markup("</a></li>\n"),
	])

## **A DM MADE FROM BROWSE**: the viewer's DM with `other` (Topics.make_dm!,
## as `POST /dms` makes it), then back to Browse at it, a 303. Signed out,
## a 401; a key, a 403.
start_dm! : Principal.HumanId => Try(Chat.Answer, Chat.Answer)
start_dm! = |other| {
	v = Topics.load_viewer!({})?
	match v.viewer.who() {
		SignedOut => Err(Wire.refused(401, "not signed in"))
		Key(_) => Err(Pages.key_refused)
		Session(_) => {
			_ = Topics.make_dm!(v, Principal.Id.Human(other))?
			Ok(
				Chat.respond(303, { content_type: Chat.text, body: [] })
					|> Chat.with_header(
						"location",
						"/chat/browse#dm-${other.to_u64().to_str()}".to_utf8(),
					),
			)
		}
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
expect Browse.route("/chat/browse".to_utf8()) == Ok(List)
expect
	match Browse.route("/chat/dm/7".to_utf8()) {
		Ok(StartDm(h)) => h.to_u64() == 7
		_ => Bool.False
	}
expect Browse.route("/chat/dm/07".to_utf8()).is_err()
expect Browse.route("/chat/dm/x".to_utf8()).is_err()
expect Browse.route("/chat/browse/x".to_utf8()).is_err()

# A topic's link is under its place's base; an empty place says so; a
# human with no DM has the button that makes one.
expect {
	html = place_html({
		label: "# <Lobby>",
		id: "channel-Lobby",
		shows: Topics({ base: "/chat/channel/Lobby", topics: [] }),
	}).bytes()
	html == "<section id=\"channel-Lobby\"><h2># &lt;Lobby&gt;</h2>\n<ul class=browse-list>\n<li class=muted>No sessions yet</li>\n</ul>\n</section>\n".to_utf8()
}
expect {
	html = place_html({
		label: "Zoe",
		id: "dm-9",
		shows: NoDmYet(Cast.hid(9)),
	}).bytes()
	html == "<section id=\"dm-9\"><h2>Zoe</h2>\n<form class=start-dm method=post action=\"/chat/dm/9\"><button>Start a DM</button></form>\n</section>\n".to_utf8()
}

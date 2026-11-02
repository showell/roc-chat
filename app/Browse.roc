## **BROWSE: WHERE A HUMAN'S TOPICS ARE**, `GET /chat/browse`: every
## human, as a DM, the viewer too (their self-DM), then the channels the viewer is a member of, each with
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
## **A NEW TOPIC, FROM BROWSE**: each place has the old app's Add Topic form
## (chat-client's js/chat_add_topic.js), a topic's name, "general" where the
## place has none yet (the old first-topic page, js/chat_first_topic.js).
## It posts `topic=` to the place's own path, `POST /chat/dm/<n>` or
## `POST /chat/channel/<c>` (a form, behind Origin's check): a DM with
## someone not yet met is made first, then the topic, and the browser lands
## on the topic's page, empty and ready to write in. A DM's form with no
## `topic=` makes the DM alone and lands back on Browse at it. Who reads
## which topic is Topic.read's, as the topics' routes ask it. A page is a
## browser's: signed out, to `/login`; a key, a 403.
import pf.Chat
import pf.Host
import Access
import Cast
import Channel
import ChannelName
import Chrome
import Messages
import Html
import Pages
import Principal
import Render
import SignInWeb
import Store
import Stored
import Topic
import Topics
import Wire

Browse := [].{

	## What a path asks of Browse: the page; a DM (and perhaps its first
	## topic) made with a human; or a topic made in a channel.
	Route : [
		List,
		StartDm(ChannelName),
		NewTopic(ChannelName),
	]

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
					match Str.from_utf8(n) {
						Ok(text) => ChannelName.dm_from(text).map_ok(|pair| StartDm(pair)).map_err(|_| NotBrowse)
						Err(_) => Err(NotBrowse)
					}
				[
					[],
					chat,
					channel,
					c,
				] if chat == "chat".to_utf8() and channel == "channel".to_utf8() =>
					match Str.from_utf8(c) {
						Ok(text) =>
							ChannelName.from_str(text).map_ok(|name| NewTopic(name)).map_err(|_| NotBrowse)
						Err(_) => Err(NotBrowse)
					}
				_ => Err(NotBrowse)
			}
		}

	## **ANSWER IT**: the page to a GET or a HEAD; a DM or a topic made to a
	## POST, its form read first.
	answer! : Chat.Request, Browse.Route => Chat.Answer
	answer! = |req, r| {
		got =
			match r {
				List => if (req.method == Get or req.method == Head) list!(req.path) else Ok(Chat.not_allowed(Get))
				StartDm(other) => if (req.method == Post) with_form!(|form| start_dm!(other, form)) else Ok(Chat.not_allowed(Post))
				NewTopic(name) => if (req.method == Post) with_form!(|form| new_topic!(name, form)) else Ok(Chat.not_allowed(Post))
			}
		match got {
			Ok(answer) => answer
			Err(answer) => answer
		}
	}
}

## A POST's form read, then `then!` on it.
with_form! : (List(U8) => Try(Chat.Answer, Chat.Answer)) => Try(Chat.Answer, Chat.Answer)
with_form! = |then!| {
	got = Host.read_body!(Wire.form_most)
	match got.status {
		Answered => Ok(Chat.answered)
		Read => then!(got.bytes)
	}
}

## The form's `topic=`, if it names one: none, or an empty one, is none.
topic_named : List(U8) -> [Named(Str), NoTopic]
topic_named = |form|
	match SignInWeb.form_field(form, "topic") {
		Ok(bytes) =>
			match Str.from_utf8(bytes) {
				Ok(text) if text.trim() != "" => Named(text.trim())
				_ => NoTopic
			}
		Err(_) => NoTopic
	}

## A 303 to `location`.
see_other : Str -> Chat.Answer
see_other = |location|
	Chat.respond(303, { content_type: Chat.text, body: [] })
		|> Chat.with_header("location", location.to_utf8())

## One place on Browse: what it is called, where it lives on the page
## (`id`), and either its topics' links or the button that makes it.
Place : {
	label : Str,
	id : Str,
	shows : [Topics({ base : Str, topics : List(Topic) }), NoDmYet(ChannelName)],
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
	# Every human, the viewer too: their own row is their self-DM.
	dms = humans_by_id(v.accounts).map(
		|h| {
			name = ChannelName.dm_of(mine, h.to_u64())
			label = Render.name_of(v.accounts, Principal.Id.Human(h))
			id = "dm-${h.to_u64().to_str()}"
			match member.keep_if(|c| c.name() == name) {
				[c, ..] => {
					label,
					id,
					shows: Channel(c, "/chat/dm/${name.to_str()}"),
				}
				[] => {
					label,
					id,
					shows: NoDm(name),
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
			viewer: Html.text(Render.name_of(v.accounts, me.id)),
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
				Html.markup("<p class=muted><a href=\"/chat\">Your agents</a></p>\n"),
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
		shows : [Channel(Channel, Str), NoDm(ChannelName)],
	},
),
List(Place),
{ viewer : Access.Viewer, accounts : List(Principal) } => Try(List(Place), Chat.Answer)
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
			NoDmYet(pair) => add_topic_html("/chat/dm/${pair.to_str()}", First)
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
					add_topic_html(base, if (topics.is_empty()) First else More),
				])
		},
		Html.markup("</section>\n"),
	])

## **THE ADD TOPIC FORM**, posting `topic=` to the place's own path: a
## place's first topic is offered as "general", as the old first-topic page
## offered it; a later one starts empty.
add_topic_html : Str, [First, More] -> Html
add_topic_html = |action, which|
	Html.join([
		Html.markup("<form class=add-topic method=post action=\""),
		Html.text(action),
		Html.markup("\"><input name=topic placeholder=\"new topic\" required value=\""),
		Html.text(
			match which {
				First => "general"
				More => ""
			},
		),
		Html.markup("\"> <button>Add topic</button></form>\n"),
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

## **A DM MADE FROM BROWSE** (`POST /chat/dm/<pair>`): the pair's DM
## (Topics.make_dm!, as `POST /dms` makes it), made once, by one of its
## two humans; with a `topic=`, that topic is made in it too, and the
## browser lands on its page; without one, back to Browse at the DM. A 303
## either way. Someone not of the pair, a 404; signed out, a 401; a key, a
## 403.
start_dm! : ChannelName, List(U8) => Try(Chat.Answer, Chat.Answer)
start_dm! = |pair, form| {
	v = Topics.load_viewer!({})?
	match v.viewer.who() {
		SignedOut => Err(Wire.refused(401, "not signed in"))
		Key(_) => Err(Pages.key_refused)
		Session(me) => {
			other = other_of(pair, me.id)?
			made = Topics.make_dm!(v, Principal.Id.Human(other))?
			match topic_named(form) {
				NoTopic => Ok(see_other("/chat/browse#dm-${other.to_u64().to_str()}"))
				Named(topic) => {
					t = Topics.make_topic!({ channel: made.dm.name(), name: topic })?
					Ok(see_other(Topics.page_path(t.at())))
				}
			}
		}
	}
}

## **THE PAIR'S OTHER HUMAN, FOR ONE OF THEM** (themselves, in a self-DM);
## anyone else asking is not of the pair: the 404 of a page not there.
other_of : ChannelName, Principal.Id -> Try(Principal.HumanId, Chat.Answer)
other_of = |pair, me| {
	not_yours = Wire.refused(404, "no such DM")
	ids = pair.dm_pair().map_err(|_| not_yours)?
	mine =
		match me {
			Human(h) => Ok(h.to_u64())
			_ => Err(not_yours)
		}?
	if mine == ids.lo {
		Principal.HumanId.from_u64(ids.hi).map_err(|_| not_yours)
	} else if mine == ids.hi {
		Principal.HumanId.from_u64(ids.lo).map_err(|_| not_yours)
	} else {
		Err(not_yours)
	}
}

## **A TOPIC MADE IN A CHANNEL FROM BROWSE**: `topic=` made there (Topic.make
## decides who may), and the browser lands on its page, a 303. Signed out,
## a 401; a key, a 403; no `topic=`, a 400.
new_topic! : ChannelName, List(U8) => Try(Chat.Answer, Chat.Answer)
new_topic! = |name, form| {
	v = Topics.load_viewer!({})?
	match v.viewer.who() {
		SignedOut => Err(Wire.refused(401, "not signed in"))
		Key(_) => Err(Pages.key_refused)
		Session(_) =>
			match topic_named(form) {
				NoTopic => Err(Wire.refused(400, "name the topic: topic="))
				Named(topic) => {
					t = Topics.make_topic!({ channel: name, name: topic })?
					Ok(see_other(Topics.page_path(t.at())))
				}
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
	match Browse.route("/chat/dm/7_11".to_utf8()) {
		Ok(StartDm(pair)) => pair == ChannelName.dm_of(11, 7)
		_ => Bool.False
	}
# A pair in its one spelling alone: 11_7, an id with a leading zero, one id, none.
expect
	[
		"/chat/dm/11_7",
		"/chat/dm/07_11",
		"/chat/dm/7",
		"/chat/dm/x",
	].all(|path| Browse.route(path.to_utf8()).is_err())
# The pair's other human, for either of them (themselves in a self-DM); anyone else, none.
expect other_of(ChannelName.dm_of(7, 11), Principal.Id.Human(Cast.hid(7))).map_ok(|h| h.to_u64()) == Ok(11)
expect other_of(ChannelName.dm_of(7, 11), Principal.Id.Human(Cast.hid(11))).map_ok(|h| h.to_u64()) == Ok(7)
expect other_of(ChannelName.dm_of(5, 5), Principal.Id.Human(Cast.hid(5))).map_ok(|h| h.to_u64()) == Ok(5)
expect other_of(ChannelName.dm_of(7, 11), Principal.Id.Human(Cast.hid(9))).is_err()
expect other_of(ChannelName.dm_of(7, 11), Principal.Id.Agent(Cast.aid(7))).is_err()
expect Browse.route("/chat/browse/x".to_utf8()).is_err()

# A topic's link is under its place's base; an empty place says so and
# offers "general" as its first topic; a human with no DM has the same form,
# which makes the DM and the topic together.
expect {
	html = place_html({
		label: "# <Lobby>",
		id: "channel-Lobby",
		shows: Topics({ base: "/chat/channel/Lobby", topics: [] }),
	}).bytes()
	html == "<section id=\"channel-Lobby\"><h2># &lt;Lobby&gt;</h2>\n<ul class=browse-list>\n<li class=muted>No sessions yet</li>\n</ul>\n<form class=add-topic method=post action=\"/chat/channel/Lobby\"><input name=topic placeholder=\"new topic\" required value=\"general\"> <button>Add topic</button></form>\n</section>\n".to_utf8()
}
expect {
	html = place_html({
		label: "Zoe",
		id: "dm-9",
		shows: NoDmYet(ChannelName.dm_of(9, 2)),
	}).bytes()
	html == "<section id=\"dm-9\"><h2>Zoe</h2>\n<form class=add-topic method=post action=\"/chat/dm/2_9\"><input name=topic placeholder=\"new topic\" required value=\"general\"> <button>Add topic</button></form>\n</section>\n".to_utf8()
}
# A channel's path names a topic's making there; a DM's pair never.
expect Browse.route("/chat/channel/Lobby".to_utf8()) == Ok(NewTopic(ChannelName.from_str("Lobby") ?? crash "a channel name"))
expect Browse.route("/chat/channel/1_2".to_utf8()).is_err()
expect Browse.route("/chat/channel/Lobby/general".to_utf8()).is_err()

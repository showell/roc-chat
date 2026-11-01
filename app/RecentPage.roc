## **RECENT**, `GET /chat/recent`: the old app's "most fundamental"
## feature, a flat newest-first feed of the viewer's topics (angry-gopher's
## recent.zig, chat-client's js/recent.js): every topic they read in the
## DMs and channels they are in, and every conversation of theirs, as
## Browse lists them, one tile each by its last message (Recent.roc draws
## it), newest first, a tie by its page's path; one with no message yet
## goes last. Live, `GET /chat/recent/stream` sends the viewer each new
## post's tile, drawn for them (Topics' publish, Conversations'
## append_post!), live only: the page is the backlog, as the old
## page's was. Its script (js/recent_page.js) writes each tile's age and moves a
## tile that changed to its place. A page is a browser's: signed out, to
## `/login` (the stream, a 401); a key, a 403.
import pf.Chat
import Access
import Channel
import ChannelName
import Chrome
import ConvAccess
import Conversations
import Html
import MessageCodec
import PageFeed
import Pages
import Principal
import Recent
import Store
import Topic
import Topics
import Wire

RecentPage := [].{

	## What a path asks of Recent.
	Route : [Page, Stream]

	## The route a path names, if it names one.
	route : List(U8) -> Try(RecentPage.Route, [NotRecent])
	route = |path|
		if path == "/chat/recent".to_utf8() {
			Ok(Page)
		} else if path == "/chat/recent/stream".to_utf8() {
			Ok(Stream)
		} else {
			Err(NotRecent)
		}

	## **ANSWER IT**: the page to a GET or a HEAD, the stream to a GET.
	answer! : Chat.Request, RecentPage.Route => Chat.Answer
	answer! = |req, r| {
		allowed =
			match r {
				Page => req.method == Get or req.method == Head
				Stream => req.method == Get
			}
		if !allowed {
			Chat.not_allowed(Get)
		} else {
			match serve!({ path: req.path, route: r }) {
				Ok(answer) => answer
				Err(answer) => answer
			}
		}
	}
}

serve! : { path : List(U8), route : RecentPage.Route } => Try(Chat.Answer, Chat.Answer)
serve! = |{ path, route }| {
	v = Topics.load_viewer!({})?
	me =
		match v.viewer.who() {
			SignedOut =>
				match route {
					Page => Err(Pages.to_login(path))
					Stream => Err(Wire.refused(401, "not signed in"))
				}
			Key(_) => Err(Pages.key_refused)
			Session(b) => Ok(b)
		}?
	match route {
		Stream => Ok(
			Chat.stream({
				key: PageFeed.recent_key(me.id),
				backlog: [],
				holder: Conversations.holder(v.viewer),
			}),
		)
		Page => {
			stored = Store.load_channels!({}).map_err(|_| Chat.failed)?
			mine = stored.channels.keep_if(
				|c| c.membership({
					who: me,
					accounts: v.accounts,
				}) == Member,
			)
			rows = rows_of!(
				mine,
				[],
				{
					viewer: v.viewer,
					accounts: v.accounts,
					me: me.id,
				},
			)?
			convs = Conversations.load_mine!(Access.Viewer.over(v.viewer), v.accounts).map_err(|_| Chat.failed)?
			conv_rows = conv_rows_of!(convs, { accounts: v.accounts, me: me.id })?
			ordered = rows.concat(conv_rows).sort_with(newest_first)
			Ok(
				Chrome.page({
					title: Html.markup("Recent"),
					viewer: Html.text(Conversations.name_of(v.accounts, me.id)),
					here: Recent,
					kind: Plain,
					body_attrs: Html.markup(" class=recent-page"),
					body: Html.join([
						Html.markup("<div class=chat-notify id=chat-notify></div>\n<div id=recent-mount><div class=recent-list>\n"),
						Html.join(ordered.map(Recent.tile)),
						Html.markup("</div>\n"),
						if (ordered.is_empty()) Html.markup("<p id=recent-empty class=muted>Nothing yet.</p>\n") else Html.join([]),
						Html.markup("</div>\n<script src=\"/recent_page.js\"></script>\n"),
					]),
				}),
			)
		}
	}
}

## **EVERY TOPIC THE VIEWER READS IN THESE CHANNELS** (Topic.read), each
## its row with its last message; a channel whose topics or a transcript
## that does not load fails the page, never shows it short.
rows_of! : List(Channel),
List(Recent.Row),
{
	viewer : Access.Viewer(Topic.At),
	accounts : List(Principal),
	me : Principal.Id,
} => Try(List(Recent.Row), Chat.Answer)
rows_of! = |
	channels,
	done,
	{
		viewer,
		accounts,
		me,
	},
|
	match channels {
		[] => Ok(done)
		[channel, .. as rest] => {
			listed = Store.load_topics!(channel).map_err(|_| Chat.failed)?
			readable = listed.topics.keep_if(
				|t| t.read({
					viewer,
					channel,
					accounts,
				}) == Permitted,
			)
			rows = rows_in!(
				readable,
				[],
				{
					channel,
					accounts,
					me,
				},
			)?
			rows_of!(
				rest,
				done.concat(rows),
				{
					viewer,
					accounts,
					me,
				},
			)
		}
	}

## Each topic's row, with its last message when it has one.
rows_in! : List(Topic),
List(Recent.Row),
{
	channel : Channel,
	accounts : List(Principal),
	me : Principal.Id,
} => Try(List(Recent.Row), Chat.Answer)
rows_in! = |
	topics,
	done,
	{
		channel,
		accounts,
		me,
	},
|
	match topics {
		[] => Ok(done)
		[topic, .. as rest] => {
			last = last_of!(Store.topic_files(topic.at()))?
			row = Topics.recent_row({
				topic,
				members: channel.members(accounts),
				reader: me,
				accounts,
				last,
			})
			rows_in!(
				rest,
				done.append(row),
				{
					channel,
					accounts,
					me,
				},
			)
		}
	}

## **EACH OF THE VIEWER'S CONVERSATIONS** (Conversations.load_mine!), its
## row with its last message; a transcript that does not load fails the
## page, never shows it short.
conv_rows_of! : List(ConvAccess.Conv), { accounts : List(Principal), me : Principal.Id } => Try(List(Recent.Row), Chat.Answer)
conv_rows_of! = |convs, { accounts, me }|
	match convs {
		[] => Ok([])
		[conv, .. as rest] => {
			last = last_of!(Store.conversation_files(conv.id()))?
			row = Conversations.recent_row({
				conv,
				reader: me,
				accounts,
				last,
			})
			more = conv_rows_of!(rest, { accounts, me })?
			Ok(more.prepend(row))
		}
	}

## A transcript's last message, read alone (Store.load_span!), or none.
last_of! : Store.TranscriptFiles => Try([NoMessage, Last({ m : MessageCodec.Fields, excerpt : Str })], Chat.Answer)
last_of! = |files| {
	tally = Store.load_tally!(files).map_err(|_| Chat.failed)?
	if tally.messages == 0 {
		Ok(NoMessage)
	} else {
		span = Store.load_span!(
			files,
			tally,
			{ first: tally.messages, last: tally.messages },
		).map_err(|_| Chat.failed)?
		match span {
			[m] => Ok(Last({ m, excerpt: Recent.excerpt(m.body) }))
			_ => Ok(NoMessage)
		}
	}
}

## **NEWEST FIRST**, a tie broken by the page's path, byte by byte, so
## every host shows one order (the old `newestFirst`).
newest_first : Recent.Row,
Recent.Row -> [
	Before,
	Same,
	After,
]
newest_first = |a, b|
	if a.ts > b.ts {
		Before
	} else if a.ts < b.ts {
		After
	} else {
		by_bytes(a.url.to_utf8(), b.url.to_utf8())
	}

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
		(
			[p, .. as xs],
			[q, .. as ys],
		) => if (p < q) Before else if (p > q) After else by_bytes(xs, ys)
	}

expect RecentPage.route("/chat/recent".to_utf8()) == Ok(Page)
expect RecentPage.route("/chat/recent/stream".to_utf8()) == Ok(Stream)
expect RecentPage.route("/chat/recent/x".to_utf8()).is_err()
expect {
	row = |url, ts| {
		url,
		ts,
		dm: Bool.False,
		place: "L",
		topic: "T",
		last: NoMessage,
	}
	[
		row("/b", 5),
		row("/a", 5),
		row("/c", 9),
		row("/d", 0),
	].sort_with(newest_first).map(|r| r.url) == [
		"/c",
		"/a",
		"/b",
		"/d",
	]
}

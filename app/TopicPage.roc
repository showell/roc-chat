## **A TOPIC'S PAGE, FOR A HUMAN IN A BROWSER**: a channel's or a DM's
## topic, its transcript drawn here, its new messages drawn here too and
## sent as fragments the page puts in as they are. The page's script
## (js/feed.js) is glue: it places a fragment, marks each bubble mine or
## theirs from the page's viewer, writes each time in the viewer's zone,
## and follows new messages only when the reader was caught up.
##
##     GET /chat/channel/<channel>/<topic>          the page: the newest page of
##                                                  messages, the transcript and
##                                                  the right pane (empty for now)
##     GET /chat/dm/<n>/<topic>                     a DM's (`n` the other human's id)
##     GET .../stream                               each message, live, as its bubble
##                                                  (SSE, `message`, its id the
##                                                  message's), after `Last-Event-ID`,
##                                                  or else after `?after=`
##     GET .../earlier?before=<id>                  the page of bubbles before
##                                                  `<id>`, a fragment
##
## **WHO MAY** is the topic's own routes' (Topics.readable!, Topic.read):
## a topic the viewer may not read is the 404 of one that is not there,
## for the page, its stream and its fragments alike. **A PAGE IS A
## BROWSER'S**: signed out, the page sends the browser to `/login` (its
## stream and fragments, a 401); a key, a 403.
import pf.Chat
import pf.Host
import Access
import AccountCodec
import Bubble
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
import TopicName
import Topics
import Wire

TopicPage := [].{

	## Which topic a path names: a channel's, or a DM's by its other human.
	Place : [
		InChannel(Topic.At),
		InDm({ other : Principal.HumanId, topic : TopicName }),
	]

	## What a path asks of it.
	Route : [
		Page(TopicPage.Place),
		Stream(TopicPage.Place),
		Earlier(TopicPage.Place),
	]

	## The route a path names, if it names one.
	route : List(U8) -> Try(TopicPage.Route, [NotATopicPage])
	route = |path| {
		place = |
			kind,
			a,
			b,
		|
			if kind == "channel".to_utf8() {
				Topics.channel_topic_in(a, b).map_ok(|at| InChannel(at)).map_err(|_| NotATopicPage)
			} else if kind == "dm".to_utf8() {
				Topics.dm_topic_in(a, b).map_ok(|d| InDm(d)).map_err(|_| NotATopicPage)
			} else {
				Err(NotATopicPage)
			}
		match path.split_on('/') {
			[
				[],
				chat,
				kind,
				a,
				b,
			] if chat == "chat".to_utf8() => place(
				kind,
				a,
				b,
			).map_ok(|p| Page(p))
			[
				[],
				chat,
				kind,
				a,
				b,
				what,
			] if chat == "chat".to_utf8() =>
				if what == "stream".to_utf8() {
					place(
						kind,
						a,
						b,
					).map_ok(|p| Stream(p))
				} else if what == "earlier".to_utf8() {
					place(
						kind,
						a,
						b,
					).map_ok(|p| Earlier(p))
				} else {
					Err(NotATopicPage)
				}
			_ => Err(NotATopicPage)
		}
	}

	## **ANSWER A ROUTE**: a GET (or a HEAD, for the page and a fragment).
	answer! : Chat.Request, TopicPage.Route => Chat.Answer
	answer! = |req, r| {
		get_only = match r {
			Stream(_) => req.method != Get
			Page(_) | Earlier(_) => req.method != Get and req.method != Head
		}
		if get_only {
			Chat.not_allowed(Get)
		} else {
			match serve!(req.path, r) {
				Ok(answer) => answer
				Err(answer) => answer
			}
		}
	}
}

## **WHAT A REQUEST ON A TOPIC'S PAGE DECIDES ON**: the viewer, signed in
## by their session; the topic they read; and where it lives in a path.
Shown : {
	viewer : Access.Viewer(Topic.At),
	accounts : List(Principal),
	me : Principal.Bound,
	channel : Channel,
	topic : Topic,
	base : Str,
}

serve! : List(U8), TopicPage.Route => Try(Chat.Answer, Chat.Answer)
serve! = |path, r| {
	place =
		match r {
			Page(p) | Stream(p) | Earlier(p) => p
		}
	v = Topics.viewer!({})?
	me =
		match v.viewer.who() {
			SignedOut =>
				match r {
					Page(_) => Err(Pages.sign_in_first(path))
					Stream(_) | Earlier(_) => Err(Wire.refused(401, "not signed in"))
				}
			Key(_) => Err(Pages.by_key)
			Session(b) => Ok(b)
		}?
	at = at_of(me, place)?
	found = Topics.readable!(v, at)?
	shown = {
		viewer: v.viewer,
		accounts: v.accounts,
		me,
		channel: found.channel,
		topic: found.topic,
		base: base_of(found.topic.at(), place),
	}
	match r {
		Page(_) => page!(shown)
		Stream(_) => stream!(shown)
		Earlier(_) => earlier!(shown)
	}
}

## **A DM'S PLACE IS THE ASKER'S**: the pair of the viewer and the other
## human (ChannelName.dm_of); oneself, or an agent asking, has none, the 404
## of a topic that is not there.
at_of : Principal.Bound, TopicPage.Place -> Try(Topic.At, Chat.Answer)
at_of = |me, place|
	match place {
		InChannel(at) => Ok(at)
		InDm({ other, topic }) =>
			match me.id {
				Human(h) if h != other => Ok({
					channel: ChannelName.dm_of(h.to_u64(), other.to_u64()),
					topic,
				})
				_ => Err(no_such_topic)
			}
	}

## Where a topic's page lives, its names as they were made.
base_of : Topic.At, TopicPage.Place -> Str
base_of = |at, place|
	match place {
		InChannel(_) => "/chat/channel/${at.channel.to_str()}/${at.topic.to_str()}"
		InDm({ other, topic: _ }) => "/chat/dm/${other.to_u64().to_str()}/${at.topic.to_str()}"
	}

## **THE PAGE'S TITLE**, the old app's: `#<channel>: <topic>` for a
## channel's topic, `Chat w/<name>: <topic>` for a DM's.
title_of : Shown -> Html
title_of = |s| {
	at = s.topic.at()
	if at.channel.is_dm() {
		other = s.channel.members(s.accounts).keep_if(|b| b.id != s.me.id)
		name =
			match other {
				[b] => Conversations.name_of(s.accounts, b.id)
				_ => at.channel.to_str()
			}
		Html.text("Chat w/${name}: ${at.topic.to_str()}")
	} else {
		Html.text("#${at.channel.to_str()}: ${at.topic.to_str()}")
	}
}

## **THE PAGE**: the newest page of messages, each its bubble, in the feed
## column; the button for the page before; the right pane, empty for now.
## The body names its viewer (`data-me`), its stream, which starts after
## the newest message drawn here, and where earlier pages come from.
page! : Shown => Try(Chat.Answer, Chat.Answer)
page! = |s| {
	files = Store.topic_files(s.topic.at())
	tally = Store.load_tally!(files).map_err(|_| Chat.failed)?
	span = Conversations.page_of(tally.messages, Newest)
	messages = Store.load_span!(
		files,
		tally,
		span,
	).map_err(|_| Chat.failed)?
	newest = messages.last().map_ok(|m| m.id) ?? 0
	Ok(
		Chrome.page({
			title: title_of(s),
			viewer: Html.text(Conversations.name_of(s.accounts, s.me.id)),
			here: Elsewhere,
			kind: Chat,
			body_attrs: Html.join([
				Html.markup(" data-me=\""),
				Html.text(AccountCodec.id_text(s.me.id)),
				Html.markup("\" data-stream=\""),
				Html.text(s.base),
				Html.markup("/stream?after="),
				Html.number(newest),
				Html.markup("\" data-earlier=\""),
				Html.text(s.base),
				Html.markup("/earlier\""),
			]),
			body: Html.join([
				Html.markup("<div class=chat-layout>\n<div id=chat-feed class=chat-mp-main>\n<div class=chat-mp-nav><button id=earlier type=button"),
				if (span.first > 1) Html.join([]) else Html.markup(" hidden"),
				Html.markup(">Earlier messages</button></div>\n<div id=chat-history class=chat-mp-history tabindex=-1><div id=chat-bubbles>\n"),
				if (messages.is_empty()) Html.markup("<p id=chat-empty class=muted>No messages yet. Say hello 👋</p>\n") else Html.join([]),
				Html.join(messages.map(|m| Bubble.of(s.accounts, m))),
				Html.markup("</div></div>\n</div>\n<div id=chat-right-sidebar class=chat-compose></div>\n</div>\n<script src=\"/feed.js\"></script>\n"),
			]),
		}),
	)
}

## **THE PAGE OF BUBBLES BEFORE `?before=`**, a fragment: one element
## holding them, oldest first, and whether messages come before it
## (`data-earlier`, 1 or 0).
earlier! : Shown => Try(Chat.Answer, Chat.Answer)
earlier! = |s| {
	before =
		match Host.read_query!(Str.to_utf8("before")) {
			[only] => Stored.count(only, "before").map_err(|_| bad_before)
			_ => Err(bad_before)
		}?
	files = Store.topic_files(s.topic.at())
	tally = Store.load_tally!(files).map_err(|_| Chat.failed)?
	span = Conversations.page_of(tally.messages, Before(before))
	messages = Store.load_span!(
		files,
		tally,
		span,
	).map_err(|_| Chat.failed)?
	Ok(
		Html.respond(
			200,
			Html.join([
				Html.markup("<div data-earlier="),
				Html.number(if (span.first > 1) 1 else 0),
				Html.markup(">\n"),
				Html.join(messages.map(|m| Bubble.of(s.accounts, m))),
				Html.markup("</div>\n"),
			]),
		),
	)
}

## **THE STREAM**: the bubbles after `Last-Event-ID` (a reconnect's), or
## else after `?after=` (the page's newest), at most the newest page of
## them, then each one posted, live, built once for every page
## (Topics.page_frame); a page further behind gets a `gap` first, as a
## topic's stream does.
stream! : Shown => Try(Chat.Answer, Chat.Answer)
stream! = |s| {
	at = s.topic.at()
	files = Store.topic_files(at)
	tally = Store.load_tally!(files).map_err(|_| Chat.failed)?
	after =
		match Host.read_header!(Str.to_utf8("last-event-id")) {
			[only] => Stored.count(only, "last-event-id") ?? 0
			_ =>
				match Host.read_query!(Str.to_utf8("after")) {
					[only] => Stored.count(only, "after") ?? 0
					_ => 0
				}
		}
	newest = Conversations.page_of(tally.messages, Newest)
	first =
		if after < newest.first {
			newest.first
		} else if after < tally.messages {
			after + 1
		} else {
			tally.messages + 1
		}
	messages = Store.load_span!(
		files,
		tally,
		{ first, last: tally.messages },
	).map_err(|_| Chat.failed)?
	gap = if (after > 0 and after + 1 < newest.first) Topics.gap(newest.first) else []
	Ok(
		Chat.stream({
			key: Topics.page_key(at),
			backlog: gap.concat(List.join(messages.map(|m| Topics.page_frame(s.accounts, m)))),
			holder: Conversations.holder(s.viewer),
		}),
	)
}

bad_before : Chat.Answer
bad_before = Wire.refused(400, "before= is a message's id")

no_such_topic : Chat.Answer
no_such_topic = Wire.refused(404, "no such topic")

# ── tests
expect
	match TopicPage.route("/chat/channel/Lobby/ChitChat".to_utf8()) {
		Ok(Page(InChannel(at))) => at.channel.to_str() == "Lobby" and at.topic.to_str() == "ChitChat"
		_ => Bool.False
	}
expect
	match TopicPage.route("/chat/dm/7/ChitChat/stream".to_utf8()) {
		Ok(Stream(InDm({ other, topic: _ }))) => other.to_u64() == 7
		_ => Bool.False
	}
expect
	match TopicPage.route("/chat/channel/Lobby/ChitChat/earlier".to_utf8()) {
		Ok(Earlier(_)) => Bool.True
		_ => Bool.False
	}
# A DM's name is no channel's; nor a bad name, an unknown kind or part.
expect TopicPage.route("/chat/channel/dm-1-2/ChitChat".to_utf8()).is_err()
expect TopicPage.route("/chat/channel/Lobby/chit_chat".to_utf8()).is_err()
expect TopicPage.route("/chat/dm/07/ChitChat".to_utf8()).is_err()
expect TopicPage.route("/chat/dm/human:7/ChitChat".to_utf8()).is_err()
expect TopicPage.route("/chat/room/Lobby/ChitChat".to_utf8()).is_err()
expect TopicPage.route("/chat/channel/Lobby/ChitChat/other".to_utf8()).is_err()
expect TopicPage.route("/chat/channel/Lobby".to_utf8()).is_err()
expect TopicPage.route("/chat/7".to_utf8()).is_err()
expect TopicPage.route("/chat/channel/Lobby/ChitChat/stream/x".to_utf8()).is_err()

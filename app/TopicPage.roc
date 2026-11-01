## **A TOPIC'S PAGE, FOR A HUMAN IN A BROWSER**: a channel's or a DM's
## topic, its transcript drawn here, its new messages drawn here too and
## sent as fragments the page puts in as they are. The page's script
## (js/feed.js) is glue: it places a fragment, marks each bubble mine or
## theirs from the page's viewer, writes each time in the viewer's zone,
## and follows new messages only when the reader was caught up.
##
##     GET /chat/channel/<channel>/<topic>          the page: the newest page of
##                                                  messages, the transcript and
##                                                  the right pane (compose, keys)
##     GET /chat/dm/<n>/<topic>                     a DM's (`n` the other human's id)
##     GET .../stream                               each message, live, as its bubble
##                                                  (SSE, `message`, its id the
##                                                  message's), after `Last-Event-ID`,
##                                                  or else after `?after=`
##     GET .../earlier?before=<id>                  the page of bubbles before
##                                                  `<id>`, a fragment
##     POST .../send                                a post from the compose box: the
##                                                  body the markdown; `201` and the
##                                                  new message's bubble
##     GET .../quote?n=<id>                         a quote-reply of the message, for
##                                                  the compose box: `{"text":…}`
##     POST .../save                                a save to the viewer's reading list
##                                                  (`n=`, `note=`): `201` and its
##                                                  reference (SavedPage.roc)
##     GET .../edit?n=<id>                          an edit of one's own message, for
##                                                  the compose box: `{"text":…,
##                                                  "caret":…}`; another's, a 403
##
## **WHO MAY** is the topic's own routes' (Topics.verdict!, Topic.read):
## a topic the viewer may not read is the 404 of one that is not there,
## for the page, its stream and its fragments alike; the page says why, in
## the old app's words, which name no channel the viewer is not in. **A PAGE IS A
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
import Edits
import Html
import JsonOut
import MessageCodec
import Pages
import Principal
import ReadingList
import SavedPage
import SignInWeb
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
		Send(TopicPage.Place),
		Quote(TopicPage.Place),
		Save(TopicPage.Place),
		Edit(TopicPage.Place),
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
				Topics.at_in(a, b).map_ok(|at| InChannel(at)).map_err(|_| NotATopicPage)
			} else if kind == "dm".to_utf8() {
				Topics.dm_in(a, b).map_ok(|d| InDm(d)).map_err(|_| NotATopicPage)
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
				} else if what == "send".to_utf8() {
					place(
						kind,
						a,
						b,
					).map_ok(|p| Send(p))
				} else if what == "quote".to_utf8() {
					place(
						kind,
						a,
						b,
					).map_ok(|p| Quote(p))
				} else if what == "edit".to_utf8() {
					place(
						kind,
						a,
						b,
					).map_ok(|p| Edit(p))
				} else if what == "save".to_utf8() {
					place(
						kind,
						a,
						b,
					).map_ok(|p| Save(p))
				} else {
					Err(NotATopicPage)
				}
			_ => Err(NotATopicPage)
		}
	}

	## **ANSWER A ROUTE**: a GET (or a HEAD, for the page and a fragment);
	## a send, a POST, its body read first, as a topic's post reads it.
	answer! : Chat.Request, TopicPage.Route => Chat.Answer
	answer! = |req, r| {
		refused =
			match r {
				Stream(_) => if (req.method != Get) Err(Chat.not_allowed(Get)) else Ok(NoBody)
				Page(_) | Earlier(_) | Quote(_) | Edit(_) => if (req.method != Get and req.method != Head) Err(Chat.not_allowed(Get)) else Ok(NoBody)
				Send(_) =>
					if req.method != Post {
						Err(Chat.not_allowed(Post))
					} else {
						got = Host.read_body!(Conversations.message_most)
						match got.status {
							Answered => Err(Chat.answered)
							Read => Ok(Body(got.bytes))
						}
					}
				Save(_) =>
					if req.method != Post {
						Err(Chat.not_allowed(Post))
					} else {
						got = Host.read_body!(Wire.form_most)
						match got.status {
							Answered => Err(Chat.answered)
							Read => Ok(Body(got.bytes))
						}
					}
			}
		match refused {
			Err(answer) => answer
			Ok(body) =>
				match serve!({
					path: req.path,
					route: r,
					body,
				}) {
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

serve! : {
	path : List(U8),
	route : TopicPage.Route,
	body : [NoBody, Body(List(U8))],
} => Try(Chat.Answer, Chat.Answer)
serve! = |
	{
		path,
		route: r,
		body,
	},
| {
	place =
		match r {
			Page(p) | Stream(p) | Earlier(p) | Send(p) | Quote(p) | Edit(p) | Save(p) => p
		}
	v = Topics.load_viewer!({})?
	me =
		match v.viewer.who() {
			SignedOut =>
				match r {
					Page(_) => Err(Pages.to_login(path))
					Stream(_) | Earlier(_) | Send(_) | Quote(_) | Edit(_) | Save(_) => Err(
						Wire.refused(
							401,
							"not signed in",
						),
					)
				}
			Key(_) => Err(Pages.key_refused)
			Session(b) => Ok(b)
		}?
	at = at_of(me, place)?
	found =
		match Topics.verdict!(v, at) {
			Ok(f) => Ok(f)
			Err(SignedOut) => Err(Wire.refused(401, "not signed in"))
			Err(Failed) => Err(Chat.failed)
			Err(NotYours) => Err(
				not_here(
					r,
					{
						why: NotYours,
						at,
						accounts: v.accounts,
						me,
					},
				),
			)
			Err(NoTopic) => Err(
				not_here(
					r,
					{
						why: NoTopic,
						at,
						accounts: v.accounts,
						me,
					},
				),
			)
		}?
	shown = {
		viewer: v.viewer,
		accounts: v.accounts,
		me,
		channel: found.channel,
		topic: found.topic,
		base: base_of(found.topic.at(), place),
	}
	match (r, body) {
		(Page(_), _) => page!(shown)
		(Stream(_), _) => stream!(shown)
		(Earlier(_), _) => earlier!(shown)
		(Quote(_), _) => quote!(shown)
		(Edit(_), _) => edit!(shown)
		(Send(_), Body(bytes)) => send!(
			v,
			shown,
			bytes,
		)
		(Save(_), Body(bytes)) => save!(
			v,
			shown,
			bytes,
		)
		(
			Send(_),
			NoBody,
		)
		| (Save(_), NoBody) => crash "TopicPage.serve!: answer! reads a POST's body first"
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
		InChannel(_) => Topics.page_path(at, InChannel)
		InDm({ other, topic: _ }) => Topics.page_path(at, InDm(other))
	}

## **A TOPIC'S PAGE THAT IS NOT THERE SAYS WHY**, as the old app's did
## (angry-gopher's chat.zig, `serveNotFoundPage`): a 404 page titled "Not
## here", its reason, and the way back. A channel that is not there and one
## the viewer is not in read alike, so it names no channel a viewer cannot
## see; a topic not there (or one a member may not read) is named. Its
## stream and its fragments answer the plain 404.
not_here : TopicPage.Route,
{
	why : [NotYours, NoTopic],
	at : Topic.At,
	accounts : List(Principal),
	me : Principal.Bound,
} -> Chat.Answer
not_here = |
	r,
	{
		why,
		at,
		accounts,
		me,
	},
|
	match r {
		Stream(_) | Earlier(_) | Send(_) | Quote(_) | Edit(_) | Save(_) => no_such_topic
		Page(_) => {
			what =
				match why {
					NotYours => "#${at.channel.to_str()} is not a channel you are a member of."
					NoTopic => "There is no topic “${at.topic.to_str()}” in this conversation."
				}
			answer = Chrome.page({
				title: Html.markup("Not here"),
				viewer: Html.text(Conversations.name_of(accounts, me.id)),
				here: Elsewhere,
				kind: Plain,
				body_attrs: Html.join([]),
				body: Html.join([
					Html.markup("<p>"),
					Html.text(what),
					Html.markup("</p><p><a href=\"/chat/browse\">Go back</a></p>\n"),
				]),
			})
			{ ..answer, status: 404 }
		}
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
## the newest message drawn here, where earlier pages come from, and where
## a quote-reply and an edit do.
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
	saved = load_saved_here!(s)?
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
				Html.markup("/earlier\" data-quote=\""),
				Html.text(s.base),
				Html.markup("/quote\" data-edit=\""),
				Html.text(s.base),
				Html.markup("/edit\" data-save=\""),
				Html.text(s.base),
				Html.markup("/save\" data-saved=\""),
				Html.markup(Str.join_with(saved.map(|n| n.to_str()), " ")),
				Html.markup("\""),
			]),
			body: Html.join([
				Html.markup("<div class=chat-notify id=chat-notify></div>\n<div class=chat-layout>\n<div id=chat-feed class=chat-mp-main>\n<div class=chat-mp-nav><button id=earlier type=button"),
				if (span.first > 1) Html.join([]) else Html.markup(" hidden"),
				Html.markup(">Earlier messages</button></div>\n<div id=chat-history class=chat-mp-history tabindex=-1><div id=chat-bubbles>\n"),
				if (messages.is_empty()) Html.markup("<p id=chat-empty class=muted>No messages yet. Say hello 👋</p>\n") else Html.join([]),
				drawn(s, { messages, from_on: messages }),
				Html.markup("</div></div>\n</div>\n<div id=chat-right-sidebar class=chat-compose>\n"),
				compose_html(s.base),
				Html.markup("</div>\n</div>\n<script src=\"/keys.js\"></script>\n<script src=\"/feed.js\"></script>\n<script src=\"/compose.js\"></script>\n<script src=\"/quote.js\"></script>\n<script src=\"/save.js\"></script>\n<script src=\"/keyhelp.js\"></script>\n"),
			]),
		}),
	)
}

## **THE RIGHT PANE: COMPOSE**, as the old client built it
## (chat-client's js/chat_right_sidebar.js and js/chat_compose.js): closed
## to start, its "Open compose box" button showing; open, the form, the
## status line and the hint. The form posts to the page's `send`, by its
## script (js/compose.js), which keeps the 3 s watch on it.
compose_html : Str -> Html
compose_html = |base|
	Html.join([
		Html.markup("<div id=chat-compose-body class=chat-compose-body hidden><form id=chat-form data-send=\""),
		Html.text(base),
		Html.markup("/send\"><textarea id=chat-body placeholder=\"Write a message…  Markdown is supported, and longer posts are welcome.\"></textarea><div class=chat-compose-actions><button type=submit>Send</button></div></form><div id=chat-status class=chat-status></div><div class=chat-hint>Markdown supported · Ctrl/⌘-Enter to send</div></div>\n<div id=chat-closed-panel class=chat-closed-panel><button type=button id=chat-open-compose class=chat-open-compose>Open compose box</button></div>\n"),
	])

## **A SEND FROM THE COMPOSE BOX**: the body is the markdown, as a topic's
## post takes it, decided by the topic's own rules (Topics.post_by!), and
## the answer is the new message's bubble, a `201`: the page puts it in,
## and the stream's copy of it, by its id, is dropped. A refusal is the
## post's own, its text the page shows.
send! : {
	viewer : Access.Viewer(Topic.At),
	accounts : List(Principal),
	now : I64,
},
Shown,
List(U8) => Try(Chat.Answer, Chat.Answer)
send! = |
	v,
	s,
	bytes,
| {
	at = s.topic.at()
	m = Topics.post_by!(
		v,
		at,
		bytes,
	)?
	Ok(
		Html.respond(
			201,
			Bubble.of(
				s.accounts,
				{
					m,
					ref: Topics.local_ref(at, m.id),
					edited: NotEdited,
				},
			),
		),
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
	# Its messages' edits can come in any page after it.
	from_on =
		if messages.is_empty() {
			[]
		} else {
			Store.load_span!(
				files,
				tally,
				{ first: span.first, last: tally.messages },
			).map_err(|_| Chat.failed)?
		}
	Ok(
		Html.respond(
			200,
			Html.join([
				Html.markup("<div data-earlier="),
				Html.number(if (span.first > 1) 1 else 0),
				Html.markup(">\n"),
				drawn(s, { messages, from_on }),
				Html.markup("</div>\n"),
			]),
		),
	)
}

## **THE STREAM**: the bubbles after `Last-Event-ID` (a reconnect's), or
## else after `?after=` (the page's newest), at most the newest page of
## them, then each one posted, live, built once for every page
## (Topics.page_frame); a page further behind gets a `gap` first. Where it
## starts is a topic's stream's one rule (Topics.resume, Topics.resume_after!):
## a resume point that is no message's id is a 400.
stream! : Shown => Try(Chat.Answer, Chat.Answer)
stream! = |s| {
	at = s.topic.at()
	files = Store.topic_files(at)
	tally = Store.load_tally!(files).map_err(|_| Chat.failed)?
	after = Topics.resume_after!(HeaderOrQuery)?
	place = Topics.resume(tally.messages, after)
	first = place.first
	messages = Store.load_span!(
		files,
		tally,
		{ first, last: tally.messages },
	).map_err(|_| Chat.failed)?
	gap =
		match place.gap {
			Gap(before) => Topics.gap_frame(before)
			NoGap => []
		}
	# Each bubble as its post published it, then the original it edits.
	frames = backlog!(at, { messages, accounts: s.accounts })
	Ok(
		Chat.stream({
			key: Topics.page_key(at),
			backlog: gap.concat(frames),
			holder: Conversations.holder(s.viewer),
		}),
	)
}

## **A STREAM'S BACKLOG**: each message as its post published it (its
## bubble, then the original it edits, redrawn).
backlog! : Topic.At,
{
	messages : List(MessageCodec.Fields),
	accounts : List(Principal),
} => List(U8)
backlog! = |at, { messages, accounts }|
	match messages {
		[] => []
		[m, .. as rest] =>
			Topics.page_frame({
				at,
				accounts,
				m,
			})
				.concat(Topics.edit_frame!(at, { message: m, accounts }))
				.concat(backlog!(at, { messages: rest, accounts }))
	}

## **THE BUBBLES OF `messages`**, each superseded by its author's last
## edit among `from_on` (the messages from the first of them to the
## topic's newest), as the page draws it.
drawn : Shown, { messages : List(MessageCodec.Fields), from_on : List(MessageCodec.Fields) } -> Html
drawn = |s, { messages, from_on }| {
	at = s.topic.at()
	edits = Edits.superseded(at, from_on)
	Html.join(
		messages.map(
			|m| Bubble.of(
				s.accounts,
				{
					m,
					ref: Topics.local_ref(at, m.id),
					edited: Topics.edited_of(at, { edits, n: m.id }),
				},
			),
		),
	)
}

## **A QUOTE-REPLY FOR THE COMPOSE BOX** (Edits.quote): the message
## `?n=` names, quoted under its reference, "I said" when it is the
## viewer's own.
quote! : Shown => Try(Chat.Answer, Chat.Answer)
quote! = |s| {
	m = load_asked!(s)?
	text = Edits.quote({
		ref: Topics.ref_of(s.topic.at(), m.id),
		mine: m.by == s.me.id,
		markdown: m.body,
	})
	Ok(Wire.json(200, JsonOut.object([("text", JsonOut.text(text))])))
}

## **AN EDIT FOR THE COMPOSE BOX** (Edits.draft): the viewer's own message
## `?n=` names, under "Edit of" its reference, and where the cursor goes.
## Another's is a 403: only its author's edit supersedes a message.
edit! : Shown => Try(Chat.Answer, Chat.Answer)
edit! = |s| {
	m = load_asked!(s)?
	if m.by != s.me.id {
		Err(Wire.refused(403, "only its author edits a message"))
	} else {
		d = Edits.draft({ ref: Topics.ref_of(s.topic.at(), m.id), markdown: m.body })
		Ok(
			Wire.json(
				200,
				JsonOut.object([
					("text", JsonOut.text(d.text)),
					("caret", JsonOut.number(d.caret)),
				]),
			),
		)
	}
}

## **LOAD THE MESSAGE `?n=` NAMES**: a 400 for no number, a 404 for no message.
load_asked! : Shown => Try(MessageCodec.Fields, Chat.Answer)
load_asked! = |s| {
	n =
		match Host.read_query!(Str.to_utf8("n")) {
			[only] => Stored.count(only, "n").map_err(|_| bad_n)
			_ => Err(bad_n)
		}?
	load_message!(s, n)
}

## **LOAD MESSAGE `n` OF THE PAGE'S TOPIC**: a 404 for no message.
load_message! : Shown, U64 => Try(MessageCodec.Fields, Chat.Answer)
load_message! = |s, n| {
	files = Store.topic_files(s.topic.at())
	tally = Store.load_tally!(files).map_err(|_| Chat.failed)?
	if n == 0 or n > tally.messages {
		Err(Wire.refused(404, "no such message"))
	} else {
		match Store.load_span!(
			files,
			tally,
			{ first: n, last: n },
		) {
			Ok([m]) => Ok(m)
			_ => Err(Chat.failed)
		}
	}
}

bad_n : Chat.Answer
bad_n = Wire.refused(400, "n= is a message's id")

## **A SAVE FROM THE PAGE** (ReadingList.roc): the form's message (`n=`, one
## of this topic's) and its note (`note=`, ReadingList's rule), the
## message's copy as it is now put on the viewer's reading list; `201` and
## `{"ref":…,"list":"/chat/saved"}`, its reference and the list, for the
## page's strip. A note not of the rule a 400; a list past its most a 413.
save! : {
	viewer : Access.Viewer(Topic.At),
	accounts : List(Principal),
	now : I64,
},
Shown,
List(U8) => Try(Chat.Answer, Chat.Answer)
save! = |
	v,
	s,
	form,
| {
	n =
		match SignInWeb.form_field(form, "n") {
			Ok(digits) => Stored.count(digits, "n").map_err(|_| bad_n)
			Err(_) => Err(bad_n)
		}?
	raw =
		match SignInWeb.form_field(form, "note") {
			Ok(bytes) => Ok(bytes)
			Err(Missing) => Ok([])
			Err(Malformed) => Err(Wire.refused(400, "note= is not a form's value"))
		}?
	note = ReadingList.note_of(raw).map_err(SavedPage.note_refused)?
	m = load_message!(s, n)?
	human = human_of(s.me)?
	list = Store.load_saved!(human).map_err(|_| Chat.failed)?
	at = s.topic.at()
	next = ReadingList.saved(
		list,
		{
			id: 0,
			saved: v.now,
			place: at,
			n: m.id,
			by: m.by,
			at: m.at,
			note,
			body: m.body,
		},
	).map_err(
		|TooBig| Wire.refused(
			413,
			"your reading list is full (${ReadingList.most_bytes.to_str()} bytes): remove some saves first",
		),
	)?
	match Store.save_saved!(human, next) {
		Failed => Err(Chat.failed)
		Written => Ok(
			Wire.json(
				201,
				JsonOut.object([
					("ref", JsonOut.string(Topics.ref_of(at, m.id))),
					("list", JsonOut.string("/chat/saved")),
				]),
			),
		)
	}
}

## The viewer's human id: a page's viewer is signed in by a session, a
## human's.
human_of : Principal.Bound -> Try(Principal.HumanId, Chat.Answer)
human_of = |me|
	match me.id {
		Human(h) => Ok(h)
		_ => Err(Pages.key_refused)
	}

## **WHICH OF THIS TOPIC'S MESSAGES THE VIEWER SAVED**, by number, as the
## page's `data-saved` names them: "✓ saved" is the viewer's alone, and a
## bubble is every viewer's.
load_saved_here! : Shown => Try(List(U64), Chat.Answer)
load_saved_here! = |s| {
	human = human_of(s.me)?
	list = Store.load_saved!(human).map_err(|_| Chat.failed)?
	Ok(ReadingList.numbers_in(list, s.topic.at()))
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

## **A TOPIC'S PAGE, FOR A HUMAN IN A BROWSER**: a channel's or a DM's,
## one page for both, so no feature reaches one and misses the other. Its transcript is drawn here, its new
## messages drawn here too (PageFeed) and sent as fragments the page puts
## in as they are. The page's script (js/feed.js) is glue: it places a
## fragment, marks each bubble mine or theirs from the page's viewer,
## writes each time in the viewer's zone, and follows new messages only
## when the reader was caught up.
##
##     GET /chat/channel/<channel>/<topic>          the page: the newest page of
##                                                  messages, the transcript and
##                                                  the right pane (compose, keys)
##     GET /chat/dm/<pair>/<topic>                  a DM's (`<pair>` its humans' ids, `7_11`),
##                                                  the same for both, and the same below
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
##     POST .../upload                              an image from the compose box (a
##                                                  form, its one part `file`): its URL
##                                                  and name, as JSON (Uploads.roc)
##     POST .../react                               a reaction turned on or off (`msg=`,
##                                                  `emoji=`, `on=1|0`): `204`, and the
##                                                  message's chips to every page live
##     GET .../edit?n=<id>                          an edit of one's own message, for
##                                                  the compose box: `{"text":…,
##                                                  "caret":…}`; another's, a 403
##
## **WHO MAY** is the topics' own routes' (Topics.verdict!, Topic.read). A
## topic the viewer may not read is the 404 of one that is not there, for the page, its stream
## and its fragments alike; the page says why, in the old app's words,
## which name no channel the viewer is not in. **A PAGE IS A BROWSER'S**:
## signed out, the page sends the browser to `/login` (its stream and
## fragments, a 401); a key, a 403.
import pf.Chat
import pf.Host
import pf.Sse
import Access
import Account
import Bubble
import ChannelName
import Chrome
import Messages
import Credentials
import Edits
import Html
import JsonOut
import Transcript
import MessageRef
import PageFeed
import Pages
import Principal
import Reactions
import Render
import SignInWeb
import Store
import Stored
import Topic
import TopicName
import Topics
import Uploads
import Wire

TopicPage := [].{

	## **WHICH TOPIC A PATH NAMES**, a channel's or a DM's: its place, the
	## same for every reader.
	Place : Topic.At

	## What a path asks of it.
	Route : [
		Page(TopicPage.Place),
		Stream(TopicPage.Place),
		Earlier(TopicPage.Place),
		Send(TopicPage.Place),
		Quote(TopicPage.Place),
		React(TopicPage.Place),
		Upload(TopicPage.Place),
		Uploaded(
			{
				at : TopicPage.Place,
				name : Str,
				image : Uploads.Image,
			},
		),
		Edit(TopicPage.Place),
	]

	## The route a path names, if it names one: a topic's place is a kind
	## and two parts, then the tail.
	route : List(U8) -> Try(TopicPage.Route, [NotATopicPage])
	route = |path| {
		topic_place = |
			kind,
			a,
			b,
		|
			if kind == "channel".to_utf8() {
				Topics.at_in(a, b).map_err(|_| NotATopicPage)
			} else if kind == "dm".to_utf8() {
				Topics.dm_in(a, b).map_err(|_| NotATopicPage)
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
			] if chat == "chat".to_utf8() => topic_place(
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
			] if chat == "chat".to_utf8() => tail(
				topic_place(
					kind,
					a,
					b,
				)?,
				what,
			)
			[
				[],
				chat,
				kind,
				a,
				b,
				uploads,
				file,
			] if chat == "chat".to_utf8() and uploads == "uploads".to_utf8() => {
				at = topic_place(
					kind,
					a,
					b,
				)?
				image = Uploads.image_named(file).map_err(|_| NotATopicPage)?
				name = Str.from_utf8(file).map_err(|_| NotATopicPage)?
				Ok(
					Uploaded({
						at,
						name,
						image,
					}),
				)
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
				Page(_) | Earlier(_) | Quote(_) | Edit(_) | Uploaded(_) => if (req.method != Get and req.method != Head) Err(Chat.not_allowed(Get)) else Ok(NoBody)
				Send(_) =>
					if req.method != Post {
						Err(Chat.not_allowed(Post))
					} else {
						got = Host.read_body!(Messages.message_most)
						match got.status {
							Answered => Err(Chat.answered)
							Read => Ok(Body(got.bytes))
						}
					}
				Upload(_) =>
					if req.method != Post {
						Err(Chat.not_allowed(Post))
					} else {
						got = Host.read_body!(Uploads.body_most)
						match got.status {
							Answered => Err(Chat.answered)
							Read => Ok(Body(got.bytes))
						}
					}
				React(_) =>
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

## **A PLACE'S TAIL**: what the path asks after the place.
tail : TopicPage.Place, List(U8) -> Try(TopicPage.Route, [NotATopicPage])
tail = |p, what|
	if what == "stream".to_utf8() {
		Ok(Stream(p))
	} else if what == "earlier".to_utf8() {
		Ok(Earlier(p))
	} else if what == "send".to_utf8() {
		Ok(Send(p))
	} else if what == "quote".to_utf8() {
		Ok(Quote(p))
	} else if what == "edit".to_utf8() {
		Ok(Edit(p))
	} else if what == "react".to_utf8() {
		Ok(React(p))
	} else if what == "upload".to_utf8() {
		Ok(Upload(p))
	} else {
		Err(NotATopicPage)
	}

## **WHAT A REQUEST ON A PAGE DECIDES ON**: the viewer, signed in by their
## session (`me`, and the stream's holder); the transcript they read
## (`place`), its title and where it lives in a path; and the viewer a
## post from its compose box is decided for (`poster`).
Shown : {
	holder : List(U8),
	accounts : List(Principal),
	me : Principal.Bound,
	place : MessageRef.Where,
	title : Html,
	base : Str,
	readable : Topic.Readable,
	poster : {
		viewer : Access.Viewer,
		accounts : List(Principal),
		now : I64,
	},
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
	shown = topic_shown!({ path, route: r }, place_of(r))?
	match (r, body) {
		(Page(_), _) => page!(shown)
		(Stream(_), _) => stream!(shown)
		(Earlier(_), _) => earlier!(shown)
		(Quote(_), _) => quote!(shown)
		(Edit(_), _) => edit!(shown)
		(Send(_), Body(bytes)) => send!(shown, bytes)
		(React(_), Body(bytes)) => react!(shown, bytes)
		(Upload(_), Body(bytes)) => upload!(shown, bytes)
		(Uploaded(u), _) => serve_upload!(shown, { name: u.name, image: u.image })
		(Send(_), NoBody)
		| (React(_), NoBody)
		| (Upload(_), NoBody) => crash "TopicPage.serve!: answer! reads a POST's body first"
	}
}

## **WHAT WAS ASKED**: the path, and the route it names.
Asked : { path : List(U8), route : TopicPage.Route }

## The place a route asks of.
place_of : TopicPage.Route -> TopicPage.Place
place_of = |r|
	match r {
		Page(p) | Stream(p) | Earlier(p) | Send(p) | Quote(p) | Edit(p) | React(p) | Upload(p) => p
		Uploaded(u) => u.at
	}

## **THE VIEWER A PAGE IS FOR**: a session's; signed out, the page goes to
## `/login` and the rest are a 401; a key, a 403.
me_of : TopicPage.Route,
List(U8),
[
	SignedOut,
	Session(Principal.Bound),
	Key(Principal.Bound),
] -> Try(Principal.Bound, Chat.Answer)
me_of = |
	r,
	path,
	who,
|
	match who {
		SignedOut =>
			match r {
				Page(_) => Err(Pages.to_login(path))
				Stream(_) | Earlier(_) | Send(_) | Quote(_) | Edit(_) | React(_) | Upload(_) | Uploaded(_) => Err(
					Wire.refused(
						401,
						"not signed in",
					),
				)
			}
		Key(_) => Err(Pages.key_refused)
		Session(b) => Ok(b)
	}

## **A TOPIC'S PAGE, DECIDED**: the viewer over topics, and the topic's
## verdict (Topics.verdict!).
topic_shown! : Asked, TopicPage.Place => Try(Shown, Chat.Answer)
topic_shown! = |{ path, route: r }, place| {
	v = Topics.load_viewer!({})?
	me = me_of(
		r,
		path,
		v.viewer.who(),
	)?
	at = place
	found =
		match Topics.verdict!(v, at) {
			Ok(f) => Ok(f)
			Err(SignedOut) => Err(Wire.refused(401, "not signed in"))
			Err(Failed) => Err(Chat.failed)
			Err(NotYours) => Err(
				not_here(
					r,
					{
						why: Html.text(if (at.channel.is_dm()) "This DM is not yours." else "#${at.channel.to_str()} is not a channel you are a member of."),
						accounts: v.accounts,
						me,
					},
				),
			)
			Err(NoTopic) => Err(
				not_here(
					r,
					{
						why: Html.text("There is no topic “${at.topic.to_str()}” in this conversation."),
						accounts: v.accounts,
						me,
					},
				),
			)
		}?
	made = found.topic.at()
	Ok({
		readable: found.readable,
		holder: Messages.holder(v.viewer),
		accounts: v.accounts,
		me,
		place: InTopic(made),
		title: topic_title(
			made,
			{
				members: found.channel.members(v.accounts),
				accounts: v.accounts,
				me,
			},
		),
		base: Topics.page_path(made),
		poster: v,
	})
}

## **A PAGE THAT IS NOT THERE SAYS WHY**, as the old app's did
## (angry-gopher's chat.zig, `serveNotFoundPage`): a 404 page titled "Not
## here", its reason (`why`), and the way back. A channel that is not
## there and one the viewer is not in read alike, so it names nothing a
## viewer cannot see. Its stream and its fragments answer the plain 404.
not_here : TopicPage.Route,
{
	why : Html,
	accounts : List(Principal),
	me : Principal.Bound,
} -> Chat.Answer
not_here = |
	r,
	{
		why,
		accounts,
		me,
	},
|
	match r {
		Stream(_) | Earlier(_) | Send(_) | Quote(_) | Edit(_) | React(_) | Upload(_) | Uploaded(_) => no_such_topic
		Page(_) => {
			answer = Chrome.page({
				title: Html.markup("Not here"),
				viewer: Html.text(Render.name_of(accounts, me.id)),
				here: Elsewhere,
				kind: Plain,
				body_attrs: Html.join([]),
				body: Html.join([
					Html.markup("<p>"),
					why,
					Html.markup("</p><p><a href=\"/chat\">Go back</a></p>\n"),
				]),
			})
			{ ..answer, status: 404 }
		}
	}

## **A TOPIC PAGE'S TITLE**, the old app's: `#<channel>: <topic>` for a
## channel's topic, `Chat w/<name>: <topic>` for a DM's.
topic_title : Topic.At,
{
	members : List(Principal.Bound),
	accounts : List(Principal),
	me : Principal.Bound,
} -> Html
topic_title = |
	at,
	{
		members,
		accounts,
		me,
	},
|
	if at.channel.is_dm() {
		others = members.keep_if(|b| b.id != me.id)
		# A self-DM's other member is the viewer.
		name =
			match (if (others.is_empty()) members else others) {
				[b] => Render.name_of(accounts, b.id)
				_ => at.channel.to_str()
			}
		Html.text("Chat w/${name}: ${at.topic.to_str()}")
	} else {
		Html.text("#${at.channel.to_str()}: ${at.topic.to_str()}")
	}

## **THE PAGE**: the newest page of messages, each its bubble, in the feed
## column; the button for the page before; the right pane, compose. The
## body names its viewer (`data-me`), its stream, which starts after the
## newest message drawn here, where earlier pages come from, where a
## quote-reply and an edit do, and where a reaction goes; each bubble
## with its reactions' chips.
page! : Shown => Try(Chat.Answer, Chat.Answer)
page! = |s| {
	files = PageFeed.files(s.place)
	tally = Store.load_tally!(files).map_err(|_| Chat.failed)?
	span = Messages.page_of(tally.messages, Newest)
	messages = Store.load_span!(
		files,
		tally,
		span,
	).map_err(|_| Chat.failed)?
	newest = messages.last().map_ok(|m| m.id) ?? 0
	reactions = load_reactions!(s)?
	Ok(
		Chrome.page({
			title: s.title,
			viewer: Html.text(Render.name_of(s.accounts, s.me.id)),
			here: Elsewhere,
			kind: Chat,
			body_attrs: Html.join([
				Html.markup(" data-me=\""),
				Html.text(Account.id_text(s.me.id)),
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
				Html.markup("/edit\" data-react=\""),
				Html.text(s.base),
				Html.markup("/react\""),
			]),
			body: Html.join([
				Html.markup("<div class=chat-notify id=chat-notify></div>\n<div class=chat-layout>\n<div id=chat-feed class=chat-mp-main>\n<div class=chat-mp-nav><button id=earlier type=button"),
				if (span.first > 1) Html.join([]) else Html.markup(" hidden"),
				Html.markup(">Earlier messages</button></div>\n<div id=chat-history class=chat-mp-history tabindex=-1><div id=chat-bubbles>\n"),
				if (messages.is_empty()) Html.markup("<p id=chat-empty class=muted>No messages yet. Say hello 👋</p>\n") else Html.join([]),
				drawn(
					s,
					{
						messages,
						from_on: messages,
						reactions,
					},
				),
				Html.markup("</div></div>\n</div>\n<div id=chat-right-sidebar class=chat-compose>\n"),
				compose_html(s.base),
				Html.markup("</div>\n</div>\n<script src=\"/keys.js\"></script>\n<script src=\"/feed.js\"></script>\n<script src=\"/emoji.js\"></script>\n<script src=\"/compose.js\"></script>\n<script src=\"/upload.js\"></script>\n<script src=\"/quote.js\"></script>\n<script src=\"/reactions.js\"></script>\n<script src=\"/keyhelp.js\"></script>\n"),
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
		Html.markup("/send\" data-upload=\""),
		Html.text(base),
		Html.markup("/upload\" data-image-most="),
		Html.number(Uploads.image_most),
		Html.markup("><textarea id=chat-body placeholder=\"Write a message…  Markdown is supported, and longer posts are welcome.\"></textarea><div class=chat-compose-actions><button type=submit>Send</button><button type=button id=chat-upload-btn>Upload</button></div></form><input type=file id=chat-file accept=\"image/png,image/jpeg,image/gif,image/webp\" hidden><div id=chat-status class=chat-status></div><div class=chat-hint>Markdown supported · :emoji: autocompletes · attach an image · Ctrl/⌘-Enter to send</div></div>\n<div id=chat-closed-panel class=chat-closed-panel><button type=button id=chat-open-compose class=chat-open-compose>Open compose box</button></div>\n"),
	])

## **A SEND FROM THE COMPOSE BOX**: the body is the markdown, as the
## topic's own post takes it, decided by its own rules (Topics.post_by!),
## and the answer is the new message's bubble, a
## `201`: the page puts it in, and the stream's copy of it, by its id, is
## dropped. A refusal is the post's own, its text the page shows.
send! : Shown, List(U8) => Try(Chat.Answer, Chat.Answer)
send! = |s, bytes| {
	m =
		match s.place {
			InTopic(at) =>
				Topics.post_by!(
					s.poster,
					at,
					bytes,
				)?
		}
	Ok(
		Html.respond(
			201,
			Bubble.of(
				s.accounts,
				{
					m,
					ref: MessageRef.local(s.place, m.id),
					edited: NotEdited,
					# New: no reaction yet.
					reactions: [],
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
			[only] =>
				match Stored.count(only, "before") {
					Ok(n) if n > 0 => Ok(n)
					_ => Err(bad_before)
				}
			_ => Err(bad_before)
		}?
	files = PageFeed.files(s.place)
	tally = Store.load_tally!(files).map_err(|_| Chat.failed)?
	span = Messages.page_of(tally.messages, Before(before))
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
				drawn(
					s,
					{
						messages,
						from_on,
						reactions: load_reactions!(s)?,
					},
				),
				Html.markup("</div>\n"),
			]),
		),
	)
}

## **THE STREAM**: the bubbles after `Last-Event-ID` (a reconnect's), or
## else after `?after=` (the page's newest), at most the newest page of
## them, then each one posted, live, built once for every page
## (PageFeed.frame); a page further behind gets a `gap` first. Where it
## starts is a topic's stream's one rule (Topics.resume, Topics.resume_after!):
## a resume point that is no message's id is a 400.
stream! : Shown => Try(Chat.Answer, Chat.Answer)
stream! = |s| {
	files = PageFeed.files(s.place)
	tally = Store.load_tally!(files).map_err(|_| Chat.failed)?
	after = Topics.resume_after!(HeaderOrQuery)?
	start = Topics.resume(tally.messages, after)
	messages = Store.load_span!(
		files,
		tally,
		{ first: start.first, last: tally.messages },
	).map_err(|_| Chat.failed)?
	gap =
		match start.gap {
			Gap(before) => Topics.gap_frame(before)
			NoGap => []
		}
	# Each bubble as its post published it, then the original it edits.
	frames = backlog!(s.place, { messages, accounts: s.accounts })
	Ok(
		Chat.stream({
			key: PageFeed.page_key(s.place),
			backlog: gap.concat(frames),
			holder: s.holder,
		}),
	)
}

## **A STREAM'S BACKLOG**: each message as its post published it (its
## bubble, then the original it edits, redrawn).
backlog! : MessageRef.Where,
{
	messages : List(Transcript.Fields),
	accounts : List(Principal),
} => List(U8)
backlog! = |place, { messages, accounts }|
	match messages {
		[] => []
		[m, .. as rest] =>
			PageFeed.frame(place, { accounts, m })
				.concat(PageFeed.edit_frame!(place, { message: m, accounts }))
				.concat(backlog!(place, { messages: rest, accounts }))
	}

## **THE BUBBLES OF `messages`**, each superseded by its author's last
## edit among `from_on` (the messages from the first of them to the
## newest), and its chips (`reactions`, the topic's events).
drawn : Shown,
{
	messages : List(Transcript.Fields),
	from_on : List(Transcript.Fields),
	reactions : List(Reactions.Event),
} -> Html
drawn = |
	s,
	{
		messages,
		from_on,
		reactions,
	},
| {
	edits = Edits.superseded(s.place, from_on)
	Html.join(
		messages.map(
			|m| Bubble.of(
				s.accounts,
				{
					m,
					ref: MessageRef.local(s.place, m.id),
					edited: PageFeed.edited_of(s.place, { edits, n: m.id }),
					reactions: Reactions.chips_of(reactions, m.id),
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
		ref: MessageRef.spelled(s.place, m.id),
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
		d = Edits.draft({ ref: MessageRef.spelled(s.place, m.id), markdown: m.body })
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
load_asked! : Shown => Try(Transcript.Fields, Chat.Answer)
load_asked! = |s| {
	n =
		match Host.read_query!(Str.to_utf8("n")) {
			[only] => Stored.count(only, "n").map_err(|_| bad_n)
			_ => Err(bad_n)
		}?
	load_message!(s, n)
}

## **LOAD MESSAGE `n` OF THE PAGE'S TRANSCRIPT**: a 404 for no message.
load_message! : Shown, U64 => Try(Transcript.Fields, Chat.Answer)
load_message! = |s, n| {
	files = PageFeed.files(s.place)
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

## The viewer's human id: a page's viewer is signed in by a session, a
## human's.
human_of : Principal.Bound -> Try(Principal.HumanId, Chat.Answer)
human_of = |me|
	match me.id {
		Human(h) => Ok(h)
		_ => Err(Pages.key_refused)
	}

## **THE TOPIC'S REACTIONS**, every event, for the chips a page draws. A
## file that will not read fails the page, as its transcript would: its
## chips are part of each bubble.
load_reactions! : Shown => Try(List(Reactions.Event), Chat.Answer)
load_reactions! = |s|
	match s.place {
		InTopic(at) => Store.load_reactions!(at).map_ok(|r| r.events).map_err(|_| Chat.failed)
	}

## **A REACTION** (the old `handleReact`): the form's message (`msg=`, one
## of this topic's), its emoji (`emoji=`, one glyph's shape) and `on=` (`1`,
## or left out, on; anything else off, as the old one read it), appended to
## the topic's reactions with the reactor's name; a `204`, and the
## message's strip, drawn again from the whole fold for every page,
## published live as a `reaction` event the page puts in place of the old
## one. A bad field, or no such message, a 400 in the old words. Who may
## react is the page's rule (a reader).
react! : Shown, List(U8) => Try(Chat.Answer, Chat.Answer)
react! = |s, form| {
	at =
		match s.place {
			InTopic(a) => a
		}
	n =
		match SignInWeb.form_field(form, "msg") {
			Ok(digits) => Stored.count(digits, "msg").map_err(|_| react_refused("msg must be a message number"))
			Err(_) => Err(react_refused("msg must be a message number"))
		}?
	emoji =
		match SignInWeb.form_field(form, "emoji") {
			Ok(bytes) => Str.from_utf8(bytes).map_err(|_| react_refused("emoji must be one glyph"))
			Err(_) => Err(react_refused("emoji must be one glyph"))
		}?
	on =
		match SignInWeb.form_field(form, "on") {
			Ok(value) => value == "1".to_utf8()
			Err(_) => Bool.True
		}
	tally = Store.load_tally!(PageFeed.files(s.place)).map_err(|_| Chat.failed)?
	if !Reactions.is_emoji(emoji) {
		Err(react_refused("emoji must be one glyph"))
	} else if n == 0 or n > tally.messages {
		Err(react_refused("no such message"))
	} else {
		stored = Store.load_reactions!(at).map_err(|_| Chat.failed)?
		event = {
			n,
			by: s.me.id,
			from: Render.name_of(s.accounts, s.me.id),
			emoji,
			on,
			at: s.poster.now,
		}
		match Store.append_reaction!(at, { cut: stored.cut, event }) {
			Failed => Err(Chat.failed)
			Appended => {
				html = Reactions.strip({ n, chips: Reactions.chips_of(stored.events.append(event), n) })
				match Sse.frame({
					name: Str.to_utf8("reaction"),
					data: html.bytes(),
					id: [],
				}) {
					Ok(frame) => Host.publish!(PageFeed.page_key(s.place), frame)
					Err(LineBreak) => crash "TopicPage.react!: a strip holds no line break"
				}
				Ok(Chat.respond(204, { content_type: [], body: [] }))
			}
		}
	}
}

## **AN IMAGE FROM THE COMPOSE BOX** (the old `handleUpload`): the form's
## file (Uploads.file_of), an image by its bytes (Uploads.sniff), at most
## 10 MiB, within its uploader's allowance; kept in the topic's folder by
## a fresh name, then counted against the allowance; its URL and its
## browser's name answered, as JSON. **WRITTEN, THEN COUNTED**: a write
## that fails fails the request (Host's `Failed`), so the old "give the
## bytes back" could never run: an image that could not be kept is never
## counted, and a count that could not be written leaves one kept image
## uncounted. Refusals in the old words: no file a 400, not an image a
## 415, too big a 413, past the allowance a 403. Who may is the page's
## rule (a reader, by a session: a human).
upload! : Shown, List(U8) => Try(Chat.Answer, Chat.Answer)
upload! = |s, body| {
	human = human_of(s.me)?
	no_file = Wire.refused(400, "no file")
	boundary =
		match Host.read_header!(Str.to_utf8("content-type")) {
			[header] => Uploads.boundary_of(header).map_err(|_| no_file)
			_ => Err(no_file)
		}?
	file = Uploads.file_of(body, boundary).map_err(|_| no_file)?
	image = Uploads.sniff(file.uploaded).map_err(|_| Wire.refused(415, "unsupported file type (images: png, jpeg, gif, webp)"))?
	size = file.uploaded.len()
	uploaded = Store.load_uploaded!(human).map_err(|_| Chat.failed)?
	if size > Uploads.image_most {
		Err(Wire.refused(413, "image too large — the limit is 10 MB."))
	} else if uploaded + size > Uploads.allowance {
		Err(Wire.refused(403, "Upload limit reached — you've used your 1 GB upload allowance."))
	} else {
		name = Uploads.name_of(Host.random_bytes!(16), image)
		match Store.save_upload!(s.readable, { name, uploaded: file.uploaded }) {
			Failed => Err(Chat.failed)
			Written =>
				match Store.save_uploaded!(human, uploaded + size) {
					Failed => Err(Chat.failed)
					Written => Ok(Wire.json(200, Uploads.answer({ url: Uploads.url(s.base, name), name: Uploads.display_name(file.filename) })))
				}
		}
	}
}

## **AN UPLOADED IMAGE, SERVED** (the old `serveUpload`), under its topic's
## page: to whoever reads the topic (the page's verdict, whose proof the
## store asks for), its type by its name's extension, the browser never
## guessing another (`nosniff`), kept by the browser for good (the old
## `private, max-age=31536000, immutable`: a name is never given twice).
## A name no upload has, the one 404 a stranger gets too.
serve_upload! : Shown, { name : Str, image : Uploads.Image } => Try(Chat.Answer, Chat.Answer)
serve_upload! = |s, { name, image }| {
	read = Store.load_upload!(s.readable, name)
	match read.status {
		Missing => Err(no_such_topic)
		Failed => Err(Chat.failed)
		Found => Ok(
			Chat.with_header(
				{ ..Chat.respond(200, { content_type: Uploads.content_type(image), body: read.bytes }), sniff: Forbid },
				"cache-control",
				"private, max-age=31536000, immutable".to_utf8(),
			),
		)
	}
}

## A reaction refused, a 400, in the old words.
react_refused : Str -> Chat.Answer
react_refused = |why| Wire.refused(400, "react: ${why}")

bad_before : Chat.Answer
bad_before = Wire.refused(400, "before= is a message's id")

no_such_topic : Chat.Answer
no_such_topic = Wire.refused(404, "no such topic")

# ── tests
expect
	match TopicPage.route("/chat/channel/Lobby/ChitChat".to_utf8()) {
		Ok(Page(at)) => at.channel.to_str() == "Lobby" and at.topic.to_str() == "ChitChat"
		_ => Bool.False
	}
expect
	match TopicPage.route("/chat/dm/7_11/ChitChat/stream".to_utf8()) {
		Ok(Stream(at)) => at.channel == ChannelName.dm_of(11, 7) and at.channel.to_str() == "7_11"
		_ => Bool.False
	}
expect
	match TopicPage.route("/chat/channel/Lobby/ChitChat/earlier".to_utf8()) {
		Ok(Earlier(_)) => Bool.True
		_ => Bool.False
	}
# Saves are gone: `save` is no tail.
expect TopicPage.route("/chat/channel/Lobby/ChitChat/save".to_utf8()).is_err()
expect
	match TopicPage.route("/chat/dm/5_5/ChitChat/react".to_utf8()) {
		Ok(React(at)) => at.channel == ChannelName.dm_of(5, 5)
		_ => Bool.False
	}
# A DM's name is no channel's; nor a bad name, an unknown kind or part.
expect TopicPage.route("/chat/channel/1_2/ChitChat".to_utf8()).is_err()
# A pair in its one spelling alone: 11_7 is not 7_11's page, nor a page at all.
expect TopicPage.route("/chat/dm/11_7/ChitChat".to_utf8()).is_err() and TopicPage.route("/chat/dm/7/ChitChat".to_utf8()).is_err()
expect TopicPage.route("/chat/dm/Lobby/ChitChat".to_utf8()).is_err()
expect TopicPage.route("/chat/channel/Lobby/chit_chat".to_utf8()).is_err()
expect TopicPage.route("/chat/dm/07/ChitChat".to_utf8()).is_err()
expect TopicPage.route("/chat/dm/human:7/ChitChat".to_utf8()).is_err()
expect TopicPage.route("/chat/room/Lobby/ChitChat".to_utf8()).is_err()
expect TopicPage.route("/chat/channel/Lobby/ChitChat/other".to_utf8()).is_err()
expect TopicPage.route("/chat/channel/Lobby".to_utf8()).is_err()
expect TopicPage.route("/chat/channel/Lobby/ChitChat/stream/x".to_utf8()).is_err()
# A path of one part after `/chat` names no topic page: the conversation
# pages, `/chat/<id>`, are no more.
expect TopicPage.route("/chat/7".to_utf8()).is_err()
expect TopicPage.route("/chat/7/stream".to_utf8()).is_err()
expect TopicPage.route("/chat/agents".to_utf8()).is_err()
expect TopicPage.route("/chat".to_utf8()).is_err()

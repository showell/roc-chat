## **THE CHAT'S CONVERSATIONS ON THE WIRE**: start one, post to it, read it,
## stream it. Every decision is the core's: who may see and who may post is
## ConvAccess's, on the viewer from the request's session or API key
## (Credentials.load_viewer!), never on anything the request claims; how a message reads is
## roc-markdown's, with its work budget. Here are the facts asked of the
## host, the records kept (Store), and the answers made.
##
## The routes (app/main.roc's table names them):
##
##     GET  /conversations                  the viewer's own, JSON: each one's id and who
##                                          is in it (`load_mine!`)
##     POST /conversations                  start one: a form, `with=` the others' ids,
##                                          comma-separated (`human:2,agent:7`)
##     GET  /conversations/<id>             its transcript, JSON
##     POST /conversations/<id>/messages    post: the body is the markdown, as is
##     GET  /conversations/<id>/stream      its messages, live (SSE), after
##                                          `Last-Event-ID` when the browser resumes
##
## A message, in the transcript and on the stream alike, is one JSON object:
## `{"id":3,"at":1761600000,"by":"agent:7","kind":"agent","owner":"human:2","markdown":"…","mentions":["human:2"],"html":"…"}`,
## `kind` the poster's (`human`, `agent` or `bot`), `owner` the human an
## agent or a bot answers to (none for a human), `mentions` the participants
## it names (Mentions.of), by their names now. On
## the stream it is the data of an event named `message` whose id is the
## message's. Signed out is a 401; a conversation the viewer may not see is
## a 404, as one that is not there; one it sees but may not post to, a 403.
import pf.Chat
import pf.Host
import pf.Sse
import md.Md
import Access
import AccountCodec
import Bytes
import Cast
import ConvAccess
import ConvKey
import Credentials
import JsonOut
import Limits
import Mentions
import MessageCodec
import Principal
import SignInWeb
import Store
import Stored
import Wire

Conversations := [].{

	## What a path under `/conversations` asks.
	Route : [
		Start,
		Read(ConvAccess.ConvId),
		Post(ConvAccess.ConvId),
		Stream(ConvAccess.ConvId),
	]

	## A conversation's id, from its path's digits (one, no leading zero):
	## the one parse the conversations' routes and the pages share.
	id_of : List(U8) -> Try(ConvAccess.ConvId, [NotAConversation])
	id_of = |digits|
		match Stored.count(digits, "id") {
			Err(_) => Err(NotAConversation)
			Ok(n) => ConvAccess.ConvId.from_u64(n).map_err(|_| NotAConversation)
		}

	## A conversation the viewer may not see, or that is not there: one 404
	## for both, the routes' and the pages'.
	no_such : Chat.Answer
	no_such = Wire.refused(404, "no such conversation")

	## The route a path names, if it names one.
	route : List(U8) -> Try(Conversations.Route, [NotAConversation])
	route = |path|
		if path == root {
			Ok(Start)
		} else {
			match Bytes.strip_prefix(path, List.append(root, '/')) {
				Err(NoMatch) => Err(NotAConversation)
				Ok(rest) =>
					match List.split_on(rest, '/') {
						[id_part] => Conversations.id_of(id_part).map_ok(|id| Read(id))
						[
							id_part,
							act,
						] if act == Str.to_utf8("messages") => Conversations.id_of(id_part).map_ok(|id| Post(id))
						[
							id_part,
							act,
						] if act == Str.to_utf8("stream") => Conversations.id_of(id_part).map_ok(|id| Stream(id))
						_ => Err(NotAConversation)
					}
			}
		}

	## **THE VIEWER'S OWN CONVERSATIONS**, oldest first: each one ConvAccess
	## lets them post in (a participant, or the human its agent or bot
	## answers to). A public conversation they may only read is not theirs.
	## Read from the index of the human the viewer answers to
	## (Store.load_conversations_of!), never every conversation.
	load_mine! : Access.Viewer(ConvAccess.ConvId),
	List(Principal) => Try(
		List(ConvAccess.Conv),
		[Failed],
	)
	load_mine! = |viewer, accounts|
		match viewer.who() {
			SignedOut => Ok([])
			Session(b) | Key(b) =>
				match Principal.find(accounts, b.id) {
					Err(_) => Ok([])
					Ok(p) => {
						theirs = Store.load_conversations_of!(Principal.answers_to(p), accounts)?
						Ok(
							List.keep_if(
								theirs,
								|conv| ConvAccess.can_post(viewer, { conv, accounts }),
							),
						)
					}
				}
		}

	## A message's HTML: roc-markdown's render of its markdown, the one
	## the transcript, the stream and the pages all give.
	html_of : MessageCodec.Fields -> List(U8)
	html_of = |m| Md.render(m.body, Conversations.markdown)

	## **WHAT THE CHAT TELLS THE RENDERER**: its uploads are the paths under
	## `/user_uploads/`, the only places a member's image or video may load
	## from; none of the chat's own routes is one. The chat serves no
	## uploads yet: this is the folder they will be served from.
	markdown : Md.Options
	markdown = { uploads: Md.uploads_under(Str.to_utf8("/user_uploads/")) }

	## The name a principal goes by, as the accounts say now; its id where
	## no account holds it.
	name_of : List(Principal), Principal.Id -> Str
	name_of = |accounts, id|
		match Principal.find(accounts, id) {
			Ok(Human(h)) => h.name
			Ok(Agent(a)) => a.name
			Ok(Bot(b)) => b.name
			Err(_) => AccountCodec.id_text(id)
		}

	## **A PAGE OF A CONVERSATION'S MESSAGES**: the newest
	## `Limits.page_messages` before `before` (or of all, for `Newest`),
	## oldest first, read from the first one's offset (Store.load_span!),
	## and whether messages come before it.
	load_page! : ConvAccess.ConvId,
	[Newest, Before(U64)] => Try(
		{ messages : List(MessageCodec.Fields), earlier : Bool },
		[Failed],
	)
	load_page! = |id, before| {
		tally = Store.load_tally!(id)?
		span = Conversations.page_of(tally.messages, before)
		messages = Store.load_span!(
			id,
			tally,
			span,
		)?
		Ok({ messages, earlier: span.first > 1 })
	}

	## **WHICH MESSAGES A PAGE HOLDS**, of a transcript of `count`: ids
	## `first` to `last`, at most Limits.page_messages of them, ending
	## before `before` (or at the newest). None (`first` past `last`) for
	## an empty transcript, or before the first message.
	page_of : U64, [Newest, Before(U64)] -> { first : U64, last : U64 }
	page_of = |count, before| {
		last =
			match before {
				Newest => count
				Before(b) => if (b - 1 < count) b - 1 else count
			}
		first = if (last > Limits.page_messages) last - Limits.page_messages + 1 else 1
		{ first, last }
	}

	## **ANSWER A ROUTE**, each to the method it takes.
	answer! : Chat.Request, Conversations.Route => Chat.Answer
	answer! = |req, r|
		match r {
			Start =>
				if req.method == Post {
					start!({})
				} else if req.method == Get {
					list!({})
				} else {
					Chat.not_allowed(Post)
				}
			Read(id) => if (req.method == Get) read!(id) else Chat.not_allowed(Get)
			Post(id) => if (req.method == Post) post!(id) else Chat.not_allowed(Post)
			Stream(id) => if (req.method == Get) stream!(id) else Chat.not_allowed(Get)
		}
}

## The most a message's markdown may be, and a start's form.
post_most : U64
post_most = 32 * 1024

root : List(U8)
root = Str.to_utf8("/conversations")

## A conversation's id as a path spells it: digits, one spelling, not 0.
## **START A CONVERSATION**: the viewer, and each id the form's `with`
## names, bound to their accounts now (ConvAccess.Conv.start, the owner rule first); stored, and
## its id answered. A session starts one; a key starts one only where it
## could post to it then (ConvAccess.can_post: its post reaching it, and its
## principal in it), and is audited when not. Nobody signed in cannot.
start! : {} => Chat.Answer
start! = |{}| {
	got = Host.read_body!(Wire.form_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match Credentials.load_viewer!(Start) {
				Err(answer) => answer
				Ok(
					{
						viewer,
						accounts,
						now,
						key,
					},
				) =>
					match viewer.who() {
						SignedOut => not_signed_in
						Session(me) | Key(me) =>
							match others_of(got.bytes) {
								Err(Malformed) => Wire.refused(
									400,
									"`with` names the others, as `human:2,agent:7`",
								)
								Ok(others) =>
									match check_start_room!(me.id, accounts) {
										Err(Failed) => Chat.failed
										Ok(Full) => Wire.refused(
											403,
											"you have started as many conversations as one person may (${Limits.load_cap!(ConversationsPerHuman).to_str()})",
										)
										Ok(Room) =>
											match Store.load_next_conversation_id!({}) {
												Err(Failed) => Chat.failed
												Ok(id) =>
													match ConvAccess.Conv.start({
														id,
														starter: me.id,
														others,
														accounts,
													}) {
														Err(NoParticipants) => Wire.refused(
															400,
															"a conversation has someone in it",
														)
														# One refusal for an id no account holds and an
														# agent the starter does not own: neither says
														# which accounts exist.
														Err(NoSuchParticipant(_)) | Err(NotTheOwner(_)) => Wire.refused(
															400,
															"`with` names someone you may not start a conversation with",
														)
														Ok(conv) =>
															if !ConvAccess.can_post(
																viewer,
																{ conv, accounts },
															) {
																audit_out_of_scope!({
																	key,
																	use: Start,
																	action: Post(conv),
																	accounts,
																	now,
																})
																Wire.refused(
																	403,
																	"this key may not post to a new conversation",
																)
															} else {
																match Store.save_new_conversation!({
																	conv,
																	created: now,
																	accounts,
																}) {
																	Failed => Chat.failed
																	Written => Wire.json(
																		201,
																		JsonOut.object([
																			(
																				"id",
																				JsonOut.number(id.to_u64()),
																			),
																		]),
																	)
																}
															}
													}
											}
									}
							}
					}
			}
	}
}

## **WHETHER THE STARTER'S HUMAN MAY START ANOTHER** (Limits'
## conversations_per_human, counted from their `started-by` index); one the
## accounts do not hold is refused later, by ConvAccess.Conv.start.
check_start_room! : Principal.Id, List(Principal) => Try([Room, Full], [Failed])
check_start_room! = |starter, accounts|
	match Principal.find(accounts, starter) {
		Err(_) => Ok(Room)
		Ok(p) => {
			started = Store.load_started_count!(Principal.answers_to(p), accounts)?
			Ok(if (started >= Limits.load_cap!(ConversationsPerHuman)) Full else Room)
		}
	}

## **THE VIEWER'S OWN, AS JSON**: each one's id, and who is in it, each
## by id and name.
list! : {} => Chat.Answer
list! = |{}|
	match Credentials.load_viewer!(ListConversations) {
		Err(answer) => answer
		Ok(
			{
				viewer,
				accounts,
				now: _,
				key: _,
			},
		) =>
			match viewer.who() {
				SignedOut => not_signed_in
				Session(_) | Key(_) =>
					match Conversations.load_mine!(viewer, accounts) {
						Err(Failed) => Chat.failed
						Ok(convs) => {
							person = |b|
								JsonOut.object([
									("id", JsonOut.string(AccountCodec.id_text(b.id))),
									("name", JsonOut.string(Conversations.name_of(accounts, b.id))),
								])
							one = |conv|
								JsonOut.object([
									("id", JsonOut.number(conv.id().to_u64())),
									("with", JsonOut.array(conv.participants().map(person))),
								])
							Wire.json(
								200,
								JsonOut.object([("conversations", JsonOut.array(convs.map(one)))]),
							)
						}
					}
			}
	}

## **A KEY USED OUTSIDE WHAT IT MAY DO, AUDITED**: the core's own refusal
## (ConvKey.decide) for the action it was refused. A session's refusal is
## no key's, and is not audited.
audit_out_of_scope! : {
	key : [NoKey, Key(ConvKey.Key)],
	use : Credentials.Use,
	action : [Read(ConvAccess.Conv), Post(ConvAccess.Conv)],
	accounts : List(Principal),
	now : I64,
} => {}
audit_out_of_scope! = |
	{
		key,
		use,
		action,
		accounts,
		now,
	},
|
	match key {
		NoKey => {}
		Key(k) =>
			match ConvKey.decide(
				k,
				{
					accounts,
					action,
					now,
				},
			) {
				Refused(refusal) => Credentials.audit_use!(
					k,
					{
						use,
						refusal,
						now,
					},
				)
				Permitted => {}
			}
	}

## The ids the start form's `with` names; none when it names none.
others_of : List(U8) -> Try(List(Principal.Id), [Malformed])
others_of = |form|
	match SignInWeb.form_field(form, "with") {
		Err(Missing) => Ok([])
		Err(Malformed) => Err(Malformed)
		Ok([]) => Ok([])
		Ok(value) => List.map_try(
			List.split_on(value, ','),
			|text| AccountCodec.id_from(text, "with"),
		).map_err(|_| Malformed)
	}

## **WHAT A REQUEST ON A CONVERSATION DECIDES ON**: Credentials.Asked (the
## viewer from its session or key, the accounts now, the time, and the key
## when a key asks) with the conversation the path names; or the answer
## that ends it (signed out, a key refused, not there, a failure).
AskedOn : {
	viewer : Access.Viewer(ConvAccess.ConvId),
	accounts : List(Principal),
	now : I64,
	conv : ConvAccess.Conv,
	key : [NoKey, Key(ConvKey.Key)],
}

load_asked! : ConvAccess.ConvId, Credentials.Use => Try(AskedOn, Chat.Answer)
load_asked! = |id, use| {
	{
		viewer,
		accounts,
		now,
		key,
	} = Credentials.load_viewer!(use)?
	match viewer.who() {
		SignedOut => Err(not_signed_in)
		Session(_) | Key(_) =>
			match Store.load_conversation!(id) {
				Err(Failed) => Err(Chat.failed)
				Err(Missing) => Err(Conversations.no_such)
				Ok(conv) => Ok({
					viewer,
					accounts,
					now,
					conv,
					key,
				})
			}
	}
}

## The same, for a viewer who may see it (ConvAccess.can_see); one who may
## not is answered as if it were not there, and a key's refusal audited.
load_seen! : ConvAccess.ConvId => Try(AskedOn, Chat.Answer)
load_seen! = |id| {
	a = load_asked!(id, Read(id))?
	if ConvAccess.can_see(a.viewer, { conv: a.conv, accounts: a.accounts }) {
		Ok(a)
	} else {
		audit_out_of_scope!({
			key: a.key,
			use: Read(id),
			action: Read(a.conv),
			accounts: a.accounts,
			now: a.now,
		})
		Err(Conversations.no_such)
	}
}

## **READ: A PAGE OF THE TRANSCRIPT** (Conversations.load_page!), each
## message as the wire spells it, and `earlier`: whether messages come
## before the page's first, which `?before=` that first's id pages back
## to. A `before` that is no message's id, or given twice, is a 400.
read! : ConvAccess.ConvId => Chat.Answer
read! = |id|
	match load_seen!(id) {
		Err(answer) => answer
		Ok(a) =>
			match before_of(Host.read_query!(Str.to_utf8("before"))) {
				Err(Malformed) => Wire.refused(400, "before= is a message's id")
				Ok(before) =>
					match Conversations.load_page!(id, before) {
						Err(Failed) => Chat.failed
						Ok({ messages, earlier }) =>
							Wire.json(
								200,
								JsonOut.object([
									("id", JsonOut.number(id.to_u64())),
									(
										"messages",
										JsonOut.array(
											messages.map(
												|m| message_json(
													m,
													{
														named: named_of(a.conv, a.accounts),
														accounts: a.accounts,
													},
												),
											),
										),
									),
									("earlier", JsonOut.bool(earlier)),
								]),
							)
					}
			}
	}

## Where a page ends: before the message `?before=` names, or after the
## newest when none is named.
before_of : List(List(U8)) -> Try([Newest, Before(U64)], [Malformed])
before_of = |values|
	match values {
		[] => Ok(Newest)
		[only] =>
			match Stored.count(only, "before") {
				Ok(n) if n > 0 => Ok(Before(n))
				_ => Err(Malformed)
			}
		_ => Err(Malformed)
	}

## **POST**: the body is the markdown. Refused when the viewer may not post
## (ConvAccess.can_post, asked first and alone: a 403 to one who may see it,
## a 404 to one who may not), when it is not UTF-8 text, or when it is
## hostile (roc-markdown's budget), when the poster is an agent or a bot
## and agents have answered agents too often since a human spoke
## (check_hops!, a 429), or when the transcript is full (append_post!, a
## 413). Then appended and published (append_post!), its id from its
## tally (Store.load_tally!, never a read of the transcript).
post! : ConvAccess.ConvId => Chat.Answer
post! = |id| {
	got = Host.read_body!(post_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match load_asked!(id, Post(id)) {
				Err(answer) => answer
				Ok(
					{
						viewer,
						accounts,
						now,
						conv,
						key,
					},
				) =>
					if !ConvAccess.can_post(viewer, { conv, accounts }) {
						audit_out_of_scope!({
							key,
							use: Post(id),
							action: Post(conv),
							accounts,
							now,
						})
						if (ConvAccess.can_see(viewer, { conv, accounts })) Wire.refused(
							403,
							"only its participants post here",
						) else Conversations.no_such
					} else if Str.from_utf8(got.bytes).is_err() {
						Wire.refused(400, "a message is UTF-8 text")
					} else if Md.hostility(got.bytes, Conversations.markdown) == TooMuchFormatting {
						Wire.refused(400, Md.too_much_formatting)
					} else {
						by =
							match viewer.who() {
								SignedOut => crash "Conversations.post!: `load_asked!` let nobody signed out through"
								Session(b) | Key(b) => b.id
							}
						match Store.load_tally!(id) {
							Err(Failed) => Chat.failed
							Ok(tally) => {
								named = named_of(conv, accounts)
								match check_hops!({
									id,
									tally,
									by,
									named,
								}) {
									Err(Failed) => Chat.failed
									Ok(Full) => refuse_hops!({
										key,
										id,
										now,
									})
									Ok(Room) => append_post!({
										id,
										tally,
										message: {
											id: MessageCodec.next_id(tally.messages),
											at: now,
											by,
											body: got.bytes,
										},
										who: { named, accounts },
									})
								}
							}
						}
					}
			}
	}
}

## **A POST TAKEN**: refused when the transcript is full
## (Limits.transcript_bytes_most, a 413); else appended, as the next id
## its tally gives, and published to the conversation's streams, each
## once: the append and the publish are in this turn, so no stream
## subscribes between them.
append_post! : {
	id : ConvAccess.ConvId,
	tally : Store.Tally,
	message : MessageCodec.Fields,
	who : Who,
} => Chat.Answer
append_post! = |
	{
		id,
		tally,
		message,
		who,
	},
|
	if tally.bytes + List.len(MessageCodec.encode(message)) > Limits.transcript_bytes_most {
		Wire.refused(
			413,
			"this conversation is full: its transcript holds as much as one may",
		)
	} else {
		match Store.append_message!({
			id,
			tally,
			message,
		}) {
			Failed => Chat.failed
			Appended => {
				match frame(message, who) {
					Ok(f) => Host.publish!(bus_key(id), f)
					Err(LineBreak) => crash "Conversations.append_post!: a message's JSON holds no line break"
				}
				Wire.json(201, message_json(message, who))
			}
		}
	}

## **WHETHER AN AGENT MAY POST NOW** (Limits.agent_hops_most): a human
## always may; an agent or a bot not once the newest page holds that many
## agents answering agents since a human last spoke (Mentions.hops). The
## newest page is read from its first message's offset (Store.load_span!),
## never the transcript whole: a run of hops longer than a page still
## counts past the cap.
check_hops! : {
	id : ConvAccess.ConvId,
	tally : Store.Tally,
	by : Principal.Id,
	named : List(Mentions.Named),
} => Try([Room, Full], [Failed])
check_hops! = |
	{
		id,
		tally,
		by,
		named,
	},
|
	match by {
		Human(_) => Ok(Room)
		Agent(_) | Bot(_) => {
			newest = Store.load_span!(
				id,
				tally,
				Conversations.page_of(tally.messages, Newest),
			)?
			posts = newest.map(|m| { by: m.by, body: m.body })
			Ok(if (Mentions.hops(posts, named) >= Limits.agent_hops_most) Full else Room)
		}
	}

## **AN AGENT'S POST PAST THE CAP**: a 429 naming it, nothing stored, and
## the key that posted audited (`agent-hops`). Only a key posts as an
## agent, so a session never meets it.
refuse_hops! : {
	key : [NoKey, Key(ConvKey.Key)],
	id : ConvAccess.ConvId,
	now : I64,
} => Chat.Answer
refuse_hops! = |
	{
		key,
		id,
		now,
	},
| {
	match key {
		NoKey => {}
		Key(k) => Credentials.audit_use!(
			k,
			{
				use: Post(id),
				refusal: AgentHops,
				now,
			},
		)
	}
	Wire.refused(
		429,
		"agents have answered agents ${Limits.agent_hops_most.to_str()} times here since a human last spoke; a human's post lets them go on",
	)
}

## **STREAM**: the messages after the one the browser saw last
## (`Last-Event-ID`), read in this turn, then each one posted after, live:
## the host subscribes in the same turn, so a message is in the backlog or
## comes live, never both.
## **THE BACKLOG IS AT MOST THE NEWEST PAGE** (Conversations.page_of),
## read from its first message's offset (Store.load_span!), never the
## transcript whole. With no `Last-Event-ID` (or one that is no id) it is
## that page, which a conversation's page already shows. A browser further
## behind is sent a `gap` event first, `{"before":<id>}`: the messages
## before that id it missed are a read's, by `?before=`.
## **ITS HOLDER IS THE VIEWER'S PRINCIPAL** (a key's, the one it acts as),
## so the host's cap on streams a holder ends only the viewer's own.
stream! : ConvAccess.ConvId => Chat.Answer
stream! = |id|
	match load_seen!(id) {
		Err(answer) => answer
		Ok(a) =>
			match Store.load_tally!(id) {
				Err(Failed) => Chat.failed
				Ok(tally) => {
					after = last_seen_id(Host.read_header!(Str.to_utf8("last-event-id")))
					newest = Conversations.page_of(tally.messages, Newest)
					# After `after`, but never before the newest page, nor past
					# the newest message (an id no message has yet).
					first =
						if after < newest.first {
							newest.first
						} else if after < tally.messages {
							after + 1
						} else {
							tally.messages + 1
						}
					match Store.load_span!(
						id,
						tally,
						{ first, last: tally.messages },
					) {
						Err(Failed) => Chat.failed
						Ok(messages) => {
							gap = if (after > 0 and after + 1 < newest.first) gap_frame(newest.first) else []
							who = { named: named_of(a.conv, a.accounts), accounts: a.accounts }
							backlog = List.concat(
								gap,
								List.join(List.keep_oks(messages, |m| frame(m, who))),
							)
							Chat.stream({
								key: bus_key(id),
								backlog,
								holder: holder_of(a.viewer),
							})
						}
					}
				}
			}
	}

## The `gap` event: the messages before `before` were not sent.
gap_frame : U64 -> List(U8)
gap_frame = |before|
	match Sse.frame({
		name: Str.to_utf8("gap"),
		data: JsonOut.object([("before", JsonOut.number(before))]).bytes(),
		id: [],
	}) {
		Ok(f) => f
		Err(LineBreak) => crash "Conversations.gap_frame: a gap's JSON holds no line break"
	}

## Who holds a stream: the viewer's principal id, as the accounts spell it.
holder_of : Access.Viewer(ConvAccess.ConvId) -> List(U8)
holder_of = |viewer|
	match viewer.who() {
		SignedOut => crash "Conversations.holder_of: `load_seen!` let nobody signed out through"
		Session(b) | Key(b) => Str.to_utf8(AccountCodec.id_text(b.id))
	}

## The message id a `Last-Event-ID` names; 0 for none, or for one that is
## no id.
last_seen_id : List(List(U8)) -> U64
last_seen_id = |values|
	match values {
		[only] => Stored.count(only, "last-event-id") ?? 0
		_ => 0
	}

## The bus key a conversation's streams are held on.
bus_key : ConvAccess.ConvId -> List(U8)
bus_key = |id| Str.to_utf8("conversation/${id.to_u64().to_str()}")

## A message as one SSE event: named `message`, its id the message's.
frame : MessageCodec.Fields, Who -> Try(List(U8), [LineBreak])
frame = |m, who| Sse.frame({
	name: Str.to_utf8("message"),
	data: message_json(m, who).bytes(),
	id: Str.to_utf8(m.id.to_str()),
})

## **WHO A MESSAGE'S JSON IS SPELLED FOR**: the conversation's
## participants by their names now (`named`, what a mention finds), and the
## accounts now (`accounts`, whom a poster answers to).
Who : { named : List(Mentions.Named), accounts : List(Principal) }

## **A MESSAGE AS THE WIRE SPELLS IT**: who posted it, of what kind, and
## the human an agent or a bot answers to (`owner_of`), so a page tells an
## agent from the human whose name it took; its markdown as posted, the
## participants it names (by their names now), and its html as
## roc-markdown renders it now. `html` is last: a reader may take it up to
## the object's closing `"}` (host/e2e.zig does).
message_json : MessageCodec.Fields, Who -> JsonOut
message_json = |m, who| {
	author = [
		("id", JsonOut.number(m.id)),
		("at", JsonOut.signed(m.at)),
		("by", JsonOut.string(AccountCodec.id_text(m.by))),
		("kind", JsonOut.string(AccountCodec.kind_text(m.by))),
	].concat(owner_of(who.accounts, m.by))
	mentioned = Mentions.of(m.body, who.named).map(|id| JsonOut.string(AccountCodec.id_text(id)))
	JsonOut.object(
		author.concat([
			("markdown", JsonOut.text(m.body)),
			("mentions", JsonOut.array(mentioned)),
			("html", JsonOut.text(Conversations.html_of(m))),
		]),
	)
}

## **THE `owner` A POSTER'S JSON CARRIES**: for an agent or a bot, the
## human it answers to (Principal.answers_to), as the accounts say now; for
## a human, none. None too for an agent no account holds now (retired):
## its owner is no longer known, and `kind` still says it is an agent.
owner_of : List(Principal), Principal.Id -> List((Str, JsonOut))
owner_of = |accounts, by|
	match by {
		Human(_) => []
		Agent(_) | Bot(_) =>
			match Principal.find(accounts, by) {
				Ok(p) => [("owner", JsonOut.string(AccountCodec.id_text(Principal.Id.Human(Principal.answers_to(p)))))]
				Err(_) => []
			}
	}

## A conversation's participants as a mention finds them: each id with the
## name the accounts give it now.
named_of : ConvAccess.Conv, List(Principal) -> List(Mentions.Named)
named_of = |conv, accounts| conv.participants().map(
	|b| {
		id: b.id,
		name: Conversations.name_of(accounts, b.id),
	},
)

not_signed_in : Chat.Answer
not_signed_in = Wire.refused(401, "not signed in")

expect Conversations.route(Str.to_utf8("/conversations")) == Ok(Start)
expect Conversations.route(Str.to_utf8("/conversations/12")).map_ok(|r| r == Read(cid(12))) == Ok(Bool.True)
expect Conversations.route(Str.to_utf8("/conversations/12/messages")).map_ok(|r| r == Post(cid(12))) == Ok(Bool.True)
expect Conversations.route(Str.to_utf8("/conversations/12/stream")).map_ok(|r| r == Stream(cid(12))) == Ok(Bool.True)
expect Conversations.route(Str.to_utf8("/conversations/0")).is_err()
expect Conversations.route(Str.to_utf8("/conversations/012")).is_err()
expect Conversations.route(Str.to_utf8("/conversations/12/other")).is_err()
expect Conversations.route(Str.to_utf8("/conversations/")).is_err()
expect Conversations.route(Str.to_utf8("/conversationsx")).is_err()
expect last_seen_id([Str.to_utf8("7")]) == 7
expect last_seen_id([Str.to_utf8("07")]) == 0
expect last_seen_id([]) == 0
expect others_of(Str.to_utf8("with=human%3A2%2Cagent%3A7")) == Ok([
	Principal.Id.Human(Cast.gid(2)),
	Principal.Id.Agent(Cast.aid(7)),
])
expect others_of(Str.to_utf8("with=")) == Ok([])
expect others_of(Str.to_utf8("with=human%3A0")) == Err(Malformed)

cid : U64 -> ConvAccess.ConvId
cid = |n| ConvAccess.ConvId.from_u64(n) ?? crash "cid: not 0"

# A message's JSON names its poster's kind, and an agent's or a bot's
# owner, before its markdown; a human's has no owner, nor has an agent no
# account holds now. `html` stays last.
said_by : Principal.Id -> List(U8)
said_by = |by|
	message_json(
		{
			id: 3,
			at: 5,
			by,
			body: "hi".to_utf8(),
		},
		{ named: [], accounts: Cast.accounts },
	).bytes()

expect said_by(Cast.ann.id()).starts_with("{\"id\":3,\"at\":5,\"by\":\"human:2\",\"kind\":\"human\",\"markdown\":\"hi\",".to_utf8())
expect said_by(Cast.ann_agent.id()).starts_with("{\"id\":3,\"at\":5,\"by\":\"agent:3\",\"kind\":\"agent\",\"owner\":\"human:2\",\"markdown\":\"hi\",".to_utf8())
expect said_by(Cast.boss_bot.id()).starts_with("{\"id\":3,\"at\":5,\"by\":\"bot:2\",\"kind\":\"bot\",\"owner\":\"human:1\",\"markdown\":\"hi\",".to_utf8())
expect said_by(Principal.Id.Agent(Cast.aid(9))).starts_with("{\"id\":3,\"at\":5,\"by\":\"agent:9\",\"kind\":\"agent\",\"markdown\":\"hi\",".to_utf8())
expect Bytes.find(said_by(Cast.ann_agent.id()), { needle: ",\"html\":\"".to_utf8(), at: 0 }).is_ok() and said_by(Cast.ann_agent.id()).ends_with("\"}".to_utf8())

# Pages: the newest, back to the first, and past either end.
expect Conversations.page_of(0, Newest) == { first: 1, last: 0 }
expect Conversations.page_of(5, Newest) == { first: 1, last: 5 }
expect Conversations.page_of(250, Newest) == { first: 151, last: 250 }
expect Conversations.page_of(250, Before(151)) == { first: 51, last: 150 }
expect Conversations.page_of(250, Before(51)) == { first: 1, last: 50 }
expect Conversations.page_of(250, Before(1)) == { first: 1, last: 0 }
expect Conversations.page_of(250, Before(900)) == { first: 151, last: 250 }
expect before_of([]) == Ok(Newest)
expect before_of([Str.to_utf8("7")]) == Ok(Before(7))
expect before_of([Str.to_utf8("0")]) == Err(Malformed)
expect before_of([Str.to_utf8("07")]) == Err(Malformed)
expect before_of([Str.to_utf8("x")]) == Err(Malformed)
expect before_of([Str.to_utf8("7"), Str.to_utf8("8")]) == Err(Malformed)

# The chat's uploads rule: an upload's image renders; one of the chat's own
# routes, as a src, is text.
expect Str.contains(
	Str.from_utf8(
		Md.render(
			Str.to_utf8("<img src=\"/user_uploads/a.png\">"),
			Conversations.markdown,
		),
	) ?? "",
	"<img src=\"/user_uploads/a.png\">",
)
expect !Str.contains(
	Str.from_utf8(
		Md.render(
			Str.to_utf8("<img src=\"/conversations/1/stream\">"),
			Conversations.markdown,
		),
	) ?? "",
	"<img",
)

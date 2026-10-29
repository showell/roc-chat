## **THE CHAT'S CONVERSATIONS ON THE WIRE**: start one, post to it, read it,
## stream it. Every decision is the core's: who may see and who may post is
## ConvAccess's, on the viewer from the request's session or API key
## (Credentials.viewer!), never on anything the request claims; how a message reads is
## roc-markdown's, with its work budget. Here are the facts asked of the
## host, the records kept (Store), and the answers made.
##
## The routes (app/main.roc's table names them):
##
##     GET  /conversations                  the viewer's own, JSON: each one's id and who
##                                          is in it (`mine!`)
##     POST /conversations                  start one: a form, `with=` the others' ids,
##                                          comma-separated (`human:2,agent:7`)
##     GET  /conversations/<id>             its transcript, JSON
##     POST /conversations/<id>/messages    post: the body is the markdown, as is
##     GET  /conversations/<id>/stream      its messages, live (SSE), after
##                                          `Last-Event-ID` when the browser resumes
##
## A message, in the transcript and on the stream alike, is one JSON object:
## `{"id":3,"at":1761600000,"by":"human:2","markdown":"…","html":"…"}`. On
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
						[id_part] => id_of(id_part).map_ok(|id| Read(id))
						[
							id_part,
							act,
						] if act == Str.to_utf8("messages") => id_of(id_part).map_ok(|id| Post(id))
						[
							id_part,
							act,
						] if act == Str.to_utf8("stream") => id_of(id_part).map_ok(|id| Stream(id))
						_ => Err(NotAConversation)
					}
			}
		}

	## **THE VIEWER'S OWN CONVERSATIONS**, oldest first: each one ConvAccess
	## lets them post in (a participant, or the human its agent or bot
	## answers to). A public conversation they may only read is not theirs.
	mine! : Access.Viewer(ConvAccess.ConvId),
	List(Principal) => Try(
		List(ConvAccess.Conv),
		[Failed],
	)
	mine! = |viewer, accounts| {
		all = Store.load_conversations!({})?
		Ok(List.keep_if(all, |conv| ConvAccess.can_post(viewer, { conv, accounts })))
	}

	## A message's HTML: roc-markdown's render of its markdown, the one
	## the transcript, the stream and the pages all give.
	html_of : MessageCodec.Fields -> List(U8)
	html_of = |m| Md.render(m.body)

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
			Read(id) => if req.method == Get read!(id) else Chat.not_allowed(Get)
			Post(id) => if req.method == Post post!(id) else Chat.not_allowed(Post)
			Stream(id) => if req.method == Get stream!(id) else Chat.not_allowed(Get)
		}
}

## The most a message's markdown may be, and a start's form.
post_most : U64
post_most = 32 * 1024

form_most : U64
form_most = 4 * 1024

root : List(U8)
root = Str.to_utf8("/conversations")

## A conversation's id as a path spells it: digits, one spelling, not 0.
id_of : List(U8) -> Try(ConvAccess.ConvId, [NotAConversation])
id_of = |digits|
	match Stored.count(digits, "id") {
		Err(_) => Err(NotAConversation)
		Ok(n) => ConvAccess.ConvId.from_u64(n).map_err(|_| NotAConversation)
	}

## **START A CONVERSATION**: the viewer, and each id the form's `with`
## names, bound to their accounts now (ConvAccess.Conv.start); stored, and
## its id answered. A session starts one; a key starts one only where it
## could post to it then (ConvAccess.can_post: its post reaching it, and its
## principal in it), and is audited when not. Nobody signed in cannot.
start! : {} => Chat.Answer
start! = |{}| {
	got = Host.read_body!(form_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match Credentials.viewer!(Start) {
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
						SignedOut => signed_out
						Session(me) | Key(me) =>
							match others_of(got.bytes) {
								Err(Malformed) => refused(
									400,
									"`with` names the others, as `human:2,agent:7`",
								)
								Ok(others) =>
									match Store.load_next_conversation_id!({}) {
										Err(Failed) => Chat.failed
										Ok(id) =>
											match ConvAccess.Conv.start({
												id,
												participants: List.prepend(others, me.id),
												accounts,
											}) {
												Err(NoParticipants) => refused(
													400,
													"a conversation has someone in it",
												)
												Err(NoSuchParticipant(who)) => refused(
													400,
													"no account is ${AccountCodec.id_text(who)}",
												)
												Ok(conv) =>
													if !ConvAccess.can_post(
														viewer,
														{ conv, accounts },
													) {
														out_of_scope!({
															key,
															use: Start,
															action: Post(conv),
															accounts,
															now,
														})
														refused(
															403,
															"this key may not post to a new conversation",
														)
													} else {
														match Store.save_conversation!(conv, now) {
															Failed => Chat.failed
															Written => json(
																201,
																Str.to_utf8("{\"id\":${id.to_u64().to_str()}}"),
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

## **THE VIEWER'S OWN, AS JSON**: each one's id, and who is in it, each
## by id and name.
list! : {} => Chat.Answer
list! = |{}|
	match Credentials.viewer!(Start) {
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
				SignedOut => signed_out
				Session(_) | Key(_) =>
					match Conversations.mine!(viewer, accounts) {
						Err(Failed) => Chat.failed
						Ok(convs) => {
							one = |conv| {
								people = List.map(
									conv.participants(),
									|b| List.join([
										Str.to_utf8("{\"id\":\"${AccountCodec.id_text(b.id)}\",\"name\":"),
										json_string(
											Str.to_utf8(
												Conversations.name_of(
													accounts,
													b.id,
												),
											),
										),
										['}'],
									]),
								)
								List.join([
									Str.to_utf8("{\"id\":${conv.id().to_u64().to_str()},\"with\":["),
									commas(people),
									Str.to_utf8("]}"),
								])
							}
							json(
								200,
								List.join([
									Str.to_utf8("{\"conversations\":["),
									commas(List.map(convs, one)),
									Str.to_utf8("]}"),
								]),
							)
						}
					}
			}
	}

## **A KEY USED OUTSIDE WHAT IT MAY DO, AUDITED**: the core's own refusal
## (ConvKey.decide) for the action it was refused. A session's refusal is
## no key's, and is not audited.
out_of_scope! : {
	key : [NoKey, Key(ConvKey.Key)],
	use : Credentials.Use,
	action : [Read(ConvAccess.Conv), Post(ConvAccess.Conv)],
	accounts : List(Principal),
	now : I64,
} => {}
out_of_scope! = |
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

## **WHAT A REQUEST ON A CONVERSATION DECIDES ON**: the viewer from its
## session or key, the accounts now, the conversation, the time, and the
## key when a key asks; or the answer that ends it (signed out, a key
## refused, not there, a failure).
Asked : {
	viewer : Access.Viewer(ConvAccess.ConvId),
	accounts : List(Principal),
	now : I64,
	conv : ConvAccess.Conv,
	key : [NoKey, Key(ConvKey.Key)],
}

asked! : ConvAccess.ConvId, Credentials.Use => Try(Asked, Chat.Answer)
asked! = |id, use| {
	{
		viewer,
		accounts,
		now,
		key,
	} = Credentials.viewer!(use)?
	match viewer.who() {
		SignedOut => Err(signed_out)
		Session(_) | Key(_) =>
			match Store.load_conversation!(id) {
				Err(Failed) => Err(Chat.failed)
				Err(Missing) => Err(no_such)
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
seen! : ConvAccess.ConvId => Try(Asked, Chat.Answer)
seen! = |id| {
	a = asked!(id, Read(id))?
	if ConvAccess.can_see(a.viewer, { conv: a.conv, accounts: a.accounts }) {
		Ok(a)
	} else {
		out_of_scope!({
			key: a.key,
			use: Read(id),
			action: Read(a.conv),
			accounts: a.accounts,
			now: a.now,
		})
		Err(no_such)
	}
}

## **READ**: the transcript, every message as the wire spells it.
read! : ConvAccess.ConvId => Chat.Answer
read! = |id|
	match seen!(id) {
		Err(answer) => answer
		Ok(_) =>
			match Store.load_transcript!(id) {
				Err(Failed) => Chat.failed
				Ok(messages) =>
					json(
						200,
						List.join([
							Str.to_utf8("{\"id\":${id.to_u64().to_str()},\"messages\":["),
							commas(List.map(messages, message_json)),
							Str.to_utf8("]}"),
						]),
					)
			}
	}

## **POST**: the body is the markdown. Refused when the viewer may not post
## (ConvAccess.can_post, asked first and alone: a 403 to one who may see it,
## a 404 to one who may not), when it is not UTF-8 text, or when it is
## hostile (roc-markdown's budget). Then appended, as the transcript's next id, and
## published to the conversation's streams, each once: the append and the
## publish are in this turn, so no stream subscribes between them.
post! : ConvAccess.ConvId => Chat.Answer
post! = |id| {
	got = Host.read_body!(post_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match asked!(id, Post(id)) {
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
						out_of_scope!({
							key,
							use: Post(id),
							action: Post(conv),
							accounts,
							now,
						})
						if ConvAccess.can_see(viewer, { conv, accounts }) refused(
							403,
							"only its participants post here",
						) else no_such
					} else if Str.from_utf8(got.bytes).is_err() {
						refused(400, "a message is UTF-8 text")
					} else if Md.hostility(got.bytes) == TooMuchFormatting {
						refused(400, Md.too_much_formatting)
					} else {
						by =
							match viewer.who() {
								SignedOut => crash "Conversations.post!: `asked!` let nobody signed out through"
								Session(b) | Key(b) => b.id
							}
						match Store.load_transcript!(id) {
							Err(Failed) => Chat.failed
							Ok(messages) => {
								message = {
									id: MessageCodec.next_id(List.len(messages)),
									at: now,
									by,
									body: got.bytes,
								}
								match Store.append_message!(id, message) {
									Failed => Chat.failed
									Appended => {
										match frame(message) {
											Ok(f) => Host.publish!(bus_key(id), f)
											Err(LineBreak) => crash "Conversations.post!: a message's JSON holds no line break"
										}
										json(201, message_json(message))
									}
								}
							}
						}
					}
			}
	}
}

## **STREAM**: the messages after the one the browser saw last
## (`Last-Event-ID`; none, or one that is no id, is from the start), read in
## this turn, then each one posted after, live: the host subscribes in the
## same turn, so a message is in the backlog or comes live, never both.
stream! : ConvAccess.ConvId => Chat.Answer
stream! = |id|
	match seen!(id) {
		Err(answer) => answer
		Ok(_) =>
			match Store.load_transcript!(id) {
				Err(Failed) => Chat.failed
				Ok(messages) => {
					after = last_seen_id(Host.read_header!(Str.to_utf8("last-event-id")))
					backlog = List.join(
						List.keep_oks(
							List.keep_if(messages, |m| m.id > after),
							frame,
						),
					)
					Chat.stream({ key: bus_key(id), backlog })
				}
			}
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
frame : MessageCodec.Fields -> Try(List(U8), [LineBreak])
frame = |m| Sse.frame({
	name: Str.to_utf8("message"),
	data: message_json(m),
	id: Str.to_utf8(m.id.to_str()),
})

## **A MESSAGE AS THE WIRE SPELLS IT**: its markdown as posted, and its
## html as roc-markdown renders it now.
message_json : MessageCodec.Fields -> List(U8)
message_json = |m|
	List.join([
		Str.to_utf8("{\"id\":${m.id.to_str()},\"at\":${m.at.to_str()},\"by\":\"${AccountCodec.id_text(m.by)}\",\"markdown\":"),
		json_string(m.body),
		Str.to_utf8(",\"html\":"),
		json_string(Conversations.html_of(m)),
		['}'],
	])

json_string : List(U8) -> List(U8)
json_string = Wire.json_string

commas : List(List(U8)) -> List(U8)
commas = Wire.commas

json : U16, List(U8) -> Chat.Answer
json = Wire.json

refused : U16, Str -> Chat.Answer
refused = Wire.refused

signed_out : Chat.Answer
signed_out = refused(401, "not signed in")

no_such : Chat.Answer
no_such = refused(404, "no such conversation")

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

## **A CHANNEL'S TOPICS ON THE WIRE** (the channels design; Topic.roc
## decides, Store.roc keeps them, Channel.roc says who is a member):
##
##     POST /channels/<channel>/topics                    make one: a form, `name=`, and
##                                                        `agents=` the agents' ids for an agent topic
##     GET  /channels/<channel>/topics/<topic>            its messages, a page (`?before=`)
##     POST /channels/<channel>/topics/<topic>/messages   post: the body is the markdown
##     GET  /channels/<channel>/topics/<topic>/stream     its messages, live (SSE), after
##                                                        `Last-Event-ID`
##
## A topic's message is a conversation's (Conversations.message_json),
## its reference first: `{"ref":"MSG_Lobby.ChitChat_3","id":3,...}`, the
## one spelling MessageRef writes, which names its channel and its topic
## and is never ambiguous. **WHO MAY** is Topic's alone (a member reads
## and posts in a human topic; an agent topic's agents and the humans they
## answer to in theirs), asked of the viewer over topics
## (Access.Viewer.over: a key that reads everywhere reaches a topic, one
## narrowed to conversations reaches none). A topic the viewer may not
## read is a 404, as one that is not there; one they read but may not
## post to, a 403. An agent topic's posts reach its agents' one stream
## (OneStream), as `{"channel":..,"topic":..,"ref":..,...}`.
import pf.Chat
import pf.Host
import pf.Sse
import md.Md
import Access
import AccountCodec
import Bubble
import Channel
import ChannelLayout
import ChannelName
import Conversations
import Credentials
import JsonOut
import Limits
import Mentions
import MessageCodec
import MessageRef
import Principal
import SignInWeb
import Store
import Stored
import Topic
import TopicName
import Wire

Topics := [].{

	## The routes.
	Route : [
		Make(ChannelName),
		Read(Topic.At),
		Post(Topic.At),
		Stream(Topic.At),

		## A human DM (`/dms`, `/dms/<n>/...`, `n` the other human's id):
		## the pair's channel (ChannelName.dm_of), found from the asker's
		## own id when they ask.
		Dms,
		DmMake(Principal.HumanId),
		DmRead({ other : Principal.HumanId, topic : TopicName }),
		DmPost({ other : Principal.HumanId, topic : TopicName }),
		DmStream({ other : Principal.HumanId, topic : TopicName }),
	]

	## The route a path names, if it names one.
	route : List(U8) -> Try(Topics.Route, [NotTopics])
	route = |path|
		match path.split_on('/') {
			[
				[],
				channels,
				c,
				topics,
			] if channels == "channels".to_utf8() and topics == "topics".to_utf8() =>
				channel_in(c).map_ok(|name| Make(name))
			[
				[],
				channels,
				c,
				topics,
				t,
			] if channels == "channels".to_utf8() and topics == "topics".to_utf8() =>
				at_in(c, t).map_ok(|at| Read(at))
			[
				[],
				channels,
				c,
				topics,
				t,
				act,
			] if channels == "channels".to_utf8() and topics == "topics".to_utf8() =>
				if act == "messages".to_utf8() {
					at_in(c, t).map_ok(|at| Post(at))
				} else if act == "stream".to_utf8() {
					at_in(c, t).map_ok(|at| Stream(at))
				} else {
					Err(NotTopics)
				}
			[[], dms] if dms == "dms".to_utf8() => Ok(Dms)
			[
				[],
				dms,
				n,
				topics,
			] if dms == "dms".to_utf8() and topics == "topics".to_utf8() =>
				human_in(n).map_ok(|other| DmMake(other))
			[
				[],
				dms,
				n,
				topics,
				t,
			] if dms == "dms".to_utf8() and topics == "topics".to_utf8() =>
				dm_in(n, t).map_ok(|d| DmRead(d))
			[
				[],
				dms,
				n,
				topics,
				t,
				act,
			] if dms == "dms".to_utf8() and topics == "topics".to_utf8() =>
				if act == "messages".to_utf8() {
					dm_in(n, t).map_ok(|d| DmPost(d))
				} else if act == "stream".to_utf8() {
					dm_in(n, t).map_ok(|d| DmStream(d))
				} else {
					Err(NotTopics)
				}
			_ => Err(NotTopics)
		}

	## **ANSWER A ROUTE**, each to the method it takes.
	answer! : Chat.Request, Topics.Route => Chat.Answer
	answer! = |req, r|
		match r {
			Make(name) =>
				match req.method {
					Post => make!(name)
					Get => list!(name)
					_ => Chat.not_allowed(Post)
				}
			Dms =>
				match req.method {
					Post => start_dm!({})
					Get => list_dms!({})
					_ => Chat.not_allowed(Post)
				}
			DmMake(other) =>
				match dm_name!(other) {
					Err(answer) => answer
					Ok(name) =>
						match req.method {
							Post => make!(name)
							Get => list!(name)
							_ => Chat.not_allowed(Post)
						}
				}
			DmRead({ other, topic }) => if (req.method == Get) in_dm!(
				{ other, topic },
				read!,
			) else Chat.not_allowed(Get)
			DmPost({ other, topic }) => if (req.method == Post) in_dm!(
				{ other, topic },
				post!,
			) else Chat.not_allowed(Post)
			DmStream({ other, topic }) => if (req.method == Get) in_dm!(
				{ other, topic },
				stream!,
			) else Chat.not_allowed(Get)
			Read(at) => if (req.method == Get) read!(at) else Chat.not_allowed(Get)
			Post(at) => if (req.method == Post) post!(at) else Chat.not_allowed(Post)
			Stream(at) => if (req.method == Get) stream!(at) else Chat.not_allowed(Get)
		}

	## **WHAT A TOPIC'S PAGE DECIDES ON** (TopicPage.roc): the viewer over
	## topics, the accounts and the time, from the credential.
	viewer! : {} => Try(
		{
			viewer : Access.Viewer(Topic.At),
			accounts : List(Principal),
			now : I64,
		},
		Chat.Answer,
	)
	viewer! = |{}| load_viewer!({})

	## **THE TOPIC, IF THIS VIEWER READS IT**, as the topic's own routes
	## decide (`Topic.read`): its channel and the topic, or the answer that
	## ends the request (no such channel or topic, or one the viewer may not
	## read: the same 404).
	readable! : {
		viewer : Access.Viewer(Topic.At),
		accounts : List(Principal),
		now : I64,
	},
	Topic.At => Try({ channel : Channel, topic : Topic }, Chat.Answer)
	readable! = |v, at| {
		a = read_by!(v, at)?
		Ok({ channel: a.channel, topic: a.topic })
	}

	## **THE BUS KEY A TOPIC'S PAGES ARE HELD ON**, beside its streams'
	## (`bus_key`): each post's bubble, as Bubble.roc draws it, published
	## once for every page that shows the topic.
	page_key : Topic.At -> List(U8)
	page_key = |at| Str.to_utf8("topic-page/${spot_of(at)}")

	## **A BUBBLE AS ONE SSE EVENT**, named `message`, its id the message's,
	## as a page's stream and a post's publish both write it.
	page_frame : List(Principal), MessageCodec.Fields -> List(U8)
	page_frame = |accounts, m|
		match Sse.frame({
			name: Str.to_utf8("message"),
			data: Bubble.data(Bubble.of(accounts, m)),
			id: Str.to_utf8(m.id.to_str()),
		}) {
			Ok(f) => f
			Err(LineBreak) => crash "Topics.page_frame: Bubble.data holds no CR, and the name and id no line break"
		}

	## A channel topic's place in a path's two parts; a DM's name is no
	## channel's.
	channel_topic_in : List(U8), List(U8) -> Try(Topic.At, [NotTopics])
	channel_topic_in = |c, t| at_in(c, t)

	## A DM's other human and its topic in a path's two parts.
	dm_topic_in : List(U8), List(U8) -> Try({ other : Principal.HumanId, topic : TopicName }, [NotTopics])
	dm_topic_in = |n, t| dm_in(n, t)

	## The `gap` event, as a topic's stream sends it.
	gap : U64 -> List(U8)
	gap = |before| gap_frame(before)

	## **THE AGENT TOPICS THAT NAME `agent`**, as sources of its one stream
	## (OneStream): every channel's agent topics naming it whose binding
	## holds, and that the viewer (its key) reads. A channel or a topic
	## record that does not read is left out, as the listings leave it.
	sources_of! : {
		agent : Principal.Bound,
		viewer : Access.Viewer(Topic.At),
		accounts : List(Principal),
	} => Try(List(Conversations.Source), [Failed])
	sources_of! = |
		{
			agent,
			viewer,
			accounts,
		},
	| {
		listed = Store.load_channels!({})?
		listed.channels.map_try!(
			|channel| {
				topics = Store.load_topics!(channel)?
				Ok(
					topics.topics.keep_if(
						|t| t.agents(accounts).contains(agent) and t.read({
							viewer,
							channel,
							accounts,
						}) == Permitted,
					).map(
						|t| source_of({
							topic: t,
							channel,
							accounts,
						}),
					),
				)
			},
		).map_ok(List.join)
	}
}

## A topic as a source of an agent's one stream.
source_of : {
	topic : Topic,
	channel : Channel,
	accounts : List(Principal),
} -> Conversations.Source
source_of = |
	{
		topic,
		channel,
		accounts,
	},
| {
	spot: spot_of(topic.at()),
	files: Store.topic_files(topic.at()),
	lead: lead_of(topic.at()),
	who: { named: named_of(topic, { channel, accounts }), accounts },
}

## A topic's spot on the one stream: its channel's key and its own.
spot_of : Topic.At -> Str
spot_of = |at| "${at.channel.key()}/${at.topic.key()}"

## What a topic's events on the one stream carry first: its channel and
## its name, as they were made.
lead_of : Topic.At -> List((Str, JsonOut))
lead_of = |at| [
	("channel", JsonOut.string(at.channel.to_str())),
	("topic", JsonOut.string(at.topic.to_str())),
]

## The channel's name in a path; none that its rule refuses.
## A channel's name in a path; a DM's (`dm-`) is reached by `/dms` alone,
## by the pair, never as a channel.
channel_in : List(U8) -> Try(ChannelName, [NotTopics])
channel_in = |bytes|
	match Str.from_utf8(bytes) {
		Ok(text) =>
			match ChannelName.from_str(text) {
				Ok(name) if !name.is_dm() => Ok(name)
				_ => Err(NotTopics)
			}
		Err(_) => Err(NotTopics)
	}

## A human's id in a path, its digits (a DM's other).
human_in : List(U8) -> Try(Principal.HumanId, [NotTopics])
human_in = |bytes| Stored.id(
	bytes,
	{ name: "human", make: Principal.HumanId.from_u64 },
).map_err(|_| NotTopics)

## A DM's other and topic in a path.
dm_in : List(U8), List(U8) -> Try({ other : Principal.HumanId, topic : TopicName }, [NotTopics])
dm_in = |n, t| {
	other = human_in(n)?
	topic =
		match Str.from_utf8(t) {
			Ok(text) => TopicName.from_str(text).map_err(|_| NotTopics)
			Err(_) => Err(NotTopics)
		}?
	Ok({ other, topic })
}

## **THE DM'S CHANNEL, FOR THE ASKER**: the pair of the asker (a human,
## by session or their own key) and `other`. Signed out, a 401; an agent
## or a bot, or oneself, has no DM: a 404.
dm_name! : Principal.HumanId => Try(ChannelName, Chat.Answer)
dm_name! = |other| {
	v = load_viewer!({})?
	match v.viewer.who() {
		SignedOut => Err(not_signed_in)
		Session(b) | Key(b) =>
			match b.id {
				Human(me) if me != other => Ok(ChannelName.dm_of(me.to_u64(), other.to_u64()))
				_ => Err(no_such_dm)
			}
	}
}

## A DM route, its topic's place found for the asker, answered by `then!`.
in_dm! : { other : Principal.HumanId, topic : TopicName }, (Topic.At => Chat.Answer) => Chat.Answer
in_dm! = |{ other, topic }, then!|
	match dm_name!(other) {
		Err(answer) => answer
		Ok(channel) => then!({ channel, topic })
	}

## **/dms, POST**: the asker's DM with `with=human:<n>` (Channel.dm
## decides), made once: `201` when made, `200` when it was there, and the
## DM either way.
start_dm! : {} => Chat.Answer
start_dm! = |{}| {
	got = Host.read_body!(Wire.form_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match start_dm_from!(got.bytes) {
				Ok(answer) => answer
				Err(answer) => answer
			}
	}
}

start_dm_from! : List(U8) => Try(Chat.Answer, Chat.Answer)
start_dm_from! = |form| {
	v = load_viewer!({})?
	other =
		match SignInWeb.form_field(form, "with") {
			Ok(text) => AccountCodec.id_from(text, "with").map_err(
				|_| Wire.refused(
					400,
					"with= is the other human's id",
				),
			)
			Err(_) => Err(Wire.refused(400, "with= is the other human's id"))
		}?
	made =
		Channel.dm({
			by: v.viewer,
			other,
			accounts: v.accounts,
		}).map_err(
			|why|
				match why {
					SignedOut | NoSuchPrincipal => not_signed_in
					NotAHuman(_) => Wire.refused(403, "a DM is two humans'")
					NoAccount(_) => Wire.refused(404, "no human holds that id")
					Yourself => Wire.refused(400, "a DM is with someone else")
				},
		)?
	answer = |status| Wire.json(status, dm_json(made, v.accounts))
	match Store.save_new_channel!(made) {
		Written => Ok(answer(201))
		Taken => Ok(answer(200))
		Failed => Ok(Chat.failed)
	}
}

## A DM as the wire spells it: its channel's name (`dm-<a>-<b>`), and its
## two members.
dm_json : Channel, List(Principal) -> JsonOut
dm_json = |dm, accounts|
	JsonOut.object([
		("dm", JsonOut.string(dm.name().to_str())),
		(
			"members",
			JsonOut.array(dm.members(accounts).map(|b| JsonOut.string(AccountCodec.id_text(b.id)))),
		),
	])

## **/dms, GET**: the asker's DMs, each with its topics.
list_dms! : {} => Chat.Answer
list_dms! = |{}|
	match load_viewer!({}) {
		Err(answer) => answer
		Ok(v) =>
			match v.viewer.who() {
				SignedOut => not_signed_in
				Session(me) | Key(me) =>
					match Store.load_channels!({}) {
						Err(Failed) => Chat.failed
						Ok(listed) => {
							mine = listed.channels.keep_if(
								|c| c.name().is_dm() and c.membership({
									who: me,
									accounts: v.accounts,
								}) == Member,
							)
							Wire.json(
								200,
								JsonOut.object([
									(
										"dms",
										JsonOut.array(mine.map(|c| dm_json(c, v.accounts))),
									),
								]),
							)
						}
					}
			}
	}

## **A CHANNEL'S (OR A DM'S) TOPICS, GET**: those the viewer may read, by
## name, with their kind; a channel none of whose topics they read lists
## none.
list! : ChannelName => Chat.Answer
list! = |name|
	match list_of!(name) {
		Ok(answer) => answer
		Err(answer) => answer
	}

list_of! : ChannelName => Try(Chat.Answer, Chat.Answer)
list_of! = |name| {
	v = load_viewer!({})?
	if v.viewer.who() == SignedOut {
		Err(not_signed_in)
	} else {
		channel = load_channel!(name)?
		topics = Store.load_topics!(channel).map_err(|_| Chat.failed)?
		readable = topics.topics.keep_if(
			|t| t.read({
				viewer: v.viewer,
				channel,
				accounts: v.accounts,
			}) == Permitted,
		)
		Ok(
			Wire.json(
				200,
				JsonOut.object([
					(
						"topics",
						JsonOut.array(readable.map(|t| topic_json(t, v.accounts))),
					),
				]),
			),
		)
	}
}

## A topic's place in a path: its channel's name and its own.
at_in : List(U8), List(U8) -> Try(Topic.At, [NotTopics])
at_in = |c, t| {
	channel = channel_in(c)?
	topic =
		match Str.from_utf8(t) {
			Ok(text) => TopicName.from_str(text).map_err(|_| NotTopics)
			Err(_) => Err(NotTopics)
		}?
	Ok({ channel, topic })
}

## **WHO A TOPIC'S MESSAGE IS SPELLED FOR**: its people by their names now
## (Mentions): a human topic's members; an agent topic's agents, and the
## humans they answer to.
named_of : Topic, { channel : Channel, accounts : List(Principal) } -> List(Mentions.Named)
named_of = |topic, { channel, accounts }| {
	ids =
		match topic.kind() {
			Human => channel.members(accounts).map(|b| b.id)
			Agents => {
				agents = topic.agents(accounts).map(|b| b.id)
				owners = agents.keep_oks(
					|id| Principal.find(
						accounts,
						id,
					).map_ok(|p| Principal.Id.Human(p.answers_to())),
				)
				agents.concat(owners.keep_if(|o| !agents.contains(o)))
			}
		}
	dedup(ids).map(|id| { id, name: Conversations.name_of(accounts, id) })
}

## The ids, each once, in order.
dedup : List(Principal.Id) -> List(Principal.Id)
dedup = |ids| ids.fold([], |kept, id| if (kept.contains(id)) kept else kept.append(id))

## A topic's message as its JSON: its reference first.
message_json : Topic.At,
MessageCodec.Fields,
{
	named : List(Mentions.Named),
	accounts : List(Principal),
} -> JsonOut
message_json = |
	at,
	m,
	who,
| Conversations.json_led(
	ref_lead(at, m.id),
	m,
	who,
)

## The `ref` a topic's message carries first.
ref_lead : Topic.At, U64 -> List((Str, JsonOut))
ref_lead = |at, n| [("ref", JsonOut.string(ref_text(at, n)))]

## **A MESSAGE'S REFERENCE**, `MSG_<channel>.<topic>_<n>`, as MessageRef
## writes and reads it.
ref_text : Topic.At, U64 -> Str
ref_text = |at, n| {
	text = "MSG_${at.channel.to_str()}.${at.topic.to_str()}_${n.to_str()}"
	match MessageRef.from_str(text) {
		# A DM's is the short `MSG_<topic>_<n>`: "this topic, on this page".
		Ok(ref) => if (at.channel.is_dm()) "MSG_${ref.local_id()}" else ref.to_str()
		Err(NotAReference) => crash "Topics.ref_text: a topic's place and a message id are a reference"
	}
}

## **WHAT A REQUEST ON A TOPIC DECIDES ON**: the viewer over topics, the
## accounts, the time, the channel and the topic; or the answer that ends
## it (a key refused, no such channel or topic, a failure).
Asked : {
	viewer : Access.Viewer(Topic.At),
	accounts : List(Principal),
	now : I64,
	channel : Channel,
	topic : Topic,
}

## The viewer over topics, the accounts and the time, from the credential.
load_viewer! : {} => Try(
	{
		viewer : Access.Viewer(Topic.At),
		accounts : List(Principal),
		now : I64,
	},
	Chat.Answer,
)
load_viewer! = |{}| {
	asked = Credentials.load_viewer!(ListConversations)?
	Ok({
		viewer: Access.Viewer.over(asked.viewer),
		accounts: asked.accounts,
		now: asked.now,
	})
}

## The channel named, stored.
load_channel! : ChannelName => Try(Channel, Chat.Answer)
load_channel! = |name|
	match Store.load_channel!(name) {
		Ok(c) => Ok(c)
		Err(Missing) => Err(no_such_channel)
		Err(Failed) => Err(Chat.failed)
	}

## The topic at `at`, with its channel and the viewer; one the viewer may
## not read is a 404, as one that is not there (signed out, a 401).
load_read! : Topic.At => Try(Asked, Chat.Answer)
load_read! = |at| {
	v = load_viewer!({})?
	read_by!(v, at)
}

## The topic at `at` for a viewer already loaded, as `load_read!` decides.
read_by! : {
	viewer : Access.Viewer(Topic.At),
	accounts : List(Principal),
	now : I64,
},
Topic.At => Try(Asked, Chat.Answer)
read_by! = |v, at| {
	channel = load_channel!(at.channel)?
	topic =
		match Store.load_topic!(channel, at.topic) {
			Ok(t) => Ok(t)
			Err(Missing) => Err(no_such_topic)
			Err(Failed) => Err(Chat.failed)
		}?
	match topic.read({
		viewer: v.viewer,
		channel,
		accounts: v.accounts,
	}) {
		Permitted => Ok({
			viewer: v.viewer,
			accounts: v.accounts,
			now: v.now,
			channel,
			topic,
		})
		Refused(SignedOut) => Err(not_signed_in)
		Refused(_) => Err(no_such_topic)
	}
}

## **/channels/<channel>/topics, POST**: a member makes a topic (Topic.make
## decides), stored once; `201` and the topic.
make! : ChannelName => Chat.Answer
make! = |name| {
	got = Host.read_body!(Wire.form_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match make_from!(name, got.bytes) {
				Ok(answer) => answer
				Err(answer) => answer
			}
	}
}

make_from! : ChannelName, List(U8) => Try(Chat.Answer, Chat.Answer)
make_from! = |name, form| {
	v = load_viewer!({})?
	channel = load_channel!(name)?
	topics = Store.load_topics!(channel).map_err(|_| Chat.failed)?
	topic_name =
		match SignInWeb.form_field(form, "name") {
			Ok(n) => Str.from_utf8(n) ?? ""
			Err(_) => ""
		}
	kind =
		match SignInWeb.form_field(form, "agents") {
			Err(Missing) => Ok(Human)
			Ok([]) => Ok(Agents([]))
			Ok(text) => text.split_on(',').map_try(
				|id| AccountCodec.id_from(
					id,
					"agents",
				),
			).map_ok(|ids| Agents(ids)).map_err(
				|_| Wire.refused(
					400,
					"agents= is a list of agents' ids, commas between",
				),
			)
			Err(Malformed) => Err(
				Wire.refused(
					400,
					"agents= is a list of agents' ids, commas between",
				),
			)
		}?
	made =
		Topic.make({
			by: v.viewer,
			channel,
			name: topic_name,
			kind,
			topics: topics.topics,
			accounts: v.accounts,
		}).map_err(make_refused)?
	match Store.save_new_topic!(made) {
		Failed => Ok(Chat.failed)
		Taken => Ok(Wire.refused(409, "this channel has a topic of that name, in some spelling"))
		Written => Ok(Wire.json(201, topic_json(made, v.accounts)))
	}
}

## A refused making, said.
make_refused : _ -> Chat.Answer
make_refused = |why|
	match why {
		SignedOut | NoSuchPrincipal => not_signed_in
		NotAHuman => Wire.refused(403, "a topic is a member's to make, by a human")
		NotATopicName => Wire.refused(
			400,
			"a topic's name is letters and digits joined by single hyphens, at most 80",
		)
		OutOfScope => Wire.refused(403, "this key does not reach the new topic")
		NotAMember => Wire.refused(403, "only the channel's members make its topics")
		Taken => Wire.refused(409, "this channel has a topic of that name, in some spelling")
		NoAgents => Wire.refused(400, "an agent topic names one agent or more")
		NamedTwice(_) => Wire.refused(400, "an agent is named twice")
		NotAnAgent(_) => Wire.refused(400, "agents= names agents and bots, not humans")
		NoAccount(_) => Wire.refused(400, "agents= names an agent no account holds")
		NotYours(_) => Wire.refused(403, "a member names only their own agents")
	}

## A topic as the wire spells it.
topic_json : Topic, List(Principal) -> JsonOut
topic_json = |topic, accounts| {
	at = topic.at()
	JsonOut.object([
		("channel", JsonOut.string(at.channel.to_str())),
		("topic", JsonOut.string(at.topic.to_str())),
		(
			"kind",
			JsonOut.string(
				match topic.kind() {
					Human => "human"
					Agents => "agents"
				},
			),
		),
		(
			"agents",
			JsonOut.array(topic.agents(accounts).map(|b| JsonOut.string(AccountCodec.id_text(b.id)))),
		),
	])
}

## **READ**: a page of the topic's messages, the newest or those before
## `?before=`, as a conversation's read pages them.
read! : Topic.At => Chat.Answer
read! = |asked_at|
	match load_read!(asked_at) {
		Err(answer) => answer
		Ok(a) => {
			# Its names as they were made, whatever case the path spelled.
			at = a.topic.at()
			match before_of(Host.read_query!(Str.to_utf8("before"))) {
				Err(Malformed) => Wire.refused(400, "before= is a message's id")
				Ok(before) => {
					files = Store.topic_files(at)
					match Store.load_tally!(files) {
						Err(Failed) => Chat.failed
						Ok(tally) => {
							span = Conversations.page_of(tally.messages, before)
							match Store.load_span!(
								files,
								tally,
								span,
							) {
								Err(Failed) => Chat.failed
								Ok(messages) => {
									who = {
										named: named_of(
											a.topic,
											{ channel: a.channel, accounts: a.accounts },
										),
										accounts: a.accounts,
									}
									Wire.json(
										200,
										JsonOut.object([
											("channel", JsonOut.string(at.channel.to_str())),
											("topic", JsonOut.string(at.topic.to_str())),
											(
												"messages",
												JsonOut.array(
													messages.map(
														|m| message_json(
															at,
															m,
															who,
														),
													),
												),
											),
											("earlier", JsonOut.bool(span.first > 1)),
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

## Where a page ends: before `?before=`'s message, or the newest.
before_of : List(List(U8)) -> Try([Newest, Before(U64)], [Malformed])
before_of = |values|
	match values {
		[] => Ok(Newest)
		[only] => Stored.count(only, "before").map_ok(|n| Before(n)).map_err(|_| Malformed)
		_ => Err(Malformed)
	}

## **POST**: the markdown, as a conversation's post takes it, by one who
## may post in the topic (Topic.post); appended, published to the topic's
## streams and to its agents' one stream, and answered.
post! : Topic.At => Chat.Answer
post! = |at| {
	got = Host.read_body!(Conversations.message_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match load_read!(at) {
				Err(answer) => answer
				Ok(a) =>
					when_posted!(a, got.bytes)
			}
	}
}

when_posted! : Asked, List(U8) => Chat.Answer
when_posted! = |a, body| {
	at = a.topic.at()
	when = a.topic.post({
		viewer: a.viewer,
		channel: a.channel,
		accounts: a.accounts,
	})
	if when != Permitted {
		Wire.refused(403, "you read this topic, but may not post in it")
	} else if Str.from_utf8(body).is_err() {
		Wire.refused(400, "a message is UTF-8 text")
	} else if Md.hostility(body, Conversations.markdown) == TooMuchFormatting {
		Wire.refused(400, Md.too_much_formatting)
	} else {
		by =
			match a.viewer.who() {
				SignedOut => crash "Topics.post!: `load_read!` let nobody signed out through"
				Session(b) | Key(b) => b.id
			}
		files = Store.topic_files(at)
		match Store.load_tally!(files) {
			Err(Failed) => Chat.failed
			Ok(tally) => {
				message = {
					id: MessageCodec.next_id(tally.messages),
					at: a.now,
					by,
					body,
				}
				if tally.bytes + MessageCodec.encode(message).len() > Limits.transcript_bytes_most {
					Wire.refused(413, "this topic is full: its transcript holds as much as one may")
				} else {
					match Store.append_message!({
						files,
						tally,
						message,
					}) {
						Failed => Chat.failed
						Appended => {
							who = {
								named: named_of(
									a.topic,
									{ channel: a.channel, accounts: a.accounts },
								),
								accounts: a.accounts,
							}
							publish!(a.topic, { message, who })
							Wire.json(
								201,
								message_json(
									at,
									message,
									who,
								),
							)
						}
					}
				}
			}
		}
	}
}

## A posted message, to the topic's streams, its pages' (as a bubble)
## and each of its agents' one stream, in the turn it was appended in.
publish! : Topic,
{
	message : MessageCodec.Fields,
	who : { named : List(Mentions.Named), accounts : List(Principal) },
} => {}
publish! = |topic, { message, who }| {
	at = topic.at()
	match frame(
		at,
		message,
		who,
	) {
		Ok(f) => Host.publish!(bus_key(at), f)
		Err(LineBreak) => crash "Topics.publish!: a message's JSON holds no line break"
	}
	Host.publish!(Topics.page_key(at), Topics.page_frame(who.accounts, message))
	match Conversations.agent_event({
		lead: lead_of(at).concat(ref_lead(at, message.id)),
		spot: spot_of(at),
		message,
		who,
	}) {
		Ok(g) => topic.agents(who.accounts).for_each!(
			|b| Host.publish!(
				Conversations.agent_key(b.id),
				g,
			),
		)
		Err(LineBreak) => crash "Topics.publish!: a message's JSON holds no line break"
	}
}

## The bus key a topic's streams are held on: its channel's key and its
## own, as its folder is named.
bus_key : Topic.At -> List(U8)
bus_key = |at| Str.to_utf8("topic/${spot_of(at)}")

## A topic's message as one SSE event, named `message`, its id the
## message's.
frame : Topic.At,
MessageCodec.Fields,
{
	named : List(Mentions.Named),
	accounts : List(Principal),
} -> Try(List(U8), [LineBreak])
frame = |
	at,
	m,
	who,
| Sse.frame({
	name: Str.to_utf8("message"),
	data: message_json(
		at,
		m,
		who,
	).bytes(),
	id: Str.to_utf8(m.id.to_str()),
})

## **STREAM**: the messages after `Last-Event-ID` (at most the newest
## page), then each one posted, live, as a conversation's stream does; a
## browser further behind gets a `gap` first.
stream! : Topic.At => Chat.Answer
stream! = |asked_at|
	match load_read!(asked_at) {
		Err(answer) => answer
		Ok(a) => {
			at = a.topic.at()
			files = Store.topic_files(at)
			match Store.load_tally!(files) {
				Err(Failed) => Chat.failed
				Ok(tally) => {
					after =
						match Host.read_header!(Str.to_utf8("last-event-id")) {
							[only] => Stored.count(only, "last-event-id") ?? 0
							_ => 0
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
					match Store.load_span!(
						files,
						tally,
						{ first, last: tally.messages },
					) {
						Err(Failed) => Chat.failed
						Ok(messages) => {
							who = {
								named: named_of(
									a.topic,
									{ channel: a.channel, accounts: a.accounts },
								),
								accounts: a.accounts,
							}
							gap = if (after > 0 and after + 1 < newest.first) gap_frame(newest.first) else []
							Chat.stream({
								key: bus_key(at),
								backlog: gap.concat(
									List.join(
										messages.keep_oks(
											|m| frame(
												at,
												m,
												who,
											),
										),
									),
								),
								holder: Conversations.holder(a.viewer),
							})
						}
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
		Err(LineBreak) => crash "Topics.gap_frame: a gap's JSON holds no line break"
	}

no_such_channel : Chat.Answer
no_such_channel = Wire.refused(404, "no such channel")

no_such_dm : Chat.Answer
no_such_dm = Wire.refused(404, "no such DM")

no_such_topic : Chat.Answer
no_such_topic = Wire.refused(404, "no such topic")

not_signed_in : Chat.Answer
not_signed_in = Wire.refused(401, "not signed in")

# ── tests
at_of : Str, Str -> Topic.At
at_of = |c, t|
	match at_in(c.to_utf8(), t.to_utf8()) {
		Ok(at) => at
		Err(NotTopics) => crash "at_of: a test's names are names"
	}

expect Topics.route("/channels/Lobby/topics".to_utf8()).is_ok()
expect
	match Topics.route("/channels/Lobby/topics/ChitChat".to_utf8()) {
		Ok(Read(at)) => at == at_of("lobby", "chitchat")
		_ => Bool.False
	}
expect
	match Topics.route("/channels/Lobby/topics/ChitChat/messages".to_utf8()) {
		Ok(Post(_)) => Bool.True
		_ => Bool.False
	}
expect
	match Topics.route("/channels/Lobby/topics/ChitChat/stream".to_utf8()) {
		Ok(Stream(_)) => Bool.True
		_ => Bool.False
	}
expect Topics.route("/channels/Lobby/topics/ChitChat/other".to_utf8()).is_err()
expect Topics.route("/channels/Lobby/topics/chit_chat".to_utf8()).is_err()
expect Topics.route("/channels/Lob.by/topics/x".to_utf8()).is_err()
expect Topics.route("/channels/Lobby/admit".to_utf8()).is_err()
expect Topics.route("/channels/Lobby/topics/".to_utf8()).is_err()
expect ref_text(at_of("Lobby", "ChitChat"), 3) == "MSG_Lobby.ChitChat_3"
expect spot_of(at_of("Lobby", "ChitChat")) == "lobby/chitchat"
expect before_of([]) == Ok(Newest)
expect before_of(["7".to_utf8()]) == Ok(Before(7))
expect before_of(["07".to_utf8()]) == Err(Malformed)
expect before_of(["7".to_utf8(), "8".to_utf8()]) == Err(Malformed)
expect ref_text(
	{ channel: ChannelName.dm_of(1, 2), topic: at_of("Lobby", "ChitChat").topic },
	4,
) == "MSG_ChitChat_4"
expect Topics.route("/channels/dm-1-2/topics".to_utf8()).is_err()
expect Topics.route("/dms".to_utf8()) == Ok(Dms)
expect
	match Topics.route("/dms/7/topics/ChitChat/messages".to_utf8()) {
		Ok(DmPost({ other, topic: _ })) => other.to_u64() == 7
		_ => Bool.False
	}
expect Topics.route("/dms/07/topics".to_utf8()).is_err()
expect Topics.route("/dms/0/topics".to_utf8()).is_err()
expect Topics.route("/dms/human:7/topics".to_utf8()).is_err()

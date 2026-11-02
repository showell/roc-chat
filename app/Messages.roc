## **A MESSAGE ON THE WIRE, AND THE AGENTS' ONE STREAM**: what every
## topic's routes share. A message as the wire spells it (`message_json`,
## `json_led`), the most its markdown may be, which messages a page holds
## (`page_of`), the agents' limit (`check_hops!`), and the agents' one
## stream: where it draws from (`Source`), its bus key, its events, and
## what a resumed one sends first (`backlog!`). A topic's routes (Topics.roc)
## and its pages (TopicPage.roc) ask here; the names, logins and HTML a
## message is drawn with are Render's.
##
## A message is one JSON object:
## `{"id":3,"at":1761600000,"by":"agent:7","kind":"agent","owner":"human:2","login":"showell","markdown":"…","mentions":["human:2"],"html":"…"}`,
## `kind` the poster's (`human`, `agent` or `bot`), `owner` the human an
## agent or a bot answers to (none for a human), `login` the GitHub login
## beside its name (its own, or its owner's), `mentions` the members it
## names (Mentions.of_post), by their names now. A topic's leads with its
## reference, and on the one stream with its channel and topic.
import pf.Chat
import pf.Sse
import md.Md
import Access
import Account
import AgentStream
import Bytes
import Cast
import JsonOut
import Limits
import Mentions
import Transcript
import Principal
import Render
import Store
import Wire

Messages := [].{

	## **WHO A MESSAGE'S JSON IS SPELLED FOR**: its topic's members by their
	## names now (`named`, what a mention finds), and the accounts now
	## (`accounts`, whom a poster answers to).
	Who : { named : List(Mentions.Named), accounts : List(Principal) }

	## **A MESSAGE AS THE WIRE SPELLS IT**: who posted it, of what kind, the
	## human an agent or a bot answers to (`owner_of`), and the GitHub login
	## beside its name (Render.login_of: its own, or its owner's), so a page
	## tells an agent from the human whose name it took; its markdown as
	## posted, the members it names (by their names now), and its html as
	## roc-markdown renders it now. `html` is last: a reader may take it up
	## to the object's closing `"}` (host/e2e.zig does).
	message_json : Transcript.Fields, Messages.Who -> JsonOut
	message_json = |m, who| JsonOut.object(message_fields(m, who))

	## **A MESSAGE'S JSON WITH `lead` FIRST** (a topic's reference, or its
	## channel and name on the one stream), as the wire spells the rest
	## (`message_json`, its html still last): one object, built.
	json_led : {
		lead : List((Str, JsonOut)),
		message : Transcript.Fields,
		who : Messages.Who,
	} -> JsonOut
	json_led = |
		{
			lead,
			message,
			who,
		},
	| JsonOut.object(lead.concat(message_fields(message, who)))

	## The most a message's markdown may be.
	message_most : U64
	message_most = 32 * 1024

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

	## **WHETHER AN AGENT MAY POST NOW** (Limits.agent_hops_per_window),
	## given its topic's transcript `files`: a human always may; an agent or
	## a bot not once the newest page holds that many of its own posts
	## answering agents, within the window (Limits.agent_hops_window_s) and
	## since a human last spoke (Mentions.own_hops). The newest page is read
	## from its first message's offset (Store.load_span!), never the
	## transcript whole. **A PAGE MAY NOT HOLD THE WHOLE WINDOW**: past a
	## page's messages since a human spoke in the hour, the poster's older
	## ones are not counted, so it is held to the cap within the newest page
	## alone.
	check_hops! : {
		files : Store.TranscriptFiles,
		tally : Store.Tally,
		by : Principal.Id,
		named : List(Mentions.Named),
		now : I64,
	} => Try([Room, Full], [Failed])
	check_hops! = |
		{
			files,
			tally,
			by,
			named,
			now,
		},
	|
		match by {
			Human(_) => Ok(Room)
			Agent(_) | Bot(_) => {
				newest = Store.load_span!(
					files,
					tally,
					Messages.page_of(tally.messages, Newest),
				)?
				posts = newest.map(
					|m| {
						at: m.at,
						by: m.by,
						body: m.body,
					},
				)
				asked = {
					poster: by,
					named,
					since: now - Limits.agent_hops_window_s,
				}
				Ok(if (Mentions.own_hops(posts, asked) >= Limits.agent_hops_per_window) Full else Room)
			}
		}

	## **AN AGENT'S POST PAST THE CAP** (`check_hops!`): a 429 that says
	## the rule.
	hops_refused : Chat.Answer
	hops_refused = Wire.refused(
		429,
		"an agent answers agents at most ${Limits.agent_hops_per_window.to_str()} times in ${(Limits.agent_hops_window_s // 60).to_str()} minutes here, counting its own posts since a human last spoke; a human's post resets it",
	)

	## **WHERE AN AGENT'S ONE STREAM DRAWS FROM** (OneStream,
	## AgentStream): a channel's topic. Its spot (as a place writes it), its
	## transcript's files, what its events carry first (`lead`: its channel
	## and name), and whom its messages' JSON is spelled for.
	Source : {
		spot : Str,
		files : Store.TranscriptFiles,
		lead : List((Str, JsonOut)),
		who : Messages.Who,
	}

	## The bus key an agent's or a bot's one stream is held on.
	agent_key : Principal.Id -> List(U8)
	agent_key = |id| Str.to_utf8("agent/${Account.id_text(id)}")

	## **A MESSAGE AS THE ONE STREAM'S EVENT**: named `message`, its data
	## the message's JSON with `lead` first, its id its place
	## (AgentStream: when, its spot, its id).
	agent_event : {
		lead : List((Str, JsonOut)),
		spot : Str,
		message : Transcript.Fields,
		who : Messages.Who,
	} -> Try(List(U8), [LineBreak])
	agent_event = |
		{
			lead,
			spot,
			message: m,
			who,
		},
	| Sse.frame({
		name: Str.to_utf8("message"),
		data: Messages.json_led({
			lead,
			message: m,
			who,
		}).bytes(),
		id: Str.to_utf8(
			AgentStream.id_text({
				at: m.at,
				spot,
				id: m.id,
			}),
		),
	})

	## **WHAT A RESUMED ONE STREAM SENDS FIRST**: nothing when it is live
	## only; else, of each source, its newest page's messages after the
	## cursor (AgentStream.is_after), a `gap` first (`lead` and `before`)
	## for one further behind, all in AgentStream's order.
	backlog! : List(Messages.Source),
	[
		After(AgentStream.Place),
		Live,
	] => Try(List(U8), [Failed])
	backlog! = |sources, cursor|
		match cursor {
			Live => Ok([])
			After(after) => {
				pieces = sources.map_try!(
					|source| {
						tally = Store.load_tally!(source.files)?
						newest = Messages.page_of(tally.messages, Newest)
						messages = Store.load_span!(
							source.files,
							tally,
							newest,
						)?
						place = |m| {
							at: m.at,
							spot: source.spot,
							id: m.id,
						}
						gap =
							match messages.first() {
								Err(_) => NoGap
								Ok(m) => AgentStream.gap_of(
									after,
									{
										spot: source.spot,
										first: m.id,
										first_at: m.at,
									},
								)
							}
						gaps =
							match gap {
								Gap(before) => [
									{
										place: {
											at: after.at,
											spot: source.spot,
											id: 0,
										},
										bytes: lead_gap_frame(source.lead, before),
									},
								]
								NoGap => []
							}
						sent = messages.keep_if(|m| AgentStream.is_after(after, place(m))).keep_oks(
							|m| Messages.agent_event({
								lead: source.lead,
								spot: source.spot,
								message: m,
								who: source.who,
							}).map_ok(|bytes| { place: place(m), bytes }),
						)
						Ok(gaps.concat(sent))
					},
				)?
				Ok(
					pieces.join().sort_with(
						|x, y| AgentStream.before(
							x.place,
							y.place,
						),
					).join_map(|f| f.bytes),
				)
			}
		}

	## Who holds a stream: the viewer's principal id, as the accounts
	## spell it.
	holder : Access.Viewer -> List(U8)
	holder = |viewer|
		match viewer.who() {
			SignedOut => crash "Messages.holder: a stream is held by someone signed in"
			Session(b) | Key(b) => Str.to_utf8(Account.id_text(b.id))
		}
}

## The one stream's `gap` event: the source's (`lead`) messages before
## `before` were not sent.
lead_gap_frame : List((Str, JsonOut)), U64 -> List(U8)
lead_gap_frame = |lead, before|
	match Sse.frame({
		name: Str.to_utf8("gap"),
		data: JsonOut.object(lead.append(("before", JsonOut.number(before)))).bytes(),
		id: [],
	}) {
		Ok(f) => f
		Err(LineBreak) => crash "Messages.lead_gap_frame: a gap's JSON holds no line break"
	}

## The fields `message_json` holds, in its order (`html` last).
message_fields : Transcript.Fields, Messages.Who -> List((Str, JsonOut))
message_fields = |m, who| {
	author = [
		("id", JsonOut.number(m.id)),
		("at", JsonOut.signed(m.at)),
		("by", JsonOut.string(Account.id_text(m.by))),
		("kind", JsonOut.string(Account.kind_text(m.by))),
	].concat(owner_of(who.accounts, m.by)).concat(
		match Render.login_of(who.accounts, m.by) {
			Login(l) => [("login", JsonOut.string(l))]
			NoLogin => []
		},
	)
	mentioned = Mentions.of_post(
		m.body,
		{ by: m.by, participants: who.named },
	).map(|id| JsonOut.string(Account.id_text(id)))
	author.concat([
		("markdown", JsonOut.text(m.body)),
		("mentions", JsonOut.array(mentioned)),
		("html", JsonOut.text(Render.html_of(m))),
	])
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
				Ok(p) => [
					(
						"owner",
						JsonOut.string(Account.id_text(Principal.Id.Human(Principal.answers_to(p)))),
					),
				]
				Err(_) => []
			}
	}

# ── tests
# A message's JSON names its poster's kind, and an agent's or a bot's
# owner, before its markdown; a human's has no owner, nor has an agent no
# account holds now. `html` stays last.
said_by : Principal.Id -> List(U8)
said_by = |by|
	Messages.message_json(
		{
			id: 3,
			at: 5,
			by,
			body: "hi".to_utf8(),
		},
		{ named: [], accounts: Cast.accounts },
	).bytes()

expect said_by(Cast.ann.id()).starts_with("{\"id\":3,\"at\":5,\"by\":\"human:2\",\"kind\":\"human\",\"login\":\"h2\",\"markdown\":\"hi\",".to_utf8())
expect said_by(Cast.ann_agent.id()).starts_with("{\"id\":3,\"at\":5,\"by\":\"agent:3\",\"kind\":\"agent\",\"owner\":\"human:2\",\"login\":\"h2\",\"markdown\":\"hi\",".to_utf8())
expect said_by(Cast.boss_bot.id()).starts_with("{\"id\":3,\"at\":5,\"by\":\"bot:2\",\"kind\":\"bot\",\"owner\":\"human:1\",\"login\":\"h1\",\"markdown\":\"hi\",".to_utf8())
expect said_by(Principal.Id.Agent(Cast.aid(9))).starts_with("{\"id\":3,\"at\":5,\"by\":\"agent:9\",\"kind\":\"agent\",\"markdown\":\"hi\",".to_utf8())
expect Bytes.find(
	said_by(Cast.ann_agent.id()),
	{ needle: ",\"html\":\"".to_utf8(), at: 0 },
).is_ok() and said_by(Cast.ann_agent.id()).ends_with("\"}".to_utf8())

# The JSON carries no login where there is none: Ann made again with her
# login cleared, and her agent named as she is.
expect
	Messages.message_json(
		{
			id: 1,
			at: 2,
			by: Principal.Id.Agent(Cast.aid(8)),
			body: [],
		},
		{
			named: [],
			accounts: [
				Principal.Human({
					id: Cast.hid(2),
					sign_in: Cast.github(2),
					login: "",
					name: "H2",
					role: Member,
					generation: Cast.gen(1),
				}),
				Principal.Agent({
					id: Cast.aid(8),
					name: "H2",
					owner: Cast.hid(2),
					generation: Cast.gen(1),
				}),
			],
		},
	).bytes().starts_with("{\"id\":1,\"at\":2,\"by\":\"agent:8\",\"kind\":\"agent\",\"owner\":\"human:2\",\"markdown\":".to_utf8())

# A topic's message leads with its reference.
expect
	Messages.json_led({
		lead: [("ref", JsonOut.string("MSG_Lobby.ChitChat_3"))],
		message: {
			id: 3,
			at: 5,
			by: Cast.ann.id(),
			body: "hi".to_utf8(),
		},
		who: { named: [], accounts: Cast.accounts },
	}).bytes().starts_with("{\"ref\":\"MSG_Lobby.ChitChat_3\",\"id\":3,\"at\":5,".to_utf8())

# Pages: the newest, back to the first, and past either end.
expect Messages.page_of(0, Newest) == { first: 1, last: 0 }
expect Messages.page_of(5, Newest) == { first: 1, last: 5 }
expect Messages.page_of(250, Newest) == { first: 151, last: 250 }
expect Messages.page_of(250, Before(151)) == { first: 51, last: 150 }
expect Messages.page_of(250, Before(51)) == { first: 1, last: 50 }
expect Messages.page_of(250, Before(1)) == { first: 1, last: 0 }
expect Messages.page_of(250, Before(900)) == { first: 151, last: 250 }

# The chat's uploads rule: an upload's image renders; one of the chat's own
# routes, as a src, is text.
expect {
	src = "/chat/dm/7_11/ChitChat/uploads/${Str.repeat("a", 32)}.png"
	html = rendered_text("<img src=\"${src}\">")
	Str.contains(html, "<img src=\"${src}\">")
}
expect {
	src = "/chat/channel/Lobby/ChitChat/uploads/${Str.repeat("a", 32)}.png"
	Str.contains(rendered_text("<img src=\"${src}\">"), "<img src=\"${src}\">")
}
expect !Str.contains(rendered_text("<img src=\"/chat/uploads/lobby/chitchat/${Str.repeat("a", 32)}.png\">"), "<img")
expect {
	html = rendered_text("<img src=\"/user_uploads/a.png\">")
	!Str.contains(html, "<img")
}
expect {
	html = rendered_text("<img src=\"/channels/Lobby/topics/ChitChat/stream\">")
	!Str.contains(html, "<img")
}

## A message's markdown as the chat renders it, as text (the tests').
rendered_text : Str -> Str
rendered_text = |markdown| {
	html = Md.render(markdown.to_utf8(), Render.markdown)
	Str.from_utf8(html) ?? ""
}

## **WHAT A TOPIC'S PAGE IS SENT** (MessageRef.Where): where its
## transcript is kept, the bus key its pages are held on, each post as the
## bubble every page puts in, and an edit's original drawn again. A topic's
## posts (Topics.roc) publish here, and its page (TopicPage.roc) reads
## here.
import pf.Host
import pf.Sse
import AccountCodec
import Bubble
import Cast
import Edits
import Transcript
import MessageRef
import Principal
import Recent
import Store

PageFeed := [].{

	## **THE BUS KEY OF A READER'S RECENT** (RecentPage.roc): a topic's post
	## publishes each reader's tile, drawn for them, on theirs.
	recent_key : Principal.Id -> List(U8)
	recent_key = |reader| Str.to_utf8("recent/${AccountCodec.id_text(reader)}")

	## A Recent tile as one SSE event, named `message`.
	recent_frame : Recent.Row -> List(U8)
	recent_frame = |row|
		match Sse.frame({
			name: Str.to_utf8("message"),
			data: Bubble.data(Recent.tile(row)),
			id: [],
		}) {
			Ok(f) => f
			Err(LineBreak) => crash "PageFeed.recent_frame: Bubble.data holds no CR, and the name no line break"
		}

	## Its transcript's files.
	files : MessageRef.Where -> Store.TranscriptFiles
	files = |place|
		match place {
			InTopic(at) => Store.topic_files(at)
		}

	## **ITS SPOT**, as its keys and its events name it: a topic's
	## channel's key and its own, `<channel>/<topic>`.
	spot : MessageRef.Where -> Str
	spot = |place|
		match place {
			InTopic(at) => "${at.channel.key()}/${at.topic.key()}"
		}

	## **THE BUS KEY ITS PAGES ARE HELD ON**, beside its streams': each
	## post's bubble, published once for every page that shows it.
	page_key : MessageRef.Where -> List(U8)
	page_key = |place|
		match place {
			InTopic(_) => Str.to_utf8("topic-page/${PageFeed.spot(place)}")
		}

	## **A BUBBLE AS ONE SSE EVENT**, named `message`, its id the message's,
	## as a page's stream and a post's publish both write it.
	frame : MessageRef.Where,
	{
		accounts : List(Principal),
		m : Transcript.Fields,
	} -> List(U8)
	frame = |place, { accounts, m }|
		match Sse.frame({
			name: Str.to_utf8("message"),
			data: Bubble.data(
				Bubble.of(
					accounts,
					{
						m,
						ref: MessageRef.local(place, m.id),
						edited: NotEdited,
						# Every page's, and new: on no one's list yet, and no reaction.
						reactions: [],
					},
				),
			),
			id: Str.to_utf8(m.id.to_str()),
		}) {
			Ok(f) => f
			Err(LineBreak) => crash "PageFeed.frame: Bubble.data holds no CR, and the name and id no line break"
		}

	## **WHETHER A MESSAGE IS SUPERSEDED**, among `edits` (Edits.superseded
	## over the messages from it on): the edit that names it, with its
	## reference, or none.
	edited_of : MessageRef.Where,
	{
		edits : Edits.Supersession,
		n : U64,
	} -> [NotEdited, EditedIn({ id : U64, ref : Str })]
	edited_of = |place, { edits, n }|
		match Edits.edit_of(edits, n) {
			EditedIn(e) => EditedIn({ id: e, ref: MessageRef.spelled(place, e) })
			NotEdited => NotEdited
		}

	## **AN EDIT, ON A PAGE** (Edits.roc): when `message` edits an earlier
	## one of the same author's, that one's bubble drawn again, superseded,
	## as an `edit` event (no id: it resumes nothing) the page puts in its
	## place; or nothing, for a message that edits nothing, edits another's,
	## or whose original does not read. A post publishes it after its own
	## bubble, and a stream's backlog sends it after each edit it resends.
	edit_frame! : MessageRef.Where,
	{
		message : Transcript.Fields,
		accounts : List(Principal),
	} => List(U8)
	edit_frame! = |place, { message, accounts }|
		match Edits.target(place, message.body) {
			Err(NotAnEdit) => []
			Ok(t) => {
				kept = PageFeed.files(place)
				original =
					match Store.load_tally!(kept) {
						Err(Failed) => Err(Failed)
						Ok(tally) => Store.load_span!(
							kept,
							tally,
							{ first: t, last: t },
						).map_err(|_| Failed)
					}
				match original {
					Ok([o]) if Edits.supersedes({ original: o, edit: message }) => {
						edited = EditedIn({ id: message.id, ref: MessageRef.spelled(place, message.id) })
						html = Bubble.data(
							Bubble.of(
								accounts,
								{
									m: o,
									ref: MessageRef.local(place, o.id),
									edited,
									# Every page's: the edit frame's body is all a page takes.
									reactions: [],
								},
							),
						)
						match Sse.frame({
							name: Str.to_utf8("edit"),
							data: html,
							id: [],
						}) {
							Ok(f) => f
							Err(LineBreak) => crash "PageFeed.edit_frame!: Bubble.data holds no CR"
						}
					}
					_ => []
				}
			}
		}

	## **A POST, TO ITS PAGES**: its bubble, then, for an edit by its
	## original's author, the original redrawn, on every page that shows
	## it, in the turn it was appended in.
	publish! : MessageRef.Where,
	{
		message : Transcript.Fields,
		accounts : List(Principal),
	} => {}
	publish! = |place, { message, accounts }| {
		Host.publish!(PageFeed.page_key(place), PageFeed.frame(place, { accounts, m: message }))
		edit = PageFeed.edit_frame!(place, { message, accounts })
		if (!edit.is_empty()) Host.publish!(PageFeed.page_key(place), edit) else {}
	}
}

# ── tests
lobby : MessageRef.Where
lobby = InTopic((MessageRef.from_str("MSG_Lobby.Chat_1") ?? crash "lobby: a reference").at())

# A topic's pages are held by its spot, each topic's apart.
expect PageFeed.page_key(lobby) == "topic-page/lobby/chat".to_utf8()
expect PageFeed.page_key(InTopic((MessageRef.from_str("MSG_Lobby.Chats_1") ?? crash "a reference").at())) != PageFeed.page_key(lobby)

## A message by Ann, number 3.
hi : Transcript.Fields
hi = {
	id: 3,
	at: 0,
	by: Cast.ann.id(),
	body: "hi".to_utf8(),
}

# A topic's bubble: its page's id, and its quote-reply link.
expect {
	f = Str.from_utf8(PageFeed.frame(lobby, { accounts: [], m: hi })) ?? ""
	f.contains("data-ref=\"Chat_3\" ") and f.contains("class=msg-quote")
}

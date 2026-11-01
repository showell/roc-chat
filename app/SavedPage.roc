## **THE READING LIST**, `GET /chat/saved`: the viewer's saves, newest
## first (ReadingList.roc), in place of the old app's `reading-list` Docs
## doc, whose blocks this draws as they were (angry-gopher's
## reading_list.zig `composeEntry`): the note as a heading; who wrote it,
## when, and "↩ open in chat", the topic's page at the message; then the
## body as it was, shown literally (the old block's `~~~ quote` fence kept
## it inert). The old doc was edited to annotate and delete; here each save
## has its own two forms:
##
##     POST /chat/saved/<id>/note      its note changed (`note=`), then a
##                                     303 back to it
##     POST /chat/saved/<id>/delete    it removed, then a 303 back to the list
##
## A save is the saver's own copy: it stays when its topic is closed to
## them, as the old doc's blocks did. A page is a browser's: signed out, a
## 303 to `/login` (the forms, a 401); a key, a 403. Its script
## (js/saved_page.js) writes each time in the viewer's zone and styles it.
## **A LIST THAT DOES NOT READ BACK** is said, a 500 in words, and never
## read as empty: a write would lose what is there.
import pf.Chat
import pf.Host
import Bubble
import ChannelName
import Chrome
import Conversations
import Html
import Pages
import Principal
import ReadingList
import SavedCodec
import SignInWeb
import Store
import Stored
import Topic
import Topics
import Wire

SavedPage := [].{

	## **WHY A SAVE OR A NOTE IS REFUSED**, in words: the list's page and
	## the topic page's save say the same, and the page's popup shows it.
	refused : [
		NotUtf8,
		TooBig,
		Unreadable,
	] -> Chat.Answer
	refused = |why|
		match why {
			NotUtf8 => Wire.refused(400, "a note is UTF-8 text")
			TooBig => Wire.refused(
				413,
				"your reading list is full (${ReadingList.most_bytes.to_str()} bytes): remove some saves first",
			)
			# Said, never read as an empty list: a write would lose it.
			Unreadable => Wire.refused(
				500,
				"your reading list does not read back, so it is left as it is; nothing was changed",
			)
		}

	## **THE VIEWER'S READING LIST, OR WHY NOT**: one that does not read back
	## is said (`refused`), and nothing writes over it.
	load_for! : Principal.HumanId => Try(SavedCodec.Book, Chat.Answer)
	load_for! = |human|
		match Store.load_saved!(human) {
			Ok(book) => Ok(book)
			Err(Failed) => Err(Chat.failed)
			Err(Unreadable) => Err(SavedPage.refused(Unreadable))
		}

	## What a path asks of the reading list.
	Route : [
		Page,
		Note(U64),
		Delete(U64),
	]

	## The route a path names, if it names one.
	route : List(U8) -> Try(SavedPage.Route, [NotSaved])
	route = |path|
		if path == "/chat/saved".to_utf8() {
			Ok(Page)
		} else {
			match path.split_on('/') {
				[
					[],
					chat,
					saved,
					id,
					what,
				] if chat == "chat".to_utf8() and saved == "saved".to_utf8() =>
					match Stored.count(id, "id") {
						Ok(n) if n > 0 and what == "note".to_utf8() => Ok(Note(n))
						Ok(n) if n > 0 and what == "delete".to_utf8() => Ok(Delete(n))
						_ => Err(NotSaved)
					}
				_ => Err(NotSaved)
			}
		}

	## **ANSWER IT**: the page to a GET or a HEAD; a form, a POST, its body
	## read first.
	answer! : Chat.Request, SavedPage.Route => Chat.Answer
	answer! = |req, r|
		match r {
			Page =>
				if req.method != Get and req.method != Head {
					Chat.not_allowed(Get)
				} else {
					match serve!({
						path: req.path,
						route: r,
						form: [],
					}) {
						Ok(answer) => answer
						Err(answer) => answer
					}
				}
			Note(_) | Delete(_) =>
				if req.method != Post {
					Chat.not_allowed(Post)
				} else {
					got = Host.read_body!(Wire.form_most)
					match got.status {
						Answered => Chat.answered
						Read =>
							match serve!({
								path: req.path,
								route: r,
								form: got.bytes,
							}) {
								Ok(answer) => answer
								Err(answer) => answer
							}
					}
				}
		}
}

serve! : {
	path : List(U8),
	route : SavedPage.Route,
	form : List(U8),
} => Try(Chat.Answer, Chat.Answer)
serve! = |
	{
		path,
		route,
		form,
	},
| {
	v = Topics.load_viewer!({})?
	me =
		match v.viewer.who() {
			SignedOut =>
				match route {
					Page => Err(Pages.to_login(path))
					Note(_) | Delete(_) => Err(Wire.refused(401, "not signed in"))
				}
			Key(_) => Err(Pages.key_refused)
			Session(b) => Ok(b)
		}?
	human =
		match me.id {
			Human(h) => Ok(h)
			_ => Err(Pages.key_refused)
		}?
	list = SavedPage.load_for!(human)?
	match route {
		Page => Ok(
			page({
				list,
				me: human,
				viewer: Conversations.name_of(v.accounts, me.id),
			}),
		)
		Delete(id) => {
			next = ReadingList.without(list, id).map_err(|NoSuchSave| no_such_save)?
			write_back!(human, { list: next, back: "/chat/saved" })
		}
		Note(id) => {
			raw =
				match SignInWeb.form_field(form, "note") {
					Ok(bytes) => Ok(bytes)
					Err(Missing) => Ok([])
					Err(Malformed) => Err(Wire.refused(400, "note= is not a form's value"))
				}?
			note = ReadingList.note_of(raw).map_err(|NotUtf8| SavedPage.refused(NotUtf8))?
			next =
				match ReadingList.renoted(list, { id, note }) {
					Ok(book) => Ok(book)
					Err(NoSuchSave) => Err(no_such_save)
					Err(TooBig) => Err(SavedPage.refused(TooBig))
				}?
			write_back!(human, { list: next, back: "/chat/saved#saved-${id.to_str()}" })
		}
	}
}

## **WRITE THE LIST BACK**, then a 303 to `back`.
write_back! : Principal.HumanId,
{
	list : SavedCodec.Book,
	back : Str,
} => Try(Chat.Answer, Chat.Answer)
write_back! = |human, { list, back }|
	match Store.save_saved!(human, list) {
		Failed => Err(Chat.failed)
		Written => Ok(
			Chat.respond(303, { content_type: Chat.text, body: [] })
				|> Chat.with_header("location", back.to_utf8()),
		)
	}

no_such_save : Chat.Answer
no_such_save = Wire.refused(404, "no such save on your reading list")

## **THE PAGE**: each save, newest first, or the empty list said.
page : {
	list : SavedCodec.Book,
	me : Principal.HumanId,
	viewer : Str,
} -> Chat.Answer
page = |
	{
		list,
		me,
		viewer,
	},
| {
	saves = ReadingList.newest_first(list)
	Chrome.page({
		title: Html.markup("Saved"),
		viewer: Html.text(viewer),
		here: Saved,
		kind: Plain,
		body_attrs: Html.markup(" class=saved-page"),
		body: Html.join([
			Html.markup("<div class=chat-notify id=chat-notify></div>\n<h2 class=saved-title>Reading list</h2>\n<div id=saved-list>\n"),
			Html.join(
				saves.map(
					|e| entry({
						e,
						me,
					}),
				),
			),
			Html.markup("</div>\n"),
			if (saves.is_empty()) Html.markup("<p id=saved-empty class=muted>Nothing saved yet. Press s on a message, or its “save”, to keep it here.</p>\n") else Html.join([]),
			Html.markup("<script src=\"/saved_page.js\"></script>\n"),
		]),
	})
}

## **ONE SAVE**, the old block's parts: the note, who and when and the way
## back, the body as it was; then its two forms.
entry : {
	e : SavedCodec.Fields,
	me : Principal.HumanId,
} -> Html
entry = |
	{
		e,
		me,
	},
| {
	Html.join([
		Html.markup("<article class=saved-entry id=saved-"),
		Html.number(e.id),
		Html.markup("><h3 class=saved-note>"),
		Html.text(e.note),
		Html.markup("</h3><div class=saved-meta>"),
		# The author's name as it was when saved, as the old block froze it.
		Html.text(e.from),
		Html.markup(" · <time class=saved-time datetime="),
		Html.markup(Bubble.iso(e.at)),
		Html.markup(" data-at="),
		Html.signed(e.at),
		Html.markup(">"),
		Html.text(Bubble.fallback(e.at)),
		Html.markup("</time> · <a class=saved-open href=\""),
		Html.text(
			way_back({
				place: e.place,
				n: e.n,
				me,
			}),
		),
		Html.markup("\">↩ open in chat</a></div><div class=saved-body>"),
		Html.escape(e.body),
		Html.markup("</div><form class=saved-renote method=post action=\"/chat/saved/"),
		Html.number(e.id),
		Html.markup("/note\"><input name=note value=\""),
		Html.text(e.note),
		Html.markup("\" aria-label=\"Note\"> <button>Change note</button></form><form class=saved-delete method=post action=\"/chat/saved/"),
		Html.number(e.id),
		Html.markup("/delete\"><button>Remove</button></form></article>\n"),
	])
}

## **THE WAY BACK** (the old `jumpURL`, built from the place the save
## kept, never searched for): the topic's page at the message. A DM's page
## is named by its other member, for the saver.
way_back : {
	place : Topic.At,
	n : U64,
	me : Principal.HumanId,
} -> Str
way_back = |
	{
		place,
		n,
		me,
	},
| {
	anchor = "#msg-${n.to_str()}"
	match dm_other(place.channel, me) {
		Ok(other) => "${Topics.page_path(place, InDm(other))}${anchor}"
		Err(NotADm) => "${Topics.page_path(place, InChannel)}${anchor}"
	}
}

## **A DM'S OTHER MEMBER, FOR `me`**: the name `dm-<a>-<b>` read back, and
## only when ChannelName.dm_of spells it so.
dm_other : ChannelName, Principal.HumanId -> Try(Principal.HumanId, [NotADm])
dm_other = |name, me|
	if !name.is_dm() {
		Err(NotADm)
	} else {
		match name.to_str().split_on("-") {
			[
				_,
				a,
				b,
			] =>
				match (U64.from_str(a), U64.from_str(b)) {
					(Ok(x), Ok(y)) if ChannelName.dm_of(x, y) == name => {
						other = if (x == me.to_u64()) y else x
						Principal.HumanId.from_u64(other).map_err(|_| NotADm)
					}
					_ => Err(NotADm)
				}
			_ => Err(NotADm)
		}
	}

# ── tests
human_of : U64 -> Principal.HumanId
human_of = |n| Principal.HumanId.from_u64(n) ?? crash "human_of: a test's id is not 0"

name_of : Str -> ChannelName
name_of = |text| ChannelName.from_str(text) ?? crash "name_of: a test's name is a name"

expect SavedPage.route("/chat/saved".to_utf8()) == Ok(Page)
expect SavedPage.route("/chat/saved/3/note".to_utf8()) == Ok(Note(3))
expect SavedPage.route("/chat/saved/12/delete".to_utf8()) == Ok(Delete(12))
expect SavedPage.route("/chat/saved/0/delete".to_utf8()) == Err(NotSaved)
expect SavedPage.route("/chat/saved/03/delete".to_utf8()) == Err(NotSaved)
expect SavedPage.route("/chat/saved/3/other".to_utf8()) == Err(NotSaved)
expect SavedPage.route("/chat/saved/".to_utf8()) == Err(NotSaved)

# A DM's other member, for either of the two; a channel is none.
expect dm_other(ChannelName.dm_of(2, 7), human_of(2)) == Ok(human_of(7))
expect dm_other(ChannelName.dm_of(2, 7), human_of(7)) == Ok(human_of(2))
expect dm_other(name_of("Orchard"), human_of(2)) == Err(NotADm)
expect dm_other(name_of("dm-07-2"), human_of(2)) == Err(NotADm)

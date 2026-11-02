## **THE EDGE**: the app's two entries, and what stands in at the edge
## until it exists.
##
## - `page` (the demo, host/demo.zig): a topic's name and its transcript in,
##   its page out. The host's bytes become unchecked text
##   (`UnvalidatedString`), then a Conversation or a refusal's tags
##   (`TranscriptRefusal` puts them in words).
## - `handle_http_request!` (the server, host/http.zig): a request in, its
##   response out. `Route` chooses the answer; `ConversationRoute` gives it.
##
## **TWO STAND-INS, BOTH HERE AT THE EDGE**: the directory, until one is
## stored (`directory`), and who is acting, until sessions exist
## (`acting`, which is dangerous).
app [handle_http_request!, page] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import pf.Host
import pf.Http
import Admin
import ChannelName
import Conversation
import ConversationRoute
import Directory
import HttpAnswer
import Name
import Page
import Route
import SignedIn
import Topic
import TranscriptRefusal
import UnvalidatedString
import Users

## The page for `topic`'s transcript, or a page saying what is wrong with it.
page : List(U8), List(U8) -> List(U8)
page = |topic, transcript| {
	answer =
		match conversation({ topic, transcript }) {
			Ok(c) => Page.conversation(c)
			Err(why) => Page.refusal(TranscriptRefusal.words(why))
		}
	answer.to_utf8()
}

## The conversation the host's bytes hold, decoded at the door.
conversation : { topic : List(U8), transcript : List(U8) } -> Try(Conversation, _)
conversation = |{ topic, transcript }| {
	name = UnvalidatedString.from_utf8(topic) ? |NotUtf8| TopicNotUtf8
	text = UnvalidatedString.from_utf8(transcript) ? |NotUtf8| TranscriptNotUtf8
	checked = name.topic() ? |why| Topic(why)
	text.conversation(checked).map_err(|why| Transcript(why))
}

## **ONE REQUEST, ANSWERED**: the route chosen, then answered, the host's
## clock read once, for a POST.
handle_http_request! : Http.Request => Http.Response
handle_http_request! = |request|
	match Route.choose({
		method: request.method,
		path: request.path,
		directory,
	}) {
		ShowConversation(key) => ConversationRoute.show!(key)
		AppendToConversation(key) =>
			ConversationRoute.append!({
				key,
				acting,
				now: Host.current_utc_seconds_since_epoch!({}),
				body: request.body,
			})
		MethodNotAllowed => HttpAnswer.method_not_allowed
		NotFound => HttpAnswer.notice(404, { title: "Not found", said: "Nothing is here." })
	}

## **STEVE (ID 1), TAKEN AS SIGNED IN WITH NOTHING CHECKED: THE SCARY
## DOOR.** No sessions exist yet, so every request acts as Steve: anyone
## who can reach the server can post as him. That is why the host listens
## on 127.0.0.1 alone (host/http.zig). Sessions replace this.
acting : SignedIn
acting = SignedIn.dangerously_assume(steve)

## Steve, the directory's founder, always id 1.
steve : Users.User
steve = Directory.founded_by(founder_name).users().to_list().first() ?? crash "main.steve: a directory starts with its founder"

founder_name : Name
founder_name = Name.from_str("Steve") ?? crash "main.founder_name: Steve is a name"

## **THE DIRECTORY UNTIL ONE IS STORED**: Steve (id 1), a human, and one
## channel, `general`, which he created as its admin. So the DM `1_1`
## (Steve's own) and the channel `general` are the places a URL can name.
directory : Directory
directory = {
	founded = Directory.founded_by(founder_name)
	admin = Admin.of(acting) ?? crash "main.directory: Steve, id 1, is an admin"
	general = ChannelName.from_str("general") ?? crash "main.directory: general is a channel's name"
	(founded.create_channel({ by: admin, name: general }) ?? crash "main.directory: the name general is free").directory
}

# ── tests
plans : Topic
plans = Topic.from_str("plans") ?? crash "main's tests: a topic's name"

expect conversation({ topic: "plans".to_utf8(), transcript: [] }) == Ok(Conversation.empty(plans))
expect conversation({ topic: [0xff], transcript: [] }) == Err(TopicNotUtf8)
expect conversation({ topic: "plans".to_utf8(), transcript: [0xff] }) == Err(TranscriptNotUtf8)
# Each refusal of the topic, and of the transcript, through the door.
expect conversation({ topic: "".to_utf8(), transcript: [] }) == Err(Topic(Empty))
expect conversation({ topic: "1a".to_utf8(), transcript: [] }) == Err(Topic(StartsWithNonLetter))
expect conversation({ topic: "a".repeat(61).to_utf8(), transcript: [] }) == Err(Topic(TooLong))
expect conversation({ topic: "a b".to_utf8(), transcript: [] }) == Err(Topic(ForbiddenByte))
expect conversation({
	topic: "plans".to_utf8(),
	transcript: "\n".to_utf8(),
}) == Err(Transcript(BadEnds))
# The order: the topic's bytes, the transcript's, then the topic's name.
expect conversation({ topic: [0xff], transcript: [0xff] }) == Err(TopicNotUtf8)
expect conversation({ topic: "".to_utf8(), transcript: [0xff] }) == Err(TranscriptNotUtf8)
expect conversation({ topic: "".to_utf8(), transcript: "\n".to_utf8() }) == Err(Topic(Empty))
# The page, through the host's bytes: a conversation's, or the refusal's.
expect page(
	"plans".to_utf8(),
	[],
) == Page.conversation(Conversation.empty(plans)).to_utf8()
expect page("<b>".to_utf8(), [0xff]) == Page.refusal("it is not UTF-8").to_utf8()

## The page a GET of `path` shows, as a test reads it.
shown : Str -> Str
shown = |path|
	match Route.choose({
		method: "GET".to_utf8(),
		path: path.to_utf8(),
		directory,
	}) {
		ShowConversation(key) => key.url_path()
		_ => "not found"
	}

# The stand-ins: Steve, id 1, acting; the directory's places.
expect acting.user().name() == founder_name and acting.user().id().to_str() == "1"
expect
	[
		"/chat/channel/general/plans",
		"/chat/dm/1_1/plans",
		"/chat/channel/other/plans",
		"/chat/dm/1_2/plans",
	].map(shown)
		== [
			"/chat/channel/general/plans",
			"/chat/dm/1_1/plans",
			"not found",
			"not found",
		]

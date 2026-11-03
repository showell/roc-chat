## **THE EDGE**: the app's two entries, and what stands in at the edge
## until it exists.
##
## - `page` (the demo, host/demo.zig): a conversation's URL path and its
##   transcript in, its page out, as the server would show it. The path's
##   bytes become unchecked text (`UnvalidatedString`), then a
##   `ConversationKey` found in the directory; the transcript's an unchecked
##   file (`Transcript.Utf8Transcript`), then a Conversation; or a refusal's
##   tags (`TranscriptRefusal` puts them in words).
## - `handle_http_request!` (the server, host/http.zig): a request in, its
##   response out. `Route` chooses the answer; `ConversationRoute` gives
##   it, or `UploadRoute` for an uploaded image.
##   A conversation's stream is held by the signed-in user (`acting`).
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
import ComposeScript
import Conversation
import ConversationKey
import ConversationRoute
import Directory
import HttpAnswer
import Name
import Page
import RequestOrigin
import Route
import SignedIn
import Topic
import Transcript
import TranscriptRefusal
import UnvalidatedString
import UploadRoute
import Users

## The page of the conversation at the URL path `path`, from its
## transcript, or a page saying what is wrong with either.
page : List(U8), List(U8) -> List(U8)
page = |path, transcript| {
	answer =
		match conversation({ path, transcript }) {
			Ok(found) => Page.conversation(found.conversation, found.key)
			Err(why) => Page.refusal(TranscriptRefusal.words(why))
		}
	answer.to_utf8()
}

## The conversation the host's bytes hold, decoded at the door: the URL
## path read as a conversation's key in `directory`, then the transcript
## file's bytes, by `Transcript.decode` under the key's topic.
conversation : { path : List(U8), transcript : List(U8) } -> Try({ conversation : Conversation, key : ConversationKey }, _)
conversation = |{ path, transcript }| {
	unchecked = UnvalidatedString.from_utf8(path) ? |NotUtf8| PathNotUtf8
	key = ConversationKey.from_url_path({ path: unchecked, directory }) ? |why| Path(why)
	decoded = Transcript.decode(key.topic(), Transcript.Utf8Transcript.unchecked_from_file(transcript))?
	Ok({ conversation: decoded, key })
}

## **ONE REQUEST, ANSWERED**: held first to this server's own origin
## (`RequestOrigin`, a trust boundary: a 403 when it comes from elsewhere),
## then the route chosen and answered, the host's clock read once, for a
## POST.
handle_http_request! : Http.Request => Http.Response
handle_http_request! = |request|
	match RequestOrigin.check({
		method: request.method,
		headers: request.headers,
		port: request.port,
	}) {
		Err(why) => HttpAnswer.notice(403, { title: "Forbidden", said: RequestOrigin.words(why) })
		Ok({}) =>
			match Route.choose({
				method: request.method,
				path: request.path,
				directory,
			}) {
				ShowConversation(key) => ConversationRoute.show!(key)
				OpenConversationStream(key) =>
					ConversationRoute.open_stream!({
						key,
						acting,
						query: request.query,
						headers: request.headers,
					})
				ServeComposeScript => HttpAnswer.script(ComposeScript.bytes)
				AppendToConversation(key) =>
					ConversationRoute.post_sent_message!({
						key,
						acting,
						now: Host.current_utc_seconds_since_epoch!({}),
						body: request.body,
					})
				UploadToConversation(key) =>
					UploadRoute.post_upload!({
						key,
						acting,
						headers: request.headers,
						body: request.body,
					})
				ServeUploadedImage(found) => UploadRoute.serve_uploaded_image!(found)
				MethodNotAllowed(allowed) => HttpAnswer.method_not_allowed(allowed)
				NotFound => HttpAnswer.notice(404, { title: "Not found", said: "Nothing is here." })
			}
	}

## **STEVE (ID 1), TAKEN AS SIGNED IN WITH NOTHING CHECKED: THE SCARY
## DOOR.** No sessions exist yet, so every request acts as Steve: anyone
## who can reach the server can post as him. That is why the host listens
## on 127.0.0.1 alone (host/http.zig), and why every request is held to
## this server's own origin first (`RequestOrigin`), so no other site's
## page can act through a browser here. Sessions replace this.
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

## What the door finds at `path` with `transcript`, as a test reads it:
## the conversation, and its key's URL path.
found_at : List(U8), List(U8) -> Try((Conversation, Str), _)
found_at = |path, transcript| conversation({ path, transcript }).map_ok(|found| (found.conversation, found.key.url_path()))

expect found_at("/chat/channel/general/plans".to_utf8(), []) == Ok((Conversation.empty(plans), "/chat/channel/general/plans"))
expect found_at("/chat/dm/1_1/plans".to_utf8(), []) == Ok((Conversation.empty(plans), "/chat/dm/1_1/plans"))
expect found_at([0xff], []) == Err(PathNotUtf8)
expect found_at("/chat/dm/1_1/plans".to_utf8(), [0xff]) == Err(TranscriptNotUtf8)
# Each refusal of the path, and of the transcript, through the door.
expect found_at("plans".to_utf8(), []) == Err(Path(NotAConversationPath))
expect found_at("/chat/channel/general/plans_2".to_utf8(), []) == Err(Path(BadName))
expect found_at("/chat/channel/other/plans".to_utf8(), []) == Err(Path(NoSuchChannel))
expect found_at("/chat/dm/1_2/plans".to_utf8(), []) == Err(Path(NoSuchHuman))
expect found_at("/chat/dm/1_1/plans".to_utf8(), "\n".to_utf8()) == Err(Transcript(NotPrefixedProperly))
# The order: the path's bytes, the path's conversation, then the transcript.
expect found_at([0xff], [0xff]) == Err(PathNotUtf8)
expect found_at("plans".to_utf8(), [0xff]) == Err(Path(NotAConversationPath))
expect found_at("plans".to_utf8(), "\n".to_utf8()) == Err(Path(NotAConversationPath))
# The page, through the host's bytes: a conversation's, posting to its own
# path, or the refusal's.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8()) ?? crash "main's tests: a path is UTF-8",
		directory,
	}) ?? crash "main's tests: Steve's own DM is a place"
	page("/chat/dm/1_1/plans".to_utf8(), []) == Page.conversation(Conversation.empty(plans), key).to_utf8()
}
expect page("/chat/dm/1_1/plans".to_utf8(), [0xff]) == Page.refusal("it is not UTF-8").to_utf8()
expect page("<b>".to_utf8(), [0xff]) == Page.refusal("its path is not a conversation's, /chat/channel/<channel>/<topic> or /chat/dm/<pair>/<topic>").to_utf8()

## The page a GET of `path` shows, as a test reads it.
shown : Str -> Str
shown = |path|
	match Route.choose({
		method: "GET".to_utf8(),
		path: path.to_utf8(),
		directory,
	}) {
		ShowConversation(key) => key.url_path()
		OpenConversationStream(key) => "the stream of ${key.url_path()}"
		ServeUploadedImage(found) => "the image ${found.image.name()} of ${found.key.url_path()}"
		_ => "not found"
	}

# The stand-ins: Steve, id 1, acting; the directory's places.
expect acting.user().name() == founder_name and acting.user().id().to_str() == "1"
expect shown("/chat/channel/general/plans") == "/chat/channel/general/plans"
expect shown("/chat/dm/1_1/plans") == "/chat/dm/1_1/plans"
expect shown("/chat/channel/other/plans") == "not found"
expect shown("/chat/dm/1_2/plans") == "not found"
expect shown("/chat/dm/1_1/plans/stream") == "the stream of /chat/dm/1_1/plans"
expect shown("/chat/dm/1_2/plans/stream") == "not found"
expect shown("/chat/channel/general/plans/uploads/${"0".repeat(32)}.png") == "the image ${"0".repeat(32)}.png of /chat/channel/general/plans"
expect shown("/chat/dm/1_2/plans/uploads/${"0".repeat(32)}.png") == "not found"

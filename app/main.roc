## This module is the app's edge. It holds the app's three entries, and
## what stands in at the edge until the real thing exists.
##
## - `page` (the demo, host/demo.zig): a conversation's URL path and its
##   transcript in, its page out, as the server would show it. The path's
##   bytes become unchecked text (`UnvalidatedString`), then a
##   `ConversationKey` found in the directory; the transcript's an unchecked
##   file (`Transcript.Utf8Transcript`), then a Conversation; or a refusal's
##   tags (`TranscriptRefusal` puts them in words).
## - `admission` (the server, host/http.zig): a request's head in, before
##   the host reads any body; out comes a refusal, or how large a body to
##   read and how long to wait for it.
## - `handle_http_request!` (the server): a request in, its response out.
##   `Route` chooses the answer; `ConversationRoute` gives it, or
##   `UploadRoute` for an uploaded image, or a script the pages load. A
##   conversation's stream is held by the signed-in user (`acting`).
##
## Two things stand in here: the directory, until one is stored
## (`directory`), and who is acting, until sessions exist (`acting`, which
## is dangerous).
app [
	admission,
	handle_http_request!,
	page,
] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import pf.Host
import pf.Http
import Admin
import ChannelName
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
import UploadedImage
import Users

## The page of the conversation at the URL path `path`, from its
## transcript, or a page saying what is wrong with either.
page : List(U8), List(U8) -> List(U8)
page = |path, transcript| {
	answer =
		match conversation({ path, transcript }) {
			Ok(found) =>
				Page.conversation({
					conversation: found.conversation,
					key: found.key,
					viewer: acting,
					users: directory.users(),
				})
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
	found = ConversationKey.from_url_path({ path: unchecked, directory }) ? |why| Path(why)
	decoded = Transcript.decode(found.key.topic(), Transcript.Utf8Transcript.unchecked_from_file(transcript))?
	Ok({ conversation: decoded, key: found.key })
}

## What the host may do with a request, judged from its head alone. A
## request from elsewhere (`RequestOrigin`, a trust boundary) is refused
## with a 403, so the host never reads its body. Any other is admitted,
## with room for an upload's body when its route is an upload, and for a
## form's otherwise.
admission : Http.RequestHead -> Http.Admission
admission = |head|
	match RequestOrigin.check({
		method: head.method,
		headers: head.headers,
		port: head.port,
	}) {
		Err(why) => Refuse(for_this_origin_alone(origin_refusal(why)))
		Ok({}) =>
			match Route.choose({
				method: head.method,
				path: head.path,
				directory,
			}) {
				UploadToConversation(_) => Admit(upload_body_allowance)
				_ => Admit(form_body_allowance)
			}
	}

## The body a form may have: a message as the compose box posts it, 64 KiB
## with room to spare, read within the request's own time.
form_body_allowance : { body_most : U64, body_grace_ms : U32 }
form_body_allowance = { body_most: 64 * 1024, body_grace_ms: 0 }

## The body an upload may have: an image at its largest
## (`UploadedImage.most_bytes`), with 64 KiB for the multipart form around
## it. It has five minutes more to arrive, the compose box's patience for
## a large image on a slow link.
upload_body_allowance : { body_most : U64, body_grace_ms : U32 }
upload_body_allowance = { body_most: UploadedImage.most_bytes + 64 * 1024, body_grace_ms: 5 * 60 * 1000 }

## One request, answered: held to this server's own origin, then the route
## chosen and answered, the host's clock read once, for a POST. The host
## asks `admission` first, so a request from elsewhere is refused before
## its body is read; the check here holds the answer to its origin even
## when a host does not ask.
handle_http_request! : Http.Request => Http.Response
handle_http_request! = |request| {
	answer =
		match RequestOrigin.check({
			method: request.method,
			headers: request.headers,
			port: request.port,
		}) {
			Err(why) => origin_refusal(why)
			Ok({}) => serve_route!(request)
		}
	for_this_origin_alone(answer)
}

## The 403 for a request from elsewhere, saying why.
origin_refusal : RequestOrigin.Refusal -> Http.Response
origin_refusal = |why| HttpAnswer.page(403, Page.notice({ title: "Forbidden", said: RequestOrigin.words(why) }))

## `answer`, which no other site's page may load: a browser refuses to hand
## a page elsewhere any answer of this server's (`Cross-Origin-Resource-Policy`),
## an image, a script or a stream included.
for_this_origin_alone : Http.Response -> Http.Response
for_this_origin_alone = |answer| {
	..answer,
	headers: answer.headers.append({ name: "cross-origin-resource-policy".to_utf8(), value: "same-origin".to_utf8() }),
}

## The answer the route of `request` gives.
serve_route! : Http.Request => Http.Response
serve_route! = |request|
	match Route.choose({
		method: request.method,
		path: request.path,
		directory,
	}) {
		ShowConversation(key) =>
			ConversationRoute.show!({
				key,
				acting,
				users: directory.users(),
			})
		OpenConversationStream(key) =>
			ConversationRoute.open_stream!({
				key,
				acting,
				users: directory.users(),
				query: request.query,
				headers: request.headers,
			})
		ServeScript(script) => HttpAnswer.script(script.bytes())
		AppendToConversation(key) =>
			ConversationRoute.post_sent_message!({
				key,
				acting,
				users: directory.users(),
				now: Host.current_utc_seconds_since_epoch!({}),
				body: request.body,
			})
		SendToConversation(key) =>
			ConversationRoute.post_message_without_reload!({
				key,
				acting,
				users: directory.users(),
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
		NotFound => HttpAnswer.page(404, Page.notice({ title: "Not found", said: "Nothing is here." }))
	}

## Steve (id 1), taken as signed in with nothing checked: the scary door.
## No sessions exist yet, so every request acts as Steve: anyone
## who can reach the server can post as him. That is why the host listens
## on 127.0.0.1 alone (host/http.zig), and why every request is held to
## this server's own origin first (`RequestOrigin`), so no other site's
## page can act through a browser here. Sessions replace this.
acting : SignedIn
acting = SignedIn.dangerously_assume(steve)

## Steve, the directory's founder, always id 1.
steve : Users.User
steve = Directory.with_founder(founder_name).users().to_list().first() ?? crash "main.steve: a directory starts with its founder"

founder_name : Name
founder_name = Name.from_str("Steve") ?? crash "main.founder_name: Steve is a name"

## The directory, until one is stored: Steve (id 1), a human, and one
## channel, `general`, which he created as its admin. So the DM `1_1`
## (Steve's own) and the channel `general` are the places a URL can name.
directory : Directory
directory = {
	founded = Directory.with_founder(founder_name)
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
found_at = |path, transcript| conversation({ path, transcript }).map_ok(|found| (found.conversation, found.key.url_path(Page)))

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
	}).map_ok(|found| found.key) ?? crash "main's tests: Steve's own DM is a place"
	page("/chat/dm/1_1/plans".to_utf8(), [])
		== Page.conversation({
			conversation: Conversation.empty(plans),
			key,
			viewer: acting,
			users: directory.users(),
		}).to_utf8()
}
expect page("/chat/dm/1_1/plans".to_utf8(), [0xff]) == Page.refusal("it is not UTF-8").to_utf8()
expect page("<b>".to_utf8(), [0xff]) == Page.refusal("its path is not a conversation's, /chat/channel/<channel>/<topic> or /chat/dm/<pair>/<topic>").to_utf8()

## The page a GET of `path` shows, as a test reads it.
page_for_get : Str -> Str
page_for_get = |path|
	match Route.choose({
		method: "GET".to_utf8(),
		path: path.to_utf8(),
		directory,
	}) {
		ShowConversation(key) => key.url_path(Page)
		OpenConversationStream(key) => "the stream of ${key.url_path(Page)}"
		ServeUploadedImage(found) => "the image ${found.image.name()} of ${found.key.url_path(Page)}"
		_ => "not found"
	}

# The stand-ins: Steve, id 1, acting; the directory's places.
expect acting.user().name() == founder_name and acting.user().id().to_str() == "1"
expect page_for_get("/chat/channel/general/plans") == "/chat/channel/general/plans"
expect page_for_get("/chat/dm/1_1/plans") == "/chat/dm/1_1/plans"
expect page_for_get("/chat/channel/other/plans") == "not found"
expect page_for_get("/chat/dm/1_2/plans") == "not found"
expect page_for_get("/chat/dm/1_1/plans/stream") == "the stream of /chat/dm/1_1/plans"
expect page_for_get("/chat/dm/1_2/plans/stream") == "not found"
expect page_for_get("/chat/channel/general/plans/uploads/${"0".repeat(32)}.png") == "the image ${"0".repeat(32)}.png of /chat/channel/general/plans"
expect page_for_get("/chat/dm/1_2/plans/uploads/${"0".repeat(32)}.png") == "not found"

## The head of a request whose request line is `line` (`POST /a`), its Host
## this server's at port 9611, with `more` headers (name, value).
head_of : Str, List((Str, Str)) -> Http.RequestHead
head_of = |line, more| {
	(method, path) =
		match line.split_on(" ") {
			[m, p] => (m, p)
			_ => crash "main's tests: a request line is a method and a path"
		}
	{
		method: method.to_utf8(),
		path: path.to_utf8(),
		headers: [("Host", "localhost:9611")].concat(more).map(|(name, value)| { name: name.to_utf8(), value: value.to_utf8() }),
		port: 9611,
	}
}

## What `admission` makes of `head`, as a test reads it: the allowance it
## admits it with, or its refusal's status and headers.
admission_verdict : Http.RequestHead -> [Admitted({ body_most : U64, body_grace_ms : U32 }), Refused(U16, List((Str, Str)))]
admission_verdict = |head|
	match admission(head) {
		Admit(allowance) => Admitted(allowance)
		Refuse(answer) => Refused(answer.status, answer.headers.map(|h| (Str.from_utf8_lossy(h.name), Str.from_utf8_lossy(h.value))))
	}

# The allowances: a form's 64 KiB in the request's own time; an upload's
# image at its largest and 64 KiB of form, with five minutes more.
expect form_body_allowance == { body_most: 65_536, body_grace_ms: 0 }
expect upload_body_allowance == { body_most: 10_551_296, body_grace_ms: 300_000 }
# Admitted from its head: a routed upload with an upload's room, from curl
# or this server's own page; any other request with a form's, a path ending
# `/upload` that is no conversation's, or an upload's path by GET or PUT,
# included.
expect
	[
		head_of("POST /chat/dm/1_1/plans/upload", []),
		head_of("POST /chat/channel/general/plans/upload", [("Origin", "http://localhost:9611"), ("Sec-Fetch-Site", "same-origin")]),
	].all(|head| admission_verdict(head) == Admitted(upload_body_allowance))
expect
	[
		head_of("POST /chat/dm/1_1/plans", []),
		head_of("POST /x/upload", []),
		head_of("POST /chat/dm/1_2/plans/upload", []),
		head_of("GET /chat/dm/1_1/plans/upload", []),
		head_of("PUT /chat/dm/1_1/plans/upload", []),
		head_of("GET /chat/dm/1_1/plans/stream", [("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "navigate")]),
	].all(|head| admission_verdict(head) == Admitted(form_body_allowance))
# Refused from its head, whatever its route: a 403 that no other site's page
# may load.
## The headers of the 403 a request from elsewhere is refused with.
forbidden_headers : List((Str, Str))
forbidden_headers = [
	("content-type", "text/html; charset=utf-8"),
	("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'self'; img-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; connect-src 'self'"),
	("x-content-type-options", "nosniff"),
	("cross-origin-resource-policy", "same-origin"),
]

## An EventSource's headers, from another site's page.
event_source_elsewhere : List((Str, Str))
event_source_elsewhere = [
	("Origin", "http://evil.example"),
	("Sec-Fetch-Site", "cross-site"),
	("Sec-Fetch-Mode", "cors"),
]

expect
	[
		head_of("POST /chat/dm/1_1/plans/upload", [("Origin", "http://evil.example")]),
		head_of("POST /chat/dm/1_1/plans/upload", [("Sec-Fetch-Site", "cross-site")]),
		head_of("GET /chat/dm/1_1/plans/stream", event_source_elsewhere),
		head_of("GET /chat/dm/1_1/plans/stream", [("Sec-Fetch-Site", "same-site"), ("Sec-Fetch-Mode", "no-cors")]),
		{ ..head_of("POST /chat/dm/1_1/plans/upload", []), port: 9612 },
	].all(|head| admission_verdict(head) == Refused(403, forbidden_headers))
# Every answer ends with its resource policy, after its own headers.
expect
	for_this_origin_alone(HttpAnswer.see_other("/a")).headers
		== [
			{ name: "location".to_utf8(), value: "/a".to_utf8() },
			{ name: "cross-origin-resource-policy".to_utf8(), value: "same-origin".to_utf8() },
		]

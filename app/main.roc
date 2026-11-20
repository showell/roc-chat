## This module is the app's edge. It holds the app's five entries, each of
## them wiring together the modules that do the work.
##
## - `page` (the demo, host/demo.zig): a conversation's URL path and its
##   transcript in, its page out, as the server would show it to the
##   founder at the first start (`FirstStart`). The path's bytes become
##   unchecked text (`UnvalidatedString`), then a `ConversationKey` found in
##   the directory; the transcript's an unchecked file
##   (`Transcript.Utf8Transcript`), then a Conversation; or a refusal's tags
##   (`TranscriptRefusal` puts them in words). Its sidebar lists the
##   founder's places with no topic but the one shown (`demo_sidebar`), as
##   the sample's data folder holds them.
## - `start!` (the server, host/http.zig, once, before it listens): when the
##   data folder holds no chat yet, the founder, Steve, id 1, is made, with
##   the channel `general`, of which he is the one member
##   (`FirstStart`). A folder that holds a chat is read, and one that
##   holds part of one is refused, so the server never starts on it.
## - `check_request_head!` (the server): a request's head in, before the
##   host reads any body; out comes a refusal, or how large a body to read
##   and how long to wait for it. Only someone signed in who may post in a
##   conversation gets an upload's room there (`Admission`).
## - `handle_http_request!` (the server): a request in, its response out.
##   The directory is read from disk (`DirectoryStore`), who is acting is
##   found (`Actor`), and `Dispatch` answers: `Route` chooses the route,
##   `Access` decides whether the actor may read or post in a conversation,
##   and `ConversationRoute`, `UploadRoute`, `BrowseRoute`, `AgentsRoute`,
##   `ChannelMembersRoute`, `HumanInvitesRoute`, `SignInRoute` or
##   `GitHubRoute` gives the answer.
## - `password_verdict` (`roc-chat hash-password`, host/main.zig): a line
##   in, and whether it is a password the sign-in form takes, so the
##   command hashes none that could never sign in.
##
## Who is acting is found from the request alone (`Actor`): a request
## with an `Authorization` header by that header alone, as the agent its
## key admits, or a 401; any other by its session cookie, as the human the
## session admits (`SignInRoute.sign_in_by_session!`), or else as no one
## (`Anonymous`). A request that proves no one may use only the routes
## `Route` says are open (the way in at `/`, the scripts, the icon, signing in and out,
## by a password or GitHub, signing up by GitHub, redeeming an agent's invite,
## and joining by a human's); any other
## page sends it to
## sign in, and any other request is a 401. Only the first start, which
## makes Steve before anyone can sign in, and the demo's page take him as
## signed in with nothing checked (`SignedIn.dangerously_assume`); no request
## does.
app [check_request_head!, handle_http_request!, page, password_verdict, start!] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
	sc: "../../roc-syntax-color/package/main.roc",
}

import pf.Http
import Actor
import Admission
import Browse
import Conversation
import ConversationKey
import ConversationPage
import DirectoryStore
import Dispatch
import FirstStart
import PageKit
import Reactions
import RequestOrigin
import SignedIn
import Topic
import Transcript
import TranscriptRefusal
import UnvalidatedString
import UserId

## The page of the conversation at the URL path `path`, from its
## transcript, or a page saying what is wrong with either.
page : List(U8), List(U8) -> List(U8)
page = |path, transcript| {
	answer =
		match conversation({ path, transcript }) {
			Ok(found) =>
				ConversationPage.conversation({
					conversation: found.conversation,
					reactions: Reactions.empty,
					key: found.key,
					viewer: demo_viewer,
					users: FirstStart.first_directory.users(),
					sidebar: demo_sidebar,
				})
			Err(why) => PageKit.refusal(TranscriptRefusal.words(why))
		}
	answer.to_utf8()
}

## The conversation the host's bytes hold, decoded at the door: the URL
## path read as a conversation's key in `FirstStart.first_directory`, then the
## transcript file's bytes, by `Transcript.decode` under the key's topic.
conversation : { path : List(U8), transcript : List(U8) } -> Try(
	{ conversation : Conversation, key : ConversationKey },
	_,
)
conversation = |{ path, transcript }| {
	unchecked = UnvalidatedString.from_utf8(path) ? |NotUtf8| PathNotUtf8
	found = ConversationKey.from_url_path({
		path: unchecked,
		directory: FirstStart.first_directory,
	}) ? |why| Path(why)
	decoded = Transcript.decode(
		found.key.topic(),
		Transcript.Utf8Transcript.unchecked_from_file(transcript),
	)?
	Ok({ conversation: decoded, key: found.key })
}

## Whether `bytes` are a password the sign-in form takes, read as the form
## reads one (`UnvalidatedString`, then `Password`): `Accepted`, or else
## `Refused`.
password_verdict : List(U8) -> [Accepted, Refused]
password_verdict = |bytes|
	match UnvalidatedString.from_utf8(bytes) {
		Err(NotUtf8) => Refused
		Ok(text) =>
			match text.password() {
				Ok(_) => Accepted
				Err(NotAPassword) => Refused
			}
	}

## The demo's viewer: the founder, as the first start makes him.
demo_viewer : SignedIn
demo_viewer = SignedIn.dangerously_assume(FirstStart.first_directory.chat_owner().user())

## The demo's sidebar: the founder's places at the first start, each with
## no topics of its own, so the page's own topic is its place's one, and
## none with a message, so `SidebarOrder` puts the page's place first and
## the rest in Browse's order, collapsed.
demo_sidebar : ConversationPage.SidebarShown
demo_sidebar = {
	listed =
		Browse.places_for({ acting: demo_viewer, directory: FirstStart.first_directory })
			?? crash "main.demo_sidebar: the founder browses by a session"
	Sidebar({
		places: listed.map(|{ label, place }| { label, place, topics: [] }),
		online_humans: [],
		notice: NoNotice,
	})
}

## Whether the server may start on its data folder: `Ready` when the folder
## holds a whole chat, or held none and now holds the first
## (`DirectoryStore`, `FirstStart`); else `Failed`, and the host stops.
start! : {} => [Failed, Ready]
start! = |{}| DirectoryStore.prepare_directory!({})

## What the host may do with a request, judged from its head alone. A
## request from elsewhere (`RequestOrigin`, a trust boundary) is refused
## with a 403 before anything is read, so the host never reads its body.
## Then the directory is read and who is acting is found, as for the whole
## request (`Actor`): a credential refused is its 401 here, and a
## directory that can't be read its 500. Any other is judged by
## `Admission.admission_in`.
check_request_head! : Http.RequestHead => Http.Admission
check_request_head! = |head|
	match RequestOrigin.check(Admission.origin_of_head(head)) {
		Err(why) => Admission.head_refusal(Admission.origin_refusal(why))
		Ok({}) =>
			match DirectoryStore.load_directory!({}) {
				Err(why) => Admission.head_refusal(DirectoryStore.directory_refusal(why))
				Ok(directory) =>
					match Actor.load_actor!({ headers: head.headers, directory }) {
						Err(why) => Admission.head_refusal(Actor.identity_refusal(why))
						Ok(actor) => Admission.admission_in({ head, directory, actor })
					}
			}
	}

## One request, answered: held to this server's own origin, then the
## directory read, who is acting found, and the route chosen and answered.
## The host asks `check_request_head!` first, so a request from elsewhere is refused
## before its body is read; the check here holds the answer to its origin
## even when a host does not ask.
handle_http_request! : Http.Request => Http.Response
handle_http_request! = |request| {
	answer =
		match RequestOrigin.check({
			method: request.method,
			headers: request.headers,
			port: request.port,
			public_origin: request.public_origin,
		}) {
			Err(why) => Admission.origin_refusal(why)
			Ok({}) =>
				match DirectoryStore.load_directory!({}) {
					Err(why) => DirectoryStore.directory_refusal(why)
					Ok(directory) =>
						match Actor.load_actor!({ headers: request.headers, directory }) {
							Err(why) => Actor.identity_refusal(why)
							Ok(actor) => Dispatch.serve_route!({ request, directory, actor })
						}
				}
		}
	Admission.with_same_origin_resource_policy(answer)
}

# ── tests
plans : Topic
plans = Topic.from_str("plans") ?? crash "main's tests: a topic's name"

## What the door finds at `path` with `transcript`, as a test reads it:
## the conversation, and its key's URL path.
found_at : { path : List(U8), transcript : List(U8) } -> Try((Conversation, Str), _)
found_at = |held| conversation(held).map_ok(|found| (found.conversation, found.key.url_path(Page)))

expect found_at({ path: "/chat/channel/general/plans".to_utf8(), transcript: [] }) == Ok((
	Conversation.empty(plans),
	"/chat/channel/general/plans",
))
expect found_at({ path: "/chat/dm/1_1/plans".to_utf8(), transcript: [] }) == Ok((
	Conversation.empty(plans),
	"/chat/dm/1_1/plans",
))
expect found_at({ path: [0xff], transcript: [] }) == Err(PathNotUtf8)
expect found_at({
	path: "/chat/dm/1_1/plans".to_utf8(),
	transcript: [0xff],
}) == Err(TranscriptNotUtf8)
# Each refusal of the path, and of the transcript, through the door.
expect found_at({ path: "plans".to_utf8(), transcript: [] }) == Err(Path(NotAConversationPath))
expect found_at({
	path: "/chat/channel/general/plans_2".to_utf8(),
	transcript: [],
}) == Err(Path(BadName))
expect found_at({
	path: "/chat/channel/other/plans".to_utf8(),
	transcript: [],
}) == Err(Path(NoSuchChannel))
expect found_at({ path: "/chat/dm/1_2/plans".to_utf8(), transcript: [] }) == Err(Path(NoSuchHuman))
expect found_at({
	path: "/chat/dm/1_1/plans".to_utf8(),
	transcript: "\n".to_utf8(),
}) == Err(Transcript(NotPrefixedProperly))
# The order: the path's bytes, the path's conversation, then the transcript.
expect found_at({ path: [0xff], transcript: [0xff] }) == Err(PathNotUtf8)
expect found_at({ path: "plans".to_utf8(), transcript: [0xff] }) == Err(Path(NotAConversationPath))
expect found_at({
	path: "plans".to_utf8(),
	transcript: "\n".to_utf8(),
}) == Err(Path(NotAConversationPath))
# The page, through the host's bytes: a conversation's, posting to its own
# path, or the refusal's.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
			?? crash "main's tests: a path is UTF-8",
		directory: FirstStart.first_directory,
	}).map_ok(|found| found.key) ?? crash "main's tests: Steve's own DM is a place"
	page("/chat/dm/1_1/plans".to_utf8(), [])
		== ConversationPage.conversation({
			conversation: Conversation.empty(plans),
			reactions: Reactions.empty,
			key,
			viewer: demo_viewer,
			users: FirstStart.first_directory.users(),
			sidebar: demo_sidebar,
		}).to_utf8()
}
expect page("/chat/dm/1_1/plans".to_utf8(), [0xff]) == PageKit.refusal("it is not UTF-8").to_utf8()
expect page("<b>".to_utf8(), [0xff])
	== PageKit.refusal("its path is not a conversation's, /chat/channel/<channel>/<topic> or /chat/dm/<pair>/<topic>")
		.to_utf8()

# The demo's viewer is the first start's Steve, id 1.
expect
	demo_viewer.user().name() == FirstStart.founder_name
		and demo_viewer.user().id() == UserId.chat_owner

# A line `hash-password` reads is a password as the sign-in form's is: 1 to
# 72 bytes of UTF-8, at the edges and just past them.
expect
	[
		"hunter2",
		"x",
		"x".repeat(72),
		"é".repeat(36),
	].all(|text| password_verdict(text.to_utf8()) == Accepted)
expect
	[
		[],
		"x".repeat(73).to_utf8(),
		"é".repeat(37).to_utf8(),
		[0xff],
		"hunter".to_utf8().append(0xc3),
	].all(|bytes| password_verdict(bytes) == Refused)

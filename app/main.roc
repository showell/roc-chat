## This module is the app's edge. It holds the app's five entries.
##
## - `page` (the demo, host/demo.zig): a conversation's URL path and its
##   transcript in, its page out, as the server would show it to the
##   founder at the first start (`FirstStart`). The path's bytes become
##   unchecked text (`UnvalidatedString`), then a `ConversationKey` found in
##   the directory; the transcript's an unchecked file
##   (`Transcript.Utf8Transcript`), then a Conversation; or a refusal's tags
##   (`TranscriptRefusal` puts them in words).
## - `start!` (the server, host/http.zig, once, before it listens): when the
##   data folder holds no chat yet, the founder, Steve, id 1, is made, with
##   the channel `general`, of which he is the one member
##   (`FirstStart`). A folder that holds a chat is read, and one that
##   holds part of one is refused, so the server never starts on it.
## - `check_request_head!` (the server): a request's head in, before the
##   host reads any body; out comes a refusal, or how large a body to read
##   and how long to wait for it. Only someone signed in who may post in a
##   conversation gets an upload's room there (`body_allowance`).
## - `handle_http_request!` (the server): a request in, its response out.
##   The directory is read from disk (`DirectoryStore`), who is acting is
##   found (`load_actor!`), `Route` chooses the answer, `Access` decides
##   whether the actor may read or post in a conversation, and
##   `ConversationRoute`, `UploadRoute`, `BrowseRoute`, `AgentsRoute`,
##   `ChannelMembersRoute`, `HumanInvitesRoute`, `SignInRoute` or
##   `GitHubRoute` gives the answer.
## - `password_verdict` (`roc-chat hash-password`, host/main.zig): a line
##   in, and whether it is a password the sign-in form takes, so the
##   command hashes none that could never sign in.
##
## Who is acting is found from the request alone (`load_actor!`): a request
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
}

import Timestamp
import pf.Host
import pf.Http
import Access
import Admission
import AgentsRoute
import BrowseRoute
import ChannelMembersRoute
import Conversation
import ConversationKey
import ConversationRoute
import Directory
import DirectoryStore
import Favicon
import FileSystem
import FirstStart
import GitHubRoute
import HumanInvitesRoute
import Html
import HttpAnswer
import Page
import Place
import RequestHeader
import RequestOrigin
import Route
import SignInRoute
import SignedIn
import Topic
import Transcript
import TranscriptRefusal
import UnvalidatedString
import UploadRoute
import UploadedImage
import UserId

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
					viewer: demo_viewer,
					users: FirstStart.first_directory.users(),
				})
			Err(why) => Page.refusal(TranscriptRefusal.words(why))
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

## Whether the server may start on its data folder: `Ready` when the folder
## holds a whole chat, or held none and now holds the first
## (`DirectoryStore`, `FirstStart`); else `Failed`, and the host stops.
start! : {} => [Failed, Ready]
start! = |{}| DirectoryStore.prepare_directory!({})

## The moment the host's clock says it is.
read_clock! : {} => Timestamp
read_clock! = |{}| Timestamp.at_second(Host.current_utc_seconds_since_epoch!({}))

## What the host may do with a request, judged from its head alone. A
## request from elsewhere (`RequestOrigin`, a trust boundary) is refused
## with a 403 before anything is read, so the host never reads its body.
## Then the directory is read and who is acting is found, as for the whole
## request (`load_actor!`): a credential refused is its 401 here, and a
## directory that can't be read its 500. Any other is judged by
## `Admission.admission_in`.
check_request_head! : Http.RequestHead => Http.Admission
check_request_head! = |head|
	match RequestOrigin.check(Admission.origin_of_head(head)) {
		Err(why) => Refuse(Admission.with_same_origin_resource_policy(Admission.origin_refusal(why)))
		Ok({}) =>
			match DirectoryStore.load_directory!({}) {
				Err(why) => Refuse(Admission.with_same_origin_resource_policy(DirectoryStore.directory_refusal(why)))
				Ok(directory) =>
					match load_actor!({ headers: head.headers, directory }) {
						Err(why) => Refuse(Admission.with_same_origin_resource_policy(identity_refusal(why)))
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
						match load_actor!({ headers: request.headers, directory }) {
							Err(why) => identity_refusal(why)
							Ok(actor) => serve_route!({ request, directory, actor })
						}
				}
		}
	Admission.with_same_origin_resource_policy(answer)
}

## Who is acting. With `Authorization: Bearer <id>-<secret>`, the agent its
## key admits (`AgentsRoute.sign_in_by_key!`); any other `Authorization` is
## refused, and a request with one is never judged by its cookie, so a key
## refused never falls back to a session. With none, the human the session
## cookie admits (`load_session_actor!`), or no one.
load_actor! : { headers : List(Http.Header), directory : Directory } => Try(
	SignedIn.Actor,
	[BadBearer, KeyRefused, FileSystem(FileSystem.Fault)],
)
load_actor! = |{ headers, directory }| {
	now = read_clock!({})
	match RequestHeader.header_value(headers, "authorization") {
		Unsent => load_session_actor!({ headers, directory, now })
		Repeated => Err(BadBearer)
		Sent(value) => {
			bearer_text = UnvalidatedString.from_utf8(value) ? |NotUtf8| BadBearer
			token = bearer_text.bearer_token() ? |NotABearer| BadBearer
			signed_in_by_key = AgentsRoute.sign_in_by_key!({ token, directory, now })?
			Ok(SignedIn(signed_in_by_key))
		}
	}
}

## Who a request with no `Authorization` header is: the human its session
## cookie admits at `now`, or no one (`Anonymous`) when it carries none, or
## one that admits no one. Only a sign-in file that can't be read fails the
## request.
load_session_actor! : {
	headers : List(Http.Header),
	directory : Directory,
	now : Timestamp,
} => Try(SignedIn.Actor, [FileSystem(FileSystem.Fault)])
load_session_actor! = |{ headers, directory, now }|
	match RequestHeader.header_value(headers, "cookie") {
		Unsent => Ok(Anonymous)
		Repeated => Ok(Anonymous)
		Sent(cookie) =>
			match SignInRoute.sign_in_by_session!({ cookie, users: directory.users(), now }) {
				Ok(signed_in_by_session) => Ok(SignedIn(signed_in_by_session))
				Err(NoSession) => Ok(Anonymous)
				Err(BadSession) => Ok(Anonymous)
				Err(SessionRefused) => Ok(Anonymous)
				Err(NoMaterial) => Ok(Anonymous)
				Err(FileSystem(fault)) => Err(FileSystem(fault))
			}
	}

## A request whose credential is refused: one 401 that says no more, or a
## 500 when the keys can't be read.
identity_refusal : [BadBearer, KeyRefused, FileSystem(FileSystem.Fault)] -> Http.Response
identity_refusal = |why|
	match why {
		BadBearer => HttpAnswer.text(401, key_refusal_words)
		KeyRefused => HttpAnswer.text(401, key_refusal_words)
		FileSystem(fault) => HttpAnswer.text(500, FileSystem.fault_words(fault))
	}

key_refusal_words : Str
key_refusal_words =
	"The API key is not accepted: send Authorization: Bearer <id>-<secret>, a live key."

## What a route asks of `Access` before it is answered: to read or post at
## a place, or nothing.
access_asked : Route.SignedInChoice -> [
	Asks({ place : Place, act : Access.Act }),
	AsksNoConversation,
]
access_asked = |asked|
	match asked {
		ShowConversation(key) => Asks({ place: key.place(), act: Read })
		OpenConversationStream(key) => Asks({ place: key.place(), act: Read })
		ServeRawTranscript(key) => Asks({ place: key.place(), act: Read })
		ServeUploadedImage(found) => Asks({ place: found.key.place(), act: Read })
		AppendToConversation(key) => Asks({ place: key.place(), act: Post })
		SendToConversation(key) => Asks({ place: key.place(), act: Post })
		UploadToConversation(key) => Asks({ place: key.place(), act: Post })
		StartTopic(place) => Asks({ place, act: Post })
		StartGitHubLink => AsksNoConversation
		ShowBrowse => AsksNoConversation
		ShowAgents => AsksNoConversation
		MakeAgent => AsksNoConversation
		InviteAgent(_) => AsksNoConversation
		RevokeInvite(_) => AsksNoConversation
		RevokeKey(_) => AsksNoConversation
		OpenAgentStream => AsksNoConversation
		ShowChannels => AsksNoConversation
		CreateChannel => AsksNoConversation
		ShowChannelMembers(_) => AsksNoConversation
		AddChannelMember(_) => AsksNoConversation
		RemoveChannelMember(_) => AsksNoConversation
		ShowInvites => AsksNoConversation
		InviteHuman => AsksNoConversation
		InviteHumanAgain(_) => AsksNoConversation
	}

## The 403 for a reader or a writer the place doesn't admit.
access_refusal : [NotAMember, ScopeOff] -> Http.Response
access_refusal = |why| {
	said =
		match why {
			NotAMember =>
				"Only the members of this conversation's channel or DM may read or post in it."
			ScopeOff => "This API key's scope doesn't reach that."
		}
	HttpAnswer.page(403, Page.notice({ title: "Forbidden", text: said }))
}

## The answer to a route only someone signed in may use, asked for by no
## one: a page sends the browser to sign in, and comes back after; any
## other request is a 401.
anonymous_refusal : Route.SignedInChoice -> Http.Response
anonymous_refusal = |asked|
	match asked {
		StartGitHubLink => unauthorized_refusal
		ShowBrowse => SignInRoute.login_redirect(site_path_of(ConversationKey.browse_path))
		StartTopic(_) => unauthorized_refusal
		ShowConversation(key) => SignInRoute.login_redirect(site_path_of(key.url_path(Page)))
		ShowAgents => SignInRoute.login_redirect(site_path_of("/agents"))
		ShowChannels => SignInRoute.login_redirect(site_path_of("/channels"))
		ShowChannelMembers(channel) =>
			SignInRoute.login_redirect(site_path_of("/channels/${channel.to_str()}"))
		CreateChannel => unauthorized_refusal
		AddChannelMember(_) => unauthorized_refusal
		RemoveChannelMember(_) => unauthorized_refusal
		ShowInvites => SignInRoute.login_redirect(site_path_of(Page.invites_path))
		InviteHuman => unauthorized_refusal
		InviteHumanAgain(_) => unauthorized_refusal
		AppendToConversation(_) => unauthorized_refusal
		SendToConversation(_) => unauthorized_refusal
		OpenConversationStream(_) => unauthorized_refusal
		ServeRawTranscript(_) => unauthorized_refusal
		UploadToConversation(_) => unauthorized_refusal
		ServeUploadedImage(_) => unauthorized_refusal
		MakeAgent => unauthorized_refusal
		InviteAgent(_) => unauthorized_refusal
		RevokeInvite(_) => unauthorized_refusal
		RevokeKey(_) => unauthorized_refusal
		OpenAgentStream => unauthorized_refusal
	}

## The 401 for a request that proves no one, at a route only someone
## signed in may use.
unauthorized_refusal : Http.Response
unauthorized_refusal = HttpAnswer.text(401, unauthorized_words)

unauthorized_words : Str
unauthorized_words =
	"No one is signed in: sign in at /login, or send Authorization: Bearer <id>-<secret>, a live key."

## The site path `text` spells, a path this server answers: one that isn't
## is a bug in its writer.
site_path_of : Str -> Html.SitePath
site_path_of = |text|
	Html.SitePath.from_str(text)
		?? crash "main.site_path_of: \"${text}\" is a path this server answers, and not a site path"

## The answer the route of `request` gives `actor`: an open route's to
## anyone; any other's to someone signed in alone, once `Access` admits
## them.
serve_route! : {
	request : Http.Request,
	directory : Directory,
	actor : SignedIn.Actor,
} => Http.Response
serve_route! = |{ request, directory, actor }|
	match Route.choose({ method: request.method, path: request.path, directory }) {
		Open(open) => answer_open_route!({ open, request, directory, actor })
		SignedInOnly(asked) =>
			match actor {
				Anonymous => anonymous_refusal(asked)
				SignedIn(acting) => serve_signed_in_route!({ asked, request, directory, acting })
			}
		MethodNotAllowed(allowed) => HttpAnswer.method_not_allowed(allowed)
		NotFound => HttpAnswer.page(404, Page.not_found)
	}

## The answer to `/`: a 303 to Browse, which shows someone signed in their
## page and sends anyone else to sign in.
browse_redirect : Http.Response
browse_redirect = HttpAnswer.see_other(ConversationKey.browse_path)

## The answer to an open route, for `actor`, whoever it is.
answer_open_route! : {
	open : Route.OpenChoice,
	request : Http.Request,
	directory : Directory,
	actor : SignedIn.Actor,
} => Http.Response
answer_open_route! = |{ open, request, directory, actor }|
	match open {
		GoToBrowse => browse_redirect
		ServeScript(script) => HttpAnswer.script(script.bytes())
		ServeFavicon => HttpAnswer.favicon(Favicon.bytes)
		ShowLogin =>
			SignInRoute.show_login({
				viewer: actor,
				query: request.query,
				github: GitHubRoute.load_offer!({}),
			})
		SignIn =>
			SignInRoute.sign_in!({
				viewer: actor,
				users: directory.users(),
				body: request.body,
				now: read_clock!({}),
				github: GitHubRoute.load_offer!({}),
			})
		SignOut => SignInRoute.sign_out
		StartGitHubSignIn =>
			GitHubRoute.serve_start!({
				viewer: actor,
				query: request.query,
				origin: own_origin_of(request),
				now: read_clock!({}),
			})
		FinishGitHubSignIn =>
			GitHubRoute.serve_return!({
				viewer: actor,
				directory,
				query: request.query,
				headers: request.headers,
				now: read_clock!({}),
			})
		FinishGitHubSignUp =>
			GitHubRoute.serve_sign_up!({
				viewer: actor,
				directory,
				body: request.body,
				headers: request.headers,
				now: read_clock!({}),
			})
		WrongMethodToGitHub(allowed) => GitHubRoute.refuse_method!(allowed)
		RedeemInvite =>
			AgentsRoute.redeem!({
				actor,
				directory,
				body: request.body,
				now: read_clock!({}),
			})
		ShowJoin => HumanInvitesRoute.join_page(actor)
		LookUpJoinName =>
			HumanInvitesRoute.serve_join_name!({
				actor,
				directory,
				body: request.body,
				now: read_clock!({}),
			})
		Join =>
			HumanInvitesRoute.join!({
				actor,
				directory,
				body: request.body,
				now: read_clock!({}),
			})
	}

## The answer the route `asked` gives `acting`, once `Access` admits them.
serve_signed_in_route! : {
	asked : Route.SignedInChoice,
	request : Http.Request,
	directory : Directory,
	acting : SignedIn,
} => Http.Response
serve_signed_in_route! = |{ asked, request, directory, acting }| {
	admitted =
		match access_asked(asked) {
			AsksNoConversation => Ok({})
			Asks({ place, act }) =>
				Access.check({ acting, place, directory, act })
		}
	match admitted {
		Err(why) => access_refusal(why)
		Ok({}) => answer_route!({ asked, request, directory, acting })
	}
}

## The answer to `asked`, which `Access` has admitted.
answer_route! : {
	asked : Route.SignedInChoice,
	request : Http.Request,
	directory : Directory,
	acting : SignedIn,
} => Http.Response
answer_route! = |{ asked, request, directory, acting }|
	match asked {
		StartGitHubLink =>
			GitHubRoute.serve_link_start!({
				acting,
				origin: own_origin_of(request),
				now: read_clock!({}),
			})
		ShowBrowse => BrowseRoute.show!({ acting, directory })
		StartTopic(place) =>
			BrowseRoute.start_topic!({ acting, directory, place, body: request.body })
		ShowConversation(key) =>
			ConversationRoute.show!({ key, acting, users: directory.users() })
		OpenConversationStream(key) =>
			ConversationRoute.open_stream!({
				key,
				acting,
				users: directory.users(),
				query: request.query,
				headers: request.headers,
			})
		ServeRawTranscript(key) => ConversationRoute.serve_raw!(key)
		AppendToConversation(key) =>
			ConversationRoute.post_sent_message!(
				make_message_post!({ key, request, directory, acting }),
			)
		SendToConversation(key) =>
			ConversationRoute.post_message_without_reload!(
				make_message_post!({ key, request, directory, acting }),
			)
		UploadToConversation(key) =>
			UploadRoute.post_upload!({
				key,
				acting,
				headers: request.headers,
				body: request.body,
			})
		ServeUploadedImage(found) => UploadRoute.serve_uploaded_image!(found)
		ShowAgents => AgentsRoute.show!({ acting, directory })
		MakeAgent => AgentsRoute.make!({ acting, directory, body: request.body })
		InviteAgent(agent) =>
			AgentsRoute.invite!({
				acting,
				directory,
				agent,
				body: request.body,
				now: read_clock!({}),
			})
		RevokeInvite({ agent, invite }) =>
			AgentsRoute.revoke_invite!({ acting, directory, agent, invite })
		RevokeKey({ agent, key }) =>
			AgentsRoute.revoke_key!({ acting, directory, agent, key })
		OpenAgentStream => AgentsRoute.open_stream!({ acting, directory, query: request.query })
		ShowChannels => ChannelMembersRoute.show_channels({ acting, directory })
		CreateChannel => ChannelMembersRoute.create!({ acting, directory, body: request.body })
		ShowChannelMembers(channel) => ChannelMembersRoute.show_members({
			acting,
			directory,
			channel,
		})
		AddChannelMember({ channel, member }) =>
			ChannelMembersRoute.add!({ acting, directory, channel, member })
		RemoveChannelMember({ channel, member }) =>
			ChannelMembersRoute.remove!({ acting, directory, channel, member })
		ShowInvites =>
			HumanInvitesRoute.show!({ acting, directory, now: read_clock!({}) })
		InviteHuman =>
			HumanInvitesRoute.invite!({
				acting,
				directory,
				body: request.body,
				origin: own_origin_of(request),
				now: read_clock!({}),
			})
		InviteHumanAgain(human) =>
			HumanInvitesRoute.invite_again!({
				acting,
				directory,
				human,
				origin: own_origin_of(request),
				now: read_clock!({}),
			})
	}

## The origin `request` came to, which `handle_http_request!` has held to
## one of this server's own.
own_origin_of : Http.Request -> Str
own_origin_of = |request|
	match RequestOrigin.origin_of_host({
		headers: request.headers,
		port: request.port,
		public_origin: request.public_origin,
	}) {
		Ok(origin) => origin
		Err(_) =>
			crash "main.own_origin_of: the request's Host passed RequestOrigin.check, so it names one of this server's origins"
	}

## A message's POST to the conversation `key`, by `acting`, at the host's
## clock, heard by its channel's agent members.
make_message_post! : {
	key : ConversationKey,
	request : Http.Request,
	directory : Directory,
	acting : SignedIn,
} => ConversationRoute.Post
make_message_post! = |{ key, request, directory, acting }| {
	key,
	acting,
	users: directory.users(),
	now: read_clock!({}),
	body: request.body,
	agents: Access.agent_members({ place: key.place(), directory }),
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
		== Page.conversation({
			conversation: Conversation.empty(plans),
			key,
			viewer: demo_viewer,
			users: FirstStart.first_directory.users(),
		}).to_utf8()
}
expect page("/chat/dm/1_1/plans".to_utf8(), [0xff]) == Page.refusal("it is not UTF-8").to_utf8()
expect page("<b>".to_utf8(), [0xff])
	== Page.refusal("its path is not a conversation's, /chat/channel/<channel>/<topic> or /chat/dm/<pair>/<topic>")
		.to_utf8()

# The demo's viewer is the first start's Steve, id 1.
expect
	demo_viewer.user().name() == FirstStart.founder_name
		and demo_viewer.user().id() == UserId.chat_owner

# Each route asks what it does of `Access`: every conversation's GET reads,
# every write posts, and nothing else asks.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
			?? crash "main's tests: a path is UTF-8",
		directory: FirstStart.first_directory,
	}).map_ok(|found| found.key) ?? crash "main's tests: Steve's own DM is a place"
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png") ?? crash "main's tests: an image's name"
	[
		ShowConversation(key),
		OpenConversationStream(key),
		ServeRawTranscript(key),
		ServeUploadedImage({ key, image }),
	].all(|choice| access_asked(choice) == Asks({ place: key.place(), act: Read }))
		and [
			AppendToConversation(key),
			SendToConversation(key),
			UploadToConversation(key),
			StartTopic(key.place()),
		].all(|choice| access_asked(choice) == Asks({ place: key.place(), act: Post }))
		and [
			ShowBrowse,
			ShowAgents,
			MakeAgent,
			OpenAgentStream,
			InviteAgent(UserId.chat_owner),
		].all(|choice| access_asked(choice) == AsksNoConversation)
}

# The way in names Browse, whoever asks.
expect
	browse_redirect.status == 303
		and browse_redirect.headers == [{ name: "location".to_utf8(), value: "/chat".to_utf8() }]
# No one asking for a page is sent to sign in, and back after; any other
# route only someone signed in may use is a 401 to no one.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
			?? crash "main's tests: a path is UTF-8",
		directory: FirstStart.first_directory,
	}).map_ok(|found| found.key) ?? crash "main's tests: Steve's own DM is a place"
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png") ?? crash "main's tests: an image's name"
	shown = anonymous_refusal(ShowConversation(key))
	agents = anonymous_refusal(ShowAgents)
	browse = anonymous_refusal(ShowBrowse)
	browse.status == 303
		and browse.headers == [{ name: "location".to_utf8(), value: "/login?next=/chat".to_utf8() }]
		and shown.status == 303
		and shown.headers == [
			{ name: "location".to_utf8(), value: "/login?next=/chat/dm/1_1/plans".to_utf8() },
		]
		and agents.status == 303
		and agents.headers == [
			{ name: "location".to_utf8(), value: "/login?next=/agents".to_utf8() },
		]
		and [
			StartTopic(key.place()),
			AppendToConversation(key),
			SendToConversation(key),
			OpenConversationStream(key),
			ServeRawTranscript(key),
			UploadToConversation(key),
			ServeUploadedImage({ key, image }),
			MakeAgent,
			InviteAgent(UserId.chat_owner),
			OpenAgentStream,
			StartGitHubLink,
		].all(|asked| anonymous_refusal(asked) == unauthorized_refusal)
		and unauthorized_refusal.status == 401
		and unauthorized_refusal.body == "${unauthorized_words}\n".to_utf8()
}

# A credential refused is one 401 in plain text, whatever was wrong with it.
expect
	[BadBearer, KeyRefused].all(
		|why| {
			answered = identity_refusal(why)
			answered.status == 401 and answered.body == "${key_refusal_words}\n".to_utf8()
		},
	)
# Each access refusal: a 403 saying which.
expect access_refusal(NotAMember).status == 403 and access_refusal(ScopeOff).status == 403
expect access_refusal(NotAMember).body != access_refusal(ScopeOff).body
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

## This module is the app's edge. It holds the app's five entries.
##
## - `page` (the demo, host/demo.zig): a conversation's URL path and its
##   transcript in, its page out, as the server would show it to the
##   founder at the first start (`first_directory`). The path's bytes become
##   unchecked text (`UnvalidatedString`), then a `ConversationKey` found in
##   the directory; the transcript's an unchecked file
##   (`Transcript.Utf8Transcript`), then a Conversation; or a refusal's tags
##   (`TranscriptRefusal` puts them in words).
## - `start!` (the server, host/http.zig, once, before it listens): when the
##   data folder holds no chat yet, the founder, Steve, id 1, is made, with
##   the channel `general`, of which he is the one member
##   (`first_directory`). A folder that holds a chat is read, and one that
##   holds part of one is refused, so the server never starts on it.
## - `check_request_head!` (the server): a request's head in, before the
##   host reads any body; out comes a refusal, or how large a body to read
##   and how long to wait for it. Only someone signed in who may post in a
##   conversation gets an upload's room there (`body_allowance`).
## - `handle_http_request!` (the server): a request in, its response out.
##   The directory is read from disk (`load_directory!`), who is acting is
##   found (`load_actor!`), `Route` chooses the answer, `Access` decides
##   whether the actor may read or post in a conversation, and
##   `ConversationRoute`, `UploadRoute`, `AgentsRoute`, `ChannelMembersRoute`,
##   `HumanInvitesRoute`, `SignInRoute` or `GitHubRoute` gives the answer.
## - `password_verdict` (`gopher-roc hash-password`, host/main.zig): a line
##   in, and whether it is a password the sign-in form takes, so the
##   command hashes none that could never sign in.
##
## Who is acting is found from the request alone (`load_actor!`): a request
## with an `Authorization` header by that header alone, as the agent its
## key admits, or a 401; any other by its session cookie, as the human the
## session admits (`SignInRoute.sign_in_by_session!`), or else as no one
## (`Anonymous`). A request that proves no one may use only the routes
## `Route` says are open (the scripts, signing in and out, by a password or
## GitHub, signing up by GitHub, redeeming an agent's invite, and joining by
## a human's); any other
## page sends it to
## sign in, and any other request is a 401. Only the first start, which
## makes Steve before anyone can sign in, and the demo's page take him as
## signed in with nothing checked (`SignedIn.dangerously_assume`); no request
## does.
app [
	check_request_head!,
	handle_http_request!,
	page,
	password_verdict,
	start!,
] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import pf.Host
import pf.Http
import Access
import Admin
import AgentsRoute
import ChannelMembersRoute
import ChannelName
import Channels
import Conversation
import ConversationKey
import ConversationRoute
import Directory
import FileSystem
import GitHubRoute
import HumanInvitesRoute
import Html
import HttpAnswer
import Name
import Page
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
					viewer: demo_viewer,
					users: first_directory.users(),
				})
			Err(why) => Page.refusal(TranscriptRefusal.words(why))
		}
	answer.to_utf8()
}

## The conversation the host's bytes hold, decoded at the door: the URL
## path read as a conversation's key in `first_directory`, then the
## transcript file's bytes, by `Transcript.decode` under the key's topic.
conversation : { path : List(U8), transcript : List(U8) } -> Try(
	{ conversation : Conversation, key : ConversationKey },
	_,
)
conversation = |{ path, transcript }| {
	unchecked = UnvalidatedString.from_utf8(path) ? |NotUtf8| PathNotUtf8
	found = ConversationKey.from_url_path({
		path: unchecked,
		directory: first_directory,
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
demo_viewer = SignedIn.dangerously_assume(first_directory.founder())

## Whether the server may start on its data folder: `Ready` when the folder
## holds a whole chat, or held none and now holds the first
## (`first_directory`); else `Failed`, and the host stops.
start! : {} => [Failed, Ready]
start! = |{}|
	match FileSystem.read_directory_files!({}) {
		Err(_) => Failed
		Ok(files) =>
			match files.counter {
				File(_) =>
					match directory_from_files(files) {
						Ok(_) => Ready
						Err(_) => Failed
					}
				NoFile if files.accounts.is_empty() and files.channels.is_empty() =>
					match write_first_directory!({}) {
						Ok({}) => Ready
						Err(_) => Failed
					}
				NoFile => Failed
			}
	}

## The first directory written: the founder's account, `general`'s members,
## then the counter of ids, which says the chat exists, last.
write_first_directory! : {} => Try({}, _)
write_first_directory! = |{}| {
	FileSystem.create_account!(first_directory.founder())?
	for channel in first_directory.channels().to_list() {
		FileSystem.replace_channel_members!(channel)?
	}
	FileSystem.replace_user_counter!(first_directory.users())?
	Ok({})
}

## The directory at the first start: Steve (id 1), a human, and one
## channel, `general`, which he creates as the chat's first admin and is
## the one member of. Steve acts here with nothing checked (`SignedIn`),
## as no one has signed in before the chat exists.
first_directory : Directory
first_directory = {
	founded = Directory.with_founder(founder_name)
	founder = founded.founder()
	admin =
		Admin.of(SignedIn.dangerously_assume(founder))
			?? crash "main.first_directory: Steve, id 1, is an admin"
	general =
		ChannelName.from_str("general") ?? crash "main.first_directory: general is a channel's name"
	created = (
		founded.create_channel({
			by: admin,
			name: general,
		}) ?? crash "main.first_directory: the name general is free"
	).directory
	created.add_member({
		by: admin,
		channel: general,
		member: founder,
	}) ?? crash "main.first_directory: Steve joins general"
}

founder_name : Name
founder_name = Name.from_str("Steve") ?? crash "main.founder_name: Steve is a name"

## The directory as the data folder holds it now; or why not.
load_directory! : {} => Try(Directory, [FileSystem(FileSystem.Fault), StoredDirectory(Str)])
load_directory! = |{}| {
	files = FileSystem.read_directory_files!({}) ? |fault| FileSystem(fault)
	directory_from_files(files)
}

## The directory the files hold; or why not, in words.
directory_from_files : FileSystem.DirectoryFiles -> Try(Directory, [StoredDirectory(Str)])
directory_from_files = |files| {
	counter =
		match files.counter {
			File(bytes) => Ok(bytes)
			NoFile => Err(StoredDirectory("there is no counter of user ids"))
		}?
	users = Users.from_files({
		counter,
		accounts: files.accounts,
	}) ? |why| StoredDirectory(users_words(why))
	channels =
		Channels.from_files(files.channels) ? |BadMembers(name)| StoredDirectory("the members of #${name.to_str()} are not one id a line")
	directory = Directory.from_files({
		users,
		channels,
	}) ? |why| StoredDirectory(directory_words(why))
	Ok(directory)
}

users_words : [
	BadCounter,
	BadName(UserId),
	BadOwner(UserId),
	NoFounder,
	CounterBehind,
] -> Str
users_words = |why|
	match why {
		BadCounter => "the counter of user ids is not one"
		BadName(id) => "user ${id.to_str()}'s name is not a name"
		BadOwner(id) => "user ${id.to_str()}'s owner is no human"
		NoFounder => "there is no founder, a human of id 1"
		CounterBehind => "the counter of user ids is behind a user's id"
	}

directory_words : [NameTaken, UnknownMember(ChannelName)] -> Str
directory_words = |why|
	match why {
		NameTaken => "two names are the same name"
		UnknownMember(name) => "#${name.to_str()} has a member who is no user"
	}

## The 500 for a directory that can't be read.
directory_refusal : [FileSystem(FileSystem.Fault), StoredDirectory(Str)] -> Http.Response
directory_refusal = |why| {
	said =
		match why {
			FileSystem(fault) => FileSystem.fault_words(fault)
			StoredDirectory(words) => "The chat's directory on disk is not whole: ${words}."
		}
	HttpAnswer.page(500, Page.notice({ title: "Failed", text: said }))
}

## What the host may do with a request, judged from its head alone. A
## request from elsewhere (`RequestOrigin`, a trust boundary) is refused
## with a 403 before anything is read, so the host never reads its body.
## Then the directory is read and who is acting is found, as for the whole
## request (`load_actor!`): a credential refused is its 401 here, and a
## directory that can't be read its 500. Any other is judged by
## `admission_in`.
check_request_head! : Http.RequestHead => Http.Admission
check_request_head! = |head|
	match RequestOrigin.check(origin_of_head(head)) {
		Err(why) => Refuse(for_this_origin_alone(origin_refusal(why)))
		Ok({}) =>
			match load_directory!({}) {
				Err(why) => Refuse(for_this_origin_alone(directory_refusal(why)))
				Ok(directory) =>
					match load_actor!({ headers: head.headers, directory }) {
						Err(why) => Refuse(for_this_origin_alone(identity_refusal(why)))
						Ok(actor) => admission_in({
							head,
							directory,
							actor,
						})
					}
			}
	}

## What `RequestOrigin` judges of a request's head.
origin_of_head : Http.RequestHead -> {
	method : List(U8),
	headers : List(Http.Header),
	port : U16,
	public_origin : List(U8),
}
origin_of_head = |head| {
	method: head.method,
	headers: head.headers,
	port: head.port,
	public_origin: head.public_origin,
}

## What the host may do with a request, from its `head`, in `directory`,
## `actor` acting: a request from elsewhere refused with a 403; any other
## admitted, with the room `body_allowance` gives it.
admission_in : {
	head : Http.RequestHead,
	directory : Directory,
	actor : SignedIn.Actor,
} -> Http.Admission
admission_in = |
	{
		head,
		directory,
		actor,
	},
|
	match RequestOrigin.check(origin_of_head(head)) {
		Err(why) => Refuse(for_this_origin_alone(origin_refusal(why)))
		Ok({}) => {
			choice = Route.choose({
				method: head.method,
				path: head.path,
				directory,
			})
			Admit(
				body_allowance({
					choice,
					directory,
					actor,
				}),
			)
		}
	}

## The body a request may have: an upload's room for an upload to a
## conversation by someone signed in who may post there, and a form's for
## any other request, an upload by anyone else included. So no one gets
## the large room or its time before their credential is checked.
body_allowance : {
	choice : Route.Choice,
	directory : Directory,
	actor : SignedIn.Actor,
} -> { body_most : U64, body_grace_ms : U32 }
body_allowance = |
	{
		choice,
		directory,
		actor,
	},
|
	match (upload_asked(choice), actor) {
		(UploadTo(key), SignedIn(acting)) =>
			match Access.check({
				acting,
				place: key.place(),
				directory,
				act: Post,
			}) {
				Ok({}) => upload_body_allowance
				Err(NotAMember) => form_body_allowance
				Err(ScopeOff) => form_body_allowance
			}
		(UploadTo(_), Anonymous) => form_body_allowance
		(NoUpload, SignedIn(_)) => form_body_allowance
		(NoUpload, Anonymous) => form_body_allowance
	}

## Whether a route uploads to a conversation, and to which.
upload_asked : Route.Choice -> [UploadTo(ConversationKey), NoUpload]
upload_asked = |choice|
	match choice {
		SignedInOnly(UploadToConversation(key)) => UploadTo(key)
		SignedInOnly(ShowConversation(_)) => NoUpload
		SignedInOnly(AppendToConversation(_)) => NoUpload
		SignedInOnly(SendToConversation(_)) => NoUpload
		SignedInOnly(OpenConversationStream(_)) => NoUpload
		SignedInOnly(ServeRawTranscript(_)) => NoUpload
		SignedInOnly(ServeUploadedImage(_)) => NoUpload
		SignedInOnly(ShowAgents) => NoUpload
		SignedInOnly(MakeAgent) => NoUpload
		SignedInOnly(InviteAgent(_)) => NoUpload
		SignedInOnly(RevokeInvite(_)) => NoUpload
		SignedInOnly(RevokeKey(_)) => NoUpload
		SignedInOnly(OpenAgentStream) => NoUpload
		SignedInOnly(ShowChannels) => NoUpload
		SignedInOnly(CreateChannel) => NoUpload
		SignedInOnly(ShowChannelMembers(_)) => NoUpload
		SignedInOnly(AddChannelMember(_)) => NoUpload
		SignedInOnly(RemoveChannelMember(_)) => NoUpload
		SignedInOnly(ShowInvites) => NoUpload
		SignedInOnly(InviteHuman) => NoUpload
		SignedInOnly(InviteHumanAgain(_)) => NoUpload
		Open(ShowJoin) => NoUpload
		Open(LookUpJoinName) => NoUpload
		Open(Join) => NoUpload
		Open(ServeScript(_)) => NoUpload
		Open(ShowLogin) => NoUpload
		Open(SignIn) => NoUpload
		Open(SignOut) => NoUpload
		Open(StartGitHubSignIn) => NoUpload
		Open(FinishGitHubSignIn) => NoUpload
		Open(FinishGitHubSignUp) => NoUpload
		Open(WrongMethodToGitHub(_)) => NoUpload
		Open(RedeemInvite) => NoUpload
		NotFound => NoUpload
		MethodNotAllowed(_) => NoUpload
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
upload_body_allowance = {
	body_most: UploadedImage.most_bytes + 64 * 1024,
	body_grace_ms: 5 * 60 * 1000,
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
			Err(why) => origin_refusal(why)
			Ok({}) =>
				match load_directory!({}) {
					Err(why) => directory_refusal(why)
					Ok(directory) =>
						match load_actor!({ headers: request.headers, directory }) {
							Err(why) => identity_refusal(why)
							Ok(actor) => serve_route!({
								request,
								directory,
								actor,
							})
						}
				}
		}
	for_this_origin_alone(answer)
}

## Who is acting. With `Authorization: Bearer <id>-<secret>`, the agent its
## key admits (`AgentsRoute.sign_in_by_key!`); any other `Authorization` is
## refused, and a request with one is never judged by its cookie, so a key
## refused never falls back to a session. With none, the human the session
## cookie admits (`load_session_actor!`), or no one.
load_actor! : { headers : List(Http.Header), directory : Directory } => Try(
	SignedIn.Actor,
	[
		BadBearer,
		KeyRefused,
		FileSystem(FileSystem.Fault),
	],
)
load_actor! = |{ headers, directory }| {
	now = Host.current_utc_seconds_since_epoch!({})
	match RequestHeader.header_value(headers, "authorization") {
		Unsent => load_session_actor!({
			headers,
			directory,
			now,
		})
		Repeated => Err(BadBearer)
		Sent(value) => {
			bearer_text = UnvalidatedString.from_utf8(value) ? |NotUtf8| BadBearer
			token = bearer_text.bearer_token() ? |NotABearer| BadBearer
			signed_in_by_key = AgentsRoute.sign_in_by_key!({
				token,
				directory,
				now,
			})?
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
	now : I64,
} => Try(SignedIn.Actor, [FileSystem(FileSystem.Fault)])
load_session_actor! = |
	{
		headers,
		directory,
		now,
	},
|
	match RequestHeader.header_value(headers, "cookie") {
		Unsent => Ok(Anonymous)
		Repeated => Ok(Anonymous)
		Sent(cookie) =>
			match SignInRoute.sign_in_by_session!({
				cookie,
				users: directory.users(),
				now,
			}) {
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
identity_refusal : [
	BadBearer,
	KeyRefused,
	FileSystem(FileSystem.Fault),
] -> Http.Response
identity_refusal = |why|
	match why {
		BadBearer => HttpAnswer.text(401, key_refusal_words)
		KeyRefused => HttpAnswer.text(401, key_refusal_words)
		FileSystem(fault) => HttpAnswer.text(500, FileSystem.fault_words(fault))
	}

key_refusal_words : Str
key_refusal_words =
	"The API key is not accepted: send Authorization: Bearer <id>-<secret>, a live key."

## The 403 for a request from elsewhere, saying why.
origin_refusal : RequestOrigin.Refusal -> Http.Response
origin_refusal = |why| HttpAnswer.page(
	403,
	Page.notice({ title: "Forbidden", text: RequestOrigin.words(why) }),
)

## `answer`, which no other site's page may load: a browser refuses to hand
## a page elsewhere any answer of this server's (`Cross-Origin-Resource-Policy`),
## an image, a script or a stream included.
for_this_origin_alone : Http.Response -> Http.Response
for_this_origin_alone = |answer| {
	..answer,
	headers: answer.headers.append({
		name: "cross-origin-resource-policy".to_utf8(),
		value: "same-origin".to_utf8(),
	}),
}

## What a route asks of `Access` before it is answered: to read or post in
## a conversation, or nothing.
access_asked : Route.SignedInChoice -> [
	Asks({ key : ConversationKey, act : Access.Act }),
	AsksNoConversation,
]
access_asked = |asked|
	match asked {
		ShowConversation(key) => Asks({ key, act: Read })
		OpenConversationStream(key) => Asks({ key, act: Read })
		ServeRawTranscript(key) => Asks({ key, act: Read })
		ServeUploadedImage(found) => Asks({ key: found.key, act: Read })
		AppendToConversation(key) => Asks({ key, act: Post })
		SendToConversation(key) => Asks({ key, act: Post })
		UploadToConversation(key) => Asks({ key, act: Post })
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
		ShowConversation(key) => SignInRoute.login_redirect(site_path_of(key.url_path(Page)))
		ShowAgents => SignInRoute.login_redirect(site_path_of("/agents"))
		ShowChannels => SignInRoute.login_redirect(site_path_of("/channels"))
		ShowChannelMembers(channel) =>
			SignInRoute.login_redirect(site_path_of("/channels/${channel.to_str()}"))
		CreateChannel => no_one_refusal
		AddChannelMember(_) => no_one_refusal
		RemoveChannelMember(_) => no_one_refusal
		ShowInvites => SignInRoute.login_redirect(site_path_of("/invites"))
		InviteHuman => no_one_refusal
		InviteHumanAgain(_) => no_one_refusal
		AppendToConversation(_) => no_one_refusal
		SendToConversation(_) => no_one_refusal
		OpenConversationStream(_) => no_one_refusal
		ServeRawTranscript(_) => no_one_refusal
		UploadToConversation(_) => no_one_refusal
		ServeUploadedImage(_) => no_one_refusal
		MakeAgent => no_one_refusal
		InviteAgent(_) => no_one_refusal
		RevokeInvite(_) => no_one_refusal
		RevokeKey(_) => no_one_refusal
		OpenAgentStream => no_one_refusal
	}

## The 401 for a request that proves no one, at a route only someone
## signed in may use.
no_one_refusal : Http.Response
no_one_refusal = HttpAnswer.text(401, no_one_words)

no_one_words : Str
no_one_words =
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
serve_route! = |
	{
		request,
		directory,
		actor,
	},
|
	match Route.choose({
		method: request.method,
		path: request.path,
		directory,
	}) {
		Open(open) => answer_open_route!({
			open,
			request,
			directory,
			actor,
		})
		SignedInOnly(asked) =>
			match actor {
				Anonymous => anonymous_refusal(asked)
				SignedIn(acting) => serve_signed_in_route!({
					asked,
					request,
					directory,
					acting,
				})
			}
		MethodNotAllowed(allowed) => HttpAnswer.method_not_allowed(allowed)
		NotFound => HttpAnswer.page(
			404,
			Page.notice({ title: "Not found", text: "Nothing is here." }),
		)
	}

## The answer to an open route, for `actor`, whoever it is.
answer_open_route! : {
	open : Route.OpenChoice,
	request : Http.Request,
	directory : Directory,
	actor : SignedIn.Actor,
} => Http.Response
answer_open_route! = |
	{
		open,
		request,
		directory,
		actor,
	},
|
	match open {
		ServeScript(script) => HttpAnswer.script(script.bytes())
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
				now: Host.current_utc_seconds_since_epoch!({}),
				github: GitHubRoute.load_offer!({}),
			})
		SignOut => SignInRoute.sign_out
		StartGitHubSignIn =>
			GitHubRoute.serve_start!({
				viewer: actor,
				query: request.query,
				origin: own_origin_of(request),
				now: Host.current_utc_seconds_since_epoch!({}),
			})
		FinishGitHubSignIn =>
			GitHubRoute.serve_return!({
				viewer: actor,
				directory,
				query: request.query,
				headers: request.headers,
				now: Host.current_utc_seconds_since_epoch!({}),
			})
		FinishGitHubSignUp =>
			GitHubRoute.serve_sign_up!({
				viewer: actor,
				directory,
				body: request.body,
				headers: request.headers,
				now: Host.current_utc_seconds_since_epoch!({}),
			})
		WrongMethodToGitHub(allowed) => GitHubRoute.refuse_method!(allowed)
		RedeemInvite =>
			AgentsRoute.redeem!({
				actor,
				directory,
				body: request.body,
				now: Host.current_utc_seconds_since_epoch!({}),
			})
		ShowJoin => HumanInvitesRoute.join_page
		LookUpJoinName =>
			HumanInvitesRoute.serve_join_name!({
				actor,
				directory,
				body: request.body,
				now: Host.current_utc_seconds_since_epoch!({}),
			})
		Join =>
			HumanInvitesRoute.join!({
				actor,
				directory,
				body: request.body,
				now: Host.current_utc_seconds_since_epoch!({}),
			})
	}

## The answer the route `asked` gives `acting`, once `Access` admits them.
serve_signed_in_route! : {
	asked : Route.SignedInChoice,
	request : Http.Request,
	directory : Directory,
	acting : SignedIn,
} => Http.Response
serve_signed_in_route! = |
	{
		asked,
		request,
		directory,
		acting,
	},
| {
	admitted =
		match access_asked(asked) {
			AsksNoConversation => Ok({})
			Asks({ key, act }) =>
				Access.check({
					acting,
					place: key.place(),
					directory,
					act,
				})
		}
	match admitted {
		Err(why) => access_refusal(why)
		Ok({}) => answer_route!({
			asked,
			request,
			directory,
			acting,
		})
	}
}

## The answer to `asked`, which `Access` has admitted.
answer_route! : {
	asked : Route.SignedInChoice,
	request : Http.Request,
	directory : Directory,
	acting : SignedIn,
} => Http.Response
answer_route! = |
	{
		asked,
		request,
		directory,
		acting,
	},
|
	match asked {
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
		ServeRawTranscript(key) => ConversationRoute.serve_raw!(key)
		AppendToConversation(key) =>
			ConversationRoute.post_sent_message!(
				make_message_post!({
					key,
					request,
					directory,
					acting,
				}),
			)
		SendToConversation(key) =>
			ConversationRoute.post_message_without_reload!(
				make_message_post!({
					key,
					request,
					directory,
					acting,
				}),
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
		MakeAgent => AgentsRoute.make!({
			acting,
			directory,
			body: request.body,
		})
		InviteAgent(agent) =>
			AgentsRoute.invite!({
				acting,
				directory,
				agent,
				body: request.body,
				now: Host.current_utc_seconds_since_epoch!({}),
			})
		RevokeInvite({ agent, invite }) =>
			AgentsRoute.revoke_invite!({
				acting,
				directory,
				agent,
				invite,
			})
		RevokeKey({ agent, key }) =>
			AgentsRoute.revoke_key!({
				acting,
				directory,
				agent,
				key,
			})
		OpenAgentStream => AgentsRoute.open_stream!({
			acting,
			directory,
			query: request.query,
		})
		ShowChannels => ChannelMembersRoute.show_channels({ acting, directory })
		CreateChannel => ChannelMembersRoute.create!({
			acting,
			directory,
			body: request.body,
		})
		ShowChannelMembers(channel) => ChannelMembersRoute.show_members({
			acting,
			directory,
			channel,
		})
		AddChannelMember({ channel, member }) =>
			ChannelMembersRoute.add!({
				acting,
				directory,
				channel,
				member,
			})
		RemoveChannelMember({ channel, member }) =>
			ChannelMembersRoute.remove!({
				acting,
				directory,
				channel,
				member,
			})
		ShowInvites => HumanInvitesRoute.show!({ acting, directory })
		InviteHuman =>
			HumanInvitesRoute.invite!({
				acting,
				directory,
				body: request.body,
				origin: own_origin_of(request),
				now: Host.current_utc_seconds_since_epoch!({}),
			})
		InviteHumanAgain(human) =>
			HumanInvitesRoute.invite_again!({
				acting,
				directory,
				human,
				origin: own_origin_of(request),
				now: Host.current_utc_seconds_since_epoch!({}),
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
make_message_post! = |
	{
		key,
		request,
		directory,
		acting,
	},
| {
	key,
	acting,
	users: directory.users(),
	now: Host.current_utc_seconds_since_epoch!({}),
	body: request.body,
	agents: Access.agent_members({ place: key.place(), directory }),
}

# ── tests
plans : Topic
plans = Topic.from_str("plans") ?? crash "main's tests: a topic's name"

## What the door finds at `path` with `transcript`, as a test reads it:
## the conversation, and its key's URL path.
found_at : { path : List(U8), transcript : List(U8) } -> Try((Conversation, Str), _)
found_at = |held| conversation(held).map_ok(
	|found| (
		found.conversation,
		found.key.url_path(Page),
	),
)

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
		directory: first_directory,
	}).map_ok(|found| found.key) ?? crash "main's tests: Steve's own DM is a place"
	page("/chat/dm/1_1/plans".to_utf8(), [])
		== Page.conversation({
			conversation: Conversation.empty(plans),
			key,
			viewer: demo_viewer,
			users: first_directory.users(),
		}).to_utf8()
}
expect page("/chat/dm/1_1/plans".to_utf8(), [0xff]) == Page.refusal("it is not UTF-8").to_utf8()
expect page(
	"<b>".to_utf8(),
	[0xff],
)
	== Page.refusal("its path is not a conversation's, /chat/channel/<channel>/<topic> or /chat/dm/<pair>/<topic>")
		.to_utf8()

## The page a GET of `path` shows, as a test reads it.
page_for_get : Str -> Str
page_for_get = |path|
	match Route.choose({
		method: "GET".to_utf8(),
		path: path.to_utf8(),
		directory: first_directory,
	}) {
		SignedInOnly(ShowConversation(key)) => key.url_path(Page)
		SignedInOnly(OpenConversationStream(key)) => "the stream of ${key.url_path(Page)}"
		SignedInOnly(ServeUploadedImage(found)) =>
			"the image ${found.image.name()} of ${found.key.url_path(Page)}"
		_ => "not found"
	}

# The first start: Steve, id 1, a human, the demo's viewer; `general`, its
# one member Steve; the counter at 2.
expect demo_viewer.user().name() == founder_name and demo_viewer.user().id() == UserId.steve
expect first_directory.users().to_list().map(|user| user.role()) == [Human]
expect first_directory.channels().to_list().map(
	|channel| (
		channel.name().to_str(),
		channel.members().map(UserId.to_str),
	),
) == [("general", ["1"])]
expect first_directory.users().counter_file() == "2\n".to_utf8()
expect page_for_get("/chat/channel/general/plans") == "/chat/channel/general/plans"
expect page_for_get("/chat/dm/1_1/plans") == "/chat/dm/1_1/plans"
expect page_for_get("/chat/channel/other/plans") == "not found"
expect page_for_get("/chat/dm/1_2/plans") == "not found"
expect page_for_get("/chat/dm/1_1/plans/stream") == "the stream of /chat/dm/1_1/plans"
expect page_for_get("/chat/dm/1_2/plans/stream") == "not found"
expect
	page_for_get("/chat/channel/general/plans/uploads/${"0".repeat(32)}.png")
		== "the image ${"0".repeat(32)}.png of /chat/channel/general/plans"
expect page_for_get("/chat/dm/1_2/plans/uploads/${"0".repeat(32)}.png") == "not found"

## The directory files of the first start, as the disk holds them.
first_files : FileSystem.DirectoryFiles
first_files = {
	founder = first_directory.founder()
	{
		counter: File(first_directory.users().counter_file()),
		accounts: [{ id: founder.id(), files: Users.account_files(founder) }],
		channels: first_directory.channels().to_list().map(
			|channel| {
				name: channel.name(),
				members: channel.members_file(),
			},
		),
	}
}

# The first start's files read back are the first directory; with no
# counter, or a counter that is no number, the files are no chat's.
expect directory_from_files(first_files) == Ok(first_directory)
expect directory_from_files({
	..first_files,
	counter: NoFile,
}) == Err(StoredDirectory("there is no counter of user ids"))
expect directory_from_files({
	..first_files,
	counter: File("x".to_utf8()),
}) == Err(StoredDirectory("the counter of user ids is not one"))
expect
	directory_from_files({
		..first_files,
		channels: [
			{
				name: ChannelName.from_str("general") ?? crash "main's tests: a name",
				members: "1\n2\n".to_utf8(),
			},
		],
	})
		== Err(StoredDirectory("#general has a member who is no user"))
expect
	directory_from_files({
		..first_files,
		channels: [
			{
				name: ChannelName.from_str("steve") ?? crash "main's tests: a name",
				members: "1\n".to_utf8(),
			},
		],
	})
		== Err(StoredDirectory("two names are the same name"))

# Each route asks what it does of `Access`: every conversation's GET reads,
# every write posts, and nothing else asks.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
			?? crash "main's tests: a path is UTF-8",
		directory: first_directory,
	}).map_ok(|found| found.key) ?? crash "main's tests: Steve's own DM is a place"
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png") ?? crash "main's tests: an image's name"
	[
		ShowConversation(key),
		OpenConversationStream(key),
		ServeRawTranscript(key),
		ServeUploadedImage({ key, image }),
	].all(|choice| access_asked(choice) == Asks({ key, act: Read }))
		and [
			AppendToConversation(key),
			SendToConversation(key),
			UploadToConversation(key),
		].all(|choice| access_asked(choice) == Asks({ key, act: Post }))
		and [
			ShowAgents,
			MakeAgent,
			OpenAgentStream,
			InviteAgent(UserId.steve),
		].all(|choice| access_asked(choice) == AsksNoConversation)
}

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
		headers: [("Host", "localhost:9611")].concat(more).map(
			|(name, value)| {
				name: name.to_utf8(),
				value: value.to_utf8(),
			},
		),
		port: 9611,
		public_origin: [],
	}
}

## What `admission_in` makes of `head` in `directory`, `actor` acting, as a
## test reads it: the allowance it admits it with, or its refusal's status
## and headers.
admission_verdict_for : {
	head : Http.RequestHead,
	directory : Directory,
	actor : SignedIn.Actor,
} -> [
	Admitted({ body_most : U64, body_grace_ms : U32 }),
	Refused(U16, List((Str, Str))),
]
admission_verdict_for = |admission|
	match admission_in(admission) {
		Admit(allowance) => Admitted(allowance)
		Refuse(answer) => Refused(
			answer.status,
			answer.headers.map(|h| (Str.from_utf8_lossy(h.name), Str.from_utf8_lossy(h.value))),
		)
	}

## What `admission_in` makes of `head` in the first directory, Steve
## signed in, as a test reads it.
admission_verdict : Http.RequestHead -> [
	Admitted({ body_most : U64, body_grace_ms : U32 }),
	Refused(U16, List((Str, Str))),
]
admission_verdict = |head|
	admission_verdict_for({
		head,
		directory: first_directory,
		actor: SignedIn(demo_viewer),
	})

## The first directory with a second human, Apoorva, id 2, whose own DM,
## `2_2`, Steve may not post in.
with_apoorva : Directory
with_apoorva = {
	apoorva = Name.from_str("Apoorva") ?? crash "main's tests: a name"
	(first_directory.add_human(apoorva) ?? crash "main's tests: Apoorva joins").directory
}

# An upload's room goes to someone signed in who may post there, and to no
# one else: not to no one, and not to one who may not post in the place.
expect
	admission_verdict_for({
		head: head_of("POST /chat/dm/2_2/plans/upload", []),
		directory: with_apoorva,
		actor: SignedIn(demo_viewer),
	})
		== Admitted(form_body_allowance)
expect
	admission_verdict_for({
		head: head_of("POST /chat/dm/1_1/plans/upload", []),
		directory: with_apoorva,
		actor: SignedIn(demo_viewer),
	})
		== Admitted(upload_body_allowance)
expect
	[
		"POST /chat/dm/1_1/plans/upload",
		"POST /chat/channel/general/plans/upload",
		"POST /chat/dm/1_1/plans",
	].all(
		|line|
			admission_verdict_for({
				head: head_of(line, []),
				directory: first_directory,
				actor: Anonymous,
			})
				== Admitted(form_body_allowance),
	)
# A public origin reaches the admission: its Host is this server's when the
# server has it, and a stranger's when it has none.
expect {
	public_head = {
		..head_of("POST /chat/dm/1_1/plans/upload", []),
		headers: [
			{ name: "Host".to_utf8(), value: "chat.example.com".to_utf8() },
			{ name: "Origin".to_utf8(), value: "https://chat.example.com".to_utf8() },
		],
	}
	admission_verdict({
		..public_head,
		public_origin: "https://chat.example.com".to_utf8(),
	}) == Admitted(upload_body_allowance)
		and admission_verdict(public_head) == Refused(403, forbidden_headers)
}
# No one asking for a page is sent to sign in, and back after; any other
# route only someone signed in may use is a 401 to no one.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
			?? crash "main's tests: a path is UTF-8",
		directory: first_directory,
	}).map_ok(|found| found.key) ?? crash "main's tests: Steve's own DM is a place"
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png") ?? crash "main's tests: an image's name"
	shown = anonymous_refusal(ShowConversation(key))
	agents = anonymous_refusal(ShowAgents)
	shown.status == 303
		and shown.headers == [
			{
				name: "location".to_utf8(),
				value: "/login?next=/chat/dm/1_1/plans".to_utf8(),
			},
		]
		and agents.status == 303
		and agents.headers == [
			{
				name: "location".to_utf8(),
				value: "/login?next=/agents".to_utf8(),
			},
		]
		and [
			AppendToConversation(key),
			SendToConversation(key),
			OpenConversationStream(key),
			ServeRawTranscript(key),
			UploadToConversation(key),
			ServeUploadedImage({ key, image }),
			MakeAgent,
			InviteAgent(UserId.steve),
			OpenAgentStream,
		].all(|asked| anonymous_refusal(asked) == no_one_refusal)
		and no_one_refusal.status == 401
		and no_one_refusal.body == "${no_one_words}\n".to_utf8()
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
		head_of(
			"POST /chat/channel/general/plans/upload",
			[("Origin", "http://localhost:9611"), ("Sec-Fetch-Site", "same-origin")],
		),
	].all(|head| admission_verdict(head) == Admitted(upload_body_allowance))
expect
	[
		head_of("POST /chat/dm/1_1/plans", []),
		head_of("POST /x/upload", []),
		head_of("POST /chat/dm/1_2/plans/upload", []),
		head_of("GET /chat/dm/1_1/plans/upload", []),
		head_of("PUT /chat/dm/1_1/plans/upload", []),
		head_of(
			"GET /chat/dm/1_1/plans/stream",
			[("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "navigate")],
		),
		head_of("POST /agents/redeem", []),
	].all(|head| admission_verdict(head) == Admitted(form_body_allowance))
# Refused from its head, whatever its route: a 403 that no other site's page
# may load.
## The headers of the 403 a request from elsewhere is refused with.
forbidden_headers : List((Str, Str))
forbidden_headers = [
	("content-type", "text/html; charset=utf-8"),
	(
		"content-security-policy",
		"default-src 'none'; style-src 'unsafe-inline'; script-src 'self'; img-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; connect-src 'self'",
	),
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
		head_of(
			"GET /chat/dm/1_1/plans/stream",
			[("Sec-Fetch-Site", "same-site"), ("Sec-Fetch-Mode", "no-cors")],
		),
		head_of("POST /agents", [("Origin", "http://evil.example")]),
		{ ..head_of("POST /chat/dm/1_1/plans/upload", []), port: 9612 },
	].all(|head| admission_verdict(head) == Refused(403, forbidden_headers))
# Every answer ends with its resource policy, after its own headers.
expect
	for_this_origin_alone(HttpAnswer.see_other("/a")).headers
		== [
			{ name: "location".to_utf8(), value: "/a".to_utf8() },
			{ name: "cross-origin-resource-policy".to_utf8(), value: "same-origin".to_utf8() },
		]
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

## This module answers a request once the directory is read and who is
## acting is found: `Route` chooses the route, an open route is answered for
## anyone, and any other only for someone signed in, once `Access` admits
## them to read or post where the route asks. No one asking for a page only
## someone signed in may see is sent to sign in, and any other such request
## is a 401. Each route's answer is a route module's: `ConversationRoute`,
## `UploadRoute`, `ReactionRoute`, `BrowseRoute`, `AgentsRoute`, `ChannelMembersRoute`,
## `HumanInvitesRoute`, `RecentRoute`, `ResumeRoute`, `SignInRoute` or `GitHubRoute`.
## Its two `match`es,
## one for the open routes and one for the signed-in ones, show the whole
## server's surface in one place.
import pf.Http
import Access
import AgentsRoute
import BrowseRoute
import ChannelMembersRoute
import Clock
import ConversationKey
import ConversationRoute
import Directory
import Favicon
import FirstStart
import GitHubRoute
import HttpAnswer
import HumanInvitesRoute
import Html
import PageKit
import Place
import PresenceNotices
import ReactionRoute
import RecentRoute
import RequestOrigin
import ResumeRoute
import Route
import SignInRoute
import SignedIn
import UnvalidatedString
import UploadRoute
import UploadedImage
import UserId

Dispatch :: [].{

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
					SignedIn(acting) => serve_signed_in_route!({
						asked,
						request,
						directory,
						acting,
					})
				}
			MethodNotAllowed(allowed) => HttpAnswer.method_not_allowed(allowed)
			NotFound => HttpAnswer.page(404, PageKit.not_found)
		}
}

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
		ReactInConversation(key) => Asks({ place: key.place(), act: Post })
		StartTopic(place) => Asks({ place, act: Post })
		StartGitHubLink => AsksNoConversation
		ShowBrowse => AsksNoConversation
		ShowRecent => AsksNoConversation
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
	HttpAnswer.page(403, PageKit.notice({ title: "Forbidden", text: said }))
}

## The answer to a route only someone signed in may use, asked for by no
## one: a page sends the browser to sign in, and comes back after; any
## other request is a 401.
anonymous_refusal : Route.SignedInChoice -> Http.Response
anonymous_refusal = |asked|
	match asked {
		StartGitHubLink => unauthorized_refusal
		ShowBrowse => SignInRoute.login_redirect(site_path_of(ConversationKey.browse_path))
		ShowRecent => SignInRoute.login_redirect(site_path_of(PageKit.recent_path))
		StartTopic(_) => unauthorized_refusal
		ShowConversation(key) => SignInRoute.login_redirect(site_path_of(key.url_path(Page)))
		ShowAgents => SignInRoute.login_redirect(site_path_of("/agents"))
		ShowChannels => SignInRoute.login_redirect(site_path_of("/channels"))
		ShowChannelMembers(channel) =>
			SignInRoute.login_redirect(site_path_of("/channels/${channel.to_str()}"))
		CreateChannel => unauthorized_refusal
		AddChannelMember(_) => unauthorized_refusal
		RemoveChannelMember(_) => unauthorized_refusal
		ShowInvites => SignInRoute.login_redirect(site_path_of(PageKit.invites_path))
		InviteHuman => unauthorized_refusal
		InviteHumanAgain(_) => unauthorized_refusal
		AppendToConversation(_) => unauthorized_refusal
		SendToConversation(_) => unauthorized_refusal
		OpenConversationStream(_) => unauthorized_refusal
		ServeRawTranscript(_) => unauthorized_refusal
		UploadToConversation(_) => unauthorized_refusal
		ReactInConversation(_) => unauthorized_refusal
		ServeUploadedImage(_) => unauthorized_refusal
		MakeAgent => unauthorized_refusal
		InviteAgent(_) => unauthorized_refusal
		RevokeInvite(_) => unauthorized_refusal
		RevokeKey(_) => unauthorized_refusal
		OpenAgentStream => unauthorized_refusal
	}

## The 500 for a request whose coming online could not be told: a DM's
## topics could not be listed.
presence_failure : Http.Response
presence_failure =
	HttpAnswer.page(
		500,
		PageKit.notice({
			title: "Failed",
			text: "Your DMs' topics could not be read, to tell the others you are online.",
		}),
	)

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
		?? crash "Dispatch.site_path_of: \"${text}\" is a path this server answers, and not a site path"

## The answer to an open route, for `actor`, whoever it is.
answer_open_route! : {
	open : Route.OpenChoice,
	request : Http.Request,
	directory : Directory,
	actor : SignedIn.Actor,
} => Http.Response
answer_open_route! = |{ open, request, directory, actor }|
	match open {
		ResumeOrBrowse => ResumeRoute.answer_way_in!({ actor, directory })
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
				now: Clock.read_clock!({}),
				github: GitHubRoute.load_offer!({}),
			})
		SignOut => SignInRoute.sign_out
		StartGitHubSignIn =>
			GitHubRoute.serve_start!({
				viewer: actor,
				query: request.query,
				origin: own_origin_of(request),
				now: Clock.read_clock!({}),
			})
		FinishGitHubSignIn =>
			GitHubRoute.serve_return!({
				viewer: actor,
				directory,
				query: request.query,
				headers: request.headers,
				now: Clock.read_clock!({}),
			})
		FinishGitHubSignUp =>
			GitHubRoute.serve_sign_up!({
				viewer: actor,
				directory,
				body: request.body,
				headers: request.headers,
				now: Clock.read_clock!({}),
			})
		WrongMethodToGitHub(allowed) => GitHubRoute.refuse_method!(allowed)
		RedeemInvite =>
			AgentsRoute.redeem!({
				actor,
				directory,
				body: request.body,
				now: Clock.read_clock!({}),
			})
		ShowJoin => HumanInvitesRoute.join_page(actor)
		LookUpJoinName =>
			HumanInvitesRoute.serve_join_name!({
				actor,
				directory,
				body: request.body,
				now: Clock.read_clock!({}),
			})
		Join =>
			HumanInvitesRoute.join!({
				actor,
				directory,
				body: request.body,
				now: Clock.read_clock!({}),
			})
	}

## The answer the route `asked` gives `acting`, once `Access` admits them
## and the request is noted for presence (`PresenceNotices`).
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
		Ok({}) => {
			noted = PresenceNotices.note_request!({
				asked,
				acting,
				directory,
				now: Clock.read_clock!({}),
			})
			match noted {
				Ok({}) => answer_route!({ asked, request, directory, acting })
				Err(_) => presence_failure
			}
		}
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
				now: Clock.read_clock!({}),
			})
		ShowBrowse => BrowseRoute.show!({ acting, directory })
		ShowRecent => RecentRoute.show!({ acting, directory })
		StartTopic(place) =>
			BrowseRoute.start_topic!({ acting, directory, place, body: request.body })
		ShowConversation(key) =>
			ConversationRoute.show!({ key, acting, directory })
		OpenConversationStream(key) =>
			ConversationRoute.open_stream!({
				key,
				acting,
				users: directory.users(),
				query: request.query,
				headers: request.headers,
			})
		ServeRawTranscript(key) => ConversationRoute.serve_raw!({ key, query: request.query })
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
		ReactInConversation(key) =>
			ReactionRoute.post_reaction!({
				key,
				acting,
				users: directory.users(),
				body: request.body,
			})
		ShowAgents => AgentsRoute.show!({ acting, directory })
		MakeAgent => AgentsRoute.make!({ acting, directory, body: request.body })
		InviteAgent(agent) =>
			AgentsRoute.invite!({
				acting,
				directory,
				agent,
				body: request.body,
				now: Clock.read_clock!({}),
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
			HumanInvitesRoute.show!({ acting, directory, now: Clock.read_clock!({}) })
		InviteHuman =>
			HumanInvitesRoute.invite!({
				acting,
				directory,
				body: request.body,
				origin: own_origin_of(request),
				now: Clock.read_clock!({}),
			})
		InviteHumanAgain(human) =>
			HumanInvitesRoute.invite_again!({
				acting,
				directory,
				human,
				origin: own_origin_of(request),
				now: Clock.read_clock!({}),
			})
	}

## The origin `request` came to, which main's `handle_http_request!` has
## held to one of this server's own.
own_origin_of : Http.Request -> Str
own_origin_of = |request|
	match RequestOrigin.origin_of_host({
		headers: request.headers,
		port: request.port,
		public_origin: request.public_origin,
	}) {
		Ok(origin) => origin
		Err(_) =>
			crash "Dispatch.own_origin_of: the request's Host passed RequestOrigin.check, so it names one of this server's origins"
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
	now: Clock.read_clock!({}),
	body: request.body,
	agents: Access.agent_members({ place: key.place(), directory }),
}

# ── tests
# Each route asks what it does of `Access`: every conversation's GET reads,
# every write posts, and nothing else asks.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
			?? crash "Dispatch's tests: a path is UTF-8",
		directory: FirstStart.first_directory,
	}).map_ok(|found| found.key) ?? crash "Dispatch's tests: Steve's own DM is a place"
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png") ?? crash "Dispatch's tests: an image's name"
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
			ReactInConversation(key),
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

# No one asking for a page is sent to sign in, and back after; any other
# route only someone signed in may use is a 401 to no one.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
			?? crash "Dispatch's tests: a path is UTF-8",
		directory: FirstStart.first_directory,
	}).map_ok(|found| found.key) ?? crash "Dispatch's tests: Steve's own DM is a place"
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png") ?? crash "Dispatch's tests: an image's name"
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
			ReactInConversation(key),
			ServeUploadedImage({ key, image }),
			MakeAgent,
			InviteAgent(UserId.chat_owner),
			OpenAgentStream,
			StartGitHubLink,
		].all(|asked| anonymous_refusal(asked) == unauthorized_refusal)
		and unauthorized_refusal.status == 401
		and unauthorized_refusal.body == "${unauthorized_words}\n".to_utf8()
}

# Each access refusal: a 403 saying which.
expect access_refusal(NotAMember).status == 403 and access_refusal(ScopeOff).status == 403
expect access_refusal(NotAMember).body != access_refusal(ScopeOff).body

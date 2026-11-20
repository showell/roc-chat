## This module answers a request once the directory is read and who is
## acting is found: `Route` chooses the route, an open route is answered for
## anyone, and any other only for someone signed in, once `Access` admits
## them to read or post where the route asks. No one asking for a page only
## someone signed in may see is sent to sign in, and any other such request
## is a 401. Each route's answer is a route module's (each `*Route`
## imported below); a signed-in route asked for by no one is
## `AnonymousRefusal`'s. Its two `match`es, one for the open routes and one
## for the signed-in ones, show the whole server's surface in one place.
import pf.Http
import Access
import AgentsRoute
import AnonymousRefusal
import BrowseRoute
import ChannelMembersRoute
import Clock
import ConversationKey
import ConversationRoute
import DeviceCodeRoute
import DeviceSessionsRoute
import DownloadRoute
import Directory
import Favicon
import FirstStart
import FullSessionRoutes
import GitHubRoute
import GitHubSignUpRoute
import HttpAnswer
import HumanInvitesRoute
import MessageLink
import MessageLinkRoute
import PageKit
import Place
import PresenceNotices
import ReactionRoute
import RecentRoute
import RequestOrigin
import ResumeRoute
import Route
import SearchRoute
import SignInRoute
import SignOutRoute
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
	serve_route! = |{ request, directory, actor }| {
		choice = Route.choose({ method: request.method, path: request.path, directory })
		match FullSessionRoutes.refusal_for({ choice, actor }) {
			StartedByDeviceCode =>
				HttpAnswer.page(
					403,
					PageKit.notice({ title: "Refused", text: FullSessionRoutes.refusal_words }),
				)
			Allowed => serve_chosen_route!({ choice, request, directory, actor })
		}
	}
}

## The answer to `choice`, for `actor`: an open route's to anyone; any
## other's to someone signed in alone, once `Access` admits them.
serve_chosen_route! : {
	choice : Route.Choice,
	request : Http.Request,
	directory : Directory,
	actor : SignedIn.Actor,
} => Http.Response
serve_chosen_route! = |{ choice, request, directory, actor }|
	match choice {
		Open(open) => answer_open_route!({ open, request, directory, actor })
		SignedInOnly(asked) =>
			match actor {
				Anonymous => AnonymousRefusal.answer(asked)
				SignedIn(acting) => serve_signed_in_route!({ asked, request, directory, acting })
			}
		MethodNotAllowed(allowed) => HttpAnswer.method_not_allowed(allowed)
		NotFound => HttpAnswer.page(404, PageKit.not_found)
	}

## What a route asks of `Access` before it is answered: to read or post at
## a place, to read wherever the reader may (a credential that reads), or
## nothing.
access_asked : Route.SignedInChoice -> [
	Asks({ place : Place, act : Access.Act }),
	AsksAnyPlace(Access.Act),
	AsksNoConversation,
]
access_asked = |asked|
	match asked {
		ShowConversation(key) => Asks({ place: key.place(), act: Read })
		OpenConversationStream(key) => Asks({ place: key.place(), act: Read })
		ServeRawTranscript(key) => Asks({ place: key.place(), act: Read })
		ServeDownload(key) => Asks({ place: key.place(), act: Read })
		ServeUploadedImage(found) => Asks({ place: found.key.place(), act: Read })
		AppendToConversation(key) => Asks({ place: key.place(), act: Post })
		SendToConversation(key) => Asks({ place: key.place(), act: Post })
		UploadToConversation(key) => Asks({ place: key.place(), act: Post })
		ReactInConversation(key) => Asks({ place: key.place(), act: Post })
		StartTopic(place) => Asks({ place, act: Post })
		FollowConversationLink(followed) => Asks({ place: followed.key.place(), act: Read })
		FollowTopicLink(_) => AsksAnyPlace(Read)
		StartGitHubLink => AsksNoConversation
		ShowBrowse => AsksNoConversation
		ShowRecent => AsksNoConversation
		OpenRecentStream | SearchEveryTopic(_) => AsksNoConversation
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
		ShowDeviceCode => AsksNoConversation
		MakeDeviceCode => AsksNoConversation
		CancelDeviceCode => AsksNoConversation
		OpenDevicesStream => AsksNoConversation
		SignOutOtherDevices => AsksNoConversation
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
		ServeAlertIcon => HttpAnswer.svg_icon(Favicon.alert_bytes)
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
		SignOut => SignOutRoute.sign_out!({ actor, body: request.body })
		RedeemDeviceCode =>
			DeviceCodeRoute.redeem!({
				viewer: actor,
				users: directory.users(),
				headers: request.headers,
				body: request.body,
				now: Clock.read_clock!({}),
				github: GitHubRoute.load_offer!({}),
			})
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
		GitHubSignUpStep(step) =>
			GitHubSignUpRoute.serve!({
				step,
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
			AsksAnyPlace(act) =>
				Access.check_credential({ acting, act }).map_err(|ScopeOff| ScopeOff)
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
				Err(_) => PresenceNotices.presence_failure
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
		OpenRecentStream => RecentRoute.open_stream(acting)
		SearchEveryTopic(asked_of) => SearchRoute.serve!({ asked_of, acting, directory, request })
		FollowTopicLink(link) => MessageLinkRoute.answer_topic_link!({ link, acting, directory })
		FollowConversationLink(followed) => MessageLinkRoute.answer_channel_link!(followed)
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
		ServeDownload(key) => DownloadRoute.serve_download!({ key, now: Clock.read_clock!({}) })
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
		ShowDeviceCode =>
			DeviceCodeRoute.show!({
				acting,
				headers: request.headers,
				now: Clock.read_clock!({}),
				origin: own_origin_of(request),
			})
		MakeDeviceCode =>
			DeviceCodeRoute.make!({ acting, users: directory.users(), now: Clock.read_clock!({}) })
		CancelDeviceCode => DeviceCodeRoute.revoke!(acting)
		OpenDevicesStream => DeviceCodeRoute.open_stream(acting)
		SignOutOtherDevices =>
			DeviceSessionsRoute.sign_out_other_devices!({ acting, now: Clock.read_clock!({}) })
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
	readers: Access.members({ place: key.place(), directory }),
}

# ── tests
# Each route asks what it does of `Access`: every conversation's GET reads,
# a channel's link reads its conversation, a topic's link asks for a
# credential that reads, every write posts, and nothing else asks.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
			?? crash "Dispatch's tests: a path is UTF-8",
		directory: FirstStart.first_directory,
	}).map_ok(|found| found.key) ?? crash "Dispatch's tests: Steve's own DM is a place"
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png") ?? crash "Dispatch's tests: an image's name"
	link = MessageLink.from_str("plans_1") ?? crash "Dispatch's tests: a link"
	[
		ShowConversation(key),
		OpenConversationStream(key),
		ServeRawTranscript(key),
		ServeDownload(key),
		ServeUploadedImage({ key, image }),
		FollowConversationLink({ key, link }),
	].all(|choice| access_asked(choice) == Asks({ place: key.place(), act: Read }))
		and access_asked(FollowTopicLink(link)) == AsksAnyPlace(Read)
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

# Each access refusal: a 403 saying which.
expect access_refusal(NotAMember).status == 403 and access_refusal(ScopeOff).status == 403
expect access_refusal(NotAMember).body != access_refusal(ScopeOff).body
expect
	access_refusal(NotAMember)
		== HttpAnswer.page(
			403,
			PageKit.notice({
				title: "Forbidden",
				text: "Only the members of this conversation's channel or DM may read or post in it.",
			}),
		)
expect
	access_refusal(ScopeOff)
		== HttpAnswer.page(403, PageKit.notice({ title: "Forbidden", text: "This API key's scope doesn't reach that." }))

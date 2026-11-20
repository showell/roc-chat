## This module answers a route only someone signed in may use (`Route`'s
## `SignedInOnly`) when the request proves no one, as `Dispatch` asks: a
## page sends the browser to sign in, and back after; any other request is
## a 401 that says how to sign in.
import pf.Http
import AgentInvite
import AgentKey
import ChannelName
import ConversationKey
import DeviceCodePage
import FirstStart
import Html
import HttpAnswer
import MessageLink
import PageKit
import Route
import SignInRoute
import UnvalidatedString
import UploadedImage
import UserId

AnonymousRefusal :: [].{

	## The answer to `asked`, a route only someone signed in may use, asked
	## for by no one.
	answer : Route.SignedInChoice -> Http.Response
	answer = |asked|
		match asked {
			StartGitHubLink => unauthorized_refusal
			ShowBrowse => SignInRoute.login_redirect(site_path_of(ConversationKey.browse_path))
			ShowRecent => SignInRoute.login_redirect(site_path_of(PageKit.recent_path))
			OpenRecentStream | SearchEveryTopic(_) => unauthorized_refusal
			FollowTopicLink(link) => SignInRoute.login_redirect(site_path_of(link.url_path()))
			FollowConversationLink({ key: _, link }) =>
				SignInRoute.login_redirect(site_path_of(link.url_path()))
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
			ShowDeviceCode => SignInRoute.login_redirect(site_path_of(DeviceCodePage.path))
			MakeDeviceCode => unauthorized_refusal
			CancelDeviceCode => unauthorized_refusal
			OpenDevicesStream => unauthorized_refusal
			SignOutOtherDevices => unauthorized_refusal
			AppendToConversation(_) => unauthorized_refusal
			SendToConversation(_) => unauthorized_refusal
			OpenConversationStream(_) => unauthorized_refusal
			ServeRawTranscript(_) => unauthorized_refusal
			ServeDownload(_) => unauthorized_refusal
			UploadToConversation(_) => unauthorized_refusal
			ReactInConversation(_) => unauthorized_refusal
			ServeUploadedImage(_) => unauthorized_refusal
			MakeAgent => unauthorized_refusal
			InviteAgent(_) => unauthorized_refusal
			RevokeInvite(_) => unauthorized_refusal
			RevokeKey(_) => unauthorized_refusal
			OpenAgentStream => unauthorized_refusal
		}
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
		?? crash "AnonymousRefusal.site_path_of: \"${text}\" is a path this server answers, and not a site path"

# ── tests
# No one asking for a page is sent to sign in, and back after; any other
# route only someone signed in may use is a 401 to no one.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
			?? crash "AnonymousRefusal's tests: a path is UTF-8",
		directory: FirstStart.first_directory,
	}).map_ok(|found| found.key) ?? crash "AnonymousRefusal's tests: Steve's own DM is a place"
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png") ?? crash "AnonymousRefusal's tests: an image's name"
	shown = AnonymousRefusal.answer(ShowConversation(key))
	agents = AnonymousRefusal.answer(ShowAgents)
	browse = AnonymousRefusal.answer(ShowBrowse)
	devices = AnonymousRefusal.answer(ShowDeviceCode)
	link = MessageLink.from_str("general.plans_1") ?? crash "AnonymousRefusal's tests: a link"
	by_topic = AnonymousRefusal.answer(
		FollowTopicLink(MessageLink.from_str("plans_1") ?? crash "AnonymousRefusal's tests: a link"),
	)
	in_conversation = AnonymousRefusal.answer(FollowConversationLink({ key, link }))
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
		and devices.headers == [
			{ name: "location".to_utf8(), value: "/login?next=/devices".to_utf8() },
		]
		and by_topic.headers == [
			{ name: "location".to_utf8(), value: "/login?next=/chat/msg/plans_1".to_utf8() },
		]
		and in_conversation.headers == [
			{ name: "location".to_utf8(), value: "/login?next=/chat/msg/general.plans_1".to_utf8() },
		]
		and [
			StartTopic(key.place()),
			AppendToConversation(key),
			SendToConversation(key),
			OpenConversationStream(key),
			ServeRawTranscript(key),
			ServeDownload(key),
			UploadToConversation(key),
			ReactInConversation(key),
			ServeUploadedImage({ key, image }),
			MakeAgent,
			InviteAgent(UserId.chat_owner),
			OpenAgentStream,
			StartGitHubLink,
			MakeDeviceCode,
		].all(|asked| AnonymousRefusal.answer(asked) == unauthorized_refusal)
		and unauthorized_refusal.status == 401
		and unauthorized_refusal.body == "${unauthorized_words}\n".to_utf8()
}
# The rest of the pages, each sent to sign in and back to itself; the rest
# of the routes, each the one 401.
expect {
	team = ChannelName.from_str("team") ?? crash "AnonymousRefusal's tests: a channel's name"
	key = AgentKey.Id.from_str("1") ?? crash "AnonymousRefusal's tests: a key's number"
	invite = AgentInvite.Id.from_str("1") ?? crash "AnonymousRefusal's tests: an invite's number"
	member = UserId.chat_owner
	[
		(ShowRecent, "/chat/recent"),
		(ShowChannels, "/channels"),
		(ShowChannelMembers(team), "/channels/team"),
		(ShowInvites, "/invites"),
	].all(
		|(asked, next)| {
			answer = AnonymousRefusal.answer(asked)
			answer.status == 303
				and answer.headers == [{ name: "location".to_utf8(), value: "/login?next=${next}".to_utf8() }]
		},
	)
		and [
			OpenRecentStream,
			SearchEveryTopic(Words),
			SearchEveryTopic(Messages),
			CreateChannel,
			AddChannelMember({ channel: team, member }),
			RemoveChannelMember({ channel: team, member }),
			InviteHuman,
			InviteHumanAgain(member),
			CancelDeviceCode,
			OpenDevicesStream,
			SignOutOtherDevices,
			RevokeInvite({ agent: member, invite }),
			RevokeKey({ agent: member, key }),
		].all(|asked| AnonymousRefusal.answer(asked) == unauthorized_refusal)
}

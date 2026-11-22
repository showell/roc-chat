## This module decides which routes a session started by a device code may
## not use (`SignedIn.check_full_session`): what would hand out a credential
## or take one from the human's other devices. That is linking GitHub, by
## its button or by going through GitHub while signed in; making agents,
## inviting them, and revoking their invites and keys; inviting a human, or
## inviting one again, which makes a link to set the password of a human
## who hasn't joined; the channels' admin
## pages, creating a channel and adding or removing its members; and making
## or cancelling a device code, or signing the human's other devices out. Such a device
## signs in with a password or GitHub first, after signing out, for those;
## everything else it does as any session does. `Dispatch` asks before answering any route, and
## answers a refusal with a 403 saying `refusal_words`.
import Route
import SignedIn

FullSessionRoutes :: [].{

	## Whether `actor` may use `choice`: `StartedByDeviceCode` when the route
	## asks for a full session and `actor`'s was started by a device code;
	## else `Allowed`. Each pair is named, so a new way a session is started,
	## or a new kind of route, is a decision here.
	refusal_for : {
		choice : Route.Choice,
		actor : SignedIn.Actor,
	} -> [Allowed, StartedByDeviceCode]
	refusal_for = |{ choice, actor }|
		match actor {
			Anonymous => Allowed
			SignedIn(acting) =>
				match (acting.check_full_session(), session_asked(choice)) {
					(Err(StartedByDeviceCode), FullSession) => StartedByDeviceCode
					(Err(StartedByDeviceCode), AnySession) => Allowed
					(Ok({}), FullSession) | (Ok({}), AnySession) => Allowed
				}
		}

	## What the refusal of a session a device code started says.
	refusal_words : Str
	refusal_words = "This device signed in with a code from another device. To invite people, manage channels or agents, link GitHub, make device codes or sign other devices out, sign out here, then sign in with your password or GitHub."
}

## The session `choice` asks for: `FullSession`, one no device code started,
## or `AnySession`. Every route is named, so a new one is a decision here.
session_asked : Route.Choice -> [FullSession, AnySession]
session_asked = |choice|
	match choice {
		SignedInOnly(UploadToConversation(_)) => AnySession
		SignedInOnly(StartGitHubLink) => FullSession
		SignedInOnly(ShowBrowse) => AnySession
		SignedInOnly(ShowRecent) => AnySession
		SignedInOnly(OpenRecentStream) => AnySession
		SignedInOnly(SearchEveryTopic(_)) => AnySession
		SignedInOnly(FollowTopicLink(_)) => AnySession
		SignedInOnly(FollowConversationLink(_)) => AnySession
		SignedInOnly(StartTopic(_)) => AnySession
		SignedInOnly(ShowConversation(_)) => AnySession
		SignedInOnly(AppendToConversation(_)) => AnySession
		SignedInOnly(SendToConversation(_)) => AnySession
		SignedInOnly(OpenConversationStream(_)) => AnySession
		SignedInOnly(ServeRawTranscript(_)) => AnySession
		SignedInOnly(ServeDownload(_)) => AnySession
		SignedInOnly(ServeUploadedImage(_)) => AnySession
		SignedInOnly(ReactInConversation(_)) => AnySession
		SignedInOnly(ShowAgents) => AnySession
		SignedInOnly(MakeAgent) => FullSession
		SignedInOnly(InviteAgent(_)) => FullSession
		SignedInOnly(RevokeInvite(_)) => FullSession
		SignedInOnly(RevokeKey(_)) => FullSession
		SignedInOnly(OpenAgentStream) => AnySession
		SignedInOnly(ShowChannels) => FullSession
		SignedInOnly(CreateChannel) => FullSession
		SignedInOnly(ShowChannelMembers(_)) => FullSession
		SignedInOnly(AddChannelMember(_)) => FullSession
		SignedInOnly(RemoveChannelMember(_)) => FullSession
		SignedInOnly(ShowInvites) => AnySession
		SignedInOnly(InviteHuman) => FullSession
		SignedInOnly(InviteHumanAgain(_)) => FullSession
		SignedInOnly(ShowDeviceCode) => AnySession
		SignedInOnly(MakeDeviceCode) => FullSession
		SignedInOnly(CancelDeviceCode) => FullSession
		SignedInOnly(OpenDevicesStream) => AnySession
		SignedInOnly(SignOutOtherDevices) => FullSession
		Open(RedeemDeviceCode) => AnySession
		Open(ReturnToLogin) => AnySession
		Open(ResumeOrBrowse) => AnySession
		Open(ShowJoin) => AnySession
		Open(LookUpJoinName) => AnySession
		Open(Join) => AnySession
		Open(ServeScript(_)) => AnySession
		Open(ServeFavicon) => AnySession
		Open(ServeAlertIcon) => AnySession
		Open(ShowLogin) => AnySession
		Open(SignIn) => AnySession
		Open(SignOut) => AnySession
		Open(StartGitHubSignIn) => FullSession
		Open(FinishGitHubSignIn) => FullSession
		Open(GitHubSignUpStep(_)) => AnySession
		Open(WrongMethodToGitHub(_)) => AnySession
		Open(RedeemInvite) => AnySession
		NotFound => AnySession
		MethodNotAllowed(_) => AnySession
	}

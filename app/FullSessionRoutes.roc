## This module decides which routes a session started by a device code may
## not use (`SignedIn.check_full_session`): what would hand out a credential
## or take one from the human's other devices. That is linking GitHub, by
## its button or by going through GitHub while signed in; making agents,
## inviting them, and revoking their invites and keys; inviting a human, or
## inviting one again, which sets their password; the channels' admin
## pages, creating a channel and adding or removing its members; and making
## or cancelling a device code, or signing the human's other devices out. Such a device
## signs in with a password or GitHub first, after signing out, for those;
## everything else it does as any session does. `Dispatch` asks before answering any route, and
## answers a refusal with a 403 saying `refusal_words`.
import Route
import SignedIn

FullSessionRoutes :: [].{

	## Whether `actor` may use `choice`: `StartedByDeviceCode` when the route
	## asks for a session no device code started and `actor`'s was; else
	## `Allowed`.
	refusal_for : {
		choice : Route.Choice,
		actor : SignedIn.Actor,
	} -> [Allowed, StartedByDeviceCode]
	refusal_for = |{ choice, actor }|
		match actor {
			Anonymous => Allowed
			SignedIn(acting) =>
				match (acting.check_full_session(), asks_full_session(choice)) {
					(Err(StartedByDeviceCode), Bool.True) => StartedByDeviceCode
					_ => Allowed
				}
		}

	## What the refusal of a session a device code started says.
	refusal_words : Str
	refusal_words = "This device signed in with a code from another device. To invite people, manage channels or agents, link GitHub, make device codes or sign other devices out, sign out here, then sign in with your password or GitHub."
}

## Whether `choice` asks for a session no device code started: every route
## named, so a new one is a decision here.
asks_full_session : Route.Choice -> Bool
asks_full_session = |choice|
	match choice {
		SignedInOnly(UploadToConversation(_)) => Bool.False
		SignedInOnly(StartGitHubLink) => Bool.True
		SignedInOnly(ShowBrowse) => Bool.False
		SignedInOnly(ShowRecent) => Bool.False
		SignedInOnly(OpenRecentStream) => Bool.False
		SignedInOnly(SearchEveryTopic(_)) => Bool.False
		SignedInOnly(StartTopic(_)) => Bool.False
		SignedInOnly(ShowConversation(_)) => Bool.False
		SignedInOnly(AppendToConversation(_)) => Bool.False
		SignedInOnly(SendToConversation(_)) => Bool.False
		SignedInOnly(OpenConversationStream(_)) => Bool.False
		SignedInOnly(ServeRawTranscript(_)) => Bool.False
		SignedInOnly(ServeDownload(_)) => Bool.False
		SignedInOnly(ServeUploadedImage(_)) => Bool.False
		SignedInOnly(ReactInConversation(_)) => Bool.False
		SignedInOnly(ShowAgents) => Bool.False
		SignedInOnly(MakeAgent) => Bool.True
		SignedInOnly(InviteAgent(_)) => Bool.True
		SignedInOnly(RevokeInvite(_)) => Bool.True
		SignedInOnly(RevokeKey(_)) => Bool.True
		SignedInOnly(OpenAgentStream) => Bool.False
		SignedInOnly(ShowChannels) => Bool.True
		SignedInOnly(CreateChannel) => Bool.True
		SignedInOnly(ShowChannelMembers(_)) => Bool.True
		SignedInOnly(AddChannelMember(_)) => Bool.True
		SignedInOnly(RemoveChannelMember(_)) => Bool.True
		SignedInOnly(ShowInvites) => Bool.False
		SignedInOnly(InviteHuman) => Bool.True
		SignedInOnly(InviteHumanAgain(_)) => Bool.True
		SignedInOnly(ShowDeviceCode) => Bool.False
		SignedInOnly(MakeDeviceCode) => Bool.True
		SignedInOnly(CancelDeviceCode) => Bool.True
		SignedInOnly(OpenDevicesStream) => Bool.False
		SignedInOnly(SignOutOtherDevices) => Bool.True
		Open(RedeemDeviceCode) => Bool.False
		Open(ResumeOrBrowse) => Bool.False
		Open(ShowJoin) => Bool.False
		Open(LookUpJoinName) => Bool.False
		Open(Join) => Bool.False
		Open(ServeScript(_)) => Bool.False
		Open(ServeFavicon) => Bool.False
		Open(ServeAlertIcon) => Bool.False
		Open(ShowLogin) => Bool.False
		Open(SignIn) => Bool.False
		Open(SignOut) => Bool.False
		Open(StartGitHubSignIn) => Bool.True
		Open(FinishGitHubSignIn) => Bool.True
		Open(GitHubSignUpStep(_)) => Bool.False
		Open(WrongMethodToGitHub(_)) => Bool.False
		Open(RedeemInvite) => Bool.False
		NotFound => Bool.False
		MethodNotAllowed(_) => Bool.False
	}

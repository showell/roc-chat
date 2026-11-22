## This module says, for every route, how its file calls grow as the chat
## grows, so a route that reads more as humans join is a decision written
## here rather than a surprise. The directory is kept in memory between
## requests (`DirectoryCache`), so a request's file calls are its route's
## own:
##
## - `Constant`: the same calls however many humans the chat has. They may
##   still grow with what the request names: one transcript, one agent's
##   keys or one human's invites.
## - `PerReaderPlaces`: a listing for each place the reader may open, and
##   every human is one of the reader's DMs.
## - `PerHuman`: a read, or several, of every human's files.
##
## Beside its route's cost, a human's request that brings them online lists
## every other human's DM once (`PresenceNotices`), whatever the route.
##
## Every route is written out, so a new route must declare its cost before
## it compiles. `zig build cost-check` (host/cost_check.zig) measures each
## probe of app/route_cost_probes.txt at 10 and 300 humans and holds it to
## its class, and `RouteCostSpec` holds each probe's route to the class its
## line names.
import Route

RouteCost :: [].{

	## How a route's file calls grow with the chat's humans.
	Class : [Constant, PerReaderPlaces, PerHuman]

	## The class of the route `choice`.
	class_of : Route.Choice -> RouteCost.Class
	class_of = |choice|
		match choice {
			Open(ResumeOrBrowse) => Constant
			Open(ServeScript(_)) => Constant
			Open(ServeFavicon) => Constant
			Open(ServeAlertIcon) => Constant
			Open(ShowLogin) => Constant
			Open(SignIn) => Constant
			Open(SignOut) => Constant
			Open(StartGitHubSignIn) => Constant
			Open(FinishGitHubSignIn) => PerHuman
			Open(GitHubSignUpStep(ShowForm)) => Constant
			Open(GitHubSignUpStep(SubmitName)) => PerHuman
			Open(WrongMethodToGitHub(_)) => Constant
			Open(RedeemInvite) => Constant
			Open(ShowJoin) => Constant
			Open(LookUpJoinName) => Constant
			Open(Join) => Constant
			Open(RedeemDeviceCode) => PerHuman
			Open(ReturnToLogin) => Constant
			SignedInOnly(StartGitHubLink) => Constant
			SignedInOnly(ShowBrowse) => PerReaderPlaces
			SignedInOnly(ShowRecent) => PerReaderPlaces
			SignedInOnly(OpenRecentStream) => Constant
			SignedInOnly(SearchEveryTopic(_)) => PerReaderPlaces
			SignedInOnly(FollowTopicLink(_)) => PerReaderPlaces
			SignedInOnly(FollowConversationLink(_)) => Constant
			SignedInOnly(StartTopic(_)) => PerReaderPlaces
			SignedInOnly(ShowConversation(_)) => PerReaderPlaces
			SignedInOnly(AppendToConversation(_)) => Constant
			SignedInOnly(SendToConversation(_)) => Constant
			SignedInOnly(OpenConversationStream(_)) => Constant
			SignedInOnly(ServeRawTranscript(_)) => Constant
			SignedInOnly(ServeDownload(_)) => Constant
			SignedInOnly(UploadToConversation(_)) => Constant
			SignedInOnly(ReactInConversation(_)) => Constant
			SignedInOnly(ServeUploadedImage(_)) => Constant
			SignedInOnly(ShowAgents) => Constant
			SignedInOnly(MakeAgent) => Constant
			SignedInOnly(InviteAgent(_)) => Constant
			SignedInOnly(RevokeInvite(_)) => Constant
			SignedInOnly(RevokeKey(_)) => Constant
			SignedInOnly(OpenAgentStream) => Constant
			SignedInOnly(ShowChannels) => Constant
			SignedInOnly(CreateChannel) => Constant
			SignedInOnly(ShowChannelMembers(_)) => Constant
			SignedInOnly(AddChannelMember(_)) => Constant
			SignedInOnly(RemoveChannelMember(_)) => Constant
			SignedInOnly(ShowInvites) => PerHuman
			SignedInOnly(InviteHuman) => PerHuman
			SignedInOnly(InviteHumanAgain(_)) => PerHuman
			SignedInOnly(ShowDeviceCode) => Constant
			SignedInOnly(MakeDeviceCode) => PerHuman
			SignedInOnly(CancelDeviceCode) => Constant
			SignedInOnly(OpenDevicesStream) => Constant
			SignedInOnly(SignOutOtherDevices) => Constant
			NotFound => Constant
			MethodNotAllowed(_) => Constant
		}

	## The class's name, as app/route_cost_probes.txt writes it.
	class_name : RouteCost.Class -> Str
	class_name = |class|
		match class {
			Constant => "Constant"
			PerReaderPlaces => "PerReaderPlaces"
			PerHuman => "PerHuman"
		}
}

# ── tests
# Each class's name.
expect
	[(Constant, "Constant"), (PerReaderPlaces, "PerReaderPlaces"), (PerHuman, "PerHuman")].all(
		|(class, name)| RouteCost.class_name(class) == name,
	)

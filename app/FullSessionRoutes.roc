## This module decides which routes a session started by a device code may
## not use (`SignedIn.check_full_session`): what would hand out a credential
## or take one from the human's other devices. That is linking GitHub, by
## its button or by going through GitHub while signed in; making agents,
## inviting them, and revoking their invites and keys; inviting a human, or
## inviting one again, which sets their password; and making or cancelling
## a device code, or signing the human's other devices out. Such a device
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
	refusal_words = "This device signed in with a code from another device. To invite people, manage agents, link GitHub, make device codes or sign other devices out, sign out here, then sign in with your password or GitHub."
}

## Whether `choice` asks for a session no device code started.
asks_full_session : Route.Choice -> Bool
asks_full_session = |choice|
	match choice {
		SignedInOnly(StartGitHubLink) => Bool.True
		SignedInOnly(MakeAgent) => Bool.True
		SignedInOnly(InviteAgent(_)) => Bool.True
		SignedInOnly(RevokeInvite(_)) => Bool.True
		SignedInOnly(RevokeKey(_)) => Bool.True
		SignedInOnly(InviteHuman) => Bool.True
		SignedInOnly(InviteHumanAgain(_)) => Bool.True
		SignedInOnly(MakeDeviceCode) => Bool.True
		SignedInOnly(CancelDeviceCode) => Bool.True
		SignedInOnly(SignOutOtherDevices) => Bool.True
		Open(StartGitHubSignIn) => Bool.True
		Open(FinishGitHubSignIn) => Bool.True
		_ => Bool.False
	}

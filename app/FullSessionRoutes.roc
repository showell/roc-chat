## This module decides which routes a session started by a device code may
## not use (`SignedIn.check_full_session`): linking GitHub, by its button or
## by going through GitHub while signed in, and making agents or their
## invites, from which keys come. Such a device signs in with a password or
## GitHub first, after signing out, for those; everything else it does as
## any session does. `Dispatch` asks before answering any route, and
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
	refusal_words = "This device signed in with a code from another device. To link GitHub, or to make agents or their invites, sign out here, then sign in with your password or GitHub."
}

## Whether `choice` asks for a session no device code started.
asks_full_session : Route.Choice -> Bool
asks_full_session = |choice|
	match choice {
		SignedInOnly(StartGitHubLink) => Bool.True
		SignedInOnly(MakeAgent) => Bool.True
		SignedInOnly(InviteAgent(_)) => Bool.True
		Open(StartGitHubSignIn) => Bool.True
		Open(FinishGitHubSignIn) => Bool.True
		_ => Bool.False
	}

## This module lists every way a sign-in with GitHub can be refused. The steps
## of `GitHubSignIn` refuse with these tags themselves, `Welcome` with
## `ClockOutOfRange`, and `GitHubRoute` puts each one into words. It reads the
## union as `GitHubSignIn.Refusal`.
GitHubRefusal :: [].{

	## Every refusal, as `GitHubRoute` takes it.
	Reason : [
		## The state did not come back signed by this server.
		StateForged,

		## The state is not this browser's: another site's doing, or a
		## browser that lost its cookie.
		StateMismatched,

		## The state is out of its window (`GitHubState.lifetime_seconds`).
		StateExpired,

		## GitHub sent the browser back with no code: the human said no.
		GitHubDenied,

		## The code is not one GitHub would send.
		NotACode,

		## GitHub refused the code: spent, expired, or the client's
		## credentials are wrong.
		CodeRefused,

		## GitHub didn't answer, or its answer made no sense.
		GitHubUnreachable,

		## GitHub's answer is no identity: an id of 0, or a login that isn't.
		BadIdentity,

		## More than one human holds the id.
		DuplicateAccount,

		## The sign-up did not come back signed by this server.
		SignUpForged,

		## The sign-up is out of its window (`GitHubSignUp.check`).
		SignUpExpired,

		## The sign-up's id has an account now, which signs in with GitHub.
		AccountExists,

		## The default channel is gone, so a new human has nowhere to start.
		NoDefaultChannel,

		## The session that came back is not the human the link's state names.
		LinkNotYours,

		## The human linking has a `github-id` already.
		AlreadyLinked,

		## Someone holds the id the human tried to link.
		GitHubIdTaken,

		## A sign-up came back from a browser signed in by then, whose human
		## links GitHub rather than making an account.
		SignedInAlready,

		## The server's clock can't date a new human's welcome.
		ClockOutOfRange,
	]
}

## This module lists every way a sign-in with GitHub can be refused, and puts
## each one into words under its status (`refusal_said`), which `GitHubRoute`
## shows on the sign-in page. The steps of `GitHubSignIn` refuse with these
## tags themselves, `Welcome` with `ClockOutOfRange`. It reads the union as
## `GitHubSignIn.Refusal`.
import Channels
import SignUpLimits

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

		## The server already has its most exchanges with GitHub at once, so
		## this one was not asked.
		GitHubBusy,

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

		## A limit on new accounts is reached (`SignUpLimits`).
		SignUpsPaused,
	]

	## A refusal's status and its words. Nothing here says more than the human
	## needs: what went wrong, and what to do.
	refusal_said : GitHubRefusal.Reason -> { status : U16, words : Str }
	refusal_said = |why|
		match why {
			StateForged => { status: 403, words: start_again_words }
			StateMismatched => { status: 403, words: start_again_words }
			StateExpired => { status: 403, words: "That sign-in took too long. Please try again." }
			GitHubDenied => { status: 403, words: "GitHub did not sign you in." }
			NotACode => { status: 403, words: start_again_words }
			CodeRefused => { status: 403, words: "GitHub refused that sign-in. Please try again." }
			GitHubUnreachable => { status: 502, words: "GitHub did not answer. Please try again." }
			GitHubBusy => {
				status: 429,
				words: "Too many sign-ins with GitHub at once. Please try again in a moment.",
			}
			BadIdentity => {
				status: 502,
				words: "GitHub's answer made no sense. Please try again.",
			}
			DuplicateAccount =>
				{ status: 403, words: "That GitHub account is tied to more than one account here." }
			SignUpForged => {
				status: 403,
				words: "That sign-up did not start in this browser. Please try again.",
			}
			SignUpExpired => { status: 403, words: "That sign-up took too long. Please try again." }
			AccountExists => {
				status: 403,
				words: "That GitHub account has an account here. Sign in with GitHub.",
			}
			NoDefaultChannel => { status: 500, words: no_default_channel_words }
			LinkNotYours => {
				status: 403,
				words: "That link did not start from this account. Please try again.",
			}
			AlreadyLinked => { status: 409, words: "You have linked GitHub already." }
			GitHubIdTaken => {
				status: 409,
				words: "That GitHub account is linked to someone here already.",
			}
			SignedInAlready => {
				status: 409,
				words: "You are signed in, so that made no new account. Sign in with GitHub again to link it to this one.",
			}
			ClockOutOfRange => { status: 500, words: "The server's clock is out of range." }
			SignUpsPaused => { status: 503, words: SignUpLimits.paused_words }
		}
}

no_default_channel_words : Str
no_default_channel_words = "This chat has no ${Channels.default_name.to_str()} channel for a new human to start in."

start_again_words : Str
start_again_words = "That sign-in did not start in this browser. Please try again."

# ── tests
# Every refusal has words, and a 5xx only when GitHub is at fault.
expect
	[
		StateForged,
		StateMismatched,
		StateExpired,
		GitHubDenied,
		NotACode,
		CodeRefused,
		DuplicateAccount,
		SignUpForged,
		SignUpExpired,
		AccountExists,
		LinkNotYours,
	].all(|why| GitHubRefusal.refusal_said(why).status == 403)
expect [GitHubUnreachable, BadIdentity].all(|why| GitHubRefusal.refusal_said(why).status == 502)
expect GitHubRefusal.refusal_said(GitHubBusy).status == 429
expect
	[
		AlreadyLinked,
		GitHubIdTaken,
		SignedInAlready,
	].all(|why| GitHubRefusal.refusal_said(why).status == 409)
expect [NoDefaultChannel, ClockOutOfRange].all(|why| GitHubRefusal.refusal_said(why).status == 500)
expect
	GitHubRefusal.refusal_said(SignUpsPaused)
		== { status: 503, words: "Sign-ups are paused for now; please try again later." }

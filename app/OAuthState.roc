## **THE OAUTH `state`, CHECKED** (the Roc chat's auth design, section 2):
## what stops login CSRF. `/login` sends GitHub a state carrying a random
## nonce and the time it was issued, and sets the same nonce in a cookie
## for this browser; GitHub hands the state back on `/login/github`. The
## host makes the nonce, signs the state and verifies the signature; this
## is the pure part, deciding from the decoded fields, the cookie and the
## time. Pure.
OAuthState := [].{

	## **HOW LONG A STATE LASTS**: ten minutes, in seconds; time enough to
	## sign in at GitHub, and short enough that a leaked one goes stale.
	lifetime_secs : I64
	lifetime_secs = 600

	## The state's fields, as the host decoded them once its signature
	## held: the nonce, and the unix time (seconds) it was issued at.
	Fields : {
		nonce : List(U8),
		issued_at : I64,
	}

	## The state cookie as the browser sent it, or not.
	Cookie : [Sent(List(U8)), Unsent]

	## What `check` says of a state.
	Verdict : [
		Valid,
		Expired,
		Mismatched,
	]

	## A new state's fields, for the host to sign: the host's random
	## `nonce`, issued `now`.
	issue : { nonce : List(U8), now : I64 } -> OAuthState.Fields
	issue = |{ nonce, now }| { nonce, issued_at: now }

	## **IS THIS STATE GOOD, FROM THIS BROWSER, NOW?**
	## - `Mismatched`: the browser sent no state cookie, or one whose nonce
	##   is not the state's, or the nonce is empty: the state was not issued
	##   to this browser (a login CSRF), so it is said before the time.
	## - `Expired`: the state is outside its window, issued `lifetime_secs`
	##   or more ago, or issued after `now` (a clock that went back: no
	##   state is trusted from a time not yet reached).
	## - `Valid` otherwise.
	check : OAuthState.Fields, { cookie : OAuthState.Cookie, now : I64 } -> OAuthState.Verdict
	check = |state, { cookie, now }| {
		# In I128: two I64 times anywhere in their range differ by less
		# than I128 holds, so no `issued_at` a host hands back overflows.
		age = now.to_i128() - state.issued_at.to_i128()
		match cookie {
			Unsent => Mismatched
			Sent(nonce) =>
				if state.nonce.is_empty() or nonce != state.nonce {
					Mismatched
				} else if age < 0 or age >= OAuthState.lifetime_secs.to_i128() {
					Expired
				} else {
					Valid
				}
		}
	}
}

nonce : List(U8)
nonce = "q7Zr2Lx9".to_utf8()

# Issued at 1000: the window is [1000, 1600).
issued : OAuthState.Fields
issued = OAuthState.issue({ nonce, now: 1000 })

expect issued == { nonce, issued_at: 1000 }

## The state `issued`, back from this browser with `cookie` at `now`.
back : { cookie : OAuthState.Cookie, now : I64 } -> OAuthState.Verdict
back = |at| OAuthState.check(issued, at)

other : Str -> OAuthState.Cookie
other = |text| Sent(text.to_utf8())

# Valid, at the window's two ends and inside it.
expect back({ cookie: Sent(nonce), now: 1000 }) == Valid
expect back({ cookie: Sent(nonce), now: 1300 }) == Valid
expect back({ cookie: Sent(nonce), now: 1599 }) == Valid

# Expired: at the lifetime and past it, and before it was issued.
expect back({ cookie: Sent(nonce), now: 1600 }) == Expired
expect back({ cookie: Sent(nonce), now: 99999 }) == Expired
expect back({ cookie: Sent(nonce), now: 999 }) == Expired

# I64's ends, issued or now: expired, never an overflow.
expect OAuthState.check(
	{ nonce, issued_at: -9223372036854775808 },
	{ cookie: Sent(nonce), now: 100 },
) == Expired
expect OAuthState.check(
	{ nonce, issued_at: 9223372036854775807 },
	{ cookie: Sent(nonce), now: -9223372036854775808 },
) == Expired

# Mismatched: no cookie, another nonce, a nonce one byte longer or shorter,
# an empty cookie, and an empty nonce on both sides.
expect back({ cookie: Unsent, now: 1300 }) == Mismatched
expect back({ cookie: other("q7Zr2Lx8"), now: 1300 }) == Mismatched
expect back({ cookie: other("q7Zr2Lx9!"), now: 1300 }) == Mismatched
expect back({ cookie: other("q7Zr2Lx"), now: 1300 }) == Mismatched
expect back({ cookie: Sent([]), now: 1300 }) == Mismatched
no_nonce : OAuthState.Fields
no_nonce = { nonce: [], issued_at: 1000 }

expect OAuthState.check(no_nonce, { cookie: Sent([]), now: 1300 }) == Mismatched

# A mismatch is said before the time: a stale state from another browser
# is Mismatched, not Expired.
expect back({ cookie: Unsent, now: 99999 }) == Mismatched
expect back({ cookie: other("other"), now: 999 }) == Mismatched

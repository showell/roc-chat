## These are the tests of signing out (`SignOut`, `SignOutRoute`): who signs out at
## once, who is asked first, and when a device's key is revoked; where
## Cancel goes; and the page that asks. The writes and their order, and the
## key refused afterwards, are the end to end's (host/end_to_end.zig).
import DeviceKey
import FirstStart
import PageKit
import Session
import SignOut
import SignedIn
import Timestamp
import UserId

SignOutSpec :: [].{}

## When a test's session is signed.
signed_at : Timestamp
signed_at = Timestamp.at_second(1_700_000_000)

## Device key 3, which a code's redemption made.
key_three : DeviceKey.Id
key_three = DeviceKey.Id.from_str("3") ?? crash "SignOutSpec: a key's number"

## Steve signed in by a session started as `origin` says, as a request's
## session admits him once its signature matched and its key is active.
steve_by : Session.Origin -> SignedIn
steve_by = |origin| {
	value = Session.cookie_value({
		id: UserId.chat_owner,
		signed_at,
		origin,
		mac: List.repeat(7, 32),
	})
	claim = Session.claim_from_cookie_header("${Session.cookie_name}=${value}".to_utf8())
		?? crash "SignOutSpec: a claim"
	admitted = Session.admit({
		claim,
		verdict: Matches,
		now: signed_at,
		users: FirstStart.first_directory.users(),
	})
		?? crash "SignOutSpec: a session admits Steve"
	SignedIn.by_session(admitted)
}

## What signing out does for `actor` with the form `body`, as a test reads
## it: `at once`, `ask, cancel to <next>`, or `revoke key <n>`.
choice_of : SignedIn.Actor, Str -> Str
choice_of = |actor, body|
	match SignOut.choose({ actor, body: body.to_utf8() }) {
		SignOutAtOnce(_) => "at once"
		Ask({ next, acting: _ }) => "ask, cancel to ${next.to_str()}"
		RevokeKey({ key, human: _ }) => "revoke key ${key.to_str()}"
	}

## Steve on a device a code signed in, bound to key 3.
on_phone : SignedIn.Actor
on_phone = SignedIn(steve_by(ByDeviceCode(key_three)))

# A cookie's `d3` reads back as a session bound to key 3.
expect steve_by(ByDeviceCode(key_three)).session_origin() == ByDeviceCode(key_three)
# No one, and a session a password, GitHub or an invite started, sign out at
# once, whatever the form says: they can sign back in.
expect
	["", "confirmed=yes", "next=/chat"].all(
		|body| {
			by_password = SignedIn(steve_by(Ordinary))
			choice_of(Anonymous, body) == "at once" and choice_of(by_password, body) == "at once"
		},
	)
# A device a code signed in is asked first, Cancel going back to the page it
# was on; only `confirmed=yes` revokes its key, the one its cookie names.
expect choice_of(on_phone, "next=/chat/dm/1_2/plans") == "ask, cancel to /chat/dm/1_2/plans"
expect choice_of(on_phone, "confirmed=yes&next=/chat") == "revoke key 3"
expect choice_of(on_phone, "confirmed=yes") == "revoke key 3"
expect
	["confirmed=no", "confirmed=YES", "confirmed=", "confirmed=yes%20", "confirm=yes"].all(
		|body| choice_of(on_phone, body) == "ask, cancel to /chat",
	)
# A `next` missing, no path on this site, or `/logout` itself (the page that
# asks posts it when its own top bar's "Sign out" is pressed, and a link to
# it is a 405) sends Cancel to Browse: no sign-out is refused for it.
expect
	[
		"",
		"next=",
		"next=chat",
		"next=//evil.example",
		"next=/a/../b",
		"next=https://x",
		"next=/logout",
		"next=%2Flogout",
	].all(|body| choice_of(on_phone, body) == "ask, cancel to /chat")
# The page that asks: what signing out does, in Steve's words; "Sign out",
# posting `confirmed=yes` and `next` to `/logout`; and Cancel, a link to
# `next`.
expect {
	page = Str.from_utf8_lossy(
		SignOut.confirm_page({
			viewer: steve_by(ByDeviceCode(key_three)),
			next: PageKit.site_path("/chat/dm/1_2/plans"),
		}).to_utf8(),
	)
	page.contains("<h1>Sign out of this device?</h1>")
		and page.contains("<p>Signing out removes this device&#39;s key. To sign in on this device again, you&#39;ll make a new code on a signed-in computer.</p>")
		and page.contains("<form method=\"post\" action=\"/logout\"><input type=\"hidden\" name=\"next\" value=\"/chat/dm/1_2/plans\"><input type=\"hidden\" name=\"confirmed\" value=\"yes\"><button>Sign out</button> <a href=\"/chat/dm/1_2/plans\">Cancel</a></form>")
}

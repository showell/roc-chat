## This module answers `POST /logout`, as `SignOut` decides: signed out at
## once, or for a device a code signed in, the page that asks first, or once
## confirmed, the device's key revoked and then signed out.
##
## Signing out ends with the browser forgetting the session's cookie and
## the one that shows a code, and a 303 to the sign-in page; a human's live
## device code is cancelled first (a failure logged, as a code's five
## minutes are all it leaves).
##
## A confirmed sign-out of a device a code signed in writes in this order:
## 1. its key's `state` rewritten `revoked`, atomically
##    (`DeviceKeyFiles.revoke_device_key!`); a failure is logged and a 500
##    saying the device is still signed in, and nothing else changes;
## 2. the human's live device code cancelled;
## 3. the answer that signs the browser out.
## A crash before 1 has told no one anything, and the key still works. A
## crash after it leaves the key refused at every request after, and the
## session with it, since each request of the session reads its key
## (`SignInFiles.check_session_key!`): no session outlives its key, and no
## key works once the device was told it is gone.
import pf.Host
import pf.Http
import DeviceCode
import DeviceCodeFiles
import DeviceKeyFiles
import FileFacts
import HttpAnswer
import PageKit
import SignInRoute
import SignOut
import SignedIn

SignOutRoute :: [].{

	## A POST of `/logout` by `actor`, of the form `body`. Never stored.
	sign_out! : { actor : SignedIn.Actor, body : List(U8) } => Http.Response
	sign_out! = |{ actor, body }|
		match SignOut.choose({ actor, body }) {
			SignOutAtOnce(NoHuman) => signed_out
			SignOutAtOnce(Human(human)) => {
				DeviceCodeFiles.revoke_or_log!(human.id())
				signed_out
			}
			Ask({ acting, next }) =>
				HttpAnswer.never_stored(
					HttpAnswer.page(200, SignOut.confirm_page({ viewer: acting, next })),
				)
			RevokeKey({ human, key }) =>
				match DeviceKeyFiles.revoke_device_key!(human.id(), key) {
					Err(FileSystem(fault)) => {
						said = "sign-out: user ${human.id().to_str()}'s device key ${key.to_str()} not revoked: ${FileFacts.fault_words(fault)}"
						Host.write_line_to_server_log!(said.to_utf8())
						HttpAnswer.never_stored(not_signed_out_answer)
					}
					Ok({}) => {
						DeviceCodeFiles.revoke_or_log!(human.id())
						signed_out
					}
				}
		}
}

## The answer that signs a browser out: the session's cookie and the one
## that shows a code forgotten, and a 303 to the sign-in page. Never stored.
signed_out : Http.Response
signed_out = HttpAnswer.with_header(
	SignInRoute.sign_out,
	{
		name: "set-cookie".to_utf8(),
		value: DeviceCode.clear_flash_cookie_text.to_utf8(),
	},
)

## The 500 when a device's key could not be revoked: nothing changed, so
## the device is still signed in.
not_signed_out_answer : Http.Response
not_signed_out_answer = HttpAnswer.page(
	500,
	PageKit.notice({
		title: "Not signed out",
		text: "This device's key could not be removed, so you are still signed in. Try again.",
	}),
)

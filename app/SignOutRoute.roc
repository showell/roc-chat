## This module answers `POST /logout`, the top bar's "Sign out" (`PageKit`):
##
## - For anyone not signed in by a session, and for a human whose session a
##   password, GitHub or an invite started: their live device code cancelled,
##   then the browser forgets the session's cookie and the one that shows a
##   code, and goes to the sign-in page. They can sign back in, so nothing
##   asks first.
## - For a human whose session a device code started: first a page saying
##   that signing out removes this device's key, with "Sign out", which
##   posts again with `confirmed=yes`, and "Cancel", a link back to `next`,
##   the page they were on (Steve, 2026-11-20). Confirmed, the writes go in
##   this order:
##   1. the key's `state` rewritten `revoked`, atomically
##      (`DeviceKeyFiles.revoke_device_key!`); a failure is a 500 saying they
##      are still signed in, and nothing else changes;
##   2. their live device code cancelled (a failure logged, as the code's
##      five minutes are all it leaves);
##   3. the answer: both cookies forgotten, and a 303 to the sign-in page.
##   A crash before 1 has told them nothing, and the key still works. A
##   crash after it leaves the key refused at every request after, and the
##   session with it, since every request of the session reads the key
##   (`SignInFiles.check_session_key!`): no session outlives its key, and no
##   key works once the device was told it is gone.
##
## `next` is the path the form carries (app/chrome.js puts the page's own
## in the top bar's form); one that is missing or no path here is `/`, which
## resumes where they were, so no sign-out is refused for it.
import pf.Http
import DeviceCode
import DeviceCodeFiles
import DeviceKey
import DeviceKeyFiles
import Escape
import Html
import HttpAnswer
import PageKit
import SignInRoute
import SignedIn
import TrustedHtml
import UrlEncodedForm
import Users

SignOutRoute :: [].{

	## Where "Sign out" posts.
	path : Str
	path = "/logout"

	## A POST of `/logout` by `actor`, of the form `body`: signed out at once,
	## or for a session a device code started, the page that asks first, or
	## once confirmed, its device key revoked and then signed out. Never
	## stored.
	sign_out! : { actor : SignedIn.Actor, body : List(U8) } => Http.Response
	sign_out! = |{ actor, body }|
		match SignOutRoute.choose({ actor, body }) {
			SignOutAtOnce(NoHuman) => signed_out
			SignOutAtOnce(Human(human)) => {
				DeviceCodeFiles.revoke_or_log!(human.id())
				signed_out
			}
			Ask({ acting, next }) =>
				HttpAnswer.never_stored(
					HttpAnswer.page(200, SignOutRoute.confirm_page({ viewer: acting, next })),
				)
			RevokeKey({ human, key }) =>
				match DeviceKeyFiles.revoke_device_key!(human.id(), key) {
					Err(FileSystem(_)) => HttpAnswer.never_stored(not_signed_out_answer)
					Ok({}) => {
						DeviceCodeFiles.revoke_or_log!(human.id())
						signed_out
					}
				}
		}

	## What a sign-out by `actor`, of the form `body`, does: sign out at once
	## (no one, or a human whose session is ordinary); ask first, for a
	## session a device code started, unless the form says `confirmed=yes`;
	## then revoke its key.
	choose : { actor : SignedIn.Actor, body : List(U8) } -> [
		SignOutAtOnce([NoHuman, Human(Users.Human)]),
		Ask({ acting : SignedIn, next : Html.SitePath }),
		RevokeKey({ human : Users.Human, key : DeviceKey.Id }),
	]
	choose = |{ actor, body }|
		match actor {
			Anonymous => SignOutAtOnce(NoHuman)
			SignedIn(acting) =>
				match (acting.human_in_session(), acting.session_origin()) {
					(Err(_), _) => SignOutAtOnce(NoHuman)
					(Ok(human), Ordinary) => SignOutAtOnce(Human(human))
					(Ok(human), ByDeviceCode(key)) =>
						if is_confirmed(body) {
							RevokeKey({ human, key })
						} else {
							Ask({ acting, next: next_from_form(body) })
						}
				}
		}

	## The page that asks a device signed in by a code before it signs out,
	## for `viewer`: what signing out does, then "Sign out", posting
	## `confirmed=yes` and `next`, and "Cancel", a link to `next`.
	confirm_page : { viewer : SignedIn, next : Html.SitePath } -> TrustedHtml
	confirm_page = |{ viewer, next }| {
		form = Html.element({
			name: Form,
			attributes: [MethodPost, Action(PageKit.site_path(SignOutRoute.path))],
			inner: TrustedHtml.join([
				hidden_field({ name: "next", value: Value(next) }),
				hidden_field({ name: confirmed_field, value: TokenValue(PageKit.token(confirmed_word)) }),
				Html.element({ name: Button, attributes: [], inner: Escape.text("Sign out") }),
				PageKit.space,
				Html.element({ name: A, attributes: [Link(next)], inner: Escape.text("Cancel") }),
			]),
		})
		PageKit.signed_in_page({
			title: "Sign out",
			viewer,
			parts: [
				PageKit.heading("Sign out of this device?"),
				PageKit.paragraph(confirm_words),
				form,
				PageKit.newline,
			],
		})
	}
}

## The answer that signs a browser out: the session's cookie and the one
## that shows a code forgotten, and a 303 to the sign-in page.
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

## What the page that asks first says.
confirm_words : Str
confirm_words = "Signing out removes this device's key. To sign in on this device again, you'll make a new code on a signed-in computer."

## The field that confirms a device's sign-out, and its one word.
confirmed_field : Str
confirmed_field = "confirmed"

confirmed_word : Str
confirmed_word = "yes"

## Whether the form `body` confirms the sign-out: `confirmed=yes` exactly.
is_confirmed : List(U8) -> Bool
is_confirmed = |body|
	match UrlEncodedForm.field({ body, name: confirmed_field }) {
		Ok(said) => said.is_exactly(confirmed_word)
		Err(_) => Bool.False
	}

## Where Cancel goes: the form's `next`, a path on this site, else `/`.
next_from_form : List(U8) -> Html.SitePath
next_from_form = |body|
	match UrlEncodedForm.field({ body, name: "next" }) {
		Ok(said) => said.site_path() ?? PageKit.site_path("/")
		Err(_) => PageKit.site_path("/")
	}

## A hidden field named `name`, holding `value`.
hidden_field : { name : Str, value : Html.Attribute } -> TrustedHtml
hidden_field = |{ name, value }|
	Html.input([InputType(Hidden), FieldName(PageKit.token(name)), value])

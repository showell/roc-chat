## This module decides what the top bar's "Sign out" (`PageKit`) does, as
## plain values a spec can test (`SignOutSpec`), and builds the page that
## asks first; `SignOutRoute` does the writes and answers.
##
## - No one signed in by a session, and a human whose session a password,
##   GitHub or an invite started, sign out at once: they can sign back in.
## - A human whose session a device code started is asked first (Steve,
##   2026-11-20): signing out removes this device's key, so signing in on it
##   again takes a new code. "Sign out" posts again with `confirmed=yes`,
##   which revokes the key the session is bound to; "Cancel" is a link back
##   to `next`, the page they were on.
##
## `next` is the path the form carries (app/chrome.js puts the page's own in
## the top bar's form); one that is missing, no path on this site, or
## `/logout` itself is Browse (`SignInRequest.default_next`), so no sign-out
## is refused for it and Cancel never leads to a 405.
import DeviceKey
import Escape
import Html
import PageKit
import SignInRequest
import SignedIn
import TrustedHtml
import UrlEncodedForm
import Users

SignOut :: [].{

	## Where "Sign out" posts.
	path : Str
	path = "/logout"

	## What a sign-out by `actor`, of the form `body`, does: sign out at once
	## (`SignOutAtOnce`: no one, or a human whose session is ordinary); ask
	## first (`Ask`), for a session a device code started, unless the form
	## says `confirmed=yes`; and then revoke its key (`RevokeKey`).
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
		confirmed = TokenValue(PageKit.token(confirmed_word))
		form = Html.element({
			name: Form,
			attributes: [MethodPost, Action(PageKit.site_path(SignOut.path))],
			inner: TrustedHtml.join([
				hidden_field("next", Value(next)),
				hidden_field(confirmed_field, confirmed),
				Html.element({
					name: Button,
					attributes: [],
					inner: Escape.text("Sign out"),
				}),
				PageKit.space,
				Html.element({
					name: A,
					attributes: [Link(next)],
					inner: Escape.text("Cancel"),
				}),
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
			panel: PlainPanel,
		})
	}
}

## What the page that asks first says.
confirm_words : Str
confirm_words = "Signing out removes this device's key. To sign in on this device again, you'll make a new code on a signed-in computer."

## The field that confirms a device's sign-out.
confirmed_field : Str
confirmed_field = "confirmed"

## The one word that confirms it.
confirmed_word : Str
confirmed_word = "yes"

## Whether the form `body` confirms the sign-out: `confirmed=yes` exactly.
is_confirmed : List(U8) -> Bool
is_confirmed = |body|
	match UrlEncodedForm.field({ body, name: confirmed_field }) {
		Ok(said) => said.is_exactly(confirmed_word)
		Err(_) => Bool.False
	}

## Where Cancel goes: the form's `next`, a path on this site, else Browse;
## Browse too for `/logout` itself, which the page that asks sends when its
## own top bar's "Sign out" is pressed, and which a link can't open.
next_from_form : List(U8) -> Html.SitePath
next_from_form = |body|
	match SignInRequest.next_from_form(body) {
		Ok(next) if next.to_str() != SignOut.path => next
		Ok(_) | Err(BadNext) => SignInRequest.default_next
	}

## A hidden field named `field_name`, its value's attribute `holding`.
hidden_field : Str, Html.Attribute -> TrustedHtml
hidden_field = |field_name, holding|
	Html.input([
		InputType(Hidden),
		FieldName(PageKit.token(field_name)),
		holding,
	])

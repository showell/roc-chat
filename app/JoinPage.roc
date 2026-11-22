## This module builds the join page, which `HumanInvitesRoute` serves at
## `/join`: where a human someone invited chooses their name and password.
## The page is the same for every invite: the invite's code is after the
## link's `#`, which only the page's script (app/join.js) reads; app/sign-in.js
## draws the page as a card, as it draws the sign-in page. A refused join is
## answered by `refused`, a card of its own.
import Escape
import Html
import PageKit
import Script
import TrustedHtml

JoinPage :: [].{

	## The join page. Its form posts to `/join` the code, in a hidden field
	## the script fills; the name, which the script fills with the name the
	## invite holds, for the invitee to keep or change; and the password they
	## choose.
	join : TrustedHtml
	join = {
		form = Html.element({
			name: Form,
			attributes: [MethodPost, Action(PageKit.site_path("/join"))],
			inner: TrustedHtml.join([
				Html.input([InputType(Hidden), FieldName(PageKit.token("code"))]),
				PageKit.newline,
				PageKit.labelled_input({
					label: "Your name",
					attributes: [
						InputType(Text),
						FieldName(PageKit.token("name")),
						Autocomplete(Username),
						Required,
					],
				}),
				PageKit.labelled_input({
					label: "Your password",
					attributes: [
						InputType(Password),
						FieldName(PageKit.token("password")),
						Autocomplete(NewPassword),
						Required,
					],
				}),
				Html.element({
					name: Button,
					attributes: [],
					inner: Escape.text("Join"),
				}),
			]),
		})
		PageKit.document({
			title: "Join",
			body: TrustedHtml.join([
				Html.element({
					name: H1,
					attributes: [],
					inner: Escape.text("Join the chat"),
				}),
				PageKit.newline,
				PageKit.paragraph("Someone you know invited you. Keep the name they chose for you, or choose another that no one has; once you join, it is yours. Choose a password: you sign in with your name and it."),
				form,
				PageKit.newline,
				PageKit.scripts(Script.join_scripts),
			]),
		})
	}

	## The page of a refused join, under `status`: the join page's heading
	## and `said`, marked as the problem (`PageKit.problem`), with no form.
	## app/sign-in.js draws it as a card and puts `/join` in its place in the
	## browser's history, so a reload is a plain GET that posts no code again.
	refused : { status : U16, said : Str } -> { status : U16, page : TrustedHtml }
	refused = |{ status, said }| {
		status,
		page: PageKit.document({
			title: "Join the chat",
			body: TrustedHtml.join([
				Html.element({
					name: H1,
					attributes: [],
					inner: Escape.text("Join the chat"),
				}),
				PageKit.newline,
				PageKit.problem(said),
				PageKit.scripts(Script.signed_out_scripts),
			]),
		}),
	}
}

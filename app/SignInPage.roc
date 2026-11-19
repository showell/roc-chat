## This module builds the sign-in pages: the sign-in page itself, which
## `SignInRoute` serves at `/login` and `GitHubRoute` shows again when a
## sign-in fails, and the page that asks a human GitHub vouched for, who has
## no account yet, to choose a name (`github_sign_up`, `GitHubRoute`'s).
## Whether the server offers GitHub at all is `GitHubOffer`.
import Escape
import Html
import Name
import PageKit
import SignedIn
import TrustedHtml

SignInPage :: [].{

	## Whether the sign-in page offers GitHub: `Offered` on a server with
	## GitHub's settings.
	GitHubOffer : [Offered, NotOffered]

	## The sign-in page, for `viewer`. For no one: a form posting a name and
	## a password to `/login`, and `next`, where to go once signed in, as a
	## hidden field; above it, `problem` when there is one; below it, when
	## `github` offers one, a link to sign in with GitHub, going to `next`.
	## For someone signed in, who has no use for a second account: `problem`,
	## who they are and a button that signs them out, under the top bar.
	login : {
		viewer : SignedIn.Actor,
		next : Html.SitePath,
		problem : [NoProblem, Problem(Str)],
		github : SignInPage.GitHubOffer,
	} -> TrustedHtml
	login = |{ viewer, next, problem, github }| {
		said =
			match problem {
				NoProblem => TrustedHtml.join([])
				Problem(text) => PageKit.paragraph(text)
			}
		form = Html.element({
			name: Form,
			attributes: [MethodPost, Action(PageKit.site_path("/login"))],
			inner: TrustedHtml.join([
				Html.input([
					InputType(Hidden),
					FieldName(PageKit.token("next")),
					Value(next),
				]),
				PageKit.newline,
				PageKit.labelled_input({
					label: "Name",
					attributes: [
						InputType(Text),
						FieldName(PageKit.token("name")),
						Autocomplete(Username),
						Required,
					],
				}),
				PageKit.labelled_input({
					label: "Password",
					attributes: [
						InputType(Password),
						FieldName(PageKit.token("password")),
						Autocomplete(CurrentPassword),
						Required,
					],
				}),
				Html.element({
					name: Button,
					attributes: [],
					inner: Escape.text("Sign in"),
				}),
			]),
		})
		github_link =
			match github {
				NotOffered => TrustedHtml.join([])
				Offered =>
					TrustedHtml.join([
						Html.element({
							name: P,
							attributes: [],
							inner: Html.element({
								name: A,
								attributes: [
									LinkWithNext({ path: PageKit.site_path("/login/github/start"), next }),
								],
								inner: Escape.text("Sign in with GitHub"),
							}),
						}),
						PageKit.newline,
					])
			}
		match viewer {
			SignedIn(acting) =>
				PageKit.signed_in_page({
					title: "Signed in",
					viewer: acting,
					parts: [
						said,
						PageKit.paragraph("You are signed in as ${acting.user().name().to_str()}."),
						PageKit.post_button({ action: "/logout", label: "Sign out" }),
					],
				})
			Anonymous =>
				PageKit.document({
					title: "Sign in",
					body: TrustedHtml.join([
						PageKit.heading("Sign in"),
						said,
						form,
						PageKit.newline,
						github_link,
					]),
				})
		}
	}

	## What a name field shows: a name, or nothing.
	NameField : [Named(Name), NoName]

	## The page that asks a human GitHub vouched for, who has no account, to
	## choose a name: a form posting it to `/login/github/name`, filled in
	## with `name`. The server carries who they are in a cookie
	## (`GitHubSignUp`), so the form holds nothing else. Above it, `problem`
	## when there is one.
	github_sign_up : {
		name : SignInPage.NameField,
		problem : [NoProblem, Problem(Str)],
	} -> TrustedHtml
	github_sign_up = |{ name, problem }| {
		said =
			match problem {
				NoProblem => TrustedHtml.join([])
				Problem(text) => PageKit.paragraph(text)
			}
		filled =
			match name {
				NoName => []
				Named(chosen) => [NameValue(chosen)]
			}
		form = Html.element({
			name: Form,
			attributes: [MethodPost, Action(PageKit.site_path("/login/github/name"))],
			inner: TrustedHtml.join([
				PageKit.labelled_input({
					label: "Your name",
					attributes: List.concat(
						[
							InputType(Text),
							FieldName(PageKit.token("name")),
							Autocomplete(Username),
							Required,
						],
						filled,
					),
				}),
				Html.element({
					name: Button,
					attributes: [],
					inner: Escape.text("Join"),
				}),
			]),
		})
		PageKit.document({
			title: "Choose your name",
			body: TrustedHtml.join([
				Html.element({
					name: H1,
					attributes: [],
					inner: Escape.text("Choose your name"),
				}),
				PageKit.newline,
				said,
				PageKit.paragraph("GitHub says who you are, and you have no account here yet. Choose a name that no one has: letters and single spaces. Once you join, it is yours, and you sign in with GitHub."),
				form,
				PageKit.newline,
			]),
		})
	}
}

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

	## Where the form that signs in by a device code posts (`DeviceCode`).
	code_path : Str
	code_path = "/login/code"

	## The sign-in page, for `viewer`. For no one: `problem` when there is
	## one; when `github` offers one, a link to sign in or sign up with
	## GitHub, going to `next`, and a line for those with a password; then a
	## form posting a name and a password to `/login`, its name field focused
	## when the page opens fresh; then a form of one field posting a device
	## code to `code_path`, focused after a refused code. Each form posts
	## `next`, where to go once signed in, as a hidden field.
	## For someone signed in, who has no use for a second account: `problem`,
	## who they are and a button that signs them out, under the top bar.
	login : {
		viewer : SignedIn.Actor,
		next : Html.SitePath,
		problem : SignInPage.Problem,
		github : SignInPage.GitHubOffer,
	} -> TrustedHtml
	login = |{ viewer, next, problem, github }| {
		said =
			match problem {
				NoProblem => TrustedHtml.join([])
				Problem(text) | CodeProblem(text) => PageKit.paragraph(text)
			}
		(name_focus, code_focus) =
			match problem {
				NoProblem => ([Autofocus], [])
				CodeProblem(_) => ([], [Autofocus])
				Problem(_) => ([], [])
			}
		code_form = Html.element({
			name: Form,
			attributes: [MethodPost, Action(PageKit.site_path(SignInPage.code_path))],
			inner: TrustedHtml.join([
				Html.input([
					InputType(Hidden),
					FieldName(PageKit.token("next")),
					Value(next),
				]),
				PageKit.newline,
				code_field(code_focus),
				Html.element({
					name: Button,
					attributes: [],
					inner: Escape.text("Sign in with the code"),
				}),
			]),
		})
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
					attributes: List.concat(
						[
							InputType(Text),
							FieldName(PageKit.token("name")),
							Autocomplete(Username),
							Required,
						],
						name_focus,
					),
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
									LinkWithNext({
										path: PageKit.site_path("/login/github/start"),
										next,
									}),
								],
								inner: Escape.text("Sign in or sign up with GitHub"),
							}),
						}),
						PageKit.newline,
						PageKit.paragraph("Already have an account? Sign in with your password, then link GitHub."),
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
						github_link,
						form,
						PageKit.newline,
						code_form,
						PageKit.newline,
					]),
				})
		}
	}

	## What the sign-in page says above its forms: nothing, which focuses the
	## name's field; a password's or GitHub's problem, which focuses none; or
	## a device code's (`CodeProblem`), which focuses the code's field.
	Problem : [NoProblem, Problem(Str), CodeProblem(Str)]

	## What a name field shows: a name, or nothing.
	NameField : [Named(Name), NoName]

	## Why the name form offers no name of GitHub's: GitHub's login is none
	## this chat shows (`NoLogin`), is no name here (`LoginNotAName`), or is
	## taken (`LoginTaken`), is reserved or looks like a name here
	## (`LoginTooClose`), or the chat is full (`ChatFull`).
	NoOffer : [NoLogin, LoginNotAName, LoginTaken, LoginTooClose, ChatFull]

	## The page that asks a human GitHub vouched for, who has no account, to
	## choose a name: a form posting it to `/login/github/name`, filled in
	## with `name`, at most `Name.longest` characters. The server carries who
	## they are in a cookie (`GitHubSignUp`), so the form holds nothing else.
	## Above it, `problem` when there is one, then what the name is for, and
	## `login_note`: why GitHub's login was not offered, when it was not.
	github_sign_up : {
		name : SignInPage.NameField,
		problem : [NoProblem, Problem(Str)],
		login_note : [NoNote, NotOffered(SignInPage.NoOffer)],
	} -> TrustedHtml
	github_sign_up = |{ name, problem, login_note }| {
		said =
			match problem {
				NoProblem => TrustedHtml.join([])
				Problem(text) => PageKit.paragraph(text)
			}
		noted =
			match login_note {
				NoNote => TrustedHtml.join([])
				NotOffered(why) => PageKit.paragraph(no_offer_words(why))
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
							MaxLength(Name.longest),
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
				PageKit.paragraph(choose_words),
				noted,
				form,
				PageKit.newline,
			]),
		})
	}
}

## What the name form says of the name, before it.
choose_words : Str
choose_words = "Everyone here sees this name, and it cannot be changed after you join. This page lasts 10 minutes; after that, sign in with GitHub again."

## Why GitHub's login was not offered as a name, in words.
no_offer_words : SignInPage.NoOffer -> Str
no_offer_words = |why|
	match why {
		NoLogin => "GitHub sent no login this chat can show, so no name is filled in."
		LoginNotAName => "Your GitHub login is not offered: a name here is letters and single spaces, at most ${Name.longest.to_str()}."
		LoginTaken => "Your GitHub login is not offered: someone here has that name."
		LoginTooClose => "Your GitHub login is not offered: it is reserved, or too close to a name the chat already has."
		ChatFull => "Your GitHub login is not offered: the chat holds as many as it can."
	}

## The device code's field, labelled, with `focus`'s attributes: a phone's
## number pad, digits with spaces or dashes allowed, no correction, room for
## a pasted code with its gap.
code_field : List(Html.Attribute) -> TrustedHtml
code_field = |focus| {
	attributes = List.concat(
		[
			InputType(Text),
			FieldName(PageKit.token("code")),
			Autocomplete(OneTimeCode),
			CodeTyping,
			MaxLength(20),
			Required,
		],
		focus,
	)
	label = Html.element({
		name: Label,
		attributes: [],
		inner: TrustedHtml.join([
			Escape.text("Have a code from your other device? Type its 8 digits: "),
			Html.input(attributes),
		]),
	})
	TrustedHtml.join([Html.element({ name: P, attributes: [], inner: label }), PageKit.newline])
}

## This module is what every page of the chat stands on: the markup kit the
## page modules build with (`paragraph`, `labelled_input`, `post_button`,
## `token`, `site_path`), the whole document each page is (`document`), the
## frame of a signed-in page (`top_bar`, `signed_in_page`), and the small
## pages that say one thing (`notice`, `not_found`, `refusal`). Each page
## lives beside the route that serves it: `ConversationPage`, `AgentsPage`,
## `SignInPage`, `JoinPage` and `PeoplePages`; `Browse` builds its own.
##
## The server sends structure and class names only, the classes and
## `data-` attributes of `PageContract`. Every page loads app/palette.js in
## its head (`Script`), which sets the colours and the theme before the
## first paint.
##
## Every page of someone signed in opens with the top bar (`top_bar`): its
## title, the links to Browse, Recent, the invites page and the device
## code page beside it, as Gopher Chat's section links were, then the Home
## link (`HomeLink`), the viewer's name and "Sign out". Under it, a page another module
## builds (`signed_in_page`) holds its parts in a panel, and ends with
## app/chrome.js, which styles the top bar and adds its theme toggle, and
## app/panel.js, which draws the panel as a card.
##
## Every `Str` a page shows goes in through `Escape.text`, and every
## element through `Html.element`. This module vouches
## (`TrustedHtml.dangerously_trust`) for one constant: the doctype and the
## head's two `<meta>` elements.
import ConversationKey
import DateTime
import Escape
import HomeLink
import Html
import PageContract
import Script
import SignedIn
import Timestamp
import TrustedHtml

PageKit :: [].{

	## Where the invites page is, which the top bar links to.
	invites_path : Str
	invites_path = "/invites"

	## Where a human signs another device in (`DeviceCodePage`), which the
	## top bar links to.
	devices_path : Str
	devices_path = "/devices"

	## Where Recent is, which the top bar links to.
	recent_path : Str
	recent_path = "/chat/recent"

	## The token `text` spells, for a name a page writes: one that isn't is
	## its writer's bug.
	token : Str -> Html.Token
	token = |text|
		Html.Token.from_str(text)
			?? crash "PageKit.token: \"${text}\" is a name a page writes, and not a token"

	## The site path `text` spells, for a path this server answers (a
	## conversation's, its script's): one that isn't is a bug in its writer.
	site_path : Str -> Html.SitePath
	site_path = |text|
		Html.SitePath.from_str(text)
			?? crash "PageKit.site_path: \"${text}\" is a path this server answers, and not a site path"

	## A line end, between a page's elements.
	newline : TrustedHtml
	newline = Escape.text("\n")

	## One space, between the parts of a line.
	space : TrustedHtml
	space = Escape.text(" ")

	## A paragraph of `said`, and a line end.
	paragraph : Str -> TrustedHtml
	paragraph = |said|
		TrustedHtml.join([
			Html.element({
				name: P,
				attributes: [],
				inner: Escape.text(said),
			}),
			PageKit.newline,
		])

	## A paragraph of `label` and an input of `attributes`, and a line end.
	labelled_input : { label : Str, attributes : List(Html.Attribute) } -> TrustedHtml
	labelled_input = |{ label, attributes }|
		TrustedHtml.join([
			Html.element({
				name: P,
				attributes: [],
				inner: TrustedHtml.join([Escape.text("${label} "), Html.input(attributes)]),
			}),
			PageKit.newline,
		])

	## A form of one button, posting nothing to `action`, a path this server
	## answers.
	post_button : { action : Str, label : Str } -> TrustedHtml
	post_button = |{ action, label }|
		TrustedHtml.join([
			Html.element({
				name: Form,
				attributes: [MethodPost, Action(PageKit.site_path(action))],
				inner: Html.element({
					name: Button,
					attributes: [],
					inner: Escape.text(label),
				}),
			}),
			PageKit.newline,
		])

	## A form posting to `action` its text fields, each a label and its
	## field's name, and a button of `label`.
	text_form : {
		action : Str,
		fields : List({ label : Str, name : Str }),
		label : Str,
	} -> TrustedHtml
	text_form = |{ action, fields, label }|
		Html.element({
			name: Form,
			attributes: [MethodPost, Action(PageKit.site_path(action))],
			inner: TrustedHtml.join(
				fields.map(
					|field|
						PageKit.labelled_input({
							label: field.label,
							attributes: [
								InputType(Text),
								FieldName(PageKit.token(field.name)),
								Required,
							],
						}),
				).append(
					Html.element({
						name: Button,
						attributes: [],
						inner: Escape.text(label),
					}),
				),
			),
		})

	## A heading of `said`.
	heading : Str -> TrustedHtml
	heading = |said|
		TrustedHtml.join([
			Html.element({
				name: H1,
				attributes: [],
				inner: Escape.text(said),
			}),
			PageKit.newline,
		])

	## A paragraph holding a link to `path`, a page of this site, of `text`.
	link_paragraph : { path : Str, text : Str } -> TrustedHtml
	link_paragraph = |{ path, text }|
		TrustedHtml.join([
			Html.element({
				name: P,
				attributes: [],
				inner: Html.element({
					name: A,
					attributes: [Link(PageKit.site_path(path))],
					inner: Escape.text(text),
				}),
			}),
			PageKit.newline,
		])

	## A one-time code shown on a page, in the class a reader finds it by.
	shown_code : Str -> TrustedHtml
	shown_code = |code|
		TrustedHtml.join([
			Html.element({
				name: P,
				attributes: [PageContract.class(InviteCode)],
				inner: Escape.text(code),
			}),
			PageKit.newline,
		])

	## The date of `moment`, or its seconds when it is out of a date's range.
	date_words : Timestamp -> Str
	date_words = |moment|
		match DateTime.from_timestamp(moment) {
			Ok(time) => time.date_to_str()
			Err(OutOfRange) => "at ${moment.to_str()} seconds"
		}

	## The element that loads `chosen`, one of this server's scripts.
	script : Script -> TrustedHtml
	script = |chosen|
		Html.element({
			name: Script,
			attributes: [Src(PageKit.site_path(chosen.url_path()))],
			inner: TrustedHtml.join([]),
		})

	## A page's whole document, the same for every page: the doctype and the
	## head's `<meta>` elements, `title` as its title, the colour script, then
	## `body`.
	document : { title : Str, body : TrustedHtml } -> TrustedHtml
	document = |{ title, body }|
		TrustedHtml.join([
			doctype,
			Html.element({
				name: Title,
				attributes: [],
				inner: Escape.text(title),
			}),
			PageKit.newline,
			PageKit.script(Script.Palette),
			PageKit.newline,
			body,
		])

	## Whether a top bar holds the line where app/chrome.js shows the
	## notices of the viewer's stream (`notice-strip`), and what it says as
	## the page is drawn. A conversation with a sidebar and Recent hold it,
	## between the section links and the viewer's name, so it costs the page
	## no row of its own (Steve, 2026-11-20, wanting that area economical).
	TopNotices : [NoNotices, Notices([NoNotice, Notice(Str)])]

	## The top bar: `title` on the left, the links to Browse, Recent, the
	## invites page and the device code page beside it, and on the right the
	## Home link and the name of `viewer`, the user viewing the page. The
	## section links sit by the title as Gopher Chat's did, so Recent is one
	## click from every page; the invites link is here so that a human in a
	## conversation reaches invites in one step.
	top_bar : { title : Str, viewer : SignedIn } -> TrustedHtml
	top_bar = |{ title, viewer }|
		top_bar_titled({
			title: Escape.text(title),
			viewer,
			notices: NoNotices,
		})

	## The top bar, its `title` a link to `link`, the page's own path, so a
	## click on it reloads the page, holding `notices`.
	linked_top_bar : {
		title : Str,
		link : Html.SitePath,
		viewer : SignedIn,
		notices : PageKit.TopNotices,
	} -> TrustedHtml
	linked_top_bar = |{ title, link, viewer, notices }|
		top_bar_titled({
			title: Html.element({
				name: A,
				attributes: [Link(link)],
				inner: Escape.text(title),
			}),
			viewer,
			notices,
		})

	## A page of a signed-in human's: the document, its top bar of `title`
	## and `viewer`, then `parts` in a panel, then the scripts that style
	## them.
	signed_in_page : {
		title : Str,
		viewer : SignedIn,
		parts : List(TrustedHtml),
	} -> TrustedHtml
	signed_in_page = |{ title, viewer, parts }|
		panel_page({
			title,
			top: PageKit.top_bar({ title, viewer }),
			parts,
		})

	## A page of a signed-in human's as `signed_in_page`, its top bar holding
	## the notices' line, empty until app/chrome.js says a notice there
	## (Recent's, as Gopher Chat's Recent had its #chat-notify).
	noticed_page : {
		title : Str,
		viewer : SignedIn,
		parts : List(TrustedHtml),
	} -> TrustedHtml
	noticed_page = |{ title, viewer, parts }|
		panel_page({
			title,
			top: top_bar_titled({
				title: Escape.text(title),
				viewer,
				notices: Notices(NoNotice),
			}),
			parts,
		})

	## A page that says one thing: `title`, and `text` beneath it (no such
	## conversation, a refused message, a failure).
	notice : { title : Str, text : Str } -> TrustedHtml
	notice = |{ title, text }|
		PageKit.document({
			title,
			body: Html.element({
				name: P,
				attributes: [],
				inner: Escape.text(text),
			}),
		})

	## The page of a path this server answers nothing at, with a 404: a path
	## no route has, or GitHub's on a server without GitHub's settings.
	not_found : TrustedHtml
	not_found = PageKit.notice({ title: "Not found", text: "Nothing is here." })

	## The page for a refused transcript, saying why in `why`'s words.
	refusal : Str -> TrustedHtml
	refusal = |why|
		PageKit.document({
			title: "Not a transcript",
			body: Html.element({
				name: P,
				attributes: [],
				inner: Escape.text("Not a transcript: ${why}."),
			}),
		})
}

## A page of `title`: the top bar `top`, then `parts` in a panel, then the
## scripts that style them.
panel_page : {
	title : Str,
	top : TrustedHtml,
	parts : List(TrustedHtml),
} -> TrustedHtml
panel_page = |{ title, top, parts }|
	PageKit.document({
		title,
		body: TrustedHtml.join([
			top,
			PageKit.newline,
			Html.element({
				name: Div,
				attributes: [PageContract.class(Layout)],
				inner: Html.element({
					name: Div,
					attributes: [PageContract.class(Panel)],
					inner: TrustedHtml.join(List.concat([PageKit.newline], parts)),
				}),
			}),
			PageKit.newline,
			PageKit.script(Script.Chrome),
			PageKit.newline,
			PageKit.script(Script.Panel),
			PageKit.newline,
		]),
	})

## The line in the top bar where app/chrome.js shows the notices, saying
## `notice` as the page is drawn, and the space after it; nothing for a top
## bar with none.
notice_strip : PageKit.TopNotices -> TrustedHtml
notice_strip = |notices|
	match notices {
		NoNotices => TrustedHtml.join([])
		Notices(notice) =>
			TrustedHtml.join([
				Html.element({
					name: P,
					attributes: [PageContract.class(NoticeStrip)],
					inner: match notice {
						NoNotice => TrustedHtml.join([])
						Notice(words) => Escape.text(words)
					},
				}),
				PageKit.space,
			])
	}

## The top bar, `title` on its left, holding `notices`.
top_bar_titled : {
	title : TrustedHtml,
	viewer : SignedIn,
	notices : PageKit.TopNotices,
} -> TrustedHtml
top_bar_titled = |{ title, viewer, notices }|
	Html.element({
		name: Header,
		attributes: [PageContract.class(TopBar)],
		inner: TrustedHtml.join([
			Html.element({
				name: Span,
				attributes: [PageContract.class(TopTitle)],
				inner: title,
			}),
			PageKit.space,
			Html.element({
				name: Span,
				attributes: [PageContract.class(TopLinks)],
				inner: TrustedHtml.join([
					Html.element({
						name: A,
						attributes: [Link(PageKit.site_path(ConversationKey.browse_path))],
						inner: Escape.text("Browse"),
					}),
					Escape.text(" · "),
					Html.element({
						name: A,
						attributes: [Link(PageKit.site_path(PageKit.recent_path))],
						inner: Escape.text("Recent"),
					}),
					Escape.text(" · "),
					Html.element({
						name: A,
						attributes: [Link(PageKit.site_path(PageKit.invites_path))],
						inner: Escape.text("Invites"),
					}),
					Escape.text(" · "),
					Html.element({
						name: A,
						attributes: [Link(PageKit.site_path(PageKit.devices_path))],
						inner: Escape.text("Add a device"),
					}),
				]),
			}),
			PageKit.space,
			notice_strip(notices),
			Html.element({
				name: Div,
				attributes: [PageContract.class(TopUser)],
				inner: TrustedHtml.join([
					home_link,
					Html.element({
						name: Span,
						attributes: [PageContract.class(Viewer)],
						inner: Escape.text(viewer.user().name().to_str()),
					}),
					Escape.text(" · "),
					sign_out_form,
				]),
			}),
		]),
	})

## The top bar's "Sign out", after the viewer's name: a form, so it is a
## POST, held to this server's origin as every POST is (`SignInRoute`'s
## `/logout`, by way of `DeviceCodeRoute.sign_out!`).
sign_out_form : TrustedHtml
sign_out_form =
	Html.element({
		name: Form,
		attributes: [PageContract.class(SignOut), MethodPost, Action(PageKit.site_path("/logout"))],
		inner: Html.element({ name: Button, attributes: [], inner: Escape.text("Sign out") }),
	})

## The top bar's Home link and the separator after it, or nothing for a
## fork with none (`HomeLink.NoHomeLink`).
home_link : TrustedHtml
home_link =
	match HomeLink.home {
		Link({ url, label }) =>
			TrustedHtml.join([
				Html.element({
					name: A,
					attributes: [
						OffSiteLink(
							Html.HttpsUrl.from_str(url)
								?? crash "PageKit.home_link: HomeLink's \"${url}\" is not an https address",
						),
					],
					inner: Escape.text(label),
				}),
				Escape.text(" · "),
			])
		NoHomeLink => TrustedHtml.join([])
	}

## The doctype, the charset, and the viewport a phone lays the page out
## in, which every page opens with: a constant, vouched for here.
doctype : TrustedHtml
doctype = TrustedHtml.dangerously_trust(doctype_text)

doctype_text : Str
doctype_text =
	\\<!doctype html>
	\\<meta charset=utf-8>
	\\<meta name=viewport content="width=device-width, initial-scale=1">
	\\

# ── tests
expect
	doctype.to_utf8()
		== "<!doctype html>\n<meta charset=utf-8>\n<meta name=viewport content=\"width=device-width, initial-scale=1\">\n".to_utf8()
# A notice: its title and its words, each escaped, under the colour script.
expect PageKit.notice({ title: "a<b", text: "x & y" }).to_utf8()
	== "${doctype_text}<title>a&lt;b</title>\n<script src=\"/chat/assets/palette.js\"></script>\n<p>x &amp; y</p>".to_utf8()

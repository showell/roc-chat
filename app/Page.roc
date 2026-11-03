## This module builds the chat's pages: a conversation's page, the agents
## page, the sign-in page, a page that says why a transcript was refused,
## and a page that says one thing. The
## server sends structure and class names only. Every page loads
## app/palette.js in its head (`Script`), which sets the colours and
## the theme before the first paint, and a conversation's page ends with
## its three scripts, which style what they find and add behaviour. The
## page reads top to bottom without them, and its form still posts.
##
## A conversation's page has a top bar, with the topic and the viewer's
## name, and below it two panes. The first holds the messages, and the
## second is the compose box: a form that posts the field `markdown` back
## to the conversation's own URL, and a line of help. The script sends the
## same form to the conversation's `/send` instead, so the page stays put.
## app/chrome.js styles the top bar and adds its theme toggle.
## app/compose.js lays the panes out, gives the compose box its keys and
## its Upload button, and sends a message without a reload. app/feed.js
## styles the messages, marks the viewer's own, writes each time in the
## viewer's time zone, appends each message the conversation's stream
## brings, which `message` writes as the page does, and lets the reader
## select a message and move between them from the keyboard.
##
## The scripts find what they need by the classes in `Class` and by the
## `data-` attributes in `DataAttribute`. The messages pane names its
## stream (`data-stream`), how many messages it shows (`data-after`) and
## the viewer's id (`data-viewer`). A message names its author's id
## (`data-author`) when its author is a user of the chat. The form names
## where the script sends a message (`data-send`), where to upload an image
## (`data-upload`) and the most bytes an image may be
## (`data-image-byte-limit`).
##
## Every `Str` a page shows goes in through `Escape.text`, a message's
## markdown through `Markdown.render`, and every element through
## `Html.element`. This module vouches (`TrustedHtml.dangerously_trust`)
## for one constant: the doctype and the head's two `<meta>` elements.
import AgentInvite
import AgentKey
import Conversation
import ConversationKey
import DateTime
import Escape
import Html
import Markdown
import Message
import MsgAnchor
import KeyScope
import Script
import SecretToken
import SignedIn
import Topic
import TrustedHtml
import UploadedImage
import UrlEncodedForm
import Users

Page :: [].{

	## A class a page uses: a closed set, so a class is never data.
	Class : [
		Author,
		Body,
		Compose,
		Empty,
		Help,
		InviteCode,
		Layout,
		Message,
		Messages,
		Ref,
		TopBar,
		TopTitle,
		TopUser,
		Viewer,
	]

	## The class attribute for `class`, its one spelling.
	class : Page.Class -> Html.Attribute
	class = |chosen| Class(token(class_name(chosen)))

	## A `data-` attribute a page writes for its scripts, with its value:
	## a closed set, so `data_attribute` is the one spelling of each name.
	DataAttribute : [
		Stream(Html.SitePath),
		After(Html.Token),
		Viewer(Html.Token),
		Author(Html.Token),
		Send(Html.SitePath),
		Upload(Html.SitePath),
		ImageByteLimit(Html.Token),
	]

	## The `data-` attribute `chosen` names, with its value.
	data_attribute : Page.DataAttribute -> Html.Attribute
	data_attribute = |chosen|
		match chosen {
			Stream(path) => Data(token("stream"), Path(path))
			After(count) => Data(token("after"), Token(count))
			Viewer(id) => Data(token("viewer"), Token(id))
			Author(id) => Data(token("author"), Token(id))
			Send(path) => Data(token("send"), Path(path))
			Upload(path) => Data(token("upload"), Path(path))
			ImageByteLimit(count) => Data(token("image-byte-limit"), Token(count))
		}

	## The page of `conversation`, the conversation `key`, for `viewer`. Each
	## message of it is found among `users` by its author's name, to name its
	## author's id.
	conversation : {
		conversation : Conversation,
		key : ConversationKey,
		viewer : SignedIn,
		users : Users,
	} -> TrustedHtml
	conversation = |
		{
			conversation: c,
			key,
			viewer,
			users,
		},
	| {
		topic = c.topic()
		messages =
			if (c.messages().is_empty())
				TrustedHtml.join([
					Html.element({
						name: P,
						attrs: [Page.class(Empty)],
						inner: Escape.text("No messages yet."),
					}),
					newline,
				])
			else
				TrustedHtml.join(
					c.messages().map(
						|m|
							Page.message({
								conversation: c,
								key,
								users,
								message: m,
							}),
					),
				)
		document({
			title: topic.to_str(),
			body: TrustedHtml.join([
				top_bar({ title: topic.to_str(), viewer }),
				newline,
				Html.element({
					name: Div,
					attrs: [Page.class(Layout)],
					inner: TrustedHtml.join([
						Html.element({
							name: Div,
							attrs: [
								Page.class(Messages),
								Page.data_attribute(Stream(site_path(key.url_path(Stream)))),
								Page.data_attribute(After(token(c.messages().len().to_str()))),
								Page.data_attribute(Viewer(user_id(viewer.user()))),
							],
							inner: TrustedHtml.join([newline, messages]),
						}),
						newline,
						compose_box(key),
						newline,
					]),
				}),
				newline,
				TrustedHtml.join(
					[
						Script.Chrome,
						Script.Compose,
						Script.Feed,
					].map(|chosen| TrustedHtml.join([script(chosen), newline])),
				),
			]),
		})
	}

	## The page for a refused transcript, saying why in `why`'s words.
	refusal : Str -> TrustedHtml
	refusal = |why|
		document({
			title: "Not a transcript",
			body: Html.element({
				name: P,
				attrs: [],
				inner: Escape.text("Not a transcript: ${why}."),
			}),
		})

	## One message of `conversation`, the conversation `key`, as its page
	## and its stream write it: its header, then its markdown rendered. Its
	## author's id is named when `users` holds a user of its author's name.
	message : {
		conversation : Conversation,
		key : ConversationKey,
		users : Users,
		message : Message,
	} -> TrustedHtml
	message = |
		{
			conversation: c,
			key,
			users,
			message: m,
		},
	| {
		message_reference = c.reference(m.id())
		author_attrs =
			match users.user_by_name(m.author().name()) {
				Ok(user) => [Page.data_attribute(Author(user_id(user)))]
				Err(NoSuchUser) => []
			}
		header = TrustedHtml.join([
			Html.element({
				name: Span,
				attrs: [Page.class(Author)],
				inner: Escape.text(m.author().to_str()),
			}),
			space,
			Html.element({
				name: Time,
				attrs: [DateTime(m.time())],
				inner: Escape.text(m.time().to_str()),
			}),
			space,
			Html.element({
				name: A,
				attrs: [Page.class(Ref), Href(anchor(message_reference))],
				inner: Escape.text(message_reference.to_str()),
			}),
		])
		article = Html.element({
			name: Article,
			attrs: [Page.class(Message), Id(anchor(message_reference))].concat(author_attrs),
			inner: TrustedHtml.join([
				Html.element({
					name: Header,
					attrs: [],
					inner: header,
				}),
				newline,
				Html.element({
					name: Div,
					attrs: [Page.class(Body)],
					inner: Markdown.render(m.markdown(), key),
				}),
			]),
		})
		TrustedHtml.join([article, newline])
	}

	## One agent on the agents page, with its keys and its invites.
	AgentSummary : {
		agent : Users.User,
		keys : List(AgentKey),
		invites : List(AgentInvite),
	}

	## The agents page, for `viewer`: a form that makes an agent, then each
	## of `agents` with a button that invites it, and its keys and invites,
	## each live one with a button that revokes it. When an invite was just
	## made, its code comes first (`shown`), the one time it is shown.
	agents : {
		viewer : SignedIn,
		agents : List(Page.AgentSummary),
		shown : [NoCode, Code({ agent : Users.User, code : SecretToken })],
	} -> TrustedHtml
	agents = |
		{
			viewer,
			agents: summaries,
			shown,
		},
	| {
		code =
			match shown {
				NoCode => TrustedHtml.join([])
				Code({ agent, code: shown_code }) =>
					TrustedHtml.join([
						paragraph("The invite code for ${agent.name().to_str()}, shown this once. It lives ten minutes and redeems once: the agent posts it as `code` to /agents/redeem for its key."),
						Html.element({
							name: P,
							attrs: [Page.class(InviteCode)],
							inner: Escape.text(shown_code.to_str()),
						}),
						newline,
					])
			}
		make_form = Html.element({
			name: Form,
			attrs: [MethodPost, Action(site_path("/agents"))],
			inner: TrustedHtml.join([
				Html.element({
					name: Textarea,
					attrs: [FieldName(token("name")), Required],
					inner: TrustedHtml.join([]),
				}),
				newline,
				Html.element({
					name: Button,
					attrs: [],
					inner: Escape.text("Make an agent"),
				}),
			]),
		})
		document({
			title: "Agents",
			body: TrustedHtml.join([
				top_bar({ title: "Agents", viewer }),
				newline,
				code,
				make_form,
				newline,
				TrustedHtml.join(summaries.map(agent_section)),
			]),
		})
	}

	## A page of a signed-in human's, for another module that builds one
	## (`PeoplePages`): the document, its top bar of `title` and `viewer`,
	## then `parts`.
	signed_in_page : {
		title : Str,
		viewer : SignedIn,
		parts : List(TrustedHtml),
	} -> TrustedHtml
	signed_in_page = |
		{
			title,
			viewer,
			parts,
		},
	|
		document({
			title,
			body: TrustedHtml.join([top_bar({ title, viewer }), newline].concat(parts)),
		})

	## A paragraph of `said`, for another module's page.
	text_paragraph : Str -> TrustedHtml
	text_paragraph = |said| paragraph(said)

	## A form of one button posting nothing to `action`, a path this server
	## answers, for another module's page.
	button_form : { action : Str, label : Str } -> TrustedHtml
	button_form = |button| post_button(button)

	## A form posting to `action` its text fields, each a label and its
	## field's name, and a button of `label`, for another module's page.
	text_form : {
		action : Str,
		fields : List({ label : Str, name : Str }),
		label : Str,
	} -> TrustedHtml
	text_form = |
		{
			action,
			fields,
			label,
		},
	|
		Html.element({
			name: Form,
			attrs: [MethodPost, Action(site_path(action))],
			inner: TrustedHtml.join(
				fields.map(
					|field|
						labelled_input({
							label: field.label,
							attrs: [
								InputType(Text),
								FieldName(token(field.name)),
								Required,
							],
						}),
				).append(
					Html.element({
						name: Button,
						attrs: [],
						inner: Escape.text(label),
					}),
				),
			),
		})

	## A paragraph holding a link to `path`, a page of this site, of `text`,
	## for another module's page.
	link_paragraph : { path : Str, text : Str } -> TrustedHtml
	link_paragraph = |{ path, text }|
		TrustedHtml.join([
			Html.element({
				name: P,
				attrs: [],
				inner: Html.element({
					name: A,
					attrs: [Link(site_path(path))],
					inner: Escape.text(text),
				}),
			}),
			newline,
		])

	## A one-time code shown on a page, in the class a reader finds it by.
	shown_code : Str -> TrustedHtml
	shown_code = |code|
		TrustedHtml.join([
			Html.element({
				name: P,
				attrs: [Page.class(InviteCode)],
				inner: Escape.text(code),
			}),
			newline,
		])

	## A time in seconds since the epoch, as a page writes it.
	time_words : I64 -> Str
	time_words = |seconds| time_text(seconds)

	## A page that says one thing: `title`, and `text` beneath it (no such
	## conversation, a refused message, a failure).
	notice : { title : Str, text : Str } -> TrustedHtml
	notice = |{ title, text }|
		document({
			title,
			body: Html.element({
				name: P,
				attrs: [],
				inner: Escape.text(text),
			}),
		})

	## The sign-in page, for `viewer`: a form posting a name and a password
	## to `/login`, and `next`, where to go once signed in, as a hidden
	## field. Above it, `problem` when there is one, and for a human signed
	## in, who they are and a button that signs them out.
	login : {
		viewer : SignedIn.Actor,
		next : Html.SitePath,
		problem : [NoProblem, Problem(Str)],
	} -> TrustedHtml
	login = |
		{
			viewer,
			next,
			problem,
		},
	| {
		said =
			match problem {
				NoProblem => TrustedHtml.join([])
				Problem(text) => paragraph(text)
			}
		signed_in =
			match viewer {
				Anonymous => TrustedHtml.join([])
				SignedIn(acting) =>
					TrustedHtml.join([
						paragraph("You are signed in as ${acting.user().name().to_str()}."),
						post_button({ action: "/logout", label: "Sign out" }),
					])
			}
		form = Html.element({
			name: Form,
			attrs: [MethodPost, Action(site_path("/login"))],
			inner: TrustedHtml.join([
				Html.input([
					InputType(Hidden),
					FieldName(token("next")),
					Value(next),
				]),
				newline,
				labelled_input({
					label: "Name",
					attrs: [
						InputType(Text),
						FieldName(token("name")),
						Autocomplete(Username),
						Required,
					],
				}),
				labelled_input({
					label: "Password",
					attrs: [
						InputType(Password),
						FieldName(token("password")),
						Autocomplete(CurrentPassword),
						Required,
					],
				}),
				Html.element({
					name: Button,
					attrs: [],
					inner: Escape.text("Sign in"),
				}),
			]),
		})
		document({
			title: "Sign in",
			body: TrustedHtml.join([
				Html.element({
					name: H1,
					attrs: [],
					inner: Escape.text("Sign in"),
				}),
				newline,
				said,
				signed_in,
				form,
				newline,
				paragraph("Invited? Enter your invite's code and the password you choose."),
				redeem_form,
				newline,
			]),
		})
	}
}

## The sign-in page's second form: a human invite's code and the password
## its human chooses, posted to `/invites/redeem` (`HumanInvitesRoute`).
redeem_form : TrustedHtml
redeem_form =
	Html.element({
		name: Form,
		attrs: [MethodPost, Action(site_path("/invites/redeem"))],
		inner: TrustedHtml.join([
			labelled_input({
				label: "Invite code",
				attrs: [
					InputType(Text),
					FieldName(token("code")),
					Required,
				],
			}),
			labelled_input({
				label: "New password",
				attrs: [
					InputType(Password),
					FieldName(token("password")),
					Autocomplete(NewPassword),
					Required,
				],
			}),
			Html.element({
				name: Button,
				attrs: [],
				inner: Escape.text("Join"),
			}),
		]),
	})

## A paragraph of `label` and an input of `attrs`, and a line end.
labelled_input : { label : Str, attrs : List(Html.Attribute) } -> TrustedHtml
labelled_input = |{ label, attrs }|
	TrustedHtml.join([
		Html.element({
			name: P,
			attrs: [],
			inner: TrustedHtml.join([Escape.text("${label} "), Html.input(attrs)]),
		}),
		newline,
	])

## The compose box: a form posting its one field, a message's markdown
## (`UrlEncodedForm.markdown_name`), to `key`'s page, as
## `ConversationRoute.post_sent_message!` takes it, and naming for the
## script where an image is uploaded and the most it may be
## (`UploadRoute`), and where the script sends the same field
## (`ConversationRoute.post_message_without_reload!`); then its help line.
compose_box : ConversationKey -> TrustedHtml
compose_box = |key|
	Html.element({
		name: Div,
		attrs: [Page.class(Compose)],
		inner: TrustedHtml.join([
			Html.element({
				name: Form,
				attrs: [
					MethodPost,
					Action(site_path(key.url_path(Page))),
					Page.data_attribute(Send(site_path(key.url_path(Send)))),
					Page.data_attribute(Upload(site_path(key.url_path(Upload)))),
					Page.data_attribute(ImageByteLimit(token(UploadedImage.most_bytes.to_str()))),
				],
				inner: TrustedHtml.join([
					Html.element({
						name: Textarea,
						attrs: [FieldName(token(UrlEncodedForm.markdown_name)), Required],
						inner: TrustedHtml.join([]),
					}),
					newline,
					Html.element({
						name: Button,
						attrs: [],
						inner: Escape.text("Send"),
					}),
				]),
			}),
			newline,
			Html.element({
				name: P,
				attrs: [Page.class(Help)],
				inner: Escape.text("Markdown supported · attach an image · Ctrl/⌘-Enter to send"),
			}),
		]),
	})

## One agent's part of the agents page: its name and id, the button that
## invites it, then its keys and its invites.
agent_section : Page.AgentSummary -> TrustedHtml
agent_section = |
	{
		agent,
		keys,
		invites,
	},
| {
	folder = "/agents/${agent.id().to_str()}"
	TrustedHtml.join([
		Html.element({
			name: H1,
			attrs: [],
			inner: Escape.text("${agent.name().to_str()} (id ${agent.id().to_str()})"),
		}),
		newline,
		post_button({ action: "${folder}/invites", label: "Invite ${agent.name().to_str()}" }),
		TrustedHtml.join(
			keys.map(
				|key| {
					state_word =
						match key.state() {
							Active => "active"
							Revoked => "revoked"
						}
					said = "Key ${key.id().to_str()}: ${state_word}, expires ${time_text(key.expires())}, read ${KeyScope.reach_word(key.scope().read())}, post ${KeyScope.reach_word(key.scope().post())}."
					revoke =
						match key.state() {
							Active => post_button({
								action: "${folder}/keys/${key.id().to_str()}/revoke",
								label: "Revoke key ${key.id().to_str()}",
							})
							Revoked => TrustedHtml.join([])
						}
					TrustedHtml.join([paragraph(said), revoke])
				},
			),
		),
		TrustedHtml.join(
			invites.map(
				|invite| {
					said = "Invite ${invite.id().to_str()}: ${invite_state_word(invite.state())}, expires ${time_text(invite.expires())}."
					revoke =
						match invite.state() {
							Live => post_button({
								action: "${folder}/invites/${invite.id().to_str()}/revoke",
								label: "Revoke invite ${invite.id().to_str()}",
							})
							Spent => TrustedHtml.join([])
							Revoked => TrustedHtml.join([])
						}
					TrustedHtml.join([paragraph(said), revoke])
				},
			),
		),
	])
}

## A form of one button, posting nothing to `action`, a path this server
## answers.
post_button : { action : Str, label : Str } -> TrustedHtml
post_button = |{ action, label }|
	TrustedHtml.join([
		Html.element({
			name: Form,
			attrs: [MethodPost, Action(site_path(action))],
			inner: Html.element({
				name: Button,
				attrs: [],
				inner: Escape.text(label),
			}),
		}),
		newline,
	])

## A paragraph of `said`, and a line end.
paragraph : Str -> TrustedHtml
paragraph = |said|
	TrustedHtml.join([
		Html.element({
			name: P,
			attrs: [],
			inner: Escape.text(said),
		}),
		newline,
	])

invite_state_word : AgentInvite.State -> Str
invite_state_word = |state|
	match state {
		Live => "live"
		Spent => "redeemed"
		Revoked => "revoked"
	}

## A time in seconds since the epoch as a transcript writes one, or its
## seconds when it is out of a date's range.
time_text : I64 -> Str
time_text = |seconds|
	match DateTime.from_seconds_since_epoch(seconds) {
		Ok(time) => time.to_str()
		Err(OutOfRange) => "at ${seconds.to_str()} seconds"
	}

## The top bar: `title` on the left, and the name of `viewer`, the user
## viewing the page, on the right.
top_bar : { title : Str, viewer : SignedIn } -> TrustedHtml
top_bar = |{ title, viewer }|
	Html.element({
		name: Header,
		attrs: [Page.class(TopBar)],
		inner: TrustedHtml.join([
			Html.element({
				name: Span,
				attrs: [Page.class(TopTitle)],
				inner: Escape.text(title),
			}),
			space,
			Html.element({
				name: Div,
				attrs: [Page.class(TopUser)],
				inner: Html.element({
					name: Span,
					attrs: [Page.class(Viewer)],
					inner: Escape.text(viewer.user().name().to_str()),
				}),
			}),
		]),
	})

## A user's id, which the scripts compare: a message's author's with the
## viewer's.
user_id : Users.User -> Html.Token
user_id = |user| token(user.id().to_str())

## The element that loads `chosen`, one of this server's scripts.
script : Script -> TrustedHtml
script = |chosen|
	Html.element({
		name: Script,
		attrs: [Src(site_path(chosen.url_path()))],
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
			attrs: [],
			inner: Escape.text(title),
		}),
		newline,
		script(Script.Palette),
		newline,
		body,
	])

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

class_name : Page.Class -> Str
class_name = |chosen|
	match chosen {
		Author => "author"
		Body => "body"
		Compose => "compose"
		Empty => "empty"
		Help => "help"
		InviteCode => "invite-code"
		Layout => "layout"
		Message => "message"
		Messages => "messages"
		Ref => "ref"
		TopBar => "top-bar"
		TopTitle => "top-title"
		TopUser => "top-user"
		Viewer => "viewer"
	}

## A message's anchor, as a token: `MsgAnchor.page_anchor`'s spelling,
## which an element's id and a link's `#` both write.
anchor : MsgAnchor -> Html.Token
anchor = |message_reference| token(message_reference.page_anchor())

## The token `text` spells, for a name this module writes: one that isn't
## is this module's bug.
token : Str -> Html.Token
token = |text| Html.Token.from_str(text) ?? crash "Page.token: \"${text}\" is a name this module writes, and not a token"

## The site path `text` spells, for a path this server answers (a
## conversation's, its script's): one that isn't is a bug in its writer.
site_path : Str -> Html.SitePath
site_path = |text| Html.SitePath.from_str(text) ?? crash "Page.site_path: \"${text}\" is a path this server answers, and not a site path"

newline : TrustedHtml
newline = Escape.text("\n")

space : TrustedHtml
space = Escape.text(" ")

# ── tests
## An element `attrs` alone opens, as a test reads it.
empty_paragraph : List(Html.Attribute) -> List(U8)
empty_paragraph = |attrs|
	Html.element({
		name: P,
		attrs,
		inner: TrustedHtml.join([]),
	}).to_utf8()

# Every class, each its one spelling.
expect
	[
		(Author, "author"),
		(Body, "body"),
		(Compose, "compose"),
		(Empty, "empty"),
		(Help, "help"),
		(InviteCode, "invite-code"),
		(Layout, "layout"),
		(Message, "message"),
		(Messages, "messages"),
		(Ref, "ref"),
		(TopBar, "top-bar"),
		(TopTitle, "top-title"),
		(TopUser, "top-user"),
		(Viewer, "viewer"),
	].all(
		|
			(
				chosen,
				spelled,
			),
		| empty_paragraph([Page.class(chosen)]) == "<p class=\"${spelled}\"></p>".to_utf8(),
	)
# Every `data-` attribute, each its one spelling, a path or a token.
expect {
	path = site_path("/chat/dm/1_1/plans")
	[
		(Stream(path), "<p data-stream=\"/chat/dm/1_1/plans\"></p>"),
		(After(token("6")), "<p data-after=\"6\"></p>"),
		(Viewer(token("1")), "<p data-viewer=\"1\"></p>"),
		(Author(token("3")), "<p data-author=\"3\"></p>"),
		(Send(path), "<p data-send=\"/chat/dm/1_1/plans\"></p>"),
		(Upload(path), "<p data-upload=\"/chat/dm/1_1/plans\"></p>"),
		(ImageByteLimit(token("10485760")), "<p data-image-byte-limit=\"10485760\"></p>"),
	].all(|(chosen, expected)| empty_paragraph([Page.data_attribute(chosen)]) == expected.to_utf8())
}

## Whether the script `bytes` finds the class `chosen` by its selector, a
## string literal in any of JavaScript's three quotes.
is_found_by : List(U8), Page.Class -> Bool
is_found_by = |bytes, chosen| has_quoted(bytes, ".${class_name(chosen)}")

## Whether the script `bytes` reads the attribute `name`, a string literal
## in any of JavaScript's three quotes.
is_read_by : List(U8), Str -> Bool
is_read_by = |bytes, name| has_quoted(bytes, name)

## Whether the script `bytes` holds `text` as a whole string literal, in
## single quotes, double quotes or backticks.
has_quoted : List(U8), Str -> Bool
has_quoted = |bytes, text| {
	script_text = Str.from_utf8_lossy(bytes)
	[
		"'",
		"\"",
		"`",
	].any(|quote| script_text.contains("${quote}${text}${quote}"))
}

# A literal is found in each of the three quotes, and only whole.
expect [
	"'.x'",
	"\".x\"",
	"`.x`",
].all(|held| has_quoted(held.to_utf8(), ".x"))
expect [
	"'.xy'",
	"\".x'",
	".x",
	"'.x\"",
].all(|held| !has_quoted(held.to_utf8(), ".x"))

# Each script finds the elements it works on by the classes this module
# writes, and reads the attributes `Html` writes for it; a class or an
# attribute it leaves to another script is not in it.
expect [TopBar, TopUser].all(|chosen| is_found_by(Script.Chrome.bytes(), chosen))
expect
	[
		Layout,
		Messages,
		Compose,
		Help,
	].all(|chosen| is_found_by(Script.Compose.bytes(), chosen))
expect
	[
		Messages,
		Compose,
		Message,
		Empty,
	].all(|chosen| is_found_by(Script.Feed.bytes(), chosen))
expect !is_found_by(Script.Compose.bytes(), Message) and !is_found_by(Script.Compose.bytes(), Empty)
expect !is_found_by(Script.Feed.bytes(), Help) and !is_found_by(Script.Chrome.bytes(), Messages)
expect
	[
		"data-stream",
		"data-after",
		"data-viewer",
		"data-author",
	].all(
		|name| is_read_by(Script.Feed.bytes(), name) and !is_read_by(
			Script.Compose.bytes(),
			name,
		),
	)
expect
	[
		"data-send",
		"data-upload",
		"data-image-byte-limit",
	].all(
		|name| is_read_by(
			Script.Compose.bytes(),
			name,
		) and !is_read_by(Script.Feed.bytes(), name),
	)
# The classes only styled are styled by the script that owns them.
expect [
	TopTitle,
	Viewer,
].all(|chosen| Str.from_utf8_lossy(Script.Chrome.bytes()).contains(".${class_name(chosen)} {"))
# A message's anchor as an id and as a link, at the first id and the next.
expect {
	second = Message.Id.first.next() ?? crash "Page's tests: the first id has a next"
	plans = Topic.from_str("plans") ?? crash "Page's tests: a topic"
	first_named = MsgAnchor.of({ topic: plans, id: Message.Id.first })
	second_named = MsgAnchor.of({ topic: plans, id: second })
	[
		(Id(anchor(first_named)), "<p id=\"msg-1\"></p>"),
		(Href(anchor(first_named)), "<p href=\"#msg-1\"></p>"),
		(Id(anchor(second_named)), "<p id=\"msg-2\"></p>"),
		(Href(anchor(second_named)), "<p href=\"#msg-2\"></p>"),
	].all(|(attr, expected)| empty_paragraph([attr]) == expected.to_utf8())
}
expect doctype.to_utf8() == "<!doctype html>\n<meta charset=utf-8>\n<meta name=viewport content=\"width=device-width, initial-scale=1\">\n".to_utf8()
# A notice: its title and its words, each escaped, under the colour script.
expect Page.notice({
	title: "a<b",
	text: "x & y",
}).to_utf8() == "${doctype_text}<title>a&lt;b</title>\n<script src=\"/chat/assets/palette.js\"></script>\n<p>x &amp; y</p>".to_utf8()

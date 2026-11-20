## This module builds the pages that say who is in the chat, from `PageKit`'s
## parts: the channels page, `/channels`, and a channel's page of its
## members, `/channels/<name>`, the admin's (`ChannelMembersRoute`); and the
## human invites' page, `/invites` (`HumanInvitesRoute`). The invited human
## joins at the link that page shows (`JoinPage.join`).
import Channels
import DateWords
import Escape
import Html
import HumanInvite
import Name
import PageContract
import PageKit
import SignInPage
import SignedIn
import Timestamp
import TrustedHtml
import Users

PeoplePages :: [].{

	## The channels page, for `viewer`, the admin: each of `channels`,
	## linked to its page, then a form that creates one.
	channels : { viewer : SignedIn, channels : List(Channels.Channel) } -> TrustedHtml
	channels = |{ viewer, channels: all }|
		PageKit.signed_in_page({
			title: "Channels",
			viewer,
			parts: all.map(
				|channel|
					PageKit.link_paragraph({
						path: "/channels/${channel.name().to_str()}",
						text: "#${channel.name().to_str()}",
					}),
			).append(
				PageKit.text_form({
					action: "/channels",
					fields: [{ label: "Name", name: "name" }],
					label: "Create a channel",
				}),
			),
			panel: PlainPanel,
		})

	## A channel's page, for `viewer`, the admin: its members, each with a
	## button that removes them, then every other of `users` with a button
	## that adds them.
	channel_members : {
		viewer : SignedIn,
		channel : Channels.Channel,
		users : List(Users.User),
	} -> TrustedHtml
	channel_members = |{ viewer, channel, users }| {
		folder = "/channels/${channel.name().to_str()}/members"
		row = |user, act|
			member_button({ folder, user, act })
		members = users.keep_if(|user| channel.has_member(user))
		others = users.drop_if(|user| channel.has_member(user))
		PageKit.signed_in_page({
			title: "#${channel.name().to_str()}",
			viewer,
			parts: List.concat(
				List.concat(
					[PageKit.paragraph("Members: ${members.len().to_str()}.")],
					members.map(|user| row(user, Remove)),
				)
					.append(PageKit.paragraph("Everyone else:")),
				others.map(|user| row(user, Add)),
			),
			panel: PlainPanel,
		})
	}

	## One human the viewer may invite again, with their invites.
	InvitedHuman : { human : Users.User, invites : List(HumanInvite) }

	## What the invites page's lines are written from: who is in the chat,
	## who is reading, and the moment that says which invites are open.
	InvitesContext : {
		users : Users,
		viewer : SignedIn,
		now : Timestamp,
	}

	## The invites page, for `viewer`. When an invite was just made, first a
	## card of the link that joins by it (`shown`), the one time it is shown,
	## and everything else behind a quiet "Invite someone else". Then the
	## steps of inviting, a quiet line of what an invite is for, which depends
	## on whether `github` signs people up too, and a form that invites
	## someone by a name, or, when the viewer may not invite (`may_invite`),
	## the line saying why; `problem` under it, when there is one, the form
	## holding the name that was typed. Then those of `invited` who have an
	## invite open at `now`, and last the rest, each human a row of their
	## invites in words, with a button that makes a new link. Each maker is
	## found among `users`.
	invites : {
		viewer : SignedIn,
		users : Users,
		invited : List(PeoplePages.InvitedHuman),
		github : SignInPage.GitHubOffer,
		may_invite : [MayInvite, MayNotInvite(Str)],
		shown : [NoLink, Link({ human : Users.User, link : Str })],
		problem : [NoProblem, Problem({ words : Str, typed : [Typed(Name), NothingTyped] })],
		now : Timestamp,
	} -> TrustedHtml
	invites = |
		{
			viewer,
			users,
			invited,
			github,
			may_invite,
			shown,
			problem,
			now,
		},
	| {
		(said, typed) =
			match problem {
				NoProblem => ([], NothingTyped)
				Problem({ words, typed: kept }) => ([PageKit.problem(words)], kept)
			}
		form =
			match may_invite {
				MayInvite => invite_form(typed)
				MayNotInvite(why) => PageKit.paragraph(why)
			}
		ask_parts = [
			invite_steps,
			[quiet(invite_purpose(github)), form],
			said,
		].join()
		{ waiting_humans, past_humans } = split_by_open_invite(invited, now)
		context = { users, viewer, now }
		PageKit.signed_in_page({
			title: "Invites",
			viewer,
			parts: [
				made_parts(shown, ask_parts),
				open_section_parts(waiting_humans, context),
				past_section_parts(past_humans, context),
			].join(),
			panel: PlainPanel,
		})
	}
}

## The top of the invites page: `ask_parts` (the steps and the form) alone;
## or, when a link was just made, its card, and `ask_parts` behind "Invite
## someone else", closed until asked.
made_parts :
	[NoLink, Link({ human : Users.User, link : Str })], List(TrustedHtml) -> List(TrustedHtml)
made_parts = |shown, ask_parts|
	match shown {
		NoLink => ask_parts
		Link({ human, link }) => [
			Html.element({
				name: Div,
				attributes: [PageContract.class(InviteMade)],
				inner: TrustedHtml.join([
					PageKit.paragraph("Send this link to ${human.name().to_str()}. It works once, for 7 days, and is shown only this once, so copy it now."),
					PageKit.shown_code(link),
				]),
			}),
			PageKit.newline,
			Html.element({
				name: Details,
				attributes: [],
				inner: TrustedHtml.join(
					List.concat(
						[
							Html.element({
								name: Summary,
								attributes: [],
								inner: Escape.text("Invite someone else"),
							}),
						],
						ask_parts,
					),
				),
			}),
			PageKit.newline,
		]
	}

## The form that invites someone by a name, holding `typed`, the name a
## refused invite was for.
invite_form : [Typed(Name), NothingTyped] -> TrustedHtml
invite_form = |typed| {
	value =
		match typed {
			Typed(name) => [NameValue(name)]
			NothingTyped => []
		}
	Html.element({
		name: Form,
		attributes: [MethodPost, Action(PageKit.site_path(PageKit.invites_path))],
		inner: TrustedHtml.join([
			PageKit.labelled_input({
				label: "Their name",
				attributes: List.concat(
					[
						InputType(Text),
						FieldName(PageKit.token("name")),
						Required,
					],
					value,
				),
			}),
			Html.element({
				name: Button,
				attributes: [],
				inner: Escape.text("Invite someone"),
			}),
		]),
	})
}

## A quiet line (`Help`) of `said`.
quiet : Str -> TrustedHtml
quiet = |said|
	Html.element({
		name: P,
		attributes: [PageContract.class(Help)],
		inner: Escape.text(said),
	})

## What an invite is for, in one quiet line. It mentions GitHub only on a
## server that signs people up by GitHub.
invite_purpose : SignInPage.GitHubOffer -> Str
invite_purpose = |github|
	match github {
		Offered => "An invite is for someone without GitHub: anyone with GitHub can sign up on their own."
		NotOffered => "They choose a password when they join, and may keep the name or choose another."
	}

## How to invite someone, a step a line.
invite_steps : List(TrustedHtml)
invite_steps = [
	PageKit.paragraph("1. Type their name."),
	PageKit.paragraph("2. Copy the link."),
	PageKit.paragraph("3. Send it to them; it works once, for 7 days."),
]

## One human on the invites page, and whether any invite of theirs was ever
## spent, so they have joined.
ListedHuman : {
	human : Users.User,
	invites : List(HumanInvite),
	joined : Bool,
}

## `invited` split in two at `now`: first the humans with an open invite, each
## with only their open invites, then everyone else, with all of theirs.
split_by_open_invite : List(PeoplePages.InvitedHuman),
Timestamp -> {
	waiting_humans : List(ListedHuman),
	past_humans : List(ListedHuman),
}
split_by_open_invite = |invited, now| {
	has_open = |listed| listed.invites.any(|invite| invite.is_open(now))
	joined = |invites| invites.any(|invite| invite.state() == Spent)
	waiting_humans = invited.keep_if(has_open).map(
		|{ human, invites }| {
			human,
			invites: invites.keep_if(|invite| invite.is_open(now)),
			joined: joined(invites),
		},
	)
	past_humans = invited.drop_if(has_open).map(
		|{ human, invites }| { human, invites, joined: joined(invites) },
	)
	{ waiting_humans, past_humans }
}

## A user as a channel's page names them: their name, whether a human or an
## agent, and their id.
user_label : Users.User -> Str
user_label = |user| {
	kind =
		match user.role() {
			Human => "human"
			Agent(_) => "agent"
		}
	"${user.name().to_str()} (${kind}, id ${user.id().to_str()})"
}

## A channel page's button that adds `user` to the channel whose members'
## paths are under `folder`, or removes them.
member_button : {
	folder : Str,
	user : Users.User,
	act : [Add, Remove],
} -> TrustedHtml
member_button = |{ folder, user, act }| {
	(word, label) =
		match act {
			Add => ("add", "Add")
			Remove => ("remove", "Remove")
		}
	PageKit.post_button({
		action: "${folder}/${user.id().to_str()}/${word}",
		label: "${label} ${user_label(user)}",
	})
}

## The invites page's list of open invites, which says so when it has none.
open_section_parts : List(ListedHuman), PeoplePages.InvitesContext -> List(TrustedHtml)
open_section_parts = |waiting_humans, context| {
	heading = PageKit.heading("Open invites")
	if waiting_humans.is_empty() {
		[heading, PageKit.paragraph("No open invites.")]
	} else {
		List.concat(
			[heading, quiet("A link is shown only once. If one is lost, make a new link.")],
			waiting_humans.map(|human| invited_row(human, context)),
		)
	}
}

## The invites page's list of everyone else, shown only when there is someone.
## It says what a new link does, as for someone who has joined that is how a
## lost password is replaced.
past_section_parts : List(ListedHuman), PeoplePages.InvitesContext -> List(TrustedHtml)
past_section_parts = |past_humans, context|
	if past_humans.is_empty() {
		[]
	} else {
		List.concat(
			[
				PageKit.heading("Past invites"),
				quiet("A new link for someone who has joined lets them set a new password; they keep their name."),
			],
			past_humans.map(|human| invited_row(human, context)),
		)
	}

## One human's row on the invites page (`InviteRow`): a line for each of
## their invites, or a line saying they have none, and at the row's right
## the button that makes them a new link. A human has none when writing their
## invite failed after their account.
invited_row : ListedHuman, PeoplePages.InvitesContext -> TrustedHtml
invited_row = |{ human, invites, joined }, context| {
	name = human.name().to_str()
	said =
		if invites.is_empty() {
			[PageKit.paragraph("${name} has no link yet")]
		} else {
			invites.map(|invite| PageKit.paragraph(invite_words({ invite, name, joined, context })))
		}
	TrustedHtml.join([
		Html.element({
			name: Div,
			attributes: [PageContract.class(InviteRow)],
			inner: TrustedHtml.join([
				Html.element({
					name: Div,
					attributes: [],
					inner: TrustedHtml.join(said),
				}),
				PageKit.post_button({
					action: "${PageKit.invites_path}/${human.id().to_str()}/again",
					label: "New link",
				}),
			]),
		}),
		PageKit.newline,
	])
}

## One invite of the human `name` in plain words, at `now`: they joined by
## it; it is open, and they haven't joined (or, when they have, it is their
## new link); or it expired. Then who made it, unless the reader did.
invite_words : {
	invite : HumanInvite,
	name : Str,
	joined : Bool,
	context : PeoplePages.InvitesContext,
} -> Str
invite_words = |{ invite, name, joined, context }| {
	{ users, viewer, now } = context
	date = DateWords.phrase({ moment: invite.expires(), now })
	standing =
		match invite.state() {
			Spent => "${name} joined"
			Live if invite.is_open(now) and joined => "${name}'s new link expires ${date}"
			Live if invite.is_open(now) => "${name} hasn't joined · link expires ${date}"
			Live => "${name}'s link expired ${date}"
		}
	maker = invite.invite_maker()
	if maker == viewer.user().id() {
		standing
	} else {
		match users.user(maker) {
			Ok(user) => "${standing} · made by ${user.name().to_str()}"
			Err(NoSuchUser) => "${standing} · made by user ${maker.to_str()}"
		}
	}
}

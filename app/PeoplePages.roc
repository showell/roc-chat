## This module builds the pages that say who is in the chat, from `Page`'s
## parts: the channels page, `/channels`, and a channel's page of its
## members, `/channels/<name>`, the admin's (`ChannelMembersRoute`); and the
## human invites' page, `/invites` (`HumanInvitesRoute`). The invited human
## joins at the link that page shows (`Page.join`).
import Channels
import HumanInvite
import Page
import SignedIn
import Timestamp
import TrustedHtml
import Users

PeoplePages :: [].{

	## The channels page, for `viewer`, the admin: each of `channels`,
	## linked to its page, then a form that creates one.
	channels : { viewer : SignedIn, channels : List(Channels.Channel) } -> TrustedHtml
	channels = |{ viewer, channels: all }|
		Page.signed_in_page({
			title: "Channels",
			viewer,
			parts: all.map(
				|channel|
					Page.link_paragraph({
						path: "/channels/${channel.name().to_str()}",
						text: "#${channel.name().to_str()}",
					}),
			).append(
				Page.text_form({
					action: "/channels",
					fields: [{ label: "Name", name: "name" }],
					label: "Create a channel",
				}),
			),
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
		Page.signed_in_page({
			title: "#${channel.name().to_str()}",
			viewer,
			parts: [Page.text_paragraph("Members: ${members.len().to_str()}.")]
				.concat(members.map(|user| row(user, Remove)))
				.append(Page.text_paragraph("Everyone else:"))
				.concat(others.map(|user| row(user, Add))),
		})
	}

	## One human the viewer may invite again, with their invites.
	InvitedHuman : { human : Users.User, invites : List(HumanInvite) }

	## What the invites page's lines are written from: who is in the chat, and
	## the moment that says which invites are open.
	InvitesContext : { users : Users, now : Timestamp }

	## The invites page, for `viewer`: `problem`, when there is one; when an
	## invite was just made, the link that joins by it, the one time it is
	## shown (`shown`); what an invite is for, which depends on whether
	## `github` signs people up too; a form that invites someone by a name;
	## then those of `invited` who have an invite open at `now`, and last the
	## rest. Each human has a button that invites them again, and each maker
	## is found among `users`.
	invites : {
		viewer : SignedIn,
		users : Users,
		invited : List(PeoplePages.InvitedHuman),
		github : Page.GitHubOffer,
		shown : [NoLink, Link({ human : Users.User, link : Str })],
		problem : [NoProblem, Problem(Str)],
		now : Timestamp,
	} -> TrustedHtml
	invites = |
		{
			viewer,
			users,
			invited,
			github,
			shown,
			problem,
			now,
		},
	| {
		said =
			match problem {
				NoProblem => []
				Problem(text) => [Page.text_paragraph(text)]
			}
		code =
			match shown {
				NoLink => []
				Link({ human, link }) => [
					Page.text_paragraph("Send this link to ${human.name().to_str()}. It is shown only this once, so copy it now."),
					Page.shown_code(link),
				]
			}
		form = Page.text_form({
			action: Page.invites_path,
			fields: [{ label: "Their name", name: "name" }],
			label: "Invite someone",
		})
		{ waiting, past } = split_by_open_invite(invited, now)
		context = { users, now }
		Page.signed_in_page({
			title: "Invites",
			viewer,
			parts: said
				.concat(code)
				.concat([
					Page.text_paragraph(invite_purpose(github)),
					Page.text_paragraph(invite_steps),
					form,
				])
				.concat(open_section(waiting, context))
				.concat(past_section(past, context)),
		})
	}
}

## What an invite is for. It mentions GitHub only on a server that signs
## people up by GitHub.
invite_purpose : Page.GitHubOffer -> Str
invite_purpose = |github|
	match github {
		Offered => "An invite brings in someone who doesn't use GitHub. They choose a password, and sign in with their name and that password. Anyone with GitHub can sign up on their own, with no invite."
		NotOffered => "An invite brings someone into the chat. They choose a password, and sign in with their name and that password."
	}

## How to make an invite.
invite_steps : Str
invite_steps = "Write the name you know them by, and you get a link to send them. The link works once, for seven days. They can keep the name or choose another."

## `invited` split in two at `now`: first the humans with an open invite, each
## with only their open invites, then everyone else, with all of theirs.
split_by_open_invite : List(PeoplePages.InvitedHuman),
Timestamp -> {
	waiting : List(PeoplePages.InvitedHuman),
	past : List(PeoplePages.InvitedHuman),
}
split_by_open_invite = |invited, now| {
	has_open = |listed| listed.invites.any(|invite| invite.is_open(now))
	waiting = invited.keep_if(has_open).map(
		|{ human, invites }| { human, invites: invites.keep_if(|invite| invite.is_open(now)) },
	)
	{ waiting, past: invited.drop_if(has_open) }
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
	Page.button_form({
		action: "${folder}/${user.id().to_str()}/${word}",
		label: "${label} ${user_label(user)}",
	})
}

## The invites page's list of open invites, which says so when it has none.
open_section : List(PeoplePages.InvitedHuman), PeoplePages.InvitesContext -> List(TrustedHtml)
open_section = |waiting, context| {
	heading = Page.heading("Open invites")
	if waiting.is_empty() {
		[heading, Page.text_paragraph("No open invites.")]
	} else {
		[
			heading,
			Page.text_paragraph("A link is shown only once. If one is lost, invite them again for a new link."),
		].concat(waiting.map(|human| invited_rows(human, context)))
	}
}

## The invites page's list of everyone else, shown only when there is someone.
## It says what inviting a human again does, as for someone who has joined
## that is how a lost password is replaced.
past_section : List(PeoplePages.InvitedHuman), PeoplePages.InvitesContext -> List(TrustedHtml)
past_section = |past, context|
	if past.is_empty() {
		[]
	} else {
		[
			Page.heading("Past invites"),
			Page.text_paragraph("Inviting someone again makes a new link. If they have joined, they keep their name, and the link sets a new password."),
		].concat(past.map(|human| invited_rows(human, context)))
	}

## One human's rows on the invites page: a line for each of their invites, or
## a line saying they have none, and the button that invites them again. A
## human has none when writing their invite failed after their account.
invited_rows : PeoplePages.InvitedHuman, PeoplePages.InvitesContext -> TrustedHtml
invited_rows = |{ human, invites }, context| {
	name = human.name().to_str()
	said =
		if invites.is_empty() {
			[Page.text_paragraph("${name}: no invite yet.")]
		} else {
			invites.map(|invite| Page.text_paragraph("${name}: ${invite_words(invite, context)}"))
		}
	again = Page.button_form({
		action: "${Page.invites_path}/${human.id().to_str()}/again",
		label: "Invite ${name} again",
	})
	TrustedHtml.join(said.append(again))
}

## One invite in words: used, open, or past its date at `now`, and who made it.
invite_words : HumanInvite, PeoplePages.InvitesContext -> Str
invite_words = |invite, { users, now }| {
	date = Page.date_words(invite.expires())
	standing =
		match invite.state() {
			Spent => "used"
			Live if invite.is_open(now) => "open until ${date}"
			Live => "expired on ${date}"
		}
	maker =
		match users.user(invite.by()) {
			Ok(user) => user.name().to_str()
			Err(NoSuchUser) => "user ${invite.by().to_str()}"
		}
	"${standing}, made by ${maker}."
}

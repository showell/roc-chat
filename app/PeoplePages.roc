## This module builds the pages that say who is in the chat, from `Page`'s
## parts: the channels page, `/channels`, and a channel's page of its
## members, `/channels/<name>`, the admin's (`ChannelMembersRoute`); and the
## human invites' page, `/invites` (`HumanInvitesRoute`). The invited human
## joins at the link that page shows (`Page.join`).
import Channels
import HumanInvite
import Page
import SignedIn
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
	channel_members = |
		{
			viewer,
			channel,
			users,
		},
	| {
		folder = "/channels/${channel.name().to_str()}/members"
		row = |user, act|
			member_button({
				folder,
				user,
				act,
			})
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

	## The invites page, for `viewer`: a form that invites someone by a
	## name; when an invite was just made, the link that joins by it, the
	## one time it is shown (`shown`); then each of `invited`, with their
	## invites and a button that invites them again.
	invites : {
		viewer : SignedIn,
		invited : List(PeoplePages.InvitedHuman),
		shown : [NoLink, Link({ human : Users.User, link : Str })],
	} -> TrustedHtml
	invites = |
		{
			viewer,
			invited,
			shown,
		},
	| {
		code =
			match shown {
				NoLink => []
				Link({ human, link }) => [
					Page.text_paragraph("The link that lets ${human.name().to_str()} join, shown this once. Send it to them: it works once, for seven days. They keep the name you chose, or choose another, and choose their password."),
					Page.shown_code(link),
				]
			}
		form = Page.text_form({
			action: "/invites",
			fields: [{ label: "Name", name: "name" }],
			label: "Invite someone",
		})
		Page.signed_in_page({
			title: "Invites",
			viewer,
			parts: code.append(form).concat(invited.map(invited_section)),
		})
	}
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
member_button = |
	{
		folder,
		user,
		act,
	},
| {
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

## One human's part of the invites page: their name and id, their invites,
## and the button that invites them again.
invited_section : PeoplePages.InvitedHuman -> TrustedHtml
invited_section = |{ human, invites }| {
	who = "${human.name().to_str()} (id ${human.id().to_str()})"
	said =
		invites.map(
			|invite| {
				state_word =
					match invite.state() {
						Live => "live"
						Spent => "redeemed"
					}
				invite_id = invite.id().to_str()
				expiry = Page.time_words(invite.expires())
				Page.text_paragraph("Invite ${invite_id}: ${state_word}, expires ${expiry}, made by id ${invite.by().to_str()}.")
			},
		)
	again = Page.button_form({
		action: "/invites/${human.id().to_str()}/again",
		label: "Invite ${human.name().to_str()} again",
	})
	TrustedHtml.join([Page.text_paragraph(who)].concat(said).append(again))
}

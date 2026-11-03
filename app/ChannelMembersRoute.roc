## This module answers the channel routes (`Route` lists them), moving data
## between the web interface and the file system, as `AgentsRoute` does for
## agents. What each route may do is `ChannelMembers`' to decide; this
## module reads, writes and answers.
##
## Every route here is the admin's, by their own session: `/channels` lists
## the channels and creates one, and `/channels/<name>` lists a channel's
## members and adds or removes one, human or agent. A change writes the
## channel's members file (`FileSystem.replace_channel_members!`) and sends
## the browser back to the channel's page (a 303). Removing a member ends
## every stream they hold, so a listener reconnects and is asked again
## whether it may read.
import pf.Host
import pf.Http
import AgentStream
import ChannelMembers
import ChannelName
import ConversationStream
import Directory
import FileSystem
import HttpAnswer
import Page
import PeoplePages
import SignedIn
import UserId

ChannelMembersRoute :: [].{

	## A GET of `/channels`: every channel, each linked to its page, and a
	## form that creates one.
	show_channels : { acting : SignedIn, directory : Directory } -> Http.Response
	show_channels = |{ acting, directory }|
		match ChannelMembers.admin_of(acting) {
			Ok(_) => HttpAnswer.page(
				200,
				PeoplePages.channels({
					viewer: acting,
					channels: directory.channels().to_list(),
				}),
			)
			Err(why) => refusal_page(Refused(why))
		}

	## A POST of `/channels`: an empty channel created, named by the form's
	## `name`; then its page.
	create! : {
		acting : SignedIn,
		directory : Directory,
		body : List(U8),
	} => Http.Response
	create! = |
		{
			acting,
			directory,
			body,
		},
	|
		match create_channel!({
			acting,
			directory,
			body,
		}) {
			Ok(name) => HttpAnswer.see_other(channel_path(name))
			Err(why) => refusal_page(why)
		}

	## A GET of `/channels/<name>`: the channel's members, each with a
	## button that removes them, and every other user with a button that
	## adds them.
	show_members : {
		acting : SignedIn,
		directory : Directory,
		channel : ChannelName,
	} -> Http.Response
	show_members = |
		{
			acting,
			directory,
			channel,
		},
	|
		match ChannelMembers.members_page_of(directory, { acting, channel }) {
			Ok(found) => HttpAnswer.page(
				200,
				PeoplePages.channel_members({
					viewer: acting,
					channel: found.channel,
					users: found.users,
				}),
			)
			Err(why) => refusal_page(Refused(why))
		}

	## A POST of `/channels/<name>/members/<id>/add`: the user added to the
	## channel; then its page.
	add! : {
		acting : SignedIn,
		directory : Directory,
		channel : ChannelName,
		member : UserId,
	} => Http.Response
	add! = |
		{
			acting,
			directory,
			channel,
			member,
		},
	|
		match ChannelMembers.add(
			directory,
			{
				acting,
				channel,
				member,
			},
		) {
			Err(why) => refusal_page(Refused(why))
			Ok(change) =>
				match FileSystem.replace_channel_members!(change.channel) {
					Ok({}) => HttpAnswer.see_other(channel_path(channel))
					Err(fault) => refusal_page(FileSystem(fault))
				}
		}

	## A POST of `/channels/<name>/members/<id>/remove`: the user removed
	## from the channel, and every stream they hold ended; then its page.
	remove! : {
		acting : SignedIn,
		directory : Directory,
		channel : ChannelName,
		member : UserId,
	} => Http.Response
	remove! = |
		{
			acting,
			directory,
			channel,
			member,
		},
	|
		match ChannelMembers.remove(
			directory,
			{
				acting,
				channel,
				member,
			},
		) {
			Err(why) => refusal_page(Refused(why))
			Ok(change) =>
				match FileSystem.replace_channel_members!(change.channel) {
					Ok({}) => {
						Host.end_every_stream_of_holder!(AgentStream.holder(member))
						Host.end_every_stream_of_holder!(ConversationStream.holder(member))
						HttpAnswer.see_other(channel_path(channel))
					}
					Err(fault) => refusal_page(FileSystem(fault))
				}
		}
}

## Why a route here refused: one of `ChannelMembers`' refusals, or the file
## system's fault.
Failure : [
	Refused(ChannelMembers.Refusal),
	FileSystem(FileSystem.Fault),
]

## A failure as a page, with its status.
refusal_page : Failure -> Http.Response
refusal_page = |why| {
	notice =
		match why {
			Refused(refusal) => ChannelMembers.refusal_notice(refusal)
			FileSystem(fault) => { status: 500, said: FileSystem.fault_words(fault) }
		}
	HttpAnswer.page(notice.status, Page.notice({ title: "Refused", text: notice.said }))
}

## The channel created, its members file written empty; its name, or why
## not.
create_channel! : {
	acting : SignedIn,
	directory : Directory,
	body : List(U8),
} => Try(ChannelName, _)
create_channel! = |
	{
		acting,
		directory,
		body,
	},
| {
	created = ChannelMembers.create(directory, { acting, body }) ? |why| Refused(why)
	FileSystem.replace_channel_members!(created.channel) ? |fault| FileSystem(fault)
	Ok(created.channel.name())
}

## The page of the channel `name`.
channel_path : ChannelName -> Str
channel_path = |name| "/channels/${name.to_str()}"

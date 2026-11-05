## This module decides what the channel routes may do, with no effects, so
## its tests reach every rule; `ChannelMembersRoute` reads and writes the
## files and answers. The rule: who is in a channel is the
## admin's decision, made by their own session. The admin creates a channel,
## and adds or removes its members, humans and agents alike. Nobody else
## does, and no API key does, whoever it names, so one stolen key never lets
## anyone in. The admin is no member by being one: they take part in a
## channel only once they add themself.
import Admin
import ChannelName
import Channels
import Directory
import SignedIn
import UrlEncodedForm
import UserId
import Users

ChannelMembers :: [].{

	## Every reason a channel route refuses, as `refusal_notice` takes it.
	Refusal : [
		ByApiKey,
		Agent(UserId),
		NotAdmin,
		NoSuchChannel,
		NoSuchUser,
		AlreadyMember,
		NotMember,
		BadForm(Str),
		BadName,
		NameTaken,
	]

	## A refusal in words, with its status: a request with a key, an agent,
	## or a human who is not the admin, a 403; no such channel or user, a
	## 404; a form at fault or a name that is no channel's, a 400; a member
	## added twice, one removed who is not in, or a name taken, a 409.
	refusal_notice : ChannelMembers.Refusal -> { status : U16, said : Str }
	refusal_notice = |why|
		match why {
			ByApiKey => {
				status: 403,
				said: "An API key can't change channels: only the admin, signed in, does.",
			}
			Agent(_) => { status: 403, said: "An agent can't change channels." }
			NotAdmin => {
				status: 403,
				said: "Only the admin creates a channel or changes who is in one.",
			}
			NoSuchChannel => { status: 404, said: "No such channel." }
			NoSuchUser => { status: 404, said: "No such user." }
			AlreadyMember => { status: 409, said: "They are in the channel already." }
			NotMember => { status: 409, said: "They are not in the channel." }
			BadForm(said) => { status: 400, said }
			BadName => {
				status: 400,
				said: "The name is not a channel's: a letter, then letters, digits and hyphens, at most 40.",
			}
			NameTaken => { status: 409, said: "The name is taken." }
		}

	## The acting user as the admin, signed in by their own session; unless
	## they came with an API key (`ByApiKey`), are an agent (`Agent`), or are
	## a human who is not the admin (`NotAdmin`).
	admin_of : SignedIn -> Try(
		Admin,
		[
			ByApiKey,
			Agent(UserId),
			NotAdmin,
		],
	)
	admin_of = |acting| {
		_ = acting.human_in_session()?
		Admin.of(acting)
	}

	## `directory` with an empty channel named by the form `body`'s field
	## `name`, created by `acting`, and that channel; or why not.
	create : Directory,
	{ acting : SignedIn, body : List(U8) } -> Try(
		Directory.Created,
		[
			ByApiKey,
			Agent(UserId),
			NotAdmin,
			BadForm(Str),
			BadName,
			NameTaken,
		],
	)
	create = |directory, { acting, body }| {
		admin = ChannelMembers.admin_of(acting)?
		unchecked = UrlEncodedForm.field({ body, name: "name" }) ? |fault| BadForm(
			UrlEncodedForm.fault_words({
				fault,
				name: "name",
			}),
		)
		name = unchecked.channel_name() ? |_| BadName
		directory.create_channel({ by: admin, name })
	}

	## `directory` with the user `member` added to the channel `channel` by
	## `acting`, and the channel as it is after; or why not.
	add : Directory,
	{
		acting : SignedIn,
		channel : ChannelName,
		member : UserId,
	} -> Try(
		ChannelMembers.Change,
		[
			ByApiKey,
			Agent(UserId),
			NotAdmin,
			NoSuchChannel,
			NoSuchUser,
			AlreadyMember,
		],
	)
	add = |
		directory,
		{
			acting,
			channel,
			member,
		},
	| {
		admin = ChannelMembers.admin_of(acting)?
		user = directory.users().user(member)?
		changed = directory.add_member({
			by: admin,
			channel,
			member: user,
		})?
		Ok(change_of(changed, channel))
	}

	## `directory` with the user `member` removed from the channel `channel`
	## by `acting`, and the channel as it is after; or why not.
	remove : Directory,
	{
		acting : SignedIn,
		channel : ChannelName,
		member : UserId,
	} -> Try(
		ChannelMembers.Change,
		[
			ByApiKey,
			Agent(UserId),
			NotAdmin,
			NoSuchChannel,
			NoSuchUser,
			NotMember,
		],
	)
	remove = |
		directory,
		{
			acting,
			channel,
			member,
		},
	| {
		admin = ChannelMembers.admin_of(acting)?
		user = directory.users().user(member)?
		changed = directory.remove_member({
			by: admin,
			channel,
			member: user,
		})?
		Ok(change_of(changed, channel))
	}

	## What a change of members gives: the directory after it, and the
	## channel as it is now, whose members file is written.
	Change : { directory : Directory, channel : Channels.Channel }

	## The channel `channel` as `acting`, the admin, sees it on its page,
	## with every user; or why not.
	members_page_of : Directory,
	{ acting : SignedIn, channel : ChannelName } -> Try(
		{ channel : Channels.Channel, users : List(Users.User) },
		[
			ByApiKey,
			Agent(UserId),
			NotAdmin,
			NoSuchChannel,
		],
	)
	members_page_of = |directory, { acting, channel }| {
		_ = ChannelMembers.admin_of(acting)?
		found = directory.channels().channel(channel)?
		Ok({ channel: found, users: directory.users().to_list() })
	}
}

## The change's directory, and its channel, which a change found there.
change_of : Directory, ChannelName -> ChannelMembers.Change
change_of = |directory, name|
	match directory.channels().channel(name) {
		Ok(channel) => { directory, channel }
		Err(NoSuchChannel) =>
			crash "ChannelMembers.change_of: a channel whose members changed is in the directory"
	}

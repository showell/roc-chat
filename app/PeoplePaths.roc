## This module reads the paths of the people's routes, which `Route`
## chooses among: what a path names under `/login`, `/logout`, `/join`
## and `/devices` (signing in or out, joining, or a device code), under
## `/agents`, under `/channels`, and under `/invites`. Each reader answers
## the resource a path names, or that the path is none of its routes, and
## `Route` pairs the resource with a method.
import AgentInvite
import AgentKey
import ChannelName
import UnvalidatedString
import UserId

PeoplePaths :: [].{

	## What a path under `/invites` names.
	InvitesResource : [Invites, Again(UserId)]

	## What `path` names under `/invites`, or `NotInvites`.
	invites_resource : UnvalidatedString -> Try(PeoplePaths.InvitesResource, [NotInvites])
	invites_resource = |path|
		match path.url_path_parts() {
			Ok([invites]) if invites.is_exactly("invites") => Ok(Invites)
			Ok(
				[invites, id, again],
			) if invites.is_exactly("invites") and again.is_exactly("again") =>
				id.user_id().map_ok(|human| Again(human)).map_err(|_| NotInvites)
			_ => Err(NotInvites)
		}

	## What a sign-in path names: signing in or out, or joining.
	SignInResource : [
		Login,
		Logout,
		JoinPage,
		JoinName,
		GitHubStart,
		GitHubReturn,
		GitHubName,
		GitHubLink,
		LoginCode,
		Devices,
		DevicesCancel,
		DevicesStream,
		DevicesSignOutOthers,
	]

	## What `path` names among the sign-in routes, or `NotSignIn`.
	sign_in_resource : UnvalidatedString -> Try(PeoplePaths.SignInResource, [NotSignIn])
	sign_in_resource = |path|
		match path.url_path_parts() {
			Ok([only]) if only.is_exactly("login") => Ok(Login)
			Ok([only]) if only.is_exactly("logout") => Ok(Logout)
			Ok([only]) if only.is_exactly("join") => Ok(JoinPage)
			Ok([only]) if only.is_exactly("devices") => Ok(Devices)
			Ok([devices, last]) if devices.is_exactly("devices") and last.is_exactly("cancel") =>
				Ok(DevicesCancel)
			Ok([devices, last]) if devices.is_exactly("devices") and last.is_exactly("stream") =>
				Ok(DevicesStream)
			Ok(
				[devices, last],
			) if devices.is_exactly("devices") and last.is_exactly("sign-out-others") =>
				Ok(DevicesSignOutOthers)
			Ok(
				[login, code],
			) if login.is_exactly("login") and code.is_exactly("code") => Ok(LoginCode)
			Ok([join, name]) if join.is_exactly("join") and name.is_exactly("name") => Ok(JoinName)
			Ok([login, github]) if login.is_exactly("login") and github.is_exactly("github") =>
				Ok(GitHubReturn)
			Ok(
				[login, github, start],
			) if login.is_exactly("login") and github.is_exactly("github") and start.is_exactly("start") =>
				Ok(GitHubStart)
			Ok(
				[login, github, name],
			) if login.is_exactly("login") and github.is_exactly("github") and name.is_exactly("name") =>
				Ok(GitHubName)
			Ok(
				[login, github, link],
			) if login.is_exactly("login") and github.is_exactly("github") and link.is_exactly("link") =>
				Ok(GitHubLink)
			_ => Err(NotSignIn)
		}

	## What a path under `/agents` names.
	AgentsResource : [
		Agents,
		Invites(UserId),
		InviteRevoke({ agent : UserId, invite : AgentInvite.Id }),
		KeyRevoke({ agent : UserId, key : AgentKey.Id }),
		Redeem,
		AgentStream,
	]

	## What `path` names under `/agents`, or `NotAgents`.
	agents_resource : UnvalidatedString -> Try(PeoplePaths.AgentsResource, [NotAgents])
	agents_resource = |path|
		match path.url_path_parts() {
			Ok([agents]) if agents.is_exactly("agents") => Ok(Agents)
			Ok(
				[agents, last],
			) if agents.is_exactly("agents") and last.is_exactly("redeem") => Ok(Redeem)
			Ok(
				[agents, last],
			) if agents.is_exactly("agents") and last.is_exactly("stream") => Ok(AgentStream)
			Ok(
				[agents, id, invites],
			) if agents.is_exactly("agents") and invites.is_exactly("invites") =>
				id.user_id().map_ok(|agent| Invites(agent)).map_err(|_| NotAgents)
			Ok(
				[agents, id, kind, number, revoke],
			) if agents.is_exactly("agents") and revoke.is_exactly("revoke") => {
				agent = id.user_id() ? |_| NotAgents
				if kind.is_exactly("invites") {
					number.invite_id().map_ok(
						|invite| InviteRevoke({ agent, invite }),
					).map_err(|_| NotAgents)
				} else if kind.is_exactly("keys") {
					number.key_id().map_ok(|key| KeyRevoke({ agent, key })).map_err(|_| NotAgents)
				} else {
					Err(NotAgents)
				}
			}
			_ => Err(NotAgents)
		}

	## What a path under `/channels` names.
	ChannelsResource : [
		Channels,
		Members(ChannelName),
		MemberAdd({ channel : ChannelName, member : UserId }),
		MemberRemove({ channel : ChannelName, member : UserId }),
	]

	## What `path` names under `/channels`, or `NotChannels`.
	channels_resource : UnvalidatedString -> Try(PeoplePaths.ChannelsResource, [NotChannels])
	channels_resource = |path|
		match path.url_path_parts() {
			Ok([channels]) if channels.is_exactly("channels") => Ok(Channels)
			Ok([channels, name]) if channels.is_exactly("channels") =>
				name.channel_name().map_ok(|channel| Members(channel)).map_err(|_| NotChannels)
			Ok(
				[channels, name, members, id, act],
			) if channels.is_exactly("channels") and members.is_exactly("members") => {
				channel = name.channel_name() ? |_| NotChannels
				member = id.user_id() ? |_| NotChannels
				if act.is_exactly("add") {
					Ok(MemberAdd({ channel, member }))
				} else if act.is_exactly("remove") {
					Ok(MemberRemove({ channel, member }))
				} else {
					Err(NotChannels)
				}
			}
			_ => Err(NotChannels)
		}
}

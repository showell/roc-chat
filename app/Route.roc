## This module decides which answer a request's method and path ask for.
## It is a pure decision, so its tests (`RouteSpec`) reach every route, and
## the host routes nothing.
##
##     GET  /chat/channel/<channel>/<topic>    the conversation's page
##     GET  /chat/dm/<pair>/<topic>
##     POST the same paths, a form field `markdown`: a message appended
##     POST the same paths and `/send`, the same: the script's send
##     GET  the same paths and `/stream`       the conversation's stream
##     GET  the same paths and `/raw`          its transcript, plain text
##     POST the same paths and `/upload`       an image uploaded to it
##     GET  the same paths, `/uploads/<name>`  an image uploaded to it
##     GET  /chat/assets/palette.js            the pages' scripts
##     GET  /chat/assets/chrome.js
##     GET  /chat/assets/compose.js
##     GET  /chat/assets/feed.js
##     GET  /login                             the sign-in page
##     POST /login                             sign in: `name=`, `password=`
##     GET  /login/github/start                off to GitHub: `?next=<path>`
##     GET  /login/github                      GitHub's way back
##     POST /logout                            sign out
##     GET  /agents                            your agents, keys, invites
##     POST /agents                            make an agent: `name=`
##     POST /agents/<id>/invites               invite it: `read=`, `post=`
##     POST /agents/<id>/invites/<n>/revoke    revoke an invite
##     POST /agents/<id>/keys/<n>/revoke       revoke a key
##     POST /agents/redeem                     an agent's: `code=`, its key
##     GET  /agents/stream                     an agent's one stream
##     GET  /channels                          the channels (the admin's)
##     POST /channels                          create one: `name=`
##     GET  /channels/<name>                   its members, to add or remove
##     POST /channels/<name>/members/<id>/add  add a user to it
##     POST /channels/<name>/members/<id>/remove   remove one
##     GET  /invites                           your human invites
##     POST /invites                           invite someone: `name=`
##     POST /invites/<id>/again                invite a human again
##     GET  /join                              the join page, the code after `#`
##     POST /join/name                         the name a code's invite holds
##     POST /join                              join: `code=`, `name=`, `password=`
##
## A route is `Open`, answered to anyone, a request that proves no one
## included: the scripts, the sign-in routes, an agent's redemption, and
## the join routes.
## Every other is `SignedInOnly`. So which routes answer someone not signed
## in is said here once, by the type, and main answers each `SignedInOnly`
## route to no one but someone signed in.
##
## A conversation's path is `ConversationKey`'s to read, which says which
## of its resources the path names, and each script's is `Script`'s. A
## path that names no conversation the directory holds is not found. Who
## may use each route is decided later: a conversation's by `Access`, an
## agent's by `Agents`, a channel's by `ChannelMembers`.
##
## Every pairing of a resource and a method is written out, so a new
## method or resource is a decision here rather than a wildcard's.
import AgentInvite
import AgentKey
import ChannelName
import ConversationKey
import Directory
import Script
import UnvalidatedString
import UploadedImage
import UserId

Route :: [].{

	## What a request asks for: a route anyone may use, one only someone
	## signed in may, nothing here, or a method the path does not take.
	Choice : [
		Open(Route.OpenChoice),
		SignedInOnly(Route.SignedInChoice),
		NotFound,
		MethodNotAllowed([GetAndPost, GetOnly, PostOnly]),
	]

	## The routes anyone may use, a request that proves no one included.
	OpenChoice : [
		ServeScript(Script),
		ShowLogin,
		SignIn,
		SignOut,
		StartGitHubSignIn,
		FinishGitHubSignIn,
		WrongMethodToGitHub,
		RedeemInvite,
		ShowJoin,
		LookUpJoinName,
		Join,
	]

	## The routes only someone signed in may use.
	SignedInChoice : [
		ShowConversation(ConversationKey),
		AppendToConversation(ConversationKey),
		SendToConversation(ConversationKey),
		OpenConversationStream(ConversationKey),
		ServeRawTranscript(ConversationKey),
		UploadToConversation(ConversationKey),
		ServeUploadedImage({ key : ConversationKey, image : UploadedImage }),
		ShowAgents,
		MakeAgent,
		InviteAgent(UserId),
		RevokeInvite({ agent : UserId, invite : AgentInvite.Id }),
		RevokeKey({ agent : UserId, key : AgentKey.Id }),
		OpenAgentStream,
		ShowChannels,
		CreateChannel,
		ShowChannelMembers(ChannelName),
		AddChannelMember({ channel : ChannelName, member : UserId }),
		RemoveChannelMember({ channel : ChannelName, member : UserId }),
		ShowInvites,
		InviteHuman,
		InviteHumanAgain(UserId),
	]

	## The route for `method` and `path`, as the host handed them, each
	## place looked up in `directory`.
	choose : {
		method : List(U8),
		path : List(U8),
		directory : Directory,
	} -> Route.Choice
	choose = |
		{
			method,
			path,
			directory,
		},
	| {
		asked = method_of(method)
		match Script.all_scripts.find_first(|script| path == script.url_path().to_utf8()) {
			Ok(script) =>
				match asked {
					Get => Open(ServeScript(script))
					Post => MethodNotAllowed(GetOnly)
					Other => MethodNotAllowed(GetOnly)
				}
			Err(NotFound) =>
				match UnvalidatedString.from_utf8(path) {
					Ok(unchecked) => path_choice({
						path: unchecked,
						method: asked,
						directory,
					})
					Err(NotUtf8) => NotFound
				}
		}
	}
}

## The route for `method` and a path under `/invites`, a conversation's, or
## nothing here.
invites_or_conversation_choice : {
	path : UnvalidatedString,
	method : [Get, Post, Other],
	directory : Directory,
} -> Route.Choice
invites_or_conversation_choice = |
	{
		path,
		method,
		directory,
	},
|
	match invites_resource(path) {
		Ok(resource) => invites_choice({ resource, method })
		Err(NotInvites) =>
			conversation_path_choice({
				path,
				method,
				directory,
			})
	}

## What a path under `/invites` names.
InvitesResource : [
	Invites,
	Again(UserId),
]

## What `path` names under `/invites`, or `NotInvites`.
invites_resource : UnvalidatedString -> Try(InvitesResource, [NotInvites])
invites_resource = |path|
	match path.url_path_parts() {
		Ok([invites]) if invites.is_exactly("invites") => Ok(Invites)
		Ok(
			[
				invites,
				id,
				again,
			],
		) if invites.is_exactly("invites") and again.is_exactly("again") =>
			id.user_id().map_ok(|human| Again(human)).map_err(|_| NotInvites)
		_ => Err(NotInvites)
	}

## The route for `method` and an `/invites` path's `resource`.
invites_choice : { resource : InvitesResource, method : [Get, Post, Other] } -> Route.Choice
invites_choice = |{ resource, method }|
	match (resource, method) {
		(Invites, Get) => SignedInOnly(ShowInvites)
		(Invites, Post) => SignedInOnly(InviteHuman)
		(Invites, Other) => MethodNotAllowed(GetAndPost)
		(Again(_), Get) => MethodNotAllowed(PostOnly)
		(Again(human), Post) => SignedInOnly(InviteHumanAgain(human))
		(Again(_), Other) => MethodNotAllowed(PostOnly)
	}

## The route for `method` and a path that is a conversation's, or nothing
## here.
conversation_path_choice : {
	path : UnvalidatedString,
	method : [Get, Post, Other],
	directory : Directory,
} -> Route.Choice
conversation_path_choice = |
	{
		path,
		method,
		directory,
	},
|
	match ConversationKey.from_url_path({ path, directory }) {
		Ok(found) => conversation_choice({
			key: found.key,
			resource: found.resource,
			method,
		})
		Err(NotAConversationPath) => NotFound
		Err(BadName) => NotFound
		Err(NoSuchChannel) => NotFound
		Err(NoSuchHuman) => NotFound
	}

## The route for `method` and a path that is no script's, as text.
path_choice : {
	path : UnvalidatedString,
	method : [Get, Post, Other],
	directory : Directory,
} -> Route.Choice
path_choice = |
	{
		path,
		method,
		directory,
	},
|
	match sign_in_resource(path) {
		Ok(resource) => sign_in_choice({ resource, method })
		Err(NotSignIn) =>
			match agents_resource(path) {
				Ok(resource) => agents_choice({ resource, method })
				Err(NotAgents) =>
					match channels_resource(path) {
						Ok(resource) => channels_choice({ resource, method })
						Err(NotChannels) => invites_or_conversation_choice({
							path,
							method,
							directory,
						})
					}
			}
	}

## The method the host handed, as a route takes it: GET, POST, or any other
## (a method is case-sensitive, so `get` is another).
method_of : List(U8) -> [Get, Post, Other]
method_of = |method|
	if (method == "GET".to_utf8())
		Get
	else if (method == "POST".to_utf8())
		Post
	else
		Other

## The route for `method` and the conversation `key`'s `resource`.
conversation_choice : {
	key : ConversationKey,
	resource : ConversationKey.Resource,
	method : [Get, Post, Other],
} -> Route.Choice
conversation_choice = |
	{
		key,
		resource,
		method,
	},
|
	match (resource, method) {
		(Page, Get) => SignedInOnly(ShowConversation(key))
		(Page, Post) => SignedInOnly(AppendToConversation(key))
		(Page, Other) => MethodNotAllowed(GetAndPost)
		(Stream, Get) => SignedInOnly(OpenConversationStream(key))
		(Stream, Post) => MethodNotAllowed(GetOnly)
		(Stream, Other) => MethodNotAllowed(GetOnly)
		(Raw, Get) => SignedInOnly(ServeRawTranscript(key))
		(Raw, Post) => MethodNotAllowed(GetOnly)
		(Raw, Other) => MethodNotAllowed(GetOnly)
		(Send, Get) => MethodNotAllowed(PostOnly)
		(Send, Post) => SignedInOnly(SendToConversation(key))
		(Send, Other) => MethodNotAllowed(PostOnly)
		(Upload, Get) => MethodNotAllowed(PostOnly)
		(Upload, Post) => SignedInOnly(UploadToConversation(key))
		(Upload, Other) => MethodNotAllowed(PostOnly)
		(UploadedImage(image), Get) => SignedInOnly(ServeUploadedImage({ key, image }))
		(UploadedImage(_), Post) => MethodNotAllowed(GetOnly)
		(UploadedImage(_), Other) => MethodNotAllowed(GetOnly)
	}

## What a sign-in path names: signing in or out, or joining.
SignInResource : [
	Login,
	Logout,
	JoinPage,
	JoinName,
	GitHubStart,
	GitHubReturn,
]

## What `path` names among the sign-in routes, or `NotSignIn`.
sign_in_resource : UnvalidatedString -> Try(SignInResource, [NotSignIn])
sign_in_resource = |path|
	match path.url_path_parts() {
		Ok([only]) if only.is_exactly("login") => Ok(Login)
		Ok([only]) if only.is_exactly("logout") => Ok(Logout)
		Ok([only]) if only.is_exactly("join") => Ok(JoinPage)
		Ok([join, name]) if join.is_exactly("join") and name.is_exactly("name") => Ok(JoinName)
		Ok([login, github]) if login.is_exactly("login") and github.is_exactly("github") =>
			Ok(GitHubReturn)
		Ok(
			[
				login,
				github,
				start,
			],
		) if login.is_exactly("login") and github.is_exactly("github") and start.is_exactly("start") =>
			Ok(GitHubStart)
		_ => Err(NotSignIn)
	}

## The route for `method` and a sign-in path's `resource`.
sign_in_choice : { resource : SignInResource, method : [Get, Post, Other] } -> Route.Choice
sign_in_choice = |{ resource, method }|
	match (resource, method) {
		(Login, Get) => Open(ShowLogin)
		(Login, Post) => Open(SignIn)
		(Login, Other) => MethodNotAllowed(GetAndPost)
		(Logout, Get) => MethodNotAllowed(PostOnly)
		(Logout, Post) => Open(SignOut)
		(Logout, Other) => MethodNotAllowed(PostOnly)
		(JoinPage, Get) => Open(ShowJoin)
		(JoinPage, Post) => Open(Join)
		(JoinPage, Other) => MethodNotAllowed(GetAndPost)
		(JoinName, Get) => MethodNotAllowed(PostOnly)
		(JoinName, Post) => Open(LookUpJoinName)
		(JoinName, Other) => MethodNotAllowed(PostOnly)
		(GitHubStart, Get) => Open(StartGitHubSignIn)
		(GitHubStart, Post) => Open(WrongMethodToGitHub)
		(GitHubStart, Other) => Open(WrongMethodToGitHub)
		(GitHubReturn, Get) => Open(FinishGitHubSignIn)
		(GitHubReturn, Post) => Open(WrongMethodToGitHub)
		(GitHubReturn, Other) => Open(WrongMethodToGitHub)
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
agents_resource : UnvalidatedString -> Try(AgentsResource, [NotAgents])
agents_resource = |path|
	match path.url_path_parts() {
		Ok([agents]) if agents.is_exactly("agents") => Ok(Agents)
		Ok(
			[
				agents,
				last,
			],
		) if agents.is_exactly("agents") and last.is_exactly("redeem") => Ok(Redeem)
		Ok(
			[
				agents,
				last,
			],
		) if agents.is_exactly("agents") and last.is_exactly("stream") => Ok(AgentStream)
		Ok(
			[
				agents,
				id,
				invites,
			],
		) if agents.is_exactly("agents") and invites.is_exactly("invites") =>
			id.user_id().map_ok(|agent| Invites(agent)).map_err(|_| NotAgents)
		Ok(
			[
				agents,
				id,
				kind,
				number,
				revoke,
			],
		) if agents.is_exactly("agents") and revoke.is_exactly("revoke") => {
			agent = id.user_id() ? |_| NotAgents
			if (kind.is_exactly("invites"))
				number.invite_id().map_ok(
					|invite| InviteRevoke({
						agent,
						invite,
					}),
				).map_err(|_| NotAgents)
			else if (kind.is_exactly("keys"))
				number.key_id().map_ok(|key| KeyRevoke({ agent, key })).map_err(|_| NotAgents)
			else
				Err(NotAgents)
		}
		_ => Err(NotAgents)
	}

## The route for `method` and an `/agents` path's `resource`.
agents_choice : { resource : AgentsResource, method : [Get, Post, Other] } -> Route.Choice
agents_choice = |{ resource, method }|
	match (resource, method) {
		(Agents, Get) => SignedInOnly(ShowAgents)
		(Agents, Post) => SignedInOnly(MakeAgent)
		(Agents, Other) => MethodNotAllowed(GetAndPost)
		(Invites(_), Get) => MethodNotAllowed(PostOnly)
		(Invites(agent), Post) => SignedInOnly(InviteAgent(agent))
		(Invites(_), Other) => MethodNotAllowed(PostOnly)
		(InviteRevoke(_), Get) => MethodNotAllowed(PostOnly)
		(InviteRevoke(named), Post) => SignedInOnly(RevokeInvite(named))
		(InviteRevoke(_), Other) => MethodNotAllowed(PostOnly)
		(KeyRevoke(_), Get) => MethodNotAllowed(PostOnly)
		(KeyRevoke(named), Post) => SignedInOnly(RevokeKey(named))
		(KeyRevoke(_), Other) => MethodNotAllowed(PostOnly)
		(Redeem, Get) => MethodNotAllowed(PostOnly)
		(Redeem, Post) => Open(RedeemInvite)
		(Redeem, Other) => MethodNotAllowed(PostOnly)
		(AgentStream, Get) => SignedInOnly(OpenAgentStream)
		(AgentStream, Post) => MethodNotAllowed(GetOnly)
		(AgentStream, Other) => MethodNotAllowed(GetOnly)
	}

## What a path under `/channels` names.
ChannelsResource : [
	Channels,
	Members(ChannelName),
	MemberAdd({ channel : ChannelName, member : UserId }),
	MemberRemove({ channel : ChannelName, member : UserId }),
]

## What `path` names under `/channels`, or `NotChannels`.
channels_resource : UnvalidatedString -> Try(ChannelsResource, [NotChannels])
channels_resource = |path|
	match path.url_path_parts() {
		Ok([channels]) if channels.is_exactly("channels") => Ok(Channels)
		Ok([channels, name]) if channels.is_exactly("channels") =>
			name.channel_name().map_ok(|channel| Members(channel)).map_err(|_| NotChannels)
		Ok(
			[
				channels,
				name,
				members,
				id,
				act,
			],
		) if channels.is_exactly("channels") and members.is_exactly("members") => {
			channel = name.channel_name() ? |_| NotChannels
			member = id.user_id() ? |_| NotChannels
			if (act.is_exactly("add"))
				Ok(MemberAdd({ channel, member }))
			else if (act.is_exactly("remove"))
				Ok(MemberRemove({ channel, member }))
			else
				Err(NotChannels)
		}
		_ => Err(NotChannels)
	}

## The route for `method` and a `/channels` path's `resource`.
channels_choice : { resource : ChannelsResource, method : [Get, Post, Other] } -> Route.Choice
channels_choice = |{ resource, method }|
	match (resource, method) {
		(Channels, Get) => SignedInOnly(ShowChannels)
		(Channels, Post) => SignedInOnly(CreateChannel)
		(Channels, Other) => MethodNotAllowed(GetAndPost)
		(Members(channel), Get) => SignedInOnly(ShowChannelMembers(channel))
		(Members(_), Post) => MethodNotAllowed(GetOnly)
		(Members(_), Other) => MethodNotAllowed(GetOnly)
		(MemberAdd(_), Get) => MethodNotAllowed(PostOnly)
		(MemberAdd(named), Post) => SignedInOnly(AddChannelMember(named))
		(MemberAdd(_), Other) => MethodNotAllowed(PostOnly)
		(MemberRemove(_), Get) => MethodNotAllowed(PostOnly)
		(MemberRemove(named), Post) => SignedInOnly(RemoveChannelMember(named))
		(MemberRemove(_), Other) => MethodNotAllowed(PostOnly)
	}

## This module answers the `/agents` routes (`Route` lists them), moving
## data between the web interface and the file system, as
## `ConversationRoute` does for a conversation. What each route may do is
## `Agents`' to decide; this module reads, writes and answers.
##
## A human's routes answer pages, and send the browser back to `/agents`
## after a change (a 303). An agent's two, the redemption and the stream,
## answer what a script reads: the key as one line of text, and an event
## stream (`AgentStream`). A refusal of an invite's code is one 401 that
## says no more.
##
## `sign_in_by_key!` is the check an agent's `Authorization: Bearer`
## request passes before any route (main's `load_acting_user!`): `AgentKey.admit`
## decides, and `SignedIn.by_api_key` is its one door.
import pf.Host
import pf.Http
import AgentInvite
import AgentKey
import AgentStream
import Agents
import Conversation
import ConversationKey
import Directory
import FileSystem
import HttpAnswer
import KeyScope
import Page
import Place
import Secret
import SecretHash
import SecretToken
import SignedIn
import Transcript
import TrustedHtml
import UserId
import Users

AgentsRoute :: [].{

	## The agent the bearer `token` names, signed in by its key at `now`;
	## unless the key admits no one (`KeyRefused`: no such agent, no key
	## with the secret's hash, or a revoked or expired one), or the files
	## could not be read (`FileSystem`).
	sign_in_by_key! : {
		token : SecretToken,
		directory : Directory,
		now : I64,
	} => Try(SignedIn, [KeyRefused, FileSystem(FileSystem.Fault)])
	sign_in_by_key! = |
		{
			token,
			directory,
			now,
		},
	|
		match directory.users().user(token.agent()) {
			Err(NoSuchUser) => Err(KeyRefused)
			Ok(user) => {
				keys = FileSystem.read_agent_keys!(user.id()) ? |fault| FileSystem(fault)
				hash = hash_secret!(token.secret())
				match AgentKey.admit({
					user,
					keys,
					hash,
					now,
				}) {
					Ok(admitted) => Ok(SignedIn.by_api_key(admitted))
					Err(_) => Err(KeyRefused)
				}
			}
		}

	## A GET of `/agents`: the acting human's agents, their keys and their
	## invites.
	show! : { acting : SignedIn, directory : Directory } => Http.Response
	show! = |{ acting, directory }|
		match load_agents_page!({
			acting,
			directory,
			shown: NoCode,
		}) {
			Ok(html) => HttpAnswer.page(200, html)
			Err(why) => refusal_page(why)
		}

	## A POST of `/agents`: an agent made, named by the form's `name`, owned
	## by the acting human; then back to `/agents`.
	make! : {
		acting : SignedIn,
		directory : Directory,
		body : List(U8),
	} => Http.Response
	make! = |
		{
			acting,
			directory,
			body,
		},
	|
		match make_agent!({
			acting,
			directory,
			body,
		}) {
			Ok({}) => HttpAnswer.see_other("/agents")
			Err(why) => refusal_page(why)
		}

	## A POST of `/agents/<id>/invites`: an invite made for the agent, at
	## `now`, for a key of the scope the form asks; then the agents page,
	## showing its code this once.
	invite! : {
		acting : SignedIn,
		directory : Directory,
		agent : UserId,
		body : List(U8),
		now : I64,
	} => Http.Response
	invite! = |request|
		match invite_agent!(request) {
			Ok(html) => HttpAnswer.page(200, html)
			Err(why) => refusal_page(why)
		}

	## A POST of `/agents/<id>/keys/<n>/revoke`: the key revoked; then back
	## to `/agents`.
	revoke_key! : {
		acting : SignedIn,
		directory : Directory,
		agent : UserId,
		key : AgentKey.Id,
	} => Http.Response
	revoke_key! = |request|
		match revoke_agent_key!(request) {
			Ok({}) => HttpAnswer.see_other("/agents")
			Err(why) => refusal_page(why)
		}

	## A POST of `/agents/<id>/invites/<n>/revoke`: the invite revoked; then
	## back to `/agents`.
	revoke_invite! : {
		acting : SignedIn,
		directory : Directory,
		agent : UserId,
		invite : AgentInvite.Id,
	} => Http.Response
	revoke_invite! = |request|
		match revoke_agent_invite!(request) {
			Ok({}) => HttpAnswer.see_other("/agents")
			Err(why) => refusal_page(why)
		}

	## A POST of `/agents/redeem`: the invite the form's `code` names spent
	## at `now`, and a key made for its agent; answered with the key, as the
	## agent sends it back (`SecretToken`), on one line of plain text.
	redeem! : {
		acting : SignedIn,
		directory : Directory,
		body : List(U8),
		now : I64,
	} => Http.Response
	redeem! = |request|
		match redeem_invite!(request) {
			Ok(key) => HttpAnswer.text(200, key.to_str())
			Err(why) => refusal_text(why)
		}

	## A GET of `/agents/stream` by an agent's key: every message of its
	## channels' conversations since the query's date, then each one
	## posted (`AgentStream`).
	open_stream! : {
		acting : SignedIn,
		directory : Directory,
		query : List(U8),
	} => Http.Response
	open_stream! = |request|
		match begin_agent_stream!(request) {
			Ok(answer) => answer
			Err(why) => refusal_text(why)
		}
}

## Why a route here refused: one of `Agents`' refusals, a stream's start
## that is none, a stream asked for by no key or one that may not read, or
## the file system's fault.
Failure : [
	Refused(Agents.Refusal),
	BadStart,
	StreamNeedsKey,
	StreamReadOff,
	FileSystem(FileSystem.Fault),
]

## A failure in words, with its status.
failure_notice : Failure -> { status : U16, said : Str }
failure_notice = |why|
	match why {
		Refused(refusal) => Agents.refusal_notice(refusal)
		BadStart => { status: 400, said: AgentStream.words(BadSince) }
		StreamNeedsKey => { status: 403, said: "The agents' stream is an agent's, by its API key." }
		StreamReadOff => { status: 403, said: "This key may not read." }
		FileSystem(fault) => { status: 500, said: FileSystem.fault_words(fault) }
	}

## A failure as a page.
refusal_page : Failure -> Http.Response
refusal_page = |why| {
	notice = failure_notice(why)
	HttpAnswer.page(notice.status, Page.notice({ title: "Refused", said: notice.said }))
}

## A failure as a line of plain text, for a script.
refusal_text : Failure -> Http.Response
refusal_text = |why| {
	notice = failure_notice(why)
	HttpAnswer.text(notice.status, notice.said)
}

## The agents page for `acting`, with `shown`'s code if one was just made.
load_agents_page! : {
	acting : SignedIn,
	directory : Directory,
	shown : [NoCode, Code({ agent : Users.User, code : SecretToken })],
} => Try(TrustedHtml, _)
load_agents_page! = |
	{
		acting,
		directory,
		shown,
	},
| {
	owner = acting.human_in_session() ? |why| Refused(why)
	var $summaries = []
	for agent in Agents.agents_of(directory, owner) {
		keys = FileSystem.read_agent_keys!(agent.id()) ? |fault| FileSystem(fault)
		invites = FileSystem.read_agent_invites!(agent.id()) ? |fault| FileSystem(fault)
		$summaries = $summaries.append({
			agent,
			keys,
			invites,
		})
	}
	Ok(
		Page.agents({
			viewer: acting,
			agents: $summaries,
			shown,
		}),
	)
}

make_agent! : {
	acting : SignedIn,
	directory : Directory,
	body : List(U8),
} => Try({}, _)
make_agent! = |
	{
		acting,
		directory,
		body,
	},
| {
	owner = acting.human_in_session() ? |why| Refused(why)
	addition = Agents.make(directory, { owner, body }) ? |why| Refused(why)
	FileSystem.replace_user_counter!(addition.directory.users()) ? |fault| FileSystem(fault)
	FileSystem.create_account!(addition.user) ? |fault| FileSystem(fault)
	Ok({})
}

invite_agent! : {
	acting : SignedIn,
	directory : Directory,
	agent : UserId,
	body : List(U8),
	now : I64,
} => Try(TrustedHtml, _)
invite_agent! = |
	{
		acting,
		directory,
		agent,
		body,
		now,
	},
| {
	owner = acting.human_in_session() ? |why| Refused(why)
	invited = Agents.owned_agent(directory, { owner, agent }) ? |why| Refused(why)
	scope = Agents.scope_from_form(body) ? |why| Refused(why)
	id = FileSystem.find_next_agent_invite_id!(agent) ? |why| full_or_fault(why)
	secret = Secret.from_random_bytes(Host.fill_with_random_bytes!(Secret.length))
	invite = AgentInvite.make({
		id,
		hash: hash_secret!(secret),
		now,
		scope,
	})
	FileSystem.create_agent_invite!(agent, invite) ? |fault| FileSystem(fault)
	load_agents_page!({
		acting,
		directory,
		shown: Code({ agent: invited, code: SecretToken.of({ agent, secret }) }),
	})
}

revoke_agent_key! : {
	acting : SignedIn,
	directory : Directory,
	agent : UserId,
	key : AgentKey.Id,
} => Try({}, _)
revoke_agent_key! = |
	{
		acting,
		directory,
		agent,
		key,
	},
| {
	owner = acting.human_in_session() ? |why| Refused(why)
	_ = Agents.owned_agent(directory, { owner, agent }) ? |why| Refused(why)
	keys = FileSystem.read_agent_keys!(agent) ? |fault| FileSystem(fault)
	revoked = Agents.revoked_key(keys, key) ? |why| Refused(why)
	FileSystem.replace_agent_key_state!(agent, revoked) ? |fault| FileSystem(fault)
	Ok({})
}

revoke_agent_invite! : {
	acting : SignedIn,
	directory : Directory,
	agent : UserId,
	invite : AgentInvite.Id,
} => Try({}, _)
revoke_agent_invite! = |
	{
		acting,
		directory,
		agent,
		invite,
	},
| {
	owner = acting.human_in_session() ? |why| Refused(why)
	_ = Agents.owned_agent(directory, { owner, agent }) ? |why| Refused(why)
	invites = FileSystem.read_agent_invites!(agent) ? |fault| FileSystem(fault)
	revoked = Agents.revoked_invite(invites, invite) ? |why| Refused(why)
	FileSystem.replace_agent_invite_state!(agent, revoked) ? |fault| FileSystem(fault)
	Ok({})
}

## The redemption: the invite spent before the key is made, so a code
## redeems once even when making the key fails.
redeem_invite! : {
	acting : SignedIn,
	directory : Directory,
	body : List(U8),
	now : I64,
} => Try(SecretToken, _)
redeem_invite! = |
	{
		acting,
		directory,
		body,
		now,
	},
| {
	_ =
		match acting.credential() {
			ApiKey(_) => Err(Refused(ByApiKey))
			Session => Ok({})
		}?
	code = Agents.code_from_form(body) ? |why| Refused(why)
	agent = code.agent()
	is_agent =
		match directory.users().user(agent) {
			Ok(user) => user.role() != Human
			Err(NoSuchUser) => Bool.False
		}
	if !is_agent {
		Err(Refused(CodeRefused))
	} else {
		invites = FileSystem.read_agent_invites!(agent) ? |fault| FileSystem(fault)
		spent = AgentInvite.redeem({
			invites,
			hash: hash_secret!(code.secret()),
			now,
		}) ? |_| Refused(CodeRefused)
		FileSystem.replace_agent_invite_state!(agent, spent) ? |fault| FileSystem(fault)
		id = FileSystem.find_next_agent_key_id!(agent) ? |why| full_or_fault(why)
		secret = Secret.from_random_bytes(Host.fill_with_random_bytes!(Secret.length))
		key = AgentKey.mint({
			id,
			hash: hash_secret!(secret),
			now,
			scope: spent.scope(),
		})
		FileSystem.create_agent_key!(agent, key) ? |fault| FileSystem(fault)
		Ok(SecretToken.of({ agent, secret }))
	}
}

## The agent's stream, for `acting`, an agent by its key whose scope reads.
begin_agent_stream! : {
	acting : SignedIn,
	directory : Directory,
	query : List(U8),
} => Try(Http.Response, _)
begin_agent_stream! = |
	{
		acting,
		directory,
		query,
	},
| {
	scope =
		match acting.credential() {
			ApiKey(held) => Ok(held)
			Session => Err(StreamNeedsKey)
		}?
	_ =
		match scope.read() {
			Everywhere => Ok({})
			Off => Err(StreamReadOff)
		}?
	start = AgentStream.start(query) ? |BadSince| BadStart
	agent = acting.user()
	backlog =
		match start {
			Live => []
			Since(since) => {
				conversations = load_readable_conversations!(directory, agent)
				AgentStream.backlog({ conversations, since })
			}
		}
	Ok(AgentStream.response({ agent: agent.id(), backlog }))
}

## Every conversation of every channel `agent` is a member of, each read
## and decoded. One that can't be read or decoded is left out: it fails
## only itself.
load_readable_conversations! : Directory,
Users.User => List(
	{
		key : ConversationKey,
		conversation : Conversation,
	},
)
load_readable_conversations! = |directory, agent| {
	var $read = []
	for channel in directory.channels().to_list().keep_if(|held| held.has_member(agent)) {
		topics = FileSystem.list_channel_topics!(channel.name()) ?? []
		for topic in topics {
			key = ConversationKey.of({ place: Place.channel(channel), topic })
			match FileSystem.read_transcript!(key) {
				Ok(File(utf8)) =>
					match Transcript.decode(key.topic(), utf8) {
						Ok(conversation) => {
							$read = $read.append({ key, conversation })
						}
						Err(_) => {}
					}
				Ok(NoFile) => {}
				Err(_) => {}
			}
		}
	}
	$read
}

## The hash of `secret`, as the host computes it.
hash_secret! : Secret => SecretHash
hash_secret! = |secret| SecretHash.of_digest(Host.sha256_of_bytes!(secret.bytes_to_hash()))

## A next number refused: the agent's folder is full, or the file system's
## fault.
full_or_fault : [Full, NotUtf8, PathRefused, Failed] -> Failure
full_or_fault = |why|
	match why {
		Full => Refused(Full)
		NotUtf8 => FileSystem(NotUtf8)
		PathRefused => FileSystem(PathRefused)
		Failed => FileSystem(Failed)
	}

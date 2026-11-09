## These are the tests of `Agents` and `Access`: a human makes, lists and
## manages only their own agents; an invite's form and a redemption's are
## read strictly; and a conversation is read and posted in only by its
## place's members, a key only as far as its scope reaches.
import Access
import AgentInvite
import AgentKey
import Agents
import ChannelName
import Channels
import Directory
import KeyScope
import Name
import Page
import Place
import Sample
import Secret
import SecretHash
import SecretToken
import SignedIn
import Timestamp
import UserId
import UserPair
import Users

AgentsSpec :: [].{}

## The sample directory with LC, Apoorva's agent (id 4), and the channel
## `team` holding Steve and CC, and `other` holding Apoorva and LC.
with_lc : Directory
with_lc = {
	apoorva = Sample.human("Apoorva")
	added = Sample.directory.add_agent({
		name: Sample.name("LC"),
		owner: apoorva,
	}) ?? crash "AgentsSpec: LC's name is free"
	team = ChannelName.from_str("team") ?? crash "AgentsSpec: a channel's name"
	other = ChannelName.from_str("other") ?? crash "AgentsSpec: a channel's name"
	with_team = (
		added.directory.create_channel({
			by: Sample.admin,
			name: team,
		}) ?? crash "AgentsSpec: team is free"
	).directory
	with_other = (
		with_team.create_channel({
			by: Sample.admin,
			name: other,
		}) ?? crash "AgentsSpec: other is free"
	).directory
	[
		(team, Sample.steve),
		(team, Sample.user("CC")),
		(other, Sample.user("Apoorva")),
		(other, added.user),
	].fold(
		with_other,
		|so_far, (channel, member)| so_far.add_member({
			by: Sample.admin,
			channel,
			member,
		}) ?? crash "AgentsSpec: a member joins",
	)
}

## The user of `with_lc` named `text`.
user_named : Str -> Users.User
user_named = |text|
	with_lc.users().to_list().find_first(|u| u.name().to_str() == text)
		?? crash "AgentsSpec: ${text} is a user"

# Each human's agents: Steve owns CC, Apoorva LC, and neither owns the other's.
expect Agents.agents_of(with_lc, Sample.human("Steve")).map(|u| u.name().to_str()) == ["CC"]
expect Agents.agents_of(with_lc, Sample.human("Apoorva")).map(|u| u.name().to_str()) == ["LC"]
# An agent its owner manages; another human's is not theirs; a human, or
# nobody, is no agent.
expect Agents.owned_agent(
	with_lc,
	{ owner: Sample.human("Steve"), agent: user_named("CC").id() },
) == Ok(user_named("CC"))
expect Agents.owned_agent(
	with_lc,
	{ owner: Sample.human("Steve"), agent: user_named("LC").id() },
) == Err(NotTheOwner)
expect Agents.owned_agent(
	with_lc,
	{ owner: Sample.human("Apoorva"), agent: user_named("CC").id() },
) == Err(NotTheOwner)
expect Agents.owned_agent(
	with_lc,
	{ owner: Sample.human("Steve"), agent: UserId.chat_owner },
) == Err(NoSuchAgent)
expect Agents.owned_agent(
	with_lc,
	{ owner: Sample.human("Steve"), agent: UserId.from_str("9") ?? crash "AgentsSpec: an id" },
) == Err(NoSuchAgent)

## What making an agent from the form `body` by `owner` gives: the new
## agent's name, id and owner, or why not.
new_agent_from : { owner : Str, body : Str } -> Try(Str, _)
new_agent_from = |{ owner, body }|
	Agents.make(with_lc, { owner: Sample.human(owner), body: body.to_utf8() }).map_ok(
		|addition| {
			user = addition.user
			match user.role() {
				Agent(role) => "${user.name().to_str()} ${user.id().to_str()} of ${role.owner.to_str()}"
				Human => "a human"
			}
		},
	)

# An agent new_agent_from: the next id, owned by whoever new_agent_from it.
expect new_agent_from({ owner: "Steve", body: "name=Helper+Bot" }) == Ok("Helper Bot 5 of 1")
expect new_agent_from({ owner: "Apoorva", body: "name=Helper" }) == Ok("Helper 5 of 2")
# A form at fault, a name that is no name, and one taken in any case, by a
# human, an agent or a channel.
expect new_agent_from({ owner: "Steve", body: "" }) == Err(BadForm("The form has no field `name`."))
expect new_agent_from({
	owner: "Steve",
	body: "name=a&name=b",
}) == Err(BadForm("The form has the field `name` more than once."))
expect new_agent_from({
	owner: "Steve",
	body: "name=%G0",
}) == Err(BadForm("The form's `name` holds a % that starts no two hex digits."))
expect [
	"name=R2D2",
	"name=",
	"name=+Bot",
].all(|body| new_agent_from({ owner: "Steve", body }) == Err(BadName))
expect [
	"name=cc",
	"name=STEVE",
	"name=Team",
].all(|body| new_agent_from({ owner: "Steve", body }) == Err(NameTaken))
# A full chat makes no agent.
expect
	Agents.make(
		Sample.directory_with_ids_left(0),
		{ owner: Sample.human("Steve"), body: "name=Bot".to_utf8() },
	).map_ok(|_| {})
		== Err(Full)

# An invite's scope: each field `everywhere` or `off`, everywhere when not
# sent; anything else refused, naming the field.
expect Agents.scope_from_form([]) == Ok(KeyScope.everywhere)
expect Agents.scope_from_form("read=off".to_utf8()) == Ok(
	KeyScope.of({ read: Off, post: Everywhere }),
)
expect Agents.scope_from_form("post=off&read=everywhere".to_utf8()) == Ok(
	KeyScope.of({ read: Everywhere, post: Off }),
)
expect
	Agents.scope_from_form("read=on".to_utf8())
		== Err(BadForm("The form's `read` is `everywhere` or `off`."))
expect
	Agents.scope_from_form("post=Off".to_utf8())
		== Err(BadForm("The form's `post` is `everywhere` or `off`."))
expect
	Agents.scope_from_form("read=off&read=off".to_utf8())
		== Err(BadForm("The form has the field `read` more than once."))

# A redemption's code: a token, or one refusal for anything else; a form
# with no code at fault.
expect
	Agents.code_from_form("code=3-${"0a".repeat(32)}".to_utf8()).map_ok(|token| token.to_str())
		== Ok("3-${"0a".repeat(32)}")
expect [
	"code=3-${"0a".repeat(31)}",
	"code=x",
	"code=",
].all(|body| Agents.code_from_form(body.to_utf8()).map_ok(|_| {}) == Err(CodeRefused))
expect
	Agents.code_from_form("token=1".to_utf8()).map_ok(|_| {})
		== Err(BadForm("The form has no field `code`."))

## A key and an invite of the tests', each numbered 1.
key_one : AgentKey
key_one = AgentKey.mint({
	id: AgentKey.Id.from_str("1") ?? crash "AgentsSpec: a number",
	hash: SecretHash.of_digest(List.repeat(1, 32)),
	now: Timestamp.at_second(0),
	scope: KeyScope.everywhere,
})

invite_one : AgentInvite
invite_one = AgentInvite.make({
	id: AgentInvite.Id.from_str("1") ?? crash "AgentsSpec: a number",
	hash: SecretHash.of_digest(List.repeat(2, 32)),
	now: Timestamp.at_second(0),
	scope: KeyScope.everywhere,
})

# A revoke finds its key or invite by number, or says there is none.
expect Agents.revoked_key([key_one], key_one.id()).map_ok(AgentKey.state) == Ok(Revoked)
expect Agents.revoked_key(
	[key_one],
	AgentKey.Id.from_str("2") ?? crash "AgentsSpec: a number",
) == Err(NoSuchKey)
expect Agents.revoked_key([], key_one.id()) == Err(NoSuchKey)
expect Agents.revoked_invite([invite_one], invite_one.id()).map_ok(AgentInvite.state) == Ok(Revoked)
expect Agents.revoked_invite(
	[invite_one],
	AgentInvite.Id.from_str("2") ?? crash "AgentsSpec: a number",
) == Err(NoSuchInvite)

# Each refusal's status: a key or another's agent 403, none 404, a form 400,
# a clash or an end already reached 409, a code 401.
expect
	[
		(ByApiKey, 403),
		(Agent(UserId.chat_owner), 403),
		(NotTheOwner, 403),
		(NoSuchAgent, 404),
		(NoSuchKey, 404),
		(NoSuchInvite, 404),
		(BadForm("x"), 400),
		(BadName, 400),
		(NameTaken, 409),
		(Full, 409),
		(AlreadyRevoked, 409),
		(Spent, 409),
		(CodeRefused, 401),
	].all(|(why, status)| Agents.refusal_notice(why).status == status)
expect Agents.refusal_notice(CodeRefused).said == "The invite code is not live."

## A place of `with_lc`: a channel by its name.
channel_place : Str -> Place
channel_place = |text| {
	name = ChannelName.from_str(text) ?? crash "AgentsSpec: a channel's name"
	Place.channel(with_lc.channels().channel(name) ?? crash "AgentsSpec: the channel exists")
}

## The DM of `with_lc` between the humans named.
dm_place : Str, Str -> Place
dm_place = |a, b| with_lc.place(
	Dm(UserPair.of({ a: user_named(a).id(), b: user_named(b).id() })),
) ?? crash "AgentsSpec: a DM of humans"

## CC signed in by a key of `scope`.
cc_by_key : KeyScope -> SignedIn
cc_by_key = |scope| {
	key = AgentKey.mint({
		id: key_one.id(),
		hash: SecretHash.of_digest(List.repeat(3, 32)),
		now: Timestamp.at_second(0),
		scope,
	})
	admitted = AgentKey.admit({
		user: user_named("CC"),
		keys: [key],
		hash: SecretHash.of_digest(List.repeat(3, 32)),
		now: Timestamp.at_second(0),
	}) ?? crash "AgentsSpec: CC's key admits"
	SignedIn.by_api_key(admitted)
}

## What `Access` says of `acting` doing `act` at `place`.
access : {
	acting : SignedIn,
	place : Place,
	act : Access.Act,
} -> Try({}, _)
access = |{ acting, place, act }| Access.check({ acting, place, directory: with_lc, act })

# A channel's members read and post, humans by session and agents by key;
# anyone else, the admin included, neither.
expect [Read, Post].all(
	|act| access({
		acting: SignedIn.dangerously_assume(Sample.steve),
		place: channel_place("team"),
		act,
	}) == Ok({}),
)
expect [Read, Post].all(
	|act| access({
		acting: cc_by_key(KeyScope.everywhere),
		place: channel_place("team"),
		act,
	}) == Ok({}),
)
expect [Read, Post].all(
	|act| access({
		acting: cc_by_key(KeyScope.everywhere),
		place: channel_place("other"),
		act,
	}) == Err(NotAMember),
)
expect [Read, Post].all(
	|act| access({
		acting: SignedIn.dangerously_assume(Sample.steve),
		place: channel_place("other"),
		act,
	}) == Err(NotAMember),
)
# A DM's humans read and post in it; another human, or an agent, neither.
expect [Read, Post].all(
	|act| access({
		acting: SignedIn.dangerously_assume(Sample.steve),
		place: dm_place("Steve", "Apoorva"),
		act,
	}) == Ok({}),
)
expect [Read, Post].all(
	|act| access({
		acting: SignedIn.dangerously_assume(Sample.steve),
		place: dm_place("Apoorva", "Apoorva"),
		act,
	}) == Err(NotAMember),
)
expect [Read, Post].all(
	|act| access({
		acting: cc_by_key(KeyScope.everywhere),
		place: dm_place("Steve", "Steve"),
		act,
	}) == Err(NotAMember),
)
# A key's scope takes away: read off reads nothing, post off posts nothing,
# each leaving the other; membership is asked first.
expect access({
	acting: cc_by_key(KeyScope.of({ read: Off, post: Everywhere })),
	place: channel_place("team"),
	act: Read,
}) == Err(ScopeOff)
expect access({
	acting: cc_by_key(KeyScope.of({ read: Off, post: Everywhere })),
	place: channel_place("team"),
	act: Post,
}) == Ok({})
expect access({
	acting: cc_by_key(KeyScope.of({ read: Everywhere, post: Off })),
	place: channel_place("team"),
	act: Post,
}) == Err(ScopeOff)
expect access({
	acting: cc_by_key(KeyScope.of({ read: Everywhere, post: Off })),
	place: channel_place("team"),
	act: Read,
}) == Ok({})
# The scope alone, as the agents' stream asks it before any channel: a
# session reaches every act, and a key only the acts its scope reaches.
expect {
	steve = SignedIn.dangerously_assume(Sample.steve)
	[Read, Post].all(|act| Access.check_credential({ acting: steve, act }) == Ok({}))
}
expect {
	read_off = KeyScope.of({ read: Off, post: Everywhere })
	post_off = KeyScope.of({ read: Everywhere, post: Off })
	[
		(KeyScope.everywhere, Read, Ok({})),
		(KeyScope.everywhere, Post, Ok({})),
		(read_off, Read, Err(ScopeOff)),
		(read_off, Post, Ok({})),
		(post_off, Read, Ok({})),
		(post_off, Post, Err(ScopeOff)),
	].all(
		|(scope, act, answer)| Access.check_credential({ acting: cc_by_key(scope), act }) == answer,
	)
}
expect access({
	acting: cc_by_key(KeyScope.of({ read: Off, post: Off })),
	place: channel_place("other"),
	act: Read,
}) == Err(NotAMember)
# Who hears a channel's messages on an agent's stream: its agent members
# alone; a DM's, nobody.
expect Access.agent_members({
	place: channel_place("team"),
	directory: with_lc,
}) == [user_named("CC").id()]
expect Access.agent_members({
	place: channel_place("other"),
	directory: with_lc,
}) == [user_named("LC").id()]
expect Access.agent_members({ place: dm_place("Steve", "Apoorva"), directory: with_lc }) == []
expect Access.members({
	place: channel_place("team"),
	directory: with_lc,
}) == [UserId.chat_owner, user_named("CC").id()]

# The agents page: each agent's invite button, each active key's and live
# invite's revoke button and no other, and an invite's code only when one
# was just made, in its own class.
expect {
	founded = Users.with_founder(Name.from_str("Steve") ?? crash "AgentsSpec: a name")
	steve = founded.to_list().first() ?? crash "AgentsSpec: Steve is the first user"
	owner = steve.as_human() ?? crash "AgentsSpec: Steve is a human"
	cc = (
		founded.add_agent({
			name: Name.from_str("CC") ?? crash "AgentsSpec: a name",
			owner,
		}) ?? crash "AgentsSpec: CC joins"
	).user
	hash = SecretHash.of_digest(List.repeat(1, 32))
	active = AgentKey.mint({
		id: AgentKey.Id.from_str("1") ?? crash "AgentsSpec: a number",
		hash,
		now: Timestamp.at_second(0),
		scope: KeyScope.everywhere,
	})
	revoked = AgentKey.mint({
		id: AgentKey.Id.from_str("2") ?? crash "AgentsSpec: a number",
		hash,
		now: Timestamp.at_second(0),
		scope: KeyScope.everywhere,
	}).revoke() ?? crash "AgentsSpec: a key revokes"
	live = AgentInvite.make({
		id: AgentInvite.Id.from_str("1") ?? crash "AgentsSpec: a number",
		hash,
		now: Timestamp.at_second(0),
		scope: KeyScope.everywhere,
	})
	spent = AgentInvite.redeem({
		invites: [
			AgentInvite.make({
				id: AgentInvite.Id.from_str("2") ?? crash "AgentsSpec: a number",
				hash,
				now: Timestamp.at_second(0),
				scope: KeyScope.everywhere,
			}),
		],
		hash,
		now: Timestamp.at_second(0),
	}) ?? crash "AgentsSpec: an invite redeems"
	summary = {
		agent: cc,
		keys: [active, revoked],
		invites: [live, spent],
	}
	plain = Str.from_utf8_lossy(
		Page.agents({
			viewer: SignedIn.dangerously_assume(steve),
			agents: [summary],
			shown: NoCode,
			github_link: LinkNotOffered,
		}).to_utf8(),
	)
	code = SecretToken.of({
		user: cc.id(),
		secret: Secret.from_random_bytes(List.repeat(0xab, 32)),
	})
	showing = Str.from_utf8_lossy(
		Page.agents({
			viewer: SignedIn.dangerously_assume(steve),
			agents: [summary],
			shown: Code({ agent: cc, code }),
			github_link: LinkOffered,
		}).to_utf8(),
	)
	!plain.contains("/login/github/link")
		and showing.contains("<form method=\"post\" action=\"/login/github/link\"><button>Link GitHub</button></form>")
		and plain.contains("<form method=\"post\" action=\"/agents\"><textarea name=\"name\" required></textarea>")
		and plain.contains("<form method=\"post\" action=\"/agents/2/invites\"><button>Invite CC</button></form>")
		and plain.contains("action=\"/agents/2/keys/1/revoke\"")
		and !plain.contains("action=\"/agents/2/keys/2/revoke\"")
		and plain.contains("action=\"/agents/2/invites/1/revoke\"")
		and !plain.contains("action=\"/agents/2/invites/2/revoke\"")
		and plain.contains("<p>Key 2: revoked, expires 1971-01-01T00:00:00Z, read everywhere, post everywhere.</p>")
		and plain.contains("<p>Invite 2: redeemed, expires 1970-01-01T00:10:00Z.</p>")
		and !plain.contains("invite-code")
		and showing.contains("<p class=\"invite-code\">2-${"ab".repeat(32)}</p>")
}

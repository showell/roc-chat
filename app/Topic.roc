## **A TOPIC, AND WHO MAY READ AND POST IN IT** (the channels design,
## Steve's decisions of 2026-10-31): a topic is its channel, its name
## (TopicName, scoped to that channel), and its kind, fixed when it is
## made:
## - **a human topic**, open to the channel's members, to read, post and
##   make one; no agent or bot reaches it, its owner a member or not;
## - **an agent topic**, naming one or more agents (a bot counts as one),
##   open only to them and to the humans they answer to, members or not;
##   no other member reaches it. A member makes one naming only agents
##   that answer to them ("no, at first": Steve), so a member never pulls
##   another's agent in; adding an agent is a new topic.
##
## **A VERDICT, ITS REFUSAL BY NAME**: `read` and `post` decide in one
## order, the same for both but the key's part they ask (a key's read
## reaches what it reads, its post what it posts): the topic is the
## channel's; someone is signed in; their account is the one their
## credential was minted for; the credential reaches the topic; then the
## kind's rule. An admin is no exception: an admin reads a human topic
## only as a member, and an agent topic only as an owner of one of its
## agents.
##
## **BOUND TO THE ACCOUNTS**: an agent named in a topic is bound to its
## account when the topic is made (Principal.Bound), and counts, with its
## owner beside it, only while that binding holds; a channel's member, as
## Channel.roc binds them. Pure.
import Access
import Channel
import ChannelCast
import ChannelName
import Principal
import TopicCodec
import TopicName

Topic :: {
	at : Topic.At,

	## An agent topic's agents, never none: `make`, the one way in,
	## refuses an agent topic naming none.
	kind : [Human, Agents(List(Principal.Bound))],
}.{

	## **WHERE A TOPIC IS**: its channel, then its name in it. The pair is
	## the topic's whole address, the id a key's scope names, and `==`
	## compares both names caselessly, so two channels' `ChitChat`s are two
	## topics, and `chitchat` is `ChitChat` in one channel.
	At : { channel : ChannelName, topic : TopicName }

	## Why a read or a post is refused. **ONE ALIAS ON PURPOSE**: `read`
	## and `post` share it, and its tags' reasons are said once.
	Refusal : [
		## The channel handed in is not the topic's own.
		OtherChannel,

		## Nobody signed in asked.
		SignedOut,

		## The asker's account is not the one their credential was minted
		## for (retired, or made again).
		NoSuchPrincipal,

		## A key whose read (or post) does not reach the topic.
		OutOfScope,

		## A human topic, and a human not in the channel now.
		NotAMember,

		## A human topic, and an agent or a bot asked.
		NotForAgents,

		## An agent topic, and neither one of its agents nor a human one of
		## them answers to.
		NotInTopic,
	]

	## A read's or a post's answer.
	Verdict : [Permitted, Refused(Topic.Refusal)]

	## **A MEMBER MAKES A TOPIC** in `channel`, named `name`, of `kind`.
	## Refused, in this order: nobody signed in (`SignedOut`); an account
	## gone (`NoSuchPrincipal`); an agent or a bot asking (`NotAHuman`:
	## topics are members' to make); a name the rule refuses
	## (`NotATopicName`); a key whose post does not reach the new topic
	## (`OutOfScope`); a human not in the channel (`NotAMember`); a name a
	## topic of this channel has, in any case (`Taken`; another channel's
	## topic of that name is no matter). Then an agent topic's agents: none
	## (`NoAgents`), and each one named twice (`NamedTwice`), a human's id
	## (`NotAnAgent`), no one account holding it (`NoAccount`), or answering
	## to someone else (`NotYours`).
	make : {
		by : Access.Viewer(Topic.At),
		channel : Channel,
		name : Str,
		kind : [Human, Agents(List(Principal.Id))],
		topics : List(Topic),
		accounts : List(Principal),
	} -> Try(Topic, _)
	make = |
		{
			by,
			channel,
			name,
			kind,
			topics,
			accounts,
		},
	| {
		maker = signed_in(by, accounts)?
		human =
			match maker.id {
				Human(h) => Ok(h)
				Agent(_) | Bot(_) => Err(NotAHuman)
			}?
		at = { channel: channel.name(), topic: TopicName.from_str(name)? }
		match by.reach(Post, at) {
			Reaches => Ok({})
			OutOfScope => Err(OutOfScope)
			SignedOut => crash "Topic.make: a signed-in viewer is not signed out"
		}?
		match channel.membership({ who: maker, accounts }) {
			Member => Ok({})
			NotAMember => Err(NotAMember)
		}?
		if topics.any(|t| t.at() == at) {
			Err(Taken)
		} else {
			match kind {
				Human => Ok(Topic.({ at, kind: Human }))
				Agents([]) => Err(NoAgents)
				Agents(ids) => {
					bound = ids.fold_try(
						[],
						|kept, id| {
							if kept.any(|b| b.id == id) {
								Err(NamedTwice(id))
							} else {
								Ok(kept.append(agent_bound(accounts, { id, owner: human })?))
							}
						},
					)?
					Ok(Topic.({ at, kind: Agents(bound) }))
				}
			}
		}
	}

	## **A TOPIC BACK FROM THE STORE**: the one way in besides `make`, from
	## a line TopicCodec decoded, every field checked, in `channel` (the
	## channel loaded, whose folder the line is in).
	load : ChannelName, TopicCodec.Line -> Topic
	load = |channel, line| {
		f = line.fields()
		Topic.({ at: { channel, topic: f.name }, kind: f.kind })
	}

	## The topic's fields, to store (TopicCodec.encode); its channel is
	## where it is stored.
	fields : Topic -> TopicCodec.Fields
	fields = |Topic.(t)| { name: t.at.topic, kind: t.kind }

	## Where the topic is.
	at : Topic -> Topic.At
	at = |Topic.(t)| t.at

	## Its kind.
	kind : Topic -> [Human, Agents]
	kind = |Topic.(t)|
		match t.kind {
			Human => Human
			Agents(_) => Agents
		}

	## **AN AGENT TOPIC'S AGENTS NOW**: those named whose binding holds
	## among `accounts`; none for a human topic.
	agents : Topic, List(Principal) -> List(Principal.Bound)
	agents = |Topic.(t), accounts|
		match t.kind {
			Human => []
			Agents(named) => named.keep_if(|b| Principal.holds(accounts, b).is_ok())
		}

	## **THE ONE TOPIC AT `wanted` AMONG `topics`**: found only when exactly
	## one is there, so a lookup never takes "the first match".
	find : List(Topic), Topic.At -> Try(Topic, [NoSuchTopic, Duplicated])
	find = |topics, wanted|
		match topics.keep_if(|t| t.at() == wanted) {
			[only] => Ok(only)
			[] => Err(NoSuchTopic)
			_ => Err(Duplicated)
		}

	## **MAY THIS VIEWER READ THE TOPIC, NOW?**
	read : Topic,
	{
		viewer : Access.Viewer(Topic.At),
		channel : Channel,
		accounts : List(Principal),
	} -> Topic.Verdict
	read = |topic, request| decided(
		topic,
		Read,
		request,
	)

	## **MAY THIS VIEWER POST IN THE TOPIC, NOW?** As `read`, by the
	## credential's post: whoever reads a topic posts in it.
	post : Topic,
	{
		viewer : Access.Viewer(Topic.At),
		channel : Channel,
		accounts : List(Principal),
	} -> Topic.Verdict
	post = |topic, request| decided(
		topic,
		Post,
		request,
	)

	is_eq : _
}

## The verdict, for a read or a post, in the order the module's header says.
decided : Topic,
[Read, Post],
{
	viewer : Access.Viewer(Topic.At),
	channel : Channel,
	accounts : List(Principal),
} -> Topic.Verdict
decided = |
	topic,
	act,
	request,
|
	match allowed(
		topic,
		act,
		request,
	) {
		Ok({}) => Permitted
		Err(why) => Refused(why)
	}

## `decided`'s checks, each refusal by its name.
allowed : Topic,
[Read, Post],
{
	viewer : Access.Viewer(Topic.At),
	channel : Channel,
	accounts : List(Principal),
} -> Try({}, _)
allowed = |
	topic,
	act,
	{
		viewer,
		channel,
		accounts,
	},
| {
	at = topic.at()
	if channel.name() != at.channel {
		Err(OtherChannel)
	} else {
		who = signed_in(viewer, accounts)?
		match viewer.reach(act, at) {
			Reaches => Ok({})
			OutOfScope => Err(OutOfScope)
			SignedOut => crash "Topic.allowed: a signed-in viewer is not signed out"
		}?
		match (topic.kind(), who.id) {
			(Human, Human(_)) =>
				match channel.membership({ who, accounts }) {
					Member => Ok({})
					NotAMember => Err(NotAMember)
				}
			(Human, Agent(_)) | (Human, Bot(_)) => Err(NotForAgents)
			(Agents, _) => {
				named = topic.agents(accounts)
				is_owner =
					match who.id {
						Human(h) => named.any(
							|b| Principal.holds(
								accounts,
								b,
							).map_ok(|p| p.answers_to()) == Ok(h),
						)
						Agent(_) | Bot(_) => Bool.False
					}
				if (named.contains(who) or is_owner) Ok({}) else Err(NotInTopic)
			}
		}
	}
}

## **THE ASKER, SIGNED IN, THEIR ACCOUNT THE ONE THEIR CREDENTIAL WAS MINTED
## FOR**, or why not.
signed_in : Access.Viewer(id), List(Principal) -> Try(Principal.Bound, [SignedOut, NoSuchPrincipal])
signed_in = |viewer, accounts|
	match viewer.who() {
		SignedOut => Err(SignedOut)
		Session(b) | Key(b) =>
			match Principal.holds(accounts, b) {
				Ok(_) => Ok(b)
				Err(NoSuchPrincipal) => Err(NoSuchPrincipal)
			}
	}

## An agent's or a bot's binding to its one account, answering to `owner`,
## to name it in a topic.
agent_bound : List(Principal),
{ id : Principal.Id, owner : Principal.GitHubId } -> Try(
	Principal.Bound,
	[
		NotAnAgent(Principal.Id),
		NoAccount(Principal.Id),
		NotYours(Principal.Id),
	],
)
agent_bound = |accounts, { id, owner }|
	match id {
		Human(_) => Err(NotAnAgent(id))
		Agent(_) | Bot(_) =>
			match Principal.find(accounts, id) {
				Err(_) => Err(NoAccount(id))
				Ok(p) =>
					if p.answers_to() != owner {
						Err(NotYours(id))
					} else {
						match Principal.bind(accounts, id) {
							Ok(b) => Ok(b)
							Err(_) => Err(NoAccount(id))
						}
					}
			}
	}

# ── tests
## A test's channel, made by Steve, the admin.
channel_of : Str, List(ChannelCast.Who) -> Channel
channel_of = |name, members|
	match Channel.make({
		by: ChannelCast.viewer(Steve),
		name,
		members: members.map(ChannelCast.id),
		channels: [],
		accounts: ChannelCast.accounts,
	}) {
		Ok(c) => c
		Err(_) => crash "channel_of: a test's channel is made"
	}

## Steve's example: Steve, Damian and Apoorva.
cobblestone : Channel
cobblestone = channel_of(
	"Cobblestone",
	[
		Steve,
		Damian,
		Apoorva,
	],
)

## Another channel, of Zed and Apoorva, with its own `ChitChat`.
general : Channel
general = channel_of("general", [Zed, Apoorva])

## A topic `by` makes in `channel` beside `topics`, or the refusal.
make_in : Channel,
{
	by : ChannelCast.Who,
	name : Str,
	kind : [Human, Agents(List(ChannelCast.Who))],
	topics : List(Topic),
} -> Try(Topic, _)
make_in = |
	channel,
	{
		by,
		name,
		kind,
		topics,
	},
|
	Topic.make({
		by: ChannelCast.viewer(by),
		channel,
		name,
		kind: match kind {
			Human => Human
			Agents(who) => Agents(who.map(ChannelCast.id))
		},
		topics,
		accounts: ChannelCast.accounts,
	})

## A topic made, in a test where it is.
made : Try(Topic, _) -> Topic
made = |tried|
	match tried {
		Ok(t) => t
		Err(_) => crash "made: a test's topic is made"
	}

## Cobblestone's human topic.
chitchat : Topic
chitchat = made(
	make_in(
		cobblestone,
		{
			by: Steve,
			name: "ChitChat",
			kind: Human,
			topics: [],
		},
	),
)

## Steve's agent topic, with Cc and Lc.
agents : Topic
agents = made(
	make_in(
		cobblestone,
		{
			by: Steve,
			name: "agents",
			kind: Agents([Cc, Lc]),
			topics: [chitchat],
		},
	),
)

## Damian's agent topic, with his own agent.
damians : Topic
damians = made(
	make_in(
		cobblestone,
		{
			by: Damian,
			name: "damians",
			kind: Agents([DamianAgent]),
			topics: [chitchat, agents],
		},
	),
)

## Steve's bot's topic: a bot follows agents.
bots : Topic
bots = made(
	make_in(
		cobblestone,
		{
			by: Steve,
			name: "bots",
			kind: Agents([SteveBot]),
			topics: [
				chitchat,
				agents,
				damians,
			],
		},
	),
)

## general's own `ChitChat`: the same name, another channel, another topic.
general_chitchat : Topic
general_chitchat = made(
	make_in(
		general,
		{
			by: Zed,
			name: "ChitChat",
			kind: Human,
			topics: [
				chitchat,
				agents,
				damians,
				bots,
			],
		},
	),
)

## Cobblestone's topics.
cobblestones : List(Topic)
cobblestones = [
	chitchat,
	agents,
	damians,
	bots,
]

## The topic's channel, of the two.
home : Topic -> Channel
home = |topic| if (topic.at().channel == general.name()) general else cobblestone

## `who` reads `topic`, by the viewer the cast mints, among the whole cast.
reads : Topic, ChannelCast.Who -> Topic.Verdict
reads = |topic, who| topic.read({
	viewer: ChannelCast.viewer(who),
	channel: home(topic),
	accounts: ChannelCast.accounts,
})

## `who` posts in `topic`, likewise.
posts : Topic, ChannelCast.Who -> Topic.Verdict
posts = |topic, who| topic.post({
	viewer: ChannelCast.viewer(who),
	channel: home(topic),
	accounts: ChannelCast.accounts,
})

## Where `channel`'s topic `name` is.
at_of : Str, Str -> Topic.At
at_of = |channel, name|
	match (ChannelName.from_str(channel), TopicName.from_str(name)) {
		(Ok(c), Ok(t)) => { channel: c, topic: t }
		_ => crash "at_of: a test's names are names"
	}

# Made: where each is, and its kind.
expect chitchat.at() == at_of("Cobblestone", "ChitChat")
expect chitchat.at().topic.to_str() == "ChitChat"
expect chitchat.kind() == Human
expect agents.kind() == Agents
expect agents.agents(ChannelCast.accounts) == [ChannelCast.bound(Cc), ChannelCast.bound(Lc)]
expect chitchat.agents(ChannelCast.accounts) == []
# Two channels' ChitChats are two topics, at two places.
expect general_chitchat.at() == at_of("general", "chitchat")
expect general_chitchat.at() != chitchat.at()
expect general_chitchat != chitchat

# ── THE READ TABLE: every viewer against every topic.
# Cobblestone's human topic: its members, nobody else, no agent.
expect reads(chitchat, Out) == Refused(SignedOut)
expect reads(chitchat, Steve) == Permitted
expect reads(chitchat, Damian) == Permitted
expect reads(chitchat, Apoorva) == Permitted
expect reads(chitchat, Zed) == Refused(NotAMember)
expect reads(chitchat, Root) == Refused(NotAMember)
expect reads(chitchat, Cc) == Refused(NotForAgents)
expect reads(chitchat, Lc) == Refused(NotForAgents)
expect reads(chitchat, SteveBot) == Refused(NotForAgents)
expect reads(chitchat, DamianAgent) == Refused(NotForAgents)
expect reads(chitchat, ZedAgent) == Refused(NotForAgents)
# Steve's agent topic: Cc, Lc, and Steve; no other member, no admin.
expect reads(agents, Out) == Refused(SignedOut)
expect reads(agents, Steve) == Permitted
expect reads(agents, Damian) == Refused(NotInTopic)
expect reads(agents, Apoorva) == Refused(NotInTopic)
expect reads(agents, Zed) == Refused(NotInTopic)
expect reads(agents, Root) == Refused(NotInTopic)
expect reads(agents, Cc) == Permitted
expect reads(agents, Lc) == Permitted
expect reads(agents, SteveBot) == Refused(NotInTopic)
expect reads(agents, DamianAgent) == Refused(NotInTopic)
expect reads(agents, ZedAgent) == Refused(NotInTopic)
# Damian's agent topic: his agent and Damian; not Steve, admin and member.
expect reads(damians, Steve) == Refused(NotInTopic)
expect reads(damians, Damian) == Permitted
expect reads(damians, Apoorva) == Refused(NotInTopic)
expect reads(damians, DamianAgent) == Permitted
expect reads(damians, Cc) == Refused(NotInTopic)
# Steve's bot's topic: the bot and Steve; not his agents.
expect reads(bots, Steve) == Permitted
expect reads(bots, SteveBot) == Permitted
expect reads(bots, Cc) == Refused(NotInTopic)
expect reads(bots, Damian) == Refused(NotInTopic)
# general's ChitChat: its own members, not Cobblestone's.
expect reads(general_chitchat, Zed) == Permitted
expect reads(general_chitchat, Apoorva) == Permitted
expect reads(general_chitchat, Steve) == Refused(NotAMember)
expect reads(general_chitchat, Damian) == Refused(NotAMember)
expect reads(general_chitchat, ZedAgent) == Refused(NotForAgents)

# ── THE POST TABLE: whoever reads posts, by the same rule.
expect posts(chitchat, Out) == Refused(SignedOut)
expect posts(chitchat, Damian) == Permitted
expect posts(chitchat, Zed) == Refused(NotAMember)
expect posts(chitchat, Cc) == Refused(NotForAgents)
expect posts(agents, Steve) == Permitted
expect posts(agents, Cc) == Permitted
expect posts(agents, Damian) == Refused(NotInTopic)
expect posts(agents, DamianAgent) == Refused(NotInTopic)
expect posts(damians, Damian) == Permitted
expect posts(damians, DamianAgent) == Permitted
expect posts(damians, Steve) == Refused(NotInTopic)
expect posts(bots, SteveBot) == Permitted
expect posts(general_chitchat, Apoorva) == Permitted
expect posts(general_chitchat, Steve) == Refused(NotAMember)

# The channel handed in must be the topic's own.
expect chitchat.read({
	viewer: ChannelCast.viewer(Zed),
	channel: general,
	accounts: ChannelCast.accounts,
}) == Refused(OtherChannel)
expect general_chitchat.post({
	viewer: ChannelCast.viewer(Steve),
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Refused(OtherChannel)

# ── A KEY'S SCOPE: its read and its post, each where it reaches, by the
# topic's place (both names, any case); a reach is no right the rule denies.
cc_reads_agents : Access.Viewer(Topic.At)
cc_reads_agents = ChannelCast.keyed(
	Cc,
	{
		read: On(Only([at_of("cobblestone", "AGENTS")])),
		post: Off,
		admin: Off,
	},
)

steve_reads_chitchat : Access.Viewer(Topic.At)
steve_reads_chitchat = ChannelCast.keyed(
	Steve,
	{
		read: On(Only([chitchat.at()])),
		post: On(Only([chitchat.at()])),
		admin: Off,
	},
)

expect agents.read({
	viewer: cc_reads_agents,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Permitted
expect agents.post({
	viewer: cc_reads_agents,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Refused(OutOfScope)
expect damians.read({
	viewer: cc_reads_agents,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Refused(OutOfScope)
expect chitchat.read({
	viewer: steve_reads_chitchat,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Permitted
expect chitchat.post({
	viewer: steve_reads_chitchat,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Permitted
# The same name in another channel is another place: out of the key's reach.
expect general_chitchat.read({
	viewer: steve_reads_chitchat,
	channel: general,
	accounts: ChannelCast.accounts,
}) == Refused(OutOfScope)
expect agents.read({
	viewer: steve_reads_chitchat,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Refused(OutOfScope)
# Steve's own key, reaching everywhere, reads as Steve does.
expect agents.read({
	viewer: ChannelCast.keyed(
		Steve,
		{
			read: On(Everywhere),
			post: Off,
			admin: Off,
		},
	),
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Permitted
expect damians.read({
	viewer: ChannelCast.keyed(
		Steve,
		{
			read: On(Everywhere),
			post: Off,
			admin: Off,
		},
	),
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Refused(NotInTopic)

# ── RETIRED, OR MADE AGAIN: a viewer whose account is not the one it was
# minted for reads nothing; a topic's agent counts only while it stands.
expect chitchat.read({
	viewer: ChannelCast.viewer(Damian),
	channel: cobblestone,
	accounts: ChannelCast.without(Damian),
}) == Refused(NoSuchPrincipal)
expect chitchat.read({
	viewer: ChannelCast.viewer(Damian),
	channel: cobblestone,
	accounts: ChannelCast.damian_again,
}) == Refused(NoSuchPrincipal)
expect agents.read({
	viewer: ChannelCast.viewer(Cc),
	channel: cobblestone,
	accounts: ChannelCast.without(Cc),
}) == Refused(NoSuchPrincipal)
# Cc retired: Steve still reads by Lc; Lc still reads.
expect agents.read({
	viewer: ChannelCast.viewer(Steve),
	channel: cobblestone,
	accounts: ChannelCast.without(Cc),
}) == Permitted
expect agents.agents(ChannelCast.without(Cc)) == [ChannelCast.bound(Lc)]
# Damian's only agent retired: his topic is nobody's.
expect damians.read({
	viewer: ChannelCast.viewer(Damian),
	channel: cobblestone,
	accounts: ChannelCast.without(DamianAgent),
}) == Refused(NotInTopic)

# ── A MEMBER REMOVED: out of the human topics; an agent topic of their
# own agent stays theirs, member or not.
without_damian : Channel
without_damian =
	match cobblestone.remove({
		by: ChannelCast.viewer(Steve),
		member: ChannelCast.id(Damian),
		accounts: ChannelCast.accounts,
	}) {
		Ok(c) => c
		Err(_) => crash "without_damian: Steve removes Damian"
	}

expect chitchat.read({
	viewer: ChannelCast.viewer(Damian),
	channel: without_damian,
	accounts: ChannelCast.accounts,
}) == Refused(NotAMember)
expect damians.read({
	viewer: ChannelCast.viewer(Damian),
	channel: without_damian,
	accounts: ChannelCast.accounts,
}) == Permitted

# ── MAKING A TOPIC
expect make_in(
	cobblestone,
	{
		by: Apoorva,
		name: "Plans",
		kind: Human,
		topics: cobblestones,
	},
).map_ok(|t| t.at()) == Ok(at_of("Cobblestone", "Plans"))
expect make_in(
	cobblestone,
	{
		by: Steve,
		name: "pair",
		kind: Agents([Cc, SteveBot]),
		topics: cobblestones,
	},
).map_ok(|t| t.agents(ChannelCast.accounts)) == Ok([
	ChannelCast.bound(Cc),
	ChannelCast.bound(SteveBot),
])
expect make_in(
	cobblestone,
	{
		by: Out,
		name: "Plans",
		kind: Human,
		topics: [],
	},
) == Err(SignedOut)
expect make_in(
	cobblestone,
	{
		by: Cc,
		name: "Plans",
		kind: Human,
		topics: [],
	},
) == Err(NotAHuman)
expect make_in(
	cobblestone,
	{
		by: SteveBot,
		name: "Plans",
		kind: Human,
		topics: [],
	},
) == Err(NotAHuman)
expect make_in(
	cobblestone,
	{
		by: Steve,
		name: "a b",
		kind: Human,
		topics: [],
	},
) == Err(NotATopicName)
expect make_in(
	cobblestone,
	{
		by: Steve,
		name: "a--b",
		kind: Human,
		topics: [],
	},
) == Err(NotATopicName)
# A non-member makes none, an admin no more than anyone.
expect make_in(
	cobblestone,
	{
		by: Zed,
		name: "Plans",
		kind: Human,
		topics: [],
	},
) == Err(NotAMember)
expect make_in(
	cobblestone,
	{
		by: Root,
		name: "Plans",
		kind: Human,
		topics: [],
	},
) == Err(NotAMember)
expect make_in(
	cobblestone,
	{
		by: Zed,
		name: "mine",
		kind: Agents([ZedAgent]),
		topics: [],
	},
) == Err(NotAMember)
# Taken in this channel, in any case; another channel's name is no matter.
expect make_in(
	cobblestone,
	{
		by: Damian,
		name: "CHITCHAT",
		kind: Human,
		topics: cobblestones,
	},
) == Err(Taken)
expect make_in(
	cobblestone,
	{
		by: Damian,
		name: "Agents",
		kind: Agents([DamianAgent]),
		topics: cobblestones,
	},
) == Err(Taken)
expect make_in(
	general,
	{
		by: Apoorva,
		name: "chitchat",
		kind: Human,
		topics: cobblestones,
	},
).is_ok()
expect make_in(
	general,
	{
		by: Apoorva,
		name: "chitchat",
		kind: Human,
		topics: [general_chitchat],
	},
) == Err(Taken)
# An agent topic's agents: some, each once, each an agent, the maker's own.
expect make_in(
	cobblestone,
	{
		by: Steve,
		name: "none",
		kind: Agents([]),
		topics: [],
	},
) == Err(NoAgents)
expect make_in(
	cobblestone,
	{
		by: Steve,
		name: "twice",
		kind: Agents([
			Cc,
			Lc,
			Cc,
		]),
		topics: [],
	},
) == Err(NamedTwice(ChannelCast.id(Cc)))
expect make_in(
	cobblestone,
	{
		by: Steve,
		name: "human",
		kind: Agents([Damian]),
		topics: [],
	},
) == Err(NotAnAgent(ChannelCast.id(Damian)))
expect make_in(
	cobblestone,
	{
		by: Steve,
		name: "theirs",
		kind: Agents([DamianAgent]),
		topics: [],
	},
) == Err(NotYours(ChannelCast.id(DamianAgent)))
expect make_in(
	cobblestone,
	{
		by: Steve,
		name: "theirs",
		kind: Agents([Cc, DamianAgent]),
		topics: [],
	},
) == Err(NotYours(ChannelCast.id(DamianAgent)))
expect make_in(
	cobblestone,
	{
		by: Damian,
		name: "steal",
		kind: Agents([Cc]),
		topics: [],
	},
) == Err(NotYours(ChannelCast.id(Cc)))
expect Topic.make({
	by: ChannelCast.viewer(Steve),
	channel: cobblestone,
	name: "gone",
	kind: Agents([ChannelCast.id(Cc)]),
	topics: [],
	accounts: ChannelCast.without(Cc),
}) == Err(NoAccount(ChannelCast.id(Cc)))
# A key makes one only where its post reaches the new topic.
expect Topic.make({
	by: ChannelCast.keyed(
		Steve,
		{
			read: On(Everywhere),
			post: On(Only([chitchat.at()])),
			admin: Off,
		},
	),
	channel: cobblestone,
	name: "Plans",
	kind: Human,
	topics: [],
	accounts: ChannelCast.accounts,
}) == Err(OutOfScope)
expect Topic.make({
	by: ChannelCast.keyed(
		Steve,
		{
			read: Off,
			post: On(Everywhere),
			admin: Off,
		},
	),
	channel: cobblestone,
	name: "Plans",
	kind: Human,
	topics: [],
	accounts: ChannelCast.accounts,
}).is_ok()
# Damian made again, by his old session: refused.
expect Topic.make({
	by: ChannelCast.viewer(Damian),
	channel: cobblestone,
	name: "Plans",
	kind: Human,
	topics: [],
	accounts: ChannelCast.damian_again,
}) == Err(NoSuchPrincipal)

# ── FINDING ONE: by both names, any case, exactly one.
expect Topic.find(
	cobblestones.append(general_chitchat),
	at_of("COBBLESTONE", "chitchat"),
) == Ok(chitchat)
expect Topic.find(
	cobblestones.append(general_chitchat),
	at_of("General", "CHITCHAT"),
) == Ok(general_chitchat)
expect Topic.find(cobblestones, at_of("general", "ChitChat")) == Err(NoSuchTopic)
expect Topic.find(cobblestones, at_of("Cobblestone", "Plans")) == Err(NoSuchTopic)
expect Topic.find([chitchat, chitchat], chitchat.at()) == Err(Duplicated)

# ── STORED AND LOADED: the topic it was, its kind and its agents' bindings.
## `topic` through its line and back, in its own channel.
stored_and_loaded : Topic -> Try(Topic, _)
stored_and_loaded = |topic| TopicCodec.decode(TopicCodec.encode(topic.fields())).map_ok(|line| Topic.load(topic.at().channel, line))

expect
	cobblestones.append(general_chitchat).all(|t| stored_and_loaded(t) == Ok(t))
expect stored_and_loaded(chitchat).map_ok(|t| t.at().topic.to_str()) == Ok("ChitChat")
expect stored_and_loaded(agents).map_ok(|t| t.agents(ChannelCast.accounts)) == Ok([ChannelCast.bound(Cc), ChannelCast.bound(Lc)])

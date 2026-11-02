## **A TOPIC, AND WHO MAY READ AND POST IN IT** (the channels design,
## Steve's decisions of 2026-10-31 and 2026-11-01): a topic is its channel
## and its name (TopicName, scoped to that channel). **WHO TAKES PART IS
## THE CHANNEL'S**: every member of the channel, human, agent or bot,
## reads, posts in and makes every one of its topics, and nobody else does.
##
## **A VERDICT, ITS REFUSAL BY NAME**: `read` and `post` decide in one
## order, the same for both but the key's part they ask (a key's read
## reaches what it reads, its post what it posts): the topic is the
## channel's; someone is signed in; their account is the one their
## credential was minted for; the credential reaches the topic; then
## membership. An admin is no exception: an admin reads a topic only as a
## member. Pure.
import Access
import Channel
import ChannelCast
import ChannelName
import Principal
import Stored
import TopicName

Topic :: {
	at : Topic.At,
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

		## Someone not in the channel now.
		NotAMember,
	]

	## A read's or a post's answer.
	Verdict : [Permitted, Refused(Topic.Refusal)]

	## **PROOF THAT A VIEWER MAY READ A TOPIC, NOW**: made by `readable`
	## alone, when `read` permits, so the store's reads and writes of a
	## topic's own files that take one (its uploads, Store.load_upload!) are
	## reached by nothing that skipped the rule. Opaque.
	Readable :: Topic.At.{

		## The topic it proves the read of.
		at : Topic.Readable -> Topic.At
		at = |Topic.Readable.(place)| place
	}

	## **MAY THIS VIEWER READ THE TOPIC, NOW? AND THE PROOF IF SO**: as
	## `read`, its refusal by name.
	readable : Topic,
	{
		viewer : Access.Viewer,
		channel : Channel,
		accounts : List(Principal),
	} -> Try(Topic.Readable, _)
	readable = |topic, request|
		allowed(
			topic,
			Read,
			request,
		).map_ok(|{}| Topic.Readable.(topic.at()))

	## **A MEMBER MAKES A TOPIC** in `channel`, named `name`. Refused, in
	## this order: nobody signed in (`SignedOut`); an account gone
	## (`NoSuchPrincipal`); a name the rule refuses (`NotATopicName`); a key
	## whose post does not reach the new topic (`OutOfScope`); someone not
	## in the channel (`NotAMember`); a name a topic of this channel has, in
	## any case (`Taken`; another channel's topic of that name is no matter).
	make : {
		by : Access.Viewer,
		channel : Channel,
		name : Str,
		topics : List(Topic),
		accounts : List(Principal),
	} -> Try(Topic, _)
	make = |
		{
			by,
			channel,
			name,
			topics,
			accounts,
		},
	| {
		maker = signed_in(by, accounts)?
		at = { channel: channel.name(), topic: TopicName.from_str(name)? }
		match by.reach(Post) {
			Reaches => Ok({})
			OutOfScope => Err(OutOfScope)
			SignedOut => crash "Topic.make: a signed-in viewer is not signed out"
		}?
		match channel.membership({ who: maker, accounts }) {
			Member => Ok({})
			NotAMember => Err(NotAMember)
		}?
		if (topics.any(|t| t.at() == at)) Err(Taken) else Ok(Topic.({ at: at }))
	}

	## **A TOPIC'S LINE** (ChannelLayout's `.../topic`), in Stored's format:
	## its name as it was made, the spelling kept for display:
	##
	##     topic v1 name=ChitChat
	##
	## The channel is not in the line: the folder the line is in says it.
	encode : Topic -> List(U8)
	encode = |Topic.(t)| Stored.line("topic", [("name", t.at.topic.to_str())])

	## **A TOPIC BACK FROM THE STORE**: the one way in besides `make`, its
	## line checked, in `channel` (the channel loaded, whose folder the line
	## is in).
	decode : List(U8), ChannelName -> Try(Topic, _)
	decode = |raw, channel| {
		fields = Stored.Reader.open(raw, "topic")?
		name_field = fields.field("name")?
		name = name_from(name_field.value)?
		name_field.rest.close()?
		Ok(Topic.({ at: { channel, topic: name } }))
	}

	## Where the topic is.
	at : Topic -> Topic.At
	at = |Topic.(t)| t.at

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
		viewer : Access.Viewer,
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
		viewer : Access.Viewer,
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
	viewer : Access.Viewer,
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
	viewer : Access.Viewer,
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
		match viewer.reach(act) {
			Reaches => Ok({})
			OutOfScope => Err(OutOfScope)
			SignedOut => crash "Topic.allowed: a signed-in viewer is not signed out"
		}?
		match channel.membership({ who, accounts }) {
			Member => Ok({})
			NotAMember => Err(NotAMember)
		}
	}
}

## **THE ASKER, SIGNED IN, THEIR ACCOUNT THE ONE THEIR CREDENTIAL WAS MINTED
## FOR**, or why not.
signed_in : Access.Viewer, List(Principal) -> Try(Principal.Bound, [SignedOut, NoSuchPrincipal])
signed_in = |viewer, accounts|
	match viewer.who() {
		SignedOut => Err(SignedOut)
		Session(b) | Key(b) =>
			match Principal.holds(accounts, b) {
				Ok(_) => Ok(b)
				Err(NoSuchPrincipal) => Err(NoSuchPrincipal)
			}
	}

## The name a topic line's field holds, by TopicName's rule.
name_from : List(U8) -> Try(TopicName, [BadValue(Str)])
name_from = |value|
	match Str.from_utf8(value) {
		Ok(text) => TopicName.from_str(text).map_err(|_| BadValue("name"))
		Err(_) => crash "Topic.name_from: Stored.Reader.open checked the line is UTF-8"
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

## Steve's example: Steve, Damian and Apoorva, and Steve's agent Cc and
## his bot.
cobblestone : Channel
cobblestone = channel_of(
	"Cobblestone",
	[
		Steve,
		Damian,
		Apoorva,
		Cc,
		SteveBot,
	],
)

## Another channel, of Zed, Apoorva and Zed's agent, with its own `ChitChat`.
general : Channel
general = channel_of(
	"general",
	[
		Zed,
		Apoorva,
		ZedAgent,
	],
)

## A channel, with the topics already in it.
Place : { channel : Channel, topics : List(Topic) }

## A topic `by` makes in `place`, or the refusal.
make_in : Place, { by : ChannelCast.Who, name : Str } -> Try(Topic, _)
make_in = |{ channel, topics }, { by, name }|
	Topic.make({
		by: ChannelCast.viewer(by),
		channel,
		name,
		topics,
		accounts: ChannelCast.accounts,
	})

## `channel`, with no topic yet.
bare : Channel -> Place
bare = |channel| { channel, topics: [] }

## A topic made, in a test where it is.
made : Try(Topic, _) -> Topic
made = |tried|
	match tried {
		Ok(t) => t
		Err(_) => crash "made: a test's topic is made"
	}

## Cobblestone's topic, made by Steve.
chitchat : Topic
chitchat = made(make_in(bare(cobblestone), { by: Steve, name: "ChitChat" }))

## Cobblestone's topic, made by Steve's agent.
plans : Topic
plans = made(make_in({ channel: cobblestone, topics: [chitchat] }, { by: Cc, name: "plans" }))

## general's own `ChitChat`: the same name, another channel, another topic.
general_chitchat : Topic
general_chitchat = made(make_in(bare(general), { by: Zed, name: "ChitChat" }))

## Cobblestone's topics.
cobblestones : List(Topic)
cobblestones = [chitchat, plans]

## Cobblestone with its topics.
full : Place
full = { channel: cobblestone, topics: cobblestones }

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

# Made: where each is.
expect chitchat.at() == at_of("Cobblestone", "ChitChat")
expect chitchat.at().topic.to_str() == "ChitChat"
expect plans.at() == at_of("cobblestone", "PLANS")
# Two channels' ChitChats are two topics, at two places.
expect general_chitchat.at() == at_of("general", "chitchat")
expect general_chitchat.at() != chitchat.at()
expect general_chitchat != chitchat

# ── THE READ TABLE: every viewer against every topic. A topic is its
# channel's members', each kind alike, and nobody else's.
everyone : List(ChannelCast.Who)
everyone = [
	Out,
	Steve,
	Damian,
	Apoorva,
	Zed,
	Root,
	Cc,
	Lc,
	SteveBot,
	DamianAgent,
	ZedAgent,
]

## What `who` gets from a topic of `channel`: the members' Permitted, the
## rest's refusal by name.
expected : Channel, ChannelCast.Who -> Topic.Verdict
expected = |channel, who|
	match who {
		Out => Refused(SignedOut)
		_ => if (channel.membership({ who: ChannelCast.bound(who), accounts: ChannelCast.accounts }) == Member) Permitted else Refused(NotAMember)
	}

expect everyone.all(|who| reads(chitchat, who) == expected(cobblestone, who))
expect everyone.all(|who| reads(plans, who) == expected(cobblestone, who))
expect everyone.all(|who| reads(general_chitchat, who) == expected(general, who))
expect everyone.all(|who| posts(chitchat, who) == expected(cobblestone, who))
expect everyone.all(|who| posts(general_chitchat, who) == expected(general, who))
# The table's two sides, named: members of each kind in, the rest out.
expect reads(chitchat, Steve) == Permitted
expect reads(chitchat, Cc) == Permitted
expect reads(chitchat, SteveBot) == Permitted
expect reads(chitchat, Lc) == Refused(NotAMember)
expect reads(chitchat, DamianAgent) == Refused(NotAMember)
expect reads(chitchat, Zed) == Refused(NotAMember)
expect reads(chitchat, Root) == Refused(NotAMember)
expect reads(chitchat, Out) == Refused(SignedOut)
expect reads(general_chitchat, ZedAgent) == Permitted
expect reads(general_chitchat, Steve) == Refused(NotAMember)
expect posts(plans, Damian) == Permitted
expect posts(plans, Cc) == Permitted
expect posts(plans, Lc) == Refused(NotAMember)

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

# ── A KEY'S SCOPE: its read and its post, each on or off; a reach is no
# right the rule denies, and a key says who it is, its member's reach
# being the channel's.
cc_reads : Access.Viewer
cc_reads = ChannelCast.keyed(
	Cc,
	{
		read: On,
		post: Off,
	},
)

expect plans.read({
	viewer: cc_reads,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Permitted
expect chitchat.read({
	viewer: cc_reads,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Permitted
expect plans.post({
	viewer: cc_reads,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Refused(OutOfScope)

## Steve's key that posts, and reads nothing.
steve_posts : Access.Viewer
steve_posts = ChannelCast.keyed(
	Steve,
	{
		read: Off,
		post: On,
	},
)

expect chitchat.post({
	viewer: steve_posts,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Permitted
expect chitchat.read({
	viewer: steve_posts,
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Refused(OutOfScope)
# A key reaching everywhere is no membership: Lc's reads nothing here.
expect plans.read({
	viewer: ChannelCast.keyed(
		Lc,
		{
			read: On,
			post: Off,
		},
	),
	channel: cobblestone,
	accounts: ChannelCast.accounts,
}) == Refused(NotAMember)

# ── RETIRED, OR MADE AGAIN: a viewer whose account is not the one it was
# minted for reads nothing.
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
expect chitchat.read({
	viewer: ChannelCast.viewer(Cc),
	channel: cobblestone,
	accounts: ChannelCast.without(Cc),
}) == Refused(NoSuchPrincipal)

# ── A MEMBER REMOVED: out of every topic, an agent as a human.
## Cobblestone without `who`.
without : ChannelCast.Who -> Channel
without = |who|
	match cobblestone.remove({
		by: ChannelCast.viewer(Steve),
		member: ChannelCast.id(who),
		accounts: ChannelCast.accounts,
	}) {
		Ok(c) => c
		Err(_) => crash "without: Steve removes a member"
	}

expect [chitchat, plans].all(
	|t| t.read({
		viewer: ChannelCast.viewer(Damian),
		channel: without(Damian),
		accounts: ChannelCast.accounts,
	}) == Refused(NotAMember),
)
expect [chitchat, plans].all(
	|t| t.read({
		viewer: ChannelCast.viewer(Cc),
		channel: without(Cc),
		accounts: ChannelCast.accounts,
	}) == Refused(NotAMember),
)

# ── MAKING A TOPIC: any member, of any kind.
expect make_in(full, { by: Apoorva, name: "Plans2" }).map_ok(|t| t.at()) == Ok(at_of("Cobblestone", "Plans2"))
expect make_in(full, { by: SteveBot, name: "notes" }).is_ok()
expect make_in(full, { by: Out, name: "x" }) == Err(SignedOut)
expect make_in(full, { by: Steve, name: "a b" }) == Err(NotATopicName)
expect make_in(full, { by: Steve, name: "a--b" }) == Err(NotATopicName)
# A non-member makes none, an admin no more than anyone, an agent no more
# than a human.
expect make_in(full, { by: Zed, name: "x" }) == Err(NotAMember)
expect make_in(full, { by: Root, name: "x" }) == Err(NotAMember)
expect make_in(full, { by: Lc, name: "x" }) == Err(NotAMember)
# Taken in this channel, in any case; another channel's name is no matter.
expect make_in(full, { by: Damian, name: "CHITCHAT" }) == Err(Taken)
expect make_in({ channel: general, topics: cobblestones }, { by: Apoorva, name: "plans" }).is_ok()
expect make_in({ channel: general, topics: [general_chitchat] }, { by: Apoorva, name: "chitchat" }) == Err(Taken)
# A key makes one only where its post is on.
expect Topic.make({
	by: ChannelCast.keyed(
		Steve,
		{
			read: On,
			post: Off,
		},
	),
	channel: cobblestone,
	name: "Plans2",
	topics: [],
	accounts: ChannelCast.accounts,
}) == Err(OutOfScope)
expect Topic.make({
	by: ChannelCast.keyed(
		Steve,
		{
			read: Off,
			post: On,
		},
	),
	channel: cobblestone,
	name: "Plans2",
	topics: [],
	accounts: ChannelCast.accounts,
}).is_ok()
# Damian made again, by his old session: refused.
expect Topic.make({
	by: ChannelCast.viewer(Damian),
	channel: cobblestone,
	name: "Plans2",
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
expect Topic.find(cobblestones, at_of("Cobblestone", "Nope")) == Err(NoSuchTopic)
expect Topic.find([chitchat, chitchat], chitchat.at()) == Err(Duplicated)

# ── STORED AND LOADED: the topic it was.
## `topic` through its line and back, in its own channel.
stored_and_loaded : Topic -> Try(Topic, _)
stored_and_loaded = |topic| Topic.decode(topic.encode(), topic.at().channel)

## A line decoded in General, or why not.
line_in_general : Str -> Try({}, _)
line_in_general = |text| Topic.decode(text.to_utf8(), at_of("General", "x").channel).map_ok(|_| {})

expect chitchat.encode() == "topic v1 name=ChitChat\n".to_utf8()

# Refusals, each by name; the old line's `kind` among them.
expect line_in_general("topic v1 name=ChitChat\n") == Ok({})
expect line_in_general("topic v1 name=x kind=human\n") == Err(Trailing)
expect line_in_general("topic v1 name=a--b\n") == Err(BadValue("name"))
expect line_in_general("topic v1 name=\n") == Err(BadValue("name"))
expect line_in_general("topic v1\n") == Err(MissingField("name"))
expect line_in_general("topic v1 name=x") == Err(Torn)
expect line_in_general("channel v1 name=x members=\n") == Err(WrongRecord)

expect
	cobblestones.append(general_chitchat).all(|t| stored_and_loaded(t) == Ok(t))
expect stored_and_loaded(chitchat).map_ok(|t| t.at().topic.to_str()) == Ok("ChitChat")

## **A CHANNEL AND WHO IS IN IT** (the channels design, Steve's decisions
## of 2026-10-31): a name (ChannelName), and its members, humans only. An
## agent or a bot is never a member: it reaches a channel only through an
## agent topic that names it (Topic.roc).
##
## **WHO IS IN IS AN ADMIN'S DECISION, BY THEIR OWN SESSION**: an admin
## makes a channel, naming it and its members, and admits or removes a
## member later; nobody else does, and no key does, so one stolen key never
## lets anyone in (as Admin.roc keeps setting a role to a session). An
## admin is no member by being one: they read a channel's topics only if
## they are in it, as anyone.
##
## **A MEMBER IS BOUND TO THEIR ACCOUNT** (Principal.Bound, made when they
## are let in): a member counts only while that binding holds, so an
## account retired and made again with the same id is not in the
## channels the old one was in, until an admin admits it again. Pure:
## each decision takes the accounts as they are, and the channels already
## made, and returns the channel to store or the refusal by name.
import Access
import ChannelCast
import ChannelCodec
import ChannelName
import Principal

Channel :: {
	name : ChannelName,
	members : List(Principal.Bound),
}.{

	## **AN ADMIN MAKES A CHANNEL**, named `name`, with `members`. Refused,
	## in this order: nobody signed in (`SignedOut`); a key, not a session
	## (`NeedsSession`); a session whose account is gone (`NoSuchPrincipal`);
	## a member, not an admin (`NotAdmin`); a name the rule refuses
	## (`NotAChannelName`); a name some channel has, in any case (`Taken`,
	## so no two channels' paths meet, on a disk that folds case too); then
	## each member: named twice (`NamedTwice`), an agent's or a bot's id
	## (`NotAHuman`), or no one account holds it (`NoAccount`). No member at
	## all is a channel, empty until an admin admits someone.
	make : {
		by : Access.Viewer(id),
		name : Str,
		members : List(Principal.Id),
		channels : List(Channel),
		accounts : List(Principal),
	} -> Try(Channel, _)
	make = |
		{
			by,
			name,
			members,
			channels,
			accounts,
		},
	| {
		admin(by, accounts)?
		valid = ChannelName.from_str(name)?
		if channels.any(|c| c.name() == valid) {
			Err(Taken)
		} else {
			bound = members.fold_try(
				[],
				|kept, id| {
					if kept.any(|b| b.id == id) {
						Err(NamedTwice(id))
					} else {
						Ok(kept.append(human_bound(accounts, id)?))
					}
				},
			)?
			Ok(Channel.({ name: valid, members: bound }))
		}
	}

	## **AN ADMIN LETS A HUMAN IN**: refused as `make` refuses its asker
	## and each of its members, and `AlreadyIn` for a member whose binding
	## holds. A binding of an earlier account with that id (retired, made
	## again since) is replaced.
	admit : Channel,
	{
		by : Access.Viewer(id),
		member : Principal.Id,
		accounts : List(Principal),
	} -> Try(Channel, _)
	admit = |
		Channel.(c),
		{
			by,
			member,
			accounts,
		},
	| {
		admin(by, accounts)?
		b = human_bound(accounts, member)?
		if c.members.contains(b) {
			Err(AlreadyIn(member))
		} else {
			Ok(Channel.({ ..c, members: c.members.keep_if(|m| m.id != member).append(b) }))
		}
	}

	## **AN ADMIN TAKES A MEMBER OUT**, by id, whether their account still
	## stands or not: refused as `make` refuses its asker, and `NotIn` for
	## an id the channel does not hold. Their reach goes with it: the
	## channel's human topics, and any agent topic they reached only as a
	## member (none: an agent topic is its agents' owners', member or not).
	remove : Channel,
	{
		by : Access.Viewer(id),
		member : Principal.Id,
		accounts : List(Principal),
	} -> Try(Channel, _)
	remove = |
		Channel.(c),
		{
			by,
			member,
			accounts,
		},
	| {
		admin(by, accounts)?
		if c.members.any(|m| m.id == member) {
			Ok(Channel.({ ..c, members: c.members.keep_if(|m| m.id != member) }))
		} else {
			Err(NotIn(member))
		}
	}

	## **MAY `by` CHANGE THE CHANNELS, NOW?** An admin by their own
	## session, as `make`, `admit` and `remove` each ask first, refused as
	## they refuse their asker: what an admin's page asks, and a route on a
	## channel that is not there, before it says so.
	administers : Access.Viewer(id),
	List(Principal) -> Try(
		{},
		[
			SignedOut,
			NeedsSession,
			NoSuchPrincipal,
			NotAdmin,
		],
	)
	administers = |by, accounts| admin(by, accounts)

	## **A CHANNEL BACK FROM THE STORE**: the one way in besides `make`, from
	## a line ChannelCodec decoded, every field checked.
	load : ChannelCodec.Line -> Channel
	load = |line| Channel.(line.fields())

	## The channel's fields, to store (ChannelCodec.encode).
	fields : Channel -> ChannelCodec.Fields
	fields = |Channel.(c)| c

	## The channel's name.
	name : Channel -> ChannelName
	name = |Channel.(c)| c.name

	## **ITS MEMBERS NOW**: those whose binding holds among `accounts`.
	members : Channel, List(Principal) -> List(Principal.Bound)
	members = |Channel.(c), accounts| c.members.keep_if(|b| Principal.holds(accounts, b).is_ok())

	## **IS `who` IN THE CHANNEL, NOW?** A human whose binding is the
	## channel's and holds among `accounts`; never an agent or a bot.
	membership : Channel,
	{
		who : Principal.Bound,
		accounts : List(Principal),
	} -> [Member, NotAMember]
	membership = |channel, { who, accounts }|
		if (channel.members(accounts).contains(who)) Member else NotAMember

	is_eq : _
}

## **THE ASKER, AN ADMIN BY THEIR OWN SESSION, NOW**, or why not.
admin : Access.Viewer(id),
List(Principal) -> Try(
	{},
	[
		SignedOut,
		NeedsSession,
		NoSuchPrincipal,
		NotAdmin,
	],
)
admin = |by, accounts|
	match by.who() {
		SignedOut => Err(SignedOut)
		Key(_) => Err(NeedsSession)
		Session(b) =>
			match Principal.holds(accounts, b) {
				Err(NoSuchPrincipal) => Err(NoSuchPrincipal)
				Ok(Human(h)) =>
					match h.role {
						Admin => Ok({})
						Member => Err(NotAdmin)
					}
				Ok(Agent(_)) | Ok(Bot(_)) => crash "Channel.admin: a session's viewer is a human"
			}
	}

## A human's binding to their one account, to let them in.
human_bound : List(Principal),
Principal.Id -> Try(
	Principal.Bound,
	[NotAHuman(Principal.Id), NoAccount(Principal.Id)],
)
human_bound = |accounts, id|
	match id {
		Agent(_) | Bot(_) => Err(NotAHuman(id))
		Human(_) =>
			match Principal.bind(accounts, id) {
				Ok(b) => Ok(b)
				Err(_) => Err(NoAccount(id))
			}
	}

# ── tests
## A test's channel, made by Steve, the admin.
made : Str, List(ChannelCast.Who) -> Channel
made = |name, members|
	match Channel.make({
		by: ChannelCast.viewer(Steve),
		name,
		members: members.map(ChannelCast.id),
		channels: [],
		accounts: ChannelCast.accounts,
	}) {
		Ok(c) => c
		Err(_) => crash "made: a test's channel is made"
	}

cobblestone : Channel
cobblestone = made(
	"Cobblestone",
	[
		Steve,
		Damian,
		Apoorva,
	],
)

## A channel made by `by`, named `name`, with `members`, beside
## `cobblestone`.
make_by : ChannelCast.Who, { name : Str, members : List(ChannelCast.Who) } -> Try(Channel, _)
make_by = |by, { name, members }|
	Channel.make({
		by: ChannelCast.viewer(by),
		name,
		members: members.map(ChannelCast.id),
		channels: [cobblestone],
		accounts: ChannelCast.accounts,
	})

## Its members' ids, among `accounts`.
ids : Channel, List(Principal) -> List(Principal.Id)
ids = |channel, accounts| channel.members(accounts).map(|b| b.id)

# Made: its name as spelled, its members bound.
expect cobblestone.name().to_str() == "Cobblestone"
expect ids(cobblestone, ChannelCast.accounts) == [
	Steve,
	Damian,
	Apoorva,
].map(ChannelCast.id)
expect make_by(
	Root,
	{ name: "general", members: [] },
).map_ok(|c| ids(c, ChannelCast.accounts)) == Ok([])
expect make_by(Root, { name: "general", members: [Zed] }).is_ok()

# Who makes one: an admin, by their own session, and nobody else.
expect make_by(Out, { name: "general", members: [] }) == Err(SignedOut)
expect make_by(Damian, { name: "general", members: [] }) == Err(NotAdmin)
expect make_by(Cc, { name: "general", members: [] }) == Err(NeedsSession)

## Made by Steve's own key, though its scope administers: a key never
## lets anyone in.
by_admin_key : Try(Channel, _)
by_admin_key = Channel.make({
	by: ChannelCast.keyed(
		Steve,
		{
			read: On(Everywhere),
			post: On(Everywhere),
			admin: On,
		},
	),
	name: "general",
	members: [],
	channels: [],
	accounts: ChannelCast.accounts,
})

expect by_admin_key == Err(NeedsSession)

# Administering, asked alone: the asker as `make` takes them.
expect Channel.administers(ChannelCast.viewer(Steve), ChannelCast.accounts) == Ok({})
expect Channel.administers(ChannelCast.viewer(Damian), ChannelCast.accounts) == Err(NotAdmin)
expect Channel.administers(ChannelCast.viewer(Cc), ChannelCast.accounts) == Err(NeedsSession)
expect Channel.administers(ChannelCast.viewer(Out), ChannelCast.accounts) == Err(SignedOut)
expect Channel.make({
	by: ChannelCast.viewer(Root),
	name: "general",
	members: [],
	channels: [],
	accounts: ChannelCast.without(Root),
}) == Err(NoSuchPrincipal)

# Its name: the rule's, and no other channel's in any case.
expect make_by(Steve, { name: "1st", members: [] }) == Err(NotAChannelName)
expect make_by(Steve, { name: "a/b", members: [] }) == Err(NotAChannelName)
expect make_by(Steve, { name: "cobblestone", members: [] }) == Err(Taken)
expect make_by(Steve, { name: "COBBLESTONE", members: [] }) == Err(Taken)
expect make_by(Steve, { name: "Cobblestone-2", members: [] }).is_ok()

# Its members: humans with an account, each once.
expect make_by(
	Steve,
	{ name: "general", members: [Damian, Cc] },
) == Err(NotAHuman(ChannelCast.id(Cc)))
expect make_by(
	Steve,
	{ name: "general", members: [SteveBot] },
) == Err(NotAHuman(ChannelCast.id(SteveBot)))
expect make_by(
	Steve,
	{ name: "general", members: [Damian, Damian] },
) == Err(NamedTwice(ChannelCast.id(Damian)))

## Zed named, retired.
with_zed_gone : Try(Channel, _)
with_zed_gone = Channel.make({
	by: ChannelCast.viewer(Steve),
	name: "general",
	members: [ChannelCast.id(Zed)],
	channels: [],
	accounts: ChannelCast.without(Zed),
})

expect with_zed_gone == Err(NoAccount(ChannelCast.id(Zed)))

# Membership: humans whose binding holds; never an agent.
expect cobblestone.membership({
	who: ChannelCast.bound(Damian),
	accounts: ChannelCast.accounts,
}) == Member
expect cobblestone.membership({
	who: ChannelCast.bound(Zed),
	accounts: ChannelCast.accounts,
}) == NotAMember
expect cobblestone.membership({
	who: ChannelCast.bound(Root),
	accounts: ChannelCast.accounts,
}) == NotAMember
expect cobblestone.membership({
	who: ChannelCast.bound(Cc),
	accounts: ChannelCast.accounts,
}) == NotAMember
# Damian retired: out; made again: still out, until admitted again.
expect cobblestone.membership({
	who: ChannelCast.bound(Damian),
	accounts: ChannelCast.without(Damian),
}) == NotAMember
expect ids(cobblestone, ChannelCast.damian_again) == [Steve, Apoorva].map(ChannelCast.id)

## `cobblestone`, with `who` admitted (or the refusal) by `by` among
## `accounts`.
admitted : ChannelCast.Who, { who : ChannelCast.Who, accounts : List(Principal) } -> Try(Channel, _)
admitted = |by, { who, accounts }|
	cobblestone.admit({
		by: ChannelCast.viewer(by),
		member: ChannelCast.id(who),
		accounts,
	})

## `cobblestone`, with `who` removed (or the refusal) by `by`.
removed : ChannelCast.Who, ChannelCast.Who -> Try(Channel, _)
removed = |by, who|
	cobblestone.remove({
		by: ChannelCast.viewer(by),
		member: ChannelCast.id(who),
		accounts: ChannelCast.accounts,
	})

# Admitting: an admin's, a human with an account, not already in.
expect admitted(Steve, { who: Zed, accounts: ChannelCast.accounts }).map_ok(
	|c| c.membership({
		who: ChannelCast.bound(Zed),
		accounts: ChannelCast.accounts,
	}),
) == Ok(Member)
expect admitted(Root, { who: Zed, accounts: ChannelCast.accounts }).is_ok()
expect admitted(Damian, { who: Zed, accounts: ChannelCast.accounts }) == Err(NotAdmin)
expect admitted(Cc, { who: Zed, accounts: ChannelCast.accounts }) == Err(NeedsSession)
expect admitted(Out, { who: Zed, accounts: ChannelCast.accounts }) == Err(SignedOut)
expect admitted(
	Steve,
	{ who: Damian, accounts: ChannelCast.accounts },
) == Err(AlreadyIn(ChannelCast.id(Damian)))
expect admitted(
	Steve,
	{ who: Lc, accounts: ChannelCast.accounts },
) == Err(NotAHuman(ChannelCast.id(Lc)))
expect admitted(
	Steve,
	{ who: Zed, accounts: ChannelCast.without(Zed) },
) == Err(NoAccount(ChannelCast.id(Zed)))
# Damian made again is admitted again, the old binding replaced.
expect admitted(
	Steve,
	{ who: Damian, accounts: ChannelCast.damian_again },
).map_ok(|c| ids(c, ChannelCast.damian_again)) == Ok(
	[
		Steve,
		Apoorva,
		Damian,
	].map(ChannelCast.id),
)

# Removing: an admin's, by id, of someone in it.
expect removed(Steve, Damian).map_ok(
	|c| ids(
		c,
		ChannelCast.accounts,
	),
) == Ok([Steve, Apoorva].map(ChannelCast.id))
expect removed(Steve, Damian).map_ok(
	|c| c.membership({ who: ChannelCast.bound(Damian), accounts: ChannelCast.accounts }),
) == Ok(NotAMember)
expect removed(Steve, Steve).is_ok()
expect removed(Damian, Apoorva) == Err(NotAdmin)
expect removed(Cc, Apoorva) == Err(NeedsSession)
expect removed(Steve, Zed) == Err(NotIn(ChannelCast.id(Zed)))
# A retired member is removed by id all the same.
## Damian removed, retired.
removed_retired : Try(Channel, _)
removed_retired = cobblestone.remove({
	by: ChannelCast.viewer(Steve),
	member: ChannelCast.id(Damian),
	accounts: ChannelCast.without(Damian),
})

expect removed_retired.is_ok()

# Stored and loaded: the channel it was, its members' bindings and all.
## `channel` through its line and back.
stored_and_loaded : Channel -> Try(Channel, _)
stored_and_loaded = |channel| ChannelCodec.decode(ChannelCodec.encode(channel.fields())).map_ok(Channel.load)

expect stored_and_loaded(cobblestone) == Ok(cobblestone)
expect stored_and_loaded(cobblestone).map_ok(|c| c.name().to_str()) == Ok("Cobblestone")
expect make_by(
	Steve,
	{ name: "general", members: [] },
).map_ok(|c| stored_and_loaded(c) == Ok(c)) == Ok(Bool.True)

## **A HUMAN ERASED** (Steve, 2026-11-02): an admin hard-removes a
## throwaway or fly-by human, and everything of theirs, so the name and the
## place are free for another (Alice again, for testing, without the noise
## of the first). Not a ban: nothing is barred, and they may come back as
## someone new. Pure: who may be erased, and what goes.
##
## **WHO MAY BE**: a human in no channel, nor any agent or bot of theirs
## (a channel's membership is the mark of someone who belongs here); never
## the asker, never an admin.
##
## **WHAT GOES**: their account and every agent and bot they own; every DM
## they are in, whole, the other human's half too (a DM is the pair's);
## the saves of those DMs' messages on anyone's reading list; their
## sessions, their reading list, their uploaded bytes' count, and the
## indexes of their keys and invites (Store.erase!). **WHAT STAYS**: their
## keys and invites, inert (each names an account no longer there, and an
## id is never given twice, so none comes back to life); the audit, as
## history.
import Channel
import ChannelCast
import ChannelName
import Principal

Erase := [].{

	## **AN ERASURE, DECIDED**: the human, the accounts left after, the ids
	## that go (the human's and their agents' and bots'), and their DMs.
	Plan : {
		human : Principal.HumanId,
		left : List(Principal),
		gone : List(Principal.Id),
		dms : List(ChannelName),
	}

	## **WHY A HUMAN MAY NOT BE ERASED**, each in words an admin's page says.
	Refusal : [
		## No human's account holds the id.
		NoSuchHuman,

		## The asker themselves.
		Yourself,

		## An admin.
		AnAdmin,

		## In these channels, they or an agent or bot of theirs.
		InChannels(List(ChannelName)),
	]

	## **MAY `target` BE ERASED BY `asker`, AND WHAT GOES**: decided
	## against the accounts and every channel and DM (Store.load_channels!).
	plan : {
		asker : Principal.Id,
		target : Principal.HumanId,
		accounts : List(Principal),
		channels : List(Channel),
	} -> Try(Erase.Plan, _)
	plan = |asked| {
		asker = asked.asker
		target = asked.target
		accounts = asked.accounts
		channels = asked.channels
		human = Principal.Id.Human(target)
		account = Principal.find(accounts, human).map_err(|_| NoSuchHuman)?
		owned = accounts.keep_if(|p| p.answers_to() == target)
		gone = owned.map(|p| p.id())
		member_in = |c| c.members(accounts).any(|b| gone.contains(b.id))
		if asker == human {
			Err(Yourself)
		} else if account.authority(accounts) == Admin {
			Err(AnAdmin)
		} else {
			match channels.keep_if(|c| !c.name().is_dm() and member_in(c)) {
				[_, ..] as held => Err(InChannels(held.map(|c| c.name())))
				[] =>
					Ok({
						human: target,
						left: accounts.drop_if(|p| gone.contains(p.id())),
						gone,
						dms: channels.map(|c| c.name()).keep_if(|name| in_pair(name, target.to_u64())),
					})
			}
		}
	}

	## **THE WORDS FOR A REFUSAL**, as the users page says it.
	why : Erase.Refusal -> Str
	why = |refusal|
		match refusal {
			NoSuchHuman => "no human has that id"
			Yourself => "you cannot remove yourself"
			AnAdmin => "an admin is never removed"
			InChannels(names) => "in a channel: ${Str.join_with(names.map(|n| n.to_str()), ", ")}"
		}
}

## Whether a DM's pair has `id` in it.
in_pair : ChannelName, U64 -> Bool
in_pair = |name, id|
	match name.dm_pair() {
		Ok({ lo, hi }) => lo == id or hi == id
		Err(NotADm) => Bool.False
	}

# ── tests
## Steve's plan for erasing human `target` among the cast's accounts and `channels`.
erasing : ChannelCast.Who, List(Channel) -> Try(Erase.Plan, _)
erasing = |target, channels| asked_by(Steve, { target, channels })

## `asker`'s plan for erasing human `target`.
asked_by : ChannelCast.Who, { target : ChannelCast.Who, channels : List(Channel) } -> Try(Erase.Plan, _)
asked_by = |asker, { target, channels }|
	match ChannelCast.id(target) {
		Human(h) =>
			Erase.plan({
				asker: ChannelCast.id(asker),
				target: h,
				accounts: ChannelCast.accounts,
				channels,
			})
		_ => crash "asked_by: a test's target is a human"
	}

## A channel the cast's admin makes, its members `members`.
channel : Str, List(ChannelCast.Who) -> Channel
channel = |name, members|
	Channel.make({
		by: ChannelCast.viewer(Steve),
		name,
		members: members.map(ChannelCast.id),
		channels: [],
		accounts: ChannelCast.accounts,
	}) ?? crash "channel: a test's channel is made"

## The DM of `a` with `b`, as `a` makes it.
dm : ChannelCast.Who, ChannelCast.Who -> Channel
dm = |a, b|
	Channel.dm({
		by: ChannelCast.viewer(a),
		other: ChannelCast.id(b),
		accounts: ChannelCast.accounts,
	}) ?? crash "dm: a test's DM is made"

## A channel's name, in a test.
named : Str -> ChannelName
named = |text| ChannelName.from_str(text) ?? crash "named: a test's name is a name"

# Zed, in no channel: he and his agent go, his DMs with Apoorva and with
# himself go, and no one else's DM.
expect {
	channels = [
		channel("Cobblestone", [Damian, Apoorva]),
		dm(Zed, Apoorva),
		dm(Zed, Zed),
		dm(Damian, Apoorva),
	]
	match erasing(Zed, channels) {
		Ok(p) =>
			p.gone == [ChannelCast.id(Zed), ChannelCast.id(ZedAgent)]
				and p.dms.map(|n| n.to_str()) == ["3_4", "4_4"]
				and p.left.len() == 8
				and !p.left.any(|a| a.id() == ChannelCast.id(Zed) or a.id() == ChannelCast.id(ZedAgent))
		Err(_) => Bool.False
	}
}
# Apoorva, a member of a channel: refused, naming it; out of it, erased with her DM.
expect erasing(Apoorva, [channel("Cobblestone", [Damian, Apoorva])]).map_ok(|_| {}) == Err(InChannels([named("Cobblestone")]))
expect erasing(Apoorva, [channel("Cobblestone", [Damian]), dm(Damian, Apoorva)]).map_ok(|p| p.dms.map(|n| n.to_str())) == Ok(["2_3"])
# Damian's agent in a channel: Damian is refused too, though he is in none.
expect erasing(Damian, [channel("Shed", [DamianAgent])]).map_ok(|_| {}) == Err(InChannels([named("Shed")]))
# Never oneself, never an admin, never nobody.
expect asked_by(Zed, { target: Zed, channels: [] }).map_ok(|_| {}) == Err(Yourself)
expect erasing(Root, []).map_ok(|_| {}) == Err(AnAdmin)
expect {
	nobody = Principal.HumanId.from_u64(99) ?? crash "an id"
	got = Erase.plan({
		asker: ChannelCast.id(Steve),
		target: nobody,
		accounts: ChannelCast.accounts,
		channels: [],
	})
	got.map_ok(|_| {}) == Err(NoSuchHuman)
}
# The page's words.
expect Erase.why(InChannels([named("Shed"), named("Lobby")])) == "in a channel: Shed, Lobby"

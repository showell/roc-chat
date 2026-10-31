## **THE CHANNELS' TESTS' CAST**: the principals, accounts and viewers the
## `expect`s of Channel.roc, Topic.roc and MessageRef.roc share, made here
## once (as Cast.roc is for the auth core). Nothing outside an `expect`
## uses it.
##
## Steve's example, as the design draft tells it: `#Cobblestone`, with
## members Steve, Damian and Apoorva.
##   Steve    an ADMIN and a member; owns the agents Cc and Lc, and SteveBot
##   Damian   a member; owns DamianAgent
##   Apoorva  a member; owns nothing
##   Zed      no member; owns ZedAgent
##   Root     an ADMIN, no member
## and `Out`, nobody signed in.
import Access
import ApiKey
import Cast
import Principal
import Session
import SessionCodec

ChannelCast := [].{

	## Who a test names.
	Who : [
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

	## The cast member's account.
	principal : ChannelCast.Who -> Principal
	principal = |who|
		match who {
			Out => crash "ChannelCast.principal: nobody signed in is no principal"
			Steve => Cast.person(1, Admin)
			Damian => Cast.person(2, Member)
			Apoorva => Cast.person(3, Member)
			Zed => Cast.person(4, Member)
			Root => Cast.person(5, Admin)
			Cc => Cast.owned(Agent, { id: 1, owner: 1 })
			Lc => Cast.owned(Agent, { id: 2, owner: 1 })
			SteveBot => Cast.owned(Bot, { id: 3, owner: 1 })
			DamianAgent => Cast.owned(Agent, { id: 4, owner: 2 })
			ZedAgent => Cast.owned(Agent, { id: 5, owner: 4 })
		}

	## The cast member's id.
	id : ChannelCast.Who -> Principal.Id
	id = |who| ChannelCast.principal(who).id()

	## Every account in the cast.
	accounts : List(Principal)
	accounts = [
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
	].map(ChannelCast.principal)

	## The cast's accounts, `gone` retired.
	without : ChannelCast.Who -> List(Principal)
	without = |gone| ChannelCast.accounts.keep_if(|p| p.id() != ChannelCast.id(gone))

	## The cast's accounts, Damian retired and made again (generation 2).
	damian_again : List(Principal)
	damian_again = ChannelCast.without(Damian).append(
		Principal.Human({
			id: Cast.hid(2),
			sign_in: Cast.github(2),
			login: "h2",
			name: "H2",
			role: Member,
			generation: Cast.gen(2),
		}),
	)

	## The cast member's binding to its account.
	bound : ChannelCast.Who -> Principal.Bound
	bound = |who|
		match Principal.bind(ChannelCast.accounts, ChannelCast.id(who)) {
			Ok(b) => b
			Err(_) => crash "ChannelCast.bound: a cast member has one account"
		}

	## **A VIEWER, AS A HANDLER GETS ONE**, minted among the whole cast at
	## 10: `Out` signed out; a human by their own session; an agent or a
	## bot by a key reaching everywhere, granted by its owner.
	viewer : ChannelCast.Who -> Access.Viewer(id)
	viewer = |who|
		match who {
			Out => Access.Viewer.signed_out({})
			_ =>
				match ChannelCast.principal(who) {
					Human(h) =>
						match Access.Viewer.from_session(
							session_of(h.id.to_u64()),
							{ accounts: ChannelCast.accounts, now: 10 },
						) {
							Ok({ viewer: v, write: _ }) => v
							Err(_) => crash "ChannelCast.viewer: a cast member's session is admitted"
						}
					Agent(_) | Bot(_) => ChannelCast.keyed(
						who,
						{
							read: On(Everywhere),
							post: On(Everywhere),
							admin: Off,
						},
					)
				}
		}

	## The viewer a key acting as `who` mints (a human's own key, or an
	## agent's or a bot's, granted by its owner), of `scope`.
	keyed : ChannelCast.Who, ApiKey.Scope(id) -> Access.Viewer(id)
	keyed = |who, scope| {
		acting = ChannelCast.principal(who)
		key = ApiKey.Key.issue(
			{
				granter: Session(session_of(acting.answers_to().to_u64())),
				acts_as: acting.id(),
				scope,
				accounts: ChannelCast.accounts,
				now: 10,
			},
			{ key: Cast.kid(1), expires: 1000 },
		)
		match key {
			Err(_) => crash "ChannelCast.keyed: a cast member's key is grantable"
			Ok(k) =>
				match Access.Viewer.from_key(k, { accounts: ChannelCast.accounts, now: 10 }) {
					Ok(v) => v
					Err(_) => crash "ChannelCast.keyed: a cast member's key stands"
				}
		}
	}
}

## Human `who`'s session to their account of generation 1, from its stored
## line, signed in at 0.
session_of : U64 -> Session
session_of = |who|
	match SessionCodec.decode(Str.to_utf8("session v1 id=${who.to_str()} human=${who.to_str()} generation=1 token=${Str.repeat("01", 32)} created=0 seen=0\n")) {
		Ok(line) => Session.load(line)
		Err(_) => crash "session_of: a test's session line decodes"
	}

expect ChannelCast.accounts.len() == 10
expect ChannelCast.viewer(Steve).who() == Session(ChannelCast.bound(Steve))
expect ChannelCast.viewer(Cc).who() == Key(ChannelCast.bound(Cc))

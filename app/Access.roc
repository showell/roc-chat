## **WHO MAY SEE A RESOURCE, AND WHO MAY ADD TO IT** (the Roc chat's auth
## design, sections 4 and 11), decided against a resource the core knows
## only by what it needs: its id, its participants, the humans they answer
## to, and its visibility. What the resource is (a conversation, a database,
## a file system) and how its visibility and owners are worked out are its
## layer's: the chat's is ConvAccess.roc, where a conversation's elections
## make it public or private and the accounts name each agent's owner.
##
## **THE VIEWER IS OPAQUE, MINTED ONLY FROM A CREDENTIAL**: `from_session`,
## from a live session the accounts admit, and `from_key`, from a key that
## stands (ApiKey), carrying its scope; and `signed_out`, which sees
## nothing. There is no viewer from an id, so a handler cannot claim an
## identity: every decision here, and the layer's on top of it, takes a
## Viewer. Each is bound to its accounts (Principal.Bound), so a viewer
## matches a participant only of the very account it was minted for.
##
## **A KEY'S READ OR POST IS DECIDED HERE** (`decide`): the key standing,
## its scope reaching the resource, and its principal allowed, in that
## order, each refusal said by name. The resource is the layer's own
## opaque value (the chat's ConvAccess.Conv), which makes the
## Access.Resource itself from the accounts (its `resource` method): never
## a record the caller built. Pure.
import ApiKey
import Cast
import KeyCodec
import Principal
import Session
import SessionCodec
import Stored

Access := [].{

	## **A RESOURCE, AS THE CORE DECIDES ON IT**: its id (the layer's own
	## type: the chat's ConvId), the principals in it, the humans they
	## answer to (the human participants, and the owners of its agents and
	## bots, as the accounts say now), each bound to its accounts, and its
	## visibility as its layer worked it out. Private or public, no more
	## granular.
	Resource(id) : {
		id : id,
		participants : List(Principal.Bound),
		involved : List(Principal.Bound),
		visibility : [Private, Public],
	}

	## **WHO IS ASKING**: nobody signed in; a human, by a live session; or a
	## principal, by a standing key, with the key's read and post reach.
	## Opaque: made only by `signed_out`, `from_session` and `from_key`.
	Viewer(id) :: [
		SignedOut,
		Session(Principal.Bound),
		Key(
			{
				who : Principal.Bound,
				read : [Off, On(ApiKey.Reach(id))],
				post : [Off, On(ApiKey.Reach(id))],
			},
		),
	].{

		## Nobody signed in: sees nothing, posts nothing.
		signed_out : {} -> Access.Viewer(id)
		signed_out = |{}| Access.Viewer.(SignedOut)

		## **THE HUMAN A SESSION SIGNS IN, NOW**: the session admitted
		## against the accounts (Session.admit: live, and its account the
		## one it was started for), with the session to write back when
		## `last seen` is stale.
		from_session : Session,
		ApiKey.AsOf -> Try(
			{ viewer : Access.Viewer(id), write : [Unchanged, Touched(Session)] },
			[SessionExpired, NoSuchAccount],
		)
		from_session = |session, as_of|
			match session.admit(as_of) {
				Refused(IdleExpired) | Refused(AbsoluteExpired) => Err(SessionExpired)
				Refused(NoSuchAccount) => Err(NoSuchAccount)
				Admitted({ principal, write }) => {
					g = Principal.generation(principal)
					Ok({
						viewer: Access.Viewer.(
							Session({
								id: Principal.id(principal),
								generation: g,
								human: g,
							}),
						),
						write,
					})
				}
			}

		## **THE PRINCIPAL A KEY ACTS AS, NOW**: the key live and standing
		## (ApiKey), with its read and post reach.
		from_key : ApiKey.Key(r, id), ApiKey.AsOf -> Try(Access.Viewer(id), ApiKey.Refusal)
		from_key = |key, as_of|
			match key.principal(as_of) {
				Err(Refused(why)) => Err(why)
				Ok(_) => {
					k = key.record()
					Ok(
						Access.Viewer.(
							Key({
								who: {
									id: k.acts_as,
									generation: k.generation,
									human: k.human_generation,
								},
								read: k.scope.read,
								post: k.scope.post,
							}),
						),
					)
				}
			}

		## Who the viewer is, and by which credential: what the layer's
		## elections and an audit read. Never its scope.
		who : Access.Viewer(id) -> [
			SignedOut,
			Session(Principal.Bound),
			Key(Principal.Bound),
		]
		who = |Access.Viewer.(v)|
			match v {
				SignedOut => SignedOut
				Session(b) => Session(b)
				Key(k) => Key(k.who)
			}
	}

	## **CAN THIS VIEWER SEE THIS RESOURCE?** A participant always can, and
	## so can the human it answers to (an owner can mint a key acting as
	## their agent, so hiding the agent's resources from them would be no
	## barrier); a public resource, any signed-in human or agent can, never
	## a bot that is not in it; nobody signed out can, whatever its
	## visibility; a key, only where its read reaches. An admin's role is no
	## part of it: an admin manages accounts and does not read private
	## conversations.
	can_see : Access.Viewer(id), Access.Resource(id) -> Bool where [id.is_eq : id, id -> Bool]
	can_see = |Access.Viewer.(v), resource|
		match v {
			SignedOut => Bool.False
			Session(who) => sees(who, resource)
			Key(k) => is_reached(k.read, resource.id) and sees(k.who, resource)
		}

	## **CAN THIS VIEWER ADD TO THIS RESOURCE?** A participant, or the
	## human it answers to: seeing is not posting, so public means
	## readable, never writable; a key, only where its post reaches.
	can_post : Access.Viewer(id), Access.Resource(id) -> Bool where [id.is_eq : id, id -> Bool]
	can_post = |Access.Viewer.(v), resource|
		match v {
			SignedOut => Bool.False
			Session(who) => is_answerable(resource, who)
			Key(k) => is_reached(k.post, resource.id) and is_answerable(resource, k.who)
		}

	## What a key is asked to do with a resource: read it, or post to it
	## (an admin action is ApiKey's `administers`). The resource is its
	## layer's own value, which makes the Access.Resource itself.
	Action(r) : [Read(r), Post(r)]

	## **MAY THIS KEY READ OR POST HERE, NOW?** In order: the key live and
	## standing (its principal, and the human it answers to, the very
	## accounts it was granted for); its scope reaching the resource; the
	## principal itself allowed it, on the resource as its layer makes it
	## from the accounts.
	decide : ApiKey.Key(r, id),
	{
		accounts : List(Principal),
		action : Access.Action(r),
		now : I64,
	} -> ApiKey.Verdict
		where [
			id.is_eq : id, id -> Bool,
			r.resource : r, List(Principal) -> Access.Resource(id),
		]
	decide = |
		key,
		{
			accounts,
			action,
			now,
		},
	|
		match Access.Viewer.from_key(key, { accounts, now }) {
			Err(why) => Refused(why)
			Ok(Access.Viewer.(SignedOut)) | Ok(Access.Viewer.(Session(_))) => crash "Access.decide: a key mints a key's viewer"
			Ok(Access.Viewer.(Key(k))) => {
				(
					reach,
					held,
					allowed,
				) =
					match action {
						Read(r) => (
							k.read,
							r,
							sees,
						)
						Post(r) => (
							k.post,
							r,
							is_answerable_by,
						)
					}
				resource = held.resource(accounts)
				if !is_reached(reach, resource.id) {
					Refused(OutOfScope)
				} else if allowed(k.who, resource) {
					Permitted
				} else {
					Refused(BeyondPrincipal)
				}
			}
		}
}

## The principal `who` may see the resource: answerable for it, or it is
## public and `who` a human or an agent.
sees : Principal.Bound, Access.Resource(id) -> Bool
sees = |who, resource|
	if is_answerable(resource, who) {
		Bool.True
	} else {
		match (resource.visibility, who.id) {
			(Public, Human(_)) | (Public, Agent(_)) => Bool.True
			(Public, Bot(_)) | (Private, _) => Bool.False
		}
	}

## `is_answerable`, `who` first, as `sees` takes it.
is_answerable_by : Principal.Bound, Access.Resource(id) -> Bool
is_answerable_by = |who, resource| is_answerable(resource, who)

## `who` is among the resource's participants, or is a human one of them
## answers to: bound to the same accounts, never only the same id.
is_answerable : Access.Resource(id), Principal.Bound -> Bool
is_answerable = |resource, who|
	if List.contains(resource.participants, who) {
		Bool.True
	} else {
		match who.id {
			Human(_) => List.contains(resource.involved, who)
			Agent(_) | Bot(_) => Bool.False
		}
	}

## A read's or a post's part of a scope reaches the resource `id`.
is_reached : [Off, On(ApiKey.Reach(id))], id -> Bool where [id.is_eq : id, id -> Bool]
is_reached = |part, id|
	match part {
		Off => Bool.False
		On(Everywhere) => Bool.True
		On(Only(ids)) => List.contains(ids, id)
	}

# ── tests
## A test's human: GitHub id `n`, its role, its account generation `g`.
person : U64, { role : Principal.Role, g : U64 } -> Principal
person = |n, { role, g }|
	Principal.Human({
		id: Cast.gid(n),
		login: "h${n.to_str()}",
		name: "H${n.to_str()}",
		role,
		generation: Cast.gen(g),
	})

## `who`'s binding among `among`.
bound : List(Principal), Principal -> Principal.Bound
bound = |among, who|
	match Principal.bind(among, Principal.id(who)) {
		Ok(b) => b
		Err(_) => crash "bound: a test's principal has an account"
	}

## Human `who`'s session to their account of generation `g`, from its
## stored line, signed in at 0.
session_of : U64, U64 -> Session
session_of = |who, g|
	match SessionCodec.decode(Str.to_utf8("session v1 id=${who.to_str()} human=${who.to_str()} generation=${g.to_str()} token=${Str.repeat("01", 32)} created=0 seen=0\n")) {
		Ok(line) => Session.load(line)
		Err(_) => crash "session_of: a test's session line decodes"
	}

## A key acting as `acts_as`, granted by its owner's session among `among`.
key_for : List(Principal),
{
	acts_as : Principal,
	scope : ApiKey.Scope(id),
	expires : I64,
} -> ApiKey.Key(r, id)
key_for = |
	among,
	{
		acts_as,
		scope,
		expires,
	},
| {
	owner = Principal.answers_to(acts_as)
	g =
		match Principal.human_account(among, owner) {
			Ok(h) => h.generation.to_u64()
			Err(_) => crash "key_for: a test's key has an owner"
		}
	match ApiKey.Key.issue(
		{
			granter: Session(session_of(owner.to_u64(), g)),
			acts_as: Principal.id(acts_as),
			scope,
			accounts: among,
			now: 10,
		},
		{ key: Cast.kid(7), expires },
	) {
		Ok(k) => k
		Err(_) => crash "key_for: a test's key is grantable"
	}
}

## **A VIEWER, AS A HANDLER GETS ONE**: a human by their session, an agent
## or a bot by a key reaching everywhere; minted among `among` at 10.
viewer_of : List(Principal), Principal -> Access.Viewer(id)
viewer_of = |among, who|
	match who {
		Human(h) =>
			match Access.Viewer.from_session(
				session_of(h.id.to_u64(), h.generation.to_u64()),
				{ accounts: among, now: 10 },
			) {
				Ok({ viewer, write: _ }) => viewer
				Err(_) => crash "viewer_of: a test's session is admitted"
			}
		Agent(_) | Bot(_) => key_viewer(among, { acts_as: who, scope: everywhere({}) })
	}

## The viewer a key acting as `acts_as`, of `scope`, mints among `among`.
key_viewer : List(Principal), { acts_as : Principal, scope : ApiKey.Scope(id) } -> Access.Viewer(id)
key_viewer = |among, { acts_as, scope }|
	match Access.Viewer.from_key(
		key_for(
			among,
			{
				acts_as,
				scope,
				expires: 1000,
			},
		),
		{ accounts: among, now: 10 },
	) {
		Ok(viewer) => viewer
		Err(_) => crash "key_viewer: a test's key stands"
	}

everywhere : {} -> ApiKey.Scope(id)
everywhere = |{}| {
	read: On(Everywhere),
	post: On(Everywhere),
	admin: Off,
}

# ── THE CORE'S OWN TABLE, on a resource that is not a conversation: a file
# a file system names by its path (its id a Str), held by one human, and a
# file held by one agent. The viewers are nobody signed in, the human
# holder, a stranger, the agent holder, its owner, a stranger's agent, and
# a stranger's bot.
holder : Principal
holder = person(1, { role: Member, g: 1 })

stranger : Principal
stranger = person(2, { role: Member, g: 1 })

owner : Principal
owner = person(3, { role: Member, g: 1 })

agent_holder : Principal
agent_holder = Cast.owned(Agent, { id: 1, owner: 3 })

other_agent : Principal
other_agent = Cast.owned(Agent, { id: 2, owner: 2 })

other_bot : Principal
other_bot = Cast.owned(Bot, { id: 3, owner: 2 })

files : List(Principal)
files = [
	holder,
	stranger,
	owner,
	agent_holder,
	other_agent,
	other_bot,
]

private_file : Access.Resource(Str)
private_file = {
	id: "/notes/plan.md",
	participants: [bound(files, holder)],
	involved: [bound(files, holder)],
	visibility: Private,
}

public_file : Access.Resource(Str)
public_file = { ..private_file, visibility: Public }

## Held by agent 1, whom human 3 owns.
agents_file : Access.Resource(Str)
agents_file = {
	id: "/notes/agent.md",
	participants: [bound(files, agent_holder)],
	involved: [bound(files, owner)],
	visibility: Private,
}

## A test's answer, said as a word, so a table cell reads plainly.
sees_file : [Out, In(Principal)], Access.Resource(Str) -> [Visible, Hidden]
sees_file = |who, resource| {
	v =
		match who {
			Out => Access.Viewer.signed_out({})
			In(p) => viewer_of(files, p)
		}
	if Access.can_see(v, resource) Visible else Hidden
}

posts_file : [Out, In(Principal)], Access.Resource(Str) -> [Writable, ReadOnly]
posts_file = |who, resource| {
	v =
		match who {
			Out => Access.Viewer.signed_out({})
			In(p) => viewer_of(files, p)
		}
	if Access.can_post(v, resource) Writable else ReadOnly
}

# Seeing.
expect sees_file(Out, private_file) == Hidden
expect sees_file(In(holder), private_file) == Visible
expect sees_file(In(stranger), private_file) == Hidden
expect sees_file(In(other_agent), private_file) == Hidden
expect sees_file(In(other_bot), private_file) == Hidden
expect sees_file(Out, public_file) == Hidden
expect sees_file(In(holder), public_file) == Visible
expect sees_file(In(stranger), public_file) == Visible
expect sees_file(In(other_agent), public_file) == Visible
expect sees_file(In(other_bot), public_file) == Hidden
expect sees_file(In(agent_holder), agents_file) == Visible
expect sees_file(In(owner), agents_file) == Visible
expect sees_file(In(stranger), agents_file) == Hidden
expect sees_file(In(other_agent), agents_file) == Hidden

# Adding to it: the participant, and the human it answers to, public or not.
expect posts_file(Out, private_file) == ReadOnly
expect posts_file(In(holder), private_file) == Writable
expect posts_file(In(stranger), private_file) == ReadOnly
expect posts_file(Out, public_file) == ReadOnly
expect posts_file(In(holder), public_file) == Writable
expect posts_file(In(stranger), public_file) == ReadOnly
expect posts_file(In(other_agent), public_file) == ReadOnly
expect posts_file(In(agent_holder), agents_file) == Writable
expect posts_file(In(owner), agents_file) == Writable
expect posts_file(In(stranger), agents_file) == ReadOnly

# **A VIEWER IS ITS ACCOUNT'S** (round three's first): the holder made again
# (generation 2) is no participant of the file the old account held.
holder_again : List(Principal)
holder_again = [
	person(1, { role: Member, g: 2 }),
	stranger,
	owner,
	agent_holder,
	other_agent,
	other_bot,
]

expect !Access.can_see(viewer_of(holder_again, person(1, { role: Member, g: 2 })), private_file)
expect !Access.can_post(viewer_of(holder_again, person(1, { role: Member, g: 2 })), private_file)

# **NO VIEWER WITHOUT A CREDENTIAL** (round three's design point): an idle
# session, a session whose account is gone, and a revoked key mint none.
expect Access.Viewer.from_session(
	session_of(1, 1),
	{ accounts: files, now: Session.idle_secs },
).map_ok(|_| {}) == Err(SessionExpired)
expect Access.Viewer.from_session(
	session_of(1, 1),
	{ accounts: holder_again, now: 10 },
).map_ok(|_| {}) == Err(NoSuchAccount)
expect Access.Viewer.from_key(
	key_for(
		files,
		{
			acts_as: other_agent,
			scope: everywhere({}),
			expires: 1000,
		},
	).revoke(),
	{ accounts: files, now: 10 },
).map_ok(|v| v.who()) == Err(Revoked)
expect Access.Viewer.from_session(
	session_of(1, 1),
	{ accounts: files, now: 10 },
).map_ok(|r| r.viewer.who()) == Ok(Session(bound(files, holder)))
expect Access.Viewer.signed_out({}).who() == SignedOut
# A key's viewer reads only where its scope reaches, its principal's sight
# notwithstanding.
reads_plan : Access.Viewer(Str)
reads_plan = key_viewer(
	files,
	{
		acts_as: stranger,
		scope: {
			read: On(Only(["/notes/plan.md"])),
			post: Off,
			admin: Off,
		},
	},
)

expect Access.can_see(reads_plan, public_file)
expect !Access.can_see(reads_plan, { ..public_file, id: "/notes/other.md" })
expect !Access.can_post(reads_plan, { ..public_file, participants: [bound(files, stranger)] })
expect reads_plan.who() == Key(bound(files, stranger))

# ── THE KEY DECISION TABLE
## **A TEST'S RESOURCE**: a fixed Access.Resource, the accounts not asked.
## The chat's is ConvAccess.Conv, which makes its resource from the
## accounts; this one stands in for it here, where the core is tested
## without the chat. The keys here are `Key(Held, U64)`, so they decide on
## a Held and nothing else; a chat key (`Key(ConvAccess.Conv, ConvId)`)
## never takes a Held, nor anything but a Conv (ConvKey.roc).
Held :: Access.Resource(U64).{
	resource : Held, List(Principal) -> Access.Resource(U64)
	resource = |Held.(r), _accounts| r
}

# The cast: boss, an admin; ann, a member; boss's agent and bot; ann's
# agent.
# Three resources: 1 (`a`), private to ann_agent (and so to ann, its
# owner); 2 (`b`), private to boss; 3 (`c`), boss's and public.
res_a : Held
res_a = Held.(
	{
		id: 1,
		participants: [bound(Cast.accounts, Cast.ann_agent)],
		involved: [bound(Cast.accounts, Cast.ann)],
		visibility: Private,
	},
)

res_b : Held
res_b = Held.(
	{
		id: 2,
		participants: [bound(Cast.accounts, Cast.boss)],
		involved: [bound(Cast.accounts, Cast.boss)],
		visibility: Private,
	},
)

res_c : Held
res_c = Held.(
	{
		id: 3,
		participants: [bound(Cast.accounts, Cast.boss)],
		involved: [bound(Cast.accounts, Cast.boss)],
		visibility: Public,
	},
)

plain : ApiKey.Scope(U64)
plain = {
	read: On(Everywhere),
	post: On(Everywhere),
	admin: Off,
}

with_admin : ApiKey.Scope(U64)
with_admin = {
	read: On(Everywhere),
	post: On(Everywhere),
	admin: On,
}

admin_only : ApiKey.Scope(U64)
admin_only = {
	read: Off,
	post: Off,
	admin: On,
}

reads_c : ApiKey.Scope(U64)
reads_c = {
	read: On(Only([3])),
	post: Off,
	admin: Off,
}

posts_a : ApiKey.Scope(U64)
posts_a = {
	read: Off,
	post: On(Only([1])),
	admin: Off,
}

## A key acting as `acts_as`, granted among the cast.
issued : { acts_as : Principal, scope : ApiKey.Scope(U64) }, I64 -> ApiKey.Key(Held, U64)
issued = |{ acts_as, scope }, expires| key_for(
	Cast.accounts,
	{
		acts_as,
		scope,
		expires,
	},
)

Answer : [Permitted, Refused(ApiKey.Refusal)]

## The key's answer to `action` at `now`, among `accounts`.
decided_at : ApiKey.Key(Held, U64), { action : Access.Action(Held), now : I64 } -> Answer
decided_at = |key, { action, now }| Access.decide(
	key,
	{
		accounts: Cast.accounts,
		action,
		now,
	},
)

## The key's answer to `action` at time 50, among `accounts`.
decided : ApiKey.Key(Held, U64), Access.Action(Held) -> Answer
decided = |key, action| decided_at(key, { action, now: 50 })

## The key's answer to `action` at time 50, among `among`.
decided_among : ApiKey.Key(Held, U64), Access.Action(Held), List(Principal) -> Answer
decided_among = |
	key,
	action,
	among,
| Access.decide(
	key,
	{
		accounts: among,
		action,
		now: 50,
	},
)

# ann_agent, reading and posting everywhere: as far as ann_agent may.
ann_agent_plain : ApiKey.Key(Held, U64)
ann_agent_plain = issued({ acts_as: Cast.ann_agent, scope: plain }, 1000)

expect decided(ann_agent_plain, Read(res_a)) == Permitted
expect decided(ann_agent_plain, Read(res_b)) == Refused(BeyondPrincipal)
expect decided(ann_agent_plain, Read(res_c)) == Permitted
expect decided(ann_agent_plain, Post(res_a)) == Permitted
expect decided(ann_agent_plain, Post(res_b)) == Refused(BeyondPrincipal)
expect decided(ann_agent_plain, Post(res_c)) == Refused(BeyondPrincipal)

# ann_agent, reading `c` alone.
ann_agent_reads_c : ApiKey.Key(Held, U64)
ann_agent_reads_c = issued({ acts_as: Cast.ann_agent, scope: reads_c }, 1000)

expect decided(ann_agent_reads_c, Read(res_a)) == Refused(OutOfScope)
expect decided(ann_agent_reads_c, Read(res_b)) == Refused(OutOfScope)
expect decided(ann_agent_reads_c, Read(res_c)) == Permitted
expect decided(ann_agent_reads_c, Post(res_a)) == Refused(OutOfScope)
expect decided(ann_agent_reads_c, Post(res_b)) == Refused(OutOfScope)
expect decided(ann_agent_reads_c, Post(res_c)) == Refused(OutOfScope)

# ann_agent, posting to `a` alone.
ann_agent_posts_a : ApiKey.Key(Held, U64)
ann_agent_posts_a = issued({ acts_as: Cast.ann_agent, scope: posts_a }, 1000)

expect decided(ann_agent_posts_a, Read(res_a)) == Refused(OutOfScope)
expect decided(ann_agent_posts_a, Read(res_b)) == Refused(OutOfScope)
expect decided(ann_agent_posts_a, Read(res_c)) == Refused(OutOfScope)
expect decided(ann_agent_posts_a, Post(res_a)) == Permitted
expect decided(ann_agent_posts_a, Post(res_b)) == Refused(OutOfScope)
expect decided(ann_agent_posts_a, Post(res_c)) == Refused(OutOfScope)

# ann herself, reading and posting everywhere: her agent's `a` too, as its
# owner (decision 1).
ann_year : ApiKey.Key(Held, U64)
ann_year = issued({ acts_as: Cast.ann, scope: plain }, 1000)

expect decided(ann_year, Read(res_a)) == Permitted
expect decided(ann_year, Read(res_b)) == Refused(BeyondPrincipal)
expect decided(ann_year, Read(res_c)) == Permitted
expect decided(ann_year, Post(res_a)) == Permitted
expect decided(ann_year, Post(res_b)) == Refused(BeyondPrincipal)
expect decided(ann_year, Post(res_c)) == Refused(BeyondPrincipal)

# boss, everything and admin: an admin still reads no private resource it
# is not in (`a`).
boss_all : ApiKey.Key(Held, U64)
boss_all = issued({ acts_as: Cast.boss, scope: with_admin }, 1000)

expect decided(boss_all, Read(res_a)) == Refused(BeyondPrincipal)
expect decided(boss_all, Read(res_b)) == Permitted
expect decided(boss_all, Read(res_c)) == Permitted
expect decided(boss_all, Post(res_a)) == Refused(BeyondPrincipal)
expect decided(boss_all, Post(res_b)) == Permitted
expect decided(boss_all, Post(res_c)) == Permitted

# boss_agent, admin alone: reads and posts nothing.
boss_agent_admin : ApiKey.Key(Held, U64)
boss_agent_admin = issued({ acts_as: Cast.boss_agent, scope: admin_only }, 1000)

expect decided(boss_agent_admin, Read(res_a)) == Refused(OutOfScope)
expect decided(boss_agent_admin, Read(res_b)) == Refused(OutOfScope)
expect decided(boss_agent_admin, Read(res_c)) == Refused(OutOfScope)
expect decided(boss_agent_admin, Post(res_a)) == Refused(OutOfScope)
expect decided(boss_agent_admin, Post(res_b)) == Refused(OutOfScope)
expect decided(boss_agent_admin, Post(res_c)) == Refused(OutOfScope)

# boss_bot, reading everywhere: a bot reads a public resource only when it
# is in it (decision 3).
boss_bot_plain : ApiKey.Key(Held, U64)
boss_bot_plain = issued({ acts_as: Cast.boss_bot, scope: plain }, 1000)

expect decided(boss_bot_plain, Read(res_c)) == Refused(BeyondPrincipal)

# Bug 1: ann retired, her agent's key reads and posts nothing, even what
# its scope and the resource would allow.
expect decided_among(
	ann_agent_plain,
	Read(res_a),
	Cast.without_ann,
) == Refused(NoSuchPrincipal)
expect decided_among(
	ann_agent_plain,
	Read(res_c),
	Cast.without_ann,
) == Refused(NoSuchPrincipal)
expect decided_among(
	ann_agent_plain,
	Post(res_a),
	Cast.without_ann,
) == Refused(NoSuchPrincipal)

# Liveness comes first: revoked and expired keys do nothing, even what
# their scope and principal would allow; an expiry at 100 is live at 99.
boss_until_100 : ApiKey.Key(Held, U64)
boss_until_100 = issued({ acts_as: Cast.boss, scope: with_admin }, 100)

expect decided(boss_all.revoke(), Read(res_c)) == Refused(Revoked)
expect decided_at(boss_until_100, { action: Read(res_c), now: 99 }) == Permitted
expect decided_at(boss_until_100, { action: Read(res_c), now: 100 }) == Refused(Expired)

# A stored line claiming admin for ann, a member, reads no more than ann;
# a narrowed line loads narrowed.
from_store : ApiKey.Record(U64) -> ApiKey.Key(Held, U64)
from_store = |record|
	match KeyCodec.decode(KeyCodec.encode({ record, hash: Cast.token(9) }, |n| n), |n| Ok(n)) {
		Ok(line) => ApiKey.Key.load(line)
		Err(_) => crash "from_store: a test's key line decodes"
	}

expect decided(
	from_store({ ..ann_year.record(), scope: with_admin }),
	Read(res_b),
) == Refused(BeyondPrincipal)
expect decided(from_store(ann_agent_reads_c.record()), Read(res_a)) == Refused(OutOfScope)

# A forged copy of ann's agent beside it, or ann made again: the old key
# stands no more.
expect decided_among(
	ann_agent_plain,
	Read(res_a),
	List.prepend(Cast.accounts, Cast.owned(Agent, { id: 3, owner: 1 })),
) == Refused(NoSuchPrincipal)
expect decided_among(
	ann_year,
	Read(res_c),
	[
		Cast.boss,
		person(2, { role: Member, g: 2 }),
		Cast.boss_agent,
		Cast.boss_bot,
		Cast.ann_agent,
	],
) == Refused(NoSuchPrincipal)

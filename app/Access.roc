## **WHO IS ASKING** (the Roc chat's auth design, sections 4 and 11): the
## viewer every decision takes. **A KEY SAYS WHO YOU ARE** (Steve,
## 2026-11-01): what the viewer may reach is the chat's other rules' (a
## channel's members, Topic.roc), asked of `who`; a key adds only whether
## its read and its post are on (`reach`).
##
## **THE VIEWER IS OPAQUE, MINTED ONLY FROM A CREDENTIAL**: `from_session`,
## from a live session the accounts admit, and `from_key`, from a key that
## stands (ApiKey), carrying its read and post; and `signed_out`, which
## reaches nothing. There is no viewer from an id, so a handler cannot
## claim an identity. Each is bound to its accounts (Principal.Bound), so a
## viewer matches a member only of the very account it was minted for.
## Pure.
import ApiKey
import Cast
import Principal
import Session

Access := [].{

	## **WHO IS ASKING**: nobody signed in; a human, by a live session; or a
	## principal, by a standing key, with the key's read and post.
	## Opaque: made only by `signed_out`, `from_session` and `from_key`.
	Viewer :: [
		SignedOut,
		Session(Principal.Bound),
		Key(
			{
				who : Principal.Bound,
				read : [Off, On],
				post : [Off, On],
			},
		),
	].{

		## Nobody signed in: reaches nothing.
		signed_out : Access.Viewer
		signed_out = Access.Viewer.(SignedOut)

		## **THE HUMAN A SESSION SIGNS IN, NOW**: the session admitted
		## against the accounts (Session.admit: live, and its account the
		## one it was started for), with the session to write back when
		## `last seen` is stale.
		from_session : Session,
		ApiKey.AsOf -> Try(
			{ viewer : Access.Viewer, write : [Unchanged, Touched(Session)] },
			[SessionExpired, NoSuchAccount],
		)
		from_session = |session, as_of|
			match session.admit(as_of) {
				Refused(IdleExpired) | Refused(AbsoluteExpired) => Err(SessionExpired)
				Refused(NoSuchAccount) => Err(NoSuchAccount)
				Admitted({ principal, write }) => {
					g = principal.generation()
					Ok({
						viewer: Access.Viewer.(
							Session({
								id: principal.id(),
								generation: g,
								human: g,
							}),
						),
						write,
					})
				}
			}

		## **THE PRINCIPAL A KEY ACTS AS, NOW**: the key live and standing
		## (ApiKey), with its read and post.
		from_key : ApiKey.Key, ApiKey.AsOf -> Try(Access.Viewer, _)
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

		## Who the viewer is, and by which credential: what the chat's rules
		## and an audit read. Never its scope.
		who : Access.Viewer -> [
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

		## **DOES THE CREDENTIAL READ, OR POST, AT ALL?** A session does, as
		## its human; a key, where its read or its post is on; nobody signed
		## out, never. Asked by a layer that names each refusal itself
		## (Topic.roc), before it decides on the principal.
		reach : Access.Viewer,
		[Read, Post] -> [
			Reaches,
			OutOfScope,
			SignedOut,
		]
		reach = |Access.Viewer.(v), act|
			match v {
				SignedOut => SignedOut
				Session(_) => Reaches
				Key(k) => {
					part =
						match act {
							Read => k.read
							Post => k.post
						}
					if (part == On) Reaches else OutOfScope
				}
			}
	}
}

# ── tests
## A test's human: id `n`, a member, its account generation `g`.
person : U64, { g : U64 } -> Principal
person = |n, { g }|
	Principal.Human({
		id: Cast.hid(n),
		sign_in: Cast.github(n),
		login: "h${n.to_str()}",
		name: "H${n.to_str()}",
		role: Member,
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
	match Session.decode(Str.to_utf8("session v1 id=${who.to_str()} human=${who.to_str()} generation=${g.to_str()} token=${Str.repeat("01", 32)} created=0 seen=0\n")) {
		Ok(session) => session
		Err(_) => crash "session_of: a test's session line decodes"
	}

## A key acting as `acts_as`, granted by its owner's session among `among`.
key_for : List(Principal),
{
	acts_as : Principal,
	scope : ApiKey.Scope,
	expires : I64,
} -> ApiKey.Key
key_for = |
	among,
	{
		acts_as,
		scope,
		expires,
	},
| {
	owner = acts_as.answers_to()
	g =
		match Principal.human_account(among, owner) {
			Ok(h) => h.generation.to_u64()
			Err(_) => crash "key_for: a test's key has an owner"
		}
	match ApiKey.Key.issue(
		{
			granter: Session(session_of(owner.to_u64(), g)),
			acts_as: acts_as.id(),
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

## The viewer a key acting as `acts_as`, of `scope`, mints among `among`.
key_viewer : List(Principal), { acts_as : Principal, scope : ApiKey.Scope } -> Access.Viewer
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

## A human, a stranger, and the stranger's agent.
holder : Principal
holder = person(1, { g: 1 })

stranger : Principal
stranger = person(2, { g: 1 })

other_agent : Principal
other_agent = Cast.owned(Agent, { id: 2, owner: 2 })

accounts : List(Principal)
accounts = [
	holder,
	stranger,
	other_agent,
]

## Accounts with the holder made again (generation 2).
holder_again : List(Principal)
holder_again = [
	person(1, { g: 2 }),
	stranger,
	other_agent,
]

## The agent's key, reading and not posting.
reads_only : Access.Viewer
reads_only = key_viewer(
	accounts,
	{
		acts_as: other_agent,
		scope: {
			read: On,
			post: Off,
		},
	},
)

# **NO VIEWER WITHOUT A CREDENTIAL**: an idle
# session, a session whose account is gone, and a revoked key mint none.
expect Access.Viewer.from_session(
	session_of(1, 1),
	{ accounts, now: Session.idle_secs },
).map_ok(|_| {}) == Err(SessionExpired)
expect Access.Viewer.from_session(
	session_of(1, 1),
	{ accounts: holder_again, now: 10 },
).map_ok(|_| {}) == Err(NoSuchAccount)
expect Access.Viewer.from_key(
	key_for(
		accounts,
		{
			acts_as: other_agent,
			scope: {
				read: On,
				post: On,
			},
			expires: 1000,
		},
	).revoke(),
	{ accounts, now: 10 },
).map_ok(|v| v.who()) == Err(Revoked)

# **A VIEWER IS ITS ACCOUNT'S**: a session's, the account it signed in;
# a key's, the principal it acts as; nobody, signed out.
expect Access.Viewer.from_session(
	session_of(1, 1),
	{ accounts, now: 10 },
).map_ok(|r| r.viewer.who()) == Ok(Session(bound(accounts, holder)))
expect reads_only.who() == Key(bound(accounts, other_agent))
expect Access.Viewer.signed_out.who() == SignedOut

# **REACH**: a key's read and post, each on or off; a session reaches as
# its human; nobody signed out, nothing.
expect reads_only.reach(Read) == Reaches
expect reads_only.reach(Post) == OutOfScope
expect
	key_viewer(
		accounts,
		{
			acts_as: other_agent,
			scope: {
				read: Off,
				post: On,
			},
		},
	).reach(Read)
		== OutOfScope
expect
	match Access.Viewer.from_session(session_of(1, 1), { accounts, now: 10 }) {
		Ok({ viewer, write: _ }) => viewer.reach(Post) == Reaches and viewer.reach(Read) == Reaches
		Err(_) => Bool.False
	}
expect Access.Viewer.signed_out.reach(Read) == SignedOut
expect Access.Viewer.signed_out.reach(Post) == SignedOut

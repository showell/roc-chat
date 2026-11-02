## **AN API KEY**: a key acts as one principal, with a scope of read and
## post, each on or off. **A KEY SAYS WHO YOU ARE** (Steve,
## 2026-11-01): what its holder may reach is the chat's other rules' (a
## channel's members, Topic.roc), on the viewer the key mints (Access);
## it never exceeds its principal.
##
## **ONLY TWO WAYS IN:** `issue`, which asks `may_grant` (a live browser
## session, never a key, for the granter's own principals), and `decode`,
## from a stored line, every field checked. There is no constructor from a record, so no
## handler mints a key, an admin's or anyone's, without a grant or a line
## in the store.
##
## **A KEY IS ITS ACCOUNTS'**: it holds the generation of its principal's
## account and of the human's it answers to (Principal.Bound), and stands
## only while those very accounts do (Principal.holds); an id retired and
## made again, a human's or an agent's, never revives the old keys.
##
## The key's secret and its hash are the host's; this is the record the
## Roc decides on, and its line. Pure.
import Account
import Cast
import Principal
import Session
import Stored

ApiKey := [].{

	## **WHAT A KEY MAY DO**, each part on or off.
	Scope : {
		read : [Off, On],
		post : [Off, On],
	}

	## **THE LONGEST A KEY LIVES**, in seconds: 365 days. Every key expires
	## (no grant makes one that never does), so a key lost or forgotten is
	## good for a year at most, and its expiry always fits the store.
	max_lifetime_secs : I64
	max_lifetime_secs = 31536000

	## **AN EXPIRY A GRANT MAKES**: after the key's creation, at most
	## `max_lifetime_secs` after it, and no later than Stored's last time.
	## The one home of the rule: the grant asks it (ApiKey.Key.issue), and
	## the decoder refuses a line that breaks it, as no grant wrote one.
	is_fitting_expiry : { created : I64, expires : I64 } -> Bool
	is_fitting_expiry = |{ created, expires }|
		expires > created and expires.to_i128() - created.to_i128() <= ApiKey.max_lifetime_secs.to_i128() and expires <= Stored.max_time

	## **A KEY'S WHOLE RECORD**: its id, the principal it acts as, the
	## generations it is bound to, its scope, when it was made and when it
	## expires (unix seconds: expired from then on), and its revocation.
	Record : {
		id : Principal.KeyId,
		acts_as : Principal.Id,
		generation : Principal.Generation,
		human_generation : Principal.Generation,
		scope : ApiKey.Scope,
		created : I64,
		expires : I64,
		revocation : [Active, Revoked],
	}

	## **A READ'S OR A POST'S REACH, IN ITS ONE SPELLING** (`everywhere`,
	## `off`): what a line holds, and what a grant's form and a key's
	## listing say.
	reach_text : [Off, On] -> Str
	reach_text = |part| spell_reach(part)

	## The reach a spelling names, as the decoder reads a line's, and a
	## grant's form.
	reach_from : List(U8), Str -> Try([Off, On], _)
	reach_from = |value, name|
		Stored.word(
			value,
			{
				name,
				members: all_switches,
				spell: spell_reach,
			},
		)

	## **WHAT THE STORE KEEPS OF A KEY**: the key, and the hash of its
	## secret, which the host looks it up by and names its file for.
	Entry : {
		key : ApiKey.Key,
		hash : Stored.SecretHash,
	}

	## **A KEY'S LINE**, in Stored's format, the secret's hash and never the
	## secret, which its owner is shown once:
	##
	##     key v1 id=4 acts=agent:7 generation=4 human-generation=3 hash=<64 hex digits> created=1761600000 expires=1793136000 state=active read=everywhere post=off
	##
	## `generation` is the generation of its principal's account, and
	## `human-generation` that of the human it answers to (itself, or the
	## owner of its agent or bot), when it was granted (Principal.Bound). A
	## human's key holds one generation twice; a line whose two differ is
	## refused, as no grant makes one. One spelling per value: a read or a
	## post is `everywhere` or `off`.
	encode : ApiKey.Entry -> List(U8)
	encode = |{ key, hash }| {
		record = key.record()
		Stored.line(
			"key",
			[
				("id", record.id.to_u64().to_str()),
				("acts", Account.id_text(record.acts_as)),
				("generation", record.generation.to_u64().to_str()),
				("human-generation", record.human_generation.to_u64().to_str()),
				("hash", Stored.hash_text(hash)),
				("created", Stored.time_text(record.created)),
				("expires", Stored.time_text(record.expires)),
				("state", spell_revocation(record.revocation)),
				("read", spell_reach(record.scope.read)),
				("post", spell_reach(record.scope.post)),
			],
		)
	}

	## **A KEY AS ITS STORED LINE HOLDS IT**, or the line's problem: the
	## line's principal, accounts, scope, expiry and revocation exactly,
	## nothing added and nothing widened. No grant is asked again: the line
	## was written from a key `issue` granted, and every use is still held to
	## its principal as the accounts say then, so a line claiming more than
	## its principal may do does no more. A line proves its checks ran, not
	## that its bytes came from the store.
	decode : List(U8) -> Try(ApiKey.Entry, _)
	decode = |raw| {
		fields = Stored.Reader.open(raw, "key")?
		id_field = fields.field("id")?
		id = Stored.id(id_field.value, { name: "id", make: Principal.KeyId.from_u64 })?
		acts_field = id_field.rest.field("acts")?
		acts_as = Account.id_from(acts_field.value, "acts")?
		generation_field = acts_field.rest.field("generation")?
		generation = Stored.id(
			generation_field.value,
			{ name: "generation", make: Principal.Generation.from_u64 },
		)?
		human_field = generation_field.rest.field("human-generation")?
		human_generation = Stored.id(
			human_field.value,
			{ name: "human-generation", make: Principal.Generation.from_u64 },
		)?
		hash_field = human_field.rest.field("hash")?
		hash = Stored.hash(hash_field.value, "hash")?
		created_field = hash_field.rest.field("created")?
		created = Stored.time(created_field.value, "created")?
		expires_field = created_field.rest.field("expires")?
		expires = Stored.time(expires_field.value, "expires")?
		state_field = expires_field.rest.field("state")?
		revocation = Stored.word(
			state_field.value,
			{
				name: "state",
				members: all_revocations,
				spell: spell_revocation,
			},
		)?
		read_field = state_field.rest.field("read")?
		read = ApiKey.reach_from(read_field.value, "read")?
		post_field = read_field.rest.field("post")?
		post = ApiKey.reach_from(post_field.value, "post")?
		post_field.rest.close()?
		match acts_as {
			Human(_) if generation != human_generation => Err(BadValue("human-generation"))
			_ if !ApiKey.is_fitting_expiry({ created, expires }) => Err(BadValue("expires"))
			_ =>
				Ok({
					key: ApiKey.Key.(
						{
							id,
							acts_as,
							generation,
							human_generation,
							scope: {
								read,
								post,
							},
							created,
							expires,
							revocation,
						},
					),
					hash,
				})
		}
	}

	## **WHO ASKS FOR A KEY**: the credential the request came with. Only a
	## browser's session mints keys; a key asking is refused, whatever its
	## scope, so a stolen key cannot mint a wider one.
	Granter : [Session(Session), Key(ApiKey.Key)]

	## A request for a key: who asks, the principal the key would act as,
	## its scope, and the accounts and the time now.
	Grant : {
		granter : ApiKey.Granter,
		acts_as : Principal.Id,
		scope : ApiKey.Scope,
		accounts : List(Principal),
		now : I64,
	}

	## Why a grant is refused. **ONE ALIAS ON PURPOSE**: ApiKey, Agents and
	## the audit share it, and AuditLog spells each tag (`all_grant_refusals`).
	GrantRefusal : [
		## A key asked: keys are minted only from a browser session.
		GrantedByKey,

		## The session is over (idle, or past its week).
		SessionExpired,

		## The session's account is not among the accounts now (retired, or
		## made again since, or held twice).
		NoSuchGranter,

		## A human grants for themselves and for the agents and bots they own.
		NotTheGrantersOwn,

		## The principal is not among the accounts, exactly once (never made,
		## retired, or a forged copy beside it).
		NoSuchPrincipal,

		## The clock is outside Stored's range (before 1970 or past 9999):
		## nothing it would write could be stored.
		ClockOutOfRange,

		## The expiry is not after now, or more than a year after it
		## (ApiKey.max_lifetime_secs), or past Stored's last time: every key
		## expires, within a year, at a time the store can write.
		BadExpiry,
	]

	## What a key's use is decided against: the accounts, and the time,
	## now.
	AsOf : { accounts : List(Principal), now : I64 }

	## A key's answer.
	Verdict : [Permitted, Refused(ApiKey.Refusal)]

	## Why a key may not do what it was asked. **ONE ALIAS ON PURPOSE**:
	## Access, Admin and the audit share it, and AuditLog spells each tag
	## (`all_key_refusals`).
	Refusal : [
		Revoked,
		Expired,

		## The key's principal, or the account of the human it answers to,
		## is not among the accounts any more, exactly once, as the one the
		## key was granted for.
		NoSuchPrincipal,

		## The key's scope does not reach it.
		OutOfScope,

		## The scope reaches it, but the principal itself may not.
		BeyondPrincipal,
	]

	## **MAY THIS GRANTER GIVE A KEY ACTING AS `acts_as` THIS SCOPE?** Only
	## a live session, of the account it was started for, for themselves
	## and for the agents and bots they own. Read and post need no check here: a key's every use is
	## held to its principal.
	may_grant : ApiKey.Grant -> [Grantable, Refused(ApiKey.GrantRefusal)]
	may_grant = |grant|
		match granted(grant) {
			Ok(_) => Grantable
			Err(why) => Refused(why)
		}

	## **A KEY, AS A STATE MACHINE**: opaque, so `issue` (which asks
	## `may_grant`) is the one way in, `load` (from a stored line) the way
	## back, and `revoke` the one transition.
	Key :: ApiKey.Record.{

		## A new key, active, made `now`, when the grant is grantable and the
		## expiry fits (ApiKey.is_fitting_expiry); bound to its accounts.
		issue : ApiKey.Grant,
		{ key : Principal.KeyId, expires : I64 } -> Try(
			ApiKey.Key,
			[Refused(ApiKey.GrantRefusal)],
		)
		issue = |grant, { key, expires }|
			match granted(grant) {
				Err(why) => Err(Refused(why))
				Ok(_) if !ApiKey.is_fitting_expiry({
					created: grant.now,
					expires,
				}) => Err(Refused(BadExpiry))
				Ok(bound) =>
					Ok(
						ApiKey.Key.(
							{
								id: key,
								acts_as: grant.acts_as,
								generation: bound.generation,
								human_generation: bound.human,
								scope: grant.scope,
								created: grant.now,
								expires: expires,
								revocation: Active,
							},
						),
					)
			}

		## The key's whole record, to store.
		record : ApiKey.Key -> ApiKey.Record
		record = |ApiKey.Key.(k)| k

		## The only transition: revoked, for good.
		revoke : ApiKey.Key -> ApiKey.Key
		revoke = |ApiKey.Key.(k)| ApiKey.Key.({ ..k, revocation: Revoked })

		## The key's public id.
		id : ApiKey.Key -> Principal.KeyId
		id = |ApiKey.Key.(k)| k.id

		## The principal it acts as.
		acts_as : ApiKey.Key -> Principal.Id
		acts_as = |ApiKey.Key.(k)| k.acts_as

		## **IS THE KEY LIVE AT `now`?** Revoked is said first, expired or
		## not; an expiry at `t` is live before `t` and expired from `t` on.
		liveness : ApiKey.Key,
		I64 -> [
			Live,
			Expired,
			Revoked,
		]
		liveness = |ApiKey.Key.(k), now|
			match k.revocation {
				Revoked => Revoked
				Active => if (now < k.expires) Live else Expired
			}

		## **THE PRINCIPAL A STANDING KEY ACTS AS**, as the accounts have
		## it now (Access's viewer).
		principal : ApiKey.Key, ApiKey.AsOf -> Try(Principal, [Refused(ApiKey.Refusal)])
		principal = |key, as_of|
			match standing(key, as_of) {
				Standing(p) => Ok(p)
				Refused(why) => Err(Refused(why))
			}
	}
}

## **THE GRANT, DECIDED**: the principal, bound to the accounts the key
## will stand on, or why not.
granted : ApiKey.Grant -> Try(Principal.Bound, _)
granted = |
	{
		granter,
		acts_as,
		scope: _,
		accounts,
		now,
	},
|
	match granter {
		_ if now < 0 or now > Stored.max_time => Err(ClockOutOfRange)
		Key(_) => Err(GrantedByKey)
		Session(session) =>
			match session.admit({ accounts, now }) {
				Refused(IdleExpired) | Refused(AbsoluteExpired) => Err(SessionExpired)
				Refused(NoSuchAccount) => Err(NoSuchGranter)
				Admitted({ principal: human, write: _ }) =>
				# The principal as the accounts have it now: its owner and
				# its authority are theirs, not the caller's copy.
					match (
						human,
						Principal.find(accounts, acts_as),
						Principal.bind(accounts, acts_as),
					) {
						(
							_,
							Err(_),
							_,
						)
						| (
							_,
							_,
							Err(_),
						) => Err(NoSuchPrincipal)
						(
							Human(h),
							Ok(current),
							Ok(bound),
						) =>
							if Principal.answers_to(current) != h.id {
								Err(NotTheGrantersOwn)
							} else {
								Ok(bound)
							}
						(
							Agent(_),
							_,
							_,
						)
						| (
							Bot(_),
							_,
							_,
						) => crash "ApiKey.granted: a session admits a human"
					}
			}
	}

## **A KEY'S PRINCIPAL, STANDING NOW**: the key live at `now`, and its
## binding still holding (Principal.holds): the principal it acts as, and
## the human it answers to (a human, itself; an agent or a bot, its owner),
## each held by exactly one account, of the generation the key was granted
## for.
standing : ApiKey.Key, ApiKey.AsOf -> [Standing(Principal), Refused(ApiKey.Refusal)]
standing = |key, { accounts, now }| {
	ApiKey.Key.(k) = key
	match key.liveness(now) {
		Revoked => Refused(Revoked)
		Expired => Refused(Expired)
		Live =>
			match Principal.holds(
				accounts,
				{
					id: k.acts_as,
					generation: k.generation,
					human: k.human_generation,
				},
			) {
				Err(_) => Refused(NoSuchPrincipal)
				Ok(principal) => Standing(principal)
			}
	}
}

Revocation : [Active, Revoked]

all_revocations : List(Revocation)
all_revocations = [Active, Revoked]

spell_revocation : Revocation -> Str
spell_revocation = |r|
	match r {
		Active => "active"
		Revoked => "revoked"
	}

Switch : [Off, On]

all_switches : List(Switch)
all_switches = [Off, On]

## **THE ONE SPELLING OF A REACH**: `everywhere` on, `off` off.
spell_reach : Switch -> Str
spell_reach = |s|
	match s {
		Off => "off"
		On => "everywhere"
	}

# ── tests
# The cast:
#   boss        an admin human
#   ann         a member human
#   boss_agent  an agent boss owns
#   boss_bot    a bot boss owns
#   ann_agent   an agent ann owns
## Human `who`'s browser session `n`, signed in at time 0 to the account
## made at 1, as the store holds it (a session's only way in but the flow).
signed_in : { n : U64, who : U64 } -> ApiKey.Granter
signed_in = |{ n, who }|
	stored_session("session v1 id=${n.to_str()} human=${who.to_str()} generation=1 token=${"07".repeat(32)} created=0 seen=0\n")

## Human `who`'s session, signed in at `at` to the account of generation
## 1, from its stored line.
session_at : U64, I64 -> Session
session_at = |who, at|
	match Session.decode(Str.to_utf8("session v1 id=3 human=${who.to_str()} generation=1 token=${Str.repeat("07", 32)} created=${at.to_str()} seen=${at.to_str()}\n")) {
		Ok(session) => session
		Err(_) => crash "session_at: a test's session line decodes"
	}

## The session a stored line holds, as a granter.
stored_session : Str -> ApiKey.Granter
stored_session = |text|
	match Session.decode(Str.to_utf8(text)) {
		Ok(session) => Session(session)
		Err(_) => crash "stored_session: a test's session line decodes"
	}

by_boss : ApiKey.Granter
by_boss = signed_in({ n: 1, who: 1 })

by_ann : ApiKey.Granter
by_ann = signed_in({ n: 2, who: 2 })

# The scopes the tables use.
plain : ApiKey.Scope
plain = {
	read: On,
	post: On,
}

mute : ApiKey.Scope
mute = {
	read: Off,
	post: Off,
}

reads : ApiKey.Scope
reads = {
	read: On,
	post: Off,
}

GrantAnswer : [Grantable, Refused(ApiKey.GrantRefusal)]

## `granter` asks for a key acting as `acts_as`, among `among`, at `now`.
grant_at : ApiKey.Granter,
{
	acts_as : Principal,
	scope : ApiKey.Scope,
	among : List(Principal),
	now : I64,
} -> GrantAnswer
grant_at = |
	granter,
	{
		acts_as,
		scope,
		among,
		now,
	},
|
	ApiKey.may_grant({
		granter,
		acts_as: acts_as.id(),
		scope,
		accounts: among,
		now,
	})

## `granter` asks for a key acting as `acts_as`, among `accounts`, at 50.
grant : ApiKey.Granter, { acts_as : Principal, scope : ApiKey.Scope } -> GrantAnswer
grant = |granter, { acts_as, scope }|
	grant_at(
		granter,
		{
			acts_as,
			scope,
			among: Cast.accounts,
			now: 50,
		},
	)

# ── THE GRANT TABLE
# Every granter against every principal a key could act as.

# boss's session: their own, their agent's and their bot's.
expect grant(by_boss, { acts_as: Cast.boss, scope: plain }) == Grantable
expect grant(by_boss, { acts_as: Cast.ann, scope: plain }) == Refused(NotTheGrantersOwn)
expect grant(by_boss, { acts_as: Cast.boss_agent, scope: plain }) == Grantable
expect grant(by_boss, { acts_as: Cast.boss_bot, scope: plain }) == Grantable
expect grant(by_boss, { acts_as: Cast.ann_agent, scope: plain }) == Refused(NotTheGrantersOwn)

# ann's session: her own and her agent's, whatever the scope.
expect grant(by_ann, { acts_as: Cast.boss, scope: plain }) == Refused(NotTheGrantersOwn)
expect grant(by_ann, { acts_as: Cast.ann, scope: plain }) == Grantable
expect grant(by_ann, { acts_as: Cast.ann, scope: mute }) == Grantable
expect grant(by_ann, { acts_as: Cast.boss_agent, scope: plain }) == Refused(NotTheGrantersOwn)
expect grant(by_ann, { acts_as: Cast.boss_bot, scope: plain }) == Refused(NotTheGrantersOwn)
expect grant(by_ann, { acts_as: Cast.ann_agent, scope: plain }) == Grantable
expect grant(by_ann, { acts_as: Cast.ann_agent, scope: reads }) == Grantable

# A key, even boss's own: grants nothing (bug 3: keys are minted only from
# a browser session).
expect grant(Key(boss_all), { acts_as: Cast.boss, scope: plain }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.ann, scope: plain }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.boss_agent, scope: plain }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.boss_bot, scope: plain }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.ann_agent, scope: plain }) == Refused(GrantedByKey)

# The accounts decide, not the caller's copy: a retired agent gets no key,
# though its owner grants it; a copy claiming boss as the owner of ann's
# agent is no owner.
expect
	grant_at(
		by_ann,
		{
			acts_as: Cast.ann_agent,
			scope: plain,
			among: [Cast.ann],
			now: 50,
		},
	)
		== Refused(NoSuchPrincipal)
ann_agent_as_boss : Principal
ann_agent_as_boss = Cast.owned(Agent, { id: 3, owner: 1 })

expect grant(by_boss, { acts_as: ann_agent_as_boss, scope: plain }) == Refused(NotTheGrantersOwn)

# The granter is the accounts' too (bug 2): a retired human's session
# grants nothing for the agent left behind; nor does a session past its
# day idle.
expect
	grant_at(
		by_ann,
		{
			acts_as: Cast.ann_agent,
			scope: plain,
			among: Cast.without_ann,
			now: 50,
		},
	)
		== Refused(NoSuchGranter)
expect
	grant_at(
		by_ann,
		{
			acts_as: Cast.ann,
			scope: plain,
			among: Cast.accounts,
			now: Session.idle_secs,
		},
	)
		== Refused(SessionExpired)

# ── keys for the tables
## A key acting as `acts_as`, granted by its owner's session.
issued : { acts_as : Principal, scope : ApiKey.Scope }, I64 -> ApiKey.Key
issued = |{ acts_as, scope }, expires|
	match ApiKey.Key.issue(
		{
			granter: signed_in({ n: 9, who: acts_as.answers_to().to_u64() }),
			acts_as: acts_as.id(),
			scope,
			accounts: Cast.accounts,
			now: 50,
		},
		{ key: Cast.kid(7), expires },
	) {
		Ok(key) => key
		Err(Refused(_)) => crash "issued: a test's key is grantable"
	}

ann_year : ApiKey.Key
ann_year = issued({ acts_as: Cast.ann, scope: plain }, 1050)

ann_until_100 : ApiKey.Key
ann_until_100 = issued({ acts_as: Cast.ann, scope: plain }, 100)

# ── THE LIVENESS TABLE
expect ann_year.liveness(0) == Live
expect ann_year.liveness(1049) == Live
expect ann_year.liveness(1050) == Expired
expect ann_until_100.liveness(99) == Live
expect ann_until_100.liveness(100) == Expired
expect ann_until_100.liveness(101) == Expired
expect ann_year.revoke().liveness(0) == Revoked
expect ann_until_100.revoke().liveness(99) == Revoked
expect ann_until_100.revoke().liveness(101) == Revoked

# An ungrantable key is never issued.
expect
	ApiKey.Key.issue(
		{
			granter: by_ann,
			acts_as: Cast.boss.id(),
			scope: plain,
			accounts: Cast.accounts,
			now: 50,
		},
		{ key: Cast.kid(7), expires: 1050 },
	).map_ok(ApiKey.Key.id)
		== Err(Refused(NotTheGrantersOwn))

# ATTACK: an expiry the store cannot write, one
# already past, or one past a year, is never granted; nor is any key under
# a clock outside the store's range.
expect
	List.all(
		[
			-1,
			Stored.max_time + 1,
			50,
			10,
			50 + ApiKey.max_lifetime_secs + 1,
		],
		|expires|
			ApiKey.Key.issue(
				{
					granter: by_ann,
					acts_as: Cast.ann.id(),
					scope: plain,
					accounts: Cast.accounts,
					now: 50,
				},
				{ key: Cast.kid(7), expires },
			).map_ok(ApiKey.Key.id)
				== Err(Refused(BadExpiry)),
	)
expect
	ApiKey.Key.issue(
		{
			granter: by_ann,
			acts_as: Cast.ann.id(),
			scope: plain,
			accounts: Cast.accounts,
			now: -1,
		},
		{ key: Cast.kid(7), expires: 10 },
	).map_ok(ApiKey.Key.id)
		== Err(Refused(ClockOutOfRange))
# The edges a grant does make: a year to the second, and the store's last
# time, both of which encode.
expect
	List.all(
		[
			{ now: 50, expires: 50 + ApiKey.max_lifetime_secs },
			{ now: Stored.max_time - 1, expires: Stored.max_time },
		],
		|{ now, expires }|
			match ApiKey.Key.issue(
				{
					granter: Session(session_at(2, now)),
					acts_as: Cast.ann.id(),
					scope: plain,
					accounts: Cast.accounts,
					now,
				},
				{ key: Cast.kid(7), expires },
			) {
				Ok(k) => ApiKey.decode(ApiKey.encode({ key: k, hash: Cast.token(9) })).is_ok()
				Err(_) => Bool.False
			},
	)

# ── STANDING, AND ADMINISTERING
## The principal a key stands as at `now` among `among`, by id.
standing_at : ApiKey.Key,
{ among : List(Principal), now : I64 } -> Try(
	Principal.Id,
	[Refused(ApiKey.Refusal)],
)
standing_at = |key, { among, now }| key.principal({ accounts: among, now }).map_ok(Principal.id)

## The principal a key stands as at 50 among `among`.
standing_among : ApiKey.Key,
List(Principal) -> Try(
	Principal.Id,
	[Refused(ApiKey.Refusal)],
)
standing_among = |key, among| standing_at(key, { among, now: 50 })

ann_agent_plain : ApiKey.Key
ann_agent_plain = issued({ acts_as: Cast.ann_agent, scope: plain }, 1050)

ann_agent_reads : ApiKey.Key
ann_agent_reads = issued({ acts_as: Cast.ann_agent, scope: reads }, 1050)

boss_all : ApiKey.Key
boss_all = issued({ acts_as: Cast.boss, scope: plain }, 1050)

boss_agent_mute : ApiKey.Key
boss_agent_mute = issued({ acts_as: Cast.boss_agent, scope: mute }, 1050)

boss_until_100 : ApiKey.Key
boss_until_100 = issued({ acts_as: Cast.boss, scope: plain }, 100)

# A standing key stands as its principal.
expect standing_among(ann_agent_plain, Cast.accounts) == Ok(Cast.ann_agent.id())
expect standing_among(boss_all, Cast.accounts) == Ok(Cast.boss.id())

# The key never stands as more than its principal now: the agent itself
# gone, or its owner gone.
expect standing_among(boss_agent_mute, [Cast.boss]) == Err(Refused(NoSuchPrincipal))
expect standing_among(boss_agent_mute, [Cast.boss_agent]) == Err(Refused(NoSuchPrincipal))

# Bug 1: ann retired, her agent's key stands as nobody.
expect standing_among(ann_agent_plain, Cast.without_ann) == Err(Refused(NoSuchPrincipal))

# Liveness comes first: revoked and expired keys stand as nobody; an expiry
# at 100 is live at 99.
expect standing_among(boss_all.revoke(), Cast.accounts) == Err(Refused(Revoked))
expect standing_at(boss_until_100, { among: Cast.accounts, now: 99 }) == Ok(Cast.boss.id())
expect standing_at(boss_until_100, { among: Cast.accounts, now: 100 }) == Err(Refused(Expired))
expect standing_at(boss_until_100.revoke(), { among: Cast.accounts, now: 99 }) == Err(Refused(Revoked))

# ── LOADING A STORED KEY
## The key a stored line holds: `record`, written and read back (a key's
## only way in but a grant).
from_store : ApiKey.Record -> ApiKey.Key
from_store = |record|
	match ApiKey.decode(ApiKey.encode({ key: ApiKey.Key.(record), hash: Cast.token(9) })) {
		Ok(entry) => entry.key
		Err(_) => crash "from_store: a test's key line decodes"
	}

# A key's record loads back to the same record, revoked or not.
expect [
	ann_year,
	boss_until_100,
	ann_agent_reads,
	boss_agent_mute.revoke(),
].all(|key| from_store(key.record()).record() == key.record())

# A scope loads as the line says.
expect from_store({ ..ann_year.record(), scope: mute }).record().scope == mute
# A reading line loads reading, and posting nothing.
expect from_store(ann_agent_reads.record()).record().scope == reads

# **NO KEY FROM A RECORD**: a key is
# issued from a live session's grant, or decoded from a stored line;
# there is no constructor from a record outside this module, so
# a handler's `{ acts_as: boss, ... }` is no key. A line it writes
# out by hand is a forged store, and still held to its principal.

# ── DUPLICATE AND FORGED ACCOUNTS
# A copy of ann's agent claiming boss as owner, first in the accounts:
# boss is granted no key acting as it, and ann's agent's own key, granted
# before, stands no more while the copy is there.
forged_ann_agent : Principal
forged_ann_agent = Cast.owned(Agent, { id: 3, owner: 1 })

forged_first : List(Principal)
forged_first = Cast.accounts.prepend(forged_ann_agent)

expect grant_at(
	by_boss,
	{
		acts_as: Cast.ann_agent,
		scope: plain,
		among: forged_first,
		now: 50,
	},
) == Refused(NoSuchPrincipal)
expect grant_at(
	by_ann,
	{
		acts_as: Cast.ann_agent,
		scope: plain,
		among: forged_first,
		now: 50,
	},
) == Refused(NoSuchPrincipal)
expect standing_among(ann_agent_plain, forged_first) == Err(Refused(NoSuchPrincipal))

# A duplicate of ann claiming admin, first: ann's session grants nothing
# (it admits no copy), and her keys stand no more.
ann_admin_first : List(Principal)
ann_admin_first = List.prepend(Cast.accounts, Cast.person(2, Admin))

expect grant_at(
	by_ann,
	{
		acts_as: Cast.ann,
		scope: plain,
		among: ann_admin_first,
		now: 50,
	},
) == Refused(NoSuchGranter)
expect standing_among(ann_agent_plain, ann_admin_first) == Err(Refused(NoSuchPrincipal))

# ── RE-CREATION AFTER RETIREMENT
# Ann retired, then made again with her GitHub id at 60: her old keys,
# and her old agent's, stand no more; a new session of the new account
# grants keys bound to it.
ann_again : Principal
ann_again = Principal.Human({
	id: Cast.hid(2),
	sign_in: Cast.github(2),
	login: "ann",
	name: "Ann",
	role: Member,
	generation: Cast.gen(2),
})

again : List(Principal)
again = [
	Cast.boss,
	ann_again,
	Cast.boss_agent,
	Cast.boss_bot,
	Cast.ann_agent,
]

expect standing_at(ann_year, { among: again, now: 70 }) == Err(Refused(NoSuchPrincipal))
expect standing_at(ann_agent_plain, { among: again, now: 70 }) == Err(Refused(NoSuchPrincipal))
expect grant_at(
	by_ann,
	{
		acts_as: Cast.ann,
		scope: plain,
		among: again,
		now: 70,
	},
) == Refused(NoSuchGranter)
new_ann_session : ApiKey.Granter
new_ann_session = stored_session("session v1 id=8 human=2 generation=2 token=${"07".repeat(32)} created=60 seen=60\n")

expect
	ApiKey.Key.issue(
		{
			granter: new_ann_session,
			acts_as: ann_again.id(),
			scope: plain,
			accounts: again,
			now: 70,
		},
		{ key: Cast.kid(8), expires: 1050 },
	).map_ok(|k| k.record().human_generation)
		== Ok(Cast.gen(2))

# **AN AGENT MADE AGAIN WITH ITS ID**: ann's agent retired, and an agent made again with id 3 for
# ann (a host that reused the id): the old key stands no more.
agent_again : List(Principal)
agent_again = [
	Cast.boss,
	Cast.ann,
	Cast.boss_agent,
	Cast.boss_bot,
	Principal.Agent({
		id: Cast.aid(3),
		name: "a3",
		owner: Cast.hid(2),
		generation: Cast.gen(5),
	}),
]

expect standing_among(ann_agent_plain, agent_again) == Err(Refused(NoSuchPrincipal))

# ── ITS LINE: what it writes, round trips, and each malformed line by name.
## A test's hash: every byte `b`.
hash_of : U8 -> Stored.SecretHash
hash_of = |b|
	match Stored.SecretHash.from_bytes(List.repeat(b, 32)) {
		Ok(h) => h
		Err(NotAHash) => crash "hash_of: 32 bytes are a hash"
	}

## An entry for the record `r`.
## A key's record and its hash, as a test compares them.
StoredKey : { record : ApiKey.Record, hash : Stored.SecretHash }

entry : ApiKey.Record -> StoredKey
entry = |r| {
	record: r,
	hash: hash_of(0x5a),
}

## A reading agent's key: agent 7, reading, not posting.
reader : ApiKey.Record
reader = {
	id: Cast.kid(4),
	acts_as: Principal.Id.Agent(Cast.aid(7)),
	generation: Cast.gen(4),
	human_generation: Cast.gen(3),
	scope: {
		read: On,
		post: Off,
	},
	created: 1761600000,
	expires: 1793136000,
	revocation: Active,
}

## Every part of a record at its other value: a human's, posting,
## expiring, revoked.
broad : ApiKey.Record
broad = {
	id: Cast.kid(18446744073709551615),
	acts_as: Principal.Id.Human(Cast.hid(583231)),
	generation: Cast.gen(18446744073709551615),
	human_generation: Cast.gen(18446744073709551615),
	scope: {
		read: Off,
		post: On,
	},
	created: 1761600000,
	expires: 1761609999,
	revocation: Revoked,
}

encoded : StoredKey -> List(U8)
encoded = |e| ApiKey.encode({ key: ApiKey.Key.(e.record), hash: e.hash })

## The entry a line holds.
read_back : List(U8) -> Try(StoredKey, _)
read_back = |raw| ApiKey.decode(raw).map_ok(|d| { record: d.key.record(), hash: d.hash })

## The entry survives a round trip whole.
is_kept : StoredKey -> Bool
is_kept = |e| read_back(encoded(e)) == Ok(e)

hex5a : Str
hex5a = "5a".repeat(32)

reader_line : Str
reader_line = "key v1 id=4 acts=agent:7 generation=4 human-generation=3 hash=${hex5a} created=1761600000 expires=1793136000 state=active read=everywhere post=off\n"

expect encoded(entry(reader)) == reader_line.to_utf8()
expect
	encoded(entry(broad))
		== "key v1 id=18446744073709551615 acts=human:583231 generation=18446744073709551615 human-generation=18446744073709551615 hash=${hex5a} created=1761600000 expires=1761609999 state=revoked read=off post=everywhere\n".to_utf8()

# Round trips: every part at each of its values.
expect is_kept(entry(reader))
expect is_kept(entry(broad))
expect
	List.all(
		[
			{ ..reader, acts_as: Principal.Id.Bot(Cast.aid(2)) },
			{
				..reader,
				created: 0,
				expires: 1,
			},
			{
				..reader,
				created: Stored.max_time - 1,
				expires: Stored.max_time,
			},
			{ ..reader, expires: 1761600001 },
			{
				..reader,
				scope: {
					read: Off,
					post: Off,
				},
			},
			{
				..reader,
				scope: {
					read: On,
					post: On,
				},
			},
			{ ..broad, revocation: Active },
		],
		|r| is_kept(entry(r)),
	)

# **THE SCOPE IS THE RECORD'S, EXACTLY**: the reader's key decodes so.
expect read_back(reader_line.to_utf8()).map_ok(|e| e.record.scope) == Ok(reader.scope)
expect ApiKey.reach_text(On) == "everywhere"
expect ApiKey.reach_text(Off) == "off"
expect ApiKey.reach_from("everywhere".to_utf8(), "read") == Ok(On)
expect ApiKey.reach_from("off".to_utf8(), "read") == Ok(Off)

# ── THE MALFORMED TABLE: each line, its named problem.
decoded : Str -> Try({}, _)
decoded = |text| ApiKey.decode(text.to_utf8()).map_ok(|_| {})

## The reader's line with `from` replaced by `to`.
reader_but : { from : Str, to : Str } -> Str
reader_but = |{ from, to }| reader_line.replace_first(from, to)

expect decoded(reader_line) == Ok({})
# **A KEY NARROWED TO LISTED RESOURCES IS NO MORE**: an `only:` line, as
# the chat once wrote one, does not decode, its read or its post.
expect decoded(reader_but({ from: "read=everywhere", to: "read=only:3,9" })) == Err(UnknownWord("read"))
expect decoded(reader_but({ from: "post=off", to: "post=only:1" })) == Err(UnknownWord("post"))
expect decoded(reader_but({ from: "\n", to: "" })) == Err(Torn)
expect decoded(reader_but({ from: "key v1", to: "key v2" })) == Err(UnknownVersion)
expect decoded(reader_but({ from: "key v1", to: "keys v1" })) == Err(WrongRecord)
expect decoded(reader_but({ from: "id=4", to: "id=0" })) == Err(BadValue("id"))
expect decoded(reader_but({ from: "id=4 ", to: "" })) == Err(MissingField("id"))
expect decoded(reader_but({ from: "acts=agent:7", to: "acts=agent:0" })) == Err(BadValue("acts"))
expect decoded(reader_but({ from: "acts=agent:7", to: "acts=agent7" })) == Err(BadValue("acts"))
expect decoded(reader_but({ from: "acts=agent:7", to: "acts=admin:7" })) == Err(UnknownWord("acts"))
expect decoded(reader_but({ from: "generation=4 ", to: "" })) == Err(MissingField("generation"))
expect decoded(
	reader_but({
		from: "generation=4",
		to: "generation=-1",
	}),
) == Err(BadNumber("generation"))
expect decoded(
	reader_but({
		from: "generation=4",
		to: "generation=0",
	}),
) == Err(BadValue("generation"))
expect decoded(
	reader_but({
		from: "human-generation=3 ",
		to: "",
	}),
) == Err(MissingField("human-generation"))
expect decoded(
	reader_but({
		from: "human-generation=3",
		to: "human-generation=0",
	}),
) == Err(BadValue("human-generation"))
# A human's key with two generations: no grant makes one.
expect decoded(
	reader_but({
		from: "acts=agent:7",
		to: "acts=human:7",
	}),
) == Err(BadValue("human-generation"))
expect decoded(
	reader_but({
		from: "acts=agent:7 generation=4",
		to: "acts=human:7 generation=3",
	}),
) == Ok({})
expect decoded(reader_but({ from: "hash=", to: "hash=0" })) == Err(BadValue("hash"))
expect decoded(reader_but({ from: hex5a, to: "5A".repeat(32) })) == Err(BadValue("hash"))
expect decoded(reader_but({ from: "hash=${hex5a} ", to: "" })) == Err(MissingField("hash"))
expect decoded(
	reader_but({
		from: "created=1761600000",
		to: "created=now",
	}),
) == Err(BadNumber("created"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=never",
	}),
) == Err(BadNumber("expires"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=",
	}),
) == Err(BadNumber("expires"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=01793136000",
	}),
) == Err(BadNumber("expires"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=-1",
	}),
) == Err(BadNumber("expires"))
# **AN EXPIRY NO GRANT MAKES**: at or before the
# key's creation, or more than a year after it.
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=1761600000",
	}),
) == Err(BadValue("expires"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=1761599999",
	}),
) == Err(BadValue("expires"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=1793136001",
	}),
) == Err(BadValue("expires"))
expect decoded(reader_but({ from: "expires=1793136000", to: "expires=1761600001" })) == Ok({})
expect ApiKey.is_fitting_expiry({ created: Stored.max_time - 1, expires: Stored.max_time })
expect !ApiKey.is_fitting_expiry({ created: Stored.max_time, expires: Stored.max_time + 1 })
expect !ApiKey.is_fitting_expiry({ created: 0, expires: -1 })
expect decoded(reader_but({ from: "state=active", to: "state=live" })) == Err(UnknownWord("state"))
expect decoded(reader_but({ from: "state=active ", to: "" })) == Err(MissingField("state"))
expect decoded(reader_but({ from: "read=everywhere", to: "read=all" })) == Err(UnknownWord("read"))
expect decoded(reader_but({ from: "read=everywhere", to: "read=" })) == Err(UnknownWord("read"))
expect decoded(reader_but({ from: "read=everywhere", to: "read=on" })) == Err(UnknownWord("read"))
expect decoded(reader_but({ from: "post=off", to: "post=on" })) == Err(UnknownWord("post"))
expect decoded(reader_but({ from: " post=off", to: "" })) == Err(MissingField("post"))
expect decoded(reader_but({ from: "post=off\n", to: "post=off \n" })) == Err(Trailing)
expect decoded(reader_but({ from: "post=off\n", to: "post=off last_used=1\n" })) == Err(Trailing)
# The admin scope of before is no field now.
expect decoded(reader_but({ from: "post=off\n", to: "post=off admin=off\n" })) == Err(Trailing)
expect decoded(
	reader_but({
		from: "read=everywhere post=off",
		to: "post=off read=everywhere",
	}),
) == Err(MissingField("read"))

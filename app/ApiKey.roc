## **API KEYS, FIRST-CLASS AND SCOPED** (the Roc chat's auth design,
## sections 3, 9 and 11): a key acts as one principal, with a scope of read,
## post and admin, each on or off, read and post narrowable to listed
## resources. It never exceeds its principal: a read or a post is Access's
## decision (Access.decide, on the viewer the key mints), an admin action
## the principal's authority as the accounts say now (`administers`).
##
## **ONLY TWO WAYS IN:** `issue`, which asks `may_grant` (a live browser
## session, never a key, for the granter's own principals), and `load`,
## which takes a KeyCodec.Line (an opaque value only the decoder makes,
## from a stored line). There is no constructor from a record, so no
## handler mints a key, an admin's or anyone's, without a grant or a line
## in the store.
##
## **A KEY IS ITS ACCOUNTS'**: it holds the generation of its principal's
## account and of the human's it answers to (Principal.Bound), and stands
## only while those very accounts do (Principal.holds); an id retired and
## made again, a human's or an agent's, never revives the old keys.
##
## **GENERIC OVER THE RESOURCE, AND BOUND TO IT**: a key is
## `Key(r, id)`, `r` the resource its layer decides on (the chat's opaque
## ConvAccess.Conv) and `id` its id (the chat's ConvId). `r` is fixed when
## the key is issued or loaded, so a key decides only on its own layer's
## resources: a chat key never takes a resource some other type made up
## (Access.decide on anything but a Conv does not compile), and a database
## or a file system keys its own. The chat's entry is ConvKey.roc, which fixes
## `r` and `id`. The key's secret and its hash are the host's; this is the
## record the Roc decides on. Pure.
import Cast
import KeyCodec
import Principal
import Session
import SessionCodec
import Stored

ApiKey := [].{

	## Where a read or a post reaches: every resource its principal may
	## reach, or only the listed ones (a bot that posts only to #commits).
	Reach(id) : KeyCodec.Reach(id)

	## **WHAT A KEY MAY DO**, each part on or off. Admin is a scope of its
	## own: an admin-only key reads nothing.
	Scope(id) : KeyCodec.Scope(id)

	## **WHO ASKS FOR A KEY**: the credential the request came with. Only a
	## browser's session mints keys; a key asking is refused, whatever its
	## scope, so a stolen key cannot mint a wider one.
	Granter(r, id) : [Session(Session), Key(ApiKey.Key(r, id))]

	## A request for a key: who asks, the principal the key would act as,
	## its scope, and the accounts and the time now.
	Grant(r, id) : {
		granter : ApiKey.Granter(r, id),
		acts_as : Principal.Id,
		scope : ApiKey.Scope(id),
		accounts : List(Principal),
		now : I64,
	}

	## Why a grant is refused.
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

		## Admin only for an admin human, or an agent an admin owns.
		AdminBeyondPrincipal,

		## The clock is outside Stored's range (before 1970 or past 9999):
		## nothing it would write could be stored.
		ClockOutOfRange,

		## The expiry is not after now, or more than a year after it
		## (KeyCodec.max_lifetime_secs), or past Stored's last time: every key
		## expires, within a year, at a time the store can write.
		BadExpiry,
	]

	## What a key's use is decided against: the accounts, and the time,
	## now.
	AsOf : { accounts : List(Principal), now : I64 }

	## A key's answer.
	Verdict : [Permitted, Refused(ApiKey.Refusal)]

	## Why a key may not do what it was asked.
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
	## and for the agents and bots they own; admin only when `acts_as` has
	## admin authority (Principal.authority: an admin human, or an agent an
	## admin owns). Read and post need no check here: a key's every use is
	## held to its principal.
	may_grant : ApiKey.Grant(r, id) -> [Grantable, Refused(ApiKey.GrantRefusal)]
	may_grant = |grant|
		match granted(grant) {
			Ok(_) => Grantable
			Err(why) => Refused(why)
		}

	## **A KEY'S WHOLE RECORD**, as the store keeps it (KeyCodec).
	Record(id) : KeyCodec.Record(id)

	## **A KEY, AS A STATE MACHINE**: opaque, so `issue` (which asks
	## `may_grant`) is the one way in, `load` (from a stored line) the way
	## back, and `revoke` the one transition.
	Key(r, id) :: KeyCodec.Record(id).{

		## A new key, active, made `now`, when the grant is grantable and the
		## expiry fits (KeyCodec.is_fitting_expiry); bound to its accounts.
		issue : ApiKey.Grant(r, id),
		{ key : Principal.KeyId, expires : I64 } -> Try(
			ApiKey.Key(r, id),
			[Refused(ApiKey.GrantRefusal)],
		)
		issue = |grant, { key, expires }|
			match granted(grant) {
				Err(why) => Err(Refused(why))
				Ok(_) if !KeyCodec.is_fitting_expiry({
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

		## **A KEY AS ITS STORED LINE HOLDS IT**: the line's principal,
		## account, scope, expiry and revocation exactly, nothing added and
		## nothing widened. No grant is asked again: the line was written
		## from a key `issue` granted, and every use is still held to its
		## principal as the accounts say then (`decide`), so a line claiming
		## more than its principal may do does no more.
		load : KeyCodec.Line(id) -> ApiKey.Key(r, id)
		load = |line| ApiKey.Key.(line.entry().record)

		## The key's whole record, to store.
		record : ApiKey.Key(r, id) -> ApiKey.Record(id)
		record = |ApiKey.Key.(k)| k

		## The only transition: revoked, for good.
		revoke : ApiKey.Key(r, id) -> ApiKey.Key(r, id)
		revoke = |ApiKey.Key.(k)| ApiKey.Key.({ ..k, revocation: Revoked })

		## The key's public id.
		id : ApiKey.Key(r, id) -> Principal.KeyId
		id = |ApiKey.Key.(k)| k.id

		## The principal it acts as.
		acts_as : ApiKey.Key(r, id) -> Principal.Id
		acts_as = |ApiKey.Key.(k)| k.acts_as

		## **IS THE KEY LIVE AT `now`?** Revoked is said first, expired or
		## not; an expiry at `t` is live before `t` and expired from `t` on.
		liveness : ApiKey.Key(r, id),
		I64 -> [
			Live,
			Expired,
			Revoked,
		]
		liveness = |ApiKey.Key.(k), now|
			match k.revocation {
				Revoked => Revoked
				Active => if now < k.expires Live else Expired
			}

		## **MAY THIS KEY PERFORM AN ADMIN ACTION, NOW?** The key live and
		## its principal standing (as for a read or a post); an admin scope; and the
		## principal's authority Admin as the accounts say now. Which action
		## is Admin.roc's to decide.
		administers : ApiKey.Key(r, id), ApiKey.AsOf -> ApiKey.Verdict
		administers = |key, { accounts, now }| {
			ApiKey.Key.(k) = key
			match standing(key, { accounts, now }) {
				Refused(why) => Refused(why)
				Standing(principal) =>
					match (k.scope.admin, principal.authority(accounts)) {
						(Off, _) => Refused(OutOfScope)
						(On, Admin) => Permitted
						(On, Member) => Refused(BeyondPrincipal)
					}
			}
		}

		## **THE PRINCIPAL A STANDING KEY ACTS AS**, as the accounts have
		## it now; what Admin acts with.
		principal : ApiKey.Key(r, id), ApiKey.AsOf -> Try(Principal, [Refused(ApiKey.Refusal)])
		principal = |key, as_of|
			match standing(key, as_of) {
				Standing(p) => Ok(p)
				Refused(why) => Err(Refused(why))
			}
	}
}

## **THE GRANT, DECIDED**: the principal, bound to the accounts the key
## will stand on, or why not.
granted : ApiKey.Grant(r, id) -> Try(Principal.Bound, ApiKey.GrantRefusal)
granted = |
	{
		granter,
		acts_as,
		scope,
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
								match (scope.admin, Principal.authority(current, accounts)) {
									(Off, _) => Ok(bound)
									(On, Admin) => Ok(bound)
									(On, Member) => Err(AdminBeyondPrincipal)
								}
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
standing : ApiKey.Key(r, id), ApiKey.AsOf -> [Standing(Principal), Refused(ApiKey.Refusal)]
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

# The cast:
#   boss        an admin human
#   ann         a member human
#   boss_agent  an agent boss owns
#   boss_bot    a bot boss owns
#   ann_agent   an agent ann owns
## Human `who`'s browser session `n`, signed in at time 0 to the account
## made at 1, as the store holds it (a session's only way in but the flow).
signed_in : { n : U64, who : U64 } -> ApiKey.Granter(Held, U64)
signed_in = |{ n, who }|
	stored_session("session v1 id=${n.to_str()} human=${who.to_str()} generation=1 token=${Str.repeat("07", 32)} created=0 seen=0\n")

## Human `who`'s session, signed in at `at` to the account of generation
## 1, from its stored line.
session_at : U64, I64 -> Session
session_at = |who, at|
	match SessionCodec.decode(Str.to_utf8("session v1 id=3 human=${who.to_str()} generation=1 token=${Str.repeat("07", 32)} created=${at.to_str()} seen=${at.to_str()}\n")) {
		Ok(line) => Session.load(line)
		Err(_) => crash "session_at: a test's session line decodes"
	}

## The session a stored line holds, as a granter.
stored_session : Str -> ApiKey.Granter(Held, U64)
stored_session = |text|
	match SessionCodec.decode(Str.to_utf8(text)) {
		Ok(line) => Session(Session.load(line))
		Err(_) => crash "stored_session: a test's session line decodes"
	}

by_boss : ApiKey.Granter(Held, U64)
by_boss = signed_in({ n: 1, who: 1 })

by_ann : ApiKey.Granter(Held, U64)
by_ann = signed_in({ n: 2, who: 2 })

# The scopes the tables use.
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

GrantAnswer : [Grantable, Refused(ApiKey.GrantRefusal)]

## `granter` asks for a key acting as `acts_as`, among `among`, at `now`.
grant_at : ApiKey.Granter(Held, U64),
{
	acts_as : Principal,
	scope : ApiKey.Scope(U64),
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
		acts_as: Principal.id(acts_as),
		scope,
		accounts: among,
		now,
	})

## `granter` asks for a key acting as `acts_as`, among `accounts`, at 50.
grant : ApiKey.Granter(Held, U64), { acts_as : Principal, scope : ApiKey.Scope(U64) } -> GrantAnswer
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
# Every granter against every principal a key could act as, without admin
# and with it.

# boss's session, an admin's: their own and their agent's admin; never
# their bot's.
expect grant(by_boss, { acts_as: Cast.boss, scope: plain }) == Grantable
expect grant(by_boss, { acts_as: Cast.boss, scope: with_admin }) == Grantable
expect grant(by_boss, { acts_as: Cast.ann, scope: plain }) == Refused(NotTheGrantersOwn)
expect grant(by_boss, { acts_as: Cast.ann, scope: with_admin }) == Refused(NotTheGrantersOwn)
expect grant(by_boss, { acts_as: Cast.boss_agent, scope: plain }) == Grantable
expect grant(by_boss, { acts_as: Cast.boss_agent, scope: with_admin }) == Grantable
expect grant(by_boss, { acts_as: Cast.boss_bot, scope: plain }) == Grantable
expect grant(
	by_boss,
	{ acts_as: Cast.boss_bot, scope: with_admin },
) == Refused(AdminBeyondPrincipal)
expect grant(by_boss, { acts_as: Cast.ann_agent, scope: plain }) == Refused(NotTheGrantersOwn)
expect grant(by_boss, { acts_as: Cast.ann_agent, scope: with_admin }) == Refused(NotTheGrantersOwn)

# ann's session, a member's: her own and her agent's, never admin.
expect grant(by_ann, { acts_as: Cast.boss, scope: plain }) == Refused(NotTheGrantersOwn)
expect grant(by_ann, { acts_as: Cast.boss, scope: with_admin }) == Refused(NotTheGrantersOwn)
expect grant(by_ann, { acts_as: Cast.ann, scope: plain }) == Grantable
expect grant(by_ann, { acts_as: Cast.ann, scope: with_admin }) == Refused(AdminBeyondPrincipal)
expect grant(by_ann, { acts_as: Cast.boss_agent, scope: plain }) == Refused(NotTheGrantersOwn)
expect grant(by_ann, { acts_as: Cast.boss_agent, scope: with_admin }) == Refused(NotTheGrantersOwn)
expect grant(by_ann, { acts_as: Cast.boss_bot, scope: plain }) == Refused(NotTheGrantersOwn)
expect grant(by_ann, { acts_as: Cast.boss_bot, scope: with_admin }) == Refused(NotTheGrantersOwn)
expect grant(by_ann, { acts_as: Cast.ann_agent, scope: plain }) == Grantable
expect grant(
	by_ann,
	{ acts_as: Cast.ann_agent, scope: with_admin },
) == Refused(AdminBeyondPrincipal)

# A key, even boss's own with admin: grants nothing (bug 3: keys are minted
# only from a browser session).
expect grant(Key(boss_all), { acts_as: Cast.boss, scope: plain }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.boss, scope: with_admin }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.ann, scope: plain }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.ann, scope: with_admin }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.boss_agent, scope: plain }) == Refused(GrantedByKey)
expect grant(
	Key(boss_all),
	{ acts_as: Cast.boss_agent, scope: with_admin },
) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.boss_bot, scope: plain }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.boss_bot, scope: with_admin }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.ann_agent, scope: plain }) == Refused(GrantedByKey)
expect grant(Key(boss_all), { acts_as: Cast.ann_agent, scope: with_admin }) == Refused(GrantedByKey)

# The accounts decide, not the caller's copy: a retired agent gets no key,
# though its owner grants it; a copy claiming boss's admin role for ann, or
# boss as the owner of ann's agent, is no admin and no owner.
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
ann_as_admin : Principal
ann_as_admin = Cast.person(2, Admin)

ann_agent_as_boss : Principal
ann_agent_as_boss = Cast.owned(Agent, { id: 3, owner: 1 })

expect grant(by_ann, { acts_as: ann_as_admin, scope: with_admin }) == Refused(AdminBeyondPrincipal)
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
issued : { acts_as : Principal, scope : ApiKey.Scope(U64) }, I64 -> ApiKey.Key(Held, U64)
issued = |{ acts_as, scope }, expires|
	match ApiKey.Key.issue(
		{
			granter: signed_in({ n: 9, who: Principal.answers_to(acts_as).to_u64() }),
			acts_as: Principal.id(acts_as),
			scope,
			accounts: Cast.accounts,
			now: 50,
		},
		{ key: Cast.kid(7), expires },
	) {
		Ok(key) => key
		Err(Refused(_)) => crash "issued: a test's key is grantable"
	}

ann_year : ApiKey.Key(Held, U64)
ann_year = issued({ acts_as: Cast.ann, scope: plain }, 1050)

ann_until_100 : ApiKey.Key(Held, U64)
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
			acts_as: Principal.id(Cast.ann),
			scope: with_admin,
			accounts: Cast.accounts,
			now: 50,
		},
		{ key: Cast.kid(7), expires: 1050 },
	).map_ok(ApiKey.Key.id)
		== Err(Refused(AdminBeyondPrincipal))

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
			50 + KeyCodec.max_lifetime_secs + 1,
		],
		|expires|
			ApiKey.Key.issue(
				{
					granter: by_ann,
					acts_as: Principal.id(Cast.ann),
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
			acts_as: Principal.id(Cast.ann),
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
			{ now: 50, expires: 50 + KeyCodec.max_lifetime_secs },
			{ now: Stored.max_time - 1, expires: Stored.max_time },
		],
		|{ now, expires }|
			match ApiKey.Key.issue(
				{
					granter: Session(session_at(2, now)),
					acts_as: Principal.id(Cast.ann),
					scope: plain,
					accounts: Cast.accounts,
					now,
				},
				{ key: Cast.kid(7), expires },
			) {
				Ok(k) => KeyCodec.decode(
					KeyCodec.encode({ record: k.record(), hash: Cast.token(9) }, |n| n),
					|n| Ok(n),
				).is_ok()
				Err(_) => Bool.False
			},
	)

# ── STANDING, AND ADMINISTERING
## **A TEST'S RESOURCE TYPE**: a key is bound to its layer's resource (a
## chat key to ConvAccess.Conv); Access.roc decides its reads and posts.
## Here no resource is asked, so the layer is a placeholder.
Held :: {}

## The principal a key stands as at `now` among `among`, by id.
standing_at : ApiKey.Key(Held, U64),
{ among : List(Principal), now : I64 } -> Try(
	Principal.Id,
	[Refused(ApiKey.Refusal)],
)
standing_at = |key, { among, now }| key.principal({ accounts: among, now }).map_ok(Principal.id)

## The principal a key stands as at 50 among `among`.
standing_among : ApiKey.Key(Held, U64),
List(Principal) -> Try(
	Principal.Id,
	[Refused(ApiKey.Refusal)],
)
standing_among = |key, among| standing_at(key, { among, now: 50 })

Answer : [Permitted, Refused(ApiKey.Refusal)]

## The key's answer to an admin action at time 50, among `accounts`.
administered : ApiKey.Key(Held, U64) -> Answer
administered = |key| key.administers({ accounts: Cast.accounts, now: 50 })

## The key's answer to an admin action at time 50, among `among` instead.
administers_among : ApiKey.Key(Held, U64), List(Principal) -> Answer
administers_among = |key, among| key.administers({ accounts: among, now: 50 })

ann_agent_plain : ApiKey.Key(Held, U64)
ann_agent_plain = issued({ acts_as: Cast.ann_agent, scope: plain }, 1050)

ann_agent_reads_c : ApiKey.Key(Held, U64)
ann_agent_reads_c = issued({ acts_as: Cast.ann_agent, scope: reads_c }, 1050)

ann_agent_posts_a : ApiKey.Key(Held, U64)
ann_agent_posts_a = issued({ acts_as: Cast.ann_agent, scope: posts_a }, 1050)

boss_all : ApiKey.Key(Held, U64)
boss_all = issued({ acts_as: Cast.boss, scope: with_admin }, 1050)

boss_agent_admin : ApiKey.Key(Held, U64)
boss_agent_admin = issued({ acts_as: Cast.boss_agent, scope: admin_only }, 1050)

boss_until_100 : ApiKey.Key(Held, U64)
boss_until_100 = issued({ acts_as: Cast.boss, scope: with_admin }, 100)

# A standing key stands as its principal.
expect standing_among(ann_agent_plain, Cast.accounts) == Ok(Principal.id(Cast.ann_agent))
expect standing_among(boss_all, Cast.accounts) == Ok(Principal.id(Cast.boss))

# Admin: only an admin scope, on an admin's or an admin's agent's key.
expect administered(ann_agent_plain) == Refused(OutOfScope)
expect administered(ann_agent_reads_c) == Refused(OutOfScope)
expect administered(ann_agent_posts_a) == Refused(OutOfScope)
expect administered(ann_year) == Refused(OutOfScope)
expect administered(boss_all) == Permitted
expect administered(boss_agent_admin) == Permitted

# The key never exceeds its principal as the accounts say NOW: boss demoted,
# boss retired, or the agent itself retired.
expect administers_among(
	boss_agent_admin,
	[Cast.boss_demoted, Cast.boss_agent],
) == Refused(BeyondPrincipal)
expect administers_among(boss_agent_admin, [Cast.boss_agent]) == Refused(NoSuchPrincipal)
expect administers_among(boss_agent_admin, [Cast.boss]) == Refused(NoSuchPrincipal)
expect administers_among(boss_all, [Cast.boss_demoted]) == Refused(BeyondPrincipal)

# Bug 1: ann retired, her agent's key stands as nobody.
expect standing_among(ann_agent_plain, Cast.without_ann) == Err(Refused(NoSuchPrincipal))

# Liveness comes first: revoked and expired keys stand as nobody; an expiry
# at 100 is live at 99.
expect standing_among(boss_all.revoke(), Cast.accounts) == Err(Refused(Revoked))
expect standing_at(boss_until_100, { among: Cast.accounts, now: 99 }) == Ok(Principal.id(Cast.boss))
expect standing_at(boss_until_100, { among: Cast.accounts, now: 100 }) == Err(Refused(Expired))
expect boss_until_100.revoke().administers({ accounts: Cast.accounts, now: 99 }) == Refused(Revoked)

# ── LOADING A STORED KEY
## The key a stored line holds: `record`, written by KeyCodec and read back
## (a key's only way in but a grant).
from_store : ApiKey.Record(U64) -> ApiKey.Key(Held, U64)
from_store = |record|
	match KeyCodec.decode(KeyCodec.encode({ record, hash: Cast.token(9) }, |n| n), |n| Ok(n)) {
		Ok(line) => ApiKey.Key.load(line)
		Err(_) => crash "from_store: a test's key line decodes"
	}

# A key's record loads back to the same record, revoked or not.
expect List.all(
	[
		ann_year,
		boss_until_100,
		ann_agent_reads_c,
		boss_agent_admin.revoke(),
	],
	|key| from_store(key.record()).record() == key.record(),
)

# A line claiming admin for ann, a member, loads as it says, and the key
# still administers nothing: its use is held to ann.
ann_claims_admin : ApiKey.Key(Held, U64)
ann_claims_admin = from_store({ ..ann_year.record(), scope: with_admin })

expect ann_claims_admin.record().scope == with_admin
expect administered(ann_claims_admin) == Refused(BeyondPrincipal)

# A narrowed line loads narrowed.
expect from_store(ann_agent_reads_c.record()).record().scope == reads_c

# **NO KEY FROM A RECORD** (the round-two attacker's third): a key is
# issued from a live session's grant, or loaded from a KeyCodec.Line, an
# opaque value only the decoder makes; there is no `load` of a record, so
# a handler's `{ acts_as: boss, admin: On }` is no key. A line it writes
# out by hand is a forged store, and still held to its principal.

# ── DUPLICATE AND FORGED ACCOUNTS (the round-two attacker's first)
# A copy of ann's agent claiming boss as owner, first in the accounts:
# boss is granted no key acting as it, and ann's agent's own key, granted
# before, stands no more while the copy is there.
forged_ann_agent : Principal
forged_ann_agent = Cast.owned(Agent, { id: 3, owner: 1 })

forged_first : List(Principal)
forged_first = List.prepend(Cast.accounts, forged_ann_agent)

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
		scope: with_admin,
		among: ann_admin_first,
		now: 50,
	},
) == Refused(NoSuchGranter)
expect grant_at(
	by_ann,
	{
		acts_as: Cast.ann,
		scope: plain,
		among: ann_admin_first,
		now: 50,
	},
) == Refused(NoSuchGranter)
expect ann_claims_admin.administers({
	accounts: ann_admin_first,
	now: 50,
}) == Refused(NoSuchPrincipal)
expect standing_among(ann_agent_plain, ann_admin_first) == Err(Refused(NoSuchPrincipal))

# ── RE-CREATION AFTER RETIREMENT (the round-two attacker's fifth)
# Ann retired, then made again with her GitHub id at 60: her old keys,
# and her old agent's, stand no more; a new session of the new account
# grants keys bound to it.
ann_again : Principal
ann_again = Principal.Human({
	id: Cast.gid(2),
	login: "h2",
	name: "H2",
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
new_ann_session : ApiKey.Granter(Held, U64)
new_ann_session = stored_session("session v1 id=8 human=2 generation=2 token=${Str.repeat("07", 32)} created=60 seen=60\n")

expect
	ApiKey.Key.issue(
		{
			granter: new_ann_session,
			acts_as: Principal.id(ann_again),
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
		owner: Cast.gid(2),
		generation: Cast.gen(5),
	}),
]

expect standing_among(ann_agent_plain, agent_again) == Err(Refused(NoSuchPrincipal))

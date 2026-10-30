## **THE ADMIN ACTIONS, AND WHO MAY PERFORM THEM** (the Roc chat's auth
## design, sections 9 and 11). **DECIDED AND AUDITED, NOT YET SERVED**: no
## route reaches this module yet; it is the core an admin page will call.
## It runs past a thousand lines because its tests are its table: the code
## ends at `# ── THE ADMIN TABLE`, and every line after is a case.
##
## A closed set of named actions, one decision
## for all of them, and an audit record of every attempt, permitted or
## refused, for the host to store and admins to read. An admin manages
## accounts and reads no one's mail: nothing here reaches a resource's
## contents, and an admin's sight is Access's like anyone's. A key acts on
## members' accounts only: acting on an admin, or on an admin's agent or
## bot, or setting a role, takes a human admin's own session, so one stolen
## admin key cannot remove the other admins.
##
## **A DECISION IS AN AUDIT AND A PLAN**: the plan is every change the
## action makes, step by step, for the host to apply whole, and nothing
## for a refusal or a read. Retiring a human is one plan, Steve's
## conservative defaults, in this order: their GitHub id barred first;
## their sessions and keys revoked; each of their agents and bots retired
## with them, its keys revoked; their public votes withdrawn in every
## conversation; their account removed last. Every step is idempotent (a
## bar is a set's member), so a plan applied again after a crash part way
## leaves what it would have once, and the id is barred before anything of
## it is gone.
##
## **A BAR IS FOR LIFE** (this is its one home; GitHubSignIn points
## here): once retired, a human is banned for good. No action lifts a bar
## (there is no Unbar), and no step of any plan, an admin's or a
## sign-in's, takes an id off the barred list; GitHubSignIn refuses a barred
## id at every door. Were a bar ever lifted, the account would start from a
## new generation, so it would revive nothing of the old one.
##
## **AGAINST A SNAPSHOT, ONE PLAN AT A TIME**: an action is decided against
## the accounts as they are (a snapshot), and refused if its plan, applied
## to that snapshot, would leave no admin. Two admins retiring each other
## are each allowed against the same snapshot; so the host decides and
## applies plans one at a time, each against the accounts the last one left
## (the second retirement is then refused, its actor gone). The bootstrap
## admin (the account the settings' `first_admin` names) is never demoted or
## retired by another admin. Generic over the resource only because a key
## is (ApiKey.Key). Pure.
##
## **THE ONLY RETIREMENT**: this core's plan is the only way an account is
## retired; a retire that knows nothing of generations, bars, agents' keys
## or votes would leave the plan half done.
import Accounts
import ApiKey
import Cast
import GitHubSignIn
import Principal
import Session
import SessionCodec
import Stored

Admin := [].{

	## **THE ACTIONS**, each a pure decision here and a plan for the host.
	Action : [
		## Every account, human, agent and bot.
		ListAccounts,

		## Retire an account, a human's (and with it their agents and bots)
		## or an agent's or a bot's.
		Retire(Principal.Id),

		## Revoke every key acting as a principal.
		RevokeKeys(Principal.Id),

		## End every sign-in session of a human ("log out everywhere").
		RevokeSessions(Principal.GitHubId),

		## Make a human an admin, or a member. Never one's own role, and
		## only from a session.
		SetRole({ human : Principal.GitHubId, role : Principal.Role }),

		## Read the operator's counters and logs.
		ReadCounters,
	]

	## **HOW THE ACTOR CAME IN**: a browser's session, which must be live
	## now; or an API key.
	Credential(r, id) : [
		Session(Session),
		Key(ApiKey.Key(r, id)),
	]

	## Why an admin action is refused. **ONE ALIAS ON PURPOSE**: the
	## decision, its steps and the audit's verdict all carry it, and
	## AuditCodec spells each tag.
	Refusal : [
		## The session's account is not among the accounts, exactly once.
		NoSuchPrincipal,

		## The session is over (idle, or past its week).
		SessionExpired,

		## The session's human is not an admin now.
		NotAdmin,

		## The key may not administer (Admin scope off, not live, or its
		## principal without admin authority).
		KeyRefused(ApiKey.Refusal),

		## The action would retire the actor, or the admin its authority
		## comes from: no admin locks the admins out by one action.
		RetiresOwnAuthority,

		## The action would set the role of the actor's own human.
		SetsOwnRole,

		## A key asked to act on an admin, or on an admin's agent or bot,
		## or to set a role, or to lift a bar: that takes a human admin's
		## own session.
		NeedsSession,

		## The action would demote or retire the first admin.
		FirstAdmin,

		## The action's plan would leave no admin among the accounts.
		LastAdmin,

		## The action names an account that is not among the accounts,
		## exactly once (a retirement, or a role set).
		NoSuchTarget,

	]

	## **THE AUDIT RECORD**: who (the principal the credential names), by
	## which session or key (its public id, never a secret), what, when,
	## the verdict, and the whole plan the action made: a retirement's every
	## step, the agents and bots retired with the human and their votes
	## withdrawn among them (empty for a refusal or a read). Made for every
	## attempt, so a surprising refusal is on the record too.
	Audit : {
		who : Principal.Id,
		via : [Session(Principal.SessionId), Key(Principal.KeyId)],
		action : Admin.Action,
		at : I64,
		verdict : [Permitted, Refused(Admin.Refusal)],
		plan : List(Admin.Step),
	}

	## **ONE STEP OF A PLAN**, for the host to apply.
	Step : [
		## Remove the account from the accounts.
		RemoveAccount(Principal.Id),

		## Add the GitHub id to the settings' barred list, unless it is there.
		Bar(Principal.GitHubId),

		## Withdraw the human's public vote in every conversation
		## (ConvAccess.Conv.withdraw_votes).
		WithdrawVotes(Principal.GitHubId),

		## Revoke every key acting as the principal.
		RevokeKeysOf(Principal.Id),

		## End every session of the human.
		RevokeSessionsOf(Principal.GitHubId),

		## Set the human's role.
		SetRole({ human : Principal.GitHubId, role : Principal.Role }),
	]

	## **THE DECISION**: the audit record, and the plan, empty unless the
	## action is permitted and changes something.
	Decision : { audit : Admin.Audit, plan : List(Admin.Step) }

	## **MAY THIS CREDENTIAL PERFORM THIS ACTION, NOW, AND WHAT DOES IT
	## CHANGE?** The actor must have admin authority as the accounts say
	## now: by a session, live and an admin human's account; by a key, one
	## ApiKey's `administers` permits (an admin scope, live, acting as an
	## admin human or an agent an admin owns). Then the action must not
	## retire the actor or the admin behind it, nor set their own role; by
	## a key, it must not touch an admin or an admin's agent or bot, nor set
	## a role, nor lift a bar. Then its plan must be one: its target an
	## account, never the first admin demoted or
	## retired, and some admin left once the plan is applied to the
	## snapshot. A clock outside Stored's range decides nothing
	## (`ClockOutOfRange`): its audit could not be stored.
	decide : {
		credential : Admin.Credential(r, id),
		action : Admin.Action,
		accounts : List(Principal),
		settings : Accounts.Settings,
		now : I64,
	} -> Try(Admin.Decision, [ClockOutOfRange])
	decide = |
		{
			credential,
			action,
			accounts,
			settings,
			now,
		},
	|
		if now < 0 or now > Stored.max_time {
			Err(ClockOutOfRange)
		} else {
			Ok(
				decided_now({
					credential,
					action,
					accounts,
					settings,
					now,
				}),
			)
		}

	## **WHAT A PLAN LEAVES OF THE ACCOUNTS AND THE SETTINGS**: each step
	## made in order, removals and role changes to the accounts, a bar to the
	## barred list (once: a set's member); the host's other steps (votes,
	## keys, sessions) change neither. The one home of what a step means
	## here; each is idempotent, so a plan applied twice leaves what once does.
	applied : List(Admin.Step),
	{
		accounts : List(Principal),
		settings : Accounts.Settings,
	} -> { accounts : List(Principal), settings : Accounts.Settings }
	applied = |plan, start|
		List.fold(
			plan,
			start,
			|{ accounts, settings }, step|
				match step {
					RemoveAccount(id) => {
						accounts: List.keep_if(accounts, |p| Principal.id(p) != id),
						settings,
					}
					SetRole({ human, role }) => {
						accounts: List.map(
							accounts,
							|p|
								match p {
									Human(h) if h.id == human => Principal.Human({ ..h, role })
									_ => p
								},
						),
						settings,
					}
					Bar(human) =>
						if List.contains(settings.barred, human) {
							{ accounts, settings }
						} else {
							{
								accounts,
								settings: {
									..settings,
									barred: List.append(settings.barred, human),
								},
							}
						}
					WithdrawVotes(_) | RevokeKeysOf(_) | RevokeSessionsOf(_) => {
						accounts,
						settings,
					}
				},
		)
}

## **THE DECISION, ITS CLOCK IN RANGE**: the audit of the attempt and its
## plan.
decided_now : {
	credential : Admin.Credential(r, id),
	action : Admin.Action,
	accounts : List(Principal),
	settings : Accounts.Settings,
	now : I64,
} -> Admin.Decision
decided_now = |
	{
		credential,
		action,
		accounts,
		settings,
		now,
	},
| {
	(who, via) =
		match credential {
			Session(s) => (Principal.Id.Human(s.human()), Session(s.id()))
			Key(key) => (key.acts_as(), Key(key.id()))
		}
	answer =
		match authorized({
			credential,
			accounts,
			now,
		}) {
			Refused(why) => Err(why)
			Admitted(actor) =>
				if is_own_authority(action, actor) {
					Err(RetiresOwnAuthority)
				} else if is_own_role(action, actor) {
					Err(SetsOwnRole)
				} else {
					match credential {
						Key(_) if is_session_only(action, accounts) => Err(NeedsSession)
						_ => planned(action, { accounts, settings })
					}
				}
		}
	(verdict, plan) =
		match answer {
			Ok(steps) => (Permitted, steps)
			Err(why) => (Refused(why), [])
		}

	{
		audit: {
			who,
			via,
			action,
			at: now,
			verdict,
			plan,
		},
		plan,
	}
}

## The actor, when the credential carries admin authority now.
authorized : {
	credential : Admin.Credential(r, id),
	accounts : List(Principal),
	now : I64,
} -> [Admitted(Principal), Refused(Admin.Refusal)]
authorized = |
	{
		credential,
		accounts,
		now,
	},
|
	match credential {
		Session(session) =>
			match session.admit({ accounts, now }) {
				Refused(IdleExpired) | Refused(AbsoluteExpired) => Refused(SessionExpired)
				Refused(NoSuchAccount) => Refused(NoSuchPrincipal)
				Admitted({ principal, write: _ }) =>
					match principal {
						Human(h) =>
							match h.role {
								Admin => Admitted(principal)
								Member => Refused(NotAdmin)
							}
						Agent(_) | Bot(_) => crash "Admin.authorized: a session admits a human"
					}
			}
		Key(key) =>
			match key.administers({ accounts, now }) {
				Refused(why) => Refused(KeyRefused(why))
				Permitted =>
					match key.principal({ accounts, now }) {
						Ok(actor) => Admitted(actor)
						Err(Refused(why)) => Refused(KeyRefused(why))
					}
			}
	}

## **THE PLAN OF A PERMITTED ACTION**, or why it has none: a target that
## is no account, the first admin demoted or retired, a bar not there,
## or no admin left.
planned : Admin.Action,
{
	accounts : List(Principal),
	settings : Accounts.Settings,
} -> Try(List(Admin.Step), Admin.Refusal)
planned = |action, { accounts, settings }| {
	is_first_admin = |human|
		match settings.first_admin {
			Named(first) => first == human
			Unnamed => Bool.False
		}
	steps =
		match action {
			ListAccounts | ReadCounters => Ok([])
			RevokeKeys(id) => Ok([RevokeKeysOf(id)])
			RevokeSessions(human) => Ok([RevokeSessionsOf(human)])
			SetRole({ human, role }) =>
				match (Principal.human_account(accounts, human), role) {
					(Err(_), _) => Err(NoSuchTarget)
					(Ok(_), Member) if is_first_admin(human) => Err(FirstAdmin)
					(Ok(_), _) => Ok([SetRole({ human, role })])
				}

			Retire(target) =>
				match Principal.find(accounts, target) {
					Err(_) => Err(NoSuchTarget)
					Ok(Human(h)) =>
						if is_first_admin(h.id) {
							Err(FirstAdmin)
						} else {
							Ok(retirement(h.id, accounts))
						}
					Ok(Agent(_)) | Ok(Bot(_)) => Ok([RevokeKeysOf(target), RemoveAccount(target)])
				}
		}
	match steps {
		Err(why) => Err(why)
		Ok(plan) => if (
			has_admin(
				Admin.applied(
					plan,
					{ accounts, settings },
				).accounts,
			)
		) Ok(plan) else Err(LastAdmin)
	}
}

## **A HUMAN'S RETIREMENT, AS ONE PLAN**: their GitHub id barred first;
## their sessions and keys revoked; each agent and bot they own retired, its
## keys revoked; their public votes withdrawn; their account removed last.
retirement : Principal.GitHubId, List(Principal) -> List(Admin.Step)
retirement = |human, accounts| {
	owned = List.join_map(
		accounts,
		|p|
			match p {
				Agent(a) if a.owner == human => [
					RevokeKeysOf(Principal.id(p)),
					RemoveAccount(Principal.id(p)),
				]
				Bot(b) if b.owner == human => [
					RevokeKeysOf(Principal.id(p)),
					RemoveAccount(Principal.id(p)),
				]
				_ => []
			},
	)
	[
		Bar(human),
		RevokeSessionsOf(human),
		RevokeKeysOf(Principal.Id.Human(human)),
	]
		.concat(owned)
		.concat([WithdrawVotes(human), RemoveAccount(Principal.Id.Human(human))])
}

## Some human among `accounts` is an admin.
has_admin : List(Principal) -> Bool
has_admin = |accounts|
	List.any(
		accounts,
		|p|
			match p {
				Human(h) => h.role == Admin
				Agent(_) | Bot(_) => Bool.False
			},
	)

## `action` retires `actor` itself, or the human its authority comes from.
is_own_authority : Admin.Action, Principal -> Bool
is_own_authority = |action, actor|
	match action {
		Retire(target) => {
			backer = Principal.Id.Human(Principal.answers_to(actor))
			target == Principal.id(actor) or target == backer
		}
		ListAccounts | RevokeKeys(_) | RevokeSessions(_) | SetRole(_) | ReadCounters => Bool.False
	}

## `action` sets the role of the human `actor` answers to.
is_own_role : Admin.Action, Principal -> Bool
is_own_role = |action, actor|
	match action {
		SetRole({ human, role: _ }) => human == Principal.answers_to(actor)
		ListAccounts | Retire(_) | RevokeKeys(_) | RevokeSessions(_) | ReadCounters => Bool.False
	}

## **`action` TAKES A SESSION**: it sets a role, or lifts a bar, or acts on
## an admin, or on an agent or a bot an admin owns, as the accounts say now.
is_session_only : Admin.Action, List(Principal) -> Bool
is_session_only = |action, accounts|
	match action {
		SetRole(_) => Bool.True
		Retire(target) | RevokeKeys(target) => is_admins(accounts, target)
		RevokeSessions(human) => is_admins(accounts, Principal.Id.Human(human))
		ListAccounts | ReadCounters => Bool.False
	}

## **THE PRINCIPAL `target` IS AN ADMIN, OR ANSWERS TO ONE**, among
## `accounts`. A target no account holds answers to nobody: acting on it
## touches no admin. A target, or its owner, that more than one account
## holds (a forged copy beside it) might be an admin's: it is taken as one,
## so a key never acts on it.
is_admins : List(Principal), Principal.Id -> Bool
is_admins = |accounts, target|
	match Principal.find(accounts, target) {
		Err(NoSuchPrincipal) => Bool.False
		Err(Duplicated) => Bool.True
		Ok(found) =>
			match Principal.human_account(accounts, Principal.answers_to(found)) {
				Ok(h) => h.role == Admin
				Err(Duplicated) => Bool.True
				Err(NoSuchPrincipal) => Bool.False
			}
	}

# The cast:
#   boss        an admin human, and the first admin
#   ann         a member human
#   cal         another admin human
#   boss_agent  an agent boss owns, with an admin-only key
#   ann_agent   an agent ann owns, with a read-and-post key
#   ann_bot     a bot ann owns
#   cal_agent   an agent cal owns
cal : Principal
cal = Cast.person(4, Admin)

ann_bot : Principal
ann_bot = Cast.owned(Bot, { id: 6, owner: 2 })

cal_agent : Principal
cal_agent = Cast.owned(Agent, { id: 5, owner: 4 })

accounts : List(Principal)
accounts = [
	Cast.boss,
	Cast.ann,
	cal,
	Cast.boss_agent,
	Cast.ann_agent,
	ann_bot,
	cal_agent,
]

## Boss is the first admin; GitHub id 66 is barred.
settings : Accounts.Settings
settings = {
	first_admin: Named(Cast.gid(1)),
	barred: [Cast.gid(66)],
	next_generation: Cast.gen(9),
	next_agent_id: Cast.aid(20),
}

admin_only : ApiKey.Scope(Str)
admin_only = {
	read: Off,
	post: Off,
	admin: On,
}

with_admin : ApiKey.Scope(Str)
with_admin = {
	read: On(Everywhere),
	post: On(Everywhere),
	admin: On,
}

plain : ApiKey.Scope(Str)
plain = {
	read: On(Everywhere),
	post: On(Everywhere),
	admin: Off,
}

## Human `who`'s session `n`, signed in at `at` to the account made at 1,
## as the store holds it.
session_of : {
	n : U64,
	who : U64,
	at : I64,
} -> Session
session_of = |
	{
		n,
		who,
		at,
	},
|
	match SessionCodec.decode(Str.to_utf8("session v1 id=${n.to_str()} human=${who.to_str()} generation=1 token=${Str.repeat("01", 32)} created=${at.to_str()} seen=${at.to_str()}\n")) {
		Ok(line) => Session.load(line)
		Err(_) => crash "session_of: a test's session line decodes"
	}

## Key number `key` acting as `acts_as`, granted from its owner's session,
## expiring at 101000.
key_for : Principal, { scope : ApiKey.Scope(Str), key : U64 } -> ApiKey.Key(Str, Str)
key_for = |acts_as, { scope, key }|
	match ApiKey.Key.issue(
		{
			granter: Session(
				session_of({
					n: 9,
					who: Principal.answers_to(acts_as).to_u64(),
					at: 100000,
				}),
			),
			acts_as: Principal.id(acts_as),
			scope,
			accounts,
			now: 100000,
		},
		{ key: Cast.kid(key), expires: 101000 },
	) {
		Ok(made) => made
		Err(Refused(_)) => crash "key_for: a test's key is grantable"
	}

# The credentials: sessions signed in at 100000, one a day before 100500
# (idle by 100500, when the table is decided).
boss_session : Admin.Credential(Str, Str)
boss_session = Session(
	session_of({
		n: 1,
		who: 1,
		at: 100000,
	}),
)

ann_session : Admin.Credential(Str, Str)
ann_session = Session(
	session_of({
		n: 2,
		who: 2,
		at: 100000,
	}),
)

cal_session : Admin.Credential(Str, Str)
cal_session = Session(
	session_of({
		n: 4,
		who: 4,
		at: 100000,
	}),
)

boss_idle_session : Admin.Credential(Str, Str)
boss_idle_session = Session(
	session_of({
		n: 3,
		who: 1,
		at: 100500 - Session.idle_secs,
	}),
)

boss_agent_key : Admin.Credential(Str, Str)
boss_agent_key = Key(key_for(Cast.boss_agent, { scope: admin_only, key: 1 }))

ann_agent_key : Admin.Credential(Str, Str)
ann_agent_key = Key(key_for(Cast.ann_agent, { scope: plain, key: 2 }))

boss_revoked_key : Admin.Credential(Str, Str)
boss_revoked_key = Key(key_for(Cast.boss, { scope: admin_only, key: 3 }).revoke())

## Boss's own admin key, live: an admin human's, not an agent's.
boss_own_key : Admin.Credential(Str, Str)
boss_own_key = Key(key_for(Cast.boss, { scope: with_admin, key: 4 }))

Verdict : [Permitted, Refused(Admin.Refusal)]

## The decision on `credential` attempting `action` at `now`, among `among`.
Attempt : { credential : Admin.Credential(Str, Str), action : Admin.Action }

When : { among : List(Principal), now : I64 }

decided : Attempt, When -> Admin.Decision
decided = |{ credential, action }, { among, now }| decision({
	credential,
	action,
	accounts: among,
	settings,
	now,
})

## A decision whose clock a test keeps in range.
decision : {
	credential : Admin.Credential(Str, Str),
	action : Admin.Action,
	accounts : List(Principal),
	settings : Accounts.Settings,
	now : I64,
} -> Admin.Decision
decision = |request|
	match Admin.decide(request) {
		Ok(d) => d
		Err(ClockOutOfRange) => crash "decision: a test's clock is in range"
	}

audited : Attempt, When -> Admin.Audit
audited = |attempt, at| decided(attempt, at).audit

## Among the cast, at time 100500.
usually : When
usually = { among: accounts, now: 100500 }

## The verdict on `credential` attempting `action`, as usually.
verdict : Admin.Credential(Str, Str), Admin.Action -> Verdict
verdict = |credential, action| audited({ credential, action }, usually).verdict

## The verdict on `credential` attempting `action` among `among`.
verdict_among : Admin.Credential(Str, Str), Admin.Action, List(Principal) -> Verdict
verdict_among = |
	credential,
	action,
	among,
| audited({ credential, action }, { among, now: 100500 }).verdict

## The plan of `credential` attempting `action`, as usually.
plan_of : Admin.Credential(Str, Str), Admin.Action -> List(Admin.Step)
plan_of = |credential, action| decided({ credential, action }, usually).plan

## The plan of `credential` attempting `action` among `among`.
plan_of_among : Admin.Credential(Str, Str), Admin.Action, List(Principal) -> List(Admin.Step)
plan_of_among = |
	credential,
	action,
	among,
| decided({ credential, action }, { among, now: 100500 }).plan

## The verdict on `credential` listing accounts among `among` at `now`.
lists : Admin.Credential(Str, Str), { among : List(Principal), now : I64 } -> Verdict
lists = |credential, at| audited({ credential, action: ListAccounts }, at).verdict

# The actions.
retire_ann_agent : Admin.Action
retire_ann_agent = Retire(Principal.id(Cast.ann_agent))

retire_boss : Admin.Action
retire_boss = Retire(Principal.id(Cast.boss))

revoke_ann_keys : Admin.Action
revoke_ann_keys = RevokeKeys(Principal.id(Cast.ann))

revoke_ann_sessions : Admin.Action
revoke_ann_sessions = RevokeSessions(Cast.gid(2))

promote_ann : Admin.Action
promote_ann = SetRole({ human: Cast.gid(2), role: Admin })

retire_cal : Admin.Action
retire_cal = Retire(Principal.id(cal))

revoke_cal_agent_keys : Admin.Action
revoke_cal_agent_keys = RevokeKeys(Principal.id(cal_agent))

# ── THE ADMIN TABLE
# Every credential against every action.

# boss's session: everything but retiring boss, another admin included.
expect verdict(boss_session, ListAccounts) == Permitted
expect verdict(boss_session, retire_ann_agent) == Permitted
expect verdict(boss_session, retire_boss) == Refused(RetiresOwnAuthority)
expect verdict(boss_session, revoke_ann_keys) == Permitted
expect verdict(boss_session, revoke_ann_sessions) == Permitted
expect verdict(boss_session, promote_ann) == Permitted
expect verdict(boss_session, retire_cal) == Permitted
expect verdict(boss_session, revoke_cal_agent_keys) == Permitted
expect verdict(boss_session, ReadCounters) == Permitted

# ann's session: a member, nothing.
expect verdict(ann_session, ListAccounts) == Refused(NotAdmin)
expect verdict(ann_session, retire_ann_agent) == Refused(NotAdmin)
expect verdict(ann_session, retire_boss) == Refused(NotAdmin)
expect verdict(ann_session, revoke_ann_keys) == Refused(NotAdmin)
expect verdict(ann_session, revoke_ann_sessions) == Refused(NotAdmin)
expect verdict(ann_session, promote_ann) == Refused(NotAdmin)
expect verdict(ann_session, retire_cal) == Refused(NotAdmin)
expect verdict(ann_session, revoke_cal_agent_keys) == Refused(NotAdmin)
expect verdict(ann_session, ReadCounters) == Refused(NotAdmin)

# boss's session, a day idle: nothing.
expect verdict(boss_idle_session, ListAccounts) == Refused(SessionExpired)
expect verdict(boss_idle_session, retire_ann_agent) == Refused(SessionExpired)
expect verdict(boss_idle_session, retire_boss) == Refused(SessionExpired)
expect verdict(boss_idle_session, revoke_ann_keys) == Refused(SessionExpired)
expect verdict(boss_idle_session, revoke_ann_sessions) == Refused(SessionExpired)
expect verdict(boss_idle_session, promote_ann) == Refused(SessionExpired)
expect verdict(boss_idle_session, retire_cal) == Refused(SessionExpired)
expect verdict(boss_idle_session, revoke_cal_agent_keys) == Refused(SessionExpired)
expect verdict(boss_idle_session, ReadCounters) == Refused(SessionExpired)

# boss_agent's admin key: as boss on members' accounts, but never retiring
# boss, never another admin or their agent, never a role, never a bar.
expect verdict(boss_agent_key, ListAccounts) == Permitted
expect verdict(boss_agent_key, retire_ann_agent) == Permitted
expect verdict(boss_agent_key, retire_boss) == Refused(RetiresOwnAuthority)
expect verdict(boss_agent_key, revoke_ann_keys) == Permitted
expect verdict(boss_agent_key, revoke_ann_sessions) == Permitted
expect verdict(boss_agent_key, promote_ann) == Refused(NeedsSession)
expect verdict(boss_agent_key, retire_cal) == Refused(NeedsSession)
expect verdict(boss_agent_key, revoke_cal_agent_keys) == Refused(NeedsSession)
expect verdict(boss_agent_key, ReadCounters) == Permitted

# **BOSS'S OWN LIVE ADMIN KEY**: an admin
# human's key is still a key: on another admin, a role or a bar, it takes
# boss's session.
expect verdict(boss_own_key, ListAccounts) == Permitted
expect verdict(boss_own_key, retire_ann_agent) == Permitted
expect verdict(boss_own_key, retire_boss) == Refused(RetiresOwnAuthority)
expect verdict(boss_own_key, revoke_ann_keys) == Permitted
expect verdict(boss_own_key, revoke_ann_sessions) == Permitted
expect verdict(boss_own_key, promote_ann) == Refused(NeedsSession)
expect verdict(boss_own_key, retire_cal) == Refused(NeedsSession)
expect verdict(boss_own_key, revoke_cal_agent_keys) == Refused(NeedsSession)
expect verdict(boss_own_key, RevokeSessions(Cast.gid(4))) == Refused(NeedsSession)
expect verdict(boss_own_key, SetRole({ human: Cast.gid(4), role: Member })) == Refused(NeedsSession)
expect verdict(boss_own_key, ReadCounters) == Permitted

# ann_agent's key, without admin: nothing.
expect verdict(ann_agent_key, ListAccounts) == Refused(KeyRefused(OutOfScope))
expect verdict(ann_agent_key, retire_ann_agent) == Refused(KeyRefused(OutOfScope))
expect verdict(ann_agent_key, retire_boss) == Refused(KeyRefused(OutOfScope))
expect verdict(ann_agent_key, revoke_ann_keys) == Refused(KeyRefused(OutOfScope))
expect verdict(ann_agent_key, revoke_ann_sessions) == Refused(KeyRefused(OutOfScope))
expect verdict(ann_agent_key, promote_ann) == Refused(KeyRefused(OutOfScope))
expect verdict(ann_agent_key, retire_cal) == Refused(KeyRefused(OutOfScope))
expect verdict(ann_agent_key, revoke_cal_agent_keys) == Refused(KeyRefused(OutOfScope))
expect verdict(ann_agent_key, ReadCounters) == Refused(KeyRefused(OutOfScope))

# boss's own admin key, revoked: nothing.
expect verdict(boss_revoked_key, ListAccounts) == Refused(KeyRefused(Revoked))
expect verdict(boss_revoked_key, retire_ann_agent) == Refused(KeyRefused(Revoked))
expect verdict(boss_revoked_key, retire_boss) == Refused(KeyRefused(Revoked))
expect verdict(boss_revoked_key, revoke_ann_keys) == Refused(KeyRefused(Revoked))
expect verdict(boss_revoked_key, revoke_ann_sessions) == Refused(KeyRefused(Revoked))
expect verdict(boss_revoked_key, promote_ann) == Refused(KeyRefused(Revoked))
expect verdict(boss_revoked_key, retire_cal) == Refused(KeyRefused(Revoked))
expect verdict(boss_revoked_key, revoke_cal_agent_keys) == Refused(KeyRefused(Revoked))
expect verdict(boss_revoked_key, ReadCounters) == Refused(KeyRefused(Revoked))

demoted : List(Principal)
demoted = [Cast.boss_demoted, Cast.boss_agent]

# The edges: an agent retiring itself; boss's session once boss is
# retired or demoted, and a year on; boss_agent's key once boss is
# demoted, and once expired (it expires at 101000).
expect verdict(
	boss_agent_key,
	Retire(Principal.id(Cast.boss_agent)),
) == Refused(RetiresOwnAuthority)
expect lists(boss_session, { among: [Cast.ann], now: 100500 }) == Refused(NoSuchPrincipal)
expect lists(boss_session, { among: [Cast.boss_demoted], now: 100500 }) == Refused(NotAdmin)
expect lists(boss_session, { among: accounts, now: 100000 + 31536000 }) == Refused(SessionExpired)
expect lists(
	boss_agent_key,
	{ among: demoted, now: 100500 },
) == Refused(KeyRefused(BeyondPrincipal))
expect lists(boss_agent_key, { among: accounts, now: 100999 }) == Permitted
expect lists(boss_agent_key, { among: accounts, now: 101000 }) == Refused(KeyRefused(Expired))

# Setting a role: never one's own, by session or key; a demotion of another
# admin by session is allowed, and by a key is not.
expect verdict(boss_session, SetRole({ human: Cast.gid(1), role: Member })) == Refused(SetsOwnRole)
expect verdict(
	boss_agent_key,
	SetRole({ human: Cast.gid(1), role: Member }),
) == Refused(SetsOwnRole)
expect verdict(boss_session, SetRole({ human: Cast.gid(4), role: Member })) == Permitted
expect verdict(
	boss_agent_key,
	SetRole({ human: Cast.gid(4), role: Member }),
) == Refused(NeedsSession)

# A key on an admin's own side touches no admin either: boss's sessions,
# boss's agent's keys (itself included) take boss's session.
expect verdict(boss_agent_key, RevokeSessions(Cast.gid(1))) == Refused(NeedsSession)
expect verdict(boss_agent_key, RevokeKeys(Principal.id(Cast.boss_agent))) == Refused(NeedsSession)
expect verdict(boss_agent_key, RevokeSessions(Cast.gid(4))) == Refused(NeedsSession)
# A target no account holds touches no admin: its keys may be revoked.
expect verdict(boss_agent_key, RevokeKeys(Principal.Id.Agent(Cast.aid(9)))) == Permitted

# ── THE BOOTSTRAP ADMIN, AND THE SNAPSHOT
# Boss is the first admin: cal, another admin, can neither demote nor
# retire boss; cal can promote and demote anyone else, and boss cal.
expect verdict(cal_session, retire_boss) == Refused(FirstAdmin)
expect verdict(
	cal_session,
	SetRole({ human: Cast.gid(1), role: Member }),
) == Refused(FirstAdmin)
expect verdict(cal_session, SetRole({ human: Cast.gid(1), role: Admin })) == Permitted
expect verdict(cal_session, promote_ann) == Permitted
expect verdict(cal_session, RevokeSessions(Cast.gid(1))) == Permitted
expect verdict(boss_session, SetRole({ human: Cast.gid(4), role: Member })) == Permitted

# A role set on an id no account holds is refused; so is a retirement.
expect verdict(boss_session, SetRole({ human: Cast.gid(99), role: Admin })) == Refused(NoSuchTarget)
expect verdict(boss_session, Retire(Principal.Id.Human(Cast.gid(99)))) == Refused(NoSuchTarget)
expect verdict(boss_session, Retire(Principal.Id.Agent(Cast.aid(99)))) == Refused(NoSuchTarget)

# **TWO ADMINS RETIRING EACH OTHER**: with no first admin named, each
# retirement is allowed against the same snapshot (one admin is left by
# each). The host applies plans one at a time, each decided against the
# accounts the last left: once boss's plan is applied, cal's session
# admits nobody, and cal's retirement of boss is refused.
two_admins : List(Principal)
two_admins = [Cast.boss, cal]

unbootstrapped : Attempt -> Verdict
unbootstrapped = |{ credential, action }|
	decision({
		credential,
		action,
		accounts: two_admins,
		settings: {
			first_admin: Unnamed,
			barred: [],
			next_generation: Cast.gen(9),
			next_agent_id: Cast.aid(20),
		},
		now: 100500,
	}).audit.verdict

expect unbootstrapped({ credential: boss_session, action: retire_cal }) == Permitted
expect unbootstrapped({ credential: cal_session, action: retire_boss }) == Permitted

after_boss_retired_cal : List(Principal)
after_boss_retired_cal = Admin.applied(
	decision({
		credential: boss_session,
		action: retire_cal,
		accounts: two_admins,
		settings: {
			first_admin: Unnamed,
			barred: [],
			next_generation: Cast.gen(9),
			next_agent_id: Cast.aid(20),
		},
		now: 100500,
	}).plan,
	{ accounts: two_admins, settings },
).accounts

expect List.map(after_boss_retired_cal, Principal.id) == [Principal.id(Cast.boss)]
expect verdict_among(
	cal_session,
	retire_boss,
	after_boss_retired_cal,
) == Refused(NoSuchPrincipal)
# And with boss the first admin, cal's retirement of boss is refused
# against the snapshot itself.
expect verdict_among(
	cal_session,
	retire_boss,
	two_admins,
) == Refused(FirstAdmin)

# **NO PLAN LEAVES NO ADMIN**: the backstop, on plans no actor reaches
# through the checks above (an admin cannot retire or demote themselves).
## The accounts `plan` leaves of the cast.
left : List(Admin.Step) -> List(Principal)
left = |plan| Admin.applied(plan, { accounts, settings }).accounts

expect !has_admin(left([RemoveAccount(Principal.id(Cast.boss)), RemoveAccount(Principal.id(cal))]))
expect !has_admin(
	left([
		SetRole({ human: Cast.gid(1), role: Member }),
		SetRole({ human: Cast.gid(4), role: Member }),
	]),
)
expect has_admin(left([SetRole({ human: Cast.gid(1), role: Member })]))
expect planned(Retire(Principal.id(cal)), { accounts: [cal], settings }) == Err(LastAdmin)
expect planned(
	SetRole({ human: Cast.gid(4), role: Member }),
	{ accounts: [cal, Cast.ann], settings },
) == Err(LastAdmin)

# ── RETIREMENT AS ONE ACTION
# Retiring ann: her id barred first; her sessions and keys revoked; her
# agent and her bot retired with their keys; her votes withdrawn; her
# account removed last. Retiring an agent: its keys, and its account.
expect
	plan_of(boss_session, Retire(Principal.id(Cast.ann)))
		== [
			Bar(Cast.gid(2)),
			RevokeSessionsOf(Cast.gid(2)),
			RevokeKeysOf(Principal.id(Cast.ann)),
			RevokeKeysOf(Principal.id(Cast.ann_agent)),
			RemoveAccount(Principal.id(Cast.ann_agent)),
			RevokeKeysOf(Principal.id(ann_bot)),
			RemoveAccount(Principal.id(ann_bot)),
			WithdrawVotes(Cast.gid(2)),
			RemoveAccount(Principal.id(Cast.ann)),
		]
expect plan_of(boss_session, retire_ann_agent) == [
	RevokeKeysOf(Principal.id(Cast.ann_agent)),
	RemoveAccount(Principal.id(Cast.ann_agent)),
]
expect
	List.map(left(ann_retired), Principal.id)
		== [
			Principal.id(Cast.boss),
			Principal.id(cal),
			Principal.id(Cast.boss_agent),
			Principal.id(cal_agent),
		]
# A refusal, and a read, plan nothing.
expect plan_of(ann_session, Retire(Principal.id(Cast.ann_agent))) == []
expect plan_of(boss_session, ListAccounts) == []
expect plan_of(boss_session, promote_ann) == [SetRole({ human: Cast.gid(2), role: Admin })]

# ATTACK: the bar comes first, so a crash part way
# through never leaves the id unbarred with its account gone; the account
# goes last.
ann_retired : List(Admin.Step)
ann_retired = plan_of(boss_session, Retire(Principal.id(Cast.ann)))

expect List.first(ann_retired) == Ok(Bar(Cast.gid(2)))
expect List.last(ann_retired) == Ok(RemoveAccount(Principal.id(Cast.ann)))

# **A PLAN APPLIED AGAIN AFTER A CRASH IS SAFE**: every prefix of the plan
# (the crash), then the whole plan (the re-run), leaves what the plan once
# does: the same accounts, ann barred once.
once : { accounts : List(Principal), settings : Accounts.Settings }
once = Admin.applied(ann_retired, { accounts, settings })

expect once.settings.barred == [Cast.gid(66), Cast.gid(2)]

## Each prefix's length: where a crash could cut the plan.
crash_points : List(U64)
crash_points = Iter.fold(
	U64.to(0, List.len(ann_retired)),
	[],
	|so_far, n| so_far.append(n),
)

expect
	List.all(
		crash_points,
		|n| {
			crashed = Admin.applied(List.take_first(ann_retired, n), { accounts, settings })
			again = Admin.applied(ann_retired, crashed)
			again.settings == once.settings and List.map(
				again.accounts,
				Principal.id,
			) == List.map(once.accounts, Principal.id)
		},
	)
# Twice whole, too; and a re-decision after the crash (the account half
# gone) plans what is left, the bar first again.
expect Admin.applied(
	List.concat(ann_retired, ann_retired),
	{ accounts, settings },
).settings == once.settings
half_gone : List(Principal)
half_gone = Admin.applied(List.take_first(ann_retired, 5), { accounts, settings }).accounts

expect List.first(
	plan_of_among(
		boss_session,
		Retire(Principal.id(Cast.ann)),
		half_gone,
	),
) == Ok(Bar(Cast.gid(2)))

# **A BAR IS FOR LIFE**: no action's plan, by anyone,
# takes an id off the barred list; there is no Unbar.
every_action : List(Admin.Action)
every_action = [
	ListAccounts,
	Retire(Principal.id(Cast.ann)),
	Retire(Principal.id(Cast.ann_agent)),
	Retire(Principal.id(cal)),
	RevokeKeys(Principal.id(Cast.ann)),
	RevokeSessions(Cast.gid(66)),
	SetRole({ human: Cast.gid(2), role: Admin }),
	SetRole({ human: Cast.gid(4), role: Member }),
	ReadCounters,
]

expect
	List.all(
		every_action,
		|action|
			List.all(
				[
					boss_session,
					cal_session,
					boss_agent_key,
					boss_own_key,
				],
				|credential| {
					barred = Admin.applied(
						plan_of(credential, action),
						{ accounts, settings },
					).settings.barred
					List.all(settings.barred, |b| List.contains(barred, b))
				},
			),
	)

# **RE-CREATION AFTER RETIREMENT**: ann retired, then made again with her id
# (a host bug, as a bar is for life) as generation 2: her old session admits
# nobody, so it is no admin either, even were the new account promoted.
ann_again_admin : Principal
ann_again_admin = Principal.Human({
	id: Cast.gid(2),
	login: "ann",
	name: "Ann",
	role: Admin,
	generation: Cast.gen(2),
})

expect verdict_among(
	ann_session,
	ListAccounts,
	[Cast.boss, ann_again_admin],
) == Refused(NoSuchPrincipal)

# ── DUPLICATE AND FORGED ACCOUNTS FIRST
# A copy of ann claiming admin, first: her session admits no copy.
ann_admin_first : List(Principal)
ann_admin_first = List.prepend(accounts, Cast.person(2, Admin))

expect verdict_among(
	ann_session,
	ListAccounts,
	ann_admin_first,
) == Refused(NoSuchPrincipal)
expect verdict_among(
	ann_session,
	promote_ann,
	ann_admin_first,
) == Refused(NoSuchPrincipal)
# A copy of boss's agent claiming ann as owner, first: its key administers
# nothing.
expect verdict_among(
	boss_agent_key,
	ListAccounts,
	List.prepend(accounts, Cast.owned(Agent, { id: 1, owner: 2 })),
) == Refused(KeyRefused(NoSuchPrincipal))
# A copy of cal's agent claiming ann as owner, first: a key cannot tell
# whose it is, so it takes a session; nor is either copy retired.
cal_agent_forged : List(Principal)
cal_agent_forged = List.prepend(accounts, Cast.owned(Agent, { id: 5, owner: 2 }))

expect verdict_among(
	boss_agent_key,
	revoke_cal_agent_keys,
	cal_agent_forged,
) == Refused(NeedsSession)
expect verdict_among(
	boss_session,
	Retire(Principal.id(cal_agent)),
	cal_agent_forged,
) == Refused(NoSuchTarget)

# ATTACK: an attempt under a clock past
# the store's range makes no audit the store cannot write.
expect
	List.all(
		[Stored.max_time + 1, -1],
		|now| Admin.decide({
			credential: boss_session,
			action: ListAccounts,
			accounts,
			settings,
			now,
		}).map_ok(|d| d.audit.at) == Err(ClockOutOfRange),
	)
expect Admin.decide({
	credential: boss_session,
	action: ListAccounts,
	accounts,
	settings,
	now: 100500,
}).map_ok(|d| d.audit.at) == Ok(100500)

# ── THE AUDIT RECORD
# Who, by which session or key, what, when: for a permitted action and a
# refused one alike.
permitted_audit : Admin.Audit
permitted_audit = audited(
	{ credential: boss_agent_key, action: revoke_ann_keys },
	{ among: accounts, now: 100500 },
)

expect permitted_audit.who == Principal.id(Cast.boss_agent)
expect permitted_audit.via == Key(Cast.kid(1))
expect permitted_audit.action == revoke_ann_keys
expect permitted_audit.at == 100500
expect permitted_audit.verdict == Permitted

refused_audit : Admin.Audit
refused_audit = audited(
	{ credential: ann_session, action: retire_boss },
	{ among: accounts, now: 100077 },
)

expect refused_audit.who == Principal.id(Cast.ann)
expect refused_audit.via == Session(Cast.sid(2))
expect refused_audit.action == retire_boss
expect refused_audit.at == 100077
expect refused_audit.verdict == Refused(NotAdmin)

role_audit : Admin.Audit
role_audit = audited(
	{ credential: boss_session, action: promote_ann },
	{ among: accounts, now: 100600 },
)

expect role_audit.who == Principal.id(Cast.boss)
expect role_audit.via == Session(Cast.sid(1))
expect role_audit.action == promote_ann
expect role_audit.verdict == Permitted
expect role_audit.plan == [SetRole({ human: Cast.gid(2), role: Admin })]

# **THE WHOLE PLAN IS AUDITED**: a
# retirement's audit holds every step, the agent and bot retired with ann
# and her votes withdrawn among them; a refusal's holds none.
expect audited(
	{ credential: boss_session, action: Retire(Principal.id(Cast.ann)) },
	usually,
).plan == ann_retired
expect List.contains(
	ann_retired,
	RemoveAccount(Principal.id(ann_bot)),
) and List.contains(ann_retired, WithdrawVotes(Cast.gid(2)))
expect refused_audit.plan == []

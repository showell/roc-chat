## **WHO IS ACTING** (the Roc chat's auth design, section 1): every request
## acts as exactly one principal, a human signed in with GitHub, or an agent
## or a bot a human owns. Each kind's id is a type of its own, so a GitHub
## id, an agent's id and a key's id cannot be passed for one another. Pure;
## nothing here knows of conversations, so a resource other than the chat's
## (a database, a file system) takes the same principals.
Principal := [
	## A person, signed in with GitHub. Keyed by GitHub's numeric id, which
	## never changes; the login (which can) is kept for display and the
	## GitHub link, and is empty once GitHub has given it to another account
	## that signed in here since (so it never links to the new owner). The
	## name is the one they chose, real or not. Every kind's `generation`
	## is its account's (see Generation).
	Human(
		{
			id : Principal.GitHubId,
			login : Str,
			name : Str,
			role : Principal.Role,
			generation : Principal.Generation,
		},
	),

	## An account a human made and owns (Claude, CC): it never signs in
	## through a browser, and acts only through API keys.
	Agent(
		{
			id : Principal.AgentId,
			name : Str,
			owner : Principal.GitHubId,
			generation : Principal.Generation,
		},
	),

	## An integration (the GitHub commit bot), fed by an outside system's
	## webhook rather than a model; owned by a human, as an agent is.
	Bot(
		{
			id : Principal.AgentId,
			name : Str,
			owner : Principal.GitHubId,
			generation : Principal.Generation,
		},
	),
].{

	## **AN ACCOUNT'S GENERATION**: a number the host's one counter gives
	## each account as it is made (GitHubSignIn's Settings hold the next),
	## never given twice, so it never repeats for an id. Sessions, keys,
	## votes and a conversation's participants are bound to the generation
	## of the account they were made for (Bound), so an id made again, by
	## a host bug or a future lifting of a bar, revives nothing; a time
	## would not do, as two accounts can be made in one second, or under a
	## clock that went back. Opaque: made only by `from_u64`, which refuses
	## 0.
	Generation :: U64.{
		from_u64 : U64 -> Try(Principal.Generation, [NotAnId])
		from_u64 = |n| if n == 0 Err(NotAnId) else Ok(Principal.Generation.(n))

		to_u64 : Principal.Generation -> U64
		to_u64 = |Principal.Generation.(n)| n

		## The generation after this one, unless the counter is spent.
		next : Principal.Generation -> Try(Principal.Generation, [Exhausted])
		next = |Principal.Generation.(n)|
			if n == u64_most Err(Exhausted) else Ok(Principal.Generation.(n + 1))

		is_eq : _
	}

	## **A PRINCIPAL, BOUND TO ITS ACCOUNTS**: its id, its account's
	## generation, and the generation of the human account it answers to
	## (itself, for a human). What a session, a key and a participant hold:
	## it names the principal only while both accounts are still the ones
	## it was bound to (`holds`).
	Bound : {
		id : Principal.Id,
		generation : Principal.Generation,
		human : Principal.Generation,
	}

	## The principal's account's generation.
	generation : Principal -> Principal.Generation
	generation = |principal|
		match principal {
			Human(h) => h.generation
			Agent(a) => a.generation
			Bot(b) => b.generation
		}

	## **`wanted`, BOUND AS THE ACCOUNTS ARE NOW**: found as `find` finds it,
	## and the human it answers to held by exactly one account.
	bind : List(Principal), Principal.Id -> Try(Principal.Bound, [NoSuchPrincipal, Duplicated])
	bind = |accounts, wanted| {
		principal = Principal.find(accounts, wanted)?
		human = Principal.human_account(accounts, Principal.answers_to(principal))?
		Ok({
			id: wanted,
			generation: Principal.generation(principal),
			human: human.generation,
		})
	}

	## **THE PRINCIPAL A BINDING STILL NAMES**: its id held by exactly one
	## account, of the bound generation, and the human it answers to held
	## by exactly one account, of the bound generation too. Every check of a
	## stored binding (a session, a key, a participant) asks here.
	holds : List(Principal), Principal.Bound -> Try(Principal, [NoSuchPrincipal])
	holds = |accounts, bound|
		match Principal.bind(accounts, bound.id) {
			Ok(now) if now == bound =>
				match Principal.find(accounts, bound.id) {
					Ok(p) => Ok(p)
					Err(_) => crash "Principal.holds: `bind` found it"
				}
			_ => Err(NoSuchPrincipal)
		}

	## **A HUMAN'S ROLE**: an admin manages accounts (Admin.roc); set for
	## the first account by the bootstrap setting, changed only by an admin.
	Role : [Admin, Member]

	## GitHub's numeric user id, as GitHub's `/user` gives it. Opaque: made
	## only by `from_u64`, which refuses 0 (GitHub's ids start at 1, and a
	## 0 is what a field that failed to decode reads as).
	GitHubId :: U64.{
		from_u64 : U64 -> Try(Principal.GitHubId, [NotAnId])
		from_u64 = |n| if n == 0 Err(NotAnId) else Ok(Principal.GitHubId.(n))

		to_u64 : Principal.GitHubId -> U64
		to_u64 = |Principal.GitHubId.(n)| n

		is_eq : _
	}

	## An agent's or a bot's id, from the chat's own counter (one counter
	## for both kinds). Opaque: made only by `from_u64`, which refuses 0.
	AgentId :: U64.{
		from_u64 : U64 -> Try(Principal.AgentId, [NotAnId])
		from_u64 = |n| if n == 0 Err(NotAnId) else Ok(Principal.AgentId.(n))

		to_u64 : Principal.AgentId -> U64
		to_u64 = |Principal.AgentId.(n)| n

		## The id after this one, unless the counter is spent.
		next : Principal.AgentId -> Try(Principal.AgentId, [Exhausted])
		next = |Principal.AgentId.(n)|
			if n == u64_most Err(Exhausted) else Ok(Principal.AgentId.(n + 1))

		is_eq : _
	}

	## An API key's public id, shown in lists and written in the audit
	## trail; never the key's secret. Opaque: made only by `from_u64`,
	## which refuses 0.
	KeyId :: U64.{
		from_u64 : U64 -> Try(Principal.KeyId, [NotAnId])
		from_u64 = |n| if n == 0 Err(NotAnId) else Ok(Principal.KeyId.(n))

		to_u64 : Principal.KeyId -> U64
		to_u64 = |Principal.KeyId.(n)| n

		is_eq : _
	}

	## A sign-in session's public number, written in the audit trail; never
	## the cookie's random value, which is the session's secret. Opaque:
	## made only by `from_u64`, which refuses 0.
	SessionId :: U64.{
		from_u64 : U64 -> Try(Principal.SessionId, [NotAnId])
		from_u64 = |n| if n == 0 Err(NotAnId) else Ok(Principal.SessionId.(n))

		to_u64 : Principal.SessionId -> U64
		to_u64 = |Principal.SessionId.(n)| n

		is_eq : _
	}

	## **WHICH PRINCIPAL, BY ID ALONE**: what a participant list, a key's
	## `acts_as` and the audit trail hold. Two principals are the same one
	## when their ids are equal; a name or a role is no part of it.
	Id := [
		Human(Principal.GitHubId),
		Agent(Principal.AgentId),
		Bot(Principal.AgentId),
	].{
		is_eq : _
	}

	## The principal's id.
	id : Principal -> Principal.Id
	id = |principal|
		match principal {
			Human(h) => Principal.Id.Human(h.id)
			Agent(a) => Principal.Id.Agent(a.id)
			Bot(b) => Principal.Id.Bot(b.id)
		}

	## **THE HUMAN A PRINCIPAL ANSWERS TO**: a human, itself; an agent or a
	## bot, its owner.
	answers_to : Principal -> Principal.GitHubId
	answers_to = |principal|
		match principal {
			Human(h) => h.id
			Agent(a) => a.owner
			Bot(b) => b.owner
		}

	## **THE ONE PRINCIPAL WITH ID `wanted` AMONG `accounts`**: found only
	## when exactly one account holds the id. `NoSuchPrincipal` when none
	## does (never made, or retired); `Duplicated` when more than one does
	## (a forged copy beside the real one), so no copy, first or last, is
	## ever taken for the account. Every decision finds through here.
	find : List(Principal), Principal.Id -> Try(Principal, [NoSuchPrincipal, Duplicated])
	find = |accounts, wanted|
		match List.keep_if(accounts, |p| Principal.id(p) == wanted) {
			[only] => Ok(only)
			[] => Err(NoSuchPrincipal)
			_ => Err(Duplicated)
		}

	## **THE ONE HUMAN ACCOUNT WITH GITHUB ID `human`**, as `find` finds it.
	human_account : List(Principal),
	Principal.GitHubId -> Try(
		{
			id : Principal.GitHubId,
			login : Str,
			name : Str,
			role : Principal.Role,
			generation : Principal.Generation,
		},
		[NoSuchPrincipal, Duplicated],
	)
	human_account = |accounts, human|
		match find(accounts, Principal.Id.Human(human)) {
			Ok(Human(h)) => Ok(h)
			Ok(Agent(_)) | Ok(Bot(_)) => crash "Principal.human_account: a human's id finds a human"
			Err(why) => Err(why)
		}

	## The human with GitHub id `human` has one account among `accounts`:
	## what an agent's key, and a human's election, stand on.
	has_account : List(Principal), Principal.GitHubId -> Bool
	has_account = |accounts, human| human_account(accounts, human).is_ok()

	## **THE AUTHORITY A PRINCIPAL ACTS WITH, AS THE ACCOUNTS SAY NOW**
	## (design section 9): `Admin` for an admin human, and for an agent
	## whose owner is an admin human among `accounts`; `Member` for anyone
	## else. A bot is never `Admin`: the design grants admin to "an agent an
	## admin owns", and a bot is fed by an outside system. Read from the
	## accounts at each request (the human's own record too, never the
	## caller's copy), so an owner's demotion or retirement takes their
	## agent's authority with it; a human without exactly one account has
	## none.
	authority : Principal, List(Principal) -> Principal.Role
	authority = |principal, accounts|
		match principal {
			Bot(_) => Member
			Human(_) | Agent(_) =>
				match human_account(accounts, Principal.answers_to(principal)) {
					Ok(h) => h.role
					Err(_) => Member
				}
		}

	## **THE ACCOUNTS LOADER'S CHECK**: `accounts` as they are, when no two
	## hold one id; else the first id held twice. An agent and a bot share
	## one counter, so `agent:7` beside `bot:7` is a duplicate too. A store
	## with a duplicate is refused whole, never loaded with one copy chosen.
	##
	## **IN O(n log n)**, as every request's load needs: the accounts sorted
	## by their number, each with its place, so a duplicate is the next one
	## sorted; of the duplicates, the one earliest in the list (of each
	## pair, the later) is the one a scan in order would meet first.
	unique : List(Principal) -> Try(List(Principal), [DuplicateId(Principal.Id)])
	unique = |accounts| {
		keyed = List.map_with_index(
			accounts,
			|p, at| {
				(kind, number) =
					match Principal.id(p) {
						Human(g) => (0, g.to_u64())
						Agent(a) | Bot(a) => (1, a.to_u64())
					}
				{ kind, number, at }
			},
		)
		sorted = List.sort_with(
			keyed,
			|x, y|
				if x.kind != y.kind {
					if x.kind < y.kind Before else After
				} else if x.number != y.number {
					if x.number < y.number Before else After
				} else if x.at < y.at {
					Before
				} else if x.at > y.at {
					After
				} else {
					Same
				},
		)
		first_dup = List.fold_with_index(
			sorted,
			List.len(accounts),
			|earliest, k, i|
				match List.get(sorted, i + 1) {
					Ok(next) =>
						if next.kind == k.kind and next.number == k.number and next.at < earliest {
							next.at
						} else {
							earliest
						}
					Err(_) => earliest
				},
		)
		match List.get(accounts, first_dup) {
			Ok(p) => Err(DuplicateId(Principal.id(p)))
			Err(_) => Ok(accounts)
		}
	}
}

## The largest U64: a generation counter that reaches it is spent.
u64_most : U64
u64_most = 18446744073709551615

gid : U64 -> Principal.GitHubId
gid = |n|
	match Principal.GitHubId.from_u64(n) {
		Ok(id) => id
		Err(NotAnId) => crash "gid: a test's GitHub id is not 0"
	}

aid : U64 -> Principal.AgentId
aid = |n|
	match Principal.AgentId.from_u64(n) {
		Ok(id) => id
		Err(NotAnId) => crash "aid: a test's agent id is not 0"
	}

gen : U64 -> Principal.Generation
gen = |n|
	match Principal.Generation.from_u64(n) {
		Ok(g) => g
		Err(NotAnId) => crash "gen: a test's generation is not 0"
	}

## A test's human: GitHub id `n`, its role, generation 1.
person : U64, Principal.Role -> Principal
person = |n, role|
	Principal.Human({
		id: gid(n),
		login: "h${n.to_str()}",
		name: "H${n.to_str()}",
		role,
		generation: gen(1),
	})

## A test's agent or bot: its id, and its owner's GitHub id; generation 1.
owned : [Agent, Bot], { id : U64, owner : U64 } -> Principal
owned = |kind, { id, owner }|
	match kind {
		Agent =>
			Principal.Agent({
				id: aid(id),
				name: "a${id.to_str()}",
				owner: gid(owner),
				generation: gen(1),
			})

		Bot =>
			Principal.Bot({
				id: aid(id),
				name: "b${id.to_str()}",
				owner: gid(owner),
				generation: gen(1),
			})
	}

boss : Principal
boss = person(1, Admin)

ann : Principal
ann = person(2, Member)

boss_agent : Principal
boss_agent = owned(Agent, { id: 1, owner: 1 })

boss_bot : Principal
boss_bot = owned(Bot, { id: 2, owner: 1 })

ann_agent : Principal
ann_agent = owned(Agent, { id: 3, owner: 2 })

## An agent whose owner is among no accounts.
orphan_agent : Principal
orphan_agent = owned(Agent, { id: 4, owner: 9 })

accounts : List(Principal)
accounts = [
	boss,
	ann,
	boss_agent,
	boss_bot,
	ann_agent,
	orphan_agent,
]

# The ids: 0 is refused for every kind, and kinds never compare equal.
expect Principal.GitHubId.from_u64(0) == Err(NotAnId)
expect Principal.AgentId.from_u64(0) == Err(NotAnId)
expect Principal.KeyId.from_u64(0) == Err(NotAnId)
expect Principal.SessionId.from_u64(0) == Err(NotAnId)
expect Principal.GitHubId.from_u64(583231).map_ok(Principal.GitHubId.to_u64) == Ok(583231)
expect Principal.Id.Agent(aid(1)) != Principal.Id.Bot(aid(1))
expect Principal.id(boss_agent) == Principal.Id.Agent(aid(1))
expect Principal.id(boss) == Principal.Id.Human(gid(1))

# answers_to: a human itself, an agent or a bot its owner.
expect Principal.answers_to(ann) == gid(2)
expect Principal.answers_to(boss_agent) == gid(1)
expect Principal.answers_to(boss_bot) == gid(1)

# find: by id, a name playing no part.
found : Principal.Id -> Try(Principal.Id, [NoSuchPrincipal, Duplicated])
found = |wanted| Principal.find(accounts, wanted).map_ok(Principal.id)

expect found(Principal.Id.Agent(aid(3))) == Ok(Principal.id(ann_agent))
expect found(Principal.Id.Bot(aid(3))) == Err(NoSuchPrincipal)
expect found(Principal.Id.Human(gid(9))) == Err(NoSuchPrincipal)

# **A DUPLICATE NAMES NOBODY**: a copy of
# ann's agent claiming boss as owner, first or last, is found as neither.
forged_ann_agent : Principal
forged_ann_agent = owned(Agent, { id: 3, owner: 1 })

expect Principal.find(
	List.prepend(accounts, forged_ann_agent),
	Principal.id(ann_agent),
).map_ok(Principal.id) == Err(Duplicated)
expect Principal.find(
	List.append(accounts, forged_ann_agent),
	Principal.id(ann_agent),
).map_ok(Principal.id) == Err(Duplicated)

# has_account: a human's id alone; an agent's id never names a human.
expect Principal.has_account(accounts, gid(2))
expect !Principal.has_account(accounts, gid(9))
expect !Principal.has_account([boss_agent], gid(1))

# authority: one row a principal.
expect Principal.authority(boss, accounts) == Admin
expect Principal.authority(ann, accounts) == Member
expect Principal.authority(boss_agent, accounts) == Admin
expect Principal.authority(boss_bot, accounts) == Member
expect Principal.authority(ann_agent, accounts) == Member
expect Principal.authority(orphan_agent, accounts) == Member
# The owner retired: the agent's authority went with them.
expect Principal.authority(boss_agent, [boss_agent]) == Member

# **THE ACCOUNTS' ROLE, NOT THE CALLER'S COPY**: a
# copy of ann claiming admin is no admin; nor is ann, once a duplicate
# admin line of her sits first in the accounts; nor her agent.
ann_admin_copy : Principal
ann_admin_copy = person(2, Admin)

with_ann_twice : List(Principal)
with_ann_twice = List.prepend(accounts, ann_admin_copy)

expect Principal.authority(ann_admin_copy, accounts) == Member
expect Principal.authority(ann, with_ann_twice) == Member
expect Principal.authority(ann_admin_copy, with_ann_twice) == Member
expect Principal.authority(ann_agent, with_ann_twice) == Member
expect !Principal.has_account(with_ann_twice, gid(2))
# A demoted boss in the accounts: boss's own copy, still saying admin, is
# no admin.
expect Principal.authority(boss, [person(1, Member)]) == Member

# **THE LOADER'S CHECK**: every id once, an agent's and a bot's numbers
# from one counter.
loaded : List(Principal) -> Try({}, [DuplicateId(Principal.Id)])
loaded = |list| Principal.unique(list).map_ok(|_| {})

expect loaded(accounts) == Ok({})
expect loaded([]) == Ok({})
expect loaded(with_ann_twice) == Err(DuplicateId(Principal.Id.Human(gid(2))))
expect loaded(
	List.append(
		accounts,
		forged_ann_agent,
	),
) == Err(DuplicateId(Principal.Id.Agent(aid(3))))
expect loaded([
	boss_agent,
	owned(Bot, { id: 1, owner: 1 }),
]) == Err(DuplicateId(Principal.Id.Bot(aid(1))))
expect loaded([boss, owned(Agent, { id: 1, owner: 1 })]) == Ok({})
# Of two duplicates, the one a scan in order meets first is named, whatever
# the sort's order of kinds.
expect loaded([boss, boss_agent, boss, owned(Bot, { id: 1, owner: 1 })]) == Err(DuplicateId(Principal.id(boss)))
expect loaded([boss_agent, boss, owned(Bot, { id: 1, owner: 1 }), boss]) == Err(DuplicateId(Principal.Id.Bot(aid(1))))
expect loaded([boss, boss, boss]) == Err(DuplicateId(Principal.id(boss)))

# ── GENERATIONS AND BINDINGS
expect Principal.Generation.from_u64(0) == Err(NotAnId)
expect gen(7).next() == Ok(gen(8))
expect gen(18446744073709551615).next() == Err(Exhausted)

ann_agent_bound : Principal.Bound
ann_agent_bound = {
	id: Principal.id(ann_agent),
	generation: gen(1),
	human: gen(1),
}

expect Principal.bind(accounts, Principal.id(ann_agent)) == Ok(ann_agent_bound)
expect Principal.bind(accounts, Principal.id(boss)) == Ok({
	id: Principal.id(boss),
	generation: gen(1),
	human: gen(1),
})
# An agent whose owner has no account binds to nothing.
expect Principal.bind(accounts, Principal.id(orphan_agent)) == Err(NoSuchPrincipal)
expect Principal.holds(
	accounts,
	ann_agent_bound,
).map_ok(Principal.id) == Ok(Principal.id(ann_agent))

## `accounts`, with `who` swapped for the same id at generation 2.
remade : Principal -> List(Principal)
remade = |who|
	List.map(
		accounts,
		|p|
			if Principal.id(p) != Principal.id(who) {
				p
			} else {
				match p {
					Human(h) => Principal.Human({ ..h, generation: gen(2) })
					Agent(a) => Principal.Agent({ ..a, generation: gen(2) })
					Bot(b) => Principal.Bot({ ..b, generation: gen(2) })
				}
			},
	)

# The agent made again with its id, or its owner made again with theirs:
# the binding names nobody. Retired, or held twice: nobody either.
expect Principal.holds(remade(ann_agent), ann_agent_bound).is_err()
expect Principal.holds(remade(ann), ann_agent_bound).is_err()
expect Principal.holds([boss, ann], ann_agent_bound).is_err()
expect Principal.holds(List.append(accounts, forged_ann_agent), ann_agent_bound).is_err()

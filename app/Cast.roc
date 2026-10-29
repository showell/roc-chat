## **THE TESTS' CAST**: the id makers and the principals the auth core's
## `expect`s share, made here once, so a change to how a principal is made
## is a change to this module alone. Nothing outside an `expect` uses it.
##
## **NEITHER PRINCIPAL NOR STORED CAN USE IT**: this module imports both,
## and Roc refuses an import cycle, so their own `expect`s keep their own
## makers. It imports nothing else, so every other core module can reach
## it; a helper whose type lives further up (a conversation's id, a
## session) stays in the modules that use it.
##
## A module whose cast differs (other ids, logins, names or generations)
## keeps its own, in that module: a name here means one value.
import Principal
import Stored

Cast := [].{

	## A test's GitHub id; 0, which the type refuses, crashes.
	gid : U64 -> Principal.GitHubId
	gid = |n|
		match Principal.GitHubId.from_u64(n) {
			Ok(id) => id
			Err(NotAnId) => crash "gid: a test's GitHub id is not 0"
		}

	## A test's agent or bot id; 0 crashes.
	aid : U64 -> Principal.AgentId
	aid = |n|
		match Principal.AgentId.from_u64(n) {
			Ok(id) => id
			Err(NotAnId) => crash "aid: a test's agent id is not 0"
		}

	## A test's account generation; 0 crashes.
	gen : U64 -> Principal.Generation
	gen = |n|
		match Principal.Generation.from_u64(n) {
			Ok(g) => g
			Err(NotAnId) => crash "gen: a test's generation is not 0"
		}

	## A test's API key id; 0 crashes.
	kid : U64 -> Principal.KeyId
	kid = |n|
		match Principal.KeyId.from_u64(n) {
			Ok(id) => id
			Err(NotAnId) => crash "kid: a test's key id is not 0"
		}

	## A test's session id; 0 crashes.
	sid : U64 -> Principal.SessionId
	sid = |n|
		match Principal.SessionId.from_u64(n) {
			Ok(id) => id
			Err(NotAnId) => crash "sid: a test's session id is not 0"
		}

	## A test's secret hash: 32 bytes of `b`.
	token : U8 -> Stored.SecretHash
	token = |b|
		match Stored.SecretHash.from_bytes(List.repeat(b, 32)) {
			Ok(h) => h
			Err(NotAHash) => crash "token: 32 bytes are a hash"
		}

	## A test's human: GitHub id `n`, login `h<n>`, name `H<n>`, its role,
	## generation 1.
	person : U64, Principal.Role -> Principal
	person = |n, role|
		Principal.Human({
			id: Cast.gid(n),
			login: "h${n.to_str()}",
			name: "H${n.to_str()}",
			role,
			generation: Cast.gen(1),
		})

	## A test's agent (named `a<id>`) or bot (`b<id>`): its id, and its
	## owner's GitHub id; generation 1.
	owned : [Agent, Bot], { id : U64, owner : U64 } -> Principal
	owned = |kind, { id, owner }|
		match kind {
			Agent =>
				Principal.Agent({
					id: Cast.aid(id),
					name: "a${id.to_str()}",
					owner: Cast.gid(owner),
					generation: Cast.gen(1),
				})

			Bot =>
				Principal.Bot({
					id: Cast.aid(id),
					name: "b${id.to_str()}",
					owner: Cast.gid(owner),
					generation: Cast.gen(1),
				})
		}

	## An admin human, GitHub id 1.
	boss : Principal
	boss = Cast.person(1, Admin)

	## Boss's copy once demoted: the same id, a member.
	boss_demoted : Principal
	boss_demoted = Cast.person(1, Member)

	## A member human, GitHub id 2.
	ann : Principal
	ann = Cast.person(2, Member)

	## An agent boss owns, id 1.
	boss_agent : Principal
	boss_agent = Cast.owned(Agent, { id: 1, owner: 1 })

	## A bot boss owns, id 2.
	boss_bot : Principal
	boss_bot = Cast.owned(Bot, { id: 2, owner: 1 })

	## An agent ann owns, id 3.
	ann_agent : Principal
	ann_agent = Cast.owned(Agent, { id: 3, owner: 2 })

	## Boss, ann, boss's agent and bot, and ann's agent.
	accounts : List(Principal)
	accounts = [
		Cast.boss,
		Cast.ann,
		Cast.boss_agent,
		Cast.boss_bot,
		Cast.ann_agent,
	]

	## `accounts` with ann retired, her agent left behind.
	without_ann : List(Principal)
	without_ann = [
		Cast.boss,
		Cast.boss_agent,
		Cast.boss_bot,
		Cast.ann_agent,
	]
}

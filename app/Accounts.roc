## **THE ACCOUNTS AND THEIR COUNTERS, CHANGED A STEP AT A TIME**: the
## settings every account change reads (the first admin, the barred ids, and
## the two counters that make an id or a generation once), the steps a
## change is made of, and what a step leaves (`applied`, their one home). A
## sign-in's plan (GitHubSignIn), an agent's making (Agents) and an admin's
## action (Admin) are each a list of these steps, so what a step means is
## decided here alone. Pure.
import Ascii
import Cast
import DisplayName
import Principal

Accounts := [].{

	## **THE SETTINGS EVERY ACCOUNT CHANGE READS**: the GitHub id of the
	## first admin, if any is named; the GitHub ids barred from signing up
	## again (their accounts retired); and the generation counter, the generation the next
	## account made is given (Principal.Generation), which the host stores
	## back advanced each time an account is made; and the agent-id counter,
	## the id the next agent or bot made is given, and the human-id counter,
	## the id the next human made is given, beside it and kept the same way,
	## so an id is never given twice (the design's section 13), not even the
	## id of an account retired since. The first admin and the barred are
	## GitHub's ids, as the config names them: GitHub accounts, resolved when
	## that account signs in.
	Settings : {
		first_admin : [Unnamed, Named(Principal.GitHubId)],
		barred : List(Principal.GitHubId),
		next_generation : Principal.Generation,
		next_agent_id : Principal.AgentId,
		next_human_id : Principal.HumanId,
	}

	## **WHO HOLDS THIS NAME, IF ANYONE?** The account, human, agent or bot,
	## whose name is the same as `name` (DisplayName.same: case folded, runs
	## of spaces collapsed), among `accounts`: one namespace for every
	## principal, so a name is taken whoever holds it.
	name_holder : List(Principal), Str -> [Held(Principal.Id), Free]
	name_holder = |accounts, name|
		match accounts.keep_if(|p| DisplayName.same(name_of(p), name)) {
			[holder, ..] => Held(holder.id())
			[] => Free
		}

	## **ONE STEP OF AN ACCOUNT CHANGE** (a sign-in's, an agent's making),
	## for the host to apply in order (`applied` says what each does). Steps, never whole records of an
	## existing account: a record copied at sign-in and stored later would
	## undo whatever changed meanwhile (a demotion). Each step is
	## idempotent, so a plan applied twice after a crash leaves what once
	## does.
	Change : [
		## Make the account, when no account holds its id: a new one, whose
		## record is the only copy.
		AddAccount(Principal),

		## Set the human's login, GitHub having renamed them.
		SetLogin({ human : Principal.HumanId, login : Str }),

		## Clear the human's login, while it is still `login` (in any case):
		## another account signed in with it, GitHub having given it away.
		ClearLogin({ human : Principal.HumanId, login : Str }),

		## Raise the settings' generation counter to at least this.
		AdvanceGeneration(Principal.Generation),

		## Raise the settings' agent-id counter to at least this.
		AdvanceAgentId(Principal.AgentId),

		## Raise the settings' human-id counter to at least this.
		AdvanceHumanId(Principal.HumanId),
	]

	## A login's bytes in lower case: GitHub's logins ignore case.
	lowered_login : Str -> List(U8)
	lowered_login = |login| login.to_utf8().map(Ascii.to_lowercase)

	## **WHAT A CHANGE'S STEPS LEAVE**: `accounts` and `settings` with each
	## step made, in order; the one home of what a step means.
	applied : List(Accounts.Change),
	{
		accounts : List(Principal),
		settings : Accounts.Settings,
	} -> { accounts : List(Principal), settings : Accounts.Settings }
	applied = |steps, start|
		steps.fold(
			start,
			|{ accounts, settings }, step|
				match step {
					AddAccount(account) =>
						if accounts.any(|a| a.id() == account.id()) {
							{ accounts, settings }
						} else {
							{ accounts: accounts.append(account), settings }
						}
					SetLogin({ human, login }) =>
						{
							accounts: with_human(
								accounts,
								human,
								|h| { ..h, login },
							),
							settings,
						}
					ClearLogin({ human, login }) =>
						{
							accounts: with_human(
								accounts,
								human,
								|h| if (Accounts.lowered_login(h.login) == Accounts.lowered_login(login)) {
									..h,
									login: "",
								} else h,
							),
							settings,
						}
					AdvanceGeneration(g) =>
						if g.to_u64() > settings.next_generation.to_u64() {
							{ accounts, settings: { ..settings, next_generation: g } }
						} else {
							{ accounts, settings }
						}
					AdvanceAgentId(id) =>
						if id.to_u64() > settings.next_agent_id.to_u64() {
							{ accounts, settings: { ..settings, next_agent_id: id } }
						} else {
							{ accounts, settings }
						}
					AdvanceHumanId(id) =>
						if id.to_u64() > settings.next_human_id.to_u64() {
							{ accounts, settings: { ..settings, next_human_id: id } }
						} else {
							{ accounts, settings }
						}
				},
		)

	## **A NEW HUMAN'S ID, AND THE COUNTER AFTER IT**: the settings' next,
	## when it is above every human's id (a counter that went back might
	## give one twice, as an agent id's might). Never a GitHub id: a human
	## is the chat's own, however they sign in.
	next_human_id : List(Principal),
	Accounts.Settings -> Try(
		{ this : Principal.HumanId, next : Principal.HumanId },
		[StaleHumanId, HumanIdsExhausted],
	)
	next_human_id = |accounts, settings| {
		this = settings.next_human_id
		if accounts.any(|a| human_id_of(a) >= this.to_u64()) {
			Err(StaleHumanId)
		} else {
			match this.next() {
				Ok(next) => Ok({ this, next })
				Err(Exhausted) => Err(HumanIdsExhausted)
			}
		}
	}

	## **A NEW AGENT'S OR BOT'S ID, AND THE COUNTER AFTER IT**: the
	## settings' next, when it is above every agent's and bot's id (a counter
	## that went back might give one twice, as a generation's might); one
	## counter for both kinds.
	next_agent_id : List(Principal),
	Accounts.Settings -> Try(
		{ this : Principal.AgentId, next : Principal.AgentId },
		[StaleAgentId, AgentIdsExhausted],
	)
	next_agent_id = |accounts, settings| {
		this = settings.next_agent_id
		if accounts.any(|a| agent_id_of(a) >= this.to_u64()) {
			Err(StaleAgentId)
		} else {
			match this.next() {
				Ok(next) => Ok({ this, next })
				Err(Exhausted) => Err(AgentIdsExhausted)
			}
		}
	}

	## **A NEW ACCOUNT'S GENERATION, AND THE COUNTER AFTER IT**: the
	## settings' next, when it is above every account's (a counter that went
	## back might give one twice); the one rule a sign-up and an agent's
	## making both ask.
	next_generation : List(Principal),
	Accounts.Settings -> Try(
		{ this : Principal.Generation, next : Principal.Generation },
		[StaleGeneration, GenerationsExhausted],
	)
	next_generation = |accounts, settings| {
		this = settings.next_generation
		if accounts.any(|a| a.generation().to_u64() >= this.to_u64()) {
			Err(StaleGeneration)
		} else {
			match this.next() {
				Ok(next) => Ok({ this, next })
				Err(Exhausted) => Err(GenerationsExhausted)
			}
		}
	}
}

## `accounts` with the human `human`'s record changed by `change`.
with_human : List(Principal),
Principal.HumanId,
(
	{
		id : Principal.HumanId,
		sign_in : Principal.SignIn,
		login : Str,
		name : Str,
		role : Principal.Role,
		generation : Principal.Generation,
	} -> {
		id : Principal.HumanId,
		sign_in : Principal.SignIn,
		login : Str,
		name : Str,
		role : Principal.Role,
		generation : Principal.Generation,
	}) -> List(Principal)
with_human = |
	accounts,
	human,
	change,
|
	accounts.map(
		|p|
			match p {
				Human(h) if h.id == human => Principal.Human(change(h))
				_ => p
			},
	)

## A human's id as a number; 0 for an agent or a bot, below every id.
human_id_of : Principal -> U64
human_id_of = |p|
	match p {
		Human(h) => h.id.to_u64()
		Agent(_) | Bot(_) => 0
	}

## An agent's or a bot's id as a number; 0 for a human, below every id.
agent_id_of : Principal -> U64
agent_id_of = |p|
	match p {
		Agent(a) | Bot(a) => a.id.to_u64()
		Human(_) => 0
	}

u64_most : U64
u64_most = 18446744073709551615

## A principal's name, whichever kind it is.
name_of : Principal -> Str
name_of = |p|
	match p {
		Human(h) => h.name
		Agent(a) => a.name
		Bot(b) => b.name
	}

# One namespace: a name is held whoever holds it, human, agent or bot, in
# any case and spacing; a near miss is free.
named : U64, Str -> Principal
named = |n, name| Principal.Human({
	id: Cast.hid(n),
	sign_in: Cast.github(n),
	login: "h${n.to_str()}",
	name,
	role: Member,
	generation: Cast.gen(1),
})

expect Accounts.name_holder(
	[named(1, "Debbie Benton")],
	"debbie  BENTON",
) == Held(Principal.Id.Human(Cast.hid(1)))
expect Accounts.name_holder(
	[Cast.owned(Agent, { id: 4, owner: 1 })],
	"A4",
) == Held(Principal.Id.Agent(Cast.aid(4)))
expect Accounts.name_holder(
	[Cast.owned(Bot, { id: 5, owner: 1 })],
	"b5",
) == Held(Principal.Id.Bot(Cast.aid(5)))
expect Accounts.name_holder([named(1, "Debbie Benton")], "Debbie Bento") == Free
expect Accounts.name_holder([named(1, "Ann")], "\u(0410)nn") == Free
expect Accounts.name_holder([], "Ann") == Free

## **THE ACCOUNTS AND THEIR COUNTERS, CHANGED A STEP AT A TIME**: the
## settings every account change reads (the first admin, the barred ids, and
## the two counters that make an id or a generation once), the steps a
## change is made of, and what a step leaves (`applied`, their one home). A
## sign-in's plan (GitHubSignIn), an agent's making (Agents) and an admin's
## action (Admin) are each a list of these steps, so what a step means is
## decided here alone. Pure.
import Ascii
import Principal

Accounts := [].{

	## **THE SETTINGS EVERY ACCOUNT CHANGE READS**: the GitHub id of the
	## first admin, if any is named; the GitHub ids barred from signing up
	## again (their accounts retired); and the generation counter, the generation the next
	## account made is given (Principal.Generation), which the host stores
	## back advanced each time an account is made; and the agent-id counter,
	## the id the next agent or bot made is given, beside it and kept the
	## same way, so an id is never given twice (the design's section 13),
	## not even the id of an agent retired since.
	Settings : {
		first_admin : [Unnamed, Named(Principal.GitHubId)],
		barred : List(Principal.GitHubId),
		next_generation : Principal.Generation,
		next_agent_id : Principal.AgentId,
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
		SetLogin({ human : Principal.GitHubId, login : Str }),

		## Clear the human's login, while it is still `login` (in any case):
		## another account signed in with it, GitHub having given it away.
		ClearLogin({ human : Principal.GitHubId, login : Str }),

		## Raise the settings' generation counter to at least this.
		AdvanceGeneration(Principal.Generation),

		## Raise the settings' agent-id counter to at least this.
		AdvanceAgentId(Principal.AgentId),
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
								|h| if (Accounts.lowered_login(h.login) == Accounts.lowered_login(login)) { ..h, login: "" } else h,
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
				},
		)

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

	## **THE AGENT-ID COUNTER A STORE WITHOUT ONE STARTS AT**: one more than
	## the highest agent or bot id among the accounts; 1 for none. What the
	## settings read as before they held the counter, so an old store stays
	## valid; from then on, the stored counter alone.
	agent_id_after : List(Principal) -> Try(Principal.AgentId, [AgentIdsExhausted])
	agent_id_after = |accounts| {
		most = accounts.fold(0, |m, a| if (agent_id_of(a) > m) agent_id_of(a) else m)
		if (most == u64_most) Err(AgentIdsExhausted) else Principal.AgentId.from_u64(most + 1).map_err(|_| AgentIdsExhausted)
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
Principal.GitHubId,
(
	{
		id : Principal.GitHubId,
		login : Str,
		name : Str,
		role : Principal.Role,
		generation : Principal.Generation,
	} -> {
		id : Principal.GitHubId,
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

## An agent's or a bot's id as a number; 0 for a human, below every id.
agent_id_of : Principal -> U64
agent_id_of = |p|
	match p {
		Agent(a) | Bot(a) => a.id.to_u64()
		Human(_) => 0
	}

u64_most : U64
u64_most = 18446744073709551615

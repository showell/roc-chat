## **SIGNING IN WITH GITHUB, AS A STATE MACHINE** (the Roc chat's auth
## design, sections 2 and 5): each step a state of its own, an opaque type
## only this module makes, and each transition a pure function of the state
## before it and the facts a host supplies. A host answers facts (the
## state's signature held, the nonce was spent before, GitHub said who
## this is); every verdict is here. So no step can be skipped: there is no
## code to exchange before the state is checked, and no account before the
## identity is known.
##
##     /login                Started       start: a state minted, for the host to sign
##     /login/github         CameBack      came_back: the state and GitHub's code returned
##                           StateChecked  check: OAuthState.check, and the nonce spent once
##     (host asks GitHub)    IdentityKnown identify: GitHub's id and login
##                           resolve:      SignedIn an existing account, and its Admission
##                                         NeedsName a new human, asked for a name
##                                         Refused
##     /login/name           Pending       resume: the pending sign-up, back from this browser
##                           name:         Created a new account, and its Admission
##                                         NameRefused, Refused
##
## **AN ADMISSION IS THE ONLY WAY TO A SESSION.** The flow never makes a
## session itself: it ends in an Admission, an opaque value only this
## module makes, and Session.start takes nothing else. So no handler mints
## a session by calling a constructor; it must walk every state here, each
## from the host's fact. (A handler that lies about the facts is beyond any
## type: the facts are the host's to tell truly.)
##
## **A PENDING SIGN-UP IS SPENT ONCE**, and names only an id with no
## account: the host spends its nonce (Pending.nonce) in a set of its own,
## apart from the states' (the state's spend of the same nonce was the
## callback's), and the name step refuses an id that has an account now, so
## a pending sign-up replayed in its window (from the same browser, after a
## log-out) never signs anyone in.
##
## **A LOGIN IS ONE ACCOUNT'S AT A TIME**: GitHub frees a renamed login for
## anyone to take, so when an account signs in or signs up with a login
## another account still holds (GitHub's logins ignore case), that other
## account's login is cleared (a ClearLogin step), so its GitHub link
## never leads to the new owner.
##
## **A BAR IS FOR LIFE (Steve, 2026-10-29)**: a retired human's GitHub id
## is barred for good. A barred id is refused at `resolve` and again at
## `name`, whatever the accounts hold, and no step here touches the barred
## list (Admin has no Unbar either).
##
## **Sign-up is open (Steve):** any GitHub account may make an account,
## giving a display name (DisplayName's rule). An account is its GitHub id;
## its login is only what GitHub last called it, so a renamed login signs
## in to the same account, and a login another id gave up is a new account.
## **The first admin** is the GitHub id the settings name, made admin when
## its account is made and only while there is no admin yet. Pure.
import Ascii
import Cast
import DisplayName
import GitHubLogin
import OAuthState
import Principal
import Stored

GitHubSignIn := [].{

	## **WHY A SIGN-IN IS REFUSED**, one name each.
	Refusal : [
		## The state did not come back signed by us (missing, or forged).
		StateForged,

		## The state is not this browser's (its cookie is missing or holds
		## another nonce): a login CSRF.
		StateMismatched,

		## The state is older than OAuthState's lifetime, or from the future.
		StateExpired,

		## The state's nonce was spent before: a replay.
		StateReused,

		## GitHub sent the browser back with no code: the person said no.
		GitHubDenied,

		## The code is not one GitHub would send.
		NotACode,

		## The host could not exchange the code, or ask GitHub who it is.
		GitHubUnreachable,

		## GitHub's answer is not an identity: an id of 0, or no login.
		BadIdentity,

		## The GitHub id's account was retired: it does not sign up again.
		Barred,

		## The pending sign-up did not come back signed by us.
		PendingForged,

		## The pending sign-up is not this browser's.
		PendingMismatched,

		## The pending sign-up is older than OAuthState's lifetime.
		PendingExpired,

		## The pending sign-up was named before: a replay.
		PendingReused,

		## The pending sign-up's id has an account now: it signs in through
		## /login, never by naming again.
		AccountExists,

		## More than one account holds the GitHub id: no copy is signed in
		## to, and none is made beside them.
		DuplicateAccount,

		## The settings' next generation is not above every account's: the
		## counter went back, and a generation might be given twice.
		StaleGeneration,

		## The generation counter is spent.
		GenerationsExhausted,

		## The clock is outside Stored's range (before 1970 or past 9999):
		## no session or account it would stamp could be stored.
		ClockOutOfRange,
	]

	## **THE SETTINGS THE FLOW IS GIVEN**: the GitHub id of the first admin,
	## if any is named; the GitHub ids barred from signing up again (their
	## accounts retired); and the generation counter, the generation the next
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

	## **A NEW SESSION'S FACTS**, the host's: its public number, and the
	## hash of the cookie's random secret.
	NewSession : {
		id : Principal.SessionId,
		token_hash : Stored.SecretHash,
	}

	## **ONE STEP OF A SIGN-IN'S PLAN**, for the host to apply in order
	## (`applied` says what each does). Steps, never whole records of an
	## existing account: a record copied at sign-in and stored later would
	## undo whatever changed meanwhile (a demotion). Each step is
	## idempotent, so a plan applied twice after a crash leaves what once
	## does.
	Step : [
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

	## Signed in: the admission Session.start takes, and the steps to store
	## (the login brought up to date; other accounts' logins cleared).
	SignedIn : {
		admission : GitHubSignIn.Admission,
		steps : List(GitHubSignIn.Step),
	}

	## **WHAT A SIGN-IN'S STEPS LEAVE**: `accounts` and `settings` with each
	## step made, in order; the one home of what a step means.
	applied : List(GitHubSignIn.Step), { accounts : List(Principal), settings : GitHubSignIn.Settings } -> { accounts : List(Principal), settings : GitHubSignIn.Settings }
	applied = |steps, start|
		List.fold(
			steps,
			start,
			|{ accounts, settings }, step|
				match step {
					AddAccount(account) =>
						if List.any(accounts, |a| Principal.id(a) == Principal.id(account)) {
							{ accounts, settings }
						} else {
							{ accounts: List.append(accounts, account), settings }
						}
					SetLogin({ human, login }) =>
						{ accounts: with_human(accounts, human, |h| { ..h, login }), settings }
					ClearLogin({ human, login }) =>
						{ accounts: with_human(accounts, human, |h| if lowered(h.login) == lowered(login) { ..h, login: "" } else h), settings }
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
	next_agent_id : List(Principal), GitHubSignIn.Settings -> Try({ this : Principal.AgentId, next : Principal.AgentId }, [StaleAgentId, AgentIdsExhausted])
	next_agent_id = |accounts, settings| {
		this = settings.next_agent_id
		if List.any(accounts, |a| agent_id_of(a) >= this.to_u64()) {
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
		most = List.fold(accounts, 0, |m, a| if agent_id_of(a) > m agent_id_of(a) else m)
		if most == u64_most Err(AgentIdsExhausted) else Principal.AgentId.from_u64(most + 1).map_err(|_| AgentIdsExhausted)
	}

	## **A NEW ACCOUNT'S GENERATION, AND THE COUNTER AFTER IT**: the one
	## rule a sign-up and an agent's making both ask (`fresh_generation`).
	next_generation : List(Principal), GitHubSignIn.Settings -> Try({ this : Principal.Generation, next : Principal.Generation }, [StaleGeneration, GenerationsExhausted])
	next_generation = |accounts, settings| fresh_generation(accounts, settings)

	## **ADMITTED**: the flow's end, the one value Session.start takes. Only
	## this module makes one, at `resolve` or `name`, once every step before
	## held: the human, the account's generation the session is bound to,
	## the host's facts of the new session, and the time.
	Admission :: {
		human : Principal.GitHubId,
		generation : Principal.Generation,
		session : GitHubSignIn.NewSession,
		now : I64,
	}.{

		## What the admission holds, for Session.start.
		facts : GitHubSignIn.Admission -> {
			human : Principal.GitHubId,
			generation : Principal.Generation,
			session : GitHubSignIn.NewSession,
			now : I64,
		}
		facts = |GitHubSignIn.Admission.(a)| a
	}

	## **STARTED**: a state minted for this browser.
	Started :: OAuthState.Fields.{

		## A state of the host's random `nonce`, at least 16 bytes.
		start : { nonce : List(U8), now : I64 } -> Try(GitHubSignIn.Started, [WeakNonce])
		start = |{ nonce, now }|
			if List.len(nonce) < min_nonce_bytes {
				Err(WeakNonce)
			} else {
				Ok(GitHubSignIn.Started.(OAuthState.issue({ nonce, now })))
			}

		## The state's fields, for the host to sign into GitHub's `state`,
		## its nonce set in this browser's state cookie too.
		state : GitHubSignIn.Started -> OAuthState.Fields
		state = |GitHubSignIn.Started.(fields)| fields
	}

	## **CAME BACK**: GitHub sent the browser back, with the state and a
	## code.
	CameBack :: { state : OAuthState.Fields, code : List(U8) }.{

		## From the facts of the return: the state, if its signature held;
		## and GitHub's answer, a code or not. A state not signed by us is
		## said first, whatever GitHub answered.
		came_back : {
			state : [Signed(OAuthState.Fields), Unsigned],
			answer : [Code(List(U8)), Denied],
		} -> Try(GitHubSignIn.CameBack, GitHubSignIn.Refusal)
		came_back = |{ state, answer }|
			match (state, answer) {
				(Unsigned, _) => Err(StateForged)
				(Signed(_), Denied) => Err(GitHubDenied)
				(Signed(fields), Code(code)) =>
					if is_code(code) Ok(
						GitHubSignIn.CameBack.(
							{
								state: fields,
								code,
							},
						),
					) else Err(NotACode)
			}

		## The nonce the host spends, answering whether it was spent before.
		nonce : GitHubSignIn.CameBack -> List(U8)
		nonce = |GitHubSignIn.CameBack.(c)| c.state.nonce

		## **IS THE STATE THIS BROWSER'S, NOW, AND NEW?** OAuthState.check
		## (another browser's is said before the time), then the nonce's
		## first use.
		check : GitHubSignIn.CameBack,
		{
			cookie : OAuthState.Cookie,
			now : I64,
			nonce_use : [FirstUse, UsedBefore],
		} -> Try(GitHubSignIn.StateChecked, GitHubSignIn.Refusal)
		check = |
			GitHubSignIn.CameBack.(c),
			{
				cookie,
				now,
				nonce_use,
			},
		|
			match OAuthState.check(c.state, { cookie, now }) {
				Mismatched => Err(StateMismatched)
				Expired => Err(StateExpired)
				Valid =>
					match nonce_use {
						UsedBefore => Err(StateReused)
						FirstUse => Ok(
							GitHubSignIn.StateChecked.(
								{
									nonce: c.state.nonce,
									code: c.code,
								},
							),
						)
					}
			}
	}

	## **STATE CHECKED**: the code may be exchanged now, and only now.
	StateChecked :: { nonce : List(U8), code : List(U8) }.{

		## The code, for the host to exchange at GitHub.
		code : GitHubSignIn.StateChecked -> List(U8)
		code = |GitHubSignIn.StateChecked.(c)| c.code

		## From GitHub's answer to `/user` (by the host, with the token it
		## got for the code, then forgot): the id and the login, or a
		## failure.
		identify : GitHubSignIn.StateChecked,
		[
			Identified({ id : U64, login : List(U8) }),
			Failed,
		] -> Try(GitHubSignIn.IdentityKnown, GitHubSignIn.Refusal)
		identify = |GitHubSignIn.StateChecked.(c), answer|
			match answer {
				Failed => Err(GitHubUnreachable)
				Identified({ id, login }) =>
					match (Principal.GitHubId.from_u64(id), GitHubLogin.from_utf8(login)) {
						(Ok(github), Ok(known)) => Ok(
							GitHubSignIn.IdentityKnown.(
								{
									nonce: c.nonce,
									github,
									login: known,
								},
							),
						)
						_ => Err(BadIdentity)
					}
			}
	}

	## **IDENTITY KNOWN**: who GitHub says this is.
	IdentityKnown :: {
		nonce : List(U8),
		github : Principal.GitHubId,
		login : GitHubLogin,
	}.{

		## The GitHub id.
		github : GitHubSignIn.IdentityKnown -> Principal.GitHubId
		github = |GitHubSignIn.IdentityKnown.(k)| k.github

		## **WHOSE SIGN-IN IS THIS?** In order: a barred id is refused; an
		## id with an account signs in to it (its login brought up to date);
		## any other id is a new human, asked for a name.
		resolve : GitHubSignIn.IdentityKnown,
		{
			accounts : List(Principal),
			settings : GitHubSignIn.Settings,
			session : GitHubSignIn.NewSession,
			now : I64,
		} -> [
			SignedIn(GitHubSignIn.SignedIn),
			NeedsName(GitHubSignIn.Pending),
			Refused(GitHubSignIn.Refusal),
		]
		resolve = |
			GitHubSignIn.IdentityKnown.(k),
			{
				accounts,
				settings,
				session,
				now,
			},
		|
			if now < 0 or now > Stored.max_time {
				Refused(ClockOutOfRange)
			} else {
				match known_account({
					github: k.github,
					login: k.login,
					accounts,
					settings,
					session,
					now,
				}) {
					Barred => Refused(Barred)
					Duplicate => Refused(DuplicateAccount)
					Known(signed_in) => SignedIn(signed_in)
					Unknown =>
						NeedsName(
							GitHubSignIn.Pending.(
								{
									nonce: k.nonce,
									github: k.github,
									login: k.login,
									issued_at: now,
								},
							),
						)
				}
			}
	}

	## A pending sign-up's fields: what the host signs into a cookie, and
	## hands back as it decoded them once the signature held.
	PendingFields : {
		nonce : List(U8),
		github : U64,
		login : List(U8),
		issued_at : I64,
	}

	## **PENDING**: a new human, between GitHub and their name.
	Pending :: {
		nonce : List(U8),
		github : Principal.GitHubId,
		login : GitHubLogin,
		issued_at : I64,
	}.{

		## The nonce the host spends when the name is given, in its set of
		## spent pending sign-ups, answering whether it was spent before.
		nonce : GitHubSignIn.Pending -> List(U8)
		nonce = |GitHubSignIn.Pending.(p)| p.nonce

		## Its fields, for the host to sign.
		fields : GitHubSignIn.Pending -> GitHubSignIn.PendingFields
		fields = |GitHubSignIn.Pending.(p)| {
			nonce: p.nonce,
			github: p.github.to_u64(),
			login: Str.to_utf8(p.login.to_str()),
			issued_at: p.issued_at,
		}

		## **BACK FROM THIS BROWSER, IN TIME?** The pending sign-up is held
		## to the state cookie's nonce and to OAuthState's lifetime, as the
		## state was: a pending sign-up another browser was handed (a login
		## CSRF into a stranger's new account) is refused.
		resume : {
			pending : [Signed(GitHubSignIn.PendingFields), Unsigned],
			cookie : OAuthState.Cookie,
			now : I64,
		} -> Try(GitHubSignIn.Pending, GitHubSignIn.Refusal)
		resume = |
			{
				pending,
				cookie,
				now,
			},
		|
			match pending {
				Unsigned => Err(PendingForged)
				Signed(p) =>
					match OAuthState.check(
						{ nonce: p.nonce, issued_at: p.issued_at },
						{ cookie, now },
					) {
						Mismatched => Err(PendingMismatched)
						Expired => Err(PendingExpired)
						Valid =>
							match (
								Principal.GitHubId.from_u64(p.github),
								GitHubLogin.from_utf8(p.login),
							) {
								(Ok(github), Ok(login)) =>
									Ok(
										GitHubSignIn.Pending.(
											{
												nonce: p.nonce,
												github,
												login,
												issued_at: p.issued_at,
											},
										),
									)

								_ => Err(BadIdentity)
							}
					}
			}

		## **THE NAME GIVEN**: in order, a barred id is refused; a pending
		## sign-up named before (its nonce spent) is refused; an id with an
		## account now (made meanwhile, in a second tab, or by this very
		## pending sign-up before) is refused, and signs in through /login;
		## a name the rule refuses is said, to ask again; a generation
		## counter that went back or is spent is refused; otherwise the
		## account is made, of the settings' next generation, admin only as
		## the first admin: its steps advance the counter first, then add the
		## account, then clear other accounts' hold on its login.
		name : GitHubSignIn.Pending,
		{
			name : List(U8),
			pending_use : [FirstUse, UsedBefore],
			accounts : List(Principal),
			settings : GitHubSignIn.Settings,
			session : GitHubSignIn.NewSession,
			now : I64,
		} -> [
			Created(
				{
					admission : GitHubSignIn.Admission,
					steps : List(GitHubSignIn.Step),
				},
			),
			NameRefused(DisplayName.Problem),
			Refused(GitHubSignIn.Refusal),
		]
		name = |
			GitHubSignIn.Pending.(p),
			{
				name,
				pending_use,
				accounts,
				settings,
				session,
				now,
			},
		|
			if now < 0 or now > Stored.max_time {
				Refused(ClockOutOfRange)
			} else if List.contains(settings.barred, p.github) {
				Refused(Barred)
			} else {
				match (pending_use, Principal.find(accounts, Principal.Id.Human(p.github))) {
					(UsedBefore, _) => Refused(PendingReused)
					(FirstUse, Ok(_)) => Refused(AccountExists)
					(FirstUse, Err(Duplicated)) => Refused(DuplicateAccount)
					(FirstUse, Err(NoSuchPrincipal)) =>
						match (DisplayName.from_utf8(name), fresh_generation(accounts, settings)) {
							(Err(problem), _) => NameRefused(problem)
							(Ok(_), Err(why)) => Refused(why)
							(Ok(chosen), Ok({ this, next })) =>
								Created({
									steps: [
										AdvanceGeneration(next),
										AddAccount(
											Principal.Human({
												id: p.github,
												login: p.login.to_str(),
												name: chosen.to_str(),
												role: first_role({
													github: p.github,
													accounts,
													settings,
												}),
												generation: this,
											}),
										),
									]
										.concat(displaced(accounts, { github: p.github, login: p.login })),
									admission: GitHubSignIn.Admission.(
										{
											human: p.github,
											generation: this,
											session,
											now,
										},
									),
								})
						}
				}
			}
	}
}

## The fewest bytes of randomness a state's nonce may have.
min_nonce_bytes : U64
min_nonce_bytes = 16

## The most bytes a GitHub code may have.
max_code_bytes : U64
max_code_bytes = 64

## A code as GitHub sends one: 1 to 64 bytes of letters, digits, `-`, `_`.
is_code : List(U8) -> Bool
is_code = |code|
	code != [] and List.len(code) <= max_code_bytes and List.all(
		code,
		|c| Ascii.is_alphanumeric(c) or c == '-' or c == '_',
	)

## The id's standing: barred, held by more than one account, an account it
## signs in to, or none yet.
known_account : {
	github : Principal.GitHubId,
	login : GitHubLogin,
	accounts : List(Principal),
	settings : GitHubSignIn.Settings,
	session : GitHubSignIn.NewSession,
	now : I64,
} -> [
	Barred,
	Duplicate,
	Known(GitHubSignIn.SignedIn),
	Unknown,
]
known_account = |
	{
		github,
		login,
		accounts,
		settings,
		session,
		now,
	},
|
	if List.contains(settings.barred, github) {
		Barred
	} else {
		match Principal.human_account(accounts, github) {
			Err(NoSuchPrincipal) => Unknown
			Err(Duplicated) => Duplicate
			Ok(h) => {
				fresh = login.to_str()
				Known({
					steps: (if h.login == fresh [] else [SetLogin({ human: github, login: fresh })]).concat(displaced(accounts, { github, login })),
					admission: GitHubSignIn.Admission.(
						{
							human: github,
							generation: h.generation,
							session,
							now,
						},
					),
				})
			}
		}
	}

## **THE OTHER ACCOUNTS HOLDING `login`**, a ClearLogin each: every human
## but `github` whose stored login is `login` in any case.
displaced : List(Principal), { github : Principal.GitHubId, login : GitHubLogin } -> List(GitHubSignIn.Step)
displaced = |accounts, { github, login }| {
	wanted = lowered(login.to_str())
	List.join_map(
		accounts,
		|p|
			match p {
				Human(h) =>
					if h.id != github and h.login != "" and lowered(h.login) == wanted {
						[ClearLogin({ human: h.id, login: h.login })]
					} else {
						[]
					}
				Agent(_) | Bot(_) => []
			},
	)
}

## A login's bytes in lower case: GitHub's logins ignore case.
lowered : Str -> List(U8)
lowered = |login| List.map(Str.to_utf8(login), Ascii.to_lowercase)

## `accounts` with the human `human`'s record changed by `change`.
with_human : List(Principal), Principal.GitHubId, ({ id : Principal.GitHubId, login : Str, name : Str, role : Principal.Role, generation : Principal.Generation } -> { id : Principal.GitHubId, login : Str, name : Str, role : Principal.Role, generation : Principal.Generation }) -> List(Principal)
with_human = |accounts, human, change|
	List.map(
		accounts,
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

## **A NEW ACCOUNT'S GENERATION**: the settings' next, when it is above
## every account's (a counter that went back might give one twice); and
## the counter after it, for the host to store.
fresh_generation : List(Principal),
GitHubSignIn.Settings -> Try(
	{ this : Principal.Generation, next : Principal.Generation },
	[StaleGeneration, GenerationsExhausted],
)
fresh_generation = |accounts, settings| {
	this = settings.next_generation
	if List.any(accounts, |a| Principal.generation(a).to_u64() >= this.to_u64()) {
		Err(StaleGeneration)
	} else {
		match this.next() {
			Ok(next) => Ok({ this, next })
			Err(Exhausted) => Err(GenerationsExhausted)
		}
	}
}

## The role a new human's account is made with: admin for the first admin
## the settings name, while no human is an admin yet; member otherwise.
first_role : {
	github : Principal.GitHubId,
	accounts : List(Principal),
	settings : GitHubSignIn.Settings,
} -> Principal.Role
first_role = |
	{
		github,
		accounts,
		settings,
	},
| {
	has_admin = List.any(
		accounts,
		|a|
			match a {
				Human(h) => h.role == Admin
				Agent(_) | Bot(_) => Bool.False
			},
	)
	match settings.first_admin {
		Named(first) if first == github and !has_admin => Admin
		_ => Member
	}
}

# ── tests

## A test's human: GitHub id `n`, its login, name and role, made at 500.
human : U64,
{
	login : Str,
	name : Str,
	role : Principal.Role,
} -> Principal
human = |
	n,
	{
		login,
		name,
		role,
	},
| Principal.Human({
	id: Cast.gid(n),
	login,
	name,
	role,
	generation: Cast.gen(5),
})

# The cast: Boss (GitHub id 1), the admin; Ann (2), a member; Ann's agent,
# whose owner id is Ann's.
boss : Principal
boss = human(
	1,
	{
		login: "boss",
		name: "Boss",
		role: Admin,
	},
)

ann : Principal
ann = human(
	2,
	{
		login: "ann",
		name: "Ann",
		role: Member,
	},
)

ann_agent : Principal
ann_agent = Principal.Agent({
	id: Cast.aid(1),
	owner: Cast.gid(2),
	name: "Ann's agent",
	generation: Cast.gen(6),
})

## This browser's nonce, 16 bytes; another browser's.
this_nonce : List(U8)
this_nonce = Str.to_utf8("q7Zr2Lx9q7Zr2Lx9")

that_nonce : List(U8)
that_nonce = Str.to_utf8("Wm4kPq8sWm4kPq8s")

new_session : GitHubSignIn.NewSession
new_session = { id: Cast.sid(5), token_hash: Cast.token(0x42) }

## Open sign-up, Boss the first admin, GitHub id 66 barred.
usual_settings : GitHubSignIn.Settings
usual_settings = { first_admin: Named(Cast.gid(1)), barred: [Cast.gid(66)], next_generation: Cast.gen(10), next_agent_id: Cast.aid(20) }

# ── STARTED
expect GitHubSignIn.Started.start({
	nonce: List.repeat('n', 15),
	now: 1000,
}).map_ok(GitHubSignIn.Started.state) == Err(WeakNonce)
expect GitHubSignIn.Started.start({
	nonce: [],
	now: 1000,
}).map_ok(GitHubSignIn.Started.state) == Err(WeakNonce)
expect
	GitHubSignIn.Started.start({ nonce: this_nonce, now: 1000 }).map_ok(GitHubSignIn.Started.state)
		== Ok({ nonce: this_nonce, issued_at: 1000 })

## **ONE SIGN-IN, FROM /login TO WHOSE IT IS**: every fact a host would
## supply, so each hostile case below is the usual run with one fact
## changed.
Facts : {
	## When /login minted the state (this browser's nonce).
	minted_at : I64,

	## The state as it came back: ours, signed; not signed by us; or another
	## state we signed (another browser's).
	state_back : [
		Ours,
		Forged,
		Swapped(OAuthState.Fields),
	],
	answer : [Code(List(U8)), Denied],
	cookie : OAuthState.Cookie,
	back_at : I64,
	nonce_use : [FirstUse, UsedBefore],
	github : [Identified({ id : U64, login : List(U8) }), Failed],
	accounts : List(Principal),
	settings : GitHubSignIn.Settings,
}

## Ann's GitHub (id 2, `ann`), signing in a minute after /login, with no
## account yet.
usual : Facts
usual = {
	minted_at: 1000,
	state_back: Ours,
	answer: Code(Str.to_utf8("e72e16c7e42f292c6912")),
	cookie: Sent(this_nonce),
	back_at: 1060,
	nonce_use: FirstUse,
	github: Identified({ id: 2, login: Str.to_utf8("ann") }),
	accounts: [boss, ann_agent],
	settings: usual_settings,
}

Resolved : [
	SignedIn(GitHubSignIn.SignedIn),
	NeedsName(GitHubSignIn.Pending),
	Refused(GitHubSignIn.Refusal),
]

## The facts, through every transition up to `resolve`.
resolved_by : Facts -> Try(Resolved, GitHubSignIn.Refusal)
resolved_by = |f| {
	minted =
		match GitHubSignIn.Started.start({ nonce: this_nonce, now: f.minted_at }) {
			Ok(s) => s
			Err(WeakNonce) => crash "resolved_by: a test's nonce is 16 bytes"
		}
	back =
		match f.state_back {
			Ours => Signed(minted.state())
			Forged => Unsigned
			Swapped(fields) => Signed(fields)
		}
	came = GitHubSignIn.CameBack.came_back({ state: back, answer: f.answer })?
	checked = came.check({
		cookie: f.cookie,
		now: f.back_at,
		nonce_use: f.nonce_use,
	})?
	known = checked.identify(f.github)?
	Ok(
		known.resolve({
			accounts: f.accounts,
			settings: f.settings,
			session: new_session,
			now: f.back_at,
		}),
	)
}

## A human account, every field, for a test to compare (Principal has no
## `==`).
Seen : {
	id : Principal.GitHubId,
	login : Str,
	name : Str,
	role : Principal.Role,
	generation : Principal.Generation,
}

## What an admission holds, comparably.
Facts_ : {
	human : Principal.GitHubId,
	generation : Principal.Generation,
	session : GitHubSignIn.NewSession,
	now : I64,
}

seen : Principal -> Seen
seen = |account|
	match account {
		Human(h) => h
		Agent(_) | Bot(_) => crash "seen: the flow makes and signs in humans alone"
	}

## A step, comparably: an added account every field of it.
SeenStep : [
	AddAccount(Seen),
	SetLogin({ human : Principal.GitHubId, login : Str }),
	ClearLogin({ human : Principal.GitHubId, login : Str }),
	AdvanceGeneration(Principal.Generation),
	AdvanceAgentId(Principal.AgentId),
]

seen_step : GitHubSignIn.Step -> SeenStep
seen_step = |step|
	match step {
		AddAccount(p) => AddAccount(seen(p))
		SetLogin(s) => SetLogin(s)
		ClearLogin(c) => ClearLogin(c)
		AdvanceGeneration(g) => AdvanceGeneration(g)
		AdvanceAgentId(id) => AdvanceAgentId(id)
	}

## What resolving says, comparably.
Said : [
	SignedIn({ admission : Facts_, steps : List(SeenStep) }),
	NeedsName({ github : U64, login : Str }),
	Refused(GitHubSignIn.Refusal),
]

said : Facts -> Said
said = |f|
	match resolved_by(f) {
		Err(why) => Refused(why)
		Ok(Refused(why)) => Refused(why)
		Ok(SignedIn(s)) => SignedIn({ admission: s.admission.facts(), steps: List.map(s.steps, seen_step) })
		Ok(NeedsName(p)) => {
			fields = p.fields()
			match Str.from_utf8(fields.login) {
				Ok(login) => NeedsName({ github: fields.github, login })
				Err(_) => crash "said: a pending login passed GitHubLogin's rule, so it is UTF-8"
			}
		}
	}

## The admission a sign-in at 1060 makes for GitHub id `n`, whose account
## was made at 500.
session_for : U64 -> Facts_
session_for = |n| {
	human: Cast.gid(n),
	generation: Cast.gen(5),
	session: new_session,
	now: 1060,
}

# ── RESOLVING: the usual runs.
# Ann, no account yet: a new human, asked for a name.
expect said(usual) == NeedsName({ github: 2, login: "ann" })

# Ann with an account: signed in to it, a session made.
expect
	said({ ..usual, accounts: [boss, ann] })
		== SignedIn({ admission: session_for(2), steps: [] })

# **A GITHUB ID THAT CHANGED ITS LOGIN IS THE SAME ACCOUNT**: Ann renamed
# to `ann-b` signs in to Ann's account, a SetLogin step bringing its
# login up to date; nothing else of hers is touched.
expect
	said({
		..usual,
		accounts: [boss, ann],
		github: Identified({ id: 2, login: Str.to_utf8("ann-b") }),
	})
		== SignedIn({ admission: session_for(2), steps: [SetLogin({ human: Cast.gid(2), login: "ann-b" })] })

# **A LOGIN REUSED BY ANOTHER ID IS ANOTHER ACCOUNT**: GitHub id 3 now
# calling itself `ann` is never Ann; it is a new human.
expect
	said({
		..usual,
		accounts: [boss, ann],
		github: Identified({ id: 3, login: Str.to_utf8("ann") }),
	})
		== NeedsName({ github: 3, login: "ann" })

# An agent's owner id with no human account: agents never sign in, so it is
# a new human.
expect said({ ..usual, accounts: [ann_agent] }) == NeedsName({ github: 2, login: "ann" })

# The first admin's existing account is not promoted by signing in.
expect
	said({
		..usual,
		accounts: [ann],
		settings: { ..usual_settings, first_admin: Named(Cast.gid(2)) },
	})
		== SignedIn({ admission: session_for(2), steps: [] })

# ── RESOLVING: the hostile runs.
# A state not signed by us: refused, whatever GitHub said.
expect said({ ..usual, state_back: Forged }) == Refused(StateForged)
expect said({
	..usual,
	state_back: Forged,
	answer: Denied,
}) == Refused(StateForged)

# **A STATE FROM ANOTHER BROWSER** (a login CSRF): another browser's state,
# signed by us, back with this browser's cookie; or this browser's state,
# back with another's cookie, or none.
expect said({
	..usual,
	state_back: Swapped({ nonce: that_nonce, issued_at: 1000 }),
}) == Refused(StateMismatched)
expect said({ ..usual, cookie: Sent(that_nonce) }) == Refused(StateMismatched)
expect said({ ..usual, cookie: Unsent }) == Refused(StateMismatched)

# **A REUSED STATE**: the nonce spent before, though all else is good.
expect said({ ..usual, nonce_use: UsedBefore }) == Refused(StateReused)
expect said({
	..usual,
	nonce_use: UsedBefore,
	accounts: [ann],
}) == Refused(StateReused)

# Another browser's reused state: the mismatch is said first.
expect said({
	..usual,
	nonce_use: UsedBefore,
	cookie: Sent(that_nonce),
}) == Refused(StateMismatched)

# The state's window: ten minutes from its minting, never before it.
expect said({ ..usual, back_at: 1599 }) == NeedsName({ github: 2, login: "ann" })
expect said({ ..usual, back_at: 1600 }) == Refused(StateExpired)
expect said({ ..usual, back_at: 999 }) == Refused(StateExpired)

# GitHub's answer: no code, or not a code.
expect said({ ..usual, answer: Denied }) == Refused(GitHubDenied)
expect
	List.all(
		[
			"",
			Str.repeat("c", 65),
			"e72e 16c7",
			"e72e/16c7",
			"e72e16c7\n",
			"code=x",
		],
		|bad| said({ ..usual, answer: Code(Str.to_utf8(bad)) }) == Refused(NotACode),
	)
expect said({
	..usual,
	answer: Code(Str.to_utf8(Str.repeat("c", 64))),
}) == NeedsName({ github: 2, login: "ann" })
expect said({
	..usual,
	answer: Code(Str.to_utf8("a-b_C9")),
}) == NeedsName({ github: 2, login: "ann" })

# GitHub unreachable, or an answer that is no identity.
expect said({ ..usual, github: Failed }) == Refused(GitHubUnreachable)
expect said({
	..usual,
	github: Identified({ id: 0, login: Str.to_utf8("ann") }),
}) == Refused(BadIdentity)
expect said({ ..usual, github: Identified({ id: 2, login: [] }) }) == Refused(BadIdentity)
expect said({
	..usual,
	github: Identified({ id: 2, login: Str.to_utf8("ann ann") }),
}) == Refused(BadIdentity)
expect said({ ..usual, github: Identified({ id: 2, login: [0x61, 0xff] }) }) == Refused(BadIdentity)

# A barred id: refused, even with an account still listed.
expect said({
	..usual,
	github: Identified({ id: 66, login: Str.to_utf8("gone") }),
}) == Refused(Barred)
expect
	said({
		..usual,
		accounts: [
			human(
				66,
				{
					login: "gone",
					name: "Gone",
					role: Member,
				},
			),
		],
		github: Identified({ id: 66, login: Str.to_utf8("gone") }),
	})
		== Refused(Barred)

# ATTACK (round three's second, its class): a sign-in whole under a clock
# before 1970 admits no session, whose times the store could not write.
expect
	match resolved_by({ ..usual, accounts: [boss, ann], minted_at: -100, back_at: -50 }) {
		Ok(SignedIn(s)) => s.admission.facts().now >= 0
		_ => Bool.True
	}

expect said({ ..usual, accounts: [boss, ann], minted_at: -100, back_at: -50 }) == Refused(ClockOutOfRange)
expect said({ ..usual, minted_at: Stored.max_time - 10, back_at: Stored.max_time + 1 }) == Refused(ClockOutOfRange)

# ── THE NAME STEP
## The pending sign-up the usual run leaves, its facts as the host would
## hand them back.
pending_of : Facts -> GitHubSignIn.PendingFields
pending_of = |f|
	match resolved_by(f) {
		Ok(NeedsName(p)) => p.fields()
		_ => crash "pending_of: the run asks for a name"
	}

usual_pending : GitHubSignIn.PendingFields
usual_pending = pending_of(usual)

expect usual_pending == {
	nonce: this_nonce,
	github: 2,
	login: Str.to_utf8("ann"),
	issued_at: 1060,
}

## The facts of the name's POST.
Naming : {
	pending : [Signed(GitHubSignIn.PendingFields), Unsigned],
	cookie : OAuthState.Cookie,
	at : I64,
	name : List(U8),
	pending_use : [FirstUse, UsedBefore],
	accounts : List(Principal),
	settings : GitHubSignIn.Settings,
}

## Ann names herself "Ann B." a minute later.
usual_naming : Naming
usual_naming = {
	pending: Signed(usual_pending),
	cookie: Sent(this_nonce),
	at: 1120,
	name: Str.to_utf8("Ann B."),
	pending_use: FirstUse,
	accounts: [boss, ann_agent],
	settings: usual_settings,
}

## What naming says, comparably.
NameSaid : [
	Created({ admission : Facts_, steps : List(SeenStep) }),
	NameRefused(DisplayName.Problem),
	Refused(GitHubSignIn.Refusal),
]

name_said : Naming -> NameSaid
name_said = |n|
	match GitHubSignIn.Pending.resume({
		pending: n.pending,
		cookie: n.cookie,
		now: n.at,
	}) {
		Err(why) => Refused(why)
		Ok(p) =>
			match p.name({
				name: n.name,
				pending_use: n.pending_use,
				accounts: n.accounts,
				settings: n.settings,
				session: new_session,
				now: n.at,
			}) {
				Created(c) => Created({ admission: c.admission.facts(), steps: List.map(c.steps, seen_step) })
				NameRefused(problem) => NameRefused(problem)
				Refused(why) => Refused(why)
			}
	}

## The admission a naming at `at` makes for Ann's new account, made then.
named_at : I64 -> Facts_
named_at = |at| {
	human: Cast.gid(2),
	generation: Cast.gen(10),
	session: new_session,
	now: at,
}

## Ann's new account, named `name`, with `role`, made at 1120.
ann_as : Str, Principal.Role -> Seen
ann_as = |name, role| {
	id: Cast.gid(2),
	login: "ann",
	name,
	role,
	generation: Cast.gen(10),
}

## Made at 1120 as `account`, the counter advanced, no login cleared.
made : Seen -> NameSaid
made = |account| Created({ admission: named_at(1120), steps: [AdvanceGeneration(Cast.gen(11)), AddAccount(account)] })

# Made: a member, named as given, trimmed, created now; its admission.
expect name_said(usual_naming) == made(ann_as("Ann B.", Member))
expect name_said({ ..usual_naming, name: Str.to_utf8("  Ann B.  ") }) == made(ann_as("Ann B.", Member))
expect name_said({ ..usual_naming, name: Str.to_utf8("🦊") }) == made(ann_as("🦊", Member))

# **THE NAME RULE**: empty, spaces alone, over 64 bytes, a control
# character, a bidi control, a format character, not UTF-8: each said, so
# the form asks again.
expect name_said({ ..usual_naming, name: [] }) == NameRefused(Empty)
expect name_said({ ..usual_naming, name: Str.to_utf8("   ") }) == NameRefused(Empty)
expect name_said({ ..usual_naming, name: Str.to_utf8(Str.repeat("n", 65)) }) == NameRefused(TooLong)
expect name_said({ ..usual_naming, name: Str.to_utf8(Str.repeat("n", 64)) }) == made(ann_as(Str.repeat("n", 64), Member))
expect name_said({
	..usual_naming,
	name: Str.to_utf8("Ann\nrole=admin"),
}) == NameRefused(ControlCharacter)
expect name_said({ ..usual_naming, name: Str.to_utf8("\u(202E)nnA") }) == NameRefused(BidiControl)
expect name_said({ ..usual_naming, name: Str.to_utf8("\u(200B)") }) == NameRefused(FormatCharacter)
expect name_said({ ..usual_naming, name: [0x41, 0xff] }) == NameRefused(NotUtf8)

# **THE FIRST ADMIN**: the named id, while no human is an admin.
first_ann : GitHubSignIn.Settings
first_ann = { ..usual_settings, first_admin: Named(Cast.gid(2)) }

expect name_said({ ..usual_naming, settings: first_ann, accounts: [ann_agent] }) == made(ann_as("Ann B.", Admin))
expect name_said({ ..usual_naming, settings: first_ann, accounts: [boss] }) == made(ann_as("Ann B.", Member))
expect name_said({ ..usual_naming, accounts: [] }) == made(ann_as("Ann B.", Member))
expect
	name_said({
		..usual_naming,
		settings: { ..usual_settings, first_admin: Unnamed },
		accounts: [],
	})
		== made(ann_as("Ann B.", Member))

# **AN ACCOUNT MADE MEANWHILE IS NEVER SIGNED IN BY NAMING** (the round-two
# attacker's tenth): a second tab's account, or this pending sign-up's own,
# replayed in its window from the same browser after a log-out: refused,
# with no admission; the person signs in through /login.
expect name_said({ ..usual_naming, accounts: [boss, ann] }) == Refused(AccountExists)
expect
	name_said({
		..usual_naming,
		accounts: [boss, ann],
		at: 1500,
		name: Str.to_utf8("whatever"),
	})
		== Refused(AccountExists)

# **A PENDING SIGN-UP IS SPENT ONCE**: its nonce spent before, it makes
# nothing, though no account was made (the first naming refused, say).
expect name_said({ ..usual_naming, pending_use: UsedBefore }) == Refused(PendingReused)
expect name_said({ ..usual_naming, pending_use: UsedBefore, accounts: [boss, ann] }) == Refused(PendingReused)
expect
	match GitHubSignIn.Pending.resume({ pending: Signed(usual_pending), cookie: Sent(this_nonce), now: 1120 }) {
		Ok(p) => p.nonce() == this_nonce
		Err(_) => Bool.False
	}

# Two accounts holding Ann's id (a forged copy): nothing made beside them,
# and neither signed in to at /login.
expect name_said({ ..usual_naming, accounts: [ann, ann] }) == Refused(DuplicateAccount)
expect said({ ..usual, accounts: [human(2, { login: "ann", name: "Ann", role: Admin }), ann] }) == Refused(DuplicateAccount)

# **THE GENERATION COUNTER** (round three's fifth): the new account takes
# the settings' next generation, and `next` is the one after it; a counter
# not above every account's (it went back), or a spent one, makes nothing.
expect name_said({ ..usual_naming, settings: { ..usual_settings, next_generation: Cast.gen(6) } }) == Refused(StaleGeneration)
expect name_said({ ..usual_naming, settings: { ..usual_settings, next_generation: Cast.gen(5) } }) == Refused(StaleGeneration)
expect name_said({ ..usual_naming, settings: { ..usual_settings, next_generation: Cast.gen(7) } }) == Created({ admission: { ..named_at(1120), generation: Cast.gen(7) }, steps: [AdvanceGeneration(Cast.gen(8)), AddAccount({ ..ann_as("Ann B.", Member), generation: Cast.gen(7) })] })
expect name_said({ ..usual_naming, settings: { ..usual_settings, next_generation: Cast.gen(18446744073709551615) } }) == Refused(GenerationsExhausted)

# Under a clock before 1970, no account is made.
expect name_said({ ..usual_naming, pending: Signed({ ..usual_pending, issued_at: -100 }), at: -50 }) == Refused(ClockOutOfRange)

# Barred meanwhile.
expect name_said({
	..usual_naming,
	settings: { ..usual_settings, barred: [Cast.gid(2)] },
}) == Refused(Barred)

# **THE PENDING SIGN-UP, HOSTILE**: not signed by us; handed to another
# browser (a login CSRF into a stranger's new account); without a cookie;
# stale; or signed but not an identity.
expect name_said({ ..usual_naming, pending: Unsigned }) == Refused(PendingForged)
expect name_said({ ..usual_naming, cookie: Sent(that_nonce) }) == Refused(PendingMismatched)
expect name_said({ ..usual_naming, cookie: Unsent }) == Refused(PendingMismatched)
expect
	name_said({ ..usual_naming, at: 1659 })
		== Created({ admission: named_at(1659), steps: [AdvanceGeneration(Cast.gen(11)), AddAccount(ann_as("Ann B.", Member))] })
expect name_said({ ..usual_naming, at: 1660 }) == Refused(PendingExpired)
expect name_said({ ..usual_naming, at: 1059 }) == Refused(PendingExpired)
expect name_said({
	..usual_naming,
	pending: Signed({ ..usual_pending, github: 0 }),
}) == Refused(BadIdentity)
expect name_said({
	..usual_naming,
	pending: Signed({ ..usual_pending, login: [] }),
}) == Refused(BadIdentity)
expect name_said({
	..usual_naming,
	pending: Signed({ ..usual_pending, issued_at: -9223372036854775808 }),
}) == Refused(PendingExpired)

# ── A LOGIN ANOTHER ACCOUNT HOLDS IS CLEARED THERE (round two's tenth)
# Bea (id 7) once went by `ann`; GitHub gave it to Ann since. Ann signing
# up, or signing in, as `ann` clears Bea's login, in any case, so Bea's
# GitHub link never leads to Ann; nobody else's is touched.
old_bea : Principal
old_bea = human(7, { login: "ANN", name: "Bea", role: Member })

expect
	name_said({ ..usual_naming, accounts: [boss, old_bea] })
		== Created({ admission: named_at(1120), steps: [AdvanceGeneration(Cast.gen(11)), AddAccount(ann_as("Ann B.", Member)), ClearLogin({ human: Cast.gid(7), login: "ANN" })] })
expect
	said({ ..usual, accounts: [boss, ann, old_bea] })
		== SignedIn({ admission: session_for(2), steps: [ClearLogin({ human: Cast.gid(7), login: "ANN" })] })
# A login already cleared is cleared nowhere again.
expect said({ ..usual, accounts: [boss, ann, human(8, { login: "", name: "C", role: Member })] }) == SignedIn({ admission: session_for(2), steps: [] })

# ── THE STEPS (round three's third)
## The accounts the steps leave from `start`, under the usual settings.
applied_to : List(GitHubSignIn.Step), List(Principal) -> List(Seen)
applied_to = |steps, start| GitHubSignIn.applied(steps, { accounts: start, settings: usual_settings }).accounts.map(seen)

## The steps resolving hands back, for a run that signs in.
steps_of : Facts -> List(GitHubSignIn.Step)
steps_of = |f|
	match resolved_by(f) {
		Ok(SignedIn(s)) => s.steps
		_ => crash "steps_of: the run signs in"
	}

# ATTACK (round three's third): boss renamed signs in; an admin demotes
# boss before the sign-in's output is stored; storing what sign-in handed
# back must not undo the demotion.
boss_renamed_steps : List(GitHubSignIn.Step)
boss_renamed_steps = steps_of({ ..usual, accounts: [boss, ann], github: Identified({ id: 1, login: Str.to_utf8("boss-b") }) })

demoted_since : List(Principal)
demoted_since = [human(1, { login: "boss", name: "Boss", role: Member }), ann]

expect applied_to(boss_renamed_steps, demoted_since) == [{ ..seen(boss), login: "boss-b", role: Member }, seen(ann)]

# A cleared login is cleared only while it is still the one cleared: Bea,
# renamed since to `bea`, keeps her new login.
clear_bea : List(GitHubSignIn.Step)
clear_bea = steps_of({ ..usual, accounts: [boss, ann, old_bea] })

expect applied_to(clear_bea, [boss, ann, old_bea]) == [seen(boss), seen(ann), { ..seen(old_bea), login: "" }]
expect applied_to(clear_bea, [boss, ann, human(7, { login: "bea", name: "Bea", role: Member })]) == [seen(boss), seen(ann), { ..seen(old_bea), login: "bea" }]

# A sign-up's steps, applied twice (a crash, and the plan again), leave
# what once does: one account, the counter once advanced.
signed_up : Naming -> List(GitHubSignIn.Step)
signed_up = |n|
	match GitHubSignIn.Pending.resume({ pending: n.pending, cookie: n.cookie, now: n.at }) {
		Ok(p) =>
			match p.name({ name: n.name, pending_use: n.pending_use, accounts: n.accounts, settings: n.settings, session: new_session, now: n.at }) {
				Created(c) => c.steps
				_ => crash "signed_up: the naming makes the account"
			}
		Err(_) => crash "signed_up: the pending sign-up resumes"
	}

once : { accounts : List(Principal), settings : GitHubSignIn.Settings }
once = GitHubSignIn.applied(signed_up(usual_naming), { accounts: [boss, ann_agent], settings: usual_settings })

twice : { accounts : List(Principal), settings : GitHubSignIn.Settings }
twice = GitHubSignIn.applied(List.concat(signed_up(usual_naming), signed_up(usual_naming)), { accounts: [boss, ann_agent], settings: usual_settings })

expect once.accounts.map(Principal.id) == [Principal.id(boss), Principal.id(ann_agent), Principal.Id.Human(Cast.gid(2))]
expect twice.accounts.map(Principal.id) == once.accounts.map(Principal.id)
expect once.settings == { ..usual_settings, next_generation: Cast.gen(11) }
expect twice.settings == once.settings
# The counter is never lowered by a step behind it.
expect GitHubSignIn.applied([AdvanceGeneration(Cast.gen(3))], { accounts: [], settings: usual_settings }).settings == usual_settings

# **A BAR IS FOR LIFE** (Steve, 2026-10-29): no sign-in step, of any kind,
# takes an id off the barred list; a barred id is refused at both doors.
every_step : List(GitHubSignIn.Step)
every_step = [
	AddAccount(human(66, { login: "gone", name: "Gone", role: Member })),
	SetLogin({ human: Cast.gid(66), login: "back" }),
	ClearLogin({ human: Cast.gid(66), login: "gone" }),
	AdvanceGeneration(Cast.gen(99)),
]

expect GitHubSignIn.applied(every_step, { accounts: [], settings: usual_settings }).settings.barred == usual_settings.barred
expect said({ ..usual, github: Identified({ id: 66, login: Str.to_utf8("gone") }), accounts: [] }) == Refused(Barred)
expect name_said({ ..usual_naming, pending: Signed({ ..usual_pending, github: 66 }) }) == Refused(Barred)

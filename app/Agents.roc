## **AGENTS AND API KEYS ON THE WIRE**: a signed-in human makes an agent
## they own, mints a key acting as themselves or as one of their agents,
## lists their keys and revokes one. Every decision is the core's: who may
## grant what is ApiKey's (`may_grant`, through ConvKey.issue), what a step
## means is GitHubSignIn's (`applied`), a name's rule is DisplayName's, and
## an agent's making is `Agents.make`, here and pure. Here are the facts
## asked of the host, the records kept (Store), and the answers made.
##
## The routes (app/main.roc's table names them):
##
##     POST /agents              make an agent: a form, `name=`
##     POST /keys                mint a key: a form, every field optional:
##                               `as=agent:7` (the human by default),
##                               `read=` and `post=` (`everywhere`, the
##                               default; `off`; `only:3,9`), `admin=on`
##                               (off by default), `lifetime=` seconds (a
##                               year, the most, by default)
##     GET  /keys                this session's keys and its agents'
##     POST /keys/<id>/revoke    revoke one of them
##
## **ONLY A SESSION**: a key never makes an agent or mints a key (the core's
## GrantedByKey, audited); nor lists or revokes one. **THE SECRET IS SHOWN
## ONCE**, in the mint's answer: 32 bytes from the host, in hex. Only its
## hash is kept (Store.save_key!), and no listing holds either.
import pf.Chat
import pf.Host
import AccountCodec
import ApiKey
import AuditCodec
import Cast
import ConvAccess
import ConvKey
import Credentials
import DisplayName
import GitHubSignIn
import KeyCodec
import Principal
import Session
import SessionCodec
import SignIn
import SignInWeb
import Store
import Stored
import Wire

Agents := [].{

	## What a path under `/agents` or `/keys` asks.
	Route : [MakeAgent, Keys, Revoke(Principal.KeyId)]

	## The route a path names, if it names one.
	route : List(U8) -> Try(Agents.Route, [NotAgents])
	route = |path|
		if path == Str.to_utf8("/agents") {
			Ok(MakeAgent)
		} else if path == Str.to_utf8("/keys") {
			Ok(Keys)
		} else {
			match List.split_on(path, '/') {
				[[], keys, digits, act] if keys == Str.to_utf8("keys") and act == Str.to_utf8("revoke") =>
					Stored.id(digits, { name: "key", make: Principal.KeyId.from_u64 }).map_ok(|id| Revoke(id)).map_err(|_| NotAgents)
				_ => Err(NotAgents)
			}
		}

	## **ANSWER A ROUTE**, each to the methods it takes.
	answer! : Chat.Request, Agents.Route => Chat.Answer
	answer! = |req, r|
		match r {
			MakeAgent => if req.method == Post make_agent!({}) else Chat.not_allowed(Post)
			Keys =>
				match req.method {
					Post => mint!({})
					Get => list!({})
					_ => Chat.not_allowed(Get)
				}
			Revoke(id) => if req.method == Post revoke!(id) else Chat.not_allowed(Post)
		}

	## Who asks to make an agent: the credential the request came with.
	Maker : ApiKey.Granter(ConvAccess.Conv, ConvAccess.ConvId)

	## **WHAT MAKING AN AGENT DECIDED**: the agent and the steps that store
	## it; the name refused (DisplayName's rule); the maker refused, as a
	## grant is (only a live session, never a key); or a counter that cannot
	## give a fresh id or generation.
	Made : [
		Made({ agent : Principal, steps : List(GitHubSignIn.Step) }),
		NameRefused(DisplayName.Problem),
		Refused([GrantedByKey, SessionExpired, NoSuchGranter, ClockOutOfRange]),
		Stuck([StaleGeneration, GenerationsExhausted, AgentIdsExhausted]),
	]

	## **MAKE AN AGENT**: owned by the human a live session signs in, named
	## by DisplayName's rule, with the chat's next agent id (one more than
	## any agent's or bot's now) and the settings' next generation
	## (GitHubSignIn.next_generation); the steps advance the counter first,
	## then add the account, for GitHubSignIn.applied, as a sign-up's do.
	make : { maker : Agents.Maker, name : List(U8), accounts : List(Principal), settings : GitHubSignIn.Settings, now : I64 } -> Agents.Made
	make = |{ maker, name, accounts, settings, now }|
		if now < 0 or now > Stored.max_time {
			Refused(ClockOutOfRange)
		} else {
			match maker {
				Key(_) => Refused(GrantedByKey)
				Session(session) =>
					match session.admit({ accounts, now }) {
						Refused(IdleExpired) | Refused(AbsoluteExpired) => Refused(SessionExpired)
						Refused(NoSuchAccount) => Refused(NoSuchGranter)
						Admitted({ principal, write: _ }) =>
							match (DisplayName.from_utf8(name), GitHubSignIn.next_generation(accounts, settings), next_agent_id(accounts)) {
								(Err(problem), _, _) => NameRefused(problem)
								(_, Err(why), _) => Stuck(why)
								(_, _, Err(why)) => Stuck(why)
								(Ok(chosen), Ok({ this, next }), Ok(id)) => {
									agent = Principal.Agent({ id, name: chosen.to_str(), owner: Principal.answers_to(principal), generation: this })
									Made({ agent, steps: [AdvanceGeneration(next), AddAccount(agent)] })
								}
							}
					}
			}
		}

	## **THE KEY IS ONE OF THIS HUMAN'S**: it acts as them, or as an agent
	## or a bot the accounts say they own now.
	is_owned_by : ConvKey.Key, { human : Principal.GitHubId, accounts : List(Principal) } -> Bool
	is_owned_by = |key, { human, accounts }|
		match Principal.find(accounts, key.acts_as()) {
			Ok(p) => Principal.answers_to(p) == human
			Err(_) => Bool.False
		}
}

## **THE CHAT'S NEXT AGENT ID**: one more than any agent's or bot's (one
## counter for both kinds); 1 for the first.
next_agent_id : List(Principal) -> Try(Principal.AgentId, [AgentIdsExhausted])
next_agent_id = |accounts| {
	most = List.fold(
		accounts,
		0,
		|m, p|
			match p {
				Agent(a) | Bot(a) => if a.id.to_u64() > m a.id.to_u64() else m
				Human(_) => m
			},
	)
	if most == u64_most Err(AgentIdsExhausted) else Principal.AgentId.from_u64(most + 1).map_err(|_| AgentIdsExhausted)
}

u64_most : U64
u64_most = 18446744073709551615

## The most of a form's body.
form_most : U64
form_most = 4 * 1024

## A key's secret: the OS's entropy, as a session's is.
secret_bytes : U64
secret_bytes = 32

## **/agents**: an agent made, from a session; stored, and answered.
make_agent! : {} => Chat.Answer
make_agent! = |{}| {
	got = Host.read_body!(form_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match Credentials.presented!({}) {
				Err(answer) => answer
				Ok(Nobody) => signed_out
				Ok(Session(s)) => made_by!(Session(s), got.bytes)
				Ok(Key(k)) => made_by!(Key(k), got.bytes)
			}
	}
}

made_by! : Agents.Maker, List(U8) => Chat.Answer
made_by! = |maker, form| {
	now = Host.read_time!({})
	name =
		match SignInWeb.form_field(form, "name") {
			Ok(n) => n
			Err(_) => []
		}
	match (Store.accounts!({}), SignIn.settings!({})) {
		(Ok(accounts), Ok(settings)) =>
			match Agents.make({ maker, name, accounts, settings, now }) {
				NameRefused(_) => Wire.refused(400, "that name is not one we can show")
				Stuck(_) => Chat.failed
				Refused(why) => {
					match next_agent_id(accounts) {
						Ok(id) => audit_grant!(maker, { acts_as: Principal.Id.Agent(id), refusal: why, now })
						Err(AgentIdsExhausted) => {}
					}
					grant_refused(why)
				}
				Made({ agent, steps }) =>
					match Store.save_accounts!(GitHubSignIn.applied(steps, { accounts, settings })) {
						Failed => Chat.failed
						Written => Wire.json(201, agent_json(agent))
					}
			}
		_ => Chat.failed
	}
}

## **/keys, POST**: a key minted, from a session, for the session's human
## or one of their agents or bots (ApiKey decides); its secret shown once.
mint! : {} => Chat.Answer
mint! = |{}| {
	got = Host.read_body!(form_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match Credentials.presented!({}) {
				Err(answer) => answer
				Ok(Nobody) => signed_out
				Ok(Session(s)) => minted!(Session(s), { default_as: Principal.Id.Human(s.human()), form: got.bytes })
				Ok(Key(k)) => minted!(Key(k), { default_as: k.acts_as(), form: got.bytes })
			}
	}
}

minted! : Agents.Maker, { default_as : Principal.Id, form : List(U8) } => Chat.Answer
minted! = |granter, { default_as, form }|
	match asked_grant(form, default_as) {
		Err(why) => Wire.refused(400, why)
		Ok({ acts_as, scope, lifetime }) => {
			now = Host.read_time!({})
			match (Store.accounts!({}), Store.next_key_id!({})) {
				(Ok(accounts), Ok(id)) => {
					secret = Host.random_bytes!(secret_bytes)
					match Stored.SecretHash.from_bytes(Host.hash!(secret)) {
						Err(NotAHash) => Chat.failed
						Ok(hash) =>
							match ConvKey.issue({ granter, acts_as, scope, accounts, now }, { key: id, expires: now + lifetime }) {
								Err(Refused(why)) => {
									audit_grant!(granter, { acts_as, refusal: why, now })
									grant_refused(why)
								}
								Ok(key) =>
									match Store.save_key!({ key, hash }) {
										Failed => Chat.failed
										Written => Wire.json(201, key_json(key, Shown(secret)))
									}
							}
					}
				}
				_ => Chat.failed
			}
		}
	}

## **WHAT A MINT'S FORM ASKS**: who the key acts as, its scope, and how
## long it lives; or why the form does not read.
asked_grant : List(U8), Principal.Id -> Try({ acts_as : Principal.Id, scope : ApiKey.Scope(ConvAccess.ConvId), lifetime : I64 }, Str)
asked_grant = |form, default_as| {
	acts_as =
		match SignInWeb.form_field(form, "as") {
			Err(Missing) => Ok(default_as)
			Err(Malformed) => Err("`as` names who the key acts as, as `agent:7`")
			Ok(text) => AccountCodec.id_from(text, "as").map_err(|_| "`as` names who the key acts as, as `agent:7`")
		}?
	read = reach_asked(form, "read")?
	post = reach_asked(form, "post")?
	admin =
		match SignInWeb.form_field(form, "admin") {
			Err(Missing) => Ok(Off)
			Ok(v) if v == Str.to_utf8("off") => Ok(Off)
			Ok(v) if v == Str.to_utf8("on") => Ok(On)
			_ => Err("`admin` is `on` or `off`")
		}?
	lifetime =
		match SignInWeb.form_field(form, "lifetime") {
			Err(Missing) => Ok(KeyCodec.max_lifetime_secs)
			Err(Malformed) => Err("`lifetime` is seconds")
			Ok(v) => Stored.time(v, "lifetime").map_err(|_| "`lifetime` is seconds")
		}?
	Ok({ acts_as, scope: { read, post, admin }, lifetime })
}

## A read's or a post's reach, as the form spells it (KeyCodec's one
## spelling); everywhere when the form names none.
reach_asked : List(U8), Str -> Try([Off, On(ApiKey.Reach(ConvAccess.ConvId))], Str)
reach_asked = |form, name|
	match SignInWeb.form_field(form, name) {
		Err(Missing) => Ok(On(Everywhere))
		Err(Malformed) => Err("`${name}` is `everywhere`, `off` or `only:` and conversation ids")
		Ok(v) => KeyCodec.reach_from(v, { name, make: ConvAccess.ConvId.from_u64 }).map_err(|_| "`${name}` is `everywhere`, `off` or `only:` and conversation ids")
	}

## **/keys, GET**: the session's human's keys and their agents', by id;
## never a secret or a hash.
list! : {} => Chat.Answer
list! = |{}|
	match owner!({}) {
		Err(answer) => answer
		Ok({ human, accounts }) =>
			match Store.keys!({}) {
				Err(Failed) => Chat.failed
				Ok(entries) => {
					mine = List.keep_if(List.map(entries, |e| e.key), |k| Agents.is_owned_by(k, { human, accounts }))
					Wire.json(200, List.join([Str.to_utf8("{\"keys\":["), Wire.commas(List.map(by_id(mine), |k| key_json(k, Hidden))), Str.to_utf8("]}")]))
				}
			}
	}

## The keys in the order of their ids.
by_id : List(ConvKey.Key) -> List(ConvKey.Key)
by_id = |keys|
	List.fold(
		keys,
		[],
		|sorted, k| {
			n = k.id().to_u64()
			List.concat(List.append(List.keep_if(sorted, |m| m.id().to_u64() < n), k), List.keep_if(sorted, |m| m.id().to_u64() > n))
		},
	)

## **/keys/<id>/revoke**: one of the session's keys revoked, for good.
revoke! : Principal.KeyId => Chat.Answer
revoke! = |id|
	match owner!({}) {
		Err(answer) => answer
		Ok({ human, accounts }) =>
			match Store.keys!({}) {
				Err(Failed) => Chat.failed
				Ok(entries) =>
					match List.find_first(entries, |e| e.key.id() == id and Agents.is_owned_by(e.key, { human, accounts })) {
						Err(_) => Wire.refused(404, "no such key of yours")
						Ok(entry) => {
							revoked = entry.key.revoke()
							match Store.save_key!({ key: revoked, hash: entry.hash }) {
								Failed => Chat.failed
								Written => Wire.json(200, key_json(revoked, Hidden))
							}
						}
					}
			}
	}

## **THE HUMAN A LIVE SESSION SIGNS IN**, for listing and revoking: a key
## manages no key (a 403), nobody signed in is a 401.
owner! : {} => Try({ human : Principal.GitHubId, accounts : List(Principal) }, Chat.Answer)
owner! = |{}| {
	credential = Credentials.presented!({})?
	match credential {
		Nobody => Err(signed_out)
		Key(_) => Err(Wire.refused(403, "keys are managed from a session"))
		Session(session) => {
			now = Host.read_time!({})
			accounts = Store.accounts!({}).map_err(|_| Chat.failed)?
			match session.admit({ accounts, now }) {
				Refused(_) => Err(signed_out)
				Admitted({ principal, write: _ }) => Ok({ human: Principal.answers_to(principal), accounts })
			}
		}
	}
}

## **A GRANT REFUSED, AUDITED**: who asked, by which session or key, for
## whom, and why.
audit_grant! : Agents.Maker, { acts_as : Principal.Id, refusal : ApiKey.GrantRefusal, now : I64 } => {}
audit_grant! = |granter, { acts_as, refusal, now }| {
	(who, via) =
		match granter {
			Session(s) => (Principal.Id.Human(s.human()), Session(s.id()))
			Key(k) => (k.acts_as(), Key(k.id()))
		}
	match AuditCodec.Entry.of_key(Grant({ at: now, who, via, acts_as, refusal })) {
		Ok(entry) => Store.audit!(entry)
		Err(ClockOutOfRange) => {}
	}
}

## A refused grant's answer: no live session is a 401, an expiry that does
## not fit a 400, and anything else (a key asking, not the granter's own,
## admin beyond the principal) a 403.
grant_refused : ApiKey.GrantRefusal -> Chat.Answer
grant_refused = |why|
	match why {
		SessionExpired | NoSuchGranter => signed_out
		BadExpiry => Wire.refused(400, "a key lives more than no time, and a year at most")
		GrantedByKey => Wire.refused(403, "a key is minted from a session, never from a key")
		NotTheGrantersOwn | NoSuchPrincipal => Wire.refused(403, "a key acts as you, or as an agent or a bot of yours")
		AdminBeyondPrincipal => Wire.refused(403, "admin is for an admin, or an admin's agent")
		ClockOutOfRange => Chat.failed
	}

signed_out : Chat.Answer
signed_out = Wire.refused(401, "not signed in")

## An agent as the wire spells it: `{"id":"agent:7","name":"CC","owner":"human:2"}`.
agent_json : Principal -> List(U8)
agent_json = |agent|
	List.join([
		Str.to_utf8("{\"id\":\"${AccountCodec.id_text(Principal.id(agent))}\",\"name\":"),
		Wire.json_string(Str.to_utf8(name_of(agent))),
		Str.to_utf8(",\"owner\":\"${AccountCodec.id_text(Principal.Id.Human(Principal.answers_to(agent)))}\"}"),
	])

name_of : Principal -> Str
name_of = |p|
	match p {
		Human(h) => h.name
		Agent(a) => a.name
		Bot(b) => b.name
	}

## **A KEY AS THE WIRE SPELLS IT**: its public id, who it acts as, its
## scope in KeyCodec's spelling, when it was made and expires, and whether
## it is revoked; its secret only when just minted (`Shown`), never after.
key_json : ConvKey.Key, [Shown(List(U8)), Hidden] -> List(U8)
key_json = |key, secret| {
	r = key.record()
	revoked =
		match r.revocation {
			Active => "false"
			Revoked => "true"
		}
	admin =
		match r.scope.admin {
			Off => "off"
			On => "on"
		}
	shown =
		match secret {
			Shown(bytes) => List.join([Str.to_utf8(",\"secret\":\""), SignInWeb.hex(bytes), ['"']])
			Hidden => []
		}
	List.join([
		Str.to_utf8("{\"id\":${r.id.to_u64().to_str()},\"acts_as\":\"${AccountCodec.id_text(r.acts_as)}\",\"read\":\"${KeyCodec.reach_text(r.scope.read, ConvAccess.ConvId.to_u64)}\",\"post\":\"${KeyCodec.reach_text(r.scope.post, ConvAccess.ConvId.to_u64)}\",\"admin\":\"${admin}\",\"created\":${r.created.to_str()},\"expires\":${r.expires.to_str()},\"revoked\":${revoked}"),
		shown,
		['}'],
	])
}

# ── tests
expect Agents.route(Str.to_utf8("/agents")) == Ok(MakeAgent)
expect Agents.route(Str.to_utf8("/keys")) == Ok(Keys)
expect Agents.route(Str.to_utf8("/keys/4/revoke")).map_ok(|r| r == Revoke(Cast.kid(4))) == Ok(Bool.True)
expect Agents.route(Str.to_utf8("/keys/0/revoke")).is_err()
expect Agents.route(Str.to_utf8("/keys/04/revoke")).is_err()
expect Agents.route(Str.to_utf8("/keys/4")).is_err()
expect Agents.route(Str.to_utf8("/agentsx")).is_err()

## Human `who`'s session, signed in at 0 to their account of generation 1.
session_of : U64 -> Session
session_of = |who|
	match SessionCodec.decode(Str.to_utf8("session v1 id=${who.to_str()} human=${who.to_str()} generation=1 token=${Str.repeat("07", 32)} created=0 seen=0\n")) {
		Ok(line) => Session.load(line)
		Err(_) => crash "session_of: a test's session line decodes"
	}

## The settings after the cast's accounts (every one of generation 1).
settings_at : U64 -> GitHubSignIn.Settings
settings_at = |next| { first_admin: Unnamed, barred: [], next_generation: Cast.gen(next) }

## What `make` decided, said plainly: the agent's id, owner, generation
## and name, and the counter it leaves; or the refusal.
Said : [Agent({ id : U64, owner : U64, generation : U64, name : Str, next : U64 }), NameRefused(DisplayName.Problem), Refused([GrantedByKey, SessionExpired, NoSuchGranter, ClockOutOfRange]), Stuck([StaleGeneration, GenerationsExhausted, AgentIdsExhausted]), Other]

said : Agents.Made -> Said
said = |made|
	match made {
		Made({ agent: Agent(a), steps: [AdvanceGeneration(n), AddAccount(_)] }) => Agent({ id: a.id.to_u64(), owner: a.owner.to_u64(), generation: a.generation.to_u64(), name: a.name, next: n.to_u64() })
		Made(_) => Other
		NameRefused(p) => NameRefused(p)
		Refused(why) => Refused(why)
		Stuck(why) => Stuck(why)
	}

## Boss (an admin) or ann (a member), by session, makes `name` among the cast at 50.
made_by : U64, Str -> Agents.Made
made_by = |who, name| Agents.make({ maker: Session(session_of(who)), name: Str.to_utf8(name), accounts: Cast.accounts, settings: settings_at(2), now: 50 })

# The next agent id is one past every agent's and bot's (the cast's are 1,
# 2 and 3); the generation, the settings'; the counter, advanced.
expect said(made_by(2, "CC")) == Agent({ id: 4, owner: 2, generation: 2, name: "CC", next: 3 })
expect said(made_by(1, "  LC  ")) == Agent({ id: 4, owner: 1, generation: 2, name: "LC", next: 3 })
expect next_agent_id([]) == Ok(Cast.aid(1))
expect next_agent_id([Cast.boss]) == Ok(Cast.aid(1))

# **NEVER GIVEN TWICE**: the first agent's steps applied, the second gets
# the next id and the next generation.
## The made agent's steps applied to the cast and `settings`.
applied_to_cast : Agents.Made -> { accounts : List(Principal), settings : GitHubSignIn.Settings }
applied_to_cast = |made|
	match made {
		Made({ agent: _, steps }) => GitHubSignIn.applied(steps, { accounts: Cast.accounts, settings: settings_at(2) })
		_ => crash "applied_to_cast: a test's agent is made"
	}

after_first : { accounts : List(Principal), settings : GitHubSignIn.Settings }
after_first = applied_to_cast(made_by(2, "CC"))

expect
	said(Agents.make({ maker: Session(session_of(2)), name: Str.to_utf8("LC"), accounts: after_first.accounts, settings: after_first.settings, now: 50 }))
		== Agent({ id: 5, owner: 2, generation: 3, name: "LC", next: 4 })
# A counter that went back is refused, never given twice.
expect said(Agents.make({ maker: Session(session_of(2)), name: Str.to_utf8("LC"), accounts: after_first.accounts, settings: settings_at(2), now: 50 })) == Stuck(StaleGeneration)

# A bad name is refused; so is anyone but a live session.
expect said(made_by(2, "")) == NameRefused(Empty)
expect said(made_by(2, "a\nb")) == NameRefused(ControlCharacter)
expect said(Agents.make({ maker: Session(session_of(2)), name: Str.to_utf8("CC"), accounts: Cast.accounts, settings: settings_at(2), now: Session.idle_secs })) == Refused(SessionExpired)
expect said(Agents.make({ maker: Session(session_of(2)), name: Str.to_utf8("CC"), accounts: Cast.without_ann, settings: settings_at(2), now: 50 })) == Refused(NoSuchGranter)
expect said(Agents.make({ maker: Session(session_of(2)), name: Str.to_utf8("CC"), accounts: Cast.accounts, settings: settings_at(2), now: -1 })) == Refused(ClockOutOfRange)

## The key a test's grant makes.
granted : Try(ConvKey.Key, [Refused(ApiKey.GrantRefusal)]) -> ConvKey.Key
granted = |t|
	match t {
		Ok(k) => k
		Err(_) => crash "granted: a test's key is grantable"
	}

ann_key : ConvKey.Key
ann_key =
	granted(ConvKey.issue({ granter: Session(session_of(2)), acts_as: Principal.id(Cast.ann), scope: { read: On(Everywhere), post: On(Everywhere), admin: Off }, accounts: Cast.accounts, now: 50 }, { key: Cast.kid(1), expires: 1000 }))

expect said(Agents.make({ maker: Key(ann_key), name: Str.to_utf8("CC"), accounts: Cast.accounts, settings: settings_at(2), now: 50 })) == Refused(GrantedByKey)

# Whose keys: ann's own, and her agent's; never boss's.
expect Agents.is_owned_by(ann_key, { human: Cast.gid(2), accounts: Cast.accounts })
expect !Agents.is_owned_by(ann_key, { human: Cast.gid(1), accounts: Cast.accounts })

# A mint's form: the defaults, and each field.
expect asked_grant([], Principal.id(Cast.ann)) == Ok({ acts_as: Principal.id(Cast.ann), scope: { read: On(Everywhere), post: On(Everywhere), admin: Off }, lifetime: KeyCodec.max_lifetime_secs })
expect
	asked_grant(Str.to_utf8("as=agent%3A3&read=only%3A3%2C9&post=off&admin=on&lifetime=60"), Principal.id(Cast.ann)).map_ok(|g| (g.acts_as, g.lifetime, g.scope.admin, g.scope.post))
		== Ok((Principal.Id.Agent(Cast.aid(3)), 60, On, Off))
expect asked_grant(Str.to_utf8("read=all"), Principal.id(Cast.ann)).is_err()
expect asked_grant(Str.to_utf8("as=agent%3A0"), Principal.id(Cast.ann)).is_err()
expect asked_grant(Str.to_utf8("lifetime=-1"), Principal.id(Cast.ann)).is_err()

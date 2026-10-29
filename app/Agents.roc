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
##     POST /invites             invite an agent: `as=agent:7` and a mint's
##                               other fields, for the key it redeems to
##     GET  /invites             this session's live invites
##     POST /invites/<id>/revoke revoke one of them
##     POST /invites/redeem      the agent's: `code=`, and no cookie or key;
##                               the key, its secret shown once
##
## **ONLY A SESSION**: a key never makes an agent, mints a key or invites
## (the core's GrantedByKey, audited); nor lists or revokes one. **THE
## SECRET IS SHOWN ONCE**, in the mint's answer: 32 bytes from the host, in
## hex. Only its hash is kept (Store.save_key!), and no listing holds
## either.
##
## **AN AGENT'S KEY COMES ONLY FROM AN INVITE** (Steve: humans never pass a
## durable secret around): a mint acting as an agent or a bot is refused.
## The human invites (ApiKey.may_grant decides, as it does a mint), and is
## shown a code once, which lives `invite_lifetime_secs`; the agent
## redeems it, with no other credential, for the key. The redemption
## grants again, as the session that invited, against the accounts then
## (`Agents.redeemed`), and spends the invite in the same turn, so a code
## redeems once. Every invite made, redeemed, revoked or refused is
## audited; a refusal is one 401 that says no more.
import pf.Chat
import pf.Host
import AccountCodec
import Admin
import ApiKey
import AuditCodec
import Cast
import ConvAccess
import ConvKey
import Credentials
import InviteCodec
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

	## What a path under `/agents`, `/keys` or `/invites` asks.
	Route : [MakeAgent, Keys, Revoke(Principal.KeyId), Invites, Redeem, RevokeInvite(InviteCodec.InviteId)]

	## The route a path names, if it names one.
	route : List(U8) -> Try(Agents.Route, [NotAgents])
	route = |path|
		if path == Str.to_utf8("/agents") {
			Ok(MakeAgent)
		} else if path == Str.to_utf8("/keys") {
			Ok(Keys)
		} else if path == Str.to_utf8("/invites") {
			Ok(Invites)
		} else if path == Str.to_utf8("/invites/redeem") {
			Ok(Redeem)
		} else {
			match List.split_on(path, '/') {
				[[], keys, digits, act] if keys == Str.to_utf8("keys") and act == Str.to_utf8("revoke") =>
					Stored.id(digits, { name: "key", make: Principal.KeyId.from_u64 }).map_ok(|id| Revoke(id)).map_err(|_| NotAgents)
				[[], invites, digits, act] if invites == Str.to_utf8("invites") and act == Str.to_utf8("revoke") =>
					Stored.id(digits, { name: "invite", make: InviteCodec.InviteId.from_u64 }).map_ok(|id| RevokeInvite(id)).map_err(|_| NotAgents)
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
			Invites =>
				match req.method {
					Post => invite!({})
					Get => list_invites!({})
					_ => Chat.not_allowed(Get)
				}
			Redeem => if req.method == Post redeem!({}) else Chat.not_allowed(Post)
			RevokeInvite(id) => if req.method == Post revoke_invite!(id) else Chat.not_allowed(Post)
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
		Stuck([StaleGeneration, GenerationsExhausted, StaleAgentId, AgentIdsExhausted]),
	]

	## **MAKE AN AGENT**: owned by the human a live session signs in, named
	## by DisplayName's rule, with the settings' next agent id
	## (GitHubSignIn.next_agent_id: never given twice, not even a retired
	## agent's) and next generation (GitHubSignIn.next_generation); the
	## steps advance both counters first, then add the account, for
	## GitHubSignIn.applied, as a sign-up's do.
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
							match (DisplayName.from_utf8(name), GitHubSignIn.next_generation(accounts, settings), GitHubSignIn.next_agent_id(accounts, settings)) {
								(Err(problem), _, _) => NameRefused(problem)
								(_, Err(why), _) => Stuck(why)
								(_, _, Err(why)) => Stuck(why)
								(Ok(chosen), Ok({ this, next }), Ok(ids)) => {
									agent = Principal.Agent({ id: ids.this, name: chosen.to_str(), owner: Principal.answers_to(principal), generation: this })
									Made({ agent, steps: [AdvanceGeneration(next), AdvanceAgentId(ids.next), AddAccount(agent)] })
								}
							}
					}
			}
		}

	## **MAY THIS GRANTER INVITE `acts_as`, FOR A KEY OF THIS SCOPE AND
	## LIFETIME?** ApiKey.may_grant decides, exactly as for a mint (only a
	## live session, for its own agents and bots, admin only for an admin's);
	## then the invite is for an agent or a bot (a human's key is minted),
	## and the key's lifetime one a mint may give. The agent, bound to its
	## accounts as they are now.
	invited : { granter : Agents.Maker, acts_as : Principal.Id, scope : ApiKey.Scope(ConvAccess.ConvId), lifetime : I64, accounts : List(Principal), now : I64 } -> Try(Principal.Bound, [Refused(ApiKey.GrantRefusal), NotAnAgent])
	invited = |{ granter, acts_as, scope, lifetime, accounts, now }|
		match ApiKey.may_grant({ granter, acts_as, scope, accounts, now }) {
			Refused(why) => Err(Refused(why))
			Grantable =>
				match acts_as {
					Human(_) => Err(NotAnAgent)
					_ if !InviteCodec.is_key_lifetime(lifetime) => Err(Refused(BadExpiry))
					_ => Principal.bind(accounts, acts_as).map_err(|_| Refused(NoSuchPrincipal))
				}
		}

	## **WHAT A REDEMPTION DECIDES**: the key, or why not. A live invite,
	## before its expiry (a clock before its making is trusted for nothing),
	## its agent's binding holding now, and the grant decided again as its
	## granter (ApiKey.may_grant through ConvKey.issue: the session still
	## live, the agent still its human's) against the accounts now. `granter`
	## is the invite's, as the store holds it now: `Gone` when it holds none.
	redeemed : { invite : InviteCodec.Record(ConvAccess.ConvId), granter : [Found(Agents.Maker), Gone], accounts : List(Principal), now : I64, key : Principal.KeyId } -> Try(ConvKey.Key, InviteCodec.Refusal)
	redeemed = |{ invite, granter, accounts, now, key }|
		match invite.state {
			Spent => Err(Spent)
			Revoked => Err(Revoked)
			Live if now < invite.created or now >= invite.expires => Err(Expired)
			Live =>
				match (Principal.holds(accounts, invite.bound), granter) {
					(Err(_), _) => Err(NoLongerHolds)
					(Ok(_), Gone) => Err(Grant(NoSuchGranter))
					(Ok(_), Found(g)) =>
						match ConvKey.issue({ granter: g, acts_as: invite.bound.id, scope: invite.scope, accounts, now }, { key, expires: now + invite.lifetime }) {
							Ok(k) => Ok(k)
							Err(Refused(why)) => Err(Grant(why))
						}
				}
		}

	## **THE INVITE IS ONE OF THIS HUMAN'S**: for an agent or a bot the
	## accounts say they own now.
	is_invited_by : InviteCodec.Record(ConvAccess.ConvId), { human : Principal.GitHubId, accounts : List(Principal) } -> Bool
	is_invited_by = |invite, { human, accounts }|
		match Principal.find(accounts, invite.bound.id) {
			Ok(p) => Principal.answers_to(p) == human
			Err(_) => Bool.False
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

## The most of a form's body.
form_most : U64
form_most = 4 * 1024

## A key's secret: the OS's entropy, as a session's is. An invite's code
## is as many.
secret_bytes : U64
secret_bytes = 32

## **AN INVITE LIVES TEN MINUTES** (Steve): long enough to hand the code
## to an agent in the sitting it was made in, short enough that a code
## left in a chat log, a terminal's scrollback or a shell's history is
## dead before anyone finds it. The key it redeems to lives its own
## lifetime. The end to end tests the expiry by moving the host's clock
## (server.zig's `clock_ahead_s_for_test`), never by waiting.
invite_lifetime_secs : I64
invite_lifetime_secs = 600

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
					audit_grant!(maker, { acts_as: Principal.Id.Agent(settings.next_agent_id), refusal: why, now })
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
		Ok({ acts_as, scope: _, lifetime: _ }) if is_session(granter) and !is_human(acts_as) =>
			Wire.refused(403, "an agent's or a bot's key comes from an invite: POST /invites, and the agent redeems its code")
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

## Whether the granter is a session.
is_session : Agents.Maker -> Bool
is_session = |granter|
	match granter {
		Session(_) => Bool.True
		Key(_) => Bool.False
	}

## Whether the id is a human's.
is_human : Principal.Id -> Bool
is_human = |id|
	match id {
		Human(_) => Bool.True
		Agent(_) | Bot(_) => Bool.False
	}

## **/invites, POST**: an invite, from a session, for one of its agents or
## bots (Agents.invited decides); its code shown once.
invite! : {} => Chat.Answer
invite! = |{}| {
	got = Host.read_body!(form_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match Credentials.presented!({}) {
				Err(answer) => answer
				Ok(Nobody) => signed_out
				Ok(Session(s)) => invited_by!(Session(s), { default_as: Principal.Id.Human(s.human()), form: got.bytes })
				Ok(Key(k)) => invited_by!(Key(k), { default_as: k.acts_as(), form: got.bytes })
			}
	}
}

invited_by! : Agents.Maker, { default_as : Principal.Id, form : List(U8) } => Chat.Answer
invited_by! = |granter, { default_as, form }|
	match asked_grant(form, default_as) {
		Err(why) => Wire.refused(400, why)
		Ok({ acts_as, scope, lifetime }) => {
			now = Host.read_time!({})
			match (Store.accounts!({}), Store.next_invite_id!({}), granter_hash!(granter)) {
				(Ok(accounts), Ok(id), Ok(by)) =>
					match Agents.invited({ granter, acts_as, scope, lifetime, accounts, now }) {
						Err(NotAnAgent) => Wire.refused(400, "an invite is for one of your agents or bots, `as=agent:7`; your own key is minted")
						Err(Refused(why)) => {
							audit_grant!(granter, { acts_as, refusal: why, now })
							grant_refused(why)
						}
						Ok(bound) => {
							code = Host.random_bytes!(secret_bytes)
							match Stored.SecretHash.from_bytes(Host.hash!(code)) {
								Err(NotAHash) => Chat.failed
								Ok(hash) => {
									invite = { id, bound, by, hash, created: now, expires: now + invite_lifetime_secs, state: Live, lifetime, scope }
									match Store.save_invite!(invite) {
										Failed => Chat.failed
										Written => {
											audit_invite!({ at: now, invite: Known({ id, agent: bound.id }), verdict: Created(via_of(granter)) })
											Wire.json(201, invite_json(invite, Shown(code)))
										}
									}
								}
							}
						}
					}
				_ => Chat.failed
			}
		}
	}

## **THE GRANTER BY ITS STORED HASH**: a session's cookie's, a key's
## Bearer secret's, as the store keeps each.
granter_hash! : Agents.Maker => Try(InviteCodec.By, [Failed])
granter_hash! = |granter|
	match granter {
		Session(s) => Ok(Session(s.fields().token_hash))
		Key(_) =>
			match Credentials.bearer_secret(Host.read_header!(Str.to_utf8("authorization"))) {
				Err(NotABearer) => Err(Failed)
				Ok(secret) => Stored.SecretHash.from_bytes(Host.hash!(secret)).map_ok(|h| Key(h)).map_err(|_| Failed)
			}
	}

## The session or key an invite was made by, by its public id, for its
## audit line.
via_of : Agents.Maker -> [Session(Principal.SessionId), Key(Principal.KeyId)]
via_of = |granter|
	match granter {
		Session(s) => Session(s.id())
		Key(k) => Key(k.id())
	}

## **/invites/redeem**: the code, from an agent with no other credential,
## for the key; refused, audited, and one 401 otherwise.
redeem! : {} => Chat.Answer
redeem! = |{}| {
	got = Host.read_body!(form_most)
	match got.status {
		Answered => Chat.answered
		Read => {
			now = Host.read_time!({})
			if Host.read_header!(Str.to_utf8("authorization")) != [] or Host.read_header!(Str.to_utf8("cookie")) != [] {
				invite_refused!({ invite: Unknown, why: CredentialSent, now })
			} else {
				match SignInWeb.form_field(got.bytes, "code") {
					Err(_) => invite_refused!({ invite: Unknown, why: Unknown, now })
					Ok(hex) =>
						match SignInWeb.unhex(hex) {
							Err(NotHex) => invite_refused!({ invite: Unknown, why: Unknown, now })
							Ok(code) =>
								match Stored.SecretHash.from_bytes(Host.hash!(code)) {
									Err(NotAHash) => Chat.failed
									Ok(hash) =>
										match Store.invite!(hash) {
											Err(Failed) => Chat.failed
											Err(Missing) | Err(Malformed) => invite_refused!({ invite: Unknown, why: Unknown, now })
											Ok(invite) => redeemed_now!(invite, now)
										}
								}
						}
				}
			}
		}
	}
}

## **THE INVITE REDEEMED, OR REFUSED**: decided (Agents.redeemed); then,
## **SPENT FIRST**, before the key is stored, so a crash between leaves a
## spent invite and no key, never a key and a live invite.
redeemed_now! : InviteCodec.Record(ConvAccess.ConvId), I64 => Chat.Answer
redeemed_now! = |invite, now| {
	known = Known({ id: invite.id, agent: invite.bound.id })
	match (Store.accounts!({}), Store.next_key_id!({}), stored_granter!(invite.by)) {
		(Ok(accounts), Ok(key_id), Ok(granter)) =>
			match Agents.redeemed({ invite, granter, accounts, now, key: key_id }) {
				Err(why) => invite_refused!({ invite: known, why, now })
				Ok(key) => {
					secret = Host.random_bytes!(secret_bytes)
					match Stored.SecretHash.from_bytes(Host.hash!(secret)) {
						Err(NotAHash) => Chat.failed
						Ok(hash) =>
							match Store.save_invite!({ ..invite, state: Spent }) {
								Failed => Chat.failed
								Written =>
									match Store.save_key!({ key, hash }) {
										Failed => Chat.failed
										Written => {
											audit_invite!({ at: now, invite: known, verdict: Redeemed(key.id()) })
											Wire.json(201, key_json(key, Shown(secret)))
										}
									}
							}
					}
				}
			}
		_ => Chat.failed
	}
}

## The granter an invite names, as the store holds it now.
stored_granter! : InviteCodec.By => Try([Found(Agents.Maker), Gone], [Failed])
stored_granter! = |by|
	match by {
		Session(h) =>
			match Store.session!(h) {
				Ok(line) => Ok(Found(Session(Session.load(line))))
				Err(Missing) | Err(Malformed) => Ok(Gone)
				Err(Failed) => Err(Failed)
			}
		Key(h) =>
			match Store.key!(h) {
				Ok(entry) => Ok(Found(Key(entry.key)))
				Err(Missing) | Err(Malformed) => Ok(Gone)
				Err(Failed) => Err(Failed)
			}
	}

## A redemption refused: audited, and a 401 that says no more.
invite_refused! : { invite : [Unknown, Known({ id : InviteCodec.InviteId, agent : Principal.Id })], why : InviteCodec.Refusal, now : I64 } => Chat.Answer
invite_refused! = |{ invite, why, now }| {
	audit_invite!({ at: now, invite, verdict: Refused(why) })
	Wire.refused(401, "invite refused")
}

## An invite's life, audited.
audit_invite! : AuditCodec.Invite => {}
audit_invite! = |event|
	match AuditCodec.Entry.of_invite(event) {
		Ok(entry) => Store.audit!(entry)
		Err(ClockOutOfRange) => {}
	}

## **/invites, GET**: the session's human's live invites, by id; never a
## code or a hash.
list_invites! : {} => Chat.Answer
list_invites! = |{}|
	match owner!({}) {
		Err(answer) => answer
		Ok({ human, accounts, session: _, now }) =>
			match Store.invites!({}) {
				Err(Failed) => Chat.failed
				Ok(all) => {
					live = List.keep_if(all, |i| is_live(i, now) and Agents.is_invited_by(i, { human, accounts }))
					Wire.json(200, List.join([Str.to_utf8("{\"invites\":["), Wire.commas(List.map(invites_by_id(live), |i| invite_json(i, Hidden))), Str.to_utf8("]}")]))
				}
			}
	}

## Live, and before its expiry.
is_live : InviteCodec.Record(ConvAccess.ConvId), I64 -> Bool
is_live = |invite, now|
	match invite.state {
		Live => now >= invite.created and now < invite.expires
		Spent | Revoked => Bool.False
	}

## The invites in the order of their ids.
invites_by_id : List(InviteCodec.Record(ConvAccess.ConvId)) -> List(InviteCodec.Record(ConvAccess.ConvId))
invites_by_id = |invites|
	List.fold(
		invites,
		[],
		|sorted, i| {
			n = i.id.to_u64()
			List.concat(List.append(List.keep_if(sorted, |m| m.id.to_u64() < n), i), List.keep_if(sorted, |m| m.id.to_u64() > n))
		},
	)

## **/invites/<id>/revoke**: one of the session's live invites revoked.
revoke_invite! : InviteCodec.InviteId => Chat.Answer
revoke_invite! = |id|
	match owner!({}) {
		Err(answer) => answer
		Ok({ human, accounts, session, now }) =>
			match Store.invites!({}) {
				Err(Failed) => Chat.failed
				Ok(all) =>
					match List.find_first(all, |i| i.id == id and is_live(i, now) and Agents.is_invited_by(i, { human, accounts })) {
						Err(_) => Wire.refused(404, "no such live invite of yours")
						Ok(invite) => {
							revoked = { ..invite, state: Revoked }
							match Store.save_invite!(revoked) {
								Failed => Chat.failed
								Written => {
									audit_invite!({ at: now, invite: Known({ id, agent: invite.bound.id }), verdict: Revoked(session) })
									Wire.json(200, invite_json(revoked, Hidden))
								}
							}
						}
					}
			}
	}

## **AN INVITE AS THE WIRE SPELLS IT**: its public id, whom it is for, and
## when it expires; its code only when just made (`Shown`), never after.
invite_json : InviteCodec.Record(ConvAccess.ConvId), [Shown(List(U8)), Hidden] -> List(U8)
invite_json = |invite, code| {
	shown =
		match code {
			Shown(bytes) => List.join([Str.to_utf8(",\"code\":\""), SignInWeb.hex(bytes), ['"']])
			Hidden => []
		}
	List.join([
		Str.to_utf8("{\"id\":${invite.id.to_u64().to_str()},\"for\":\"${AccountCodec.id_text(invite.bound.id)}\",\"expires\":${invite.expires.to_str()}"),
		shown,
		['}'],
	])
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
		Ok({ human, accounts, session: _, now: _ }) =>
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
		Ok({ human, accounts, session: _, now: _ }) =>
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
owner! : {} => Try({ human : Principal.GitHubId, accounts : List(Principal), session : Principal.SessionId, now : I64 }, Chat.Answer)
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
				Admitted({ principal, write: _ }) => Ok({ human: Principal.answers_to(principal), accounts, session: session.id(), now })
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
expect Agents.route(Str.to_utf8("/invites")) == Ok(Invites)
expect Agents.route(Str.to_utf8("/invites/redeem")) == Ok(Redeem)
expect Agents.route(Str.to_utf8("/invites/3/revoke")).map_ok(|r| r == RevokeInvite(iid(3))) == Ok(Bool.True)
expect Agents.route(Str.to_utf8("/invites/0/revoke")).is_err()
expect Agents.route(Str.to_utf8("/invites/x/revoke")).is_err()

## A test's invite id.
iid : U64 -> InviteCodec.InviteId
iid = |n|
	match InviteCodec.InviteId.from_u64(n) {
		Ok(id) => id
		Err(NotAnId) => crash "iid: a test's invite id is not 0"
	}

## Human `who`'s session, signed in at 0 to their account of generation 1.
session_of : U64 -> Session
session_of = |who|
	match SessionCodec.decode(Str.to_utf8("session v1 id=${who.to_str()} human=${who.to_str()} generation=1 token=${Str.repeat("07", 32)} created=0 seen=0\n")) {
		Ok(line) => Session.load(line)
		Err(_) => crash "session_of: a test's session line decodes"
	}

## The settings after the cast's accounts (every one of generation 1).
settings_at : U64 -> GitHubSignIn.Settings
settings_at = |next| { first_admin: Unnamed, barred: [], next_generation: Cast.gen(next), next_agent_id: Cast.aid(4) }

## What `make` decided, said plainly: the agent's id, owner, generation
## and name, and the counter it leaves; or the refusal.
Said : [Agent({ id : U64, owner : U64, generation : U64, name : Str, next : U64, next_id : U64 }), NameRefused(DisplayName.Problem), Refused([GrantedByKey, SessionExpired, NoSuchGranter, ClockOutOfRange]), Stuck([StaleGeneration, GenerationsExhausted, StaleAgentId, AgentIdsExhausted]), Other]

said : Agents.Made -> Said
said = |made|
	match made {
		Made({ agent: Agent(a), steps: [AdvanceGeneration(n), AdvanceAgentId(i), AddAccount(_)] }) => Agent({ id: a.id.to_u64(), owner: a.owner.to_u64(), generation: a.generation.to_u64(), name: a.name, next: n.to_u64(), next_id: i.to_u64() })
		Made(_) => Other
		NameRefused(p) => NameRefused(p)
		Refused(why) => Refused(why)
		Stuck(why) => Stuck(why)
	}

## Boss (an admin) or ann (a member), by session, makes `name` among the cast at 50.
made_by : U64, Str -> Agents.Made
made_by = |who, name| Agents.make({ maker: Session(session_of(who)), name: Str.to_utf8(name), accounts: Cast.accounts, settings: settings_at(2), now: 50 })

# The agent id and the generation are the settings'; both counters,
# advanced. (The cast's agents and bots are 1, 2 and 3.)
expect said(made_by(2, "CC")) == Agent({ id: 4, owner: 2, generation: 2, name: "CC", next: 3, next_id: 5 })
expect said(made_by(1, "  LC  ")) == Agent({ id: 4, owner: 1, generation: 2, name: "LC", next: 3, next_id: 5 })
# A store from before the counter starts it one past every agent's and
# bot's.
expect GitHubSignIn.agent_id_after(Cast.accounts) == Ok(Cast.aid(4))
expect GitHubSignIn.agent_id_after([]) == Ok(Cast.aid(1))
expect GitHubSignIn.agent_id_after([Cast.boss]) == Ok(Cast.aid(1))

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
		== Agent({ id: 5, owner: 2, generation: 3, name: "LC", next: 4, next_id: 6 })
# A counter that went back is refused, never given twice: the generation's,
# and the agent id's.
expect said(Agents.make({ maker: Session(session_of(2)), name: Str.to_utf8("LC"), accounts: after_first.accounts, settings: settings_at(2), now: 50 })) == Stuck(StaleGeneration)
expect said(Agents.make({ maker: Session(session_of(2)), name: Str.to_utf8("LC"), accounts: after_first.accounts, settings: { ..after_first.settings, next_agent_id: Cast.aid(4) }, now: 50 })) == Stuck(StaleAgentId)
expect said(Agents.make({ maker: Session(session_of(2)), name: Str.to_utf8("LC"), accounts: Cast.accounts, settings: { ..settings_at(2), next_agent_id: Cast.aid(3) }, now: 50 })) == Stuck(StaleAgentId)

# **A RETIRED AGENT'S ID IS NEVER GIVEN AGAIN**: the highest agent (4,
# ann's CC) retired by boss through Admin's plan, the next agent made is 5.
## Agent `n` retired by boss, through Admin's plan, from `start`.
retired_by_boss : U64, { accounts : List(Principal), settings : GitHubSignIn.Settings } -> { accounts : List(Principal), settings : GitHubSignIn.Settings }
retired_by_boss = |n, start|
	match Admin.decide({ credential: Session(session_of(1)), action: Retire(Principal.Id.Agent(Cast.aid(n))), accounts: start.accounts, settings: start.settings, now: 60 }) {
		Ok({ audit: _, plan }) => Admin.applied(plan, start)
		Err(_) => crash "retired_by_boss: a test's retirement is decided"
	}

after_retired : { accounts : List(Principal), settings : GitHubSignIn.Settings }
after_retired = retired_by_boss(4, after_first)

expect !List.any(after_retired.accounts, |p| Principal.id(p) == Principal.Id.Agent(Cast.aid(4)))
expect
	said(Agents.make({ maker: Session(session_of(2)), name: Str.to_utf8("CC"), accounts: after_retired.accounts, settings: after_retired.settings, now: 70 }))
		== Agent({ id: 5, owner: 2, generation: 3, name: "CC", next: 4, next_id: 6 })

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

# ── INVITES: who may invite (the grant rule, as a mint's), and what a
# redemption decides.
plain : ApiKey.Scope(ConvAccess.ConvId)
plain = { read: On(Everywhere), post: On(Everywhere), admin: Off }

## Ann's agent's id.
ann_agent_id : Principal.Id
ann_agent_id = Principal.id(Cast.ann_agent)

invited_as : { granter : Agents.Maker, acts_as : Principal.Id, lifetime : I64 } -> Try(Principal.Bound, [Refused(ApiKey.GrantRefusal), NotAnAgent])
invited_as = |{ granter, acts_as, lifetime }| Agents.invited({ granter, acts_as, scope: plain, lifetime, accounts: Cast.accounts, now: 50 })

expect invited_as({ granter: Session(session_of(2)), acts_as: ann_agent_id, lifetime: 60 }) == Ok({ id: ann_agent_id, generation: Cast.gen(1), human: Cast.gen(1) })
expect invited_as({ granter: Key(ann_key), acts_as: ann_agent_id, lifetime: 60 }) == Err(Refused(GrantedByKey))
expect invited_as({ granter: Session(session_of(1)), acts_as: ann_agent_id, lifetime: 60 }) == Err(Refused(NotTheGrantersOwn))
expect invited_as({ granter: Session(session_of(2)), acts_as: Principal.id(Cast.ann), lifetime: 60 }) == Err(NotAnAgent)
expect invited_as({ granter: Session(session_of(2)), acts_as: ann_agent_id, lifetime: 0 }) == Err(Refused(BadExpiry))
expect invited_as({ granter: Session(session_of(2)), acts_as: ann_agent_id, lifetime: KeyCodec.max_lifetime_secs + 1 }) == Err(Refused(BadExpiry))

## A test's hash: every byte `b`.
hash_of : U8 -> Stored.SecretHash
hash_of = |b|
	match Stored.SecretHash.from_bytes(List.repeat(b, 32)) {
		Ok(h) => h
		Err(NotAHash) => crash "hash_of: 32 bytes are a hash"
	}

## Ann's invite for her agent, made at 50, its key to live 1000 seconds.
anns_invite : InviteCodec.Record(ConvAccess.ConvId)
anns_invite = {
	id: iid(1),
	bound: { id: ann_agent_id, generation: Cast.gen(1), human: Cast.gen(1) },
	by: Session(hash_of(0x07)),
	hash: hash_of(0x22),
	created: 50,
	expires: 50 + invite_lifetime_secs,
	state: Live,
	lifetime: 1000,
	scope: plain,
}

## What redeeming `invite` at `now` decides, said plainly: the key's
## principal and expiry, or the refusal.
redeemed_at : { invite : InviteCodec.Record(ConvAccess.ConvId), granter : [Found(Agents.Maker), Gone], accounts : List(Principal), now : I64 } -> Try((Principal.Id, I64), InviteCodec.Refusal)
redeemed_at = |{ invite, granter, accounts, now }|
	Agents.redeemed({ invite, granter, accounts, now, key: Cast.kid(9) }).map_ok(|k| (k.acts_as(), k.record().expires))

by_ann : [Found(Agents.Maker), Gone]
by_ann = Found(Session(session_of(2)))

expect redeemed_at({ invite: anns_invite, granter: by_ann, accounts: Cast.accounts, now: 100 }) == Ok((ann_agent_id, 1100))
# Once spent, or revoked, never again; past its ten minutes, or before its
# making, expired.
expect redeemed_at({ invite: { ..anns_invite, state: Spent }, granter: by_ann, accounts: Cast.accounts, now: 100 }) == Err(Spent)
expect redeemed_at({ invite: { ..anns_invite, state: Revoked }, granter: by_ann, accounts: Cast.accounts, now: 100 }) == Err(Revoked)
expect redeemed_at({ invite: anns_invite, granter: by_ann, accounts: Cast.accounts, now: 50 + invite_lifetime_secs }) == Err(Expired)
expect redeemed_at({ invite: anns_invite, granter: by_ann, accounts: Cast.accounts, now: 49 }) == Err(Expired)
expect invite_lifetime_secs == 600
# The agent retired, or its owner: the invite redeems to nothing.
expect redeemed_at({ invite: anns_invite, granter: by_ann, accounts: List.drop_last(Cast.accounts, 1), now: 100 }) == Err(NoLongerHolds)
expect redeemed_at({ invite: anns_invite, granter: by_ann, accounts: Cast.without_ann, now: 100 }) == Err(NoLongerHolds)
# The agent made again under its id (a new generation): nothing.
expect redeemed_at({ invite: { ..anns_invite, bound: { ..anns_invite.bound, generation: Cast.gen(2) } }, granter: by_ann, accounts: Cast.accounts, now: 100 }) == Err(NoLongerHolds)
# The grant decided again: the inviting session gone, or over; a key never
# grants.
expect redeemed_at({ invite: anns_invite, granter: Gone, accounts: Cast.accounts, now: 100 }) == Err(Grant(NoSuchGranter))
expect redeemed_at({ invite: { ..anns_invite, created: Session.idle_secs, expires: Session.idle_secs + invite_lifetime_secs }, granter: by_ann, accounts: Cast.accounts, now: Session.idle_secs + 10 }) == Err(Grant(SessionExpired))
expect redeemed_at({ invite: anns_invite, granter: Found(Key(ann_key)), accounts: Cast.accounts, now: 100 }) == Err(Grant(GrantedByKey))
# Whose invites: ann's, for her agent; never boss's.
expect Agents.is_invited_by(anns_invite, { human: Cast.gid(2), accounts: Cast.accounts })
expect !Agents.is_invited_by(anns_invite, { human: Cast.gid(1), accounts: Cast.accounts })
expect is_live(anns_invite, 100) and !is_live(anns_invite, 650) and !is_live({ ..anns_invite, state: Spent }, 100)

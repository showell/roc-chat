## **SIGN-IN'S ROUTES**: `/login`, `/login/github`, `/login/name` and `/me`.
## Every decision is the auth core's (GitHubSignIn, OAuthState, Session);
## here are the facts asked of the host, the records kept (Store), and the
## answers made. A sign-in by another provider is a module beside this one,
## ending, as this does, in the core's Admission (Session.start takes
## nothing else).
import pf.Chat
import pf.Host
import AccountCodec
import AuditCodec
import GitHubSignIn
import OAuthState
import Principal
import Session
import SignInWeb
import Store
import Stored

SignIn := [].{

	## **/login**: a state minted (GitHubSignIn.Started), signed by the
	## host, and the browser sent to GitHub's authorize page with it; its
	## nonce set in this browser's state cookie for OAuthState's lifetime.
	login! : {} => Chat.Answer
	login! = |{}| {
		now = Host.read_time!({})
		match GitHubSignIn.Started.start({ nonce: Host.random_bytes!(nonce_bytes), now }) {
			Err(WeakNonce) => Chat.failed
			Ok(started) => {
				fields = started.state()
				location = List.join([
					Host.read_config!(GitHubAuthorize),
					Str.to_utf8("/login/oauth/authorize?client_id="),
					SignInWeb.url_encode(Host.read_config!(GitHubClientId)),
					Str.to_utf8("&redirect_uri="),
					SignInWeb.url_encode(List.concat(Host.read_config!(Origin), Str.to_utf8("/login/github"))),
					Str.to_utf8("&state="),
					signed!(State, SignInWeb.state_body(fields)),
				])
				see_other(location)
					|> Chat.with_header("set-cookie", SignInWeb.set_cookie("state", SignInWeb.hex(fields.nonce), OAuthState.lifetime_secs))
			}
		}
	}

	## **/login/github, GITHUB'S CALLBACK, IN TWO CALLS** (decision D1):
	## - the first checks the state (signed by us, this browser's, in its
	##   window, its nonce not spent) and asks the host to exchange the
	##   code, outside the turn, spending nothing;
	## - the second, the same request with what GitHub said, checks the
	##   state again, now spending its nonce (check-then-set in one turn),
	##   and resolves whose sign-in it is.
	## The Roc keeps nothing between them: the request is the facts. A
	## refusal is audited (`refused_or!`).
	callback! : Chat.Request => Chat.Answer
	callback! = |req| refused_or!(came_back!(req))

	## **/login/name**: the pending sign-up back from this browser
	## (GitHubSignIn.Pending.resume), and the name it gives; the account
	## made, or the name asked for again. A refusal is audited.
	name! : {} => Chat.Answer
	name! = |{}| refused_or!(named!({}))

	## **/me**: the session this browser's cookie names, admitted or not
	## (Session.admit), its `last seen` written when stale.
	me! : {} => Chat.Answer
	me! = |{}| {
		now = Host.read_time!({})
		match SignInWeb.cookie(Host.read_header!(Str.to_utf8("cookie")), "session") {
			Unsent => not_signed_in
			Sent(value) =>
				match SignInWeb.unhex(value) {
					Err(NotHex) => not_signed_in
					Ok(secret) =>
						match Stored.SecretHash.from_bytes(Host.hash!(secret)) {
							Err(NotAHash) => Chat.failed
							Ok(token_hash) =>
								match Store.session!(token_hash) {
									Err(Failed) => Chat.failed
									Err(Missing) => not_signed_in
									Err(Malformed) => not_signed_in
									Ok(line) =>
										match Store.accounts!({}) {
											Err(Failed) => Chat.failed
											Ok(accounts) => admitted!(Session.load(line), { accounts, now })
										}
								}
						}
				}
		}
	}
}

## The session admitted against the accounts, or not; its `last seen`
## written when stale.
admitted! : Session, { accounts : List(Principal), now : I64 } => Chat.Answer
admitted! = |session, as_of|
	match session.admit(as_of) {
		Refused(_) => not_signed_in
		Admitted({ principal, write }) => {
			touched =
				match write {
					Unchanged => Written
					Touched(s) => Store.save_session!(s.fields())
				}
			if touched == Written {
				Chat.plain(Str.to_utf8("signed in as ${AccountCodec.id_text(Principal.id(principal))}\n"))
			} else {
				Chat.failed
			}
		}
	}

## A state's nonce, and a session's secret: the OS's entropy.
nonce_bytes : U64
nonce_bytes = 32

## The most of the name form's body.
form_most : U64
form_most = 4 * 1024

came_back! : Chat.Request => Try(Chat.Answer, GitHubSignIn.Refusal)
came_back! = |req| {
	now = Host.read_time!({})
	answer =
		match List.first(Host.read_query!(Str.to_utf8("code"))) {
			Ok(code) => Code(code)
			Err(_) => Denied
		}
	state =
		match List.first(Host.read_query!(Str.to_utf8("state"))) {
			Ok(token) => verified!(State, token, SignInWeb.state_fields)
			Err(_) => Unsigned
		}
	came = GitHubSignIn.CameBack.came_back({ state, answer })?
	cookie = SignInWeb.state_cookie(SignInWeb.cookie(Host.read_header!(Str.to_utf8("cookie")), "state"))
	match Store.nonce_use!(State, came.nonce()) {
		Err(Failed) => Ok(Chat.failed)
		Ok(nonce_use) => {
			checked = came.check({ cookie, now, nonce_use })?
			match Chat.exchanged(req) {
				NotAsked => Ok(Chat.exchange(checked.code()))
				said =>
					match Store.spend!(State, came.nonce()) {
						Failed => Ok(Chat.failed)
						Written => {
							github =
								match said {
									Known(who) => Identified(who)
									_ => Failed
								}
							known = checked.identify(github)?
							match facts!({}) {
								Err(Failed) => Ok(Chat.failed)
								Ok(f) =>
									match known.resolve({ accounts: f.accounts, settings: f.settings, session: f.session, now }) {
										Refused(why) => Err(why)
										SignedIn({ admission, steps }) => Ok(signed_in!(f, { admission, steps }))
										NeedsName(pending) => {
											token = signed!(Pending, SignInWeb.pending_body(pending.fields()))
											Ok(
												name_form(Ok({}))
													|> Chat.with_header("set-cookie", SignInWeb.set_cookie("pending", token, OAuthState.lifetime_secs)),
											)
										}
									}
							}
						}
					}
			}
		}
	}
}

named! : {} => Try(Chat.Answer, GitHubSignIn.Refusal)
named! = |{}| {
	got = Host.read_body!(form_most)
	match got.status {
		Answered => Ok(Chat.answered)
		Read => {
			now = Host.read_time!({})
			cookies = Host.read_header!(Str.to_utf8("cookie"))
			pending =
				match SignInWeb.cookie(cookies, "pending") {
					Sent(token) => verified!(Pending, token, SignInWeb.pending_fields)
					Unsent => Unsigned
				}
			resumed = GitHubSignIn.Pending.resume({ pending, cookie: SignInWeb.state_cookie(SignInWeb.cookie(cookies, "state")), now })?
			# A field missing or malformed is no name: DisplayName says so.
			name =
				match SignInWeb.form_field(got.bytes, "name") {
					Ok(n) => n
					Err(_) => []
				}
			match (Store.nonce_use!(Pending, resumed.nonce()), facts!({})) {
				(Ok(pending_use), Ok(f)) =>
					match resumed.name({ name, pending_use, accounts: f.accounts, settings: f.settings, session: f.session, now }) {
						Refused(why) => Err(why)
						NameRefused(problem) => Ok(name_form(Err(problem)))
						Created({ admission, steps }) =>
							match Store.spend!(Pending, resumed.nonce()) {
								Failed => Ok(Chat.failed)
								Written => Ok(signed_in!(f, { admission, steps }))
							}
					}
				_ => Ok(Chat.failed)
			}
		}
	}
}

## **SIGNED IN**: the plan's steps applied (GitHubSignIn.applied: the
## settings' counter, then the accounts), the session started
## (Session.start), all three stored, and the session cookie set; the
## state and pending cookies ended.
signed_in! : Facts, { admission : GitHubSignIn.Admission, steps : List(GitHubSignIn.Step) } => Chat.Answer
signed_in! = |f, { admission, steps }| {
	after = GitHubSignIn.applied(steps, { accounts: f.accounts, settings: f.settings })
	session = Session.start(admission)
	match Store.save_signed_in!({ accounts: after.accounts, settings: after.settings, session: session.fields() }) {
		Failed => Chat.failed
		Written =>
			see_other(Str.to_utf8("/"))
				|> Chat.with_header("set-cookie", SignInWeb.set_cookie("session", SignInWeb.hex(f.secret), Session.absolute_secs))
				|> Chat.with_header("set-cookie", SignInWeb.set_cookie("state", [], 0))
				|> Chat.with_header("set-cookie", SignInWeb.set_cookie("pending", [], 0))
	}
}

## Not signed in: a 401, no reason given.
not_signed_in : Chat.Answer
not_signed_in = Chat.respond(401, { content_type: Chat.text, body: Str.to_utf8("not signed in\n") })

## **A REFUSED SIGN-IN**: audited, and a 403 naming why, as the audit
## spells it (AuditCodec).
refused_or! : Try(Chat.Answer, GitHubSignIn.Refusal) => Chat.Answer
refused_or! = |decided|
	match decided {
		Ok(answer) => answer
		Err(why) => {
			match AuditCodec.Entry.of_sign_in({ at: Host.read_time!({}), github: Unknown, refusal: why }) {
				Ok(entry) => Store.audit!(entry)
				Err(ClockOutOfRange) => {}
			}
			Chat.respond(403, { content_type: Chat.text, body: Str.to_utf8("sign-in refused: ${AuditCodec.sign_in_refusal_text(why)}\n") })
				|> Chat.with_header("set-cookie", SignInWeb.set_cookie("pending", [], 0))
		}
	}

## The name form; with why the last name was refused, a 400.
name_form : Try({}, _) -> Chat.Answer
name_form = |last| {
	said =
		match last {
			Ok({}) => ""
			Err(_) => "<p>That name is not one we can show. Try another.</p>\n"
		}
	page = Str.to_utf8("<!doctype html>\n<title>Your name</title>\n${said}<form method=post action=/login/name><label>Your name in the chat <input name=name maxlength=64 required></label> <button>Sign up</button></form>\n")
	status = if last.is_ok() 200 else 400
	Chat.respond(status, { content_type: Chat.html, body: page })
		|> Chat.with_header("cache-control", Str.to_utf8("no-store"))
}

## A 303 to `location`.
see_other : List(U8) -> Chat.Answer
see_other = |location|
	Chat.respond(303, { content_type: Chat.text, body: [] })
		|> Chat.with_header("location", location)

## `body`, signed by the host for `purpose`, as a token.
signed! : SignInWeb.Purpose, List(U8) => List(U8)
signed! = |purpose, body| SignInWeb.token(body, Host.sign!(SignInWeb.signed_message(purpose, body)))

## A token's fields when the host's MAC holds and its body reads; else
## `Unsigned`, which the core refuses (a forgery).
verified! : SignInWeb.Purpose, List(U8), (List(U8) -> Try(a, [Malformed])) => [Signed(a), Unsigned]
verified! = |purpose, token, fields_of|
	match SignInWeb.untoken(token) {
		Err(Malformed) => Unsigned
		Ok({ body, mac }) =>
			match Host.verify!(SignInWeb.signed_message(purpose, body), mac) {
				Invalid => Unsigned
				Valid =>
					match fields_of(body) {
						Ok(fields) => Signed(fields)
						Err(Malformed) => Unsigned
					}
			}
	}

## What resolving or naming is decided against: the accounts, the
## settings, and a new session's facts (its secret, its number and the
## secret's hash).
Facts : {
	accounts : List(Principal),
	settings : GitHubSignIn.Settings,
	session : GitHubSignIn.NewSession,
	secret : List(U8),
}

facts! : {} => Try(Facts, [Failed])
facts! = |{}| {
	accounts = Store.accounts!({})?
	settings = Store.settings!(first_admin!({})?)?
	secret = Host.random_bytes!(nonce_bytes)
	id = Principal.SessionId.from_u64(SignInWeb.u64_of(Host.random_bytes!(8))).map_err(|_| Failed)?
	token_hash = Stored.SecretHash.from_bytes(Host.hash!(secret)).map_err(|_| Failed)?
	Ok({ accounts, settings, session: { id, token_hash }, secret })
}

## The first admin the config names, if it names one.
first_admin! : {} => Try([Unnamed, Named(Principal.GitHubId)], [Failed])
first_admin! = |{}| {
	admin = Host.read_config!(BootstrapAdmin)
	if admin == [] {
		Ok(Unnamed)
	} else {
		Stored.id(admin, { name: "bootstrap_admin", make: Principal.GitHubId.from_u64 }).map_ok(|id| Named(id)).map_err(|_| Failed)
	}
}

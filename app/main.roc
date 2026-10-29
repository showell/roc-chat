## THE ROC CHAT, A STUB AND SIGN-IN FOR NOW: a hello page (rendered by
## roc-markdown, the chat's dialect), a POST echoed (the body through
## `read_body!`, a header through `read_header!`), the chat client's scripts
## (`serve_script!`), and GitHub sign-in on the auth core (`/login`,
## `/login/github`, `/login/name`, and `/me` to say who a session is). The
## chat itself comes after.
app [handle!] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import pf.Chat
import pf.Host
import md.Md

## The auth core. ConvKey is imported for its expects until a route uses
## it: with AuditCodec it reaches every one of the core's modules.
import ConvKey
import AuditCodec
import AccountCodec
import GitHubSignIn
import OAuthState
import Principal
import Session
import SessionCodec
import SignInWeb
import Stored

## The most of a body `/echo` reads; the host's own cap is larger, so a body
## between the two is the Roc's to refuse (through the host's 413).
echo_most : U64
echo_most = 32 * 1024

handle! : Chat.Request => Chat.Answer
handle! = |req|
	if req.path == Str.to_utf8("/") {
		if req.method == Get or req.method == Head {
			hello
		} else {
			Chat.not_allowed(Get)
		}
	} else if req.path == Str.to_utf8("/echo") {
		if req.method == Post {
			echo!(req)
		} else {
			Chat.not_allowed(Post)
		}
	} else if req.path == Str.to_utf8("/stub/notes") {
		notes!(req)
	} else if req.path == Str.to_utf8("/login") {
		if req.method == Get login!({}) else Chat.not_allowed(Get)
	} else if req.path == Str.to_utf8("/login/github") {
		if req.method == Get refused_or!(callback!(req)) else Chat.not_allowed(Get)
	} else if req.path == Str.to_utf8("/login/name") {
		if req.method == Post refused_or!(name!({})) else Chat.not_allowed(Post)
	} else if req.path == Str.to_utf8("/me") {
		if req.method == Get me!({}) else Chat.not_allowed(Get)
	} else {
		match script_name(req.path) {
			Ok(name) =>
				match Host.serve_script!(name) {
					Served => Chat.answered
					Missing => Chat.not_found
				}
			Err(NotAScript) => Chat.not_found
		}
	}

## The hello page, never cached.
hello : Chat.Answer
hello = {
	page = List.join([
		Str.to_utf8("<!doctype html>\n<title>roc-chat</title>\n"),
		Md.render_trusted(Str.to_utf8("**Hello** from roc-chat. The chat is not here yet.")),
	])
	Chat.respond(200, { content_type: Chat.html, body: page })
		|> Chat.with_header("cache-control", Str.to_utf8("no-store"))
}

## The request said back: its path, its `x-probe` header's values, and its
## body.
echo! : Chat.Request => Chat.Answer
echo! = |req| {
	got = Host.read_body!(echo_most)
	match got.status {
		Answered => Chat.answered
		Read => {
			probes = Host.read_header!(Str.to_utf8("x-probe"))
			Chat.plain(
				List.join([
					Str.to_utf8("path "),
					req.path,
					Str.to_utf8("\nx-probe "),
					List.join(List.map(probes, |p| List.concat(p, [' ']))),
					Str.to_utf8("\nbody ${U64.to_str(List.len(got.bytes))} bytes\n"),
					got.bytes,
				]),
			)
		}
	}
}

## **A STUB OF THE FILES, WHICH STEP 6 REPLACES**: a POST's body appended
## to one file, its size after said back; a GET, the file. It proves
## `append!` and `read!` through the seam, and nothing more.
notes_path : List(U8)
notes_path = Str.to_utf8("stub/notes.txt")

notes! : Chat.Request => Chat.Answer
notes! = |req|
	if req.method == Post {
		got = Host.read_body!(echo_most)
		match got.status {
			Answered => Chat.answered
			Read => {
				appended = Host.append!(notes_path, got.bytes)
				match appended.status {
					Appended => Chat.plain(Str.to_utf8("size ${U64.to_str(appended.size)}\n"))
					Failed => failed
				}
			}
		}
	} else if req.method == Get {
		read = Host.read!(notes_path)
		match read.status {
			Found => Chat.plain(read.bytes)
			Missing => Chat.not_found
			Failed => failed
		}
	} else {
		Chat.not_allowed(Get)
	}

## The host failed the request; it answers the 500 whatever this says.
failed : Chat.Answer
failed = Chat.respond(500, { content_type: Chat.text, body: Str.to_utf8("failed\n") })

# ── SIGN-IN: every decision the core's (GitHubSignIn, OAuthState,
# Session); here, the facts asked of the host and the answers made.

## A state's nonce, and a session's secret: the OS's entropy.
nonce_bytes : U64
nonce_bytes = 32

## The most of the name form's body.
form_most : U64
form_most = 4 * 1024

## **/login**: a state minted (GitHubSignIn.Started), signed by the host, and
## the browser sent to GitHub's authorize page with it; its nonce set in
## this browser's state cookie for OAuthState's lifetime.
login! : {} => Chat.Answer
login! = |{}| {
	now = Host.read_time!({})
	match GitHubSignIn.Started.start({ nonce: Host.random_bytes!(nonce_bytes), now }) {
		Err(WeakNonce) => failed
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
##   window, its nonce not spent) and asks the host to exchange the code,
##   outside the turn, spending nothing;
## - the second, the same request with what GitHub said, checks the state
##   again, now spending its nonce (check-then-set in one turn), and
##   resolves whose sign-in it is.
## The Roc keeps nothing between them: the request is the facts.
callback! : Chat.Request => Try(Chat.Answer, GitHubSignIn.Refusal)
callback! = |req| {
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
	spent = spent_path("state", came.nonce())
	match nonce_use!(spent) {
		Err(Failed) => Ok(failed)
		Ok(nonce_use) => {
			checked = came.check({ cookie, now, nonce_use })?
			match Chat.exchanged(req) {
				NotAsked => Ok(Chat.exchange(checked.code()))
				said => {
					match Host.write!(spent, []) {
						Failed => Ok(failed)
						Written => {
							github =
								match said {
									Known(who) => Identified(who)
									_ => Failed
								}
							known = checked.identify(github)?
							match facts!(now) {
								Err(Failed) => Ok(failed)
								Ok(f) =>
									match known.resolve({ accounts: f.accounts, settings: f.settings, session: f.session, now }) {
										Refused(why) => Err(why)
										SignedIn({ admission, steps }) => Ok(signed_in!(f, { admission, steps, secret: f.secret }))
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
}

## **/login/name**: the pending sign-up back from this browser
## (GitHubSignIn.Pending.resume), and the name it gives; the account made,
## or the name asked for again.
name! : {} => Try(Chat.Answer, GitHubSignIn.Refusal)
name! = |{}| {
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
			spent = spent_path("pending", resumed.nonce())
			# A field missing or malformed is no name: DisplayName says so.
			name =
				match SignInWeb.form_field(got.bytes, "name") {
					Ok(n) => n
					Err(_) => []
				}
			match (nonce_use!(spent), facts!(now)) {
				(Ok(pending_use), Ok(f)) =>
					match resumed.name({ name, pending_use, accounts: f.accounts, settings: f.settings, session: f.session, now }) {
						Refused(why) => Err(why)
						NameRefused(problem) => Ok(name_form(Err(problem)))
						Created({ admission, steps }) =>
							match Host.write!(spent, []) {
								Failed => Ok(failed)
								Written => Ok(signed_in!(f, { admission, steps, secret: f.secret }))
							}
					}
				_ => Ok(failed)
			}
		}
	}
}

## **SIGNED IN**: the plan's steps stored (GitHubSignIn.applied: the
## settings' counter, then the accounts), the session started
## (Session.start) and stored by its secret's hash, and the session cookie
## set; the state and pending cookies ended.
signed_in! : Facts, { admission : GitHubSignIn.Admission, steps : List(GitHubSignIn.Step), secret : List(U8) } => Chat.Answer
signed_in! = |f, { admission, steps, secret }| {
	after = GitHubSignIn.applied(steps, { accounts: f.accounts, settings: f.settings })
	session = Session.start(admission)
	fields = session.fields()
	accounts_text = List.map_try(after.accounts, AccountCodec.encode)
	match accounts_text {
		Err(_) => failed
		Ok(lines) => {
			wrote_settings = Host.write!(settings_path, SignInWeb.settings_line(after.settings.next_generation))
			wrote_accounts = Host.write!(accounts_path, List.join(lines))
			wrote_session = Host.write!(session_path(fields.token_hash), SessionCodec.encode(fields))
			if wrote_settings == Written and wrote_accounts == Written and wrote_session == Written {
				see_other(Str.to_utf8("/"))
					|> Chat.with_header("set-cookie", SignInWeb.set_cookie("session", SignInWeb.hex(secret), Session.absolute_secs))
					|> Chat.with_header("set-cookie", SignInWeb.set_cookie("state", [], 0))
					|> Chat.with_header("set-cookie", SignInWeb.set_cookie("pending", [], 0))
			} else {
				failed
			}
		}
	}
}

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
				Ok(secret) => match Stored.SecretHash.from_bytes(Host.hash!(secret)) {
					Err(NotAHash) => failed
					Ok(token_hash) => {
						read = Host.read!(session_path(token_hash))
						match read.status {
							Failed => failed
							Missing => not_signed_in
							Found =>
								match (SessionCodec.decode(read.bytes), accounts!({})) {
									(_, Err(Failed)) => failed
									(Err(_), _) => not_signed_in
									(Ok(line), Ok(accounts)) =>
										match Session.load(line).admit({ accounts, now }) {
											Refused(_) => not_signed_in
											Admitted({ principal, write }) => {
												touched =
													match write {
														Unchanged => Written
														Touched(s) => Host.write!(session_path(token_hash), SessionCodec.encode(s.fields()))
													}
												if touched == Written {
													Chat.plain(Str.to_utf8("signed in as ${AccountCodec.id_text(Principal.id(principal))}\n"))
												} else {
													failed
												}
											}
										}
								}
						}
					}
				}
			}
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
			now = Host.read_time!({})
			match AuditCodec.Entry.of_sign_in({ at: now, github: Unknown, refusal: why }) {
				Ok(entry) => {
					_ = Host.append!(audit_path, AuditCodec.encode(entry))
					{}
				}
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

# ── the store: every record through the core's codecs

accounts_path : List(U8)
accounts_path = Str.to_utf8("auth/accounts")

settings_path : List(U8)
settings_path = Str.to_utf8("auth/settings")

barred_path : List(U8)
barred_path = Str.to_utf8("auth/barred")

audit_path : List(U8)
audit_path = Str.to_utf8("auth/audit")

## A session's file, named for its secret's hash: found only by one who
## holds the secret, with no compare to time.
session_path : Stored.SecretHash -> List(U8)
session_path = |h| Str.to_utf8("auth/sessions/${Stored.hash_text(h)}")

## A spent nonce's file: `kind` is `state` or `pending`, each its own set.
spent_path : Str, List(U8) -> List(U8)
spent_path = |kind, nonce| List.concat(Str.to_utf8("auth/spent/${kind}/"), SignInWeb.hex(nonce))

## Whether the nonce's file says it was spent.
nonce_use! : List(U8) => Try([FirstUse, UsedBefore], [Failed])
nonce_use! = |path| {
	read = Host.read!(path)
	match read.status {
		Missing => Ok(FirstUse)
		Found => Ok(UsedBefore)
		Failed => Err(Failed)
	}
}

## Every account (AccountCodec.load); none before the first.
accounts! : {} => Try(List(Principal), [Failed])
accounts! = |{}| {
	read = Host.read!(accounts_path)
	match read.status {
		Missing => Ok([])
		Failed => Err(Failed)
		Found => AccountCodec.load(read.bytes).map_err(|_| Failed)
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

facts! : I64 => Try(Facts, [Failed])
facts! = |_now| {
	accounts = accounts!({})?
	settings = settings!({})?
	secret = Host.random_bytes!(nonce_bytes)
	id = Principal.SessionId.from_u64(SignInWeb.u64_of(Host.random_bytes!(8))).map_err(|_| Failed)?
	token_hash = Stored.SecretHash.from_bytes(Host.hash!(secret)).map_err(|_| Failed)?
	Ok({ accounts, settings, session: { id, token_hash }, secret })
}

## The settings: the first admin the config names, the barred ids, and the
## generation counter (1 before the first account).
settings! : {} => Try(GitHubSignIn.Settings, [Failed])
settings! = |{}| {
	admin = Host.read_config!(BootstrapAdmin)
	first_admin =
		if admin == [] {
			Ok(Unnamed)
		} else {
			Stored.id(admin, { name: "bootstrap_admin", make: Principal.GitHubId.from_u64 }).map_ok(|id| Named(id)).map_err(|_| Failed)
		}
	settings_read = Host.read!(settings_path)
	next_generation =
		match settings_read.status {
			Missing => Principal.Generation.from_u64(1).map_err(|_| Failed)
			Failed => Err(Failed)
			Found => SignInWeb.settings_next(settings_read.bytes).map_err(|_| Failed)
		}
	barred_read = Host.read!(barred_path)
	barred =
		match barred_read.status {
			Missing => Ok([])
			Failed => Err(Failed)
			Found => SignInWeb.barred(barred_read.bytes).map_err(|_| Failed)
		}
	Ok({ first_admin: first_admin?, barred: barred?, next_generation: next_generation? })
}

## `/<name>.js`, one part: the script's name.
script_name : List(U8) -> Try(List(U8), [NotAScript])
script_name = |path| {
	name = List.drop_first(path, 1)
	if List.starts_with(path, ['/']) and List.ends_with(name, Str.to_utf8(".js")) and !List.contains(name, '/') {
		Ok(name)
	} else {
		Err(NotAScript)
	}
}

expect script_name(Str.to_utf8("/chat.js")) == Ok(Str.to_utf8("chat.js"))
expect script_name(Str.to_utf8("/a/chat.js")) == Err(NotAScript)
expect script_name(Str.to_utf8("/chat.css")) == Err(NotAScript)

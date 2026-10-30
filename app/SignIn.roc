## **SIGN-IN'S ROUTES**: `/login`, `/login/github`, `/login/name` and `/me`.
## Every decision is the auth core's (GitHubSignIn, OAuthState, Session);
## here are the facts asked of the host, the records kept (Store), and the
## answers made. A sign-in by another provider is a module beside this one,
## ending, as this does, in the core's Admission (Session.start takes
## nothing else).
import pf.Chat
import pf.Host
import Accounts
import AccountCodec
import AuditCodec
import GitHubSignIn
import Html
import OAuthState
import Principal
import Session
import SignInWeb
import Store
import Stored
import Wire

SignIn := [].{

	## **/login**: a state minted (GitHubSignIn.Started), signed by the
	## host, and the browser sent to GitHub's authorize page with it; its
	## nonce set in this browser's state cookie for OAuthState's lifetime.
	login! : {} => Chat.Answer
	login! = |{}| {
		now = Host.read_time!({})
		match GitHubSignIn.Started.start({ nonce: Host.random_bytes!(Wire.secret_bytes), now }) {
			Err(WeakNonce) => Chat.failed
			Ok(started) => {
				fields = started.state()
				location = List.join([
					Host.read_config!(GitHubAuthorize),
					Str.to_utf8("/login/oauth/authorize?client_id="),
					SignInWeb.url_encode(Host.read_config!(GitHubClientId)),
					Str.to_utf8("&redirect_uri="),
					SignInWeb.url_encode(
						List.concat(
							Host.read_config!(Origin),
							Str.to_utf8("/login/github"),
						),
					),
					Str.to_utf8("&state="),
					sign_token!(State, SignInWeb.state_body(fields)),
				])
				see_other(location)
					|> Chat.with_header(
						"set-cookie",
						SignInWeb.set_cookie({
							name: "state",
							contents: SignInWeb.hex(fields.nonce),
							max_age: OAuthState.lifetime_secs,
						}),
					)
			}
		}
	}

	## **/login/github, GITHUB'S CALLBACK, IN TWO CALLS**, so the turn is
	## never held while GitHub answers:
	## - the first checks the state (signed by us, this browser's, in its
	##   window, its nonce not spent) and asks the host to exchange the
	##   code, outside the turn, spending nothing;
	## - the second, the same request with what GitHub said, checks the
	##   state again, now spending its nonce (check-then-set in one turn),
	##   and resolves whose sign-in it is.
	## The Roc keeps nothing between them: the request is the facts. A
	## refusal past the exchange is audited (`answer_refused!`).
	serve_callback! : Chat.Request => Chat.Answer
	serve_callback! = |req| answer_refused!(check_callback!(req))

	## **/login/name**: the pending sign-up back from this browser
	## (GitHubSignIn.Pending.resume), and the name it gives; the account
	## made, or the name asked for again. Its refusals are a pending
	## sign-up's, anonymous, and never audited (`answer_refused!`).
	serve_name! : {} => Chat.Answer
	serve_name! = |{}| answer_refused!(sign_up!({}))

	## **/logout, POST**: the session this browser's cookie names ended
	## (its record removed, so the cookie is a 401 from now on, wherever it
	## was copied), the cookie cleared, and a 303 to `/`. No session, or a
	## cookie naming none, is signed out already: the same answer. Behind
	## Origin's check, as every write is, so another site cannot sign
	## someone out.
	serve_logout! : {} => Chat.Answer
	serve_logout! = |{}| {
		removed =
			match SignInWeb.cookie(Host.read_header!(Str.to_utf8("cookie")), "session") {
				Unsent => Removed
				Sent(value) =>
					match SignInWeb.unhex(value) {
						Err(NotHex) => Removed
						Ok(secret) =>
							match Stored.SecretHash.from_bytes(Host.hash!(secret)) {
								Err(NotAHash) => Failed
								Ok(token_hash) => Store.remove_session!(token_hash)
							}
					}
			}
		match removed {
			Failed => Chat.failed
			Removed =>
				see_other(Str.to_utf8("/"))
					|> Chat.with_header(
						"set-cookie",
						SignInWeb.set_cookie({
							name: "session",
							contents: [],
							max_age: 0,
						}),
					)
		}
	}

	## **THE SESSION THIS BROWSER'S COOKIE NAMES**, as stored, not yet
	## admitted (Credentials admits it, and a grant asks ApiKey). No cookie,
	## one that is not hex, no such session, or a malformed one, is none.
	## Never anything the request claims.
	load_cookie_session! : {} => Try([NoSession, Found(Session)], [Failed])
	load_cookie_session! = |{}|
		match SignInWeb.cookie(Host.read_header!(Str.to_utf8("cookie")), "session") {
			Unsent => Ok(NoSession)
			Sent(value) =>
				match SignInWeb.unhex(value) {
					Err(NotHex) => Ok(NoSession)
					Ok(secret) =>
						match Stored.SecretHash.from_bytes(Host.hash!(secret)) {
							Err(NotAHash) => Err(Failed)
							Ok(token_hash) =>
								match Store.load_session!(token_hash) {
									Err(Failed) => Err(Failed)
									Err(Missing) => Ok(NoSession)
									Err(Malformed) => Ok(NoSession)
									Ok(line) => Ok(Found(Session.load(line)))
								}
						}
				}
		}

	## **THE SETTINGS NOW**: the store's, with the first admin the config
	## names. What a sign-in and an agent's making decide on.
	load_settings! : {} => Try(Accounts.Settings, [Failed])
	load_settings! = |{}| Store.load_settings!(load_first_admin!({})?)

	## **/me**: the session this browser's cookie names, admitted or not
	## (Session.admit), its `last seen` written when stale.
	serve_me! : {} => Chat.Answer
	serve_me! = |{}| {
		now = Host.read_time!({})
		match SignIn.load_cookie_session!({}) {
			Err(Failed) => Chat.failed
			Ok(NoSession) => not_signed_in
			Ok(Found(session)) =>
				match Store.load_accounts!({}) {
					Err(Failed) => Chat.failed
					Ok(accounts) => admit!(session, { accounts, now })
				}
		}
	}

}

## The session admitted against the accounts, or not; its `last seen`
## written when stale.
admit! : Session, { accounts : List(Principal), now : I64 } => Chat.Answer
admit! = |session, as_of|
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

check_callback! : Chat.Request => Try(Chat.Answer, _)
check_callback! = |req| {
	now = Host.read_time!({})
	answer =
		match List.first(Host.read_query!(Str.to_utf8("code"))) {
			Ok(code) => Code(code)
			Err(_) => Denied
		}
	state =
		match List.first(Host.read_query!(Str.to_utf8("state"))) {
			Ok(token) => check_signed!({
				purpose: State,
				token: token,
				fields_of: SignInWeb.state_fields,
			})
			Err(_) => Unsigned
		}
	came = GitHubSignIn.CameBack.came_back({ state, answer })?
	cookies = Host.read_header!(Str.to_utf8("cookie"))
	cookie = SignInWeb.state_cookie(SignInWeb.cookie(cookies, "state"))
	match Store.load_nonce_use!(State, came.nonce()) {
		Err(Failed) => Ok(Chat.failed)
		Ok(nonce_use) => {
			checked = came.check({
				cookie,
				now,
				nonce_use,
			})?
			match Chat.exchanged(req) {
				NotAsked => Ok(Chat.exchange(checked.code()))
				said =>
					match Store.spend_nonce!(State, came.nonce()) {
						Failed => Ok(Chat.failed)
						Written => {
							github =
								match said {
									Known(who) => Identified(who)
									_ => Failed
								}
							known = checked.identify(github)?
							match load_facts!({}) {
								Err(Failed) => Ok(Chat.failed)
								Ok(f) =>
									match known.resolve({
										accounts: f.accounts,
										settings: f.settings,
										session: f.session,
										now,
									}) {
										Refused(why) => Err(why)
										SignedIn({ admission, steps }) => Ok(
											sign_in!(
												f,
												{ admission, steps },
											),
										)
										NeedsName(pending) => {
											token = sign_token!(
												Pending,
												SignInWeb.pending_body(pending.fields()),
											)
											Ok(
												name_form(Ok({}))
													|> Chat.with_header(
														"set-cookie",
														SignInWeb.set_cookie({
															name: "pending",
															contents: token,
															max_age: OAuthState.lifetime_secs,
														}),
													),
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

sign_up! : {} => Try(Chat.Answer, _)
sign_up! = |{}| {
	got = Host.read_body!(Wire.form_most)
	match got.status {
		Answered => Ok(Chat.answered)
		Read => {
			now = Host.read_time!({})
			cookies = Host.read_header!(Str.to_utf8("cookie"))
			pending =
				match SignInWeb.cookie(cookies, "pending") {
					Sent(token) => check_signed!({
						purpose: Pending,
						token: token,
						fields_of: SignInWeb.pending_fields,
					})
					Unsent => Unsigned
				}
			resumed = GitHubSignIn.Pending.resume({
				pending,
				cookie: SignInWeb.state_cookie(SignInWeb.cookie(cookies, "state")),
				now,
			})?
			# A field missing or malformed is no name: DisplayName says so.
			name =
				match SignInWeb.form_field(got.bytes, "name") {
					Ok(n) => n
					Err(_) => []
				}
			match (Store.load_nonce_use!(Pending, resumed.nonce()), load_facts!({})) {
				(Ok(pending_use), Ok(f)) =>
					match resumed.name({
						name,
						pending_use,
						accounts: f.accounts,
						settings: f.settings,
						session: f.session,
						now,
					}) {
						Refused(why) => Err(why)
						NameRefused(problem) => Ok(name_form(Err(problem)))
						Created({ admission, steps }) =>
							match Store.spend_nonce!(Pending, resumed.nonce()) {
								Failed => Ok(Chat.failed)
								Written => Ok(sign_in!(f, { admission, steps }))
							}
					}
				_ => Ok(Chat.failed)
			}
		}
	}
}

## **SIGNED IN**: the plan's steps applied (Accounts.applied: the
## settings' counter, then the accounts), the session started
## (Session.start), all three stored, and the session cookie set; the
## state and pending cookies ended.
sign_in! : Facts,
{
	admission : GitHubSignIn.Admission,
	steps : List(Accounts.Change),
} => Chat.Answer
sign_in! = |f, { admission, steps }| {
	after = Accounts.applied(steps, { accounts: f.accounts, settings: f.settings })
	session = Session.start(admission)
	match Store.save_signed_in!({
		accounts: after.accounts,
		settings: after.settings,
		session: session.fields(),
	}) {
		Failed => Chat.failed
		Written =>
			see_other(Str.to_utf8("/"))
				|> Chat.with_header(
					"set-cookie",
					SignInWeb.set_cookie({
						name: "session",
						contents: SignInWeb.hex(f.secret),
						max_age: Session.absolute_secs,
					}),
				)
				|> Chat.with_header(
					"set-cookie",
					SignInWeb.set_cookie({
						name: "state",
						contents: [],
						max_age: 0,
					}),
				)
				|> Chat.with_header(
					"set-cookie",
					SignInWeb.set_cookie({
						name: "pending",
						contents: [],
						max_age: 0,
					}),
				)
	}
}

## Not signed in: a 401, no reason given.
not_signed_in : Chat.Answer
not_signed_in = Chat.respond(401, { content_type: Chat.text, body: Str.to_utf8("not signed in\n") })

## **A REFUSED SIGN-IN**: audited unless anonymous (GitHubSignIn.audited),
## and a 403 naming why, as the audit spells it (AuditCodec).
answer_refused! : Try(Chat.Answer, GitHubSignIn.Refusal) => Chat.Answer
answer_refused! = |decided|
	match decided {
		Ok(answer) => answer
		Err(why) => {
			match GitHubSignIn.audited(why) {
				Anonymous => {}
				Audited =>
					match AuditCodec.Entry.of_sign_in({
						at: Host.read_time!({}),
						github: Unknown,
						refusal: why,
					}) {
						Ok(entry) => Store.append_audit!(entry)
						Err(ClockOutOfRange) => {}
					}
			}
			Chat.respond(
				403,
				{
					content_type: Chat.text,
					body: Str.to_utf8("sign-in refused: ${AuditCodec.sign_in_refusal_text(why)}\n"),
				},
			)
				|> Chat.with_header(
					"set-cookie",
					SignInWeb.set_cookie({
						name: "pending",
						contents: [],
						max_age: 0,
					}),
				)
		}
	}

## The name form; with why the last name was refused, a 400.
name_form : Try({}, _) -> Chat.Answer
name_form = |last| {
	said =
		match last {
			Ok({}) => Html.join([])
			Err(_) => Html.markup("<p>That name is not one we can show. Try another.</p>\n")
		}
	page = Html.join([
		Html.markup("<!doctype html>\n<title>Your name</title>\n"),
		said,
		Html.markup("<form method=post action=/login/name><label>Your name in the chat <input name=name maxlength=64 required></label> <button>Sign up</button></form>\n"),
	])
	Html.respond(if (last.is_ok()) 200 else 400, page)
}

## A 303 to `location`.
see_other : List(U8) -> Chat.Answer
see_other = |location|
	Chat.respond(303, { content_type: Chat.text, body: [] })
		|> Chat.with_header("location", location)

## `body`, signed by the host for `purpose`, as a token.
sign_token! : SignInWeb.Purpose, List(U8) => List(U8)
sign_token! = |purpose, body| SignInWeb.token(
	body,
	Host.sign!(SignInWeb.signed_message(purpose, body)),
)

## A token's fields when the host's MAC holds and its body reads; else
## `Unsigned`, which the core refuses (a forgery).
check_signed! : {
	purpose : SignInWeb.Purpose,
	token : List(U8),
	fields_of : (List(U8) -> Try(a, [Malformed])),
} => [Signed(a), Unsigned]
check_signed! = |
	{
		purpose,
		token,
		fields_of,
	},
|
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
	settings : Accounts.Settings,
	session : GitHubSignIn.NewSession,
	secret : List(U8),
}

load_facts! : {} => Try(Facts, [Failed])
load_facts! = |{}| {
	accounts = Store.load_accounts!({})?
	settings = SignIn.load_settings!({})?
	secret = Host.random_bytes!(Wire.secret_bytes)
	id = Principal.SessionId.from_u64(SignInWeb.u64_of(Host.random_bytes!(8))).map_err(|_| Failed)?
	token_hash = Stored.SecretHash.from_bytes(Host.hash!(secret)).map_err(|_| Failed)?
	Ok({
		accounts,
		settings,
		session: { id, token_hash },
		secret,
	})
}

## The first admin the config names, if it names one.
load_first_admin! : {} => Try([Unnamed, Named(Principal.GitHubId)], [Failed])
load_first_admin! = |{}| {
	admin = Host.read_config!(FirstAdmin)
	if admin == [] {
		Ok(Unnamed)
	} else {
		Stored.id(
			admin,
			{ name: "bootstrap_admin", make: Principal.GitHubId.from_u64 },
		).map_ok(|id| Named(id)).map_err(|_| Failed)
	}
}

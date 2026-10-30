## **WHO IS ASKING: A SESSION'S COOKIE OR AN API KEY, NEVER BOTH.** A
## browser comes with its session cookie (SignIn.load_cookie_session!); an agent
## with `Authorization: Bearer <secret>`, the secret a mint showed once,
## its hash looked up in the store (Store.load_key!) and the key loaded through
## ConvKey. A request with both is refused (a 400): which one counts is
## never guessed. Every decision is the core's: a session is admitted by
## Access.Viewer.from_session, a key stands by Access.Viewer.from_key, and
## a grant asks ApiKey (Agents.roc). Here are the facts asked of the host
## and the answers that end a request before its route's work.
##
## **A KEY REFUSED IN USE IS AUDITED** (`audit_use!`): revoked, expired or
## its principal gone, here; outside its scope, by the route that found it
## so (Conversations). An unknown key names no principal, so it is a 401
## and nothing more.
import pf.Chat
import pf.Host
import Access
import ApiKey
import AuditCodec
import ConvAccess
import ConvKey
import Principal
import Session
import SignIn
import SignInWeb
import Store
import Stored
import Wire

Credentials := [].{

	## **THE CREDENTIAL A REQUEST CAME WITH**, as stored: none, a browser's
	## session (not yet admitted), or a key (not yet standing).
	Credential : [
		Nobody,
		Session(Session),
		Key(ConvKey.Key),
	]

	## What a key was used for, as its audit line says it: listing the
	## viewer's conversations, starting one, reading one or posting to one.
	Use : [
		ListConversations,
		Start,
		Read(ConvAccess.ConvId),
		Post(ConvAccess.ConvId),
	]

	## **WHAT A ROUTE ON A CONVERSATION DECIDES ON**: the viewer, the
	## accounts and the time it was minted at, and the key, when a key
	## minted it (for the audit of a use outside its scope).
	Asked : {
		viewer : Access.Viewer(ConvAccess.ConvId),
		accounts : List(Principal),
		now : I64,
		key : [NoKey, Key(ConvKey.Key)],
	}

	## **THE CREDENTIAL, OR THE ANSWER THAT ENDS THE REQUEST**: both sent,
	## a 400; a Bearer header that names no key we hold, a 401.
	load_credential! : {} => Try(Credentials.Credential, Chat.Answer)
	load_credential! = |{}| {
		authorization = Host.read_header!(Str.to_utf8("authorization"))
		cookie = SignInWeb.cookie(Host.read_header!(Str.to_utf8("cookie")), "session")
		match (authorization, cookie) {
			([], _) =>
				match SignIn.load_cookie_session!({}) {
					Err(Failed) => Err(Chat.failed)
					Ok(NoSession) => Ok(Nobody)
					Ok(Found(session)) => Ok(Session(session))
				}
			(_, Sent(_)) => Err(both_sent)
			(values, Unsent) =>
				match Credentials.bearer_secret(values) {
					Err(NotABearer) => Err(no_such_key)
					Ok(secret) =>
						match Stored.SecretHash.from_bytes(Host.hash!(secret)) {
							Err(NotAHash) => Err(Chat.failed)
							Ok(hash) =>
								match Store.load_key!(hash) {
									Err(Failed) => Err(Chat.failed)
									Err(Missing) | Err(Malformed) => Err(no_such_key)
									Ok(entry) => Ok(Key(entry.key))
								}
						}
				}
		}
	}

	## **THE VIEWER**: nobody, a session admitted now (its `last seen`
	## written when stale; one not admitted is signed out), or a key
	## standing now (one that does not stand is audited, and a 401).
	load_viewer! : Credentials.Use => Try(Credentials.Asked, Chat.Answer)
	load_viewer! = |use| {
		credential = load_credential!({})?
		now = Host.read_time!({})
		accounts = Store.load_accounts!({}).map_err(|_| Chat.failed)?
		signed_out = Ok({
			viewer: Access.Viewer.signed_out({}),
			accounts,
			now,
			key: NoKey,
		})
		match credential {
			Nobody => signed_out
			Session(session) =>
				match Access.Viewer.from_session(session, { accounts, now }) {
					Err(_) => signed_out
					Ok({ viewer, write: Unchanged }) => Ok({
						viewer,
						accounts,
						now,
						key: NoKey,
					})
					Ok({ viewer, write: Touched(s) }) =>
						match Store.save_session!(s.fields()) {
							Written => Ok({
								viewer,
								accounts,
								now,
								key: NoKey,
							})
							Failed => Err(Chat.failed)
						}
				}
			Key(key) =>
				match Access.Viewer.from_key(key, { accounts, now }) {
					Ok(viewer) => Ok({
						viewer,
						accounts,
						now,
						key: Key(key),
					})
					Err(why) => {
						audit_use!(
							key,
							{
								use,
								refusal: why,
								now,
							},
						)
						Err(Wire.refused(401, "key refused"))
					}
				}
		}
	}

	## **A KEY REFUSED IN USE, AUDITED**: who it acts as, its public id,
	## what it was used for, and why. Never its secret or its hash.
	audit_use! : ConvKey.Key,
	{
		use : Credentials.Use,
		refusal : ApiKey.Refusal,
		now : I64,
	} => {}
	audit_use! = |
		key,
		{
			use,
			refusal,
			now,
		},
	| {
		action =
			match use {
				ListConversations => ListConversations
				Start => Start
				Read(id) => Read(id.to_u64())
				Post(id) => Post(id.to_u64())
			}
		match AuditCodec.Entry.of_key(
			Use({
				at: now,
				who: key.acts_as(),
				key: key.id(),
				action,
				refusal,
			}),
		) {
			Ok(entry) => Store.append_audit!(entry)
			Err(ClockOutOfRange) => {}
		}
	}

	## **A BEARER HEADER'S SECRET**: exactly one `authorization` header,
	## `Bearer ` and the secret in lower-case hex, as a mint shows it.
	bearer_secret : List(List(U8)) -> Try(List(U8), [NotABearer])
	bearer_secret = |values|
		match values {
			[only] =>
				if List.starts_with(only, bearer_prefix) {
					SignInWeb.unhex(
						List.drop_first(
							only,
							List.len(bearer_prefix),
						),
					).map_err(|_| NotABearer)
				} else {
					Err(NotABearer)
				}
			_ => Err(NotABearer)
		}
}

bearer_prefix : List(U8)
bearer_prefix = Str.to_utf8("Bearer ")

both_sent : Chat.Answer
both_sent = Wire.refused(400, "send a session cookie or a key, not both")

no_such_key : Chat.Answer
no_such_key = Wire.refused(401, "no such key")

expect Credentials.bearer_secret([Str.to_utf8("Bearer 0aff")]) == Ok([0x0A, 0xFF])
expect Credentials.bearer_secret([Str.to_utf8("bearer 0aff")]) == Err(NotABearer)
expect Credentials.bearer_secret([Str.to_utf8("Bearer 0xff")]) == Err(NotABearer)
expect Credentials.bearer_secret([
	Str.to_utf8("Bearer 0aff"),
	Str.to_utf8("Bearer 0aff"),
]) == Err(NotABearer)
expect Credentials.bearer_secret([]) == Err(NotABearer)

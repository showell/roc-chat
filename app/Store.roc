## **THE STORE: EVERY FILE THE APP KEEPS, AND THE ONLY MODULE THAT NAMES
## ONE.** Its functions take and give the core's types (the accounts, the
## settings, a session, an audit entry); the paths, the line formats
## (the core's codecs) and the host's file functions are kept here. A
## handler never names a path, so the store's layout is read in one module,
## and a fork that keeps its records elsewhere (a database) rewrites this
## module and the host's file functions, never a handler.
##
## The layout, under the data root:
##
##     auth/accounts             every account, a line each (AccountCodec)
##     auth/settings             the generation and agent-id counters (`settings_line`)
##     auth/barred               the barred GitHub ids, a line each
##     auth/audit                every refusal and admin act, appended (AuditCodec)
##     auth/sessions/<hash>      a session, named for its secret's hash (SessionCodec)
##     auth/keys/<hash>          an API key, named for its secret's hash (ConvKey)
##     auth/invites/<hash>       an agent's invite, named for its code's hash (InviteCodec)
##     auth/spent/state/<hex>    a state's nonce, spent
##     auth/spent/pending/<hex>  a pending sign-up's nonce, spent
##     chat/conversations/<id>   a conversation, its participants bound (ConvCodec)
##     chat/transcripts/<id>     its messages, a line each, appended (MessageCodec)
##
## **A TRANSCRIPT HOLDS ANY BODY EXACTLY**: a message is one line, its
## markdown escaped (MessageCodec's header says how), so a body of many
## lines, a CR, a `%` or bytes that are not UTF-8 reads back as it was
## posted. Ids run 1, 2, 3 in a transcript, so a message's id is its place.
## A conversation's id is the count of conversations before it, plus one:
## check-then-set, atomic because one handler runs at a time (the turn).
##
## **`Failed` HAS FAILED THE REQUEST** (Host.roc): a caller answers
## anything, and the host answers the 500.
import pf.Host
import AccountCodec
import AuditCodec
import Cast
import ConvAccess
import ConvCodec
import ConvKey
import GitHubSignIn
import InviteCodec
import MessageCodec
import Principal
import SessionCodec
import SignInWeb
import Stored

Store := [].{

	## Which set a spent nonce is kept in: a state's or a pending sign-up's,
	## each its own (GitHubSignIn: the same nonce is spent once in each).
	Spent : [State, Pending]

	## Every account; none before the first.
	load_accounts! : {} => Try(List(Principal), [Failed])
	load_accounts! = |{}| {
		read = Host.read!(accounts_path)
		match read.status {
			Missing => Ok([])
			Failed => Err(Failed)
			Found => AccountCodec.load(read.bytes).map_err(|_| Failed)
		}
	}

	## The settings: `first_admin` (the config's, which the caller reads),
	## the barred ids, the generation counter (1 before the first account)
	## and the agent-id counter. **A STORE FROM BEFORE THE AGENT-ID COUNTER**
	## (no settings, or a line without `agent=`) reads it as
	## GitHubSignIn.agent_id_after the accounts, so today's data stays
	## valid; the next save writes it.
	load_settings! : [Unnamed, Named(Principal.GitHubId)] => Try(GitHubSignIn.Settings, [Failed])
	load_settings! = |first_admin| {
		settings_read = Host.read!(settings_path)
		counters =
			match settings_read.status {
				Missing => Principal.Generation.from_u64(1).map_ok(
					|next| {
						next,
						agent: Unkept,
					},
				).map_err(|_| Failed)
				Failed => Err(Failed)
				Found => settings_counters(settings_read.bytes).map_err(|_| Failed)
			}?
		next_agent_id =
			match counters.agent {
				Kept(id) => Ok(id)
				Unkept => {
					accounts = Store.load_accounts!({})?
					GitHubSignIn.agent_id_after(accounts).map_err(|_| Failed)
				}
			}
		barred_read = Host.read!(barred_path)
		barred =
			match barred_read.status {
				Missing => Ok([])
				Failed => Err(Failed)
				Found => barred_of(barred_read.bytes).map_err(|_| Failed)
			}
		Ok({
			first_admin,
			barred: barred?,
			next_generation: counters.next,
			next_agent_id: next_agent_id?,
		})
	}

	## Whether `nonce` was spent before, in its set.
	load_nonce_use! : Store.Spent, List(U8) => Try([FirstUse, UsedBefore], [Failed])
	load_nonce_use! = |set, nonce| {
		read = Host.read!(spent_path(set, nonce))
		match read.status {
			Missing => Ok(FirstUse)
			Found => Ok(UsedBefore)
			Failed => Err(Failed)
		}
	}

	## `nonce` spent, in its set: a second use is refused from now on.
	spend_nonce! : Store.Spent, List(U8) => [Failed, Written]
	spend_nonce! = |set, nonce| Host.write!(spent_path(set, nonce), [])

	## The session whose secret hashes to `hash`: its stored line, nothing
	## there, or a line that does not read (`Malformed`, which a caller
	## takes for no session).
	load_session! : Stored.SecretHash => Try(
		SessionCodec.Line,
		[
			Missing,
			Malformed,
			Failed,
		],
	)
	load_session! = |hash| {
		read = Host.read!(session_path(hash))
		match read.status {
			Failed => Err(Failed)
			Missing => Err(Missing)
			Found => SessionCodec.decode(read.bytes).map_err(|_| Malformed)
		}
	}

	## A session written: started, or its `last seen` touched.
	save_session! : SessionCodec.Fields => [Failed, Written]
	save_session! = |fields| Host.write!(
		session_path(fields.token_hash),
		SessionCodec.encode(fields),
	)

	## **A SIGN-IN'S RECORDS, IN ORDER**: the settings (the generation
	## counter first, so no generation is ever given twice), the accounts,
	## then the new session. `Failed` when an account will not encode, or a
	## write fails.
	save_signed_in! : {
		accounts : List(Principal),
		settings : GitHubSignIn.Settings,
		session : SessionCodec.Fields,
	} => [Failed, Written]
	save_signed_in! = |
		{
			accounts,
			settings,
			session,
		},
	|
		match Store.save_accounts!({ accounts, settings }) {
			Failed => Failed
			Written => save_session!(session)
		}

	## **THE ACCOUNTS AND THE SETTINGS, IN ORDER**: the settings (the
	## generation counter first, so no generation is ever given twice), then
	## the accounts. What a sign-in and an agent's making write. `Failed`
	## when an account will not encode, or a write fails.
	save_accounts! : {
		accounts : List(Principal),
		settings : GitHubSignIn.Settings,
	} => [Failed, Written]
	save_accounts! = |{ accounts, settings }|
		match List.map_try(accounts, AccountCodec.encode) {
			Err(_) => Failed
			Ok(lines) =>
				match Host.write!(settings_path, settings_line(settings)) {
					Failed => Failed
					Written => Host.write!(accounts_path, List.join(lines))
				}
		}

	## **THE KEY WHOSE SECRET HASHES TO `hash`**: its stored entry, nothing
	## there, or a line that does not read (`Malformed`, which a caller takes
	## for no key).
	load_key! : Stored.SecretHash => Try(
		ConvKey.Entry,
		[
			Missing,
			Malformed,
			Failed,
		],
	)
	load_key! = |hash| {
		read = Host.read!(key_path(hash))
		match read.status {
			Failed => Err(Failed)
			Missing => Err(Missing)
			Found => ConvKey.decode(read.bytes).map_err(|_| Malformed)
		}
	}

	## **EVERY KEY THAT READS**, in no order; a line that does not read is
	## left out (one damaged key fails only itself).
	load_keys! : {} => Try(List(ConvKey.Entry), [Failed])
	load_keys! = |{}| {
		listed = Host.list!(keys_path)
		match listed.status {
			Missing => Ok([])
			Failed => Err(Failed)
			Found => collect_keys!(listed.entries, [])
		}
	}

	## **THE NEXT KEY'S PUBLIC ID**: one past the count of those stored. A
	## key is never removed (a revoked one stays, revoked), so no id is
	## given twice.
	load_next_key_id! : {} => Try(Principal.KeyId, [Failed])
	load_next_key_id! = |{}| {
		listed = Host.list!(keys_path)
		count =
			match listed.status {
				Missing => Ok(0)
				Failed => Err(Failed)
				Found => Ok(List.len(listed.entries))
			}?
		Principal.KeyId.from_u64(count + 1).map_err(|_| Failed)
	}

	## A key written: minted, or revoked.
	save_key! : ConvKey.Entry => [Failed, Written]
	save_key! = |entry| Host.write!(key_path(entry.hash), ConvKey.encode(entry))

	## **THE INVITE WHOSE CODE HASHES TO `hash`**: its record, nothing
	## there, or a line that does not read (`Malformed`, which a caller takes
	## for no invite).
	load_invite! : Stored.SecretHash => Try(
		InviteCodec.Record(ConvAccess.ConvId),
		[
			Missing,
			Malformed,
			Failed,
		],
	)
	load_invite! = |hash| {
		read = Host.read!(invite_path(hash))
		match read.status {
			Failed => Err(Failed)
			Missing => Err(Missing)
			Found => InviteCodec.decode(
				read.bytes,
				ConvAccess.ConvId.from_u64,
			).map_err(|_| Malformed)
		}
	}

	## **EVERY INVITE THAT READS**, in no order; a line that does not read
	## is left out, as a key's is.
	load_invites! : {} => Try(List(InviteCodec.Record(ConvAccess.ConvId)), [Failed])
	load_invites! = |{}| {
		listed = Host.list!(invites_path)
		match listed.status {
			Missing => Ok([])
			Failed => Err(Failed)
			Found => collect_invites!(listed.entries, [])
		}
	}

	## **THE NEXT INVITE'S PUBLIC ID**: one past the count of those stored.
	## An invite is never removed (a spent or revoked one stays), so no id
	## is given twice.
	load_next_invite_id! : {} => Try(InviteCodec.InviteId, [Failed])
	load_next_invite_id! = |{}| {
		listed = Host.list!(invites_path)
		count =
			match listed.status {
				Missing => Ok(0)
				Failed => Err(Failed)
				Found => Ok(List.len(listed.entries))
			}?
		InviteCodec.InviteId.from_u64(count + 1).map_err(|_| Failed)
	}

	## An invite written: made, spent or revoked.
	save_invite! : InviteCodec.Record(ConvAccess.ConvId) => [Failed, Written]
	save_invite! = |record| Host.write!(
		invite_path(record.hash),
		InviteCodec.encode(record, ConvAccess.ConvId.to_u64),
	)

	## **THE NEXT CONVERSATION'S ID**: one past the count of those stored.
	load_next_conversation_id! : {} => Try(ConvAccess.ConvId, [Failed])
	load_next_conversation_id! = |{}| {
		listed = Host.list!(conversations_path)
		count =
			match listed.status {
				Missing => Ok(0)
				Failed => Err(Failed)
				Found => Ok(List.len(listed.entries))
			}?
		ConvAccess.ConvId.from_u64(count + 1).map_err(|_| Failed)
	}

	## The conversation `id`: `Missing` when there is none, and `Failed`
	## when its record will not read (a store the chat did not write).
	load_conversation! : ConvAccess.ConvId => Try(ConvAccess.Conv, [Missing, Failed])
	load_conversation! = |id| {
		read = Host.read!(conversation_path(id))
		match read.status {
			Missing => Err(Missing)
			Failed => Err(Failed)
			Found =>
				match ConvCodec.decode(read.bytes) {
					Ok(line) => Ok(ConvAccess.Conv.load(line))
					Err(_) => Err(Failed)
				}
		}
	}

	## **EVERY CONVERSATION STORED**, oldest first. `Failed` when the folder
	## or a record will not read, or an id up to the count is missing (a
	## store the chat did not write).
	load_conversations! : {} => Try(List(ConvAccess.Conv), [Failed])
	load_conversations! = |{}| {
		listed = Host.list!(conversations_path)
		match listed.status {
			Missing => Ok([])
			Failed => Err(Failed)
			Found => {
				# Ids run 1 to the count, as `load_next_conversation_id!` gives them.
				var $convs = []
				var $n = 1
				while $n <= List.len(listed.entries) {
					id = ConvAccess.ConvId.from_u64($n).map_err(|_| Failed)?
					$convs = List.append($convs, Store.load_conversation!(id).map_err(|_| Failed)?)
					$n = $n + 1
				}
				Ok($convs)
			}
		}
	}

	## A conversation written, as it started at `created`.
	save_conversation! : ConvAccess.Conv, I64 => [Failed, Written]
	save_conversation! = |conv, created| Host.write!(
		conversation_path(conv.id()),
		ConvCodec.encode(conv.fields(created)),
	)

	## **A CONVERSATION'S MESSAGES**, oldest first; none before the first.
	## `Failed` when the transcript will not read whole (a torn append, a
	## line the chat did not write).
	load_transcript! : ConvAccess.ConvId => Try(List(MessageCodec.Fields), [Failed])
	load_transcript! = |id| {
		read = Host.read!(transcript_path(id))
		match read.status {
			Missing => Ok([])
			Failed => Err(Failed)
			Found =>
				match MessageCodec.transcript(read.bytes) {
					Ok(lines) => Ok(List.map(lines, MessageCodec.Line.fields))
					Err(_) => Err(Failed)
				}
		}
	}

	## A message appended to its conversation's transcript, synced. Its id
	## is the caller's, the transcript's count plus one, read in this turn.
	append_message! : ConvAccess.ConvId, MessageCodec.Fields => [Failed, Appended]
	append_message! = |id, message| {
		appended = Host.append!(transcript_path(id), MessageCodec.encode(message))
		match appended.status {
			Appended => Appended
			Failed => Failed
		}
	}

	## An audit entry appended. The audit is a record of what happened, not
	## the request's work, so its failure is the host's to log alone.
	append_audit! : AuditCodec.Entry => {}
	append_audit! = |entry| {
		_ = Host.append!(audit_path, AuditCodec.encode(entry))
		{}
	}
}

accounts_path : List(U8)
accounts_path = Str.to_utf8("auth/accounts")

settings_path : List(U8)
settings_path = Str.to_utf8("auth/settings")

barred_path : List(U8)
barred_path = Str.to_utf8("auth/barred")

audit_path : List(U8)
audit_path = Str.to_utf8("auth/audit")

conversations_path : List(U8)
conversations_path = Str.to_utf8("chat/conversations")

conversation_path : ConvAccess.ConvId -> List(U8)
conversation_path = |id| Str.to_utf8("chat/conversations/${id.to_u64().to_str()}")

transcript_path : ConvAccess.ConvId -> List(U8)
transcript_path = |id| Str.to_utf8("chat/transcripts/${id.to_u64().to_str()}")

## A session's file, named for its secret's hash: found only by one who
## holds the secret, with no compare to time.
session_path : Stored.SecretHash -> List(U8)
session_path = |h| Str.to_utf8("auth/sessions/${Stored.hash_text(h)}")

keys_path : List(U8)
keys_path = Str.to_utf8("auth/keys")

## A key's file, named for its secret's hash, as a session's is.
key_path : Stored.SecretHash -> List(U8)
key_path = |h| Str.to_utf8("auth/keys/${Stored.hash_text(h)}")

invites_path : List(U8)
invites_path = Str.to_utf8("auth/invites")

## An invite's file, named for its code's hash, as a key's is.
invite_path : Stored.SecretHash -> List(U8)
invite_path = |h| Str.to_utf8("auth/invites/${Stored.hash_text(h)}")

## The invites the listed files hold, after `kept`; a file that does not
## read as one is left out.
collect_invites! : List(
	{
		kind : [
			Dir,
			File,
			Other,
		],
		name : List(U8),
	},
),
List(InviteCodec.Record(ConvAccess.ConvId)) => Try(
	List(InviteCodec.Record(ConvAccess.ConvId)),
	[Failed],
)
collect_invites! = |entries, kept|
	match entries {
		[] => Ok(kept)
		[entry, .. as rest] => {
			read = Host.read!(
				List.join([
					invites_path,
					['/'],
					entry.name,
				]),
			)
			match read.status {
				Failed => Err(Failed)
				Missing => collect_invites!(rest, kept)
				Found =>
					match InviteCodec.decode(read.bytes, ConvAccess.ConvId.from_u64) {
						Ok(r) => collect_invites!(rest, List.append(kept, r))
						Err(_) => collect_invites!(rest, kept)
					}
			}
		}
	}

## The keys the listed files hold, after `kept`; a file that does not read
## as a key is left out.
collect_keys! : List(
	{
		kind : [
			Dir,
			File,
			Other,
		],
		name : List(U8),
	},
),
List(ConvKey.Entry) => Try(List(ConvKey.Entry), [Failed])
collect_keys! = |entries, kept|
	match entries {
		[] => Ok(kept)
		[entry, .. as rest] => {
			read = Host.read!(
				List.join([
					keys_path,
					['/'],
					entry.name,
				]),
			)
			match read.status {
				Failed => Err(Failed)
				Missing => collect_keys!(rest, kept)
				Found =>
					match ConvKey.decode(read.bytes) {
						Ok(e) => collect_keys!(rest, List.append(kept, e))
						Err(_) => collect_keys!(rest, kept)
					}
			}
		}
	}

spent_path : Store.Spent, List(U8) -> List(U8)
spent_path = |set, nonce| {
	kind =
		match set {
			State => "state"
			Pending => "pending"
		}
	List.concat(Str.to_utf8("auth/spent/${kind}/"), SignInWeb.hex(nonce))
}

expect spent_path(State, [0xAB]) == Str.to_utf8("auth/spent/state/ab")
expect spent_path(Pending, [0x01]) == Str.to_utf8("auth/spent/pending/01")

## **THE SETTINGS' RECORD**: the generation the next account is given,
## and the id the next agent or bot is given.
##
##     settings v1 next=3 agent=8
settings_line : GitHubSignIn.Settings -> List(U8)
settings_line = |settings| Stored.line(
	"settings",
	[
		("next", settings.next_generation.to_u64().to_str()),
		("agent", settings.next_agent_id.to_u64().to_str()),
	],
)

## The counters the settings' record holds; a line from before the agent-id
## counter, `settings v1 next=3`, holds none (`Unkept`), the one field that
## may be missing, and only at the end.
settings_counters : List(U8) -> Try(
	{ next : Principal.Generation, agent : [Kept(Principal.AgentId), Unkept] },
	Stored.Problem,
)
settings_counters = |raw| {
	fields = Stored.Reader.open(raw, "settings")?
	next_field = fields.field("next")?
	next = Stored.id(next_field.value, { name: "next", make: Principal.Generation.from_u64 })?
	match next_field.rest.close() {
		Ok({}) => Ok({ next, agent: Unkept })
		Err(_) => {
			agent_field = next_field.rest.field("agent")?
			agent = Stored.id(
				agent_field.value,
				{ name: "agent", make: Principal.AgentId.from_u64 },
			)?
			agent_field.rest.close()?
			Ok({ next, agent: Kept(agent) })
		}
	}
}

## **THE BARRED IDS**, one line each:
##
##     barred v1 github=583231
barred_line : Principal.GitHubId -> List(U8)
barred_line = |id| Stored.line("barred", [("github", id.to_u64().to_str())])

## The barred ids a store of their lines holds.
barred_of : List(U8) -> Try(List(Principal.GitHubId), Stored.Problem)
barred_of = |raw|
	List.map_try(
		List.drop_last(List.split_on(raw, '\n'), 1),
		|line| {
			fields = Stored.Reader.open(List.append(line, '\n'), "barred")?
			github_field = fields.field("github")?
			github = Stored.id(
				github_field.value,
				{ name: "github", make: Principal.GitHubId.from_u64 },
			)?
			github_field.rest.close()?
			Ok(github)
		},
	)
# The settings' record and the barred ids, round trips and refusals.
expect settings_counters(
	settings_line({
		first_admin: Unnamed,
		barred: [],
		next_generation: Cast.gen(3),
		next_agent_id: Cast.aid(8),
	}),
) == Ok({ next: Cast.gen(3), agent: Kept(Cast.aid(8)) })
expect settings_line({
	first_admin: Unnamed,
	barred: [],
	next_generation: Cast.gen(3),
	next_agent_id: Cast.aid(8),
}) == Str.to_utf8("settings v1 next=3 agent=8\n")
expect settings_counters(Str.to_utf8("settings v1 next=0\n")) == Err(BadValue("next"))
# A line from before the agent-id counter reads, holding none; a damaged
# counter is refused, never read as missing.
expect settings_counters(Str.to_utf8("settings v1 next=3\n")) == Ok({
	next: Cast.gen(3),
	agent: Unkept,
})
expect settings_counters(Str.to_utf8("settings v1 next=3 agent=0\n")) == Err(BadValue("agent"))
expect settings_counters(Str.to_utf8("settings v1 next=3 agents=4\n")) == Err(MissingField("agent"))
expect settings_counters(Str.to_utf8("settings v1 next=3 agent=4 x=1\n")) == Err(Trailing)

barred_ids : List(Principal.GitHubId)
barred_ids = [Cast.gid(7), Cast.gid(583231)]

expect barred_of(List.join_map(barred_ids, barred_line)) == Ok(barred_ids)
expect barred_of([]) == Ok([])
expect barred_of(Str.to_utf8("barred v1 github=x\n")) == Err(BadNumber("github"))

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
##     chat/tallies/<id>         its transcript's messages and bytes (`load_tally!`)
##     chat/offsets/<id>         where each of its messages starts, a record each (`load_span!`)
##     chat/by-human/<github id> the conversations a human is in, theirs or their agents', by id
##     chat/started-by/<github id> the conversations a human has started, by id
##     chat/indexed              how many conversations those two index
##     auth/keys-by-human/<github id>    a human's keys and their agents', by hash
##     auth/keys-indexed                 how many keys that indexes
##     auth/invites-by-human/<github id> a human's invites, by hash
##     auth/invites-indexed              how many invites that indexes
##
## **WHAT ONE HUMAN HAS, BY AN INDEX**: a file a
## human, one record a line, appended as each thing of theirs is made, so a
## listing reads that file and what it names, never everyone's, and a cap
## counts its records by the file's size. Each index's mark says how many
## things it covers in all; a mark that is not the count stored (missing:
## a store from before the index; short: a stop between a write and its
## record) has the index rebuilt from the full scan, once, as a tally is
## counted again.
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
import Accounts
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
	## Accounts.agent_id_after the accounts, so today's data stays
	## valid; the next save writes it.
	load_settings! : [Unnamed, Named(Principal.GitHubId)] => Try(Accounts.Settings, [Failed])
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
					Accounts.agent_id_after(accounts).map_err(|_| Failed)
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

	## A session ended: its record removed (a logout).
	remove_session! : Stored.SecretHash => [Failed, Removed]
	remove_session! = |hash| Host.remove!(session_path(hash))

	## **A SIGN-IN'S RECORDS, IN ORDER**: the settings (the generation
	## counter first, so no generation is ever given twice), the accounts,
	## then the new session. `Failed` when an account will not encode, or a
	## write fails.
	save_signed_in! : {
		accounts : List(Principal),
		settings : Accounts.Settings,
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
		settings : Accounts.Settings,
	} => [Failed, Written]
	save_accounts! = |{ accounts, settings }|
		match accounts.map_try(AccountCodec.encode) {
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
		Principal.KeyId.from_u64(load_one_past_count!(keys_path)?).map_err(|_| Failed)
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
		InviteCodec.InviteId.from_u64(load_one_past_count!(invites_path)?).map_err(|_| Failed)
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
		ConvAccess.ConvId.from_u64(load_one_past_count!(conversations_path)?).map_err(|_| Failed)
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
				while $n <= listed.entries.len() {
					id = ConvAccess.ConvId.from_u64($n).map_err(|_| Failed)?
					$convs = $convs.append(Store.load_conversation!(id).map_err(|_| Failed)?)
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
					Ok(lines) => Ok(lines.map(MessageCodec.Line.fields))
					Err(_) => Err(Failed)
				}
		}
	}

	## **A TRANSCRIPT'S TALLY: ITS MESSAGES AND ITS BYTES**,
	## from the sidecar written with each append, so a post
	## never reads the transcript to learn its id or its size. A sidecar
	## that is missing (a transcript from before it) or that disagrees with
	## the transcript's size (a stop between an append and its tally) is
	## counted once from the whole transcript; the next append writes it.
	load_tally! : ConvAccess.ConvId => Try(Store.Tally, [Failed])
	load_tally! = |id| {
		stat = Host.read_stat!(transcript_path(id))
		match stat.status {
			Failed => Err(Failed)
			Missing => Ok({ messages: 0, bytes: 0 })
			Found => {
				read = Host.read!(tally_path(id))
				kept =
					match read.status {
						Failed => Err(Failed)
						Missing => Ok(Stale)
						Found =>
							match tally_of(read.bytes) {
								Ok(t) if t.bytes == stat.size => Ok(Kept(t))
								_ => Ok(Stale)
							}
					}?
				match kept {
					Kept(t) => Ok(t)
					Stale => {
						messages = Store.load_transcript!(id)?
						Ok({ messages: messages.len(), bytes: stat.size })
					}
				}
			}
		}
	}

	## What a transcript holds, told: its messages and its bytes.
	Tally : { messages : U64, bytes : U64 }

	## **A RUN OF A CONVERSATION'S MESSAGES, `first` TO `last`**, read from
	## where `first` starts (its offsets file), never the transcript whole;
	## none when `first` is past `last`. `tally` is the transcript's now
	## (`load_tally!`, in this turn). An offsets file that does not hold one
	## record a message (a transcript from before it, or a stop between an
	## append and its record) is passed by: the transcript is read whole,
	## and the next append writes the file again.
	load_span! : ConvAccess.ConvId,
	Store.Tally,
	{ first : U64, last : U64 } => Try(
		List(MessageCodec.Fields),
		[Failed],
	)
	load_span! = |
		id,
		tally,
		{ first, last },
	|
		if first == 0 or last > tally.messages {
			crash "Store.load_span!: a span outside its transcript"
		} else if first > last {
			Ok([])
		} else {
			match check_offsets!(id, tally) {
				Err(Failed) => Err(Failed)
				Ok(Bool.False) => {
					all = Store.load_transcript!(id)?
					Ok(all.sublist({ start: first - 1, len: last - first + 1 }))
				}
				Ok(Bool.True) => {
					# `first`'s record, and the next one's after `last`'s, which
					# the transcript's end stands in for after its last message.
					records = Host.read_at!(
						offsets_path(id),
						(first - 1) * offset_width,
						(last - first + 2) * offset_width,
					)
					starts =
						match records.status {
							Found => records.bytes.chunks_of(offset_width).map_try(offset_of).map_err(|_| Failed)?
							Missing | Failed => return Err(Failed)
						}
					ends = if (last == tally.messages) List.append(starts, tally.bytes) else starts
					match (ends.first(), ends.get(last - first + 1)) {
						(Ok(from), Ok(to)) if from < to and to <= tally.bytes => {
							text = Host.read_at!(
								transcript_path(id),
								from,
								to - from,
							)
							if text.status != Found or text.bytes.len() != to - from {
								Err(Failed)
							} else {
								match MessageCodec.span(text.bytes, first) {
									Ok(lines) if lines.len() == last - first + 1 => Ok(lines.map(MessageCodec.Line.fields))
									_ => Err(Failed)
								}
							}
						}
						_ => Err(Failed)
					}
				}
			}
		}

	## **A MESSAGE APPENDED TO ITS CONVERSATION'S TRANSCRIPT, SYNCED, THEN
	## ITS TALLY**: `tally` is the transcript's before it (`load_tally!`, in
	## this turn), and the message's id the caller's, its count plus one.
	##
	## **THEN ITS OFFSET**, where it starts (the transcript's size before
	## it), appended to the offsets file; a file that does not hold one
	## record a message before it is written again whole, from the
	## transcript.
	append_message! : {
		id : ConvAccess.ConvId,
		tally : Store.Tally,
		message : MessageCodec.Fields,
	} => [Failed, Appended]
	append_message! = |
		{
			id,
			tally,
			message,
		},
	|
		match check_offsets!(id, tally) {
			Err(Failed) => Failed
			Ok(kept) => {
				appended = Host.append!(transcript_path(id), MessageCodec.encode(message))
				match appended.status {
					Failed => Failed
					Appended => {
						offsets =
							if kept {
								Host.append!(offsets_path(id), offset_record(tally.bytes)).status
							} else {
								save_offsets!(id)
							}
						match offsets {
							Failed => Failed
							Appended =>
								match Host.write!(
									tally_path(id),
									tally_line({
										messages: tally.messages + 1,
										bytes: appended.size,
									}),
								) {
									Failed => Failed
									Written => Appended
								}
						}
					}
				}
			}
		}

	## **THE CONVERSATIONS OF `human`'S**: each one a participant of answers
	## to them (the human, or an agent or a bot they own), oldest first, by
	## their index.
	load_conversations_of! : Principal.GitHubId,
	List(Principal) => Try(
		List(ConvAccess.Conv),
		[Failed],
	)
	load_conversations_of! = |human, accounts| {
		_ = index_conversations!(accounts)?
		records = load_records!(index_path(by_human_folder, human), offset_width)?
		load_conversations_at!(records, [])
	}

	## How many conversations `human` has started, by session or by their
	## agents' keys.
	load_started_count! : Principal.GitHubId, List(Principal) => Try(U64, [Failed])
	load_started_count! = |human, accounts| {
		_ = index_conversations!(accounts)?
		load_record_count!(index_path(started_folder, human), offset_width)
	}

	## **A NEW CONVERSATION WRITTEN, THEN INDEXED**: its record, then its id
	## in its starter's `started-by` index and each involved human's
	## `by-human` index, then the mark.
	save_new_conversation! : {
		conv : ConvAccess.Conv,
		created : I64,
		accounts : List(Principal),
	} => [Failed, Written]
	save_new_conversation! = |
		{
			conv,
			created,
			accounts,
		},
	|
		match index_conversations!(accounts) {
			Err(Failed) => Failed
			Ok(count) =>
				match Store.save_conversation!(conv, created) {
					Failed => Failed
					Written => {
						record = offset_record(conv.id().to_u64())
						started =
							match starter_of(conv, accounts) {
								Ok(h) => [index_path(started_folder, h)]
								Err(Unresolved) => []
							}
						involved = humans_of(conv, accounts).map(|h| index_path(by_human_folder, h))
						match append_each!(started.concat(involved), record) {
							Failed => Failed
							Appended => Host.write!(conversations_mark, mark_line(count + 1))
						}
					}
				}
		}

	## **THE KEYS OF `human`'S**, theirs and their agents', by their index;
	## one whose file is gone or does not read is left out, as in `load_keys!`.
	load_keys_of! : Principal.GitHubId, List(Principal) => Try(List(ConvKey.Entry), [Failed])
	load_keys_of! = |human, accounts| {
		_ = index_keys!(accounts)?
		records = load_records!(index_path(keys_folder, human), hash_width)?
		load_keys_at!(records, [])
	}

	## How many keys `human` has minted, for themselves and their agents,
	## revoked ones counted.
	load_key_count! : Principal.GitHubId, List(Principal) => Try(U64, [Failed])
	load_key_count! = |human, accounts| {
		_ = index_keys!(accounts)?
		load_record_count!(index_path(keys_folder, human), hash_width)
	}

	## **A NEW KEY WRITTEN, THEN INDEXED** under the human the principal it
	## acts as answers to (none, for one the accounts do not hold, as the
	## rebuild leaves it out too).
	save_new_key! : ConvKey.Entry, List(Principal) => [Failed, Written]
	save_new_key! = |entry, accounts|
		match index_keys!(accounts) {
			Err(Failed) => Failed
			Ok(count) =>
				match Store.save_key!(entry) {
					Failed => Failed
					Written => append_indexed!(
						keys_folder,
						keys_mark,
						{
							answerer: answerer_of(accounts, entry.key.acts_as()),
							record: hash_record(entry.hash),
							count,
						},
					)
				}
		}

	## **THE INVITES OF `human`'S**, by their index; one whose file is gone
	## or does not read is left out, as in `load_invites!`.
	load_invites_of! : Principal.GitHubId,
	List(Principal) => Try(
		List(InviteCodec.Record(ConvAccess.ConvId)),
		[Failed],
	)
	load_invites_of! = |human, accounts| {
		_ = index_invites!(accounts)?
		records = load_records!(index_path(invites_folder, human), hash_width)?
		load_invites_at!(records, [])
	}

	## How many invites `human` has made, spent and revoked ones counted.
	load_invite_count! : Principal.GitHubId, List(Principal) => Try(U64, [Failed])
	load_invite_count! = |human, accounts| {
		_ = index_invites!(accounts)?
		load_record_count!(index_path(invites_folder, human), hash_width)
	}

	## **A NEW INVITE WRITTEN, THEN INDEXED** under the human its agent
	## answers to, as a key is.
	save_new_invite! : InviteCodec.Record(ConvAccess.ConvId), List(Principal) => [Failed, Written]
	save_new_invite! = |invite, accounts|
		match index_invites!(accounts) {
			Err(Failed) => Failed
			Ok(count) =>
				match Store.save_invite!(invite) {
					Failed => Failed
					Written => append_indexed!(
						invites_folder,
						invites_mark,
						{
							answerer: answerer_of(accounts, invite.bound.id),
							record: hash_record(invite.hash),
							count,
						},
					)
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
accounts_path = "auth/accounts".to_utf8()

settings_path : List(U8)
settings_path = "auth/settings".to_utf8()

barred_path : List(U8)
barred_path = "auth/barred".to_utf8()

audit_path : List(U8)
audit_path = "auth/audit".to_utf8()

conversations_path : List(U8)
conversations_path = "chat/conversations".to_utf8()

conversation_path : ConvAccess.ConvId -> List(U8)
conversation_path = |id| "chat/conversations/${id.to_u64().to_str()}".to_utf8()

transcript_path : ConvAccess.ConvId -> List(U8)
transcript_path = |id| "chat/transcripts/${id.to_u64().to_str()}".to_utf8()

offsets_path : ConvAccess.ConvId -> List(U8)
offsets_path = |id| "chat/offsets/${id.to_u64().to_str()}".to_utf8()

## Whether the offsets file holds one record for each message `tally`
## counts.
check_offsets! : ConvAccess.ConvId, Store.Tally => Try(Bool, [Failed])
check_offsets! = |id, tally| {
	stat = Host.read_stat!(offsets_path(id))
	match stat.status {
		Failed => Err(Failed)
		Missing => Ok(tally.messages == 0)
		Found => Ok(stat.size == tally.messages * offset_width)
	}
}

## The offsets file written whole, from the transcript as it is.
save_offsets! : ConvAccess.ConvId => [Appended, Failed]
save_offsets! = |id| {
	read = Host.read!(transcript_path(id))
	match read.status {
		Missing | Failed => Failed
		Found =>
			match Host.write!(
				offsets_path(id),
				List.join_map(line_starts(read.bytes), offset_record),
			) {
				Failed => Failed
				Written => Appended
			}
	}
}

## **AN OFFSET'S RECORD**: ten digits and a newline, so message `n`'s is
## at `(n - 1) * offset_width`. Ten digits hold any offset of a transcript
## (Limits.transcript_bytes_most).
offset_width : U64
offset_width = 11

offset_record : U64 -> List(U8)
offset_record = |at| {
	digits = at.to_str().to_utf8()
	if digits.len() >= offset_width {
		crash "Store.offset_record: an offset past ten digits"
	} else {
		List.join([
			List.repeat('0', offset_width - 1 - List.len(digits)),
			digits,
			['\n'],
		])
	}
}

offset_of : List(U8) -> Try(U64, [Malformed])
offset_of = |record|
	if record.len() != offset_width or record.last() != Ok('\n') {
		Err(Malformed)
	} else {
		record.drop_last(1).fold_try(
			0,
			|n, c| if (c >= '0' and c <= '9') Ok(n * 10 + (c - '0').to_u64()) else Err(Malformed),
		)
	}

## Where each line of a transcript starts.
line_starts : List(U8) -> List(U64)
line_starts = |raw|
	raw.fold(
		{ at: 0, starts: if (raw.is_empty()) [] else [0] },
		|state, c| {
			at = state.at + 1
			if c == '\n' and at < raw.len() {
				{ at, starts: state.starts.append(at) }
			} else {
				{ at, starts: state.starts }
			}
		},
	).starts

## ── the indexes by human ──

by_human_folder : Str
by_human_folder = "chat/by-human"

started_folder : Str
started_folder = "chat/started-by"

conversations_mark : List(U8)
conversations_mark = "chat/indexed".to_utf8()

keys_folder : Str
keys_folder = "auth/keys-by-human"

keys_mark : List(U8)
keys_mark = "auth/keys-indexed".to_utf8()

invites_folder : Str
invites_folder = "auth/invites-by-human"

invites_mark : List(U8)
invites_mark = "auth/invites-indexed".to_utf8()

## A human's file in an index's folder.
index_path : Str, Principal.GitHubId -> List(U8)
index_path = |folder, human| "${folder}/${human.to_u64().to_str()}".to_utf8()

## A secret's hash as an index's record: its hex, and a newline.
hash_width : U64
hash_width = 65

hash_record : Stored.SecretHash -> List(U8)
hash_record = |h| Str.to_utf8("${Stored.hash_text(h)}\n")

mark_line : U64 -> List(U8)
mark_line = |n| "${n.to_str()}\n".to_utf8()

## **IS THE INDEX UP TO DATE?** Its mark against `count`, the things
## stored: one missing is right only when none are.
check_mark! : List(U8), U64 => Try(Bool, [Failed])
check_mark! = |mark, count| {
	read = Host.read!(mark)
	match read.status {
		Failed => Err(Failed)
		Missing => Ok(count == 0)
		Found =>
			match read.bytes.split_last('\n') {
				Ok({ before, after: [] }) => Ok(Stored.count(before, "mark") == Ok(count))
				_ => Ok(Bool.False)
			}
	}
}

## **THE CONVERSATIONS' INDEXES, UP TO DATE**: their count, the indexes
## rebuilt from every conversation first when their mark is not it.
index_conversations! : List(Principal) => Try(U64, [Failed])
index_conversations! = |accounts| {
	count = load_one_past_count!(conversations_path)? - 1
	if check_mark!(conversations_mark, count)? {
		Ok(count)
	} else {
		all = Store.load_conversations!({})?
		involved = all.join_map(
			|c| humans_of(c, accounts).map(
				|h| (
					h,
					offset_record(c.id().to_u64()),
				),
			),
		)
		started = all.join_map(
			|c|
				match starter_of(c, accounts) {
					Ok(h) => [(h, offset_record(c.id().to_u64()))]
					Err(Unresolved) => []
				},
		)
		rewrite_index!(by_human_folder, grouped(involved))?
		rewrite_index!(started_folder, grouped(started))?
		match Host.write!(conversations_mark, mark_line(count)) {
			Failed => Err(Failed)
			Written => Ok(count)
		}
	}
}

## The keys' index, up to date, as the conversations' are.
index_keys! : List(Principal) => Try(U64, [Failed])
index_keys! = |accounts| {
	count = load_one_past_count!(keys_path)? - 1
	if check_mark!(keys_mark, count)? {
		Ok(count)
	} else {
		all = Store.load_keys!({})?
		owned = all.join_map(
			|e|
				match answerer_of(accounts, e.key.acts_as()) {
					Ok(h) => [(h, hash_record(e.hash))]
					Err(Unresolved) => []
				},
		)
		rewrite_index!(keys_folder, grouped(owned))?
		match Host.write!(keys_mark, mark_line(count)) {
			Failed => Err(Failed)
			Written => Ok(count)
		}
	}
}

## The invites' index, up to date, as the conversations' are.
index_invites! : List(Principal) => Try(U64, [Failed])
index_invites! = |accounts| {
	count = load_one_past_count!(invites_path)? - 1
	if check_mark!(invites_mark, count)? {
		Ok(count)
	} else {
		all = Store.load_invites!({})?
		owned = all.join_map(
			|i|
				match answerer_of(accounts, i.bound.id) {
					Ok(h) => [(h, hash_record(i.hash))]
					Err(Unresolved) => []
				},
		)
		rewrite_index!(invites_folder, grouped(owned))?
		match Host.write!(invites_mark, mark_line(count)) {
			Failed => Err(Failed)
			Written => Ok(count)
		}
	}
}

## The human a principal answers to, as the accounts say now.
answerer_of : List(Principal), Principal.Id -> Try(Principal.GitHubId, [Unresolved])
answerer_of = |accounts, id|
	match Principal.find(accounts, id) {
		Ok(p) => Ok(p.answers_to())
		Err(_) => Err(Unresolved)
	}

## **ONE NEW THING'S RECORD, THEN THE MARK**: `record` appended to its
## human's file (none for nobody), and the mark one past `count`.
append_indexed! : Str,
List(U8),
{
	answerer : Try(Principal.GitHubId, [Unresolved]),
	record : List(U8),
	count : U64,
} => [Failed, Written]
append_indexed! = |
	folder,
	mark,
	{
		answerer,
		record,
		count,
	},
| {
	appended =
		match answerer {
			Ok(h) => Host.append!(index_path(folder, h), record).status
			Err(Unresolved) => Appended
		}
	match appended {
		Failed => Failed
		Appended => Host.write!(mark, mark_line(count + 1))
	}
}

## **THE HUMANS A CONVERSATION'S PARTICIPANTS ANSWER TO**, each once; one
## the accounts no longer hold answers for nobody.
humans_of : ConvAccess.Conv, List(Principal) -> List(Principal.GitHubId)
humans_of = |conv, accounts|
	List.fold(
		conv.participants(),
		[],
		|humans, b|
			match Principal.find(accounts, b.id) {
				Ok(p) if !humans.contains(p.answers_to()) => humans.append(p.answers_to())
				_ => humans
			},
	)

## The human who started it: its first participant's (ConvAccess.Conv.start
## puts the starter first).
starter_of : ConvAccess.Conv, List(Principal) -> Try(Principal.GitHubId, [Unresolved])
starter_of = |conv, accounts|
	match conv.participants().first() {
		Ok(b) =>
			match Principal.find(accounts, b.id) {
				Ok(p) => Ok(p.answers_to())
				Err(_) => Err(Unresolved)
			}
		Err(_) => Err(Unresolved)
	}

## Records gathered by human, each human's in the order given.
grouped : List((Principal.GitHubId, List(U8))) -> List(
	{
		human : Principal.GitHubId,
		records : List(U8),
	},
)
grouped = |pairs|
	pairs.fold(
		[],
		|groups, (human, record)|
			if groups.any(|g| g.human == human) {
				groups.map(
					|g| if (g.human == human) {
						human,
						records: g.records.concat(record),
					} else g,
				)
			} else {
				groups.append({ human, records: record })
			},
	)

## **AN INDEX WRITTEN WHOLE**: each human's file from `groups`, and any
## other file in its folder removed.
rewrite_index! : Str, List({ human : Principal.GitHubId, records : List(U8) }) => Try({}, [Failed])
rewrite_index! = |folder, groups| {
	listed = Host.list!(Str.to_utf8(folder))
	existing =
		match listed.status {
			Missing => []
			Failed => return Err(Failed)
			Found => listed.entries.map(|e| e.name)
		}
	kept = groups.map(|g| g.human.to_u64().to_str().to_utf8())
	remove_files!(folder, existing.keep_if(|name| !kept.contains(name)))?
	write_index_files!(folder, groups)
}

remove_files! : Str, List(List(U8)) => Try({}, [Failed])
remove_files! = |folder, names|
	match names {
		[] => Ok({})
		[name, .. as rest] =>
			match Host.remove!(
				List.join([
					Str.to_utf8(folder),
					['/'],
					name,
				]),
			) {
				Failed => Err(Failed)
				Removed => remove_files!(folder, rest)
			}
	}

write_index_files! : Str,
List(
	{
		human : Principal.GitHubId,
		records : List(U8),
	},
) => Try({}, [Failed])
write_index_files! = |folder, groups|
	match groups {
		[] => Ok({})
		[g, .. as rest] =>
			match Host.write!(index_path(folder, g.human), g.records) {
				Failed => Err(Failed)
				Written => write_index_files!(folder, rest)
			}
	}

## `record` appended to each index file in `paths`.
append_each! : List(List(U8)), List(U8) => [Appended, Failed]
append_each! = |paths, record|
	match paths {
		[] => Appended
		[path, .. as rest] =>
			match Host.append!(path, record).status {
				Failed => Failed
				Appended => append_each!(rest, record)
			}
	}

## An index file's records, each `width` bytes; none when it is missing.
load_records! : List(U8), U64 => Try(List(List(U8)), [Failed])
load_records! = |path, width| {
	read = Host.read!(path)
	match read.status {
		Missing => Ok([])
		Failed => Err(Failed)
		Found =>
			if read.bytes.len() % width == 0 {
				Ok(read.bytes.chunks_of(width))
			} else {
				Err(Failed)
			}
	}
}

## How many records an index file holds, by its size alone.
load_record_count! : List(U8), U64 => Try(U64, [Failed])
load_record_count! = |path, width| {
	stat = Host.read_stat!(path)
	match stat.status {
		Missing => Ok(0)
		Failed => Err(Failed)
		Found => Ok(stat.size // width)
	}
}

load_conversations_at! : List(List(U8)),
List(ConvAccess.Conv) => Try(
	List(ConvAccess.Conv),
	[Failed],
)
load_conversations_at! = |records, kept|
	match records {
		[] => Ok(kept)
		[record, .. as rest] => {
			id = offset_of(record).map_err(|_| Failed)?
			conv_id = ConvAccess.ConvId.from_u64(id).map_err(|_| Failed)?
			conv = Store.load_conversation!(conv_id).map_err(|_| Failed)?
			load_conversations_at!(rest, kept.append(conv))
		}
	}

load_keys_at! : List(List(U8)), List(ConvKey.Entry) => Try(List(ConvKey.Entry), [Failed])
load_keys_at! = |records, kept|
	match records {
		[] => Ok(kept)
		[record, .. as rest] => {
			hash = Stored.hash(List.drop_last(record, 1), "key").map_err(|_| Failed)?
			match Store.load_key!(hash) {
				Ok(e) => load_keys_at!(rest, kept.append(e))
				Err(Missing) | Err(Malformed) => load_keys_at!(rest, kept)
				Err(Failed) => Err(Failed)
			}
		}
	}

load_invites_at! : List(List(U8)),
List(InviteCodec.Record(ConvAccess.ConvId)) => Try(
	List(InviteCodec.Record(ConvAccess.ConvId)),
	[Failed],
)
load_invites_at! = |records, kept|
	match records {
		[] => Ok(kept)
		[record, .. as rest] => {
			hash = Stored.hash(List.drop_last(record, 1), "invite").map_err(|_| Failed)?
			match Store.load_invite!(hash) {
				Ok(i) => load_invites_at!(rest, kept.append(i))
				Err(Missing) | Err(Malformed) => load_invites_at!(rest, kept)
				Err(Failed) => Err(Failed)
			}
		}
	}

tally_path : ConvAccess.ConvId -> List(U8)
tally_path = |id| "chat/tallies/${id.to_u64().to_str()}".to_utf8()

## A tally's file: `<messages> <bytes>` and a newline.
tally_line : Store.Tally -> List(U8)
tally_line = |t| "${t.messages.to_str()} ${t.bytes.to_str()}\n".to_utf8()

tally_of : List(U8) -> Try(Store.Tally, [Malformed])
tally_of = |bytes|
	match bytes.split_on(' ') {
		[messages, rest] if rest.last() == Ok('\n') =>
			match (
				Stored.count(messages, "messages"),
				Stored.count(List.drop_last(rest, 1), "bytes"),
			) {
				(Ok(m), Ok(b)) => Ok({ messages: m, bytes: b })
				_ => Err(Malformed)
			}
		_ => Err(Malformed)
	}

expect tally_of(tally_line({ messages: 3, bytes: 120 })) == Ok({ messages: 3, bytes: 120 })
expect tally_of("3 120".to_utf8()) == Err(Malformed)
expect tally_of("03 120\n".to_utf8()) == Err(Malformed)

## A session's file, named for its secret's hash: found only by one who
## holds the secret, with no compare to time.
session_path : Stored.SecretHash -> List(U8)
session_path = |h| Str.to_utf8("auth/sessions/${Stored.hash_text(h)}")

keys_path : List(U8)
keys_path = "auth/keys".to_utf8()

## A key's file, named for its secret's hash, as a session's is.
key_path : Stored.SecretHash -> List(U8)
key_path = |h| Str.to_utf8("auth/keys/${Stored.hash_text(h)}")

invites_path : List(U8)
invites_path = "auth/invites".to_utf8()

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
						Ok(r) => collect_invites!(rest, kept.append(r))
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
						Ok(e) => collect_keys!(rest, kept.append(e))
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

expect spent_path(State, [0xAB]) == "auth/spent/state/ab".to_utf8()
expect spent_path(Pending, [0x01]) == "auth/spent/pending/01".to_utf8()

## **THE SETTINGS' RECORD**: the generation the next account is given,
## and the id the next agent or bot is given.
##
##     settings v1 next=3 agent=8
settings_line : Accounts.Settings -> List(U8)
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
	_,
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
barred_of : List(U8) -> Try(List(Principal.GitHubId), _)
barred_of = |raw|
	List.map_try(
		raw.split_on('\n').drop_last(1),
		|line| {
			fields = Stored.Reader.open(line.append('\n'), "barred")?
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
}) == "settings v1 next=3 agent=8\n".to_utf8()
expect settings_counters("settings v1 next=0\n".to_utf8()) == Err(BadValue("next"))
# A line from before the agent-id counter reads, holding none; a damaged
# counter is refused, never read as missing.
expect settings_counters("settings v1 next=3\n".to_utf8()) == Ok({
	next: Cast.gen(3),
	agent: Unkept,
})
expect settings_counters("settings v1 next=3 agent=0\n".to_utf8()) == Err(BadValue("agent"))
expect settings_counters("settings v1 next=3 agents=4\n".to_utf8()) == Err(MissingField("agent"))
expect settings_counters("settings v1 next=3 agent=4 x=1\n".to_utf8()) == Err(Trailing)

barred_ids : List(Principal.GitHubId)
barred_ids = [Cast.gid(7), Cast.gid(583231)]

expect barred_of(barred_ids.join_map(barred_line)) == Ok(barred_ids)
expect barred_of([]) == Ok([])
expect barred_of("barred v1 github=x\n".to_utf8()) == Err(BadNumber("github"))

## **ONE PAST THE COUNT OF A FOLDER'S ENTRIES**: the next id of a record that
## is never removed (a key, an invite, a conversation), so no id is given
## twice; 1 for a folder not made yet.
load_one_past_count! : List(U8) => Try(U64, [Failed])
load_one_past_count! = |folder| {
	listed = Host.list!(folder)
	match listed.status {
		Missing => Ok(1)
		Failed => Err(Failed)
		Found => Ok(listed.entries.len() + 1)
	}
}
expect offset_record(0) == "0000000000\n".to_utf8()
expect offset_record(4_000_000) == "0004000000\n".to_utf8()
expect offset_of(offset_record(123)) == Ok(123)
expect offset_of("000000012\n".to_utf8()) == Err(Malformed)
expect offset_of("00000001x2\n".to_utf8()) == Err(Malformed)
expect line_starts("ab\nc\n\nd\n".to_utf8()) == [
	0,
	3,
	5,
	6,
]
expect line_starts([]) == []
expect grouped([]) == []
expect mark_line(12) == "12\n".to_utf8()

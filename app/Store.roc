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
##     auth/audit                every refusal and admin act, appended (AuditCodec)
##     auth/sessions/<hash>      a session, named for its secret's hash (SessionCodec)
##     auth/keys/<hash>          an API key, named for its secret's hash (ChatKey)
##     auth/invites/<hash>       an agent's invite, named for its code's hash (InviteCodec)
##     auth/human-invites/<hash> a human invite, named for its code's hash (HumanInviteCodec)
##     auth/spent/state/<hex>    a state's nonce, spent
##     auth/spent/pending/<hex>  a pending sign-up's nonce, spent
##     auth/keys-by-human/<github id>    a human's keys and their agents', by hash
##     auth/keys-indexed                 how many keys that indexes
##     auth/invites-by-human/<github id> a human's invites, by hash
##     auth/invites-indexed              how many invites that indexes
##     auth/human-invites-by-human/<id>  the human invites a human made, by hash
##     auth/human-invites-indexed        how many human invites that indexes
##     chat/channels/<channel>/channel   a channel, its members bound (ChannelCodec)
##     chat/dms/<pair>/...               a DM (`7_11`), laid out as a channel is below it (ChannelLayout)
##     chat/channels/<channel>/topics/<topic>/topic       a topic (TopicCodec)
##     chat/channels/<channel>/topics/<topic>/transcript  its messages, a line each, appended (MessageCodec)
##     chat/channels/<channel>/topics/<topic>/tally       its transcript's messages and bytes (`load_tally!`)
##     chat/channels/<channel>/topics/<topic>/offsets     where each of its messages starts, a record each (`load_span!`)
##     chat/channels/<channel>/topics/<topic>/reactions.jsonl  its reactions, a JSON event a line, appended (Reactions)
##     chat/channels/<channel>/topics/<topic>/uploads/<name>  an image uploaded to it, as uploaded (Uploads)
##     chat/upload-bytes/<human id>  the bytes a human has uploaded in all, in decimal (Uploads)
##
## A channel's folder is its name's key, and each topic's its name's key
## in it (ChannelLayout, which names those paths); the functions that keep
## a transcript reach a topic's files through `topic_files`.
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
## A record's id given by a count (a key's, an invite's) is check-then-set,
## atomic because one handler runs at a time (the turn).
##
## **`Failed` HAS FAILED THE REQUEST** (Host.roc): a caller answers
## anything, and the host answers the 500.
import pf.Host
import Accounts
import AccountCodec
import AuditCodec
import Cast
import Channel
import ChannelCodec
import ChannelLayout
import ChannelName
import ChatKey
import Erase
import GitHubSignIn
import HumanInvite
import HumanInviteCodec
import InviteCodec
import MessageCodec
import Principal
import Reactions
import SessionCodec
import SignInWeb
import Stored
import Topic
import TopicCodec
import TopicName
import Uploads

Store := [].{

	## Which set a spent nonce is kept in: a state's or a pending sign-up's,
	## each its own (GitHubSignIn: the same nonce is spent once in each).
	Spent : [State, Pending]

	## **AN UPLOADED IMAGE KEPT**, under its topic, by its fresh name. **ONLY
	## WITH PROOF OF THE READ** (Topic.Readable, which Topic.readable alone
	## makes): no way to a topic's uploads skips the topic's rule.
	save_upload! : Topic.Readable, { name : Str, uploaded : List(U8) } => [Failed, Written]
	save_upload! = |readable, { name, uploaded }| Host.write!(ChannelLayout.upload_path(readable.at(), name), uploaded)

	## An uploaded image's bytes, by its name, with proof of the read.
	load_upload! : Topic.Readable, Str => { bytes : List(U8), status : [Failed, Found, Missing] }
	load_upload! = |readable, name| Host.read!(ChannelLayout.upload_path(readable.at(), name))

	## **WHAT A HUMAN HAS UPLOADED IN ALL**, in bytes: none before their
	## first. A file that does not read back is `Unreadable`, never none, so
	## the allowance is never reset by a write over it.
	load_uploaded! : Principal.HumanId => Try(U64, [Failed, Unreadable])
	load_uploaded! = |human| {
		read = Host.read!(uploaded_path(human))
		match read.status {
			Missing => Ok(0)
			Failed => Err(Failed)
			Found => Uploads.uploaded_from(read.bytes)
		}
	}

	## What a human has uploaded in all, written whole.
	save_uploaded! : Principal.HumanId, U64 => [Failed, Written]
	save_uploaded! = |human, n| Host.write!(uploaded_path(human), Uploads.uploaded_text(n))

	## **A HUMAN ERASED, AS DECIDED** (Erase.plan, which says what goes and
	## why): every DM of theirs removed, folder by folder; their sessions
	## ended; their uploaded bytes' count and the indexes of their keys and invites removed; and their accounts
	## (theirs, and their agents' and bots') written out **LAST**, so a stop
	## part way leaves them erasable again, and a second run finds what the
	## first left (erase_steps!, which says each step).
	erase! : Erase.Plan => [Failed, Erased]
	erase! = |plan|
		match erase_steps!(plan) {
			Ok({}) => Erased
			Err(Failed) => Failed
		}

	## **A TOPIC'S REACTIONS**, oldest first (Reactions.list); none before
	## the first, and whether the file ends mid-line (for
	## `append_reaction!`). A read that failed has failed.
	load_reactions! : Topic.At => Try({ events : List(Reactions.Event), cut : Bool }, [Failed])
	load_reactions! = |at| {
		read = Host.read!(ChannelLayout.reactions_path(at))
		match read.status {
			Missing => Ok({ events: [], cut: Bool.False })
			Failed => Err(Failed)
			Found => Ok({
				events: Reactions.list(read.bytes),
				cut: !read.bytes.is_empty() and read.bytes.last() != Ok('\n'),
			})
		}
	}

	## **ONE REACTION APPENDED** to a topic's file. **A TORN LINE STAYS ITS OWN
	## LINE** (the old `appendReaction`): after an append a stop cut short
	## (`cut`), a line's end first, so the event is never glued to it and
	## lost with it.
	append_reaction! : Topic.At, { cut : Bool, event : Reactions.Event } => [Failed, Appended]
	append_reaction! = |at, { cut, event }| {
		lead = if (cut) ['\n'] else []
		match Host.append!(
			ChannelLayout.reactions_path(at),
			lead.concat(Reactions.encode(event)),
		).status {
			Appended => Appended
			Failed => Failed
		}
	}

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
	## and the three counters (the generation, the
	## agent id and the human id, each 1 before its first account). The
	## store starts empty: no settings read as the counters at 1.
	load_settings! : [Unnamed, Named(Principal.GitHubId)] => Try(Accounts.Settings, [Failed])
	load_settings! = |first_admin| {
		settings_read = Host.read!(settings_path)
		counters =
			match settings_read.status {
				Missing => first_counters
				Failed => Err(Failed)
				Found => settings_counters(settings_read.bytes).map_err(|_| Failed)
			}?
		Ok({
			first_admin,
			next_generation: counters.next,
			next_agent_id: counters.agent,
			next_human_id: counters.human,
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
		ChatKey.Entry,
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
			Found => ChatKey.decode(read.bytes).map_err(|_| Malformed)
		}
	}

	## **EVERY KEY THAT READS**, in no order; a line that does not read is
	## left out (one damaged key fails only itself).
	load_keys! : {} => Try(List(ChatKey.Entry), [Failed])
	load_keys! = |{}| {
		listed = Host.list!(keys_path)
		match listed.status {
			Missing => Ok([])
			Failed => Err(Failed)
			Found => collect_keys!(listed.entries, [])
		}
	}

	## **THE NEXT KEY'S PUBLIC ID**: one past the highest stored, so none is
	## given twice while its key is there (erasure removes keys, and the count
	## of files would then hand out an id another key holds).
	load_next_key_id! : {} => Try(Principal.KeyId, [Failed])
	load_next_key_id! = |{}| {
		keys = Store.load_keys!({})?
		Principal.KeyId.from_u64(one_past_highest(keys.map(|e| e.key.id().to_u64()))).map_err(|_| Failed)
	}

	## A key written: minted, or revoked.
	save_key! : ChatKey.Entry => [Failed, Written]
	save_key! = |entry| Host.write!(key_path(entry.hash), ChatKey.encode(entry))

	## **THE INVITE WHOSE CODE HASHES TO `hash`**: its record, nothing
	## there, or a line that does not read (`Malformed`, which a caller takes
	## for no invite).
	load_invite! : Stored.SecretHash => Try(
		InviteCodec.Record,
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
			Found => InviteCodec.decode(read.bytes).map_err(|_| Malformed)
		}
	}

	## **EVERY INVITE THAT READS**, in no order; a line that does not read
	## is left out, as a key's is.
	load_invites! : {} => Try(List(InviteCodec.Record), [Failed])
	load_invites! = |{}| {
		listed = Host.list!(invites_path)
		match listed.status {
			Missing => Ok([])
			Failed => Err(Failed)
			Found => collect_invites!(listed.entries, [])
		}
	}

	## **THE NEXT INVITE'S PUBLIC ID**: one past the highest stored, as a
	## key's.
	load_next_invite_id! : {} => Try(InviteCodec.InviteId, [Failed])
	load_next_invite_id! = |{}| {
		invites = Store.load_invites!({})?
		InviteCodec.InviteId.from_u64(one_past_highest(invites.map(|r| r.id.to_u64()))).map_err(|_| Failed)
	}

	## An invite written: made, spent or revoked.
	save_invite! : InviteCodec.Record => [Failed, Written]
	save_invite! = |record| Host.write!(
		invite_path(record.hash),
		InviteCodec.encode(record),
	)

	## **THE HUMAN INVITE WHOSE CODE HASHES TO `hash`**: its record,
	## nothing there, or a line that does not read (`Malformed`, which a
	## caller takes for no invite).
	load_human_invite! : Stored.SecretHash => Try(
		HumanInvite.Record,
		[
			Missing,
			Malformed,
			Failed,
		],
	)
	load_human_invite! = |hash| {
		read = Host.read!(human_invite_path(hash))
		match read.status {
			Failed => Err(Failed)
			Missing => Err(Missing)
			Found => HumanInviteCodec.decode(read.bytes).map_err(|_| Malformed)
		}
	}

	## **THE NEXT HUMAN INVITE'S PUBLIC ID**: one past the highest stored,
	## as a key's.
	load_next_human_invite_id! : {} => Try(HumanInvite.InviteId, [Failed])
	load_next_human_invite_id! = |{}| {
		invites = load_human_invites!({})?
		HumanInvite.InviteId.from_u64(one_past_highest(invites.map(|r| r.id.to_u64()))).map_err(|_| Failed)
	}

	## A human invite written: spent or revoked.
	save_human_invite! : HumanInvite.Record => [Failed, Written]
	save_human_invite! = |record| Host.write!(
		human_invite_path(record.hash),
		HumanInviteCodec.encode(record),
	)

	## **THE HUMAN INVITES `human` MADE**, by their index; one whose file
	## is gone or does not read is left out.
	load_human_invites_of! : Principal.HumanId => Try(List(HumanInvite.Record), [Failed])
	load_human_invites_of! = |human| {
		_ = index_human_invites!({})?
		records = load_records!(index_path(human_invites_folder, human), hash_width)?
		load_human_invites_at!(records, [])
	}

	## **A NEW HUMAN INVITE WRITTEN, THEN INDEXED** under the human who
	## made it.
	save_new_human_invite! : HumanInvite.Record => [Failed, Written]
	save_new_human_invite! = |invite|
		match index_human_invites!({}) {
			Err(Failed) => Failed
			Ok(count) =>
				match Store.save_human_invite!(invite) {
					Failed => Failed
					Written => append_indexed!(
						human_invites_folder,
						human_invites_mark,
						{
							answerer: Ok(invite.by),
							record: hash_record(invite.hash),
							count,
						},
					)
				}
		}

	## **THE THREE FILES OF A TRANSCRIPT**: its messages, where each starts,
	## and their tally. The functions that keep a transcript reach the disk
	## through these alone.
	TranscriptFiles : {
		transcript : List(U8),
		offsets : List(U8),
		tally : List(U8),
	}

	## A topic's transcript files, in its folder in its channel's.
	topic_files : Topic.At -> Store.TranscriptFiles
	topic_files = |at| {
		transcript: ChannelLayout.transcript_path(at),
		offsets: ChannelLayout.offsets_path(at),
		tally: ChannelLayout.tally_path(at),
	}

	## **A TRANSCRIPT'S MESSAGES**, oldest first; none before the first.
	## `Failed` when the transcript will not read whole (a torn append, a
	## line the chat did not write).
	load_transcript! : Store.TranscriptFiles => Try(List(MessageCodec.Fields), [Failed])
	load_transcript! = |files| {
		read = Host.read!(files.transcript)
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
	load_tally! : Store.TranscriptFiles => Try(Store.Tally, [Failed])
	load_tally! = |files| {
		stat = Host.read_stat!(files.transcript)
		match stat.status {
			Failed => Err(Failed)
			Missing => Ok({ messages: 0, bytes: 0 })
			Found => {
				read = Host.read!(files.tally)
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
						messages = Store.load_transcript!(files)?
						Ok({ messages: messages.len(), bytes: stat.size })
					}
				}
			}
		}
	}

	## What a transcript holds, told: its messages and its bytes.
	Tally : { messages : U64, bytes : U64 }

	## **A RUN OF A TRANSCRIPT'S MESSAGES, `first` TO `last`**, read from
	## where `first` starts (its offsets file), never the transcript whole;
	## none when `first` is past `last`. `tally` is the transcript's now
	## (`load_tally!`, in this turn). An offsets file that does not hold one
	## record a message (a transcript from before it, or a stop between an
	## append and its record) is passed by: the transcript is read whole,
	## and the next append writes the file again.
	load_span! : Store.TranscriptFiles,
	Store.Tally,
	{ first : U64, last : U64 } => Try(
		List(MessageCodec.Fields),
		[Failed],
	)
	load_span! = |
		files,
		tally,
		{ first, last },
	|
		if first == 0 or last > tally.messages {
			crash "Store.load_span!: a span outside its transcript"
		} else if first > last {
			Ok([])
		} else {
			match check_offsets!(files, tally) {
				Err(Failed) => Err(Failed)
				Ok(Bool.False) => {
					all = Store.load_transcript!(files)?
					Ok(all.sublist({ start: first - 1, len: last - first + 1 }))
				}
				Ok(Bool.True) => {
					# `first`'s record, and the next one's after `last`'s, which
					# the transcript's end stands in for after its last message.
					records = Host.read_at!(
						files.offsets,
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
								files.transcript,
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

	## **A MESSAGE APPENDED TO A TRANSCRIPT, SYNCED, THEN
	## ITS TALLY**: `tally` is the transcript's before it (`load_tally!`, in
	## this turn), and the message's id the caller's, its count plus one.
	##
	## **THEN ITS OFFSET**, where it starts (the transcript's size before
	## it), appended to the offsets file; a file that does not hold one
	## record a message before it is written again whole, from the
	## transcript.
	append_message! : {
		files : Store.TranscriptFiles,
		tally : Store.Tally,
		message : MessageCodec.Fields,
	} => [Failed, Appended]
	append_message! = |
		{
			files,
			tally,
			message,
		},
	|
		match check_offsets!(files, tally) {
			Err(Failed) => Failed
			Ok(kept) => {
				appended = Host.append!(files.transcript, MessageCodec.encode(message))
				match appended.status {
					Failed => Failed
					Appended => {
						offsets =
							if kept {
								Host.append!(files.offsets, offset_record(tally.bytes)).status
							} else {
								save_offsets!(files)
							}
						match offsets {
							Failed => Failed
							Appended =>
								match Host.write!(
									files.tally,
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

	## **THE KEYS OF `human`'S**, theirs and their agents', by their index;
	## one whose file is gone or does not read is left out, as in `load_keys!`.
	load_keys_of! : Principal.HumanId, List(Principal) => Try(List(ChatKey.Entry), [Failed])
	load_keys_of! = |human, accounts| {
		_ = index_keys!(accounts)?
		records = load_records!(index_path(keys_folder, human), hash_width)?
		load_keys_at!(records, [])
	}

	## How many keys `human` has minted, for themselves and their agents,
	## revoked ones counted.
	load_key_count! : Principal.HumanId, List(Principal) => Try(U64, [Failed])
	load_key_count! = |human, accounts| {
		_ = index_keys!(accounts)?
		load_record_count!(index_path(keys_folder, human), hash_width)
	}

	## **A NEW KEY WRITTEN, THEN INDEXED** under the human the principal it
	## acts as answers to (none, for one the accounts do not hold, as the
	## rebuild leaves it out too).
	save_new_key! : ChatKey.Entry, List(Principal) => [Failed, Written]
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
	load_invites_of! : Principal.HumanId,
	List(Principal) => Try(
		List(InviteCodec.Record),
		[Failed],
	)
	load_invites_of! = |human, accounts| {
		_ = index_invites!(accounts)?
		records = load_records!(index_path(invites_folder, human), hash_width)?
		load_invites_at!(records, [])
	}

	## How many invites `human` has made, spent and revoked ones counted.
	load_invite_count! : Principal.HumanId, List(Principal) => Try(U64, [Failed])
	load_invite_count! = |human, accounts| {
		_ = index_invites!(accounts)?
		load_record_count!(index_path(invites_folder, human), hash_width)
	}

	## **A NEW INVITE WRITTEN, THEN INDEXED** under the human its agent
	## answers to, as a key is.
	save_new_invite! : InviteCodec.Record, List(Principal) => [Failed, Written]
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

	## **A NEW CHANNEL WRITTEN**, at its name's key: `Taken` when a channel
	## of that key is there already, in any spelling. Checked then set,
	## atomic because one handler runs at a time (the turn).
	save_new_channel! : Channel => [
		Failed,
		Taken,
		Written,
	]
	save_new_channel! = |channel| save_new!(
		ChannelLayout.channel_path(channel.name()),
		ChannelCodec.encode(channel.fields()),
	)

	## **A CHANNEL WRITTEN OVER ITS RECORD** (a member let in or let go):
	## `Missing` when no channel is at its name's key, so a write here never
	## makes one (`save_new_channel!` does). Checked then set, atomic because
	## one handler runs at a time (the turn).
	save_channel! : Channel => [
		Failed,
		Missing,
		Written,
	]
	save_channel! = |channel| {
		path = ChannelLayout.channel_path(channel.name())
		stat = Host.read_stat!(path)
		match stat.status {
			Missing => Missing
			Failed => Failed
			Found =>
				match Host.write!(path, ChannelCodec.encode(channel.fields())) {
					Failed => Failed
					Written => Written
				}
		}
	}

	## The channel `name` names, in any spelling: `Missing` when there is
	## none, and `Failed` when its record will not read or names another
	## channel than its folder's (a store the chat did not write).
	load_channel! : ChannelName => Try(Channel, [Missing, Failed])
	load_channel! = |name| read_channel!(name).map_err(
		|e|
			match e {
				Missing => Missing
				Malformed | Failed => Failed
			},
	)

	## **EVERY CHANNEL AND DM STORED**, the channels first, each in the
	## order the disk gives their folders. One damaged entry fails only itself: a folder
	## whose name is no channel's key, or whose record will not read, is
	## left out and counted in `damaged`. A folder with no record yet (a
	## stop before its first write landed) holds no channel.
	load_channels! : {} => Try({ channels : List(Channel), damaged : U64 }, [Failed])
	load_channels! = |{}| {
		channels = load_folder_of!(ChannelLayout.channels_path, { parse: ChannelName.from_str, kept: { channels: [], damaged: 0 } })?
		load_folder_of!(ChannelLayout.dms_path, { parse: |text| ChannelName.dm_from(text).map_err(|_| NotAChannelName), kept: channels })
	}

	## **EVERY CHANNEL'S NAME**, as the one namespace asks it
	## (Accounts.name_holder) before a person or an agent is named: the
	## channels `load_channels!` reads, a damaged one left out as it leaves it.
	load_channel_names! : {} => Try(List(ChannelName), [Failed])
	load_channel_names! = |{}| Store.load_channels!({}).map_ok(|listed| listed.channels.map(|c| c.name()))

	## **A NEW TOPIC WRITTEN** in its channel, at its name's key: `Taken`
	## when a topic of that key is in the channel already, in any spelling
	## (another channel's topic of the name is no matter). Checked then set,
	## as a channel is.
	save_new_topic! : Topic => [
		Failed,
		Taken,
		Written,
	]
	save_new_topic! = |topic| save_new!(
		ChannelLayout.topic_path(topic.at()),
		TopicCodec.encode(topic.fields()),
	)

	## The topic `name` names in `channel` (loaded), in any spelling:
	## `Missing` when there is none, and `Failed` when its record will not
	## read or names another topic than its folder's.
	load_topic! : Channel, TopicName => Try(Topic, [Missing, Failed])
	load_topic! = |channel, name| read_topic!({ channel: channel.name(), topic: name }).map_err(
		|e|
			match e {
				Missing => Missing
				Malformed | Failed => Failed
			},
	)

	## **EVERY TOPIC OF `channel`** (loaded), in the order the disk gives
	## their folders; a damaged one left out and counted, as a channel is.
	load_topics! : Channel => Try({ topics : List(Topic), damaged : U64 }, [Failed])
	load_topics! = |channel| {
		listed = Host.list!(ChannelLayout.topics_path(channel.name()))
		match listed.status {
			Missing => Ok({ topics: [], damaged: 0 })
			Failed => Err(Failed)
			Found => collect_topics!(
				channel.name(),
				{ folders: listed.entries, kept: { topics: [], damaged: 0 } },
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

## Where a human's uploaded bytes are counted.
uploaded_path : Principal.HumanId -> List(U8)
uploaded_path = |human| "chat/upload-bytes/${human.to_u64().to_str()}".to_utf8()

## **ERASURE, STEP BY STEP** (Store.erase!): each DM's folder; the
## human's sessions; every key acting as one who goes (the human, their
## agents and bots); every agent invite for one of them; every human invite
## made by the human or for them; the human's own files; then the
## accounts, written out last. A step that fails stops the rest.
erase_steps! : Erase.Plan => Try({}, [Failed])
erase_steps! = |plan| {
	step(remove_places!(plan.dms))?
	step(remove_sessions_of!(plan.human))?
	keys = Store.load_keys!({})?
	step(remove_each!(keys.keep_if(|e| plan.gone.contains(e.key.acts_as())).map(|e| key_path(e.hash))))?
	invites = Store.load_invites!({})?
	step(remove_each!(invites.keep_if(|r| plan.gone.contains(r.bound.id)).map(|r| invite_path(r.hash))))?
	human_invites = load_human_invites!({})?
	by_or_for = |r| r.by == plan.human or r.human.id == Principal.Id.Human(plan.human)
	step(remove_each!(human_invites.keep_if(by_or_for).map(|r| human_invite_path(r.hash))))?
	step(remove_each!(own_paths(plan.human)))?
	lines = plan.left.map_try(AccountCodec.encode).map_err(|_| Failed)?
	match Host.write!(accounts_path, List.join(lines)) {
		Failed => Err(Failed)
		Written => Ok({})
	}
}

## A removal's answer as a step's.
step : [Failed, Removed] -> Try({}, [Failed])
step = |answer|
	match answer {
		Failed => Err(Failed)
		Removed => Ok({})
	}

## One past the highest of `ids`; 1 for none.
one_past_highest : List(U64) -> U64
one_past_highest = |ids| ids.fold(0, |most, id| if (id > most) id else most) + 1

## **EVERY HUMAN INVITE THAT READS**, in no order; one that does not read is
## left out, as a key's is.
load_human_invites! : {} => Try(List(HumanInvite.Record), [Failed])
load_human_invites! = |{}| {
	listed = Host.list!(human_invites_path)
	match listed.status {
		Missing => Ok([])
		Failed => Err(Failed)
		Found => collect_human_invites!(listed.entries, [])
	}
}

## **A HUMAN'S OWN FILES, AS ERASURE TAKES THEM**: their uploaded bytes'
## count, and the indexes of their keys, agents' invites and
## human invites (an index rebuilds from the files it indexes, so dropping a
## human's leaves the others whole).
own_paths : Principal.HumanId -> List(List(U8))
own_paths = |human| [
	uploaded_path(human),
	index_path(keys_folder, human),
	index_path(invites_folder, human),
	index_path(human_invites_folder, human),
]

## Each file of `paths` removed, in order; one not there is gone already.
remove_each! : List(List(U8)) => [Failed, Removed]
remove_each! = |paths|
	match paths {
		[] => Removed
		[path, .. as rest] =>
			match Host.remove!(path) {
				Failed => Failed
				Removed => remove_each!(rest)
			}
	}

## **EACH DM'S FOLDER REMOVED, WHOLE**: a DM's alone (a channel's name is
## never one, ChannelName.dm_pair), so no channel's folder is ever taken.
remove_places! : List(ChannelName) => [Failed, Removed]
remove_places! = |dms|
	match dms {
		[] => Removed
		[dm, .. as rest] =>
			if !dm.is_dm() {
				Failed
			} else {
				match remove_tree!(ChannelLayout.place_path(dm)) {
					Failed => Failed
					Removed => remove_places!(rest)
				}
			}
	}

## **A FOLDER AND EVERYTHING IN IT REMOVED**, depth first, never through a
## link (the host's listing says what each entry is; one neither a file
## nor a folder fails it); a folder not there is gone already.
remove_tree! : List(U8) => [Failed, Removed]
remove_tree! = |path| {
	listed = Host.list!(path)
	match listed.status {
		Missing => Removed
		Failed => Failed
		Found =>
			match remove_entries!(path, listed.entries) {
				Failed => Failed
				Removed => Host.remove!(path)
			}
	}
}

remove_entries! : List(U8), List(FolderEntry) => [Failed, Removed]
remove_entries! = |path, entries|
	match entries {
		[] => Removed
		[entry, .. as rest] => {
			child = path.concat(['/']).concat(entry.name)
			done =
				match entry.kind {
					Dir => remove_tree!(child)
					File => Host.remove!(child)
					Other => Failed
				}
			match done {
				Failed => Failed
				Removed => remove_entries!(path, rest)
			}
		}
	}

## **EVERY SESSION OF `human`'S ENDED**: each stored session that reads and
## is theirs removed (a session is named for its secret's hash, so they are
## found by reading each).
remove_sessions_of! : Principal.HumanId => [Failed, Removed]
remove_sessions_of! = |human| {
	listed = Host.list!("auth/sessions".to_utf8())
	match listed.status {
		Missing => Removed
		Failed => Failed
		Found => remove_sessions_from!(listed.entries, human)
	}
}

remove_sessions_from! : List(FolderEntry), Principal.HumanId => [Failed, Removed]
remove_sessions_from! = |entries, human|
	match entries {
		[] => Removed
		[entry, .. as rest] => {
			path = "auth/sessions/".to_utf8().concat(entry.name)
			read = Host.read!(path)
			theirs =
				match read.status {
					Found => SessionCodec.decode(read.bytes).map_ok(|line| line.fields().human == human) ?? Bool.False
					Missing | Failed => Bool.False
				}
			done = if (theirs) Host.remove!(path) else Removed
			match done {
				Failed => Failed
				Removed => remove_sessions_from!(rest, human)
			}
		}
	}

settings_path : List(U8)
settings_path = "auth/settings".to_utf8()

audit_path : List(U8)
audit_path = "auth/audit".to_utf8()

## Whether the offsets file holds one record for each message `tally`
## counts.
check_offsets! : Store.TranscriptFiles, Store.Tally => Try(Bool, [Failed])
check_offsets! = |files, tally| {
	stat = Host.read_stat!(files.offsets)
	match stat.status {
		Failed => Err(Failed)
		Missing => Ok(tally.messages == 0)
		Found => Ok(stat.size == tally.messages * offset_width)
	}
}

## The offsets file written whole, from the transcript as it is.
save_offsets! : Store.TranscriptFiles => [Appended, Failed]
save_offsets! = |files| {
	read = Host.read!(files.transcript)
	match read.status {
		Missing | Failed => Failed
		Found =>
			match Host.write!(
				files.offsets,
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

keys_folder : Str
keys_folder = "auth/keys-by-human"

keys_mark : List(U8)
keys_mark = "auth/keys-indexed".to_utf8()

invites_folder : Str
invites_folder = "auth/invites-by-human"

invites_mark : List(U8)
invites_mark = "auth/invites-indexed".to_utf8()

## A human's file in an index's folder.
index_path : Str, Principal.HumanId -> List(U8)
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

## **THE KEYS' INDEX, UP TO DATE**: their count, the index rebuilt from
## every key first when its mark is not it.
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

## The human invites' index, up to date, as the agent invites' is: each
## under the human who made it.
index_human_invites! : {} => Try(U64, [Failed])
index_human_invites! = |{}| {
	count = load_one_past_count!(human_invites_path)? - 1
	if check_mark!(human_invites_mark, count)? {
		Ok(count)
	} else {
		listed = Host.list!(human_invites_path)
		all =
			match listed.status {
				Missing => Ok([])
				Failed => Err(Failed)
				Found => collect_human_invites!(listed.entries, [])
			}?
		rewrite_index!(human_invites_folder, grouped(all.map(|i| (i.by, hash_record(i.hash)))))?
		match Host.write!(human_invites_mark, mark_line(count)) {
			Failed => Err(Failed)
			Written => Ok(count)
		}
	}
}

## The invites' index, up to date, as the keys' is.
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
answerer_of : List(Principal), Principal.Id -> Try(Principal.HumanId, [Unresolved])
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
	answerer : Try(Principal.HumanId, [Unresolved]),
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

## Records gathered by human, each human's in the order given.
grouped : List((Principal.HumanId, List(U8))) -> List(
	{
		human : Principal.HumanId,
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
rewrite_index! : Str, List({ human : Principal.HumanId, records : List(U8) }) => Try({}, [Failed])
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
		human : Principal.HumanId,
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

load_keys_at! : List(List(U8)), List(ChatKey.Entry) => Try(List(ChatKey.Entry), [Failed])
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
List(InviteCodec.Record) => Try(
	List(InviteCodec.Record),
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

human_invites_path : List(U8)
human_invites_path = "auth/human-invites".to_utf8()

## A human invite's file, named for its code's hash.
human_invite_path : Stored.SecretHash -> List(U8)
human_invite_path = |h| Str.to_utf8("auth/human-invites/${Stored.hash_text(h)}")

human_invites_folder : Str
human_invites_folder = "auth/human-invites-by-human"

human_invites_mark : List(U8)
human_invites_mark = "auth/human-invites-indexed".to_utf8()

## The human invites the listed files hold, after `kept`; a file that does
## not read as one is left out.
collect_human_invites! : List(
	{
		kind : [
			Dir,
			File,
			Other,
		],
		name : List(U8),
	},
),
List(HumanInvite.Record) => Try(List(HumanInvite.Record), [Failed])
collect_human_invites! = |entries, kept|
	match entries {
		[] => Ok(kept)
		[entry, .. as rest] => {
			read = Host.read!(
				List.join([
					human_invites_path,
					['/'],
					entry.name,
				]),
			)
			match read.status {
				Failed => Err(Failed)
				Missing => collect_human_invites!(rest, kept)
				Found =>
					match HumanInviteCodec.decode(read.bytes) {
						Ok(r) => collect_human_invites!(rest, kept.append(r))
						Err(_) => collect_human_invites!(rest, kept)
					}
			}
		}
	}

## The human invites an index's records name, after `kept`.
load_human_invites_at! : List(List(U8)),
List(HumanInvite.Record) => Try(
	List(HumanInvite.Record),
	[Failed],
)
load_human_invites_at! = |records, kept|
	match records {
		[] => Ok(kept)
		[record, .. as rest] => {
			hash = Stored.hash(List.drop_last(record, 1), "invite").map_err(|_| Failed)?
			match Store.load_human_invite!(hash) {
				Ok(i) => load_human_invites_at!(rest, kept.append(i))
				Err(Missing) | Err(Malformed) => load_human_invites_at!(rest, kept)
				Err(Failed) => Err(Failed)
			}
		}
	}

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
List(InviteCodec.Record) => Try(
	List(InviteCodec.Record),
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
					match InviteCodec.decode(read.bytes) {
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
List(ChatKey.Entry) => Try(List(ChatKey.Entry), [Failed])
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
					match ChatKey.decode(read.bytes) {
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
## the id the next agent or bot is given, and the id the next human is
## given. Every field is there: the store started empty with this format.
##
##     settings v1 next=3 agent=8 human=2
settings_line : Accounts.Settings -> List(U8)
settings_line = |settings| Stored.line(
	"settings",
	[
		("next", settings.next_generation.to_u64().to_str()),
		("agent", settings.next_agent_id.to_u64().to_str()),
		("human", settings.next_human_id.to_u64().to_str()),
	],
)

## The counters of a store with no settings yet: each at 1.
first_counters : Try(
	{
		next : Principal.Generation,
		agent : Principal.AgentId,
		human : Principal.HumanId,
	},
	[Failed],
)
first_counters =
	match (
		Principal.Generation.from_u64(1),
		Principal.AgentId.from_u64(1),
		Principal.HumanId.from_u64(1),
	) {
		(
			Ok(next),
			Ok(agent),
			Ok(human),
		) => Ok({
			next,
			agent,
			human,
		})
		_ => Err(Failed)
	}

## The counters the settings' record holds, every one of them.
settings_counters : List(U8) -> Try(
	{
		next : Principal.Generation,
		agent : Principal.AgentId,
		human : Principal.HumanId,
	},
	_,
)
settings_counters = |raw| {
	fields = Stored.Reader.open(raw, "settings")?
	next_field = fields.field("next")?
	next = Stored.id(next_field.value, { name: "next", make: Principal.Generation.from_u64 })?
	agent_field = next_field.rest.field("agent")?
	agent = Stored.id(agent_field.value, { name: "agent", make: Principal.AgentId.from_u64 })?
	human_field = agent_field.rest.field("human")?
	human = Stored.id(human_field.value, { name: "human", make: Principal.HumanId.from_u64 })?
	human_field.rest.close()?
	Ok({
		next,
		agent,
		human,
	})
}

## **ONE PAST THE COUNT OF A FOLDER'S ENTRIES**; 1 for a folder not made
## yet. What an index's mark is checked against (a changed count means
## the index is rebuilt).
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

## ── the channels and their topics (ChannelLayout) ──

## A folder's entry, as the host lists it.
FolderEntry : {
	kind : [
		Dir,
		File,
		Other,
	],
	name : List(U8),
}

## **A RECORD WRITTEN WHERE NONE IS**: `Taken` when the file is there.
save_new! : List(U8),
List(U8) => [
	Failed,
	Taken,
	Written,
]
save_new! = |path, bytes| {
	stat = Host.read_stat!(path)
	match stat.status {
		Found => Taken
		Failed => Failed
		Missing =>
			match Host.write!(path, bytes) {
				Failed => Failed
				Written => Written
			}
	}
}

## The channel at `name`'s key: its record not there (`Missing`), not one
## the chat wrote there (`Malformed`), or a read that failed.
read_channel! : ChannelName => Try(
	Channel,
	[
		Missing,
		Malformed,
		Failed,
	],
)
read_channel! = |name| {
	read = Host.read!(ChannelLayout.channel_path(name))
	match read.status {
		Missing => Err(Missing)
		Failed => Err(Failed)
		Found =>
			match ChannelCodec.decode(read.bytes) {
				Ok(line) if line.fields().name == name => Ok(Channel.load(line))
				_ => Err(Malformed)
			}
	}
}

## The topic at `at`'s keys, as `read_channel!` reads a channel.
read_topic! : Topic.At => Try(
	Topic,
	[
		Missing,
		Malformed,
		Failed,
	],
)
read_topic! = |at| {
	read = Host.read!(ChannelLayout.topic_path(at))
	match read.status {
		Missing => Err(Missing)
		Failed => Err(Failed)
		Found =>
			match TopicCodec.decode(read.bytes) {
				Ok(line) if line.fields().name == at.topic => Ok(Topic.load(at.channel, line))
				_ => Err(Malformed)
			}
	}
}

## **THE NAME A FOLDER IS THE KEY OF**: a folder whose name `parse` takes
## and is its own `key`, the one spelling a path uses.
folder_key : FolderEntry, { parse : (Str -> Try(a, _)), key : (a -> Str) } -> Try(a, [NotAKey])
folder_key = |entry, { parse, key }|
	match (entry.kind, Str.from_utf8(entry.name)) {
		(Dir, Ok(text)) =>
			match parse(text) {
				Ok(name) if key(name) == text => Ok(name)
				_ => Err(NotAKey)
			}
		_ => Err(NotAKey)
	}

## **THE CHANNELS (OR DMS) ONE FOLDER HOLDS**, after `kept`: each entry
## whose name `parse` takes as its key.
load_folder_of! : List(U8),
{
	parse : Str -> Try(ChannelName, [NotAChannelName]),
	kept : { channels : List(Channel), damaged : U64 },
} => Try({ channels : List(Channel), damaged : U64 }, [Failed])
load_folder_of! = |path, { parse, kept }| {
	listed = Host.list!(path)
	match listed.status {
		Missing => Ok(kept)
		Failed => Err(Failed)
		Found => collect_channels!(listed.entries, { parse, kept })
	}
}

## The channels the listed folders hold, after `kept`.
collect_channels! : List(FolderEntry),
{
	parse : Str -> Try(ChannelName, [NotAChannelName]),
	kept : { channels : List(Channel), damaged : U64 },
} => Try(
	{ channels : List(Channel), damaged : U64 },
	[Failed],
)
collect_channels! = |entries, { parse, kept }|
	match entries {
		[] => Ok(kept)
		[entry, .. as rest] => {
			read =
				match folder_key(entry, { parse, key: ChannelName.key }) {
					Ok(name) => read_channel!(name)
					Err(NotAKey) => Err(Malformed)
				}
			match read {
				Ok(c) => collect_channels!(rest, { parse, kept: { ..kept, channels: kept.channels.append(c) } })
				Err(Missing) => collect_channels!(rest, { parse, kept })
				Err(Malformed) => collect_channels!(rest, { parse, kept: { ..kept, damaged: kept.damaged + 1 } })
				Err(Failed) => Err(Failed)
			}
		}
	}

## The topics of `channel` the listed folders hold, after `kept`.
collect_topics! : ChannelName,
{
	folders : List(FolderEntry),
	kept : { topics : List(Topic), damaged : U64 },
} => Try(
	{ topics : List(Topic), damaged : U64 },
	[Failed],
)
collect_topics! = |channel, { folders, kept }|
	match folders {
		[] => Ok(kept)
		[entry, .. as rest] => {
			read =
				match folder_key(entry, { parse: TopicName.from_str, key: TopicName.key }) {
					Ok(topic) => read_topic!({ channel, topic })
					Err(NotAKey) => Err(Malformed)
				}
			next =
				match read {
					Ok(t) => { ..kept, topics: kept.topics.append(t) }
					Err(Missing) => kept
					Err(Malformed) => { ..kept, damaged: kept.damaged + 1 }
					Err(Failed) => return Err(Failed)
				}
			collect_topics!(channel, { folders: rest, kept: next })
		}
	}

expect folder_key(
	{ kind: Dir, name: "cobblestone".to_utf8() },
	{ parse: ChannelName.from_str, key: ChannelName.key },
).map_ok(ChannelName.to_str) == Ok("cobblestone")
expect folder_key(
	{ kind: Dir, name: "Cobblestone".to_utf8() },
	{ parse: ChannelName.from_str, key: ChannelName.key },
) == Err(NotAKey)
expect folder_key(
	{ kind: File, name: "cobblestone".to_utf8() },
	{ parse: ChannelName.from_str, key: ChannelName.key },
) == Err(NotAKey)
expect folder_key(
	{ kind: Dir, name: "a--b".to_utf8() },
	{ parse: TopicName.from_str, key: TopicName.key },
) == Err(NotAKey)
expect folder_key(
	{ kind: Dir, name: "road-trip-2".to_utf8() },
	{ parse: TopicName.from_str, key: TopicName.key },
).is_ok()

# ── transcript files
## Where `channel`'s topic `name` is.
topic_at : Str, Str -> Topic.At
topic_at = |channel, name|
	match (ChannelName.from_str(channel), TopicName.from_str(name)) {
		(Ok(c), Ok(t)) => { channel: c, topic: t }
		_ => crash "topic_at: a test's names are names"
	}

## A transcript's three files, in a list.
files_list : Store.TranscriptFiles -> List(List(U8))
files_list = |f| [
	f.transcript,
	f.offsets,
	f.tally,
]

# A topic's files: in its own folder, in its own channel's.
expect
	Store.topic_files(topic_at("Cobblestone", "ChitChat"))
		== {
			transcript: "chat/channels/cobblestone/topics/chitchat/transcript".to_utf8(),
			offsets: "chat/channels/cobblestone/topics/chitchat/offsets".to_utf8(),
			tally: "chat/channels/cobblestone/topics/chitchat/tally".to_utf8(),
		}
# Two channels' ChitChats: no file shared.
expect
	files_list(Store.topic_files(topic_at("Cobblestone", "ChitChat")))
		.all(|p| !files_list(Store.topic_files(topic_at("general", "ChitChat"))).contains(p))
# One topic in any spelling: one set of files.
expect Store.topic_files(
	topic_at(
		"COBBLESTONE",
		"chitchat",
	),
) == Store.topic_files(topic_at("Cobblestone", "ChitChat"))

## **THE CHANNELS ON THE WIRE, AN ADMIN'S**: making a channel, and letting
## a member in or out. Every decision is Channel's (an admin by their own
## session, a channel's name and members); here are the facts asked of the
## host, the records kept (Store) and the answers made.
##
##     POST /channels                 make a channel: a form, `name=` and
##                                    `members=`, humans' ids, commas
##                                    between (`human:2,human:7`), or none
##     POST /channels/<name>/admit    let a human in: `member=human:2`
##     POST /channels/<name>/remove   let a member go: `member=human:2`
##
## A change answers the channel as JSON (`Channels.channel_json`); a refusal
## is plain text that says why. **EVERY CHANGE, AND EVERY REFUSAL OF A
## NAMED ASKER, IS AUDITED** (AuditCodec's `audit-channel`): a session's or
## a key's, never a signed-out request's, which names no one. A form that
## does not read (a member that is no id) is a 400 before any decision, and
## names nothing to audit. The admin's page of them is Pages'
## (`/chat/channels`), from `Channels.load_listing!`.
import pf.Chat
import pf.Host
import Access
import AccountCodec
import ApiKey
import AuditCodec
import Channel
import ChannelName
import ConvAccess
import Credentials
import JsonOut
import Principal
import SignInWeb
import Store
import Wire

Channels := [].{

	## What a path under `/channels` asks.
	Route : [
		Make,
		Admit(ChannelName),
		Remove(ChannelName),
	]

	## The route a path names, if it names one.
	route : List(U8) -> Try(Channels.Route, [NotChannels])
	route = |path|
		if path == "/channels".to_utf8() {
			Ok(Make)
		} else {
			match path.split_on('/') {
				[
					[],
					channels,
					name,
					act,
				] if channels == "channels".to_utf8() => {
					valid = name_in_path(name)?
					if act == "admit".to_utf8() {
						Ok(Admit(valid))
					} else if act == "remove".to_utf8() {
						Ok(Remove(valid))
					} else {
						Err(NotChannels)
					}
				}
				_ => Err(NotChannels)
			}
		}

	## **ANSWER A ROUTE**: each a POST.
	answer! : Chat.Request, Channels.Route => Chat.Answer
	answer! = |req, r|
		if req.method != Post {
			Chat.not_allowed(Post)
		} else {
			got = Host.read_body!(Wire.form_most)
			match got.status {
				Answered => Chat.answered
				Read =>
					match load_asker!({}) {
						Err(Answered(answer)) => answer
						Err(KeyRefused(refused)) =>
							refuse_key!({
								refused,
								route: r,
								form: got.bytes,
							})
						Ok(asker) =>
							match r {
								Make => make!(asker, got.bytes)
								Admit(name) =>
									admit_or_remove!(
										asker,
										{
											name,
											action: Admit,
											form: got.bytes,
										},
									)
								Remove(name) =>
									admit_or_remove!(
										asker,
										{
											name,
											action: Remove,
											form: got.bytes,
										},
									)
							}
					}
			}
		}

	## **WHAT THE ADMIN'S PAGE SHOWS**: the accounts, and every channel
	## stored, sorted by its key; and how many records did not read.
	Listing : {
		accounts : List(Principal),
		channels : List(Channel),
		damaged : U64,
	}

	## **THE ADMIN'S PAGE'S FACTS**, for an admin by their own session:
	## nobody signed in (or a session no longer admitted, or its account
	## gone) is `SignedOut`; any key is `ByKey` (a page is a browser's); a
	## human who is no admin, `NotAdmin`; a credential that ends the
	## request, its answer.
	load_listing! : {} => Try(
		Channels.Listing,
		[
			SignedOut,
			ByKey,
			NotAdmin,
			Answered(Chat.Answer),
		],
	)
	load_listing! = |{}|
		match load_asker!({}) {
			Err(Answered(answer)) => Err(Answered(answer))
			Err(KeyRefused(_)) => Err(ByKey)
			Ok(asker) =>
				match Channel.administers(asker.viewer, asker.accounts) {
					Err(SignedOut) | Err(NoSuchPrincipal) => Err(SignedOut)
					Err(NeedsSession) => Err(ByKey)
					Err(NotAdmin) => Err(NotAdmin)
					Ok({}) =>
						match Store.load_channels!({}) {
							Err(Failed) => Err(Answered(Chat.failed))
							Ok({ channels, damaged }) =>
								Ok({
									accounts: asker.accounts,
									channels: channels.sort_with(by_name_key),
									damaged,
								})
						}
				}
		}

	## **A CHANNEL AS THE WIRE SPELLS IT**: its name as made, and its
	## members now, by id: `{"name":"Lobby","members":["human:2"]}`.
	channel_json : Channel, List(Principal) -> JsonOut
	channel_json = |channel, accounts|
		JsonOut.object([
			("name", JsonOut.string(channel.name().to_str())),
			("members", JsonOut.array(channel.members(accounts).map(|b| JsonOut.string(AccountCodec.id_text(b.id))))),
		])
}

## **WHO ASKS**: the viewer Channel decides on, the accounts and the time,
## and who to audit: a session's human or a key's principal, by its public
## id; nobody signed in is never audited.
Asker : {
	viewer : Access.Viewer(ConvAccess.ConvId),
	audit : [Unaudited, As(Named)],
	accounts : List(Principal),
	now : I64,
}

## A named asker, as an audit line says them.
Named : {
	who : Principal.Id,
	via : [Session(Principal.SessionId), Key(Principal.KeyId)],
}

## A key that does not stand (revoked, expired, its principal gone): who
## it acts as, and ApiKey's reason.
Refused : {
	named : Named,
	why : ApiKey.Refusal,
	now : I64,
}

## **THE ASKER, FROM THE CREDENTIAL**: a session admitted now (its `last
## seen` written when stale; one not admitted is signed out, as
## Credentials.load_viewer! has it), a key standing now, or nobody. A key
## that does not stand is `KeyRefused`, for the route to audit and refuse.
load_asker! : {} => Try(Asker, [KeyRefused(Refused), Answered(Chat.Answer)])
load_asker! = |{}| {
	credential = Credentials.load_credential!({}).map_err(|answer| Answered(answer))?
	now = Host.read_time!({})
	accounts = Store.load_accounts!({}).map_err(|_| Answered(Chat.failed))?
	signed_out = Ok({
		viewer: Access.Viewer.signed_out({}),
		audit: Unaudited,
		accounts,
		now,
	})
	match credential {
		Nobody => signed_out
		Session(session) => {
			named = As({ who: Principal.Id.Human(session.human()), via: Session(session.id()) })
			match Access.Viewer.from_session(session, { accounts, now }) {
				Err(_) => signed_out
				Ok({ viewer, write: Unchanged }) =>
					Ok({
						viewer,
						audit: named,
						accounts,
						now,
					})
				Ok({ viewer, write: Touched(s) }) =>
					match Store.save_session!(s.fields()) {
						Failed => Err(Answered(Chat.failed))
						Written =>
							Ok({
								viewer,
								audit: named,
								accounts,
								now,
							})
					}
			}
		}
		Key(key) => {
			named = { who: key.acts_as(), via: Key(key.id()) }
			match Access.Viewer.from_key(key, { accounts, now }) {
				Ok(viewer) =>
					Ok({
						viewer,
						audit: As(named),
						accounts,
						now,
					})
				Err(why) =>
					Err(
						KeyRefused({
							named,
							why,
							now,
						}),
					)
			}
		}
	}
}

## **A KEY THAT DOES NOT STAND**: a 401, as every route answers one, and
## audited as this change refused by its key's reason.
refuse_key! : {
	refused : Refused,
	route : Channels.Route,
	form : List(U8),
} => Chat.Answer
refuse_key! = |
	{
		refused,
		route: r,
		form,
	},
| {
	named = refused.named
	why = refused.why
	now = refused.now
	(action, channel) =
		match r {
			Make => (Make, unnamed_or(SignInWeb.form_field(form, "name")))
			Admit(name) => (Admit, Named(name))
			Remove(name) => (Remove, Named(name))
		}
	asked =
		match r {
			Make => asked_members(form)
			Admit(_) | Remove(_) => asked_member(form).map_ok(|m| [m])
		}
	members =
		match asked {
			Ok(ids) => ids
			Err(_) => []
		}
	append_audit!({
		at: now,
		who: named.who,
		via: named.via,
		action,
		channel,
		members,
		verdict: Refused(KeyRefused(why)),
	})
	Wire.refused(401, "key refused")
}

## The name a form asks, when the rule takes it; `Unnamed` otherwise.
unnamed_or : Try(List(U8), [Missing, Malformed]) -> [Named(ChannelName), Unnamed]
unnamed_or = |asked|
	match asked {
		Ok(bytes) =>
			match Str.from_utf8(bytes) {
				Ok(text) =>
					match ChannelName.from_str(text) {
						Ok(name) => Named(name)
						Err(NotAChannelName) => Unnamed
					}
				Err(_) => Unnamed
			}
		Err(_) => Unnamed
	}

## **/channels**: a channel made, by an admin, with its members; stored at
## its name's key, audited, and answered.
make! : Asker, List(U8) => Chat.Answer
make! = |asker, form|
	match asked_members(form) {
		Err(why) => Wire.refused(400, why)
		Ok(members) => {
			name_bytes =
				match SignInWeb.form_field(form, "name") {
					Ok(bytes) => bytes
					Err(_) => []
				}
			name =
				match Str.from_utf8(name_bytes) {
					Ok(text) => text
					Err(_) => ""
				}
			event = |verdict, channel| {
				action: Make,
				channel,
				members,
				verdict,
			}
			match Store.load_channels!({}) {
				Err(Failed) => Chat.failed
				Ok({ channels, damaged: _ }) =>
					{
						made = Channel.make({
							by: asker.viewer,
							name,
							members,
							channels,
							accounts: asker.accounts,
						})
						match made {
							Err(why) => refuse!(asker, { event: event(Refused(word_of(why)), unnamed_or(Ok(name_bytes))), why })
							Ok(channel) =>
								match Store.save_new_channel!(channel) {
									Failed => Chat.failed
									# No channel loaded holds the name, but a folder of
									# its key does: a record that does not read.
									Taken => Wire.refused(409, "a channel's folder holds that name, but its record does not read")
									Written => {
										audit!(asker, event(Permitted, Named(channel.name())))
										Wire.json(201, Channels.channel_json(channel, asker.accounts))
									}
								}
						}
					}
			}
		}
	}

## **/channels/<name>/admit or /remove**: a member let in or out, by an
## admin; the channel written over, audited, and answered. A channel that
## is not there is said so only to an admin.
admit_or_remove! : Asker,
{
	name : ChannelName,
	action : [Admit, Remove],
	form : List(U8),
} => Chat.Answer
admit_or_remove! = |
	asker,
	{
		name,
		action,
		form,
	},
|
	match asked_member(form) {
		Err(why) => Wire.refused(400, why)
		Ok(member) => {
			# The channel as it was made, once found; as the path spells it
			# until then.
			event = |verdict, spelled| {
				action: match action {
					Admit => Admit
					Remove => Remove
				},
				channel: Named(spelled),
				members: [member],
				verdict,
			}
			match Store.load_channel!(name) {
				Err(Failed) => Chat.failed
				Err(Missing) =>
					match Channel.administers(asker.viewer, asker.accounts) {
						Err(why) => refuse!(asker, { event: event(Refused(word_of(why)), name), why })
						Ok({}) => refuse!(asker, { event: event(Refused(NoSuchChannel), name), why: NoSuchChannel })
					}
				Ok(channel) => {
					by = {
						by: asker.viewer,
						member,
						accounts: asker.accounts,
					}
					decided =
						match action {
							Admit => channel.admit(by)
							Remove => channel.remove(by)
						}
					match decided {
						Err(why) => refuse!(asker, { event: event(Refused(word_of(why)), channel.name()), why })
						Ok(changed) =>
							match Store.save_channel!(changed) {
								Failed | Missing => Chat.failed
								Written => {
									audit!(asker, event(Permitted, changed.name()))
									Wire.json(200, Channels.channel_json(changed, asker.accounts))
								}
							}
					}
				}
			}
		}
	}

## Every refusal a channel's route answers.
Refusal : [
	SignedOut,
	NeedsSession,
	NoSuchPrincipal,
	NotAdmin,
	NotAChannelName,
	Taken,
	NamedTwice(Principal.Id),
	NotAHuman(Principal.Id),
	NoAccount(Principal.Id),
	AlreadyIn(Principal.Id),
	NotIn(Principal.Id),
	NoSuchChannel,
]

## The change's event, without its asker.
Event : {
	action : AuditCodec.ChannelAction,
	channel : [Named(ChannelName), Unnamed],
	members : List(Principal.Id),
	verdict : [Permitted, Refused(AuditCodec.ChannelRefusal)],
}

## **A CHANGE REFUSED**: audited when the asker is named, and answered in
## plain text with its reason.
refuse! : Asker, { event : Event, why : Refusal } => Chat.Answer
refuse! = |asker, { event, why }| {
	match why {
		SignedOut => {}
		_ => audit!(asker, event)
	}
	(status, text) = refusal_text(why)
	Wire.refused(status, text)
}

## A refusal's status and words.
refusal_text : Refusal -> (U16, Str)
refusal_text = |why|
	match why {
		SignedOut => (401, "not signed in")
		NeedsSession => (403, "channels are an admin's to change, by their own session; a key never changes one")
		NoSuchPrincipal => (403, "your account is gone")
		NotAdmin => (403, "only an admin makes a channel or changes who is in one")
		NotAChannelName => (400, "a channel's name is a letter, then letters, digits and hyphens, at most 40")
		Taken => (409, "a channel of that name is there already, in some spelling")
		NamedTwice(id) => (400, "${AccountCodec.id_text(id)} is named twice")
		NotAHuman(id) => (400, "${AccountCodec.id_text(id)} is no human: a channel's members are humans")
		NoAccount(id) => (400, "no account is ${AccountCodec.id_text(id)}")
		AlreadyIn(id) => (409, "${AccountCodec.id_text(id)} is in the channel already")
		NotIn(id) => (409, "${AccountCodec.id_text(id)} is not in the channel")
		NoSuchChannel => (404, "no such channel")
	}

## A refusal's word in its audit line (a signed-out one is never written).
word_of : Refusal -> AuditCodec.ChannelRefusal
word_of = |why|
	match why {
		SignedOut | NeedsSession => NeedsSession
		NoSuchPrincipal => NoSuchPrincipal
		NotAdmin => NotAdmin
		NotAChannelName => NotAChannelName
		Taken => Taken
		NamedTwice(_) => NamedTwice
		NotAHuman(_) => NotAHuman
		NoAccount(_) => NoAccount
		AlreadyIn(_) => AlreadyIn
		NotIn(_) => NotIn
		NoSuchChannel => NoSuchChannel
	}

## The change audited, when the asker is named.
audit! : Asker, Event => {}
audit! = |asker, event|
	match asker.audit {
		Unaudited => {}
		As(named) =>
			append_audit!({
				at: asker.now,
				who: named.who,
				via: named.via,
				action: event.action,
				channel: event.channel,
				members: event.members,
				verdict: event.verdict,
			})
	}

## A channel's event, appended to the audit.
append_audit! : AuditCodec.ChannelEvent => {}
append_audit! = |event|
	match AuditCodec.Entry.of_channel(event) {
		Ok(entry) => Store.append_audit!(entry)
		Err(ClockOutOfRange) => {}
	}

## **THE MEMBERS A MAKE NAMES**: `members=`, ids with commas between;
## none when the field is missing or empty.
asked_members : List(U8) -> Try(List(Principal.Id), Str)
asked_members = |form|
	match SignInWeb.form_field(form, "members") {
		Err(Missing) => Ok([])
		Ok([]) => Ok([])
		Ok(text) => text.split_on(',').map_try(|id| AccountCodec.id_from(id, "members")).map_err(|_| members_problem)
		Err(Malformed) => Err(members_problem)
	}

members_problem : Str
members_problem = "`members` is humans' ids, commas between, as `human:2,human:7`"

## **THE MEMBER AN ADMIT OR A REMOVE NAMES**: `member=`, one id.
asked_member : List(U8) -> Try(Principal.Id, Str)
asked_member = |form|
	match SignInWeb.form_field(form, "member") {
		Ok(text) => AccountCodec.id_from(text, "member").map_err(|_| member_problem)
		Err(_) => Err(member_problem)
	}

member_problem : Str
member_problem = "`member` is a human's id, as `human:2`"

## The channels' order on the page: by their names' keys, byte by byte.
by_name_key : Channel,
Channel -> [
	Before,
	Same,
	After,
]
by_name_key = |a, b| compare_bytes(a.name().key().to_utf8(), b.name().key().to_utf8())

## The name a path's part spells, when the rule takes it.
name_in_path : List(U8) -> Try(ChannelName, [NotChannels])
name_in_path = |part|
	match Str.from_utf8(part) {
		Ok(text) => ChannelName.from_str(text).map_err(|_| NotChannels)
		Err(_) => Err(NotChannels)
	}

## Two byte strings' order, byte by byte, a prefix first.
compare_bytes : List(U8),
List(U8) -> [
	Before,
	Same,
	After,
]
compare_bytes = |x, y|
	match (x, y) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([a, .. as xs], [b, .. as ys]) =>
			if a < b {
				Before
			} else if a > b {
				After
			} else {
				compare_bytes(xs, ys)
			}
	}

expect Channels.route("/channels".to_utf8()) == Ok(Make)
expect ChannelName.from_str("lobby").map_ok(|n| Channels.route("/channels/Lobby/admit".to_utf8()) == Ok(Admit(n))) == Ok(Bool.True)
expect Channels.route("/channels/Lobby/remove".to_utf8()).is_ok()
expect Channels.route("/channels/1st/admit".to_utf8()) == Err(NotChannels)
expect Channels.route("/channels/Lobby/rename".to_utf8()) == Err(NotChannels)
expect Channels.route("/channels/Lobby".to_utf8()) == Err(NotChannels)
expect Channels.route("/channelsx".to_utf8()) == Err(NotChannels)
expect asked_members("name=x".to_utf8()) == Ok([])
expect asked_members("members=".to_utf8()) == Ok([])
expect asked_members("members=human%3A2%2Chuman%3A7".to_utf8()).map_ok(|l| l.len()) == Ok(2)
expect asked_members("members=human%3A2%2C".to_utf8()) == Err(members_problem)
expect asked_member("member=bob".to_utf8()) == Err(member_problem)
expect compare_bytes("general".to_utf8(), "lobby".to_utf8()) == Before
expect compare_bytes("lobby".to_utf8(), "lobby-2".to_utf8()) == Before
expect compare_bytes("lobby".to_utf8(), "lobby".to_utf8()) == Same
expect compare_bytes("m".to_utf8(), "lobby".to_utf8()) == After

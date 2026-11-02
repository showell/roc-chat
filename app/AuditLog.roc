## **THE AUDIT LOG, STORED** (the Roc chat's auth design, section 9): one
## line in Stored's format for every sign-in refused, and for every key
## refused, in use or in its grant:
##
##     audit-sign-in v1 at=1761600090 github=583231 verdict=refused:state-expired
##     audit-key v1 at=1761600095 who=agent:7 via=key:4 action=read:3 verdict=refused:out-of-scope
##     audit-key v1 at=1761600099 who=human:2 via=session:12 action=grant:agent:3 verdict=refused:not-the-granters-own
##     audit-invite v1 at=1761600100 invite=3 for=agent:7 verdict=created:session:12
##     audit-invite v1 at=1761600160 invite=3 for=agent:7 verdict=redeemed:key:9
##     audit-invite v1 at=1761600170 invite=unknown for=unknown verdict=refused:unknown
##     audit-human-invite v1 at=1761600180 invite=3 for=human:100 verdict=created:human:2
##     audit-human-invite v1 at=1761600190 invite=3 for=human:100 verdict=redeemed:session:9
##     audit-channel v1 at=1761600200 who=human:1 via=session:3 action=make channel=Lobby members=human:2,human:7 verdict=permitted
##     audit-channel v1 at=1761600210 who=human:2 via=session:12 action=admit channel=Lobby members=human:9 verdict=refused:not-admin
##     audit-rename v1 at=1761600300 who=human:1 via=session:3 agent=agent:1 verdict=permitted name=LC
##     audit-rename v1 at=1761600310 who=human:2 via=session:12 agent=agent:1 verdict=refused:not-the-owner name=Mine
##
## And for every rename of an agent or a bot (Agents.rename), permitted or
## refused: the agent, the verdict, and the name asked last, as free text
## (empty when the name rule refused it). A signed-out asker is never
## audited.
##
## And for every admin's change to a channel (Channel.roc), permitted or
## refused: making one, admitting a member, removing one; the channel by
## its name (empty when the name asked is no channel's name), the members
## it names (a make's, or the one admitted or removed; empty for none),
## and the verdict, a key's refusal after `key:` as in an admin line. A
## signed-out asker names no one, and is never audited.
##
## And for every invite (AgentInvite): made, redeemed into a key (its public
## id), revoked, or a redemption refused, `grant:` and a grant's word when
## the grant decided again refused it.
##
## And for every human invite (HumanInvite): made for a new human, or
## again for one (`reinvited`), by whom; redeemed into a session (its
## public number); revoked, by whom; or a redemption refused. Never the
## code, nor its hash.
##
## Who (a principal's id, as AccountCodec spells it), by which session or
## key (its public number), what, when, and the verdict, each spelled once:
## an action as a word and its target after a colon, a refusal as a word (a
## key's after `key:` in an admin line), a plan as its steps, commas
## between (`none` for no step). **No secret is in any record**: no token,
## hash, cookie, nonce, OAuth code or login, only public numbers and words;
## a sign-in refused before GitHub named anyone is `github=unknown`.
##
## **AN ENTRY IS OPAQUE**, made only by `of_sign_in`, `of_key`,
## `of_invite`, `of_human_invite`, `of_channel` and `of_rename`, which refuse a time outside Stored's range (ClockOutOfRange),
## or by `decode`: the encoder never meets a time it cannot write. Pure.
import AccountCodec
import ApiKey
import Bytes
import Cast
import ChannelName
import GitHubSignIn
import HumanInvite
import HumanInviteCodec
import AgentInvite
import Principal
import Stored

AuditLog := [].{

	## A sign-in refused: when, the GitHub id when GitHub had named one, and
	## why.
	SignIn : {
		at : I64,
		github : [Unknown, Known(Principal.HumanId)],
		refusal : GitHubSignIn.Refusal,
	}

	## A key refused: in use (a read or a post of a resource, by its
	## number), by the principal it acts as; or in its grant, by the
	## granter (a session's human, or a key's principal), for the principal
	## the key would act as.
	KeyEvent : [
		Use(
			{
				at : I64,
				who : Principal.Id,
				key : Principal.KeyId,
				refusal : ApiKey.Refusal,
			},
		),
		Grant(
			{
				at : I64,
				who : Principal.Id,
				via : [Session(Principal.SessionId), Key(Principal.KeyId)],
				acts_as : Principal.Id,
				refusal : ApiKey.GrantRefusal,
			},
		),
	]

	## **AN INVITE'S LIFE**: when, the invite (unknown when no invite's
	## hash is the code's, or the code was never looked up), and what
	## happened: made by a session, redeemed into a key, revoked by a
	## session, or a redemption refused.
	Invite : {
		at : I64,
		invite : [Unknown, Known({ id : AgentInvite.InviteId, agent : Principal.Id })],
		verdict : [
			Created([Session(Principal.SessionId), Key(Principal.KeyId)]),
			Redeemed(Principal.KeyId),
			Revoked(Principal.SessionId),
			Refused(AgentInvite.Refusal),
		],
	}

	## **A HUMAN INVITE'S EVENT**: when, which invite and whom it is for
	## (both unknown when no invite's hash is the code's), and what
	## happened: made by a human for a new human, or again; redeemed into
	## a session; revoked by its maker; or a redemption refused.
	HumanInviteEvent : {
		at : I64,
		invite : [Unknown, Known({ id : HumanInvite.InviteId, human : Principal.HumanId })],
		verdict : [
			Created(Principal.HumanId),
			Reinvited(Principal.HumanId),
			Redeemed(Principal.SessionId),
			Revoked(Principal.HumanId),
			Refused(HumanInvite.Refusal),
		],
	}

	## **AN ADMIN'S CHANGE TO A CHANNEL, OR ITS REFUSAL**: when, who by
	## which session or key, what (a channel made, a member admitted or
	## removed), the channel (`Unnamed` when the name asked is no channel's
	## name), the members it names, and the verdict.
	ChannelEvent : {
		at : I64,
		who : Principal.Id,
		via : [Session(Principal.SessionId), Key(Principal.KeyId)],
		action : AuditLog.ChannelAction,
		channel : [Named(ChannelName), Unnamed],
		members : List(Principal.Id),
		verdict : [Permitted, Refused(AuditLog.ChannelRefusal)],
	}

	## What an admin did to a channel.
	ChannelAction : [
		Make,
		Admit,
		Remove,
	]

	## **WHY A CHANNEL'S CHANGE WAS REFUSED**: Channel's refusals of a
	## named asker, its name and its members (each without the id the
	## line's `members` holds); a channel that is not there; or the key
	## asking not standing (ApiKey's word).
	ChannelRefusal : [
		NeedsSession,
		NoSuchPrincipal,
		NotAdmin,
		NotAChannelName,
		Taken,
		NamedTwice,
		NotAHuman,
		NoAccount,
		AlreadyIn,
		NotIn,
		NoSuchChannel,
		KeyRefused(ApiKey.Refusal),
	]

	## **AN AGENT'S OR BOT'S RENAME, OR ITS REFUSAL**: when, who by which
	## session or key, the agent, the verdict, and the name asked (empty
	## for one the name rule refused, which may be anything).
	RenameEvent : {
		at : I64,
		who : Principal.Id,
		via : [Session(Principal.SessionId), Key(Principal.KeyId)],
		agent : Principal.Id,
		verdict : [Permitted, Refused(AuditLog.RenameRefusal)],
		name : Str,
	}

	## **WHY A RENAME WAS REFUSED** (Agents.RenameRefusal, its words): by a
	## key; not the owner's; no such agent; the name taken; or no name the
	## rule takes.
	RenameRefusal : [
		NeedsSession,
		NotTheOwner,
		NoSuchAgent,
		NameTaken,
		NotAName,
	]

	## **ONE LINE OF THE AUDIT LOG**, the log's entry. Opaque: its time
	## always in Stored's range.
	Entry :: [
		SignIn(AuditLog.SignIn),
		Key(AuditLog.KeyEvent),
		Invite(AuditLog.Invite),
		HumanInvite(AuditLog.HumanInviteEvent),
		Channel(AuditLog.ChannelEvent),
		Rename(AuditLog.RenameEvent),
	].{

		## A refused sign-in's.
		of_sign_in : AuditLog.SignIn -> Try(AuditLog.Entry, [ClockOutOfRange])
		of_sign_in = |s| if (is_storable(s.at)) Ok(AuditLog.Entry.(SignIn(s))) else Err(ClockOutOfRange)

		## A refused key's, in use or in its grant.
		of_key : AuditLog.KeyEvent -> Try(AuditLog.Entry, [ClockOutOfRange])
		of_key = |e| {
			at =
				match e {
					Use(u) => u.at
					Grant(g) => g.at
				}
			if (is_storable(at)) Ok(AuditLog.Entry.(Key(e))) else Err(ClockOutOfRange)
		}

		## An invite's.
		of_invite : AuditLog.Invite -> Try(AuditLog.Entry, [ClockOutOfRange])
		of_invite = |i| if (is_storable(i.at)) Ok(AuditLog.Entry.(Invite(i))) else Err(ClockOutOfRange)

		## A human invite's.
		of_human_invite : AuditLog.HumanInviteEvent -> Try(AuditLog.Entry, [ClockOutOfRange])
		of_human_invite = |i| if (is_storable(i.at)) Ok(AuditLog.Entry.(HumanInvite(i))) else Err(ClockOutOfRange)

		## A channel's change, or its refusal.
		of_channel : AuditLog.ChannelEvent -> Try(AuditLog.Entry, [ClockOutOfRange])
		of_channel = |c| if (is_storable(c.at)) Ok(AuditLog.Entry.(Channel(c))) else Err(ClockOutOfRange)

		## A rename, or its refusal. Its name is free text, which may hold
		## no newline (no line could hold it): one that does is written
		## empty.
		of_rename : AuditLog.RenameEvent -> Try(AuditLog.Entry, [ClockOutOfRange])
		of_rename = |r| {
			name = if (r.name.to_utf8().contains('\n') or r.name.to_utf8().contains('\r')) "" else r.name
			if (is_storable(r.at)) Ok(
				AuditLog.Entry.(
					Rename({
						..r,
						name,
					}),
				),
			) else Err(ClockOutOfRange)
		}

		## What the entry records.
		event : AuditLog.Entry -> [
			SignIn(AuditLog.SignIn),
			Key(AuditLog.KeyEvent),
			Invite(AuditLog.Invite),
			HumanInvite(AuditLog.HumanInviteEvent),
			Channel(AuditLog.ChannelEvent),
			Rename(AuditLog.RenameEvent),
		]
		event = |AuditLog.Entry.(e)| e

		is_eq : _
	}

	## **A REFUSED SIGN-IN'S REASON, AS THE AUDIT SPELLS IT**: the one
	## spelling, which the refusal page shows too.
	sign_in_refusal_text : GitHubSignIn.Refusal -> Str
	sign_in_refusal_text = |why| spell_sign_in_refusal(why)

	## The entry's line.
	encode : AuditLog.Entry -> List(U8)
	encode = |AuditLog.Entry.(e)|
		match e {
			SignIn(s) =>
				Stored.line(
					sign_in_kind,
					[
						("at", Stored.time_text(s.at)),
						("github", github_text(s.github)),
						("verdict", "${refused_prefix}${spell_sign_in_refusal(s.refusal)}"),
					],
				)

			Key(Use(u)) =>
				Stored.line(
					key_kind,
					[
						("at", Stored.time_text(u.at)),
						("who", AccountCodec.id_text(u.who)),
						("via", via_text(Key(u.key))),
						("action", use_word),
						("verdict", "${refused_prefix}${spell_key_refusal(u.refusal)}"),
					],
				)

			Key(Grant(g)) =>
				Stored.line(
					key_kind,
					[
						("at", Stored.time_text(g.at)),
						("who", AccountCodec.id_text(g.who)),
						("via", via_text(g.via)),
						("action", "${grant_word}${colon}${AccountCodec.id_text(g.acts_as)}"),
						("verdict", "${refused_prefix}${spell_grant_refusal(g.refusal)}"),
					],
				)

			Invite(i) => {
				(invite, agent) =
					match i.invite {
						Unknown => (unknown_word, unknown_word)
						Known(k) => (k.id.to_u64().to_str(), AccountCodec.id_text(k.agent))
					}
				Stored.line(
					invite_kind,
					[
						("at", Stored.time_text(i.at)),
						("invite", invite),
						("for", agent),
						("verdict", invite_verdict_text(i.verdict)),
					],
				)
			}

			HumanInvite(i) => {
				(invite, human) =
					match i.invite {
						Unknown => (unknown_word, unknown_word)
						Known(k) => (
							k.id.to_u64().to_str(),
							AccountCodec.id_text(Principal.Id.Human(k.human)),
						)
					}
				Stored.line(
					human_invite_kind,
					[
						("at", Stored.time_text(i.at)),
						("invite", invite),
						("for", human),
						("verdict", human_invite_verdict_text(i.verdict)),
					],
				)
			}

			Channel(c) =>
				Stored.line(
					channel_kind,
					[
						("at", Stored.time_text(c.at)),
						("who", AccountCodec.id_text(c.who)),
						("via", via_text(c.via)),
						("action", spell_channel_action(c.action)),
						("channel", channel_text(c.channel)),
						("members", Str.join_with(c.members.map(AccountCodec.id_text), ",")),
						("verdict", channel_verdict_text(c.verdict)),
					],
				)

			Rename(r) =>
				Stored.line(
					rename_kind,
					[
						("at", Stored.time_text(r.at)),
						("who", AccountCodec.id_text(r.who)),
						("via", via_text(r.via)),
						("agent", AccountCodec.id_text(r.agent)),
						("verdict", rename_verdict_text(r.verdict)),
						("name", r.name),
					],
				)
		}

	## The entry a line holds, of whichever kind its first word names.
	decode : List(U8) -> Try(AuditLog.Entry, _)
	decode = |raw|
		match Stored.Reader.open(raw, sign_in_kind) {
			Ok(fields) => decode_sign_in(fields).map_ok(|s| AuditLog.Entry.(SignIn(s)))
			Err(WrongRecord) =>
				match Stored.Reader.open(raw, key_kind) {
					Ok(fields) => decode_key(fields).map_ok(|k| AuditLog.Entry.(Key(k)))
					Err(WrongRecord) =>
						match Stored.Reader.open(raw, invite_kind) {
							Ok(fields) => decode_invite(fields).map_ok(|i| AuditLog.Entry.(Invite(i)))
							Err(WrongRecord) => decode_later(raw)
							Err(why) => Err(why)
						}
					Err(why) => Err(why)
				}
			Err(why) => Err(why)
		}
}

## The entry a line of a later kind holds: a human invite's, a channel's
## or a rename's.
decode_later : List(U8) -> Try(AuditLog.Entry, _)
decode_later = |raw|
	match Stored.Reader.open(raw, human_invite_kind) {
		Ok(fields) => decode_human_invite(fields).map_ok(|i| AuditLog.Entry.(HumanInvite(i)))
		Err(WrongRecord) =>
			match Stored.Reader.open(raw, channel_kind) {
				Ok(fields) => decode_channel(fields).map_ok(|c| AuditLog.Entry.(Channel(c)))
				Err(WrongRecord) => {
					fields = Stored.Reader.open(raw, rename_kind)?
					decode_rename(fields).map_ok(|r| AuditLog.Entry.(Rename(r)))
				}
				Err(why) => Err(why)
			}
		Err(why) => Err(why)
	}

## The lines' first words.
sign_in_kind : Str
sign_in_kind = "audit-sign-in"

key_kind : Str
key_kind = "audit-key"

invite_kind : Str
invite_kind = "audit-invite"

human_invite_kind : Str
human_invite_kind = "audit-human-invite"

channel_kind : Str
channel_kind = "audit-channel"

rename_kind : Str
rename_kind = "audit-rename"

all_rename_refusals : List(AuditLog.RenameRefusal)
all_rename_refusals = [
	NeedsSession,
	NotTheOwner,
	NoSuchAgent,
	NameTaken,
	NotAName,
]

spell_rename_refusal : AuditLog.RenameRefusal -> Str
spell_rename_refusal = |why|
	match why {
		NeedsSession => "needs-session"
		NotTheOwner => "not-the-owner"
		NoSuchAgent => "no-such-agent"
		NameTaken => "name-taken"
		NotAName => "not-a-name"
	}

## `permitted`, or `refused:` and the refusal's word.
rename_verdict_text : [Permitted, Refused(AuditLog.RenameRefusal)] -> Str
rename_verdict_text = |verdict|
	match verdict {
		Permitted => permitted_word
		Refused(why) => "${refused_prefix}${spell_rename_refusal(why)}"
	}

rename_verdict_from : List(U8) -> Try([Permitted, Refused(AuditLog.RenameRefusal)], _)
rename_verdict_from = |value|
	if value == Str.to_utf8(permitted_word) {
		Ok(Permitted)
	} else {
		match Bytes.strip_prefix(value, Str.to_utf8(refused_prefix)) {
			Err(NoMatch) => Err(UnknownWord("verdict"))
			Ok(why) =>
				Stored.word(
					why,
					{
						name: "verdict",
						members: all_rename_refusals,
						spell: spell_rename_refusal,
					},
				).map_ok(|w| Refused(w))
		}
	}

decode_rename : Stored.Reader -> Try(AuditLog.RenameEvent, _)
decode_rename = |fields| {
	at_field = fields.field("at")?
	at = Stored.time(at_field.value, "at")?
	who_field = at_field.rest.field("who")?
	who = AccountCodec.id_from(who_field.value, "who")?
	via_field = who_field.rest.field("via")?
	via = via_from(via_field.value)?
	agent_field = via_field.rest.field("agent")?
	agent = AccountCodec.id_from(agent_field.value, "agent")?
	verdict_field = agent_field.rest.field("verdict")?
	verdict = rename_verdict_from(verdict_field.value)?
	name = verdict_field.rest.text("name")?
	Ok({
		at,
		who,
		via,
		agent,
		verdict,
		name,
	})
}

all_channel_actions : List(AuditLog.ChannelAction)
all_channel_actions = [
	Make,
	Admit,
	Remove,
]

spell_channel_action : AuditLog.ChannelAction -> Str
spell_channel_action = |action|
	match action {
		Make => "make"
		Admit => "admit"
		Remove => "remove"
	}

## The channel's name as it was made; empty for a name the rule refused.
channel_text : [Named(ChannelName), Unnamed] -> Str
channel_text = |channel|
	match channel {
		Named(name) => name.to_str()
		Unnamed => ""
	}

channel_from : List(U8) -> Try([Named(ChannelName), Unnamed], _)
channel_from = |value|
	if value.is_empty() {
		Ok(Unnamed)
	} else {
		match Str.from_utf8(value) {
			Ok(text) => ChannelName.from_stored(text).map_ok(|n| Named(n)).map_err(|_| BadValue("channel"))
			Err(_) => Err(BadValue("channel"))
		}
	}

## A channel's refusal's word, without a key's.
ChannelWord : [
	NeedsSession,
	NoSuchPrincipal,
	NotAdmin,
	NotAChannelName,
	Taken,
	NamedTwice,
	NotAHuman,
	NoAccount,
	AlreadyIn,
	NotIn,
	NoSuchChannel,
]

all_channel_words : List(ChannelWord)
all_channel_words = [
	NeedsSession,
	NoSuchPrincipal,
	NotAdmin,
	NotAChannelName,
	Taken,
	NamedTwice,
	NotAHuman,
	NoAccount,
	AlreadyIn,
	NotIn,
	NoSuchChannel,
]

spell_channel_word : ChannelWord -> Str
spell_channel_word = |word|
	match word {
		NeedsSession => "needs-session"
		NoSuchPrincipal => "no-such-principal"
		NotAdmin => "not-admin"
		NotAChannelName => "not-a-channel-name"
		Taken => "taken"
		NamedTwice => "named-twice"
		NotAHuman => "not-a-human"
		NoAccount => "no-account"
		AlreadyIn => "already-in"
		NotIn => "not-in"
		NoSuchChannel => "no-such-channel"
	}

## `permitted`, or `refused:` and the refusal's word (`refused:key:` and a
## key's).
channel_verdict_text : [Permitted, Refused(AuditLog.ChannelRefusal)] -> Str
channel_verdict_text = |verdict|
	match verdict {
		Permitted => permitted_word
		Refused(KeyRefused(why)) => "${refused_prefix}${key_prefix}${spell_key_refusal(why)}"
		Refused(NeedsSession) => "${refused_prefix}${spell_channel_word(NeedsSession)}"
		Refused(NoSuchPrincipal) => "${refused_prefix}${spell_channel_word(NoSuchPrincipal)}"
		Refused(NotAdmin) => "${refused_prefix}${spell_channel_word(NotAdmin)}"
		Refused(NotAChannelName) => "${refused_prefix}${spell_channel_word(NotAChannelName)}"
		Refused(Taken) => "${refused_prefix}${spell_channel_word(Taken)}"
		Refused(NamedTwice) => "${refused_prefix}${spell_channel_word(NamedTwice)}"
		Refused(NotAHuman) => "${refused_prefix}${spell_channel_word(NotAHuman)}"
		Refused(NoAccount) => "${refused_prefix}${spell_channel_word(NoAccount)}"
		Refused(AlreadyIn) => "${refused_prefix}${spell_channel_word(AlreadyIn)}"
		Refused(NotIn) => "${refused_prefix}${spell_channel_word(NotIn)}"
		Refused(NoSuchChannel) => "${refused_prefix}${spell_channel_word(NoSuchChannel)}"
	}

channel_verdict_from : List(U8) -> Try([Permitted, Refused(AuditLog.ChannelRefusal)], _)
channel_verdict_from = |value|
	if value == Str.to_utf8(permitted_word) {
		Ok(Permitted)
	} else {
		match Bytes.strip_prefix(value, Str.to_utf8(refused_prefix)) {
			Err(NoMatch) => Err(UnknownWord("verdict"))
			Ok(why) =>
				match Bytes.strip_prefix(why, Str.to_utf8(key_prefix)) {
					Ok(key_why) =>
						Stored.word(
							key_why,
							{
								name: "verdict",
								members: all_key_refusals,
								spell: spell_key_refusal,
							},
						).map_ok(|w| Refused(KeyRefused(w)))
					Err(NoMatch) =>
						match Stored.word(
							why,
							{
								name: "verdict",
								members: all_channel_words,
								spell: spell_channel_word,
							},
						)? {
							NeedsSession => Ok(Refused(NeedsSession))
							NoSuchPrincipal => Ok(Refused(NoSuchPrincipal))
							NotAdmin => Ok(Refused(NotAdmin))
							NotAChannelName => Ok(Refused(NotAChannelName))
							Taken => Ok(Refused(Taken))
							NamedTwice => Ok(Refused(NamedTwice))
							NotAHuman => Ok(Refused(NotAHuman))
							NoAccount => Ok(Refused(NoAccount))
							AlreadyIn => Ok(Refused(AlreadyIn))
							NotIn => Ok(Refused(NotIn))
							NoSuchChannel => Ok(Refused(NoSuchChannel))
						}
				}
		}
	}

decode_channel : Stored.Reader -> Try(AuditLog.ChannelEvent, _)
decode_channel = |fields| {
	at_field = fields.field("at")?
	at = Stored.time(at_field.value, "at")?
	who_field = at_field.rest.field("who")?
	who = AccountCodec.id_from(who_field.value, "who")?
	via_field = who_field.rest.field("via")?
	via = via_from(via_field.value)?
	action_field = via_field.rest.field("action")?
	action = Stored.word(
		action_field.value,
		{
			name: "action",
			members: all_channel_actions,
			spell: spell_channel_action,
		},
	)?
	channel_field = action_field.rest.field("channel")?
	channel = channel_from(channel_field.value)?
	members_field = channel_field.rest.field("members")?
	members =
		if members_field.value.is_empty() {
			[]
		} else {
			members_field.value.split_on(',').map_try(|v| AccountCodec.id_from(v, "members"))?
		}
	verdict_field = members_field.rest.field("verdict")?
	verdict = channel_verdict_from(verdict_field.value)?
	verdict_field.rest.close()?
	Ok({
		at,
		who,
		via,
		action,
		channel,
		members,
		verdict,
	})
}

## `created:session:12`, `redeemed:key:9`, `revoked:session:12`, or
## `refused:` and AgentInvite's word.
invite_verdict_text : [
	Created([Session(Principal.SessionId), Key(Principal.KeyId)]),
	Redeemed(Principal.KeyId),
	Revoked(Principal.SessionId),
	Refused(AgentInvite.Refusal),
] -> Str
invite_verdict_text = |verdict|
	match verdict {
		Created(via) => "${spell_invite_act(Created)}${colon}${via_text(via)}"
		Redeemed(k) => "${spell_invite_act(Redeemed)}${colon}${via_text(Key(k))}"
		Revoked(s) => "${spell_invite_act(Revoked)}${colon}${via_text(Session(s))}"
		Refused(why) => "${refused_prefix}${AgentInvite.refusal_text(why, spell_grant_refusal)}"
	}

InviteAct : [
	Created,
	Redeemed,
	Revoked,
]

all_invite_acts : List(InviteAct)
all_invite_acts = [
	Created,
	Redeemed,
	Revoked,
]

spell_invite_act : InviteAct -> Str
spell_invite_act = |act|
	match act {
		Created => "created"
		Redeemed => "redeemed"
		Revoked => "revoked"
	}

invite_verdict_from : List(U8) -> Try(
	[
		Created([Session(Principal.SessionId), Key(Principal.KeyId)]),
		Redeemed(Principal.KeyId),
		Revoked(Principal.SessionId),
		Refused(AgentInvite.Refusal),
	],
	_,
)
invite_verdict_from = |value|
	match Bytes.strip_prefix(value, Str.to_utf8(refused_prefix)) {
		Ok(why) => AgentInvite.refusal_from(
			why,
			|g| Stored.word(
				g,
				{
					name: "verdict",
					members: all_grant_refusals,
					spell: spell_grant_refusal,
				},
			),
		).map_ok(|r| Refused(r))
		Err(NoMatch) => {
			{ head, tail } = split_colon(value, "verdict")?
			act = Stored.word(
				head,
				{
					name: "verdict",
					members: all_invite_acts,
					spell: spell_invite_act,
				},
			)?
			via = via_from(tail)?
			match (act, via) {
				(Created, v) => Ok(Created(v))
				(Revoked, Session(s)) => Ok(Revoked(s))
				(Redeemed, Key(k)) => Ok(Redeemed(k))
				_ => Err(BadValue("verdict"))
			}
		}
	}

HumanInviteAct : [
	Created,
	Reinvited,
	Redeemed,
	Revoked,
]

all_human_invite_acts : List(HumanInviteAct)
all_human_invite_acts = [
	Created,
	Reinvited,
	Redeemed,
	Revoked,
]

spell_human_invite_act : HumanInviteAct -> Str
spell_human_invite_act = |act|
	match act {
		Created => "created"
		Reinvited => "reinvited"
		Redeemed => "redeemed"
		Revoked => "revoked"
	}

human_invite_verdict_text : [
	Created(Principal.HumanId),
	Reinvited(Principal.HumanId),
	Redeemed(Principal.SessionId),
	Revoked(Principal.HumanId),
	Refused(HumanInvite.Refusal),
] -> Str
human_invite_verdict_text = |verdict| {
	by = |
		act,
		h,
	| "${spell_human_invite_act(act)}${colon}${AccountCodec.id_text(Principal.Id.Human(h))}"
	match verdict {
		Created(h) => by(Created, h)
		Reinvited(h) => by(Reinvited, h)
		Revoked(h) => by(Revoked, h)
		Redeemed(s) => "${spell_human_invite_act(Redeemed)}${colon}${via_text(Session(s))}"
		Refused(why) => "${refused_prefix}${HumanInviteCodec.refusal_text(why)}"
	}
}

human_invite_verdict_from : List(U8) -> Try(
	[
		Created(Principal.HumanId),
		Reinvited(Principal.HumanId),
		Redeemed(Principal.SessionId),
		Revoked(Principal.HumanId),
		Refused(HumanInvite.Refusal),
	],
	_,
)
human_invite_verdict_from = |value|
	match Bytes.strip_prefix(value, Str.to_utf8(refused_prefix)) {
		Ok(why) => HumanInviteCodec.refusal_from(why).map_ok(|r| Refused(r))
		Err(NoMatch) => {
			{ head, tail } = split_colon(value, "verdict")?
			act = Stored.word(
				head,
				{
					name: "verdict",
					members: all_human_invite_acts,
					spell: spell_human_invite_act,
				},
			)?
			match act {
				Redeemed =>
					match via_from(tail)? {
						Session(s) => Ok(Redeemed(s))
						Key(_) => Err(BadValue("verdict"))
					}
				_ =>
					match (act, AccountCodec.id_from(tail, "verdict")?) {
						(Created, Human(h)) => Ok(Created(h))
						(Reinvited, Human(h)) => Ok(Reinvited(h))
						(Revoked, Human(h)) => Ok(Revoked(h))
						_ => Err(BadValue("verdict"))
					}
			}
		}
	}

decode_human_invite : Stored.Reader -> Try(AuditLog.HumanInviteEvent, _)
decode_human_invite = |fields| {
	at_field = fields.field("at")?
	at = Stored.time(at_field.value, "at")?
	invite_field = at_field.rest.field("invite")?
	for_field = invite_field.rest.field("for")?
	verdict_field = for_field.rest.field("verdict")?
	verdict = human_invite_verdict_from(verdict_field.value)?
	verdict_field.rest.close()?
	invite = human_invite_from(invite_field.value, for_field.value)?
	Ok({
		at,
		invite,
		verdict,
	})
}

## Both `unknown`, or a human invite's id and the human it is for.
human_invite_from : List(U8),
List(U8) -> Try(
	[Unknown, Known({ id : HumanInvite.InviteId, human : Principal.HumanId })],
	_,
)
human_invite_from = |invite_value, for_value| {
	unknown = Str.to_utf8(unknown_word)
	if invite_value == unknown and for_value == unknown {
		Ok(Unknown)
	} else if invite_value == unknown or for_value == unknown {
		Err(BadValue("for"))
	} else {
		id = Stored.id(invite_value, { name: "invite", make: HumanInvite.InviteId.from_u64 })?
		match AccountCodec.id_from(for_value, "for")? {
			Human(h) => Ok(Known({ id, human: h }))
			_ => Err(BadValue("for"))
		}
	}
}

decode_invite : Stored.Reader -> Try(AuditLog.Invite, _)
decode_invite = |fields| {
	at_field = fields.field("at")?
	at = Stored.time(at_field.value, "at")?
	invite_field = at_field.rest.field("invite")?
	for_field = invite_field.rest.field("for")?
	verdict_field = for_field.rest.field("verdict")?
	verdict = invite_verdict_from(verdict_field.value)?
	verdict_field.rest.close()?
	invite = invite_from(invite_field.value, for_field.value)?
	Ok({
		at,
		invite,
		verdict,
	})
}

## Both `unknown`, or an invite's id and whom it is for: never one of each.
invite_from : List(U8),
List(U8) -> Try(
	[Unknown, Known({ id : AgentInvite.InviteId, agent : Principal.Id })],
	_,
)
invite_from = |invite_value, for_value| {
	unknown = Str.to_utf8(unknown_word)
	if invite_value == unknown and for_value == unknown {
		Ok(Unknown)
	} else if invite_value == unknown or for_value == unknown {
		Err(BadValue("for"))
	} else {
		id = Stored.id(invite_value, { name: "invite", make: AgentInvite.InviteId.from_u64 })?
		agent = AccountCodec.id_from(for_value, "for")?
		Ok(Known({ id, agent }))
	}
}

## A time Stored can write.
is_storable : I64 -> Bool
is_storable = |t| t >= 0 and t <= Stored.max_time

decode_sign_in : Stored.Reader -> Try(AuditLog.SignIn, _)
decode_sign_in = |fields| {
	at_field = fields.field("at")?
	at = Stored.time(at_field.value, "at")?
	github_field = at_field.rest.field("github")?
	github = github_from(github_field.value)?
	verdict_field = github_field.rest.field("verdict")?
	refusal = refused_word(
		verdict_field.value,
		{ members: all_sign_in_refusals, spell: spell_sign_in_refusal },
	)?
	verdict_field.rest.close()?
	Ok({
		at,
		github,
		refusal,
	})
}

decode_key : Stored.Reader -> Try(AuditLog.KeyEvent, _)
decode_key = |fields| {
	at_field = fields.field("at")?
	at = Stored.time(at_field.value, "at")?
	who_field = at_field.rest.field("who")?
	who = AccountCodec.id_from(who_field.value, "who")?
	via_field = who_field.rest.field("via")?
	via = via_from(via_field.value)?
	action_field = via_field.rest.field("action")?
	verdict_field = action_field.rest.field("verdict")?
	verdict_field.rest.close()?
	if action_field.value != Str.to_utf8(use_word) {
		{ head, tail } = split_colon(action_field.value, "action")?
		acts_as =
			if (head == Str.to_utf8(grant_word)) AccountCodec.id_from(tail, "action")? else Err(UnknownWord("action"))?
		refusal = refused_word(
			verdict_field.value,
			{ members: all_grant_refusals, spell: spell_grant_refusal },
		)?
		Ok(
			Grant({
				at,
				who,
				via,
				acts_as,
				refusal,
			}),
		)
	} else {
		key =
			match via {
				Key(k) => Ok(k)
				Session(_) => Err(BadValue("via"))
			}?
		refusal = refused_word(
			verdict_field.value,
			{ members: all_key_refusals, spell: spell_key_refusal },
		)?
		Ok(
			Use({
				at,
				who,
				key,
				refusal,
			}),
		)
	}
}

## `refused:` and a word of the closed set, in a `verdict` field.
refused_word : List(U8), { members : List(a), spell : (a -> Str) } -> Try(a, _)
refused_word = |value, { members, spell }|
	match Bytes.strip_prefix(value, Str.to_utf8(refused_prefix)) {
		Err(NoMatch) => Err(UnknownWord("verdict"))
		Ok(why) => Stored.word(
			why,
			{
				name: "verdict",
				members,
				spell,
			},
		)
	}

## `unknown`, or the GitHub id.
github_text : [Unknown, Known(Principal.HumanId)] -> Str
github_text = |github|
	match github {
		Unknown => unknown_word
		Known(g) => g.to_u64().to_str()
	}

github_from : List(U8) -> Try([Unknown, Known(Principal.HumanId)], _)
github_from = |value|
	if value == Str.to_utf8(unknown_word) {
		Ok(Unknown)
	} else {
		Stored.id(value, { name: "github", make: Principal.HumanId.from_u64 }).map_ok(|g| Known(g))
	}

unknown_word : Str
unknown_word = "unknown"

grant_word : Str
grant_word = "grant"

## A key refused in use: `use`, all the line says of what it was asked
## (the refusal comes before the request is known).
use_word : Str
use_word = "use"

all_sign_in_refusals : List(GitHubSignIn.Refusal)
all_sign_in_refusals = [
	StateForged,
	StateMismatched,
	StateExpired,
	StateReused,
	GitHubDenied,
	NotACode,
	GitHubUnreachable,
	BadIdentity,
	PendingForged,
	PendingMismatched,
	PendingExpired,
	PendingReused,
	AccountExists,
	DuplicateAccount,
	AccountsFull,
	StaleGeneration,
	GenerationsExhausted,
	StaleHumanId,
	HumanIdsExhausted,
	ClockOutOfRange,
]

spell_sign_in_refusal : GitHubSignIn.Refusal -> Str
spell_sign_in_refusal = |why|
	match why {
		StateForged => "state-forged"
		StateMismatched => "state-mismatched"
		StateExpired => "state-expired"
		StateReused => "state-reused"
		GitHubDenied => "github-denied"
		NotACode => "not-a-code"
		GitHubUnreachable => "github-unreachable"
		BadIdentity => "bad-identity"
		PendingForged => "pending-forged"
		PendingMismatched => "pending-mismatched"
		PendingExpired => "pending-expired"
		PendingReused => "pending-reused"
		AccountExists => "account-exists"
		DuplicateAccount => "duplicate-account"
		AccountsFull => "accounts-full"
		StaleGeneration => "stale-generation"
		GenerationsExhausted => "generations-exhausted"
		StaleHumanId => "stale-human-id"
		HumanIdsExhausted => "human-ids-exhausted"
		ClockOutOfRange => "clock-out-of-range"
	}

all_grant_refusals : List(ApiKey.GrantRefusal)
all_grant_refusals = [
	GrantedByKey,
	SessionExpired,
	NoSuchGranter,
	NotTheGrantersOwn,
	NoSuchPrincipal,
	ClockOutOfRange,
	BadExpiry,
]

spell_grant_refusal : ApiKey.GrantRefusal -> Str
spell_grant_refusal = |why|
	match why {
		GrantedByKey => "granted-by-key"
		SessionExpired => "session-expired"
		NoSuchGranter => "no-such-granter"
		NotTheGrantersOwn => "not-the-granters-own"
		NoSuchPrincipal => "no-such-principal"
		ClockOutOfRange => "clock-out-of-range"
		BadExpiry => "bad-expiry"
	}

Via : [Session(Principal.SessionId), Key(Principal.KeyId)]

ViaKind : [Session, Key]

all_via_kinds : List(ViaKind)
all_via_kinds = [Session, Key]

spell_via : ViaKind -> Str
spell_via = |kind|
	match kind {
		Session => "session"
		Key => "key"
	}

## `session:12` or `key:4`.
via_text : Via -> Str
via_text = |via|
	match via {
		Session(s) => "${spell_via(Session)}${colon}${s.to_u64().to_str()}"
		Key(k) => "${spell_via(Key)}${colon}${k.to_u64().to_str()}"
	}

via_from : List(U8) -> Try(Via, _)
via_from = |value| {
	{ head, tail } = split_colon(value, "via")?
	match Stored.word(
		head,
		{
			name: "via",
			members: all_via_kinds,
			spell: spell_via,
		},
	)? {
		Session => Stored.id(
			tail,
			{ name: "via", make: Principal.SessionId.from_u64 },
		).map_ok(|s| Session(s))
		Key => Stored.id(tail, { name: "via", make: Principal.KeyId.from_u64 }).map_ok(|k| Key(k))
	}
}

all_key_refusals : List(ApiKey.Refusal)
all_key_refusals = [
	Revoked,
	Expired,
	NoSuchPrincipal,
	OutOfScope,
	BeyondPrincipal,
]

spell_key_refusal : ApiKey.Refusal -> Str
spell_key_refusal = |why|
	match why {
		Revoked => "revoked"
		Expired => "expired"
		NoSuchPrincipal => "no-such-principal"
		OutOfScope => "out-of-scope"
		BeyondPrincipal => "beyond-principal"
	}

permitted_word : Str
permitted_word = "permitted"

refused_prefix : Str
refused_prefix = "refused:"

key_prefix : Str
key_prefix = "key:"

colon : Str
colon = ":"

## The bytes before and after the first colon, both there.
split_colon : List(U8), Str -> Try({ head : List(U8), tail : List(U8) }, _)
split_colon = |value, name|
	match List.split_first(value, ':') {
		Ok({ before, after }) => Ok({ head: before, tail: after })
		Err(NotFound) => Err(BadValue(name))
	}

# ── tests

## An entry as text.
line_text : AuditLog.Entry -> Str
line_text = |entry|
	match Str.from_utf8(AuditLog.encode(entry)) {
		Ok(text) => text
		Err(_) => crash "line_text: a stored line is UTF-8"
	}

# ── SIGN-IN REFUSALS AND KEY REFUSALS
sign_in_entry : AuditLog.SignIn -> AuditLog.Entry
sign_in_entry = |s|
	match AuditLog.Entry.of_sign_in(s) {
		Ok(e) => e
		Err(ClockOutOfRange) => crash "sign_in_entry: a test's time is in range"
	}

key_entry : AuditLog.KeyEvent -> AuditLog.Entry
key_entry = |k|
	match AuditLog.Entry.of_key(k) {
		Ok(e) => e
		Err(ClockOutOfRange) => crash "key_entry: a test's time is in range"
	}

expect line_text(
	sign_in_entry({
		at: 1761600090,
		github: Known(Cast.hid(583231)),
		refusal: StateExpired,
	}),
) == "audit-sign-in v1 at=1761600090 github=583231 verdict=refused:state-expired\n"
expect line_text(
	sign_in_entry({
		at: 5,
		github: Unknown,
		refusal: StateForged,
	}),
) == "audit-sign-in v1 at=5 github=unknown verdict=refused:state-forged\n"
expect line_text(
	key_entry(
		Use({
			at: 1761600095,
			who: Principal.Id.Agent(Cast.aid(7)),
			key: Cast.kid(4),
			refusal: OutOfScope,
		}),
	),
) == "audit-key v1 at=1761600095 who=agent:7 via=key:4 action=use verdict=refused:out-of-scope\n"
expect line_text(
	key_entry(
		Grant({
			at: 1761600099,
			who: Principal.Id.Human(Cast.hid(2)),
			via: Session(Cast.sid(12)),
			acts_as: Principal.Id.Agent(Cast.aid(3)),
			refusal: NotTheGrantersOwn,
		}),
	),
) == "audit-key v1 at=1761600099 who=human:2 via=session:12 action=grant:agent:3 verdict=refused:not-the-granters-own\n"

# Every sign-in refusal, and every key refusal in use and in grant, round
# trips; a time the store cannot write makes no entry at all.
sign_ins : List(AuditLog.SignIn)
sign_ins = List.join_map(
	all_sign_in_refusals,
	|refusal| [
		{
			at: 1761600000,
			github: Known(Cast.hid(2)),
			refusal,
		},
		{
			at: 0,
			github: Unknown,
			refusal,
		},
	],
)

key_events : List(AuditLog.KeyEvent)
key_events =
	List.concat(
		List.join_map(
			all_key_refusals,
			|refusal| [
				Use({
					at: 1,
					who: Principal.Id.Bot(Cast.aid(9)),
					key: Cast.kid(4),
					refusal,
				}),
				Use({
					at: Stored.max_time,
					who: Principal.Id.Human(Cast.hid(2)),
					key: Cast.kid(5),
					refusal,
				}),
				Use({
					at: 7,
					who: Principal.Id.Agent(Cast.aid(3)),
					key: Cast.kid(6),
					refusal,
				}),
			],
		),
		List.join_map(
			all_grant_refusals,
			|refusal| [
				Grant({
					at: 2,
					who: Principal.Id.Human(Cast.hid(2)),
					via: Session(Cast.sid(1)),
					acts_as: Principal.Id.Bot(Cast.aid(3)),
					refusal,
				}),
				Grant({
					at: 3,
					who: Principal.Id.Agent(Cast.aid(1)),
					via: Key(Cast.kid(4)),
					acts_as: Principal.Id.Human(Cast.hid(1)),
					refusal,
				}),
			],
		),
	)

expect List.len(all_sign_in_refusals) == 20
expect List.len(all_grant_refusals) == 7
expect List.all(
	sign_ins,
	|s| AuditLog.decode(AuditLog.encode(sign_in_entry(s))) == Ok(sign_in_entry(s)),
)
expect List.all(
	key_events,
	|k| AuditLog.decode(AuditLog.encode(key_entry(k))) == Ok(key_entry(k)),
)
expect AuditLog.Entry.of_sign_in({
	at: -1,
	github: Unknown,
	refusal: StateForged,
}).map_ok(|_| {}) == Err(ClockOutOfRange)
expect AuditLog.Entry.of_key(
	Use({
		at: Stored.max_time + 1,
		who: Principal.Id.Bot(Cast.aid(9)),
		key: Cast.kid(4),
		refusal: Expired,
	}),
).map_ok(|_| {}) == Err(ClockOutOfRange)

## A key line with `from` replaced by `to`, decoded.
key_line_but : { from : Str, to : Str } -> Try({}, _)
key_line_but = |
	{
		from,
		to,
	},
| AuditLog.decode(
	Str.to_utf8(
		"audit-key v1 at=7 who=agent:7 via=key:4 action=use verdict=refused:out-of-scope\n".replace_first(
			from,
			to,
		),
	),
).map_ok(|_| {})

expect key_line_but({ from: "", to: "" }) == Ok({})
# A use is by a key; a grant's refusal words are a grant's alone.
expect key_line_but({ from: "via=key:4", to: "via=session:4" }) == Err(BadValue("via"))
expect key_line_but({ from: "out-of-scope", to: "granted-by-key" }) == Err(UnknownWord("verdict"))
expect key_line_but({
	from: "action=use verdict=refused:out-of-scope",
	to: "action=grant:agent:3 verdict=refused:out-of-scope",
}) == Err(UnknownWord("verdict"))
expect key_line_but({ from: "action=use", to: "action=use:3" }) == Err(UnknownWord("action"))
expect key_line_but({ from: "action=use", to: "action=read:3" }) == Err(UnknownWord("action"))
expect key_line_but({ from: "action=use", to: "action=list:conversations" }) == Err(UnknownWord("action"))
expect key_line_but({
	from: "verdict=refused:out-of-scope",
	to: "verdict=permitted",
}) == Err(UnknownWord("verdict"))
expect AuditLog.decode(Str.to_utf8("audit-sign-in v1 at=7 github=0 verdict=refused:state-expired\n")).map_ok(|_| {}) == Err(BadValue("github"))
expect AuditLog.decode(Str.to_utf8("audit-sign-in v1 at=7 github=2 verdict=permitted\n")).map_ok(|_| {}) == Err(UnknownWord("verdict"))
expect AuditLog.decode(Str.to_utf8("audit-login v1 at=7\n")).map_ok(|_| {}) == Err(WrongRecord)

# ── AN INVITE'S LIFE: every verdict round-trips, known and unknown; the
# lines read as the header shows them; a mixed or mismatched line refused.
invite_entry : AuditLog.Invite -> AuditLog.Entry
invite_entry = |i|
	match AuditLog.Entry.of_invite(i) {
		Ok(e) => e
		Err(ClockOutOfRange) => crash "invite_entry: a test's time is storable"
	}

## Invite `n`, for agent 7.
invite_for_seven : U64 -> [Unknown, Known({ id : AgentInvite.InviteId, agent : Principal.Id })]
invite_for_seven = |n|
	match AgentInvite.InviteId.from_u64(n) {
		Ok(id) => Known({ id, agent: Principal.Id.Agent(Cast.aid(7)) })
		Err(NotAnId) => crash "invite_for_seven: a test's invite id is not 0"
	}

invite_three : [Unknown, Known({ id : AgentInvite.InviteId, agent : Principal.Id })]
invite_three = invite_for_seven(3)

invite_verdicts : List(
	[
		Created([Session(Principal.SessionId), Key(Principal.KeyId)]),
		Redeemed(Principal.KeyId),
		Revoked(Principal.SessionId),
		Refused(AgentInvite.Refusal),
	],
)
invite_verdicts = List.concat(
	[
		Created(Session(Cast.sid(12))),
		Created(Key(Cast.kid(5))),
		Redeemed(Cast.kid(9)),
		Revoked(Cast.sid(12)),
	],
	List.map(invite_refusals, |r| Refused(r)),
)

## Every refusal an invite's redemption can give.
invite_refusals : List(AgentInvite.Refusal)
invite_refusals = List.concat(
	[
		Unknown,
		Spent,
		Revoked,
		Expired,
		CredentialSent,
		NoLongerHolds,
	],
	List.map(all_grant_refusals, |g| Grant(g)),
)

invite_events : List(AuditLog.Invite)
invite_events = List.join_map(
	invite_verdicts,
	|v| [
		{
			at: 1761600100,
			invite: invite_three,
			verdict: v,
		},
		{
			at: 5,
			invite: Unknown,
			verdict: v,
		},
	],
)

expect List.len(invite_events) == 34
expect List.all(
	invite_events,
	|i| AuditLog.decode(AuditLog.encode(invite_entry(i))) == Ok(invite_entry(i)),
)
expect line_text(
	invite_entry({
		at: 1761600100,
		invite: invite_three,
		verdict: Created(Session(Cast.sid(12))),
	}),
) == "audit-invite v1 at=1761600100 invite=3 for=agent:7 verdict=created:session:12\n"
expect line_text(
	invite_entry({
		at: 1761600160,
		invite: invite_three,
		verdict: Redeemed(Cast.kid(9)),
	}),
) == "audit-invite v1 at=1761600160 invite=3 for=agent:7 verdict=redeemed:key:9\n"
expect line_text(
	invite_entry({
		at: 1761600170,
		invite: Unknown,
		verdict: Refused(Unknown),
	}),
) == "audit-invite v1 at=1761600170 invite=unknown for=unknown verdict=refused:unknown\n"
expect line_text(
	invite_entry({
		at: 7,
		invite: invite_three,
		verdict: Refused(Grant(SessionExpired)),
	}),
) == "audit-invite v1 at=7 invite=3 for=agent:7 verdict=refused:grant:session-expired\n"
expect AuditLog.Entry.of_invite({
	at: -1,
	invite: Unknown,
	verdict: Refused(Unknown),
}).map_ok(|_| {}) == Err(ClockOutOfRange)

## An invite line with `from` replaced by `to`, decoded.
invite_line_but : { from : Str, to : Str } -> Try({}, _)
invite_line_but = |
	{
		from,
		to,
	},
| AuditLog.decode(
	Str.to_utf8(
		"audit-invite v1 at=7 invite=3 for=agent:7 verdict=created:session:12\n".replace_first(
			from,
			to,
		),
	),
).map_ok(|_| {})

expect invite_line_but({ from: "", to: "" }) == Ok({})
expect invite_line_but({ from: "invite=3", to: "invite=unknown" }) == Err(BadValue("for"))
expect invite_line_but({ from: "created:session:12", to: "created:key:12" }) == Ok({})
expect invite_line_but({
	from: "created:session:12",
	to: "revoked:key:12",
}) == Err(BadValue("verdict"))
expect invite_line_but({
	from: "created:session:12",
	to: "redeemed:session:12",
}) == Err(BadValue("verdict"))
expect invite_line_but({
	from: "created:session:12",
	to: "used:session:12",
}) == Err(UnknownWord("verdict"))
expect invite_line_but({
	from: "created:session:12",
	to: "refused:stale",
}) == Err(UnknownWord("verdict"))
expect invite_line_but({
	from: "created:session:12",
	to: "refused:grant:stale",
}) == Err(UnknownWord("verdict"))
expect invite_line_but({ from: "invite=3", to: "invite=0" }) == Err(BadValue("invite"))

# ── A CHANNEL'S CHANGES: the header's lines, each verdict round-tripped.
## The name `text` is, in a test where the rule takes it.
channel_named : Str -> ChannelName
channel_named = |text|
	match ChannelName.from_str(text) {
		Ok(n) => n
		Err(_) => crash "channel_named: a test's channel name is one"
	}

## Lobby made by human 1 with humans 2 and 7, by session 3, with `verdict`.
lobby_made : [Permitted, Refused(AuditLog.ChannelRefusal)] -> AuditLog.ChannelEvent
lobby_made = |verdict| {
	at: 1761600200,
	who: Principal.Id.Human(Cast.hid(1)),
	via: Session(Cast.sid(3)),
	action: Make,
	channel: Named(channel_named("Lobby")),
	members: [Principal.Id.Human(Cast.hid(2)), Principal.Id.Human(Cast.hid(7))],
	verdict,
}

## The channel event's line, its time in range.
channel_line : AuditLog.ChannelEvent -> Str
channel_line = |c|
	match AuditLog.Entry.of_channel(c) {
		Ok(e) => line_text(e)
		Err(ClockOutOfRange) => crash "channel_line: a test's time is in range"
	}

## The channel event through its line and back.
channel_round_trip : AuditLog.ChannelEvent -> Bool
channel_round_trip = |c|
	match AuditLog.Entry.of_channel(c) {
		Ok(e) => AuditLog.decode(AuditLog.encode(e)) == Ok(e)
		Err(ClockOutOfRange) => Bool.False
	}

expect channel_line(lobby_made(Permitted)) == "audit-channel v1 at=1761600200 who=human:1 via=session:3 action=make channel=Lobby members=human:2,human:7 verdict=permitted\n"
expect
	channel_line({
		..lobby_made(Refused(NotAdmin)),
		at: 1761600210,
		who: Principal.Id.Human(Cast.hid(2)),
		via: Session(Cast.sid(12)),
		action: Admit,
		members: [Principal.Id.Human(Cast.hid(9))],
	})
		== "audit-channel v1 at=1761600210 who=human:2 via=session:12 action=admit channel=Lobby members=human:9 verdict=refused:not-admin\n"
# A name the rule refused, and no members: both empty.
expect channel_line({
	..lobby_made(Refused(NotAChannelName)),
	channel: Unnamed,
	members: [],
}) == "audit-channel v1 at=1761600200 who=human:1 via=session:3 action=make channel= members= verdict=refused:not-a-channel-name\n"
expect channel_line({
	..lobby_made(Refused(KeyRefused(Revoked))),
	via: Key(Cast.kid(4)),
}).ends_with(" via=key:4 action=make channel=Lobby members=human:2,human:7 verdict=refused:key:revoked\n")
expect
	[
		Permitted,
		Refused(NeedsSession),
		Refused(NoSuchPrincipal),
		Refused(NotAdmin),
		Refused(NotAChannelName),
		Refused(Taken),
		Refused(NamedTwice),
		Refused(NotAHuman),
		Refused(NoAccount),
		Refused(AlreadyIn),
		Refused(NotIn),
		Refused(NoSuchChannel),
		Refused(KeyRefused(Expired)),
	].all(|v| channel_round_trip(lobby_made(v)))

## Every channel action, each by a key.
every_channel_action : List(AuditLog.ChannelAction)
every_channel_action = [
	Make,
	Admit,
	Remove,
]

expect every_channel_action.all(
	|a| channel_round_trip({
		..lobby_made(Permitted),
		action: a,
		via: Key(Cast.kid(5)),
	}),
)
expect channel_round_trip({
	..lobby_made(Permitted),
	channel: Unnamed,
	members: [],
})
expect AuditLog.Entry.of_channel({
	..lobby_made(Permitted),
	at: -1,
}).map_ok(|_| {}) == Err(ClockOutOfRange)

## A channel line with `from` replaced by `to`, decoded.
channel_line_but : { from : Str, to : Str } -> Try({}, _)
channel_line_but = |{ from, to }| {
	line = channel_line(lobby_made(Permitted)).replace_first(from, to)
	AuditLog.decode(Str.to_utf8(line)).map_ok(|_| {})
}

expect channel_line_but({ from: "", to: "" }) == Ok({})
expect channel_line_but({ from: "action=make", to: "action=rename" }) == Err(UnknownWord("action"))
expect channel_line_but({ from: "channel=Lobby", to: "channel=1st" }) == Err(BadValue("channel"))
expect channel_line_but({
	from: "members=human:2,human:7",
	to: "members=human:2,",
}) == Err(BadValue("members"))
expect channel_line_but({
	from: "verdict=permitted",
	to: "verdict=refused:busy",
}) == Err(UnknownWord("verdict"))
expect channel_line_but({
	from: "verdict=permitted",
	to: "verdict=refused:key:taken",
}) == Err(UnknownWord("verdict"))
expect channel_line_but({ from: " channel=Lobby", to: "" }) == Err(MissingField("channel"))

# ── THE MALFORMED TABLE: each line, its named problem, on a channel's line.
usual_line : Str
usual_line = "audit-channel v1 at=1761600200 who=human:1 via=session:3 action=make channel=Lobby members=human:2,human:7 verdict=permitted\n"

decoded : { from : Str, to : Str } -> Try({}, _)
decoded = |
	{
		from,
		to,
	},
| AuditLog.decode(Str.to_utf8(usual_line.replace_first(from, to))).map_ok(|_| {})

expect decoded({ from: "", to: "" }) == Ok({})
expect decoded({ from: "\n", to: "" }) == Err(Torn)
expect decoded({ from: "audit-channel", to: "audits" }) == Err(WrongRecord)
expect decoded({ from: "v1", to: "v9" }) == Err(UnknownVersion)
expect decoded({ from: "at=1761600200 ", to: "" }) == Err(MissingField("at"))
expect decoded({ from: "at=1761600200", to: "at=-0" }) == Err(BadNumber("at"))
expect decoded({ from: "at=1761600200", to: "at=-1" }) == Err(BadNumber("at"))
expect decoded({ from: "who=human:1", to: "who=human:0" }) == Err(BadValue("who"))
expect decoded({ from: "who=human:1", to: "who=root" }) == Err(BadValue("who"))
expect decoded({ from: "via=session:3", to: "via=cookie:3" }) == Err(UnknownWord("via"))
expect decoded({ from: "via=session:3", to: "via=session" }) == Err(BadValue("via"))
expect decoded({ from: "via=session:3", to: "via=session:0" }) == Err(BadValue("via"))
expect decoded({ from: "via=session:3", to: "via=key:x" }) == Err(BadNumber("via"))
expect decoded({ from: "via=session:3 ", to: "" }) == Err(MissingField("via"))
expect decoded({ from: " verdict=permitted", to: "" }) == Err(MissingField("verdict"))
expect decoded({ from: "permitted\n", to: "permitted by=steve\n" }) == Err(Trailing)
expect decoded({
	from: "who=human:1 via=session:3",
	to: "via=session:3 who=human:1",
}) == Err(MissingField("who"))
# The admin's line of before (`audit v1 ...`) is no entry now.
expect AuditLog.decode("audit v1 at=1761600000 who=agent:1 via=key:4 action=revoke-keys:human:2 verdict=permitted plan=none\n".to_utf8()).is_err()

# ── RENAMES
renamed_entry : AuditLog.RenameEvent -> AuditLog.Entry
renamed_entry = |r|
	match AuditLog.Entry.of_rename(r) {
		Ok(e) => e
		Err(ClockOutOfRange) => crash "renamed_entry: a test's time is in range"
	}

rename_lc : AuditLog.RenameEvent
rename_lc = {
	at: 1761600300,
	who: Principal.Id.Human(Cast.hid(1)),
	via: Session(Cast.sid(3)),
	agent: Principal.Id.Agent(Cast.aid(1)),
	verdict: Permitted,
	name: "LC",
}

expect AuditLog.encode(renamed_entry(rename_lc)) == "audit-rename v1 at=1761600300 who=human:1 via=session:3 agent=agent:1 verdict=permitted name=LC\n".to_utf8()
expect
	List.all(
		[
			rename_lc,
			{ ..rename_lc, name: "Two  words, and = signs" },
			{
				..rename_lc,
				name: "",
				verdict: Refused(NotAName),
			},
			{
				..rename_lc,
				verdict: Refused(NotTheOwner),
				via: Key(Cast.kid(4)),
				who: Principal.Id.Agent(Cast.aid(2)),
			},
			{ ..rename_lc, verdict: Refused(NeedsSession) },
			{
				..rename_lc,
				verdict: Refused(NoSuchAgent),
				agent: Principal.Id.Bot(Cast.aid(9)),
			},
			{ ..rename_lc, verdict: Refused(NameTaken) },
		],
		|r| AuditLog.decode(AuditLog.encode(renamed_entry(r))) == Ok(renamed_entry(r)),
	)
# A name that could end the line is written empty; a verdict unknown, refused.
expect AuditLog.encode(
	renamed_entry({
		..rename_lc,
		name: "a\nb",
	}),
) == "audit-rename v1 at=1761600300 who=human:1 via=session:3 agent=agent:1 verdict=permitted name=\n".to_utf8()
expect AuditLog.decode("audit-rename v1 at=1 who=human:1 via=session:3 agent=agent:1 verdict=refused:nope name=x\n".to_utf8()).is_err()
expect AuditLog.Entry.of_rename({ ..rename_lc, at: -1 }).map_ok(|_| {}) == Err(ClockOutOfRange)

# A human invite's lines: each verdict round trips; the code is in none.
human_invited : AuditLog.HumanInviteEvent -> AuditLog.Entry
human_invited = |i|
	match AuditLog.Entry.of_human_invite(i) {
		Ok(e) => e
		Err(ClockOutOfRange) => crash "human_invited: a test's time is in range"
	}

zoe_invited : AuditLog.HumanInviteEvent
zoe_invited = {
	at: 1761600180,
	invite: Known({
		id: HumanInvite.InviteId.from_u64(3) ?? crash "3 is an id",
		human: Cast.hid(100),
	}),
	verdict: Created(Cast.hid(2)),
}

expect AuditLog.encode(human_invited(zoe_invited)) == "audit-human-invite v1 at=1761600180 invite=3 for=human:100 verdict=created:human:2\n".to_utf8()
expect AuditLog.encode(
	human_invited({
		..zoe_invited,
		verdict: Redeemed(Cast.sid(9)),
	}),
) == "audit-human-invite v1 at=1761600180 invite=3 for=human:100 verdict=redeemed:session:9\n".to_utf8()
expect
	[
		zoe_invited,
		{ ..zoe_invited, verdict: Reinvited(Cast.hid(1)) },
		{ ..zoe_invited, verdict: Redeemed(Cast.sid(9)) },
		{ ..zoe_invited, verdict: Revoked(Cast.hid(2)) },
		{ ..zoe_invited, verdict: Refused(Spent) },
		{ ..zoe_invited, verdict: Refused(Revoked) },
		{ ..zoe_invited, verdict: Refused(Expired) },
		{ ..zoe_invited, verdict: Refused(NoLongerHolds) },
		{
			..zoe_invited,
			invite: Unknown,
			verdict: Refused(Unknown),
		},
	].all(|i| AuditLog.decode(AuditLog.encode(human_invited(i))) == Ok(human_invited(i)))
expect AuditLog.decode("audit-human-invite v1 at=1761600180 invite=3 for=agent:1 verdict=created:human:2\n".to_utf8()) == Err(BadValue("for"))
expect AuditLog.decode("audit-human-invite v1 at=1761600180 invite=3 for=unknown verdict=created:human:2\n".to_utf8()) == Err(BadValue("for"))
expect AuditLog.decode("audit-human-invite v1 at=1761600180 invite=3 for=human:100 verdict=created:agent:2\n".to_utf8()) == Err(BadValue("verdict"))
expect AuditLog.decode("audit-human-invite v1 at=1761600180 invite=3 for=human:100 verdict=redeemed:key:2\n".to_utf8()) == Err(BadValue("verdict"))
expect AuditLog.decode("audit-human-invite v1 at=1761600180 invite=3 for=human:100 verdict=refused:grant:x\n".to_utf8()) == Err(UnknownWord("verdict"))
expect AuditLog.Entry.of_human_invite({ ..zoe_invited, at: -1 }) == Err(ClockOutOfRange)

## **THE AUDIT LOG, STORED** (the Roc chat's auth design, section 9): one
## line in Stored's format for every admin attempt, permitted or refused,
## with the whole plan it made; for every sign-in refused; and for every
## key refused, in use or in its grant:
##
##     audit v1 at=1761600000 who=agent:1 via=key:4 action=revoke-keys:human:2 verdict=permitted plan=revoke-keys:human:2
##     audit v1 at=1761600077 who=human:2 via=session:12 action=retire:human:1 verdict=refused:not-admin plan=none
##     audit-sign-in v1 at=1761600090 github=583231 verdict=refused:barred
##     audit-key v1 at=1761600095 who=agent:7 via=key:4 action=read:3 verdict=refused:out-of-scope
##     audit-key v1 at=1761600099 who=human:2 via=session:12 action=grant:agent:3 verdict=refused:not-the-granters-own
##     audit-invite v1 at=1761600100 invite=3 for=agent:7 verdict=created:session:12
##     audit-invite v1 at=1761600160 invite=3 for=agent:7 verdict=redeemed:key:9
##     audit-invite v1 at=1761600170 invite=unknown for=unknown verdict=refused:unknown
##
## And for every invite (InviteCodec): made, redeemed into a key (its public
## id), revoked, or a redemption refused, `grant:` and a grant's word when
## the grant decided again refused it.
##
## Who (a principal's id, as AccountCodec spells it), by which session or
## key (its public number), what, when, and the verdict, each spelled once:
## an action as a word and its target after a colon, a refusal as a word (a
## key's after `key:` in an admin line), a plan as its steps, commas
## between (`none` for no step). **No secret is in any record**: no token,
## hash, cookie, nonce, OAuth code or login, only public numbers and words;
## a sign-in refused before GitHub named anyone is `github=unknown`.
##
## **AN ENTRY IS OPAQUE**, made only by `of_admin`, `of_sign_in`, `of_key`
## and `of_invite`, which refuse a time outside Stored's range (ClockOutOfRange),
## or by `decode`: the encoder never meets a time it cannot write. Pure.
import AccountCodec
import Admin
import ApiKey
import Bytes
import Cast
import GitHubSignIn
import InviteCodec
import Principal
import Stored

AuditCodec := [].{

	## A sign-in refused: when, the GitHub id when GitHub had named one, and
	## why.
	SignIn : {
		at : I64,
		github : [Unknown, Known(Principal.GitHubId)],
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
				action : [
					Read(U64),
					Post(U64),
					Start,
				],
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
		invite : [Unknown, Known({ id : InviteCodec.InviteId, agent : Principal.Id })],
		verdict : [
			Created([Session(Principal.SessionId), Key(Principal.KeyId)]),
			Redeemed(Principal.KeyId),
			Revoked(Principal.SessionId),
			Refused(InviteCodec.Refusal),
		],
	}

	## **ONE LINE OF THE AUDIT LOG**. Opaque: its time always in Stored's
	## range.
	Entry :: [
		Admin(Admin.Audit),
		SignIn(AuditCodec.SignIn),
		Key(AuditCodec.KeyEvent),
		Invite(AuditCodec.Invite),
	].{

		## An admin attempt's audit (Admin.decide's).
		of_admin : Admin.Audit -> Try(AuditCodec.Entry, [ClockOutOfRange])
		of_admin = |audit| if is_storable(audit.at) Ok(AuditCodec.Entry.(Admin(audit))) else Err(ClockOutOfRange)

		## A refused sign-in's.
		of_sign_in : AuditCodec.SignIn -> Try(AuditCodec.Entry, [ClockOutOfRange])
		of_sign_in = |s| if is_storable(s.at) Ok(AuditCodec.Entry.(SignIn(s))) else Err(ClockOutOfRange)

		## A refused key's, in use or in its grant.
		of_key : AuditCodec.KeyEvent -> Try(AuditCodec.Entry, [ClockOutOfRange])
		of_key = |e| {
			at =
				match e {
					Use(u) => u.at
					Grant(g) => g.at
				}
			if is_storable(at) Ok(AuditCodec.Entry.(Key(e))) else Err(ClockOutOfRange)
		}

		## An invite's.
		of_invite : AuditCodec.Invite -> Try(AuditCodec.Entry, [ClockOutOfRange])
		of_invite = |i| if is_storable(i.at) Ok(AuditCodec.Entry.(Invite(i))) else Err(ClockOutOfRange)

		## What the entry records.
		event : AuditCodec.Entry -> [
			Admin(Admin.Audit),
			SignIn(AuditCodec.SignIn),
			Key(AuditCodec.KeyEvent),
			Invite(AuditCodec.Invite),
		]
		event = |AuditCodec.Entry.(e)| e

		is_eq : _
	}

	## **A REFUSED SIGN-IN'S REASON, AS THE AUDIT SPELLS IT**: the one
	## spelling, which the refusal page shows too.
	sign_in_refusal_text : GitHubSignIn.Refusal -> Str
	sign_in_refusal_text = |why| spell_sign_in_refusal(why)

	## The entry's line.
	encode : AuditCodec.Entry -> List(U8)
	encode = |AuditCodec.Entry.(e)|
		match e {
			Admin(audit) =>
				Stored.line(
					admin_kind,
					[
						("at", Stored.time_text(audit.at)),
						("who", AccountCodec.id_text(audit.who)),
						("via", via_text(audit.via)),
						("action", action_text(audit.action)),
						("verdict", verdict_text(audit.verdict)),
						("plan", plan_text(audit.plan)),
					],
				)

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
						("action", key_action_text(u.action)),
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
		}

	## The entry a line holds, of whichever kind its first word names.
	decode : List(U8) -> Try(AuditCodec.Entry, Stored.Problem)
	decode = |raw|
		match Stored.Reader.open(raw, admin_kind) {
			Ok(fields) => decode_admin(fields).map_ok(|a| AuditCodec.Entry.(Admin(a)))
			Err(WrongRecord) =>
				match Stored.Reader.open(raw, sign_in_kind) {
					Ok(fields) => decode_sign_in(fields).map_ok(|s| AuditCodec.Entry.(SignIn(s)))
					Err(WrongRecord) =>
						match Stored.Reader.open(raw, key_kind) {
							Ok(fields) => decode_key(fields).map_ok(|k| AuditCodec.Entry.(Key(k)))
							Err(WrongRecord) => {
								fields = Stored.Reader.open(raw, invite_kind)?
								decode_invite(fields).map_ok(|i| AuditCodec.Entry.(Invite(i)))
							}
							Err(why) => Err(why)
						}
					Err(why) => Err(why)
				}
			Err(why) => Err(why)
		}
}

## The three lines' first words.
admin_kind : Str
admin_kind = "audit"

sign_in_kind : Str
sign_in_kind = "audit-sign-in"

key_kind : Str
key_kind = "audit-key"

invite_kind : Str
invite_kind = "audit-invite"

## `created:session:12`, `redeemed:key:9`, `revoked:session:12`, or
## `refused:` and InviteCodec's word.
invite_verdict_text : [
	Created([Session(Principal.SessionId), Key(Principal.KeyId)]),
	Redeemed(Principal.KeyId),
	Revoked(Principal.SessionId),
	Refused(InviteCodec.Refusal),
] -> Str
invite_verdict_text = |verdict|
	match verdict {
		Created(via) => "${spell_invite_act(Created)}${colon}${via_text(via)}"
		Redeemed(k) => "${spell_invite_act(Redeemed)}${colon}${via_text(Key(k))}"
		Revoked(s) => "${spell_invite_act(Revoked)}${colon}${via_text(Session(s))}"
		Refused(why) => "${refused_prefix}${InviteCodec.refusal_text(why, spell_grant_refusal)}"
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
		Refused(InviteCodec.Refusal),
	],
	Stored.Problem,
)
invite_verdict_from = |value|
	match Bytes.strip_prefix(value, Str.to_utf8(refused_prefix)) {
		Ok(why) => InviteCodec.refusal_from(
			why,
			|g| Stored.word(
				g,
				{
					name: "verdict",
					all: all_grant_refusals,
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
					all: all_invite_acts,
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

decode_invite : Stored.Reader -> Try(AuditCodec.Invite, Stored.Problem)
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
	[Unknown, Known({ id : InviteCodec.InviteId, agent : Principal.Id })],
	Stored.Problem,
)
invite_from = |invite_value, for_value| {
	unknown = Str.to_utf8(unknown_word)
	if invite_value == unknown and for_value == unknown {
		Ok(Unknown)
	} else if invite_value == unknown or for_value == unknown {
		Err(BadValue("for"))
	} else {
		id = Stored.id(invite_value, { name: "invite", make: InviteCodec.InviteId.from_u64 })?
		agent = AccountCodec.id_from(for_value, "for")?
		Ok(Known({ id, agent }))
	}
}

## A time Stored can write.
is_storable : I64 -> Bool
is_storable = |t| t >= 0 and t <= Stored.max_time

decode_admin : Stored.Reader -> Try(Admin.Audit, Stored.Problem)
decode_admin = |fields| {
	at_field = fields.field("at")?
	at = Stored.time(at_field.value, "at")?
	who_field = at_field.rest.field("who")?
	who = AccountCodec.id_from(who_field.value, "who")?
	via_field = who_field.rest.field("via")?
	via = via_from(via_field.value)?
	action_field = via_field.rest.field("action")?
	action = action_from(action_field.value)?
	verdict_field = action_field.rest.field("verdict")?
	verdict = verdict_from(verdict_field.value)?
	plan_field = verdict_field.rest.field("plan")?
	plan = plan_from(plan_field.value)?
	plan_field.rest.close()?
	Ok({
		who,
		via,
		action,
		at,
		verdict,
		plan,
	})
}

decode_sign_in : Stored.Reader -> Try(AuditCodec.SignIn, Stored.Problem)
decode_sign_in = |fields| {
	at_field = fields.field("at")?
	at = Stored.time(at_field.value, "at")?
	github_field = at_field.rest.field("github")?
	github = github_from(github_field.value)?
	verdict_field = github_field.rest.field("verdict")?
	refusal = refused_word(
		verdict_field.value,
		{ all: all_sign_in_refusals, spell: spell_sign_in_refusal },
	)?
	verdict_field.rest.close()?
	Ok({
		at,
		github,
		refusal,
	})
}

decode_key : Stored.Reader -> Try(AuditCodec.KeyEvent, Stored.Problem)
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
	{ head, tail } = split_colon(action_field.value, "action")?
	if head == Str.to_utf8(grant_word) {
		acts_as = AccountCodec.id_from(tail, "action")?
		refusal = refused_word(
			verdict_field.value,
			{ all: all_grant_refusals, spell: spell_grant_refusal },
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
		action = key_action_from(head, tail)?
		refusal = refused_word(
			verdict_field.value,
			{ all: all_key_refusals, spell: spell_key_refusal },
		)?
		Ok(
			Use({
				at,
				who,
				key,
				action,
				refusal,
			}),
		)
	}
}

## `refused:` and a word of the closed set, in a `verdict` field.
refused_word : List(U8), { all : List(a), spell : (a -> Str) } -> Try(a, Stored.Problem)
refused_word = |value, { all, spell }|
	match Bytes.strip_prefix(value, Str.to_utf8(refused_prefix)) {
		Err(NoMatch) => Err(UnknownWord("verdict"))
		Ok(why) => Stored.word(
			why,
			{
				name: "verdict",
				all,
				spell,
			},
		)
	}

## `unknown`, or the GitHub id.
github_text : [Unknown, Known(Principal.GitHubId)] -> Str
github_text = |github|
	match github {
		Unknown => unknown_word
		Known(g) => g.to_u64().to_str()
	}

github_from : List(U8) -> Try([Unknown, Known(Principal.GitHubId)], Stored.Problem)
github_from = |value|
	if value == Str.to_utf8(unknown_word) {
		Ok(Unknown)
	} else {
		Stored.id(value, { name: "github", make: Principal.GitHubId.from_u64 }).map_ok(|g| Known(g))
	}

unknown_word : Str
unknown_word = "unknown"

grant_word : Str
grant_word = "grant"

## A key's start of a conversation: `start:conversation`.
start_word : Str
start_word = "start"

new_word : Str
new_word = "conversation"

KeyActionKind : [Read, Post]

all_key_action_kinds : List(KeyActionKind)
all_key_action_kinds = [Read, Post]

spell_key_action : KeyActionKind -> Str
spell_key_action = |kind|
	match kind {
		Read => "read"
		Post => "post"
	}

## `read:` or `post:` and the resource's number; `start:conversation`, a
## new one, which has no number yet.
key_action_text : [
	Read(U64),
	Post(U64),
	Start,
] -> Str
key_action_text = |action|
	match action {
		Read(n) => "${spell_key_action(Read)}${colon}${n.to_str()}"
		Post(n) => "${spell_key_action(Post)}${colon}${n.to_str()}"
		Start => "${start_word}${colon}${new_word}"
	}

key_action_from : List(U8),
List(U8) -> Try(
	[
		Read(U64),
		Post(U64),
		Start,
	],
	Stored.Problem,
)
key_action_from = |head, tail| if head == Str.to_utf8(start_word) {
	if tail == Str.to_utf8(new_word) Ok(Start) else Err(BadValue("action"))
} else {
	kind = Stored.word(
		head,
		{
			name: "action",
			all: all_key_action_kinds,
			spell: spell_key_action,
		},
	)?
	n = Stored.count(tail, "action")?
	match kind {
		Read => Ok(Read(n))
		Post => Ok(Post(n))
	}
}

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
	Barred,
	PendingForged,
	PendingMismatched,
	PendingExpired,
	PendingReused,
	AccountExists,
	DuplicateAccount,
	StaleGeneration,
	GenerationsExhausted,
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
		Barred => "barred"
		PendingForged => "pending-forged"
		PendingMismatched => "pending-mismatched"
		PendingExpired => "pending-expired"
		PendingReused => "pending-reused"
		AccountExists => "account-exists"
		DuplicateAccount => "duplicate-account"
		StaleGeneration => "stale-generation"
		GenerationsExhausted => "generations-exhausted"
		ClockOutOfRange => "clock-out-of-range"
	}

all_grant_refusals : List(ApiKey.GrantRefusal)
all_grant_refusals = [
	GrantedByKey,
	SessionExpired,
	NoSuchGranter,
	NotTheGrantersOwn,
	NoSuchPrincipal,
	AdminBeyondPrincipal,
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
		AdminBeyondPrincipal => "admin-beyond-principal"
		ClockOutOfRange => "clock-out-of-range"
		BadExpiry => "bad-expiry"
	}

## A plan's step's word, without its target.
StepKind : [
	Bar,
	RevokeSessions,
	RevokeKeys,
	Remove,
	WithdrawVotes,
	SetRole,
]

all_step_kinds : List(StepKind)
all_step_kinds = [
	Bar,
	RevokeSessions,
	RevokeKeys,
	Remove,
	WithdrawVotes,
	SetRole,
]

spell_step : StepKind -> Str
spell_step = |kind|
	match kind {
		Bar => "bar"
		RevokeSessions => "revoke-sessions"
		RevokeKeys => "revoke-keys"
		Remove => "remove"
		WithdrawVotes => "withdraw-votes"
		SetRole => "set-role"
	}

## A step's word and its target after a colon.
step_text : Admin.Step -> Str
step_text = |step|
	match step {
		Bar(g) => "${spell_step(Bar)}${colon}${g.to_u64().to_str()}"
		RevokeSessionsOf(g) => "${spell_step(RevokeSessions)}${colon}${g.to_u64().to_str()}"
		RevokeKeysOf(id) => "${spell_step(RevokeKeys)}${colon}${AccountCodec.id_text(id)}"
		RemoveAccount(id) => "${spell_step(Remove)}${colon}${AccountCodec.id_text(id)}"
		WithdrawVotes(g) => "${spell_step(WithdrawVotes)}${colon}${g.to_u64().to_str()}"
		SetRole(
			{
				human,
				role,
			},
		) => "${spell_step(SetRole)}${colon}${human.to_u64().to_str()}${colon}${AccountCodec.role_text(role)}"
	}

step_from : List(U8) -> Try(Admin.Step, Stored.Problem)
step_from = |value| {
	{ head, tail } = split_colon(value, "plan")?
	human = |bytes| Stored.id(bytes, { name: "plan", make: Principal.GitHubId.from_u64 })
	match Stored.word(
		head,
		{
			name: "plan",
			all: all_step_kinds,
			spell: spell_step,
		},
	)? {
		Bar => human(tail).map_ok(|g| Bar(g))
		RevokeSessions => human(tail).map_ok(|g| RevokeSessionsOf(g))
		WithdrawVotes => human(tail).map_ok(|g| WithdrawVotes(g))
		RevokeKeys => AccountCodec.id_from(tail, "plan").map_ok(|id| RevokeKeysOf(id))
		Remove => AccountCodec.id_from(tail, "plan").map_ok(|id| RemoveAccount(id))
		SetRole => {
			parts = split_colon(tail, "plan")?
			g = human(parts.head)?
			role = AccountCodec.role_from(parts.tail, "plan")?
			Ok(SetRole({ human: g, role }))
		}
	}
}

## The steps, commas between; `none` for no step.
plan_text : List(Admin.Step) -> Str
plan_text = |plan| if List.is_empty(plan) none_word else Str.join_with(
	List.map(plan, step_text),
	",",
)

plan_from : List(U8) -> Try(List(Admin.Step), Stored.Problem)
plan_from = |value|
	if value == Str.to_utf8(none_word) {
		Ok([])
	} else {
		List.map_try(List.split_on(value, ','), step_from)
	}

none_word : Str
none_word = "none"

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

via_from : List(U8) -> Try(Via, Stored.Problem)
via_from = |value| {
	{ head, tail } = split_colon(value, "via")?
	match Stored.word(
		head,
		{
			name: "via",
			all: all_via_kinds,
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

## An action's word, without its target.
ActionKind : [
	ListAccounts,
	Retire,
	RevokeKeys,
	RevokeSessions,
	SetRole,
	ReadCounters,
]

all_action_kinds : List(ActionKind)
all_action_kinds = [
	ListAccounts,
	Retire,
	RevokeKeys,
	RevokeSessions,
	SetRole,
	ReadCounters,
]

spell_action : ActionKind -> Str
spell_action = |kind|
	match kind {
		ListAccounts => "list-accounts"
		Retire => "retire"
		RevokeKeys => "revoke-keys"
		RevokeSessions => "revoke-sessions"
		SetRole => "set-role"
		ReadCounters => "read-counters"
	}

## The action's word, and its target after a colon: a principal's id, a
## human's GitHub id for their sessions, or a human's GitHub id and the
## role set, colon between.
action_text : Admin.Action -> Str
action_text = |action|
	match action {
		ListAccounts => spell_action(ListAccounts)
		Retire(id) => "${spell_action(Retire)}${colon}${AccountCodec.id_text(id)}"
		RevokeKeys(id) => "${spell_action(RevokeKeys)}${colon}${AccountCodec.id_text(id)}"
		RevokeSessions(g) => "${spell_action(RevokeSessions)}${colon}${g.to_u64().to_str()}"
		SetRole({ human, role }) => {
			target = "${human.to_u64().to_str()}${colon}${AccountCodec.role_text(role)}"
			"${spell_action(SetRole)}${colon}${target}"
		}
		ReadCounters => spell_action(ReadCounters)
	}

action_from : List(U8) -> Try(Admin.Action, Stored.Problem)
action_from = |value|
	match List.split_first(value, ':') {
		Err(NotFound) =>
			match Stored.word(
				value,
				{
					name: "action",
					all: all_action_kinds,
					spell: spell_action,
				},
			)? {
				ListAccounts => Ok(ListAccounts)
				ReadCounters => Ok(ReadCounters)
				Retire | RevokeKeys | RevokeSessions | SetRole => Err(BadValue("action"))
			}

		Ok({ before, after }) =>
			match Stored.word(
				before,
				{
					name: "action",
					all: all_action_kinds,
					spell: spell_action,
				},
			)? {
				ListAccounts | ReadCounters => Err(BadValue("action"))
				Retire => AccountCodec.id_from(after, "action").map_ok(|id| Retire(id))
				RevokeKeys => AccountCodec.id_from(after, "action").map_ok(|id| RevokeKeys(id))
				RevokeSessions =>
					Stored.id(
						after,
						{ name: "action", make: Principal.GitHubId.from_u64 },
					).map_ok(|g| RevokeSessions(g))
				SetRole => {
					{ head, tail } = split_colon(after, "action")?
					human = Stored.id(head, { name: "action", make: Principal.GitHubId.from_u64 })?
					role = AccountCodec.role_from(tail, "action")?
					Ok(SetRole({ human, role }))
				}
			}
	}

Verdict : [Permitted, Refused(Admin.Refusal)]

## The refusals Admin says itself; a key's are ApiKey's, after `key:`.
AdminRefusal : [
	NoSuchPrincipal,
	SessionExpired,
	NotAdmin,
	RetiresOwnAuthority,
	SetsOwnRole,
	NeedsSession,
	BootstrapAdmin,
	LastAdmin,
	NoSuchTarget,
]

all_admin_refusals : List(AdminRefusal)
all_admin_refusals = [
	NoSuchPrincipal,
	SessionExpired,
	NotAdmin,
	RetiresOwnAuthority,
	SetsOwnRole,
	NeedsSession,
	BootstrapAdmin,
	LastAdmin,
	NoSuchTarget,
]

spell_admin_refusal : AdminRefusal -> Str
spell_admin_refusal = |why|
	match why {
		NoSuchPrincipal => "no-such-principal"
		SessionExpired => "session-expired"
		NotAdmin => "not-admin"
		RetiresOwnAuthority => "retires-own-authority"
		SetsOwnRole => "sets-own-role"
		NeedsSession => "needs-session"
		BootstrapAdmin => "bootstrap-admin"
		LastAdmin => "last-admin"
		NoSuchTarget => "no-such-target"
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

## `permitted`, or `refused:` and the refusal (`refused:key:` and a key's).
verdict_text : Verdict -> Str
verdict_text = |verdict|
	match verdict {
		Permitted => permitted_word
		Refused(why) => "${refused_prefix}${refusal_text(why)}"
	}

## A refusal's word, a key's after `key:`.
refusal_text : Admin.Refusal -> Str
refusal_text = |why|
	match why {
		KeyRefused(key_why) => "${key_prefix}${spell_key_refusal(key_why)}"
		NoSuchPrincipal => spell_admin_refusal(NoSuchPrincipal)
		SessionExpired => spell_admin_refusal(SessionExpired)
		NotAdmin => spell_admin_refusal(NotAdmin)
		RetiresOwnAuthority => spell_admin_refusal(RetiresOwnAuthority)
		SetsOwnRole => spell_admin_refusal(SetsOwnRole)
		NeedsSession => spell_admin_refusal(NeedsSession)
		BootstrapAdmin => spell_admin_refusal(BootstrapAdmin)
		LastAdmin => spell_admin_refusal(LastAdmin)
		NoSuchTarget => spell_admin_refusal(NoSuchTarget)
	}

verdict_from : List(U8) -> Try(Verdict, Stored.Problem)
verdict_from = |value|
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
								all: all_key_refusals,
								spell: spell_key_refusal,
							},
						)
							.map_ok(|w| Refused(KeyRefused(w)))

					Err(NoMatch) =>
						match Stored.word(
							why,
							{
								name: "verdict",
								all: all_admin_refusals,
								spell: spell_admin_refusal,
							},
						)? {
							NoSuchPrincipal => Ok(Refused(NoSuchPrincipal))
							SessionExpired => Ok(Refused(SessionExpired))
							NotAdmin => Ok(Refused(NotAdmin))
							RetiresOwnAuthority => Ok(Refused(RetiresOwnAuthority))
							SetsOwnRole => Ok(Refused(SetsOwnRole))
							NeedsSession => Ok(Refused(NeedsSession))
							BootstrapAdmin => Ok(Refused(BootstrapAdmin))
							LastAdmin => Ok(Refused(LastAdmin))
							NoSuchTarget => Ok(Refused(NoSuchTarget))
						}
				}
		}
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
split_colon : List(U8), Str -> Try({ head : List(U8), tail : List(U8) }, Stored.Problem)
split_colon = |value, name|
	match List.split_first(value, ':') {
		Ok({ before, after }) => Ok({ head: before, tail: after })
		Err(NotFound) => Err(BadValue(name))
	}

# ── tests

## A test's admin audit, with no plan.
Bare : {
	who : Principal.Id,
	via : [Session(Principal.SessionId), Key(Principal.KeyId)],
	action : Admin.Action,
	at : I64,
	verdict : [Permitted, Refused(Admin.Refusal)],
}

## The entry of an admin audit whose time a test keeps in range.
admin_entry : Admin.Audit -> AuditCodec.Entry
admin_entry = |audit|
	match AuditCodec.Entry.of_admin(audit) {
		Ok(e) => e
		Err(ClockOutOfRange) => crash "admin_entry: a test's time is in range"
	}

## An entry as text.
line_text : AuditCodec.Entry -> Str
line_text = |entry|
	match Str.from_utf8(AuditCodec.encode(entry)) {
		Ok(text) => text
		Err(_) => crash "line_text: a stored line is UTF-8"
	}

## A bare audit as text.
text_of : Bare -> Str
text_of = |bare|
	match Str.from_utf8(
		AuditCodec.encode(
			admin_entry({
				who: bare.who,
				via: bare.via,
				action: bare.action,
				at: bare.at,
				verdict: bare.verdict,
				plan: [],
			}),
		),
	) {
		Ok(text) => text
		Err(_) => crash "text_of: a stored line is UTF-8"
	}

expect
	text_of({
		who: Principal.Id.Agent(Cast.aid(1)),
		via: Key(Cast.kid(4)),
		action: RevokeKeys(Principal.Id.Human(Cast.gid(2))),
		at: 1761600000,
		verdict: Permitted,
	})
		== "audit v1 at=1761600000 who=agent:1 via=key:4 action=revoke-keys:human:2 verdict=permitted plan=none\n"
expect
	text_of({
		who: Principal.Id.Human(Cast.gid(2)),
		via: Session(Cast.sid(12)),
		action: Retire(Principal.Id.Human(Cast.gid(1))),
		at: 1761600077,
		verdict: Refused(NotAdmin),
	})
		== "audit v1 at=1761600077 who=human:2 via=session:12 action=retire:human:1 verdict=refused:not-admin plan=none\n"
expect
	text_of({
		who: Principal.Id.Bot(Cast.aid(3)),
		via: Key(Cast.kid(5)),
		action: ReadCounters,
		at: 0,
		verdict: Refused(KeyRefused(OutOfScope)),
	})
		== "audit v1 at=0 who=bot:3 via=key:5 action=read-counters verdict=refused:key:out-of-scope plan=none\n"
expect
	text_of({
		who: Principal.Id.Human(Cast.gid(1)),
		via: Session(Cast.sid(3)),
		action: SetRole({ human: Cast.gid(2), role: Admin }),
		at: 1761600100,
		verdict: Permitted,
	})
		== "audit v1 at=1761600100 who=human:1 via=session:3 action=set-role:2:admin verdict=permitted plan=none\n"
expect
	text_of({
		who: Principal.Id.Agent(Cast.aid(1)),
		via: Key(Cast.kid(4)),
		action: SetRole({ human: Cast.gid(2), role: Member }),
		at: 1761600100,
		verdict: Refused(NeedsSession),
	})
		== "audit v1 at=1761600100 who=agent:1 via=key:4 action=set-role:2:member verdict=refused:needs-session plan=none\n"

# ── EVERY ENTRY ROUND-TRIPS: every action against every verdict, by a
# session and by a key.
actions : List(Admin.Action)
actions = [
	ListAccounts,
	Retire(Principal.Id.Human(Cast.gid(1))),
	Retire(Principal.Id.Agent(Cast.aid(2))),
	Retire(Principal.Id.Bot(Cast.aid(3))),
	RevokeKeys(Principal.Id.Human(Cast.gid(18446744073709551615))),
	RevokeKeys(Principal.Id.Agent(Cast.aid(2))),
	RevokeKeys(Principal.Id.Bot(Cast.aid(3))),
	RevokeSessions(Cast.gid(583231)),
	SetRole({ human: Cast.gid(2), role: Admin }),
	SetRole({ human: Cast.gid(583231), role: Member }),
	ReadCounters,
]

verdicts : List(Verdict)
verdicts = List.concat(
	List.concat([Permitted], List.map(all_admin_refusals, |w| when_refused(w))),
	List.map(all_key_refusals, |w| Refused(KeyRefused(w))),
)

when_refused : AdminRefusal -> Verdict
when_refused = |why|
	match why {
		NoSuchPrincipal => Refused(NoSuchPrincipal)
		SessionExpired => Refused(SessionExpired)
		NotAdmin => Refused(NotAdmin)
		RetiresOwnAuthority => Refused(RetiresOwnAuthority)
		SetsOwnRole => Refused(SetsOwnRole)
		NeedsSession => Refused(NeedsSession)
		BootstrapAdmin => Refused(BootstrapAdmin)
		LastAdmin => Refused(LastAdmin)
		NoSuchTarget => Refused(NoSuchTarget)
	}

entries : List(Admin.Audit)
entries =
	List.join_map(
		actions,
		|action|
			List.join_map(
				verdicts,
				|verdict| [
					{
						who: Principal.Id.Human(Cast.gid(1)),
						via: Session(Cast.sid(9)),
						action,
						at: 1761600000,
						verdict,
						plan: [],
					},
					{
						who: Principal.Id.Agent(Cast.aid(1)),
						via: Key(Cast.kid(4)),
						action,
						at: 0,
						verdict,
						plan: every_step,
					},
				],
			),
	)

expect List.len(verdicts) == 15
expect List.len(entries) == 330
expect List.all(
	entries,
	|e| AuditCodec.decode(AuditCodec.encode(admin_entry(e))) == Ok(admin_entry(e)),
)

## Every step of a plan, each kind once and every target kind.
every_step : List(Admin.Step)
every_step = [
	Bar(Cast.gid(2)),
	RevokeSessionsOf(Cast.gid(2)),
	RevokeKeysOf(Principal.Id.Human(Cast.gid(2))),
	RevokeKeysOf(Principal.Id.Agent(Cast.aid(3))),
	RemoveAccount(Principal.Id.Agent(Cast.aid(3))),
	RevokeKeysOf(Principal.Id.Bot(Cast.aid(6))),
	RemoveAccount(Principal.Id.Bot(Cast.aid(6))),
	WithdrawVotes(Cast.gid(2)),
	RemoveAccount(Principal.Id.Human(Cast.gid(2))),
	SetRole({ human: Cast.gid(4), role: Member }),
]

# **A RETIREMENT'S WHOLE PLAN IS AUDITED** (round three's design point): the
# agents and bots that went with the human and the votes withdrawn, each a
# step on the line, in the plan's order.
expect
	line_text(
		admin_entry({
			who: Principal.Id.Human(Cast.gid(1)),
			via: Session(Cast.sid(3)),
			action: Retire(Principal.Id.Human(Cast.gid(2))),
			at: 1761600200,
			verdict: Permitted,
			plan: List.take_first(every_step, 9),
		}),
	)
		== "audit v1 at=1761600200 who=human:1 via=session:3 action=retire:human:2 verdict=permitted plan=bar:2,revoke-sessions:2,revoke-keys:human:2,revoke-keys:agent:3,remove:agent:3,revoke-keys:bot:6,remove:bot:6,withdraw-votes:2,remove:human:2\n"

# ── SIGN-IN REFUSALS AND KEY REFUSALS (round three's design point)
sign_in_entry : AuditCodec.SignIn -> AuditCodec.Entry
sign_in_entry = |s|
	match AuditCodec.Entry.of_sign_in(s) {
		Ok(e) => e
		Err(ClockOutOfRange) => crash "sign_in_entry: a test's time is in range"
	}

key_entry : AuditCodec.KeyEvent -> AuditCodec.Entry
key_entry = |k|
	match AuditCodec.Entry.of_key(k) {
		Ok(e) => e
		Err(ClockOutOfRange) => crash "key_entry: a test's time is in range"
	}

expect line_text(
	sign_in_entry({
		at: 1761600090,
		github: Known(Cast.gid(583231)),
		refusal: Barred,
	}),
) == "audit-sign-in v1 at=1761600090 github=583231 verdict=refused:barred\n"
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
			action: Read(3),
			refusal: OutOfScope,
		}),
	),
) == "audit-key v1 at=1761600095 who=agent:7 via=key:4 action=read:3 verdict=refused:out-of-scope\n"
expect line_text(
	key_entry(
		Grant({
			at: 1761600099,
			who: Principal.Id.Human(Cast.gid(2)),
			via: Session(Cast.sid(12)),
			acts_as: Principal.Id.Agent(Cast.aid(3)),
			refusal: NotTheGrantersOwn,
		}),
	),
) == "audit-key v1 at=1761600099 who=human:2 via=session:12 action=grant:agent:3 verdict=refused:not-the-granters-own\n"

# Every sign-in refusal, and every key refusal in use and in grant, round
# trips; a time the store cannot write makes no entry at all.
sign_ins : List(AuditCodec.SignIn)
sign_ins = List.join_map(
	all_sign_in_refusals,
	|refusal| [
		{
			at: 1761600000,
			github: Known(Cast.gid(2)),
			refusal,
		},
		{
			at: 0,
			github: Unknown,
			refusal,
		},
	],
)

key_events : List(AuditCodec.KeyEvent)
key_events =
	List.concat(
		List.join_map(
			all_key_refusals,
			|refusal| [
				Use({
					at: 1,
					who: Principal.Id.Bot(Cast.aid(9)),
					key: Cast.kid(4),
					action: Read(18446744073709551615),
					refusal,
				}),
				Use({
					at: Stored.max_time,
					who: Principal.Id.Human(Cast.gid(2)),
					key: Cast.kid(5),
					action: Post(0),
					refusal,
				}),
				Use({
					at: 7,
					who: Principal.Id.Agent(Cast.aid(3)),
					key: Cast.kid(6),
					action: Start,
					refusal,
				}),
			],
		),
		List.join_map(
			all_grant_refusals,
			|refusal| [
				Grant({
					at: 2,
					who: Principal.Id.Human(Cast.gid(2)),
					via: Session(Cast.sid(1)),
					acts_as: Principal.Id.Bot(Cast.aid(3)),
					refusal,
				}),
				Grant({
					at: 3,
					who: Principal.Id.Agent(Cast.aid(1)),
					via: Key(Cast.kid(4)),
					acts_as: Principal.Id.Human(Cast.gid(1)),
					refusal,
				}),
			],
		),
	)

expect List.len(all_sign_in_refusals) == 18
expect List.len(all_grant_refusals) == 8
expect List.all(
	sign_ins,
	|s| AuditCodec.decode(AuditCodec.encode(sign_in_entry(s))) == Ok(sign_in_entry(s)),
)
expect List.all(
	key_events,
	|k| AuditCodec.decode(AuditCodec.encode(key_entry(k))) == Ok(key_entry(k)),
)
expect AuditCodec.Entry.of_sign_in({
	at: -1,
	github: Unknown,
	refusal: StateForged,
}).map_ok(|_| {}) == Err(ClockOutOfRange)
expect AuditCodec.Entry.of_key(
	Use({
		at: Stored.max_time + 1,
		who: Principal.Id.Bot(Cast.aid(9)),
		key: Cast.kid(4),
		action: Read(1),
		refusal: Expired,
	}),
).map_ok(|_| {}) == Err(ClockOutOfRange)
expect AuditCodec.Entry.of_admin({
	who: Principal.Id.Human(Cast.gid(1)),
	via: Session(Cast.sid(1)),
	action: ListAccounts,
	at: -5,
	verdict: Permitted,
	plan: [],
}).map_ok(|_| {}) == Err(ClockOutOfRange)

## A key line with `from` replaced by `to`, decoded.
key_line_but : { from : Str, to : Str } -> Try({}, Stored.Problem)
key_line_but = |
	{
		from,
		to,
	},
| AuditCodec.decode(
	Str.to_utf8(
		"audit-key v1 at=7 who=agent:7 via=key:4 action=read:3 verdict=refused:out-of-scope\n".replace_first(
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
	from: "action=read:3 verdict=refused:out-of-scope",
	to: "action=grant:agent:3 verdict=refused:out-of-scope",
}) == Err(UnknownWord("verdict"))
expect key_line_but({ from: "action=read:3", to: "action=write:3" }) == Err(UnknownWord("action"))
expect key_line_but({
	from: "verdict=refused:out-of-scope",
	to: "verdict=permitted",
}) == Err(UnknownWord("verdict"))
expect AuditCodec.decode(Str.to_utf8("audit-sign-in v1 at=7 github=0 verdict=refused:barred\n")).map_ok(|_| {}) == Err(BadValue("github"))
expect AuditCodec.decode(Str.to_utf8("audit-sign-in v1 at=7 github=2 verdict=permitted\n")).map_ok(|_| {}) == Err(UnknownWord("verdict"))
expect AuditCodec.decode(Str.to_utf8("audit-login v1 at=7\n")).map_ok(|_| {}) == Err(WrongRecord)

# ── AN INVITE'S LIFE: every verdict round-trips, known and unknown; the
# lines read as the header shows them; a mixed or mismatched line refused.
invite_entry : AuditCodec.Invite -> AuditCodec.Entry
invite_entry = |i|
	match AuditCodec.Entry.of_invite(i) {
		Ok(e) => e
		Err(ClockOutOfRange) => crash "invite_entry: a test's time is storable"
	}

## Invite `n`, for agent 7.
invite_for_seven : U64 -> [Unknown, Known({ id : InviteCodec.InviteId, agent : Principal.Id })]
invite_for_seven = |n|
	match InviteCodec.InviteId.from_u64(n) {
		Ok(id) => Known({ id, agent: Principal.Id.Agent(Cast.aid(7)) })
		Err(NotAnId) => crash "invite_for_seven: a test's invite id is not 0"
	}

invite_three : [Unknown, Known({ id : InviteCodec.InviteId, agent : Principal.Id })]
invite_three = invite_for_seven(3)

invite_verdicts : List(
	[
		Created([Session(Principal.SessionId), Key(Principal.KeyId)]),
		Redeemed(Principal.KeyId),
		Revoked(Principal.SessionId),
		Refused(InviteCodec.Refusal),
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
invite_refusals : List(InviteCodec.Refusal)
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

invite_events : List(AuditCodec.Invite)
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

expect List.len(invite_events) == 36
expect List.all(
	invite_events,
	|i| AuditCodec.decode(AuditCodec.encode(invite_entry(i))) == Ok(invite_entry(i)),
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
expect AuditCodec.Entry.of_invite({
	at: -1,
	invite: Unknown,
	verdict: Refused(Unknown),
}).map_ok(|_| {}) == Err(ClockOutOfRange)

## An invite line with `from` replaced by `to`, decoded.
invite_line_but : { from : Str, to : Str } -> Try({}, Stored.Problem)
invite_line_but = |
	{
		from,
		to,
	},
| AuditCodec.decode(
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

# ── THE MALFORMED TABLE: each line, its named problem.
usual_line : Str
usual_line = "audit v1 at=1761600000 who=agent:1 via=key:4 action=revoke-keys:human:2 verdict=permitted plan=none\n"

decoded : { from : Str, to : Str } -> Try({}, Stored.Problem)
decoded = |
	{
		from,
		to,
	},
| AuditCodec.decode(Str.to_utf8(usual_line.replace_first(from, to))).map_ok(|_| {})

expect decoded({ from: "", to: "" }) == Ok({})
expect decoded({ from: "\n", to: "" }) == Err(Torn)
expect decoded({ from: "audit", to: "audits" }) == Err(WrongRecord)
expect decoded({ from: "v1", to: "v9" }) == Err(UnknownVersion)
expect decoded({ from: "at=1761600000 ", to: "" }) == Err(MissingField("at"))
expect decoded({ from: "at=1761600000", to: "at=-0" }) == Err(BadNumber("at"))
expect decoded({ from: "who=agent:1", to: "who=agent:0" }) == Err(BadValue("who"))
expect decoded({ from: "who=agent:1", to: "who=root" }) == Err(BadValue("who"))
expect decoded({ from: "via=key:4", to: "via=cookie:4" }) == Err(UnknownWord("via"))
expect decoded({ from: "via=key:4", to: "via=key" }) == Err(BadValue("via"))
expect decoded({ from: "via=key:4", to: "via=key:0" }) == Err(BadValue("via"))
expect decoded({ from: "via=key:4", to: "via=session:x" }) == Err(BadNumber("via"))
expect decoded({ from: "via=key:4 ", to: "" }) == Err(MissingField("via"))
expect decoded({
	from: "revoke-keys:human:2",
	to: "read-mail:human:2",
}) == Err(UnknownWord("action"))
expect decoded({ from: "revoke-keys:human:2", to: "revoke-keys" }) == Err(BadValue("action"))
expect decoded({
	from: "revoke-keys:human:2",
	to: "list-accounts:human:2",
}) == Err(BadValue("action"))
expect decoded({
	from: "revoke-keys:human:2",
	to: "revoke-keys:human:0",
}) == Err(BadValue("action"))
expect decoded({
	from: "revoke-keys:human:2",
	to: "revoke-sessions:human:2",
}) == Err(BadNumber("action"))
expect decoded({ from: "revoke-keys:human:2", to: "revoke-sessions:2" }) == Ok({})
expect decoded({ from: "revoke-keys:human:2", to: "list-accounts" }) == Ok({})
expect decoded({ from: "revoke-keys:human:2", to: "set-role:2:admin" }) == Ok({})
expect decoded({ from: "revoke-keys:human:2", to: "set-role:2" }) == Err(BadValue("action"))
expect decoded({ from: "revoke-keys:human:2", to: "set-role" }) == Err(BadValue("action"))
# No action lifts a bar (Steve, 2026-10-29): `unbar` is no word.
expect decoded({ from: "revoke-keys:human:2", to: "unbar:66" }) == Err(UnknownWord("action"))
expect decoded({ from: "revoke-keys:human:2", to: "unbar" }) == Err(UnknownWord("action"))
expect decoded({ from: "permitted", to: "refused:bootstrap-admin" }) == Ok({})
expect decoded({ from: "permitted", to: "refused:not-barred" }) == Err(UnknownWord("verdict"))
expect decoded({ from: "at=1761600000", to: "at=-1" }) == Err(BadNumber("at"))
expect decoded({ from: "revoke-keys:human:2", to: "set-role:0:admin" }) == Err(BadValue("action"))
expect decoded({
	from: "revoke-keys:human:2",
	to: "set-role:2:owner",
}) == Err(UnknownWord("action"))
expect decoded({
	from: "revoke-keys:human:2",
	to: "set-role:human:2:admin",
}) == Err(BadNumber("action"))
expect decoded({
	from: "permitted",
	to: "refused:session-not-human",
}) == Err(UnknownWord("verdict"))
expect decoded({ from: "permitted", to: "allowed" }) == Err(UnknownWord("verdict"))
expect decoded({ from: "permitted", to: "refused:" }) == Err(UnknownWord("verdict"))
expect decoded({ from: "permitted", to: "refused:not-admin" }) == Ok({})
expect decoded({ from: "permitted", to: "refused:because" }) == Err(UnknownWord("verdict"))
expect decoded({ from: "permitted", to: "refused:key:not-admin" }) == Err(UnknownWord("verdict"))
expect decoded({ from: "permitted", to: "refused:key:" }) == Err(UnknownWord("verdict"))
expect decoded({ from: " verdict=permitted", to: "" }) == Err(MissingField("verdict"))
expect decoded({ from: "none\n", to: "none by=steve\n" }) == Err(Trailing)
expect decoded({ from: " plan=none", to: "" }) == Err(MissingField("plan"))
expect decoded({ from: "plan=none", to: "plan=" }) == Err(BadValue("plan"))
expect decoded({ from: "plan=none", to: "plan=bar:2," }) == Err(BadValue("plan"))
expect decoded({ from: "plan=none", to: "plan=unbar:2" }) == Err(UnknownWord("plan"))
expect decoded({ from: "plan=none", to: "plan=bar:0" }) == Err(BadValue("plan"))
expect decoded({ from: "plan=none", to: "plan=remove:human:2,bar:2" }) == Ok({})
expect decoded({
	from: "who=agent:1 via=key:4",
	to: "via=key:4 who=agent:1",
}) == Err(MissingField("who"))

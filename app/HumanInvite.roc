## **A HUMAN INVITE, DECIDED** (docs/design/humans-without-github.md, step
## 4): how a human without GitHub joins. Any human member invites someone
## by a name, which a new account holds at once (an invited human,
## Principal.SignIn's `Invited`, signing in by no password); the invitee
## redeems the code, single-use and good for `lifetime_secs`, on this
## device, and may take any other free name as they do. A re-invite, from
## the human who invited them or an admin, is a new code for the same
## account: another device, or a lost one. At most
## `Limits.human_invites_open` open invites per human.
##
## **A REDEMPTION ENDS IN AN ADMISSION**, an opaque value only this module
## makes, which Session.start_invited takes, as GitHub sign-in's does
## Session.start: no handler mints an invited human's session. Pure; the
## routes are HumanInvites'.
import Account
import Accounts
import Cast
import ChannelName
import DisplayName
import GitHubSignIn
import Limits
import Principal
import Stored

HumanInvite := [].{

	## A human invite's public id, shown in a listing and the audit; never
	## its code. Opaque: made only by `from_u64`, which refuses 0.
	InviteId :: U64.{
		from_u64 : U64 -> Try(HumanInvite.InviteId, [NotAnId])
		from_u64 = |n| if (n == 0) Err(NotAnId) else Ok(HumanInvite.InviteId.(n))

		to_u64 : HumanInvite.InviteId -> U64
		to_u64 = |HumanInvite.InviteId.(n)| n

		is_eq : _
	}

	## Where an invite is: redeemable, redeemed once, or revoked.
	State : [
		Live,
		Spent,
		Revoked,
	]

	## **AN INVITE'S WHOLE RECORD**: the invited human, bound as their
	## account is (one retired, or made again, and the invite redeems to
	## nothing); the human who made it (the inviter, or an admin's
	## re-invite); its code's hash, never the code; when, and until when.
	Record : {
		id : HumanInvite.InviteId,
		human : Principal.Bound,
		by : Principal.HumanId,
		hash : Stored.SecretHash,
		created : I64,
		expires : I64,
		state : HumanInvite.State,
	}

	## **WHY A REDEMPTION IS REFUSED**, each audited and each the same 401
	## on the wire. **ONE ALIAS ON PURPOSE**: the redemption and the audit
	## share it, and the audit's record round-trips each tag.
	Refusal : [
		## No invite's hash is the code's.
		Unknown,

		## Redeemed before.
		Spent,

		## Its maker revoked it.
		Revoked,

		## Past its expiry, or a clock no time can be trusted from.
		Expired,

		## The invited account is not the one it was made for (retired).
		NoLongerHolds,
	]

	## How long a code lives, in seconds: 7 days.
	lifetime_secs : I64
	lifetime_secs = 604800

	## The welcome's topic when the inviter names none.
	default_topic : Str
	default_topic = "ChitChat"

	## The welcome when the inviter writes none, from the inviter by name.
	default_welcome : Str -> Str
	default_welcome = |inviter| "Hi! This is an automated message from ${inviter}"

	## **ADMITTED BY AN INVITE**: the one value Session.start_invited takes.
	## Only `redeem` makes one: the human, the account's generation the
	## session is bound to, the host's facts of the new session, the time.
	Admission :: {
		human : Principal.HumanId,
		generation : Principal.Generation,
		session : GitHubSignIn.NewSession,
		now : I64,
	}.{

		## What the admission holds, for Session.start_invited.
		facts : HumanInvite.Admission -> {
			human : Principal.HumanId,
			generation : Principal.Generation,
			session : GitHubSignIn.NewSession,
			now : I64,
		}
		facts = |HumanInvite.Admission.(a)| a
	}

	## Whether the invite still redeems at `now`: live, and unexpired.
	is_open : HumanInvite.Record, I64 -> Bool
	is_open = |r, now| r.state == Live and now < r.expires

	## **INVITE SOMEONE**: by the human `by`, who has an account, under
	## the open-invite and total caps (their `open` and `made` counted by
	## the caller from their own invites), a new invited human named
	## `name` (DisplayName's rule, free in the one namespace), with the
	## settings' next human id and generation, the steps advancing both
	## counters first, as a sign-up's do.
	invite : {
		by : Principal.HumanId,
		name : List(U8),
		open : U64,
		made : U64,
		accounts : List(Principal),
		channels : List(ChannelName),
		settings : Accounts.Settings,
		now : I64,
	} -> Try({ human : Principal, steps : List(Accounts.Change) }, _)
	invite = |
		{
			by,
			name,
			open,
			made,
			accounts,
			channels,
			settings,
			now,
		},
	| {
		if now < 0 or now > Stored.max_time {
			Err(ClockOutOfRange)
		} else if !Principal.has_account(accounts, by) {
			Err(NoSuchInviter)
		} else if open >= Limits.human_invites_open {
			Err(Capped(OpenInvites))
		} else if made >= Limits.human_invites_per_human or List.len(accounts) >= Limits.accounts_most {
			Err(Capped(Made))
		} else {
			chosen = DisplayName.from_utf8(name).map_err(|p| NameRefused(p))?
			if Accounts.name_holder({ accounts, channels }, chosen.to_str()) != Free {
				Err(NameTaken)
			} else {
				generation = Accounts.next_generation(accounts, settings).map_err(|why| Stuck(why))?
				ids = Accounts.next_human_id(accounts, settings).map_err(|why| Stuck(why))?
				human = Principal.Human({
					id: ids.this,
					sign_in: Invited(by),
					login: "",
					name: chosen.to_str(),
					role: Member,
					generation: generation.this,
				})
				Ok({
					human,
					steps: [
						AdvanceGeneration(generation.next),
						AdvanceHumanId(ids.next),
						AddAccount(human),
					],
				})
			}
		}
	}

	## **MAY `asker` RE-INVITE `human`?** The invited human's binding when
	## `human` is an invited human (one who signs in by GitHub signs in
	## there) and `asker` invited them or is an admin, under `asker`'s caps.
	reinvite : {
		asker : Principal.HumanId,
		human : Principal.HumanId,
		open : U64,
		made : U64,
		accounts : List(Principal),
	} -> Try(Principal.Bound, _)
	reinvite = |
		{
			asker,
			human,
			open,
			made,
			accounts,
		},
	| {
		them = Principal.human_account(accounts, asker).map_err(|_| NoSuchInviter)?
		invited = Principal.human_account(accounts, human).map_err(|_| NoSuchHuman)?
		match invited.sign_in {
			GitHub(_) => Err(SignsInByGitHub)
			Invited(inviter) if inviter != asker and them.role != Admin => Err(NotYours)
			Invited(_) if open >= Limits.human_invites_open => Err(Capped(OpenInvites))
			Invited(_) if made >= Limits.human_invites_per_human => Err(Capped(Made))
			Invited(_) => Principal.bind(
				accounts,
				Principal.Id.Human(human),
			).map_err(|_| NoSuchHuman)
		}
	}

	## **WHAT A REDEMPTION DECIDES**: an open invite whose account still
	## holds, the invitee's name kept or changed to any free one, signs
	## them in (the Admission), with the steps that rename them, if any,
	## and the invite spent; or why not.
	redeem : {
		record : HumanInvite.Record,
		name : [Kept, Chosen(List(U8))],
		accounts : List(Principal),
		channels : List(ChannelName),
		session : GitHubSignIn.NewSession,
		now : I64,
	} -> Try(
		{
			admission : HumanInvite.Admission,
			steps : List(Accounts.Change),
			spent : HumanInvite.Record,
		},
		_,
	)
	redeem = |
		{
			record,
			name,
			accounts,
			channels,
			session,
			now,
		},
	|
		match record.state {
			Spent => Err(Refused(Spent))
			Revoked => Err(Refused(Revoked))
			Live if now < 0 or now > Stored.max_time or !HumanInvite.is_open(
				record,
				now,
			) => Err(Refused(Expired))
			Live =>
				match Principal.holds(accounts, record.human) {
					Err(NoSuchPrincipal) => Err(Refused(NoLongerHolds))
					Ok(principal) => {
						steps = renamed(
							principal,
							name,
							{ accounts, channels },
						)?
						Ok({
							admission: HumanInvite.Admission.(
								{
									human: Principal.answers_to(principal),
									generation: record.human.generation,
									session,
									now,
								},
							),
							steps,
							spent: { ..record, state: Spent },
						})
					}
				}
		}

	## **REVOKE IT**: a live invite revoked, by its maker (the caller
	## found it among theirs); one spent or revoked already is not live.
	revoke : HumanInvite.Record -> Try(HumanInvite.Record, [NotLive])
	revoke = |r| if (r.state == Live) Ok({ ..r, state: Revoked }) else Err(NotLive)

	## **AN INVITE'S LINE**, in Stored's format, its code's hash and never
	## the code, which the inviter is shown once and hands on:
	##
	##     human-invite v1 id=3 for=human:100/2/2 by=human:2 hash=<64 hex digits> created=1761600000 expires=1762204800 state=live
	##
	## `for` is the invited human, bound as their account is; `by` the human
	## who made it, the inviter or an admin re-inviting. The state is `live`
	## until it is `spent` (redeemed, once) or `revoked`.

	## The record's line.
	encode : HumanInvite.Record -> List(U8)
	encode = |r|
		Stored.line(
			"human-invite",
			[
				("id", r.id.to_u64().to_str()),
				("for", Account.bound_text(r.human)),
				("by", Account.id_text(Principal.Id.Human(r.by))),
				("hash", Stored.hash_text(r.hash)),
				("created", Stored.time_text(r.created)),
				("expires", Stored.time_text(r.expires)),
				("state", spell_state(r.state)),
			],
		)

	## The record a line holds; refused when it is for, or by, anyone but
	## a human, or expires before it was made.
	decode : List(U8) -> Try(HumanInvite.Record, _)
	decode = |raw| {
		fields = Stored.Reader.open(raw, "human-invite")?
		id_field = fields.field("id")?
		id = Stored.id(id_field.value, { name: "id", make: HumanInvite.InviteId.from_u64 })?
		for_field = id_field.rest.field("for")?
		human = Account.bound_from(for_field.value, "for")?
		by_field = for_field.rest.field("by")?
		by = Account.id_from(by_field.value, "by")?
		hash_field = by_field.rest.field("hash")?
		hash = Stored.hash(hash_field.value, "hash")?
		created_field = hash_field.rest.field("created")?
		created = Stored.time(created_field.value, "created")?
		expires_field = created_field.rest.field("expires")?
		expires = Stored.time(expires_field.value, "expires")?
		state_field = expires_field.rest.field("state")?
		state = Stored.word(
			state_field.value,
			{
				name: "state",
				members: all_states,
				spell: spell_state,
			},
		)?
		state_field.rest.close()?
		match (human.id, by) {
			(Human(_), Human(maker)) if expires > created => Ok({
				id,
				human,
				by: maker,
				hash,
				created,
				expires,
				state,
			})
			(Human(_), Human(_)) => Err(BadValue("expires"))
			(Human(_), _) => Err(BadValue("by"))
			_ => Err(BadValue("for"))
		}
	}

	## **A REDEMPTION'S REFUSAL, AS THE AUDIT SPELLS IT**: a word.
	refusal_text : HumanInvite.Refusal -> Str
	refusal_text = |why| spell_refusal(why)

	## The refusal a word names.
	refusal_from : List(U8) -> Try(HumanInvite.Refusal, _)
	refusal_from = |value|
		Stored.word(
			value,
			{
				name: "verdict",
				members: all_refusals,
				spell: spell_refusal,
			},
		)
}

## The steps that give `principal` the name chosen: none when it keeps its
## own (in any spelling the rule calls the same, which the new spelling
## takes); refused when the rule refuses it or another account holds it.
renamed : Principal,
[Kept, Chosen(List(U8))],
{ accounts : List(Principal), channels : List(ChannelName) } -> Try(
	List(Accounts.Change),
	[NameRefused(DisplayName.Problem), NameTaken],
)
renamed = |
	principal,
	name,
	names,
|
	match name {
		Kept => Ok([])
		Chosen(bytes) => {
			chosen = DisplayName.from_utf8(bytes).map_err(|p| NameRefused(p))?
			match Accounts.name_holder(names, chosen.to_str()) {
				Held(id) if id != principal.id() => Err(NameTaken)
				Channel(_) => Err(NameTaken)
				_ if chosen.to_str() == name_of(principal) => Ok([])
				_ => Ok([SetName({ account: principal.id(), name: chosen.to_str() })])
			}
		}
	}

## The account's name.
name_of : Principal -> Str
name_of = |principal|
	match principal {
		Human(h) => h.name
		Agent(a) => a.name
		Bot(b) => b.name
	}

all_states : List(HumanInvite.State)
all_states = [
	Live,
	Spent,
	Revoked,
]

spell_state : HumanInvite.State -> Str
spell_state = |s|
	match s {
		Live => "live"
		Spent => "spent"
		Revoked => "revoked"
	}

all_refusals : List(HumanInvite.Refusal)
all_refusals = [
	Unknown,
	Spent,
	Revoked,
	Expired,
	NoLongerHolds,
]

spell_refusal : HumanInvite.Refusal -> Str
spell_refusal = |why|
	match why {
		Unknown => "unknown"
		Spent => "spent"
		Revoked => "revoked"
		Expired => "expired"
		NoLongerHolds => "no-longer-holds"
	}

# ── tests

## The cast and ann's invite of Zoe, human 100, applied.
zoe_made : { accounts : List(Principal), settings : Accounts.Settings }
zoe_made =
	match HumanInvite.invite({ ..asked, name: "Zoe".to_utf8() }) {
		Ok(made) => Accounts.applied(made.steps, { accounts: Cast.accounts, settings })
		Err(_) => crash "zoe_made: ann invites a free name"
	}

zoe : Principal.Id
zoe = Principal.Id.Human(Cast.hid(100))

settings : Accounts.Settings
settings = {
	first_admin: Unnamed,
	next_generation: Cast.gen(2),
	next_agent_id: Cast.aid(4),
	next_human_id: Cast.hid(100),
}

## What an invite asks, in a test.
Asked : {
	by : Principal.HumanId,
	name : List(U8),
	open : U64,
	made : U64,
	accounts : List(Principal),
	channels : List(ChannelName),
	settings : Accounts.Settings,
	now : I64,
}

asked : Asked
asked = {
	by: Cast.hid(2),
	name: "Zoe".to_utf8(),
	open: 0,
	made: 0,
	accounts: Cast.accounts,
	channels: [],
	settings,
	now: 1761600000,
}

## Zoe's live invite, made by ann.
zoe_invite : HumanInvite.Record
zoe_invite =
	match Principal.bind(zoe_made.accounts, zoe) {
		Ok(human) => {
			id: HumanInvite.InviteId.from_u64(1) ?? crash "1 is an id",
			human,
			by: Cast.hid(2),
			hash: Cast.token(7),
			created: 1761600000,
			expires: 1761600000 + HumanInvite.lifetime_secs,
			state: Live,
		}
		Err(_) => crash "zoe_invite: zoe has an account"
	}

## The renames among `steps`, as pairs.
names_set : List(Accounts.Change) -> List((Principal.Id, Str))
names_set = |steps|
	steps.join_map(
		|step|
			match step {
				SetName({ account, name }) => [(account, name)]
				_ => []
			},
	)

new_session : GitHubSignIn.NewSession
new_session = { id: Cast.sid(9), token_hash: Cast.token(8) }

## Zoe's invite redeemed at `now` with `name`, as the accounts after it.
redeemed : I64,
[Kept, Chosen(List(U8))] -> Try(
	{
		admission : HumanInvite.Admission,
		steps : List(Accounts.Change),
		spent : HumanInvite.Record,
	},
	_,
)
redeemed = |now, name|
	HumanInvite.redeem({
		record: zoe_invite,
		name,
		accounts: zoe_made.accounts,
		channels: [],
		session: new_session,
		now,
	})

# The invite makes an invited human: ann's, a member, no login, the next
# id and generation, the counters advanced first.
expect
	match Principal.find(zoe_made.accounts, zoe) {
		Ok(Human(h)) => h.sign_in == Invited(Cast.hid(2)) and h.login == "" and h.role == Member and h.name == "Zoe" and h.generation == Cast.gen(2)
		_ => Bool.False
	}
expect zoe_made.settings.next_human_id == Cast.hid(101) and zoe_made.settings.next_generation == Cast.gen(3)
# Its refusals.
expect
	match HumanInvite.invite({ ..asked, name: "H1".to_utf8() }) {
		Err(NameTaken) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.invite({ ..asked, name: "h1".to_utf8() }) {
		Err(NameTaken) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.invite({ ..asked, name: "a3".to_utf8() }) {
		Err(NameTaken) => Bool.True
		_ => Bool.False
	}
# A channel's name is taken as an account's is, in any case; a near miss
# is free.
roc_chat_dev : List(ChannelName)
roc_chat_dev = [ChannelName.from_str("RocChatDev") ?? crash "roc_chat_dev: a channel name"]

## Ann's invite of `name`, beside the channel RocChatDev.
beside_channel : Str -> Asked
beside_channel = |name| {
	..asked,
	name: name.to_utf8(),
	channels: roc_chat_dev,
}

expect
	match HumanInvite.invite(beside_channel("rocchatdev")) {
		Err(NameTaken) => Bool.True
		_ => Bool.False
	}
expect HumanInvite.invite(beside_channel("RocChatDev2")).is_ok()
expect
	match HumanInvite.redeem({
		record: zoe_invite,
		name: Chosen("RocChatDev".to_utf8()),
		accounts: zoe_made.accounts,
		channels: roc_chat_dev,
		session: new_session,
		now: 1761600100,
	}) {
		Err(NameTaken) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.invite({ ..asked, name: "".to_utf8() }) {
		Err(NameRefused(_)) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.invite({ ..asked, by: Cast.hid(9) }) {
		Err(NoSuchInviter) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.invite({ ..asked, open: 9 }) {
		Ok(_) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.invite({ ..asked, open: 10 }) {
		Err(Capped(OpenInvites)) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.invite({ ..asked, made: 200 }) {
		Err(Capped(Made)) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.invite({ ..asked, now: -1 }) {
		Err(ClockOutOfRange) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.invite({ ..asked, settings: { ..settings, next_human_id: Cast.hid(2) } }) {
		Err(Stuck(StaleHumanId)) => Bool.True
		_ => Bool.False
	}

# A redemption signs zoe in, bound to her account; the invite spent.
expect
	match redeemed(1761600100, Kept) {
		Ok(r) => r.admission.facts().human == Cast.hid(100) and r.admission.facts().generation == Cast.gen(2) and r.steps.is_empty() and r.spent.state == Spent
		Err(_) => Bool.False
	}
# Another name, free: hers; her own in a new spelling, the spelling.
expect
	match redeemed(1761600100, Chosen("Zed".to_utf8())) {
		Ok(r) => names_set(r.steps) == [(zoe, "Zed")]
		Err(_) => Bool.False
	}
expect
	match redeemed(1761600100, Chosen("ZOE".to_utf8())) {
		Ok(r) => names_set(r.steps) == [(zoe, "ZOE")]
		Err(_) => Bool.False
	}
expect
	match redeemed(1761600100, Chosen("Zoe".to_utf8())) {
		Ok(r) => r.steps.is_empty()
		Err(_) => Bool.False
	}
expect
	match redeemed(1761600100, Chosen("H2".to_utf8())) {
		Err(NameTaken) => Bool.True
		_ => Bool.False
	}
expect
	match redeemed(1761600100, Chosen("".to_utf8())) {
		Err(NameRefused(_)) => Bool.True
		_ => Bool.False
	}
# Its refusals: expired at its expiry (live just before), spent, revoked,
# its account retired, a clock out of range.
expect redeemed(1761600000 + HumanInvite.lifetime_secs - 1, Kept).is_ok()
expect
	match redeemed(1761600000 + HumanInvite.lifetime_secs, Kept) {
		Err(Refused(Expired)) => Bool.True
		_ => Bool.False
	}
expect
	match redeemed(-1, Kept) {
		Err(Refused(Expired)) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.redeem({
		record: { ..zoe_invite, state: Spent },
		name: Kept,
		accounts: zoe_made.accounts,
		channels: [],
		session: new_session,
		now: 1761600100,
	}) {
		Err(Refused(Spent)) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.redeem({
		record: { ..zoe_invite, state: Revoked },
		name: Kept,
		accounts: zoe_made.accounts,
		channels: [],
		session: new_session,
		now: 1761600100,
	}) {
		Err(Refused(Revoked)) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.redeem({
		record: zoe_invite,
		name: Kept,
		accounts: Cast.accounts,
		channels: [],
		session: new_session,
		now: 1761600100,
	}) {
		Err(Refused(NoLongerHolds)) => Bool.True
		_ => Bool.False
	}

## A re-invite of zoe asked by `asker`, with no invites open.
reinvited : U64 -> Try(Principal.Bound, _)
reinvited = |asker|
	HumanInvite.reinvite({
		asker: Cast.hid(asker),
		human: Cast.hid(100),
		open: 0,
		made: 0,
		accounts: zoe_made.accounts,
	})

# Re-invited by her inviter or an admin; by nobody else; a human who signs
# in by GitHub is never re-invited; the caps hold.
expect reinvited(2) == Principal.bind(zoe_made.accounts, zoe).map_err(|_| NoSuchHuman)
expect reinvited(1).is_ok()
expect
	match HumanInvite.reinvite({
		asker: Cast.hid(2),
		human: Cast.hid(100),
		open: 0,
		made: 0,
		accounts: zoe_made.accounts.append(Cast.person(3, Member)),
	}) {
		Ok(_) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.reinvite({
		asker: Cast.hid(3),
		human: Cast.hid(100),
		open: 0,
		made: 0,
		accounts: zoe_made.accounts.append(Cast.person(3, Member)),
	}) {
		Err(NotYours) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.reinvite({
		asker: Cast.hid(1),
		human: Cast.hid(2),
		open: 0,
		made: 0,
		accounts: zoe_made.accounts,
	}) {
		Err(SignsInByGitHub) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.reinvite({
		asker: Cast.hid(2),
		human: Cast.hid(77),
		open: 0,
		made: 0,
		accounts: zoe_made.accounts,
	}) {
		Err(NoSuchHuman) => Bool.True
		_ => Bool.False
	}
expect
	match HumanInvite.reinvite({
		asker: Cast.hid(2),
		human: Cast.hid(100),
		open: 10,
		made: 0,
		accounts: zoe_made.accounts,
	}) {
		Err(Capped(OpenInvites)) => Bool.True
		_ => Bool.False
	}

# Revoked once; not again.
expect HumanInvite.revoke(zoe_invite).map_ok(|r| r.state) == Ok(Revoked)
expect HumanInvite.revoke({ ..zoe_invite, state: Spent }) == Err(NotLive)
expect HumanInvite.default_welcome("Steve") == "Hi! This is an automated message from Steve"

# ── ITS LINE: what it writes, round trips, and each malformed line by name.
## Zoe's invite, by ann, as it is made.
fresh : HumanInvite.Record
fresh = {
	id: HumanInvite.InviteId.from_u64(3) ?? crash "3 is an id",
	human: {
		id: Principal.Id.Human(Cast.hid(100)),
		generation: Cast.gen(2),
		human: Cast.gen(2),
	},
	by: Cast.hid(2),
	hash: Cast.token(0x22),
	created: 1761600000,
	expires: 1762204800,
	state: Live,
}

fresh_line : Str
fresh_line = "human-invite v1 id=3 for=human:100/2/2 by=human:2 hash=${Str.repeat("22", 32)} created=1761600000 expires=1762204800 state=live\n"

## The fresh line with `from` replaced by `to`, decoded.
fresh_but : { from : Str, to : Str } -> Try({}, _)
fresh_but = |
	{
		from,
		to,
	},
| HumanInvite.decode(fresh_line.replace_first(from, to).to_utf8()).map_ok(|_| {})

expect HumanInvite.encode(fresh) == fresh_line.to_utf8()
expect HumanInvite.decode(HumanInvite.encode(fresh)) == Ok(fresh)
expect
	[Spent, Revoked].all(
		|state| {
			r = { ..fresh, state }
			HumanInvite.decode(HumanInvite.encode(r)) == Ok(r)
		},
	)
expect fresh_but({ from: "", to: "" }) == Ok({})
expect fresh_but({ from: "human-invite", to: "invite" }) == Err(WrongRecord)
expect fresh_but({ from: "for=human:100", to: "for=agent:100" }) == Err(BadValue("for"))
expect fresh_but({ from: "by=human:2", to: "by=agent:2" }) == Err(BadValue("by"))
expect fresh_but({
	from: "expires=1762204800",
	to: "expires=1761600000",
}) == Err(BadValue("expires"))
expect fresh_but({ from: "state=live", to: "state=open" }) == Err(UnknownWord("state"))
expect fresh_but({ from: " by=human:2", to: "" }) == Err(MissingField("by"))
expect fresh_but({ from: "state=live", to: "state=live extra=1" }).is_err()
expect all_refusals.all(|why| HumanInvite.refusal_from(HumanInvite.refusal_text(why).to_utf8()) == Ok(why))
expect HumanInvite.refusal_from("grant:x".to_utf8()) == Err(UnknownWord("verdict"))

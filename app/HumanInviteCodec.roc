## **A HUMAN INVITE, STORED** (HumanInvite decides): one line in Stored's
## format, its code's hash and never the code, which the inviter is shown
## once and hands on:
##
##     human-invite v1 id=3 for=human:100/2/2 by=human:2 hash=<64 hex digits> created=1761600000 expires=1762204800 state=live
##
## `for` is the invited human, bound as their account is (AccountCodec's
## `bound_text`); `by` the human who made it, the inviter or an admin
## re-inviting. The state is `live` until it is `spent` (redeemed, once)
## or `revoked`. A redemption's refusals are spelled here too, so the audit
## spells them (AuditLog) without asking the wire. Pure.
import AccountCodec
import Cast
import HumanInvite
import Principal
import Stored

HumanInviteCodec := [].{

	## The record's line.
	encode : HumanInvite.Record -> List(U8)
	encode = |r|
		Stored.line(
			"human-invite",
			[
				("id", r.id.to_u64().to_str()),
				("for", AccountCodec.bound_text(r.human)),
				("by", AccountCodec.id_text(Principal.Id.Human(r.by))),
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
		human = AccountCodec.bound_from(for_field.value, "for")?
		by_field = for_field.rest.field("by")?
		by = AccountCodec.id_from(by_field.value, "by")?
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
| HumanInviteCodec.decode(fresh_line.replace_first(from, to).to_utf8()).map_ok(|_| {})

expect HumanInviteCodec.encode(fresh) == fresh_line.to_utf8()
expect HumanInviteCodec.decode(HumanInviteCodec.encode(fresh)) == Ok(fresh)
expect
	[Spent, Revoked].all(
		|state| {
			r = { ..fresh, state }
			HumanInviteCodec.decode(HumanInviteCodec.encode(r)) == Ok(r)
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
expect all_refusals.all(|why| HumanInviteCodec.refusal_from(HumanInviteCodec.refusal_text(why).to_utf8()) == Ok(why))
expect HumanInviteCodec.refusal_from("grant:x".to_utf8()) == Err(UnknownWord("verdict"))

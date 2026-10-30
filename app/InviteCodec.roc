## **AN AGENT'S INVITE, STORED**: a short-lived invite (ten minutes), so
## humans never pass a durable secret around. One line in Stored's format, the code's hash and never
## the code, which the human is shown once and hands to their agent:
##
##     invite v1 id=3 for=agent:7 generation=5 human-generation=4 by=session:<64 hex digits> hash=<64 hex digits> created=1761600000 expires=1761600600 state=live lifetime=31536000 read=everywhere post=everywhere admin=off
##
## `for` is the agent or bot the key will act as, bound to its account's
## generation and its owner's (Principal.Bound), as a key is: an agent
## retired, or its owner, and the invite redeems to nothing. `by` is the
## granter who asked for it, by the hash it is stored by (a session's; a
## key's is never granted, ApiKey.may_grant refusing it): the redemption
## grants as that granter, so may_grant decides it again against the
## accounts then. `expires` is the invite's own; `lifetime` and the scope are the
## key's it redeems to. The state is `live` until it is `spent` (redeemed,
## once) or `revoked`.
##
## The refusals of a redemption are here too, so the audit spells them
## (AuditCodec) without asking the wire. Pure.
import AccountCodec
import ApiKey
import Bytes
import Cast
import KeyCodec
import Principal
import Stored

InviteCodec := [].{

	## An invite's public id, shown in a listing and the audit; never its
	## code. Opaque: made only by `from_u64`, which refuses 0.
	InviteId :: U64.{
		from_u64 : U64 -> Try(InviteCodec.InviteId, [NotAnId])
		from_u64 = |n| if (n == 0) Err(NotAnId) else Ok(InviteCodec.InviteId.(n))

		to_u64 : InviteCodec.InviteId -> U64
		to_u64 = |InviteCodec.InviteId.(n)| n

		is_eq : _
	}

	## **WHO ASKED FOR AN INVITE**: the granter, by the hash the store
	## keeps it by (Store.load_session!, Store.load_key!).
	By : [Session(Stored.SecretHash), Key(Stored.SecretHash)]

	## Where an invite is: redeemable, redeemed once, or revoked.
	State : [
		Live,
		Spent,
		Revoked,
	]

	## **AN INVITE'S WHOLE RECORD**.
	Record(id) : {
		id : InviteCodec.InviteId,
		bound : Principal.Bound,
		by : InviteCodec.By,
		hash : Stored.SecretHash,
		created : I64,
		expires : I64,
		state : InviteCodec.State,
		lifetime : I64,
		scope : KeyCodec.Scope(id),
	}

	## **WHY A REDEMPTION IS REFUSED**, each audited, and each the same
	## 401 on the wire. **ONE ALIAS ON PURPOSE**: Agents and the audit share
	## it, and the audit's record of a redemption round-trips each tag.
	Refusal : [
		## No invite's hash is the code's.
		Unknown,

		## Redeemed before: an invite is spent by its first redemption.
		Spent,

		## Its human revoked it.
		Revoked,

		## Past its expiry.
		Expired,

		## Sent with a cookie or a Bearer key: the code is the credential,
		## and which one counts is never guessed.
		CredentialSent,

		## The agent's account, or its owner's, is not the one it was
		## invited as (retired, or made again).
		NoLongerHolds,

		## The grant, decided again at redemption as the inviting session's,
		## is refused (ApiKey.may_grant): the session over, its human gone.
		Grant(ApiKey.GrantRefusal),
	]

	## The record's line, an id spelled by `number`.
	encode : InviteCodec.Record(id), (id -> U64) -> List(U8)
	encode = |r, number|
		Stored.line(
			"invite",
			[
				("id", r.id.to_u64().to_str()),
				("for", AccountCodec.id_text(r.bound.id)),
				("generation", r.bound.generation.to_u64().to_str()),
				("human-generation", r.bound.human.to_u64().to_str()),
				("by", by_text(r.by)),
				("hash", Stored.hash_text(r.hash)),
				("created", Stored.time_text(r.created)),
				("expires", Stored.time_text(r.expires)),
				("state", spell_state(r.state)),
				("lifetime", r.lifetime.to_str()),
				("read", KeyCodec.reach_text(r.scope.read, number)),
				("post", KeyCodec.reach_text(r.scope.post, number)),
				("admin", KeyCodec.admin_text(r.scope.admin)),
			],
		)

	## The record a line holds, an id read by `make`; refused when it is for
	## a human (an invite is for an agent or a bot), expires before it was
	## made, or names a key's lifetime no grant gives.
	decode : List(U8), (U64 -> Try(id, [NotAnId])) -> Try(InviteCodec.Record(id), Stored.Problem)
	decode = |raw, make| {
		fields = Stored.Reader.open(raw, "invite")?
		id_field = fields.field("id")?
		id = Stored.id(id_field.value, { name: "id", make: InviteCodec.InviteId.from_u64 })?
		for_field = id_field.rest.field("for")?
		invited = AccountCodec.id_from(for_field.value, "for")?
		generation_field = for_field.rest.field("generation")?
		generation = Stored.id(
			generation_field.value,
			{ name: "generation", make: Principal.Generation.from_u64 },
		)?
		human_field = generation_field.rest.field("human-generation")?
		human = Stored.id(
			human_field.value,
			{ name: "human-generation", make: Principal.Generation.from_u64 },
		)?
		by_field = human_field.rest.field("by")?
		by = by_from(by_field.value)?
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
				all: all_states,
				spell: spell_state,
			},
		)?
		lifetime_field = state_field.rest.field("lifetime")?
		lifetime = Stored.time(lifetime_field.value, "lifetime")?
		read_field = lifetime_field.rest.field("read")?
		read = KeyCodec.reach_from(read_field.value, { name: "read", make })?
		post_field = read_field.rest.field("post")?
		post = KeyCodec.reach_from(post_field.value, { name: "post", make })?
		admin_field = post_field.rest.field("admin")?
		admin = KeyCodec.admin_from(admin_field.value)?
		admin_field.rest.close()?
		match invited {
			Human(_) => Err(BadValue("for"))
			_ if expires <= created => Err(BadValue("expires"))
			_ if !InviteCodec.is_key_lifetime(lifetime) => Err(BadValue("lifetime"))
			_ => Ok({
				id,
				bound: {
					id: invited,
					generation,
					human,
				},
				by,
				hash,
				created,
				expires,
				state,
				lifetime,
				scope: {
					read,
					post,
					admin,
				},
			})
		}
	}

	## **A KEY'S LIFETIME AN INVITE MAY CARRY**: more than no time, and a
	## year at most (KeyCodec.max_lifetime_secs), as a mint's.
	is_key_lifetime : I64 -> Bool
	is_key_lifetime = |secs| secs > 0 and secs <= KeyCodec.max_lifetime_secs

	## **A REDEMPTION'S REFUSAL, AS THE AUDIT SPELLS IT**: a word, a grant's
	## after `grant:` in ApiKey's words (`spell_grant`).
	refusal_text : InviteCodec.Refusal, (ApiKey.GrantRefusal -> Str) -> Str
	refusal_text = |why, spell_grant|
		match why {
			Grant(g) => "${grant_prefix}${spell_grant(g)}"
			Unknown => spell_plain(Unknown)
			Spent => spell_plain(Spent)
			Revoked => spell_plain(Revoked)
			Expired => spell_plain(Expired)
			CredentialSent => spell_plain(CredentialSent)
			NoLongerHolds => spell_plain(NoLongerHolds)
		}

	## The refusal a word names, a grant's read by `grant_from`.
	refusal_from : List(U8),
	(
		List(U8) -> Try(
			ApiKey.GrantRefusal,
			Stored.Problem,
		)) -> Try(InviteCodec.Refusal, Stored.Problem)
	refusal_from = |value, grant_from|
		match Bytes.strip_prefix(value, Str.to_utf8(grant_prefix)) {
			Ok(g) => grant_from(g).map_ok(|r| Grant(r))
			Err(NoMatch) =>
				match Stored.word(
					value,
					{
						name: "verdict",
						all: all_plain,
						spell: spell_plain,
					},
				)? {
					Unknown => Ok(Unknown)
					Spent => Ok(Spent)
					Revoked => Ok(Revoked)
					Expired => Ok(Expired)
					CredentialSent => Ok(CredentialSent)
					NoLongerHolds => Ok(NoLongerHolds)
				}
		}
}

grant_prefix : Str
grant_prefix = "grant:"

session_prefix : Str
session_prefix = "session:"

key_prefix : Str
key_prefix = "key:"

## `session:` or `key:` and the hash.
by_text : InviteCodec.By -> Str
by_text = |by|
	match by {
		Session(h) => "${session_prefix}${Stored.hash_text(h)}"
		Key(h) => "${key_prefix}${Stored.hash_text(h)}"
	}

by_from : List(U8) -> Try(InviteCodec.By, Stored.Problem)
by_from = |value|
	match (
		Bytes.strip_prefix(value, Str.to_utf8(session_prefix)),
		Bytes.strip_prefix(value, Str.to_utf8(key_prefix)),
	) {
		(Ok(h), _) => Stored.hash(h, "by").map_ok(|hash| Session(hash))
		(_, Ok(h)) => Stored.hash(h, "by").map_ok(|hash| Key(hash))
		_ => Err(UnknownWord("by"))
	}

Plain : [
	Unknown,
	Spent,
	Revoked,
	Expired,
	CredentialSent,
	NoLongerHolds,
]

all_plain : List(Plain)
all_plain = [
	Unknown,
	Spent,
	Revoked,
	Expired,
	CredentialSent,
	NoLongerHolds,
]

spell_plain : Plain -> Str
spell_plain = |p|
	match p {
		Unknown => "unknown"
		Spent => "spent"
		Revoked => "revoked"
		Expired => "expired"
		CredentialSent => "credential-sent"
		NoLongerHolds => "no-longer-holds"
	}

all_states : List(InviteCodec.State)
all_states = [
	Live,
	Spent,
	Revoked,
]

spell_state : InviteCodec.State -> Str
spell_state = |s|
	match s {
		Live => "live"
		Spent => "spent"
		Revoked => "revoked"
	}

# ── tests
## A test's hash: every byte `b`.
hash_of : U8 -> Stored.SecretHash
hash_of = |b|
	match Stored.SecretHash.from_bytes(List.repeat(b, 32)) {
		Ok(h) => h
		Err(NotAHash) => crash "hash_of: 32 bytes are a hash"
	}

## A test's invite id.
iid : U64 -> InviteCodec.InviteId
iid = |n|
	match InviteCodec.InviteId.from_u64(n) {
		Ok(id) => id
		Err(NotAnId) => crash "iid: a test's invite id is not 0"
	}

## A conversation's number, as a test's lines hold it.
number : U64 -> Try(U64, [NotAnId])
number = |n| if (n == 0) Err(NotAnId) else Ok(n)

## Agent 7's invite, as it is made: live, everywhere, no admin, a year's key.
fresh : InviteCodec.Record(U64)
fresh = {
	id: iid(3),
	bound: {
		id: Principal.Id.Agent(Cast.aid(7)),
		generation: Cast.gen(5),
		human: Cast.gen(4),
	},
	by: Session(hash_of(0x11)),
	hash: hash_of(0x22),
	created: 1761600000,
	expires: 1761600600,
	state: Live,
	lifetime: KeyCodec.max_lifetime_secs,
	scope: {
		read: On(Everywhere),
		post: On(Everywhere),
		admin: Off,
	},
}

## Every part at its other value: a bot's, spent, narrowed, admin, a minute.
other : InviteCodec.Record(U64)
other = {
	..fresh,
	bound: { ..fresh.bound, id: Principal.Id.Bot(Cast.aid(9)) },
	state: Spent,
	lifetime: 60,
	scope: {
		read: On(Only([3, 9])),
		post: Off,
		admin: On,
	},
}

line_of : InviteCodec.Record(U64) -> Str
line_of = |r|
	match Str.from_utf8(InviteCodec.encode(r, |n| n)) {
		Ok(s) => s
		Err(_) => crash "line_of: a line is UTF-8"
	}

expect line_of(fresh) == "invite v1 id=3 for=agent:7 generation=5 human-generation=4 by=session:${"11".repeat(32)} hash=${"22".repeat(32)} created=1761600000 expires=1761600600 state=live lifetime=31536000 read=everywhere post=everywhere admin=off\n"
expect InviteCodec.decode(InviteCodec.encode(fresh, |n| n), number) == Ok(fresh)
expect InviteCodec.decode(InviteCodec.encode(other, |n| n), number) == Ok(other)
expect InviteCodec.decode(
	InviteCodec.encode({ ..fresh, state: Revoked }, |n| n),
	number,
) == Ok({ ..fresh, state: Revoked })

## `fresh`'s line with `from` made `to`, decoded.
decoded_but : { from : Str, to : Str } -> Try({}, Stored.Problem)
decoded_but = |{ from, to }| InviteCodec.decode(
	line_of(fresh).replace_first(from, to).to_utf8(),
	number,
).map_ok(|_| {})

expect decoded_but({ from: "for=agent:7", to: "for=human:7" }) == Err(BadValue("for"))
expect decoded_but({
	from: "expires=1761600600",
	to: "expires=1761600000",
}) == Err(BadValue("expires"))
expect decoded_but({
	from: "lifetime=31536000",
	to: "lifetime=31536001",
}) == Err(BadValue("lifetime"))
expect decoded_but({ from: "lifetime=31536000", to: "lifetime=0" }) == Err(BadValue("lifetime"))
expect decoded_but({ from: "state=live", to: "state=used" }) == Err(UnknownWord("state"))
expect decoded_but({ from: "id=3", to: "id=0" }) == Err(BadValue("id"))
expect decoded_but({ from: " by=", to: " from=" }) == Err(MissingField("by"))
expect decoded_but({ from: "by=session:", to: "by=cookie:" }) == Err(UnknownWord("by"))
expect decoded_but({ from: "by=session:11", to: "by=session:1" }) == Err(BadValue("by"))
expect InviteCodec.decode(
	InviteCodec.encode({ ..fresh, by: Key(hash_of(0x33)) }, |n| n),
	number,
) == Ok({ ..fresh, by: Key(hash_of(0x33)) })
expect decoded_but({ from: "admin=off", to: "admin=off x=1" }) == Err(Trailing)

## A grant's refusal, as a test spells and reads it.
grant_word : ApiKey.GrantRefusal -> Str
grant_word = |g|
	match g {
		SessionExpired => "session-expired"
		_ => "other"
	}

grant_back : List(U8) -> Try(ApiKey.GrantRefusal, Stored.Problem)
grant_back = |w| if (w == "session-expired".to_utf8()) Ok(SessionExpired) else Err(UnknownWord("verdict"))

refusals : List(InviteCodec.Refusal)
refusals = [
	Unknown,
	Spent,
	Revoked,
	Expired,
	CredentialSent,
	NoLongerHolds,
	Grant(SessionExpired),
]

expect refusals.all(
	|r| InviteCodec.refusal_from(
		InviteCodec.refusal_text(r, grant_word).to_utf8(),
		grant_back,
	) == Ok(r),
)
expect InviteCodec.refusal_text(Grant(SessionExpired), grant_word) == "grant:session-expired"
expect InviteCodec.refusal_from("stale".to_utf8(), grant_back) == Err(UnknownWord("verdict"))

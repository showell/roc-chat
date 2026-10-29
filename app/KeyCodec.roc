## **AN API KEY, STORED** (the Roc chat's auth design, sections 3 and 9):
## one line in Stored's format, the key's hash and never the key, which its
## owner is shown once:
##
##     key v1 id=4 acts=agent:7 generation=4 human-generation=3 hash=<64 hex digits> created=1761600000 expires=1793136000 state=active read=only:3,9 post=off admin=off
##
## `generation` is the generation of its principal's account, and
## `human-generation` that of the human it answers to (itself, or the owner
## of its agent or bot), when it was granted (Principal.Bound): the key is
## those accounts', never ones made again later with the same ids. A human's
## key holds one generation twice; a line whose two differ is refused
## (`BadValue("human-generation")`), as no grant makes one. The record's types are here, the store's shape of a
## key, and ApiKey's are these; the line is generic over the resource's id,
## its spelling a number (`make` reads one back, `number` writes it).
##
## **`decode` GIVES A LINE, AND A LINE IS THE ONLY WAY BACK TO A KEY**: an
## opaque value only this module makes, and the only thing ApiKey.Key.load
## takes. No handler loads a key from a record it built; a key comes from
## a grant (ApiKey.Key.issue) or from a stored line.
##
## **ONE SPELLING PER VALUE**: a read or a post reach is `off`,
## `everywhere`, or `only:` and its ids, ascending, each once. `encode`
## writes that spelling (a list sorted, a repeat dropped, an empty list
## `off`, which reaches the same nothing), and `decode` refuses every other
## (`only:9,3,3`, `only:`): two lines with one meaning are never both
## valid. A key acting as a bot with admin on is refused (`AdminForBot`):
## no grant makes one (a bot is never an admin), so the record is not one
## the chat wrote.
##
## **A LINE PROVES THE PATH, NOT THE SOURCE** (as SessionCodec says): the
## decoder accepts any bytes, so a Line proves its checks ran, not that its
## bytes came from the store; provenance needs an opaque read value from
## the platform, a host task. Pure.
import AccountCodec
import Bytes
import Cast
import Principal
import Stored

KeyCodec := [].{

	## Where a read or a post reaches: every resource its principal may
	## reach, or only the listed ones (a bot that posts only to #commits).
	Reach(id) : [Everywhere, Only(List(id))]

	## **WHAT A KEY MAY DO**, each part on or off. Admin is a scope of its
	## own: an admin-only key reads nothing.
	Scope(id) : {
		read : [Off, On(KeyCodec.Reach(id))],
		post : [Off, On(KeyCodec.Reach(id))],
		admin : [Off, On],
	}

	## **THE LONGEST A KEY LIVES**, in seconds: 365 days. Every key expires
	## (no grant makes one that never does), so a key lost or forgotten is
	## good for a year at most, and its expiry always fits the store.
	max_lifetime_secs : I64
	max_lifetime_secs = 31536000

	## **AN EXPIRY A GRANT MAKES**: after the key's creation, at most
	## `max_lifetime_secs` after it, and no later than Stored's last time.
	## The one home of the rule: the grant asks it (ApiKey.Key.issue), and
	## the decoder refuses a line that breaks it, as no grant wrote one.
	is_fitting_expiry : { created : I64, expires : I64 } -> Bool
	is_fitting_expiry = |{ created, expires }|
		expires > created and expires.to_i128() - created.to_i128() <= KeyCodec.max_lifetime_secs.to_i128() and expires <= Stored.max_time

	## **A KEY'S WHOLE RECORD**: its id, the principal it acts as, the
	## generations it is bound to, its scope, when it was made and when it
	## expires (unix seconds: expired from then on), and its revocation.
	Record(id) : {
		id : Principal.KeyId,
		acts_as : Principal.Id,
		generation : Principal.Generation,
		human_generation : Principal.Generation,
		scope : KeyCodec.Scope(id),
		created : I64,
		expires : I64,
		revocation : [Active, Revoked],
	}

	## **WHAT THE STORE KEEPS OF A KEY**: its record, and the hash the host
	## looks it up by.
	Entry(id) : {
		record : KeyCodec.Record(id),
		hash : Stored.SecretHash,
	}

	## **A LINE THAT DECODED**: its entry, every field checked. Opaque:
	## made only by `decode`.
	Line(id) :: KeyCodec.Entry(id).{

		## The line's entry, for ApiKey.Key.load.
		entry : KeyCodec.Line(id) -> KeyCodec.Entry(id)
		entry = |KeyCodec.Line.(e)| e
	}

	## **A READ'S OR A POST'S REACH, IN ITS ONE SPELLING** (`off`,
	## `everywhere`, `only:3,9`): what a line holds, and what a grant's form
	## and a key's listing say.
	reach_text : [Off, On(KeyCodec.Reach(id))], (id -> U64) -> Str
	reach_text = |part, number| reach_text_of(part, number)

	## **ADMIN, IN ITS ONE SPELLING** (`on`, `off`), and back: what a key's
	## line holds, and an invite's (InviteCodec).
	admin_text : [Off, On] -> Str
	admin_text = |s| spell_switch(s)

	## The switch a stored `admin` field's value spells.
	admin_from : List(U8) -> Try([Off, On], Stored.Problem)
	admin_from = |value| Stored.word(
		value,
		{
			name: "admin",
			all: all_switches,
			spell: spell_switch,
		},
	)

	## The reach a spelling names, as the decoder reads a line's.
	reach_from : List(U8),
	{
		name : Str,
		make : (U64 -> Try(id, [NotAnId])),
	} -> Try([Off, On(KeyCodec.Reach(id))], Stored.Problem)
	reach_from = |value, named| reach_from_text(value, named)

	## The entry's line, an id spelled by `number`, in the one spelling.
	encode : KeyCodec.Entry(id), (id -> U64) -> List(U8)
	encode = |{ record, hash }, number|
		Stored.line(
			"key",
			[
				("id", record.id.to_u64().to_str()),
				("acts", AccountCodec.id_text(record.acts_as)),
				("generation", record.generation.to_u64().to_str()),
				("human-generation", record.human_generation.to_u64().to_str()),
				("hash", Stored.hash_text(hash)),
				("created", Stored.time_text(record.created)),
				("expires", Stored.time_text(record.expires)),
				("state", spell_revocation(record.revocation)),
				("read", reach_text_of(record.scope.read, number)),
				("post", reach_text_of(record.scope.post, number)),
				("admin", spell_switch(record.scope.admin)),
			],
		)

	## The entry a line holds, an id read by `make`, or the line's problem.
	decode : List(U8), (U64 -> Try(id, [NotAnId])) -> Try(KeyCodec.Line(id), Stored.Problem)
	decode = |raw, make| {
		fields = Stored.Reader.open(raw, "key")?
		id_field = fields.field("id")?
		id = Stored.id(id_field.value, { name: "id", make: Principal.KeyId.from_u64 })?
		acts_field = id_field.rest.field("acts")?
		acts_as = AccountCodec.id_from(acts_field.value, "acts")?
		generation_field = acts_field.rest.field("generation")?
		generation = Stored.id(
			generation_field.value,
			{ name: "generation", make: Principal.Generation.from_u64 },
		)?
		human_field = generation_field.rest.field("human-generation")?
		human_generation = Stored.id(
			human_field.value,
			{ name: "human-generation", make: Principal.Generation.from_u64 },
		)?
		hash_field = human_field.rest.field("hash")?
		hash = Stored.hash(hash_field.value, "hash")?
		created_field = hash_field.rest.field("created")?
		created = Stored.time(created_field.value, "created")?
		expires_field = created_field.rest.field("expires")?
		expires = Stored.time(expires_field.value, "expires")?
		state_field = expires_field.rest.field("state")?
		revocation = Stored.word(
			state_field.value,
			{
				name: "state",
				all: all_revocations,
				spell: spell_revocation,
			},
		)?
		read_field = state_field.rest.field("read")?
		read = reach_from_text(read_field.value, { name: "read", make })?
		post_field = read_field.rest.field("post")?
		post = reach_from_text(post_field.value, { name: "post", make })?
		admin_field = post_field.rest.field("admin")?
		admin = KeyCodec.admin_from(admin_field.value)?
		admin_field.rest.close()?
		match (acts_as, admin) {
			(Bot(_), On) => Err(AdminForBot)
			(Human(_), _) if generation != human_generation => Err(BadValue("human-generation"))
			_ if !KeyCodec.is_fitting_expiry({ created, expires }) => Err(BadValue("expires"))
			_ =>
				Ok(
					KeyCodec.Line.(
						{
							record: {
								id,
								acts_as,
								generation,
								human_generation,
								scope: {
									read,
									post,
									admin,
								},
								created,
								expires,
								revocation,
							},
							hash,
						},
					),
				)
		}
	}
}

Revocation : [Active, Revoked]

all_revocations : List(Revocation)
all_revocations = [Active, Revoked]

spell_revocation : Revocation -> Str
spell_revocation = |r|
	match r {
		Active => "active"
		Revoked => "revoked"
	}

Switch : [Off, On]

all_switches : List(Switch)
all_switches = [Off, On]

spell_switch : Switch -> Str
spell_switch = |s|
	match s {
		Off => "off"
		On => "on"
	}

ReachPart(id) : [Off, On(KeyCodec.Reach(id))]

## **THE ONE SPELLING OF A REACH**: `off`, `everywhere`, or `only:` and the
## ids, ascending, each once, commas between; a list with no id reaches
## nothing, which is `off`.
reach_text_of : ReachPart(id), (id -> U64) -> Str
reach_text_of = |part, number|
	match part {
		Off => spell_switch(Off)
		On(Everywhere) => everywhere_word
		On(Only(ids)) =>
			match ascending_once(List.map(ids, number)) {
				[] => spell_switch(Off)
				numbers => "${only_prefix}${Str.join_with(List.map(numbers, U64.to_str), ",")}"
			}
	}

## The numbers ascending, each once.
ascending_once : List(U64) -> List(U64)
ascending_once = |numbers|
	List.fold(
		numbers,
		[],
		|sorted, n| {
			below = List.keep_if(sorted, |m| m < n)
			above = List.keep_if(sorted, |m| m > n)
			List.concat(List.append(below, n), above)
		},
	)

reach_from_text : List(U8),
{
	name : Str,
	make : (U64 -> Try(id, [NotAnId])),
} -> Try(ReachPart(id), Stored.Problem)
reach_from_text = |value, { name, make }|
	if value == Str.to_utf8(spell_switch(Off)) {
		Ok(Off)
	} else if value == Str.to_utf8(everywhere_word) {
		Ok(On(Everywhere))
	} else {
		match Bytes.strip_prefix(value, Str.to_utf8(only_prefix)) {
			Err(NoMatch) => Err(UnknownWord(name))
			Ok([]) => Err(BadValue(name))
			Ok(listed) => {
				numbers = List.map_try(List.split_on(listed, ','), |c| Stored.count(c, name))?
				if ascending_once(numbers) != numbers {
					Err(BadValue(name))
				} else {
					ids = List.map_try(
						numbers,
						|n|
							match make(n) {
								Ok(made) => Ok(made)
								Err(_) => Err(BadValue(name))
							},
					)?
					Ok(On(Only(ids)))
				}
			}
		}
	}

everywhere_word : Str
everywhere_word = "everywhere"

only_prefix : Str
only_prefix = "only:"

# ── tests
# The id a test's lines hold: a conversation's number, any but 0.
Conv :: U64.{
	from_u64 : U64 -> Try(Conv, [NotAnId])
	from_u64 = |n| if n == 0 Err(NotAnId) else Ok(Conv.(n))

	to_u64 : Conv -> U64
	to_u64 = |Conv.(n)| n

	is_eq : _
}

conv : U64 -> Conv
conv = |n|
	match Conv.from_u64(n) {
		Ok(id) => id
		Err(NotAnId) => crash "conv: a test's conversation id is not 0"
	}

## A test's hash: every byte `b`.
hash_of : U8 -> Stored.SecretHash
hash_of = |b|
	match Stored.SecretHash.from_bytes(List.repeat(b, 32)) {
		Ok(h) => h
		Err(NotAHash) => crash "hash_of: 32 bytes are a hash"
	}

## An entry for the record `r`.
entry : KeyCodec.Record(Conv) -> KeyCodec.Entry(Conv)
entry = |r| {
	record: r,
	hash: hash_of(0x5a),
}

## A commit bot's key: agent 7, reading #3 and #9 alone.
narrow : KeyCodec.Record(Conv)
narrow = {
	id: Cast.kid(4),
	acts_as: Principal.Id.Agent(Cast.aid(7)),
	generation: Cast.gen(4),
	human_generation: Cast.gen(3),
	scope: {
		read: On(Only([conv(3), conv(9)])),
		post: Off,
		admin: Off,
	},
	created: 1761600000,
	expires: 1793136000,
	revocation: Active,
}

## Every part of a record at its other value: a human's, everywhere, admin,
## expiring, revoked.
broad : KeyCodec.Record(Conv)
broad = {
	id: Cast.kid(18446744073709551615),
	acts_as: Principal.Id.Human(Cast.gid(583231)),
	generation: Cast.gen(18446744073709551615),
	human_generation: Cast.gen(18446744073709551615),
	scope: {
		read: On(Everywhere),
		post: On(Only([conv(1)])),
		admin: On,
	},
	created: 1761600000,
	expires: 1761609999,
	revocation: Revoked,
}

encoded : KeyCodec.Entry(Conv) -> List(U8)
encoded = |e| KeyCodec.encode(e, Conv.to_u64)

## The entry a line holds.
read_back : List(U8) -> Try(KeyCodec.Entry(Conv), Stored.Problem)
read_back = |raw| KeyCodec.decode(raw, Conv.from_u64).map_ok(KeyCodec.Line.entry)

## The entry survives a round trip whole.
is_kept : KeyCodec.Entry(Conv) -> Bool
is_kept = |e| read_back(encoded(e)) == Ok(e)

hex5a : Str
hex5a = Str.repeat("5a", 32)

narrow_line : Str
narrow_line = "key v1 id=4 acts=agent:7 generation=4 human-generation=3 hash=${hex5a} created=1761600000 expires=1793136000 state=active read=only:3,9 post=off admin=off\n"

expect encoded(entry(narrow)) == Str.to_utf8(narrow_line)
expect
	encoded(entry(broad))
		== Str.to_utf8("key v1 id=18446744073709551615 acts=human:583231 generation=18446744073709551615 human-generation=18446744073709551615 hash=${hex5a} created=1761600000 expires=1761609999 state=revoked read=everywhere post=only:1 admin=on\n")

# Round trips: every part at each of its values.
expect is_kept(entry(narrow))
expect is_kept(entry(broad))
expect
	List.all(
		[
			{ ..narrow, acts_as: Principal.Id.Bot(Cast.aid(2)) },
			{
				..narrow,
				created: 0,
				expires: 1,
			},
			{
				..narrow,
				created: Stored.max_time - 1,
				expires: Stored.max_time,
			},
			{ ..narrow, expires: 1761600001 },
			{
				..narrow,
				scope: {
					read: Off,
					post: On(Everywhere),
					admin: Off,
				},
			},
			{
				..narrow,
				scope: {
					read: On(Only([conv(5)])),
					post: On(Only([conv(5), conv(6)])),
					admin: Off,
				},
			},
			{ ..broad, revocation: Active },
		],
		|r| is_kept(entry(r)),
	)

# **THE SCOPE IS THE RECORD'S, EXACTLY**: the narrow key decodes narrow;
# its admin stays off.
expect read_back(Str.to_utf8(narrow_line)).map_ok(|e| e.record.scope) == Ok(narrow.scope)

# **ONE SPELLING PER VALUE** (the round-two attacker's eighth): the encoder
# writes a list ascending, each once, and an empty one `off`; the decoder
# refuses every other spelling of the same reach.
with_read : KeyCodec.Reach(Conv) -> List(U8)
with_read = |reach| encoded(entry({ ..narrow, scope: { ..narrow.scope, read: On(reach) } }))

expect with_read(
	Only([
		conv(9),
		conv(3),
		conv(3),
	]),
) == Str.to_utf8(narrow_line)
expect with_read(Only([conv(3), conv(9)])) == Str.to_utf8(narrow_line)
expect with_read(Only([])) == Str.to_utf8(narrow_line.replace_first("read=only:3,9", "read=off"))
expect ascending_once([
	9,
	3,
	3,
	1,
	9,
]) == [
	1,
	3,
	9,
]
expect ascending_once([]) == []

# ── THE MALFORMED TABLE: each line, its named problem.
decoded : Str -> Try({}, Stored.Problem)
decoded = |text| KeyCodec.decode(Str.to_utf8(text), Conv.from_u64).map_ok(|_| {})

## The narrow line with `from` replaced by `to`.
narrow_but : { from : Str, to : Str } -> Str
narrow_but = |{ from, to }| narrow_line.replace_first(from, to)

expect decoded(narrow_line) == Ok({})
expect decoded(narrow_but({ from: "\n", to: "" })) == Err(Torn)
expect decoded(narrow_but({ from: "key v1", to: "key v2" })) == Err(UnknownVersion)
expect decoded(narrow_but({ from: "key v1", to: "keys v1" })) == Err(WrongRecord)
expect decoded(narrow_but({ from: "id=4", to: "id=0" })) == Err(BadValue("id"))
expect decoded(narrow_but({ from: "id=4 ", to: "" })) == Err(MissingField("id"))
expect decoded(narrow_but({ from: "acts=agent:7", to: "acts=agent:0" })) == Err(BadValue("acts"))
expect decoded(narrow_but({ from: "acts=agent:7", to: "acts=agent7" })) == Err(BadValue("acts"))
expect decoded(narrow_but({ from: "acts=agent:7", to: "acts=admin:7" })) == Err(UnknownWord("acts"))
expect decoded(narrow_but({ from: "generation=4 ", to: "" })) == Err(MissingField("generation"))
expect decoded(
	narrow_but({
		from: "generation=4",
		to: "generation=-1",
	}),
) == Err(BadNumber("generation"))
expect decoded(
	narrow_but({
		from: "generation=4",
		to: "generation=0",
	}),
) == Err(BadValue("generation"))
expect decoded(
	narrow_but({
		from: "human-generation=3 ",
		to: "",
	}),
) == Err(MissingField("human-generation"))
expect decoded(
	narrow_but({
		from: "human-generation=3",
		to: "human-generation=0",
	}),
) == Err(BadValue("human-generation"))
# A human's key with two generations: no grant makes one.
expect decoded(
	narrow_but({
		from: "acts=agent:7",
		to: "acts=human:7",
	}),
) == Err(BadValue("human-generation"))
expect decoded(
	narrow_but({
		from: "acts=agent:7 generation=4",
		to: "acts=human:7 generation=3",
	}),
) == Ok({})
expect decoded(narrow_but({ from: "hash=", to: "hash=0" })) == Err(BadValue("hash"))
expect decoded(narrow_but({ from: hex5a, to: Str.repeat("5A", 32) })) == Err(BadValue("hash"))
expect decoded(narrow_but({ from: "hash=${hex5a} ", to: "" })) == Err(MissingField("hash"))
expect decoded(
	narrow_but({
		from: "created=1761600000",
		to: "created=now",
	}),
) == Err(BadNumber("created"))
expect decoded(
	narrow_but({
		from: "expires=1793136000",
		to: "expires=never",
	}),
) == Err(BadNumber("expires"))
expect decoded(
	narrow_but({
		from: "expires=1793136000",
		to: "expires=",
	}),
) == Err(BadNumber("expires"))
expect decoded(
	narrow_but({
		from: "expires=1793136000",
		to: "expires=at:1793136000",
	}),
) == Err(BadNumber("expires"))
expect decoded(
	narrow_but({
		from: "expires=1793136000",
		to: "expires=01793136000",
	}),
) == Err(BadNumber("expires"))
expect decoded(
	narrow_but({
		from: "expires=1793136000",
		to: "expires=-1",
	}),
) == Err(BadNumber("expires"))
# **AN EXPIRY NO GRANT MAKES** (round three's second): at or before the
# key's creation, or more than a year after it.
expect decoded(
	narrow_but({
		from: "expires=1793136000",
		to: "expires=1761600000",
	}),
) == Err(BadValue("expires"))
expect decoded(
	narrow_but({
		from: "expires=1793136000",
		to: "expires=1761599999",
	}),
) == Err(BadValue("expires"))
expect decoded(
	narrow_but({
		from: "expires=1793136000",
		to: "expires=1793136001",
	}),
) == Err(BadValue("expires"))
expect decoded(narrow_but({ from: "expires=1793136000", to: "expires=1761600001" })) == Ok({})
expect KeyCodec.is_fitting_expiry({ created: Stored.max_time - 1, expires: Stored.max_time })
expect !KeyCodec.is_fitting_expiry({ created: Stored.max_time, expires: Stored.max_time + 1 })
expect !KeyCodec.is_fitting_expiry({ created: 0, expires: -1 })
expect decoded(narrow_but({ from: "state=active", to: "state=live" })) == Err(UnknownWord("state"))
expect decoded(narrow_but({ from: "state=active ", to: "" })) == Err(MissingField("state"))
expect decoded(narrow_but({ from: "read=only:3,9", to: "read=all" })) == Err(UnknownWord("read"))
expect decoded(narrow_but({ from: "read=only:3,9", to: "read=" })) == Err(UnknownWord("read"))
expect decoded(
	narrow_but({
		from: "read=only:3,9",
		to: "read=only:3,,9",
	}),
) == Err(BadNumber("read"))
expect decoded(
	narrow_but({
		from: "read=only:3,9",
		to: "read=only:3,9,",
	}),
) == Err(BadNumber("read"))
expect decoded(narrow_but({ from: "read=only:3,9", to: "read=only:0,3" })) == Err(BadValue("read"))
expect decoded(narrow_but({ from: "read=only:3,9", to: "read=only:3;9" })) == Err(BadNumber("read"))
# Not the one spelling: out of order, repeated, empty.
expect decoded(
	narrow_but({
		from: "read=only:3,9",
		to: "read=only:9,3,3",
	}),
) == Err(BadValue("read"))
expect decoded(narrow_but({ from: "read=only:3,9", to: "read=only:9,3" })) == Err(BadValue("read"))
expect decoded(
	narrow_but({
		from: "read=only:3,9",
		to: "read=only:3,3,9",
	}),
) == Err(BadValue("read"))
expect decoded(narrow_but({ from: "read=only:3,9", to: "read=only:" })) == Err(BadValue("read"))
expect decoded(narrow_but({ from: "post=off", to: "post=only:" })) == Err(BadValue("post"))
expect decoded(narrow_but({ from: "post=off", to: "post=on" })) == Err(UnknownWord("post"))
expect decoded(narrow_but({ from: "post=off ", to: "" })) == Err(MissingField("post"))
expect decoded(narrow_but({ from: "admin=off", to: "admin=yes" })) == Err(UnknownWord("admin"))
expect decoded(narrow_but({ from: " admin=off", to: "" })) == Err(MissingField("admin"))
expect decoded(narrow_but({ from: "admin=off\n", to: "admin=off \n" })) == Err(Trailing)
expect decoded(narrow_but({ from: "admin=off\n", to: "admin=off last_used=1\n" })) == Err(Trailing)
expect decoded(
	narrow_but({
		from: "read=only:3,9 post=off",
		to: "post=off read=only:3,9",
	}),
) == Err(MissingField("read"))

# A bot with admin on: no grant makes one.
expect decoded(narrow_but({ from: "acts=agent:7", to: "acts=bot:7" })) == Ok({})
expect
	decoded(
		narrow_but({
			from: "acts=agent:7",
			to: "acts=bot:7",
		}).replace_first("admin=off", "admin=on"),
	)
		== Err(AdminForBot)
expect decoded(narrow_but({ from: "admin=off", to: "admin=on" })) == Ok({})

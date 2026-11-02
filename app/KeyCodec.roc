## **AN API KEY, STORED** (the Roc chat's auth design, sections 3 and 9):
## one line in Stored's format, the key's hash and never the key, which its
## owner is shown once:
##
##     key v1 id=4 acts=agent:7 generation=4 human-generation=3 hash=<64 hex digits> created=1761600000 expires=1793136000 state=active read=everywhere post=off
##
## `generation` is the generation of its principal's account, and
## `human-generation` that of the human it answers to (itself, or the owner
## of its agent or bot), when it was granted (Principal.Bound): the key is
## those accounts', never ones made again later with the same ids. A human's
## key holds one generation twice; a line whose two differ is refused
## (`BadValue("human-generation")`), as no grant makes one. The record is
## ApiKey's key as the store holds it, in ApiKey's types.
##
## **A KEY SAYS WHO YOU ARE** (Steve, 2026-11-01): what its holder may
## reach is the chat's other rules' (a channel's members, Topic.roc). Its
## read and its post are each on (`everywhere`) or `off`; a key narrowed to
## listed resources (`only:`) is no more, and a line that spells one does
## not decode.
##
## **`decode` GIVES A LINE, AND A LINE IS THE ONLY WAY BACK TO A KEY**: an
## opaque value only this module makes, and the only thing ApiKey.Key.load
## takes. No handler loads a key from a record it built; a key comes from
## a grant (ApiKey.Key.issue) or from a stored line.
##
## **ONE SPELLING PER VALUE**: a read or a post is `everywhere` or `off`.
##
## **A LINE PROVES THE PATH, NOT THE SOURCE** (as SessionCodec says): the
## decoder accepts any bytes, so a Line proves its checks ran, not that its
## bytes came from the store; provenance needs an opaque read value from
## the platform, a host task. Pure.
import AccountCodec
import Cast
import Principal
import Stored

KeyCodec := [].{

	## **WHAT A KEY MAY DO**, each part on or off.
	Scope : {
		read : [Off, On],
		post : [Off, On],
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
	Record : {
		id : Principal.KeyId,
		acts_as : Principal.Id,
		generation : Principal.Generation,
		human_generation : Principal.Generation,
		scope : KeyCodec.Scope,
		created : I64,
		expires : I64,
		revocation : [Active, Revoked],
	}

	## **WHAT THE STORE KEEPS OF A KEY**, the key store's entry: its record, and the hash the host
	## looks it up by.
	Entry : {
		record : KeyCodec.Record,
		hash : Stored.SecretHash,
	}

	## **A LINE THAT DECODED**: its entry, every field checked. Opaque:
	## made only by `decode`.
	Line :: KeyCodec.Entry.{

		## The line's entry, for ApiKey.Key.load.
		entry : KeyCodec.Line -> KeyCodec.Entry
		entry = |KeyCodec.Line.(e)| e
	}

	## **A READ'S OR A POST'S REACH, IN ITS ONE SPELLING** (`everywhere`,
	## `off`): what a line holds, and what a grant's form and a key's
	## listing say.
	reach_text : [Off, On] -> Str
	reach_text = |part| spell_reach(part)

	## The reach a spelling names, as the decoder reads a line's, and a
	## grant's form.
	reach_from : List(U8), Str -> Try([Off, On], _)
	reach_from = |value, name|
		Stored.word(
			value,
			{
				name,
				members: all_switches,
				spell: spell_reach,
			},
		)

	## The entry's line, in the one spelling.
	encode : KeyCodec.Entry -> List(U8)
	encode = |{ record, hash }|
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
				("read", spell_reach(record.scope.read)),
				("post", spell_reach(record.scope.post)),
			],
		)

	## The entry a line holds, or the line's problem.
	decode : List(U8) -> Try(KeyCodec.Line, _)
	decode = |raw| {
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
				members: all_revocations,
				spell: spell_revocation,
			},
		)?
		read_field = state_field.rest.field("read")?
		read = KeyCodec.reach_from(read_field.value, "read")?
		post_field = read_field.rest.field("post")?
		post = KeyCodec.reach_from(post_field.value, "post")?
		post_field.rest.close()?
		match acts_as {
			Human(_) if generation != human_generation => Err(BadValue("human-generation"))
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

## **THE ONE SPELLING OF A REACH**: `everywhere` on, `off` off.
spell_reach : Switch -> Str
spell_reach = |s|
	match s {
		Off => "off"
		On => "everywhere"
	}

# ── tests
## A test's hash: every byte `b`.
hash_of : U8 -> Stored.SecretHash
hash_of = |b|
	match Stored.SecretHash.from_bytes(List.repeat(b, 32)) {
		Ok(h) => h
		Err(NotAHash) => crash "hash_of: 32 bytes are a hash"
	}

## An entry for the record `r`.
entry : KeyCodec.Record -> KeyCodec.Entry
entry = |r| {
	record: r,
	hash: hash_of(0x5a),
}

## A reading agent's key: agent 7, reading, not posting.
reader : KeyCodec.Record
reader = {
	id: Cast.kid(4),
	acts_as: Principal.Id.Agent(Cast.aid(7)),
	generation: Cast.gen(4),
	human_generation: Cast.gen(3),
	scope: {
		read: On,
		post: Off,
	},
	created: 1761600000,
	expires: 1793136000,
	revocation: Active,
}

## Every part of a record at its other value: a human's, posting,
## expiring, revoked.
broad : KeyCodec.Record
broad = {
	id: Cast.kid(18446744073709551615),
	acts_as: Principal.Id.Human(Cast.hid(583231)),
	generation: Cast.gen(18446744073709551615),
	human_generation: Cast.gen(18446744073709551615),
	scope: {
		read: Off,
		post: On,
	},
	created: 1761600000,
	expires: 1761609999,
	revocation: Revoked,
}

encoded : KeyCodec.Entry -> List(U8)
encoded = |e| KeyCodec.encode(e)

## The entry a line holds.
read_back : List(U8) -> Try(KeyCodec.Entry, _)
read_back = |raw| KeyCodec.decode(raw).map_ok(KeyCodec.Line.entry)

## The entry survives a round trip whole.
is_kept : KeyCodec.Entry -> Bool
is_kept = |e| read_back(encoded(e)) == Ok(e)

hex5a : Str
hex5a = "5a".repeat(32)

reader_line : Str
reader_line = "key v1 id=4 acts=agent:7 generation=4 human-generation=3 hash=${hex5a} created=1761600000 expires=1793136000 state=active read=everywhere post=off\n"

expect encoded(entry(reader)) == reader_line.to_utf8()
expect
	encoded(entry(broad))
		== "key v1 id=18446744073709551615 acts=human:583231 generation=18446744073709551615 human-generation=18446744073709551615 hash=${hex5a} created=1761600000 expires=1761609999 state=revoked read=off post=everywhere\n".to_utf8()

# Round trips: every part at each of its values.
expect is_kept(entry(reader))
expect is_kept(entry(broad))
expect
	List.all(
		[
			{ ..reader, acts_as: Principal.Id.Bot(Cast.aid(2)) },
			{
				..reader,
				created: 0,
				expires: 1,
			},
			{
				..reader,
				created: Stored.max_time - 1,
				expires: Stored.max_time,
			},
			{ ..reader, expires: 1761600001 },
			{
				..reader,
				scope: {
					read: Off,
					post: Off,
				},
			},
			{
				..reader,
				scope: {
					read: On,
					post: On,
				},
			},
			{ ..broad, revocation: Active },
		],
		|r| is_kept(entry(r)),
	)

# **THE SCOPE IS THE RECORD'S, EXACTLY**: the reader's key decodes so.
expect read_back(reader_line.to_utf8()).map_ok(|e| e.record.scope) == Ok(reader.scope)
expect KeyCodec.reach_text(On) == "everywhere"
expect KeyCodec.reach_text(Off) == "off"
expect KeyCodec.reach_from("everywhere".to_utf8(), "read") == Ok(On)
expect KeyCodec.reach_from("off".to_utf8(), "read") == Ok(Off)

# ── THE MALFORMED TABLE: each line, its named problem.
decoded : Str -> Try({}, _)
decoded = |text| KeyCodec.decode(text.to_utf8()).map_ok(|_| {})

## The reader's line with `from` replaced by `to`.
reader_but : { from : Str, to : Str } -> Str
reader_but = |{ from, to }| reader_line.replace_first(from, to)

expect decoded(reader_line) == Ok({})
# **A KEY NARROWED TO LISTED RESOURCES IS NO MORE**: an `only:` line, as
# the chat once wrote one, does not decode, its read or its post.
expect decoded(reader_but({ from: "read=everywhere", to: "read=only:3,9" })) == Err(UnknownWord("read"))
expect decoded(reader_but({ from: "post=off", to: "post=only:1" })) == Err(UnknownWord("post"))
expect decoded(reader_but({ from: "\n", to: "" })) == Err(Torn)
expect decoded(reader_but({ from: "key v1", to: "key v2" })) == Err(UnknownVersion)
expect decoded(reader_but({ from: "key v1", to: "keys v1" })) == Err(WrongRecord)
expect decoded(reader_but({ from: "id=4", to: "id=0" })) == Err(BadValue("id"))
expect decoded(reader_but({ from: "id=4 ", to: "" })) == Err(MissingField("id"))
expect decoded(reader_but({ from: "acts=agent:7", to: "acts=agent:0" })) == Err(BadValue("acts"))
expect decoded(reader_but({ from: "acts=agent:7", to: "acts=agent7" })) == Err(BadValue("acts"))
expect decoded(reader_but({ from: "acts=agent:7", to: "acts=admin:7" })) == Err(UnknownWord("acts"))
expect decoded(reader_but({ from: "generation=4 ", to: "" })) == Err(MissingField("generation"))
expect decoded(
	reader_but({
		from: "generation=4",
		to: "generation=-1",
	}),
) == Err(BadNumber("generation"))
expect decoded(
	reader_but({
		from: "generation=4",
		to: "generation=0",
	}),
) == Err(BadValue("generation"))
expect decoded(
	reader_but({
		from: "human-generation=3 ",
		to: "",
	}),
) == Err(MissingField("human-generation"))
expect decoded(
	reader_but({
		from: "human-generation=3",
		to: "human-generation=0",
	}),
) == Err(BadValue("human-generation"))
# A human's key with two generations: no grant makes one.
expect decoded(
	reader_but({
		from: "acts=agent:7",
		to: "acts=human:7",
	}),
) == Err(BadValue("human-generation"))
expect decoded(
	reader_but({
		from: "acts=agent:7 generation=4",
		to: "acts=human:7 generation=3",
	}),
) == Ok({})
expect decoded(reader_but({ from: "hash=", to: "hash=0" })) == Err(BadValue("hash"))
expect decoded(reader_but({ from: hex5a, to: "5A".repeat(32) })) == Err(BadValue("hash"))
expect decoded(reader_but({ from: "hash=${hex5a} ", to: "" })) == Err(MissingField("hash"))
expect decoded(
	reader_but({
		from: "created=1761600000",
		to: "created=now",
	}),
) == Err(BadNumber("created"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=never",
	}),
) == Err(BadNumber("expires"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=",
	}),
) == Err(BadNumber("expires"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=01793136000",
	}),
) == Err(BadNumber("expires"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=-1",
	}),
) == Err(BadNumber("expires"))
# **AN EXPIRY NO GRANT MAKES**: at or before the
# key's creation, or more than a year after it.
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=1761600000",
	}),
) == Err(BadValue("expires"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=1761599999",
	}),
) == Err(BadValue("expires"))
expect decoded(
	reader_but({
		from: "expires=1793136000",
		to: "expires=1793136001",
	}),
) == Err(BadValue("expires"))
expect decoded(reader_but({ from: "expires=1793136000", to: "expires=1761600001" })) == Ok({})
expect KeyCodec.is_fitting_expiry({ created: Stored.max_time - 1, expires: Stored.max_time })
expect !KeyCodec.is_fitting_expiry({ created: Stored.max_time, expires: Stored.max_time + 1 })
expect !KeyCodec.is_fitting_expiry({ created: 0, expires: -1 })
expect decoded(reader_but({ from: "state=active", to: "state=live" })) == Err(UnknownWord("state"))
expect decoded(reader_but({ from: "state=active ", to: "" })) == Err(MissingField("state"))
expect decoded(reader_but({ from: "read=everywhere", to: "read=all" })) == Err(UnknownWord("read"))
expect decoded(reader_but({ from: "read=everywhere", to: "read=" })) == Err(UnknownWord("read"))
expect decoded(reader_but({ from: "read=everywhere", to: "read=on" })) == Err(UnknownWord("read"))
expect decoded(reader_but({ from: "post=off", to: "post=on" })) == Err(UnknownWord("post"))
expect decoded(reader_but({ from: " post=off", to: "" })) == Err(MissingField("post"))
expect decoded(reader_but({ from: "post=off\n", to: "post=off \n" })) == Err(Trailing)
expect decoded(reader_but({ from: "post=off\n", to: "post=off last_used=1\n" })) == Err(Trailing)
# The admin scope of before is no field now.
expect decoded(reader_but({ from: "post=off\n", to: "post=off admin=off\n" })) == Err(Trailing)
expect decoded(
	reader_but({
		from: "read=everywhere post=off",
		to: "post=off read=everywhere",
	}),
) == Err(MissingField("read"))

## **A SESSION, STORED** (the Roc chat's auth design, section 2): one line in
## Stored's format, the cookie secret's hash and never the secret:
##
##     session v1 id=12 human=583231 generation=3 token=<64 hex digits> created=1761600000 seen=1761603600
##
## `generation` is the generation of the human's account the session was
## started for (Principal.Generation): a session admits only that account,
## never one made again later with the same GitHub id. `decode` gives a Line, an opaque value
## only this module makes, and the only thing Session.load takes: a
## session comes back from the store through this decoder or not at all,
## never from a record a handler built. A record seen before it was created
## is refused (`SeenBeforeCreated`) as every other malformed line is, by
## name.
##
## **A LINE PROVES THE PATH, NOT THE SOURCE**: `decode`, like every codec's
## decoder here (AccountCodec, KeyCodec, AuditCodec), accepts any bytes,
## so a Line proves that its value came through this decoder's checks, not
## that its bytes came from the store. A handler that decodes bytes it made
## up gets a session of its making. Real provenance needs an opaque read
## value from the platform (bytes only the store's read can hand over),
## which is a host task. Pure.
import Cast
import Principal
import Stored

SessionCodec := [].{

	## **A SESSION'S STORED FIELDS**: what the line holds, and what
	## Session.fields gives back to store.
	Fields : {
		id : Principal.SessionId,
		human : Principal.GitHubId,
		generation : Principal.Generation,
		token_hash : Stored.SecretHash,
		created : I64,
		last_seen : I64,
	}

	## **A LINE THAT DECODED**: its fields, every one checked. Opaque: made
	## only by `decode`.
	Line :: SessionCodec.Fields.{

		## The line's fields, for Session.load.
		fields : SessionCodec.Line -> SessionCodec.Fields
		fields = |SessionCodec.Line.(f)| f
	}

	## The session's line.
	encode : SessionCodec.Fields -> List(U8)
	encode = |s|
		Stored.line(
			"session",
			[
				("id", s.id.to_u64().to_str()),
				("human", s.human.to_u64().to_str()),
				("generation", s.generation.to_u64().to_str()),
				("token", Stored.hash_text(s.token_hash)),
				("created", Stored.time_text(s.created)),
				("seen", Stored.time_text(s.last_seen)),
			],
		)

	## The session a line holds.
	decode : List(U8) -> Try(SessionCodec.Line, _)
	decode = |raw| {
		fields = Stored.Reader.open(raw, "session")?
		id_field = fields.field("id")?
		id = Stored.id(id_field.value, { name: "id", make: Principal.SessionId.from_u64 })?
		human_field = id_field.rest.field("human")?
		human = Stored.id(human_field.value, { name: "human", make: Principal.GitHubId.from_u64 })?
		generation_field = human_field.rest.field("generation")?
		generation = Stored.id(
			generation_field.value,
			{ name: "generation", make: Principal.Generation.from_u64 },
		)?
		token_field = generation_field.rest.field("token")?
		token_hash = Stored.hash(token_field.value, "token")?
		created_field = token_field.rest.field("created")?
		created = Stored.time(created_field.value, "created")?
		seen_field = created_field.rest.field("seen")?
		last_seen = Stored.time(seen_field.value, "seen")?
		seen_field.rest.close()?
		if last_seen < created {
			Err(SeenBeforeCreated)
		} else {
			Ok(
				SessionCodec.Line.(
					{
						id,
						human,
						generation,
						token_hash,
						created,
						last_seen,
					},
				),
			)
		}
	}
}

# ── tests

## Session 12 of human 583231, created at `created` and seen at `seen`.
fields_at : { created : I64, seen : I64 } -> SessionCodec.Fields
fields_at = |{ created, seen }| {
	id: Cast.sid(12),
	human: Cast.gid(583231),
	generation: Cast.gen(3),
	token_hash: Cast.token(0xab),
	created,
	last_seen: seen,
}

usual : SessionCodec.Fields
usual = fields_at({ created: 1761600000, seen: 1761603600 })

ab64 : Str
ab64 = "ab".repeat(32)

usual_line : Str
usual_line = "session v1 id=12 human=583231 generation=3 token=${ab64} created=1761600000 seen=1761603600\n"

expect SessionCodec.encode(usual) == usual_line.to_utf8()

## The fields a line decodes to.
read_back : List(U8) -> Try(SessionCodec.Fields, _)
read_back = |raw| SessionCodec.decode(raw).map_ok(SessionCodec.Line.fields)

# Round trips: the usual, a fresh one (seen when created), times at 0 and
# at the last a record may hold, the biggest ids.
expect read_back(SessionCodec.encode(usual)) == Ok(usual)
expect
	List.all(
		[
			fields_at({ created: 5, seen: 5 }),
			fields_at({ created: 0, seen: 0 }),
			fields_at({ created: 0, seen: Stored.max_time }),
			{
				..usual,
				id: Cast.sid(18446744073709551615),
				human: Cast.gid(18446744073709551615),
				generation: Cast.gen(18446744073709551615),
			},
		],
		|f| read_back(SessionCodec.encode(f)) == Ok(f),
	)

# ── THE MALFORMED TABLE: each line, its named problem.
decoded : Str -> Try({}, _)
decoded = |text| SessionCodec.decode(text.to_utf8()).map_ok(|_| {})

## The usual line with `from` replaced by `to`.
usual_but : { from : Str, to : Str } -> Str
usual_but = |{ from, to }| usual_line.replace_first(from, to)

expect decoded(usual_but({ from: "", to: "" })) == Ok({})
expect decoded(usual_but({ from: "\n", to: "" })) == Err(Torn)
expect decoded(usual_but({ from: "\n", to: "\n\n" })) == Err(ExtraLine)
expect decoded(usual_but({ from: "session", to: "account" })) == Err(WrongRecord)
expect decoded(usual_but({ from: "v1", to: "v0" })) == Err(UnknownVersion)
expect decoded(usual_but({ from: "id=12 ", to: "" })) == Err(MissingField("id"))
expect decoded(usual_but({ from: "id=12", to: "id=0" })) == Err(BadValue("id"))
expect decoded(usual_but({ from: "id=12", to: "id=012" })) == Err(BadNumber("id"))
expect decoded(usual_but({ from: "human=583231 ", to: "" })) == Err(MissingField("human"))
expect decoded(usual_but({ from: "human=583231", to: "human=0" })) == Err(BadValue("human"))
expect decoded(usual_but({ from: "generation=3 ", to: "" })) == Err(MissingField("generation"))
expect decoded(
	usual_but({
		from: "generation=3",
		to: "generation=-1",
	}),
) == Err(BadNumber("generation"))
expect decoded(
	usual_but({
		from: "generation=3",
		to: "generation=0",
	}),
) == Err(BadValue("generation"))
expect decoded(
	usual_but({
		from: "generation=3",
		to: "account=3",
	}),
) == Err(MissingField("generation"))
expect decoded(usual_but({ from: "token=${ab64} ", to: "" })) == Err(MissingField("token"))
expect decoded(usual_but({ from: ab64, to: "AB".repeat(32) })) == Err(BadValue("token"))
expect decoded(usual_but({ from: ab64, to: "ab".repeat(31) })) == Err(BadValue("token"))
expect decoded(usual_but({ from: ab64, to: "ab".repeat(33) })) == Err(BadValue("token"))
expect decoded(usual_but({ from: ab64, to: "" })) == Err(BadValue("token"))
expect decoded(usual_but({ from: "created=1761600000 ", to: "" })) == Err(MissingField("created"))
expect decoded(
	usual_but({
		from: "created=1761600000",
		to: "created=1761600000.5",
	}),
) == Err(BadNumber("created"))
expect decoded(usual_but({ from: " seen=1761603600", to: "" })) == Err(MissingField("seen"))
expect decoded(usual_but({ from: "seen=1761603600", to: "seen=" })) == Err(BadNumber("seen"))
expect decoded(
	usual_but({
		from: "seen=1761603600",
		to: "seen=1761599999",
	}),
) == Err(SeenBeforeCreated)
expect decoded(usual_but({ from: "1761603600\n", to: "1761603600 \n" })) == Err(Trailing)
expect decoded(usual_but({ from: "1761603600\n", to: "1761603600 device=x\n" })) == Err(Trailing)
expect decoded(
	usual_but({
		from: "created=1761600000 seen=1761603600",
		to: "seen=1761603600 created=1761600000",
	}),
) == Err(MissingField("created"))
expect SessionCodec.decode([0xff, '\n']).map_ok(|_| {}) == Err(NotUtf8)

# **THE ATTACKER'S EXTREME SESSION**: created at I64's
# minimum, its liveness overflowed. A time before 1970 is no record the chat
# wrote: refused at the door, as is one past 9999.
expect decoded(
	usual_but({
		from: "created=1761600000",
		to: "created=-9223372036854775808",
	}),
) == Err(BadNumber("created"))
expect decoded(
	usual_but({
		from: "seen=1761603600",
		to: "seen=9223372036854775807",
	}),
) == Err(BadNumber("seen"))

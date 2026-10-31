## **A CONVERSATION, STORED**: one line in Stored's format, its participants
## each bound to their accounts as they were when it started:
##
##     conversation v1 id=1 created=1761600000 with=human:583231/3/3,agent:7/4/3 public=
##
## - `with` is every participant, in the order it was started with, each as
##   `<id>/<generation>/<human generation>` (Principal.Bound: its account's
##   generation and that of the human it answers to). A human's two
##   generations are one, so a line whose two differ is refused, as no
##   binding makes one.
## - `public` is every human's public election, each `<github id>/<its
##   account's generation>`, comma-separated; empty for none, the one
##   spelling of none.
##
## `decode` gives a Line, an opaque value only this module makes, and the
## only thing ConvAccess.Conv.load takes: a conversation comes back from the
## store through this decoder, never from a record a handler built. Its id
## is a bare number here (ConvAccess, which owns the type, imports this
## module, not the other way). Pure.
import AccountCodec
import Cast
import Principal
import Stored

ConvCodec := [].{

	## **A CONVERSATION'S STORED FIELDS**: what the line holds, and what
	## ConvAccess.Conv.fields gives back to store. `id` is never 0.
	Fields : {
		id : U64,
		created : I64,
		participants : List(Principal.Bound),
		public_by : List({ human : Principal.GitHubId, generation : Principal.Generation }),
	}

	## **A LINE THAT DECODED**: its fields, every one checked. Opaque: made
	## only by `decode`.
	Line :: ConvCodec.Fields.{

		## The line's fields, for ConvAccess.Conv.load.
		fields : ConvCodec.Line -> ConvCodec.Fields
		fields = |ConvCodec.Line.(f)| f
	}

	## The conversation's line. No participants, or an id of 0, is no
	## conversation ConvAccess makes: a crash.
	encode : ConvCodec.Fields -> List(U8)
	encode = |c|
		if c.id == 0 or c.participants.is_empty() {
			crash "ConvCodec.encode: a conversation has an id and a participant"
		} else {
			Stored.line(
				"conversation",
				[
					("id", c.id.to_str()),
					("created", Stored.time_text(c.created)),
					("with", Str.join_with(List.map(c.participants, AccountCodec.bound_text), ",")),
					("public", Str.join_with(List.map(c.public_by, vote_text), ",")),
				],
			)
		}

	## The conversation a line holds.
	decode : List(U8) -> Try(ConvCodec.Line, _)
	decode = |raw| {
		fields = Stored.Reader.open(raw, "conversation")?
		id_field = fields.field("id")?
		id = Stored.count(id_field.value, "id")?
		created_field = id_field.rest.field("created")?
		created = Stored.time(created_field.value, "created")?
		with_field = created_field.rest.field("with")?
		participants = with_field.value.split_on(',').map_try(bound_from)?
		public_field = with_field.rest.field("public")?
		public_by =
			if public_field.value.is_empty() {
				[]
			} else {
				public_field.value.split_on(',').map_try(vote_from)?
			}
		public_field.rest.close()?
		if id == 0 {
			Err(BadValue("id"))
		} else {
			Ok(
				ConvCodec.Line.(
					{
						id,
						created,
						participants,
						public_by,
					},
				),
			)
		}
	}
}

## A participant, as `with` holds it (AccountCodec.bound_from).
bound_from : List(U8) -> Try(Principal.Bound, _)
bound_from = |value| AccountCodec.bound_from(value, "with")

## A public election as `public` spells it: `<github id>/<generation>`.
vote_text : { human : Principal.GitHubId, generation : Principal.Generation } -> Str
vote_text = |v| "${v.human.to_u64().to_str()}/${v.generation.to_u64().to_str()}"

vote_from : List(U8) -> Try(
	{ human : Principal.GitHubId, generation : Principal.Generation },
	_,
)
vote_from = |value|
	match value.split_on('/') {
		[human_part, generation_part] => {
			human = Stored.id(human_part, { name: "public", make: Principal.GitHubId.from_u64 })?
			generation = Stored.id(
				generation_part,
				{ name: "public", make: Principal.Generation.from_u64 },
			)?
			Ok({ human, generation })
		}
		_ => Err(BadValue("public"))
	}

# ── tests

ann_bound : Principal.Bound
ann_bound = {
	id: Principal.Id.Human(Cast.gid(583231)),
	generation: Cast.gen(3),
	human: Cast.gen(3),
}

agent_bound : Principal.Bound
agent_bound = {
	id: Principal.Id.Agent(Cast.aid(7)),
	generation: Cast.gen(4),
	human: Cast.gen(3),
}

usual : ConvCodec.Fields
usual = {
	id: 1,
	created: 1761600000,
	participants: [ann_bound, agent_bound],
	public_by: [],
}

## The fields a line decodes to.
read_back : List(U8) -> Try(ConvCodec.Fields, _)
read_back = |raw| ConvCodec.decode(raw).map_ok(ConvCodec.Line.fields)

expect ConvCodec.encode(usual) == "conversation v1 id=1 created=1761600000 with=human:583231/3/3,agent:7/4/3 public=\n".to_utf8()

# Round trips: the usual, one participant, an election, two elections.
expect
	List.all(
		[
			usual,
			{ ..usual, participants: [ann_bound] },
			{ ..usual, public_by: [{ human: Cast.gid(583231), generation: Cast.gen(3) }] },
			{
				..usual,
				id: 18446744073709551615,
				public_by: [
					{ human: Cast.gid(1), generation: Cast.gen(1) },
					{ human: Cast.gid(2), generation: Cast.gen(9) },
				],
			},
		],
		|f| read_back(ConvCodec.encode(f)) == Ok(f),
	)

# Refusals, each by name.
expect read_back("conversation v1 id=0 created=1 with=human:1/1/1 public=\n".to_utf8()) == Err(BadValue("id"))
expect read_back("conversation v1 id=1 created=1 with= public=\n".to_utf8()) == Err(BadValue("with"))
expect read_back("conversation v1 id=1 created=1 with=human:1/2/1 public=\n".to_utf8()) == Err(BadValue("with"))
expect read_back("conversation v1 id=1 created=1 with=human:1/1 public=\n".to_utf8()) == Err(BadValue("with"))
expect read_back("conversation v1 id=1 created=1 with=human:1/1/1 public=1\n".to_utf8()) == Err(BadValue("public"))
expect read_back("conversation v1 id=1 created=1 with=human:1/1/1 public=,\n".to_utf8()) == Err(BadValue("public"))
expect read_back("conversation v1 id=1 created=1 with=human:1/1/1\n".to_utf8()) == Err(MissingField("public"))
expect read_back("conversation v1 id=1 created=1 with=human:1/1/1 public= x=1\n".to_utf8()) == Err(Trailing)
expect read_back("conversation v1 id=01 created=1 with=human:1/1/1 public=\n".to_utf8()) == Err(BadNumber("id"))
expect read_back("conversation v1 id=1 created=1 with=human:1/1/1 public=".to_utf8()) == Err(Torn)

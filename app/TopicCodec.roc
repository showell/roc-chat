## **A TOPIC, STORED** (ChannelLayout's `.../topic`): one line in Stored's
## format, its name as it was made and its kind, fixed when it was made:
##
##     topic v1 name=ChitChat kind=human
##     topic v1 name=agents kind=agents agents=agent:1/4/3,bot:3/5/3
##
## - `name` is the name as made (TopicName's rule), its spelling kept for
##   display; the folder the line is in is its key, in its channel's.
## - `kind` is `human` or `agents`. An agent topic, and only one, has
##   `agents` after it: every agent it names, in the order named, each as
##   AccountCodec.bound_text spells a binding; agents and bots only, each
##   once, never none.
##
## The channel is not in the line: the folder the line is in says it, and
## Topic.load takes it from the channel loaded. `decode` gives a Line, an
## opaque value only this module makes, and the only thing Topic.load
## takes. Pure.
import AccountCodec
import Cast
import Principal
import Stored
import TopicName

TopicCodec := [].{

	## **A TOPIC'S STORED FIELDS**: what the line holds, and what
	## Topic.fields gives back to store.
	Fields : {
		name : TopicName,
		kind : [Human, Agents(List(Principal.Bound))],
	}

	## **A LINE THAT DECODED**: its fields, every one checked. Opaque: made
	## only by `decode`.
	Line :: TopicCodec.Fields.{

		## The line's fields, for Topic.load.
		fields : TopicCodec.Line -> TopicCodec.Fields
		fields = |TopicCodec.Line.(f)| f
	}

	## The topic's line. An agent topic naming none, a human, or one agent
	## twice is no topic Topic makes: a crash.
	encode : TopicCodec.Fields -> List(U8)
	encode = |t|
		match t.kind {
			Human => Stored.line(
				"topic",
				[
					("name", t.name.to_str()),
					("kind", spell_kind(Human)),
				],
			)
			Agents(agents) =>
				if is_each_agent_once(agents) {
					Stored.line(
						"topic",
						[
							("name", t.name.to_str()),
							("kind", spell_kind(Agents)),
							("agents", Str.join_with(agents.map(AccountCodec.bound_text), ",")),
						],
					)
				} else {
					crash "TopicCodec.encode: an agent topic's agents are some, agents, each once"
				}
		}

	## The topic a line holds.
	decode : List(U8) -> Try(TopicCodec.Line, _)
	decode = |raw| {
		fields = Stored.Reader.open(raw, "topic")?
		name_field = fields.field("name")?
		name = name_from(name_field.value)?
		kind_field = name_field.rest.field("kind")?
		kind_word = Stored.word(
			kind_field.value,
			{
				name: "kind",
				members: all_kinds,
				spell: spell_kind,
			},
		)?
		match kind_word {
			Human => {
				kind_field.rest.close()?
				Ok(TopicCodec.Line.({ name, kind: Human }))
			}
			Agents => {
				agents_field = kind_field.rest.field("agents")?
				agents = agents_field.value.split_on(',').map_try(|v| AccountCodec.bound_from(v, "agents"))?
				agents_field.rest.close()?
				if is_each_agent_once(agents) {
					Ok(TopicCodec.Line.({ name, kind: Agents(agents) }))
				} else {
					Err(BadValue("agents"))
				}
			}
		}
	}
}

## A topic's kind, as its line's `kind` names it.
Kind : [Human, Agents]

all_kinds : List(Kind)
all_kinds = [Human, Agents]

## The one home of each kind's word.
spell_kind : Kind -> Str
spell_kind = |kind|
	match kind {
		Human => "human"
		Agents => "agents"
	}

## The name the field holds, by TopicName's rule.
name_from : List(U8) -> Try(TopicName, [BadValue(Str)])
name_from = |value|
	match Str.from_utf8(value) {
		Ok(text) => TopicName.from_str(text).map_err(|_| BadValue("name"))
		Err(_) => crash "TopicCodec.name_from: Stored.Reader.open checked the line is UTF-8"
	}

## Whether `agents` are some, each an agent or a bot, each once.
is_each_agent_once : List(Principal.Bound) -> Bool
is_each_agent_once = |agents|
	!agents.is_empty()
		and agents.all(
			|b|
				match b.id {
					Human(_) => Bool.False
					Agent(_) | Bot(_) => agents.count_if(|other| other.id == b.id) == 1
				},
		)

# ── tests
## The topic name `text` is, in a test where the rule takes it.
named : Str -> TopicName
named = |text|
	match TopicName.from_str(text) {
		Ok(n) => n
		Err(_) => crash "named: a test's topic name is one"
	}

cc_bound : Principal.Bound
cc_bound = {
	id: Principal.Id.Agent(Cast.aid(1)),
	generation: Cast.gen(4),
	human: Cast.gen(3),
}

bot_bound : Principal.Bound
bot_bound = {
	id: Principal.Id.Bot(Cast.aid(3)),
	generation: Cast.gen(5),
	human: Cast.gen(3),
}

chitchat : TopicCodec.Fields
chitchat = { name: named("ChitChat"), kind: Human }

agents_topic : TopicCodec.Fields
agents_topic = { name: named("agents"), kind: Agents([cc_bound, bot_bound]) }

## The fields a line decodes to.
read_back : List(U8) -> Try(TopicCodec.Fields, _)
read_back = |raw| TopicCodec.decode(raw).map_ok(TopicCodec.Line.fields)

expect TopicCodec.encode(chitchat) == "topic v1 name=ChitChat kind=human\n".to_utf8()
expect TopicCodec.encode(agents_topic) == "topic v1 name=agents kind=agents agents=agent:1/4/3,bot:3/5/3\n".to_utf8()

# Round trips: a human topic, an agent topic, one agent; the spelling as made.
expect
	[
		chitchat,
		agents_topic,
		{ ..agents_topic, kind: Agents([bot_bound]) },
	].all(|f| read_back(TopicCodec.encode(f)) == Ok(f))
expect read_back(TopicCodec.encode(chitchat)).map_ok(|f| f.name.to_str()) == Ok("ChitChat")

# Refusals, each by name.
expect read_back("topic v1 name=a--b kind=human\n".to_utf8()) == Err(BadValue("name"))
expect read_back("topic v1 name= kind=human\n".to_utf8()) == Err(BadValue("name"))
expect read_back("topic v1 name=x kind=Human\n".to_utf8()) == Err(UnknownWord("kind"))
expect read_back("topic v1 name=x kind=agent agents=agent:1/1/1\n".to_utf8()) == Err(UnknownWord("kind"))
expect read_back("topic v1 name=x kind=human agents=\n".to_utf8()) == Err(Trailing)
expect read_back("topic v1 name=x kind=human agents=agent:1/1/1\n".to_utf8()) == Err(Trailing)
expect read_back("topic v1 name=x kind=agents\n".to_utf8()) == Err(MissingField("agents"))
expect read_back("topic v1 name=x kind=agents agents=\n".to_utf8()) == Err(BadValue("agents"))
expect read_back("topic v1 name=x kind=agents agents=human:1/1/1\n".to_utf8()) == Err(BadValue("agents"))
expect read_back("topic v1 name=x kind=agents agents=agent:1/1/1,agent:1/1/1\n".to_utf8()) == Err(BadValue("agents"))
expect read_back("topic v1 name=x kind=agents agents=agent:1/1/1,\n".to_utf8()) == Err(BadValue("agents"))
expect read_back("topic v1 name=x kind=agents agents=agent:1/0/1\n".to_utf8()) == Err(BadValue("agents"))
expect read_back("topic v1 name=x kind=agents agents=agent:1/1/1 x=1\n".to_utf8()) == Err(Trailing)
expect read_back("topic v1 kind=human name=x\n".to_utf8()) == Err(MissingField("name"))
expect read_back("topic v1 name=x kind=human".to_utf8()) == Err(Torn)
expect read_back("channel v1 name=x members=\n".to_utf8()) == Err(WrongRecord)

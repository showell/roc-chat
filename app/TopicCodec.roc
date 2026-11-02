## **A TOPIC, STORED** (ChannelLayout's `.../topic`): one line in Stored's
## format, its name as it was made:
##
##     topic v1 name=ChitChat
##
## `name` is the name as made (TopicName's rule), its spelling kept for
## display; the folder the line is in is its key, in its channel's.
##
## The channel is not in the line: the folder the line is in says it, and
## Topic.load takes it from the channel loaded. `decode` gives a Line, an
## opaque value only this module makes, and the only thing Topic.load
## takes. Pure.
import Stored
import TopicName

TopicCodec := [].{

	## **A TOPIC'S STORED FIELDS**: what the line holds, and what
	## Topic.fields gives back to store.
	Fields : {
		name : TopicName,
	}

	## **A LINE THAT DECODED**: its fields, every one checked. Opaque: made
	## only by `decode`.
	Line :: TopicCodec.Fields.{

		## The line's fields, for Topic.load.
		fields : TopicCodec.Line -> TopicCodec.Fields
		fields = |TopicCodec.Line.(f)| f
	}

	## The topic's line.
	encode : TopicCodec.Fields -> List(U8)
	encode = |t|
		Stored.line(
			"topic",
			[("name", t.name.to_str())],
		)

	## The topic a line holds.
	decode : List(U8) -> Try(TopicCodec.Line, _)
	decode = |raw| {
		fields = Stored.Reader.open(raw, "topic")?
		name_field = fields.field("name")?
		name = name_from(name_field.value)?
		name_field.rest.close()?
		Ok(TopicCodec.Line.({ name: name }))
	}
}

## The name the field holds, by TopicName's rule.
name_from : List(U8) -> Try(TopicName, [BadValue(Str)])
name_from = |value|
	match Str.from_utf8(value) {
		Ok(text) => TopicName.from_str(text).map_err(|_| BadValue("name"))
		Err(_) => crash "TopicCodec.name_from: Stored.Reader.open checked the line is UTF-8"
	}

# ── tests
## The topic name `text` is, in a test where the rule takes it.
named : Str -> TopicName
named = |text|
	match TopicName.from_str(text) {
		Ok(n) => n
		Err(_) => crash "named: a test's topic name is one"
	}

chitchat : TopicCodec.Fields
chitchat = { name: named("ChitChat") }

## The fields a line decodes to.
read_back : List(U8) -> Try(TopicCodec.Fields, _)
read_back = |raw| TopicCodec.decode(raw).map_ok(TopicCodec.Line.fields)

expect TopicCodec.encode(chitchat) == "topic v1 name=ChitChat\n".to_utf8()

# Round trips; the spelling as made.
expect read_back(TopicCodec.encode(chitchat)) == Ok(chitchat)
expect read_back(TopicCodec.encode({ name: named("initial-work") })) == Ok({ name: named("initial-work") })
expect read_back(TopicCodec.encode(chitchat)).map_ok(|f| f.name.to_str()) == Ok("ChitChat")

# Refusals, each by name; the old line's `kind` among them.
expect read_back("topic v1 name=x kind=human\n".to_utf8()) == Err(Trailing)
expect read_back("topic v1 name=a--b\n".to_utf8()) == Err(BadValue("name"))
expect read_back("topic v1 name=\n".to_utf8()) == Err(BadValue("name"))
expect read_back("topic v1\n".to_utf8()) == Err(MissingField("name"))
expect read_back("topic v1 name=x".to_utf8()) == Err(Torn)
expect read_back("channel v1 name=x members=\n".to_utf8()) == Err(WrongRecord)

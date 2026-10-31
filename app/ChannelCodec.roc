## **A CHANNEL, STORED** (ChannelLayout's `.../channel`): one line in
## Stored's format, its name as it was made and its members, each bound to
## their account as they were when let in:
##
##     channel v1 name=Cobblestone members=human:583231/3/3,human:7/1/1
##
## - `name` is the name as made (ChannelName's rule), its spelling kept for
##   display; the folder the line is in is its key.
## - `members` is every member, in the order let in, each as
##   AccountCodec.bound_text spells a binding; humans only, each once;
##   empty for none, the one spelling of none.
##
## `decode` gives a Line, an opaque value only this module makes, and the
## only thing Channel.load takes: a channel comes back from the store through
## this decoder, never from a record a handler built. Pure.
import AccountCodec
import Cast
import ChannelName
import Principal
import Stored

ChannelCodec := [].{

	## **A CHANNEL'S STORED FIELDS**: what the line holds, and what
	## Channel.fields gives back to store.
	Fields : {
		name : ChannelName,
		members : List(Principal.Bound),
	}

	## **A LINE THAT DECODED**: its fields, every one checked. Opaque: made
	## only by `decode`.
	Line :: ChannelCodec.Fields.{

		## The line's fields, for Channel.load.
		fields : ChannelCodec.Line -> ChannelCodec.Fields
		fields = |ChannelCodec.Line.(f)| f
	}

	## The channel's line. A member who is not a human, or one named twice,
	## is no channel Channel makes: a crash.
	encode : ChannelCodec.Fields -> List(U8)
	encode = |c|
		if is_each_human_once(c.members) {
			Stored.line(
				"channel",
				[
					("name", c.name.to_str()),
					("members", Str.join_with(c.members.map(AccountCodec.bound_text), ",")),
				],
			)
		} else {
			crash "ChannelCodec.encode: a channel's members are humans, each once"
		}

	## The channel a line holds.
	decode : List(U8) -> Try(ChannelCodec.Line, _)
	decode = |raw| {
		fields = Stored.Reader.open(raw, "channel")?
		name_field = fields.field("name")?
		name = name_from(name_field.value)?
		members_field = name_field.rest.field("members")?
		members =
			if members_field.value.is_empty() {
				[]
			} else {
				members_field.value.split_on(',').map_try(|v| AccountCodec.bound_from(v, "members"))?
			}
		members_field.rest.close()?
		if is_each_human_once(members) {
			Ok(ChannelCodec.Line.({ name, members }))
		} else {
			Err(BadValue("members"))
		}
	}
}

## The name the field holds, by ChannelName's rule.
name_from : List(U8) -> Try(ChannelName, [BadValue(Str)])
name_from = |value|
	match Str.from_utf8(value) {
		Ok(text) => ChannelName.from_str(text).map_err(|_| BadValue("name"))
		Err(_) => crash "ChannelCodec.name_from: Stored.Reader.open checked the line is UTF-8"
	}

## Whether `members` are humans, each once.
is_each_human_once : List(Principal.Bound) -> Bool
is_each_human_once = |members|
	members.all(
		|b|
			match b.id {
				Human(_) => members.count_if(|other| other.id == b.id) == 1
				Agent(_) | Bot(_) => Bool.False
			},
	)

# ── tests
## Human `n`'s binding, at generation `g`.
human_bound : U64, U64 -> Principal.Bound
human_bound = |n, g| {
	id: Principal.Id.Human(Cast.gid(n)),
	generation: Cast.gen(g),
	human: Cast.gen(g),
}

cobblestone : ChannelCodec.Fields
cobblestone = {
	name: match ChannelName.from_str("Cobblestone") {
		Ok(n) => n
		Err(_) => crash "cobblestone: a test's channel name is one"
	},
	members: [human_bound(583231, 3), human_bound(7, 1)],
}

## The fields a line decodes to.
read_back : List(U8) -> Try(ChannelCodec.Fields, _)
read_back = |raw| ChannelCodec.decode(raw).map_ok(ChannelCodec.Line.fields)

expect ChannelCodec.encode(cobblestone) == "channel v1 name=Cobblestone members=human:583231/3/3,human:7/1/1\n".to_utf8()

# Round trips: the usual, no members, one member; the spelling as made.
expect
	[
		cobblestone,
		{ ..cobblestone, members: [] },
		{ ..cobblestone, members: [human_bound(1, 9)] },
	].all(|f| read_back(ChannelCodec.encode(f)) == Ok(f))
expect read_back(ChannelCodec.encode(cobblestone)).map_ok(|f| f.name.to_str()) == Ok("Cobblestone")
expect ChannelCodec.encode(cobblestone).count_if(|c| c == '\n') == 1

# Refusals, each by name.
expect read_back("channel v1 name=1st members=\n".to_utf8()) == Err(BadValue("name"))
expect read_back("channel v1 name=a/b members=\n".to_utf8()) == Err(BadValue("name"))
expect read_back("channel v1 name= members=\n".to_utf8()) == Err(BadValue("name"))
expect read_back("channel v1 name=general members=agent:1/1/1\n".to_utf8()) == Err(BadValue("members"))
expect read_back("channel v1 name=general members=bot:1/1/1\n".to_utf8()) == Err(BadValue("members"))
expect read_back("channel v1 name=general members=human:1/1/1,human:1/1/1\n".to_utf8()) == Err(BadValue("members"))
expect read_back("channel v1 name=general members=human:1/2/1\n".to_utf8()) == Err(BadValue("members"))
expect read_back("channel v1 name=general members=human:1/1\n".to_utf8()) == Err(BadValue("members"))
expect read_back("channel v1 name=general members=,\n".to_utf8()) == Err(BadValue("members"))
expect read_back("channel v1 name=general members=human:1/01/1\n".to_utf8()) == Err(BadNumber("members"))
expect read_back("channel v1 name=general\n".to_utf8()) == Err(MissingField("members"))
expect read_back("channel v1 members= name=general\n".to_utf8()) == Err(MissingField("name"))
expect read_back("channel v1 name=general members= x=1\n".to_utf8()) == Err(Trailing)
expect read_back("channel v1 name=general members=".to_utf8()) == Err(Torn)
expect read_back("channel v2 name=general members=\n".to_utf8()) == Err(UnknownVersion)
expect read_back("topic v1 name=general kind=human\n".to_utf8()) == Err(WrongRecord)

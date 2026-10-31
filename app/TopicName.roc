## **A TOPIC'S NAME** (production's rule, which roc-webbox's chat ported
## as `is_topic_id`): letters and digits joined by single hyphens, none at
## either end, 1 to 80 bytes, all ASCII (`ChitChat`, `road-trip-2`).
## Opaque, so a name that passed is the only kind there is.
##
## **A NAME IS SCOPED TO ITS CHANNEL**: the name alone says nothing of
## where the topic is, so `ChitChat` can be a topic of every channel; a
## topic is found by its channel and its name together (Topic.At).
##
## **TWO NAMES ARE ONE TOPIC WHEN THEY DIFFER ONLY IN CASE** (roc-webbox's
## `has_topic`, production's caseless match): `==` is ASCII-caseless. The
## name keeps the spelling it was made with, for display, and its `key`
## (lowercase) is the one spelling a path uses. Pure.
import Ascii

TopicName :: Str.{

	## The name `text` is, when the rule takes it.
	from_str : Str -> Try(TopicName, [NotATopicName])
	from_str = |text| {
		bytes = text.to_utf8()
		n = bytes.len()
		if n == 0 or n > max_bytes or bytes.first() == Ok('-') or bytes.last() == Ok('-') {
			Err(NotATopicName)
		} else {
			(is_good, _) = bytes.fold(
				(Bool.True, Bool.False),
				|(good, after_hyphen), c|
					if !good {
						(Bool.False, after_hyphen)
					} else if c == '-' {
						(!after_hyphen, Bool.True)
					} else {
						(Ascii.is_alphanumeric(c), Bool.False)
					},
			)
			if (is_good) Ok(TopicName.(text)) else Err(NotATopicName)
		}
	}

	## The name as it was made, for display and URLs.
	to_str : TopicName -> Str
	to_str = |TopicName.(name)| name

	## **THE ONE SPELLING OF THE TOPIC IN ITS CHANNEL**: its name in
	## lowercase, the same for every name `==` to it, and what a path names
	## (ChannelLayout).
	key : TopicName -> Str
	key = |TopicName.(name)|
		match Str.from_utf8(name.to_utf8().map(Ascii.to_lowercase)) {
			Ok(lower) => lower
			Err(_) => crash "TopicName.key: ASCII lowercased is UTF-8"
		}

	## Two names are one topic, in one channel, when they differ only in
	## ASCII case.
	is_eq : TopicName, TopicName -> Bool
	is_eq = |TopicName.(a), TopicName.(b)| a.caseless_ascii_equals(b)
}

## The longest name, in bytes.
max_bytes : U64
max_bytes = 80

# ── tests
## The name `text` is, in a test where the rule takes it.
named : Str -> TopicName
named = |text|
	match TopicName.from_str(text) {
		Ok(name) => name
		Err(NotATopicName) => crash "named: a test's topic name is one"
	}

# The rule: letters and digits joined by single hyphens, 1 to 80 bytes.
expect TopicName.from_str("ChitChat").is_ok()
expect TopicName.from_str("road-trip-2").is_ok()
expect TopicName.from_str("9").is_ok()
expect TopicName.from_str(Str.repeat("a", 80)).is_ok()
expect TopicName.from_str(Str.repeat("a", 81)) == Err(NotATopicName)
expect TopicName.from_str("") == Err(NotATopicName)
expect TopicName.from_str("..") == Err(NotATopicName)
expect TopicName.from_str("a/b") == Err(NotATopicName)
expect TopicName.from_str("../x") == Err(NotATopicName)
expect TopicName.from_str("-a") == Err(NotATopicName)
expect TopicName.from_str("a-") == Err(NotATopicName)
expect TopicName.from_str("a--b") == Err(NotATopicName)
expect TopicName.from_str("a_b") == Err(NotATopicName)
expect TopicName.from_str("a.b") == Err(NotATopicName)
expect TopicName.from_str("a b") == Err(NotATopicName)
expect TopicName.from_str("a.md") == Err(NotATopicName)
expect TopicName.from_str("caf\u(e9)") == Err(NotATopicName)

# Case: one topic, its spelling kept, one key.
expect named("ChitChat") == named("chitchat")
expect named("Plans") == named("pLANS")
expect named("ChitChat") != named("Chit-Chat")
expect named("ChitChat").to_str() == "ChitChat"
expect named("ChitChat").key() == "chitchat"
expect [named("Plans")].contains(named("PLANS"))

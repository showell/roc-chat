## **A CHANNEL'S NAME** (production's rule, which roc-webbox's chat ported
## as `ChannelName`): a letter, then letters, digits and hyphens, 1 to 40
## bytes, all ASCII. Opaque, so a name that passed is the only kind there
## is, and every path built from one (ChannelLayout) is built from a name
## the rule took.
##
## **TWO NAMES ARE ONE CHANNEL WHEN THEY DIFFER ONLY IN CASE**: `==` is
## ASCII-caseless, so `Cobblestone` and `cobblestone` name the same
## channel, wherever names are compared (a list's `contains`, a record's
## `==`). The name keeps the spelling it was made with, for display, and
## its `key` (lowercase) is the one spelling a path uses. Pure.
import Ascii

ChannelName :: Str.{

	## The name `text` is, when the rule takes it.
	from_str : Str -> Try(ChannelName, [NotAChannelName])
	from_str = |text|
		match text.to_utf8() {
			[first, .. as more] =>
				if text.count_utf8_bytes() <= max_bytes and Ascii.is_letter(first) and more.all(|c| Ascii.is_alphanumeric(c) or c == '-') {
					Ok(ChannelName.(text))
				} else {
					Err(NotAChannelName)
				}
			[] => Err(NotAChannelName)
		}

	## The name as it was made, for display and URLs.
	to_str : ChannelName -> Str
	to_str = |ChannelName.(name)| name

	## **THE ONE SPELLING OF THE CHANNEL**: its name in lowercase, the same
	## for every name `==` to it, and what a path names (ChannelLayout).
	key : ChannelName -> Str
	key = |ChannelName.(name)| lowercase(name)

	## Two names are one channel when they differ only in ASCII case.
	is_eq : ChannelName, ChannelName -> Bool
	is_eq = |ChannelName.(a), ChannelName.(b)| a.caseless_ascii_equals(b)
}

## The longest name, in bytes.
max_bytes : U64
max_bytes = 40

## ASCII's lowercase of a name the rule took (ASCII alone).
lowercase : Str -> Str
lowercase = |name|
	match Str.from_utf8(name.to_utf8().map(Ascii.to_lowercase)) {
		Ok(lower) => lower
		Err(_) => crash "ChannelName.lowercase: ASCII lowercased is UTF-8"
	}

# ── tests
## The name `text` is, in a test where the rule takes it.
named : Str -> ChannelName
named = |text|
	match ChannelName.from_str(text) {
		Ok(name) => name
		Err(NotAChannelName) => crash "named: a test's channel name is one"
	}

# The rule: a letter, then letters, digits and hyphens, 1 to 40 bytes.
expect ChannelName.from_str("general").is_ok()
# Production's two channels, made by hand: the rule must take them.
expect ChannelName.from_str("Cobblestone").is_ok()
expect ChannelName.from_str("General").is_ok()
expect ChannelName.from_str("a-1-").is_ok()
expect ChannelName.from_str("a--b").is_ok()
expect ChannelName.from_str(Str.repeat("a", 40)).is_ok()
expect ChannelName.from_str(Str.repeat("a", 41)) == Err(NotAChannelName)
expect ChannelName.from_str("") == Err(NotAChannelName)
expect ChannelName.from_str("1abc") == Err(NotAChannelName)
expect ChannelName.from_str("-abc") == Err(NotAChannelName)
expect ChannelName.from_str("..") == Err(NotAChannelName)
expect ChannelName.from_str("a/b") == Err(NotAChannelName)
expect ChannelName.from_str("a.b") == Err(NotAChannelName)
expect ChannelName.from_str("a_b") == Err(NotAChannelName)
expect ChannelName.from_str("a b") == Err(NotAChannelName)
expect ChannelName.from_str("caf\u(e9)") == Err(NotAChannelName)
expect ChannelName.from_str("\u(c9)cole") == Err(NotAChannelName)

# Case: one channel, its spelling kept, one key.
expect named("Cobblestone") == named("cOBBLESTONE")
expect named("Cobblestone") != named("Cobblestones")
expect named("Cobblestone").to_str() == "Cobblestone"
expect named("Cobblestone").key() == "cobblestone"
expect named("cOBBLE-stone-9").key() == named("Cobble-Stone-9").key()
expect [named("General")].contains(named("general"))

## **A STRICT NAME**: one that becomes a file name and a URL, the one home
## of that rule, which a topic (`Topic`) and a channel's name
## (`ChannelName`) obey: ASCII letters, digits and `-`, starting with a
## letter, at most `longest` bytes. Opaque, so `from_str` is the only way
## in; no space, CR, LF, `/`, `.` or `_` ever reaches a path, a URL or a
## transcript's id line. With no `_` and a letter first, no strict name is
## ever a DM's (`7_11`), and a reference's `_`s (`MSG_<topic>_<n>`)
## are never a topic's.
import Ascii

StrictName :: Str.{

	## The strict name `name`, or the first reason, in this order, it is
	## refused.
	from_str : Str -> Try(StrictName, [Empty, StartsWithNonLetter, TooLong, ForbiddenByte])
	from_str = |name| {
		bytes = name.to_utf8()
		match bytes {
			[] => Err(Empty)
			[first, ..] if !Ascii.is_letter(first) => Err(StartsWithNonLetter)
			_ if bytes.len() > StrictName.longest => Err(TooLong)
			_ if !bytes.all(is_allowed) => Err(ForbiddenByte)
			_ => Ok(StrictName.(name))
		}
	}

	## The longest name, in bytes; every byte is ASCII, so in characters too.
	longest : U64
	longest = 60

	## The name, as a file name and a URL take it.
	to_str : StrictName -> Str
	to_str = |StrictName.(name)| name

	is_eq : _
	to_hash : _
}

is_allowed : U8 -> Bool
is_allowed = |b| Ascii.is_letter(b) or Ascii.is_digit(b) or b == '-'

# ── tests
expect StrictName.from_str("") == Err(Empty)
expect StrictName.from_str(" ") == Err(StartsWithNonLetter)
expect StrictName.from_str("\t") == Err(StartsWithNonLetter)
expect StrictName.from_str("\n") == Err(StartsWithNonLetter)
expect StrictName.from_str("\r") == Err(StartsWithNonLetter)
expect StrictName.from_str("1plans") == Err(StartsWithNonLetter)
expect StrictName.from_str("-plans") == Err(StartsWithNonLetter)
expect StrictName.from_str("_plans") == Err(StartsWithNonLetter)
# The bytes beside the letters' ranges, first.
expect StrictName.from_str("@a") == Err(StartsWithNonLetter)
expect StrictName.from_str("[a") == Err(StartsWithNonLetter)
expect StrictName.from_str("`a") == Err(StartsWithNonLetter)
expect StrictName.from_str("{a") == Err(StartsWithNonLetter)
# The bytes beside every allowed range, after the first.
expect StrictName.from_str("aAzZ09-").map_ok(StrictName.to_str) == Ok("aAzZ09-")
expect StrictName.from_str("a/") == Err(ForbiddenByte)
expect StrictName.from_str("a:") == Err(ForbiddenByte)
expect StrictName.from_str("a@") == Err(ForbiddenByte)
expect StrictName.from_str("a[") == Err(ForbiddenByte)
expect StrictName.from_str("a`") == Err(ForbiddenByte)
expect StrictName.from_str("a{") == Err(ForbiddenByte)
expect StrictName.from_str("a,") == Err(ForbiddenByte)
expect StrictName.from_str("a.") == Err(ForbiddenByte)
expect StrictName.from_str("plans\nnext") == Err(ForbiddenByte)
expect StrictName.from_str("plans\r") == Err(ForbiddenByte)
expect StrictName.from_str("plans ") == Err(ForbiddenByte)
expect StrictName.from_str("plans_2") == Err(ForbiddenByte)
expect StrictName.from_str("café") == Err(ForbiddenByte)
# The length at, under and over the longest.
expect StrictName.from_str("a".repeat(61)) == Err(TooLong)
expect StrictName.from_str("a".repeat(60)).map_ok(StrictName.to_str) == Ok("a".repeat(60))
expect StrictName.from_str("a".repeat(59)).map_ok(StrictName.to_str) == Ok("a".repeat(59))
expect StrictName.longest == 60
# The order of refusals: the first byte, then the length, then the bytes.
expect StrictName.from_str("1${"a".repeat(60)}") == Err(StartsWithNonLetter)
expect StrictName.from_str("a${"a".repeat(59)} ") == Err(TooLong)
expect StrictName.from_str("a b") == Err(ForbiddenByte)
expect StrictName.from_str("p").map_ok(StrictName.to_str) == Ok("p")
expect StrictName.from_str("Z").map_ok(StrictName.to_str) == Ok("Z")
expect StrictName.from_str("gopher-roc-2").map_ok(StrictName.to_str) == Ok("gopher-roc-2")

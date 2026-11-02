## **A TOPIC**: a conversation's name, which becomes a file name and a URL,
## so it is strictly named: ASCII letters, digits and `-`, starting with a
## letter, at most `longest` bytes. Opaque, so `from_str` is the only way in;
## no space, CR or LF ever reaches a path, a URL or a transcript's id line.
import Ascii

Topic :: Str.{

	## The topic named `name`, or the first reason, in this order, it is
	## refused.
	from_str : Str -> Try(Topic, [Empty, StartsWithNonLetter, TooLong, ForbiddenByte])
	from_str = |name| {
		bytes = name.to_utf8()
		match bytes {
			[] => Err(Empty)
			[first, ..] if !Ascii.is_letter(first) => Err(StartsWithNonLetter)
			_ if bytes.len() > Topic.longest => Err(TooLong)
			_ if !bytes.all(is_allowed) => Err(ForbiddenByte)
			_ => Ok(Topic.(name))
		}
	}

	## The longest name, in bytes; every byte is ASCII, so in characters too.
	longest : U64
	longest = 60

	## The name, as a file name and a URL take it.
	to_str : Topic -> Str
	to_str = |Topic.(name)| name

	is_eq : _
}

is_allowed : U8 -> Bool
is_allowed = |b| Ascii.is_letter(b) or Ascii.is_digit(b) or b == '-'

# ── tests
expect Topic.from_str("") == Err(Empty)
expect Topic.from_str(" ") == Err(StartsWithNonLetter)
expect Topic.from_str("\t") == Err(StartsWithNonLetter)
expect Topic.from_str("\n") == Err(StartsWithNonLetter)
expect Topic.from_str("\r") == Err(StartsWithNonLetter)
expect Topic.from_str("1plans") == Err(StartsWithNonLetter)
expect Topic.from_str("-plans") == Err(StartsWithNonLetter)
# The bytes beside the letters' ranges, first.
expect Topic.from_str("@a") == Err(StartsWithNonLetter)
expect Topic.from_str("[a") == Err(StartsWithNonLetter)
expect Topic.from_str("`a") == Err(StartsWithNonLetter)
expect Topic.from_str("{a") == Err(StartsWithNonLetter)
# The bytes beside every allowed range, after the first.
expect Topic.from_str("aAzZ09-").map_ok(Topic.to_str) == Ok("aAzZ09-")
expect Topic.from_str("a/") == Err(ForbiddenByte)
expect Topic.from_str("a:") == Err(ForbiddenByte)
expect Topic.from_str("a@") == Err(ForbiddenByte)
expect Topic.from_str("a[") == Err(ForbiddenByte)
expect Topic.from_str("a`") == Err(ForbiddenByte)
expect Topic.from_str("a{") == Err(ForbiddenByte)
expect Topic.from_str("a,") == Err(ForbiddenByte)
expect Topic.from_str("a.") == Err(ForbiddenByte)
expect Topic.from_str("plans\nnext") == Err(ForbiddenByte)
expect Topic.from_str("plans\r") == Err(ForbiddenByte)
expect Topic.from_str("plans ") == Err(ForbiddenByte)
expect Topic.from_str("plans_2") == Err(ForbiddenByte)
expect Topic.from_str("café") == Err(ForbiddenByte)
# The length at, under and over the longest.
expect Topic.from_str("a".repeat(61)) == Err(TooLong)
expect Topic.from_str("a".repeat(60)).map_ok(Topic.to_str) == Ok("a".repeat(60))
expect Topic.from_str("a".repeat(59)).map_ok(Topic.to_str) == Ok("a".repeat(59))
expect Topic.longest == 60
# The order of refusals: the first byte, then the length, then the bytes.
expect Topic.from_str("1${"a".repeat(60)}") == Err(StartsWithNonLetter)
expect Topic.from_str("a${"a".repeat(59)} ") == Err(TooLong)
expect Topic.from_str("a b") == Err(ForbiddenByte)
expect Topic.from_str("p").map_ok(Topic.to_str) == Ok("p")
expect Topic.from_str("Z").map_ok(Topic.to_str) == Ok("Z")
expect Topic.from_str("gopher-roc-2").map_ok(Topic.to_str) == Ok("gopher-roc-2")

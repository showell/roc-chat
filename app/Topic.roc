## **A TOPIC**: a conversation's name, which becomes a file name and a URL,
## so it is strictly named: ASCII letters, digits and `-`, starting with a
## letter, at most 60 characters. Opaque, so `from_str` is the only way in;
## no space, CR or LF ever reaches a path, a URL or a transcript's id line.
Topic :: Str.{

	## The topic named `name`, or why the name is refused.
	from_str : Str -> Try(Topic, [Empty, TooLong, StartsWithNonLetter, ForbiddenByte])
	from_str = |name| {
		bytes = name.to_utf8()
		match bytes {
			[] => Err(Empty)
			[first, ..] if !is_letter(first) => Err(StartsWithNonLetter)
			_ if bytes.len() > longest => Err(TooLong)
			_ if !bytes.all(|b| is_letter(b) or (b >= '0' and b <= '9') or b == '-') => Err(ForbiddenByte)
			_ => Ok(Topic.(name))
		}
	}

	## The name, as a file name and a URL take it.
	to_str : Topic -> Str
	to_str = |Topic.(name)| name

	is_eq : _
}

## The longest name, in bytes; every byte is ASCII, so in characters too.
longest : U64
longest = 60

is_letter : U8 -> Bool
is_letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')

# ── tests
expect Topic.from_str("") == Err(Empty)
expect Topic.from_str(" ") == Err(StartsWithNonLetter)
expect Topic.from_str("\t") == Err(StartsWithNonLetter)
expect Topic.from_str("\n") == Err(StartsWithNonLetter)
expect Topic.from_str("\r") == Err(StartsWithNonLetter)
expect Topic.from_str("1plans") == Err(StartsWithNonLetter)
expect Topic.from_str("-plans") == Err(StartsWithNonLetter)
expect Topic.from_str("plans\nnext") == Err(ForbiddenByte)
expect Topic.from_str("plans\r") == Err(ForbiddenByte)
expect Topic.from_str("plans ") == Err(ForbiddenByte)
expect Topic.from_str("plans_2") == Err(ForbiddenByte)
expect Topic.from_str("plans/2") == Err(ForbiddenByte)
expect Topic.from_str("café") == Err(ForbiddenByte)
expect Topic.from_str("a".repeat(61)) == Err(TooLong)
expect Topic.from_str("a".repeat(60)).map_ok(Topic.to_str) == Ok("a".repeat(60))
expect Topic.from_str("a".repeat(59)).map_ok(Topic.to_str) == Ok("a".repeat(59))
expect Topic.from_str("p").map_ok(Topic.to_str) == Ok("p")
expect Topic.from_str("Z").map_ok(Topic.to_str) == Ok("Z")
expect Topic.from_str("gopher-roc-2").map_ok(Topic.to_str) == Ok("gopher-roc-2")

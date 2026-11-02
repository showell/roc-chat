## **AN AUTHOR**: who wrote a message, by their permanent name, exactly as
## they signed up (names are case-sensitive). Opaque, so `from_str` is the
## only way in: a name is never blank, and never holds a CR or an LF, which
## would end the transcript's `from:` line early.
Author :: Str.{

	## The author named `name`, unless it is blank or breaks a line.
	from_str : Str -> Try(Author, [Blank, LineBreak])
	from_str = |name|
		if (name.trim().is_empty())
			Err(Blank)
		else if (name.contains("\n") or name.contains("\r"))
			Err(LineBreak)
		else
			Ok(Author.(name))

	## The name, exactly as given.
	to_str : Author -> Str
	to_str = |Author.(name)| name

	is_eq : _
}

# ── tests
expect Author.from_str("") == Err(Blank)
expect Author.from_str(" ") == Err(Blank)
expect Author.from_str("\t") == Err(Blank)
expect Author.from_str("\n") == Err(Blank)
expect Author.from_str("\r") == Err(Blank)
expect Author.from_str("Ste\nve") == Err(LineBreak)
expect Author.from_str("Steve\r") == Err(LineBreak)
expect Author.from_str("S").map_ok(Author.to_str) == Ok("S")
expect Author.from_str("Steve Howell").map_ok(Author.to_str) == Ok("Steve Howell")
expect Author.from_str(" Zoë\t").map_ok(Author.to_str) == Ok(" Zoë\t")

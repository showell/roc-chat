## **AN AUTHOR**: who wrote a message, by their permanent name, exactly as
## they signed up (names are case-sensitive). Opaque, so `from_str` is the
## only way in: a name is never blank, never holds a control byte, which
## could end the transcript's `from:` line early or hide in a page, and
## never starts or ends with a space, so a permanent name looks like itself.
import Ascii

Author :: Str.{

	## The author named `name`, or the first reason, in this order, it is
	## refused: blank, a control byte, or a space at either end (Unicode's,
	## as `Str.trim` takes them).
	from_str : Str -> Try(Author, [Blank, ControlByte, Padded])
	from_str = |name|
		if (name.trim().is_empty())
			Err(Blank)
		else if (name.to_utf8().any(Ascii.is_control))
			Err(ControlByte)
		else if (name.trim() != name)
			Err(Padded)
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
expect Author.from_str("\u(a0)") == Err(Blank)
expect Author.from_str("Ste\nve") == Err(ControlByte)
expect Author.from_str("Steve\r") == Err(ControlByte)
expect Author.from_str(" Zoë\t") == Err(ControlByte)
# Every control byte refused, the first and last of each run and DEL; the
# printable bytes beside them, and a byte past ASCII, kept.
expect Author.from_str("a\u(0)") == Err(ControlByte)
expect Author.from_str("a\u(1f)") == Err(ControlByte)
expect Author.from_str("a\u(7f)") == Err(ControlByte)
expect Author.from_str("a ~").map_ok(Author.to_str) == Ok("a ~")
expect Author.from_str("a¡").map_ok(Author.to_str) == Ok("a¡")
expect Author.from_str("S").map_ok(Author.to_str) == Ok("S")
expect Author.from_str("Steve Howell").map_ok(Author.to_str) == Ok("Steve Howell")
# A space inside a name kept; at either end, ASCII or not, refused.
expect Author.from_str("Zoë Ann").map_ok(Author.to_str) == Ok("Zoë Ann")
expect Author.from_str(" Zoë ") == Err(Padded)
expect Author.from_str(" Zoë") == Err(Padded)
expect Author.from_str("Zoë ") == Err(Padded)
expect Author.from_str("\u(a0)Zoë") == Err(Padded)
expect Author.from_str("Zoë\u(2003)") == Err(Padded)
expect Author.from_str("Zoë").map_ok(Author.to_str) == Ok("Zoë")

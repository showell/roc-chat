## **A PERMANENT NAME**: a human's, an agent's or a channel's, exactly as
## given, the one home of the rule every name obeys. Names are permanent
## and case-sensitive: someone who signs up as "Steve Howell" is never shown
## as "steve howell". Opaque, so `from_str` is the only way in: a name is
## never blank, never holds a control byte, which could end a transcript's
## `from:` line early or hide in a page, never holds a Unicode format
## character (`FormatCharacter`), which could draw it as another name, and
## never starts or ends with a space, so a permanent name looks like itself.
##
## **ONE NAMESPACE, UNIQUE REGARDLESS OF CASE**: humans, agents and
## channels share it, so no two of them have names that differ only in
## case. `key` is the one spelling that uniqueness compares.
import Ascii
import FormatCharacter

Name :: Str.{

	## The name `name`, or the first reason, in this order, it is refused:
	## blank, a control byte, a format character, or a space at either end
	## (Unicode's, as `Str.trim` takes them).
	from_str : Str -> Try(Name, [Blank, ControlByte, FormatCharacter, Padded])
	from_str = |name|
		if (name.trim().is_empty())
			Err(Blank)
		else if (name.to_utf8().any(Ascii.is_control))
			Err(ControlByte)
		else if (FormatCharacter.is_in(name))
			Err(FormatCharacter)
		else if (name.trim() != name)
			Err(Padded)
		else
			Ok(Name.(name))

	## The name, exactly as given.
	to_str : Name -> Str
	to_str = |Name.(name)| name

	## **WHAT UNIQUENESS COMPARES**: two names are the same name in the
	## namespace exactly when their keys are equal. Opaque, so a key is only
	## ever a name's, and is never shown.
	Key :: Str.{
		is_eq : _
		to_hash : _
	}

	## **THE NAME'S KEY: ITS ASCII LETTERS IN LOWER CASE**, every other byte
	## as it is. The pinned Roc's builtins fold only ASCII's case, so `Zoë`
	## and `ZOË` are two names.
	key : Name -> Name.Key
	key = |Name.(name)| Name.Key.(name.with_ascii_lowercased())

	is_eq : _
}

# ── tests
expect Name.from_str("") == Err(Blank)
expect Name.from_str(" ") == Err(Blank)
expect Name.from_str("\t") == Err(Blank)
expect Name.from_str("\n") == Err(Blank)
expect Name.from_str("\r") == Err(Blank)
expect Name.from_str("\u(a0)") == Err(Blank)
expect Name.from_str("Ste\nve") == Err(ControlByte)
expect Name.from_str("Steve\r") == Err(ControlByte)
expect Name.from_str(" Zoë\t") == Err(ControlByte)
# Every control byte refused, the first and last of each run and DEL; the
# printable bytes beside them, and a byte past ASCII, kept.
expect Name.from_str("a\u(0)") == Err(ControlByte)
expect Name.from_str("a\u(1f)") == Err(ControlByte)
expect Name.from_str("a\u(7f)") == Err(ControlByte)
expect Name.from_str("a ~").map_ok(Name.to_str) == Ok("a ~")
expect Name.from_str("a¡").map_ok(Name.to_str) == Ok("a¡")
expect Name.from_str("S").map_ok(Name.to_str) == Ok("S")
expect Name.from_str("Steve Howell").map_ok(Name.to_str) == Ok("Steve Howell")
# A format character refused anywhere in a name, alone or beside a space;
# the characters next to the ones a reviewer named kept.
expect Name.from_str("Steve\u(202e)llewoH") == Err(FormatCharacter)
expect Name.from_str("\u(200b)") == Err(FormatCharacter)
expect Name.from_str("Ste\u(200d)ve") == Err(FormatCharacter)
expect Name.from_str("\u(feff)Steve") == Err(FormatCharacter)
expect Name.from_str("Steve \u(2060)") == Err(FormatCharacter)
expect Name.from_str("Ste\u(200a)ve").map_ok(Name.to_str) == Ok("Ste\u(200a)ve")
expect Name.from_str("Ste\u(2010)ve").map_ok(Name.to_str) == Ok("Ste\u(2010)ve")
expect Name.from_str("Steve\u(202f)Howell").map_ok(Name.to_str) == Ok("Steve\u(202f)Howell")
# The order: a control byte is named before a format character, and a
# format character before padding.
expect Name.from_str("\u(202e)\n") == Err(ControlByte)
expect Name.from_str(" \u(202e)Steve") == Err(FormatCharacter)
# A space inside a name kept; at either end, ASCII or not, refused.
expect Name.from_str("Zoë Ann").map_ok(Name.to_str) == Ok("Zoë Ann")
expect Name.from_str(" Zoë ") == Err(Padded)
expect Name.from_str(" Zoë") == Err(Padded)
expect Name.from_str("Zoë ") == Err(Padded)
expect Name.from_str("\u(a0)Zoë") == Err(Padded)
expect Name.from_str("Zoë\u(2003)") == Err(Padded)
expect Name.from_str("Zoë").map_ok(Name.to_str) == Ok("Zoë")
# The key: names that differ only in ASCII case share one; any other
# difference, a character past ASCII's case among them, keeps them apart.
## The key of the name `text`, which a test's text always is.
key_of : Str -> Name.Key
key_of = |text| (Name.from_str(text) ?? crash "Name's tests: a test's name is a name").key()

expect key_of("Steve Howell") == key_of("sTeVe hoWEll")
expect key_of("Steve Howell") == key_of("STEVE HOWELL")
expect key_of("CC") == key_of("cc")
expect key_of("Steve Howell") != key_of("Steve Howel")
expect key_of("Steve Howell") != key_of("Steve-Howell")
expect key_of("Zoë") != key_of("ZOË")
expect key_of("Zoë") == key_of("zoë")
# The name keeps its case; only the key folds it.
expect Name.from_str("sTeVe").map_ok(Name.to_str) == Ok("sTeVe")
expect Name.from_str("Steve") != Name.from_str("steve")

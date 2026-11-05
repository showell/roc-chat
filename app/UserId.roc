## This module is a user's id: the number of a person or an agent. An id is
## unique and permanent, and short enough for a URL and a file's name
## (`UserStem`). Steve's id is 1.
##
## People and agents are numbered in one count, as their names share one
## namespace, so an id alone says who a user is.
##
## An id is a `U8`: the chat is for a small group of people and their
## agents, and 255 is many times that. Every id that is kept is written as
## its decimal digits, in a file's name, a URL or a DM's pair, so a wider
## type later changes no byte on disk.
import Ascii

UserId :: U8.{

	## Steve's id: the first user's, and the admin's (`Admin`).
	steve : UserId
	steve = UserId.(1)

	## The id after this one, or `Full` if this is the highest.
	next : UserId -> Try(UserId, [Full])
	next = |UserId.(n)| if (n == U8.highest) Err(Full) else Ok(UserId.(n + 1))

	## The id `text` spells, or `NotAUserId`. Only the spellings `to_str`
	## writes are read, the digits of 1 to 255 with no leading `0`, so each
	## id has exactly one spelling.
	from_str : Str -> Try(UserId, [NotAUserId])
	from_str = |text| {
		bytes = text.to_utf8()
		match bytes {
			[] => Err(NotAUserId)
			['0', ..] => Err(NotAUserId)
			_ if bytes.len() > 3 or !bytes.all(Ascii.is_digit) => Err(NotAUserId)
			_ => {
				number = bytes.fold(0, |so_far, b| so_far * 10 + (b - '0').to_u64())
				if number > U8.highest.to_u64() {
					Err(NotAUserId)
				} else {
					Ok(UserId.(number.to_u8_wrap()))
				}
			}
		}
	}

	## The id's decimal digits, as a URL, a file's name and a DM's pair
	## write it.
	to_str : UserId -> Str
	to_str = |UserId.(n)| n.to_str()

	## Which of two ids comes first, by number. A DM's pair and a channel's
	## members are written in this order.
	compare : UserId, UserId -> [Before, Same, After]
	compare = |
		UserId.(n),
		UserId.(other),
	| if (n < other) Before else if (n == other) Same else After

	is_eq : _
	to_hash : _
}

# ── tests
expect UserId.steve.to_str() == "1"
# The next id, from the first, and at, under and over the highest.
expect UserId.steve.next().map_ok(UserId.to_str) == Ok("2")
expect UserId.(254).next().map_ok(UserId.to_str) == Ok("255")
expect UserId.(255).next() == Err(Full)
# Read back as `to_str` writes it, at the ends of the range and at each
# count of digits.
expect
	[
		"1",
		"9",
		"10",
		"99",
		"100",
		"254",
		"255",
	].all(|text| UserId.from_str(text).map_ok(UserId.to_str) == Ok(text))
# Every other spelling refused: none, zero, a leading `0`, past the
# highest, a sign, a space, a letter, Roc's other number forms, and a
# digit that isn't ASCII's.
expect
	[
		"",
		"0",
		"00",
		"01",
		"007",
		"256",
		"999",
		"1000",
		"+1",
		"-1",
		" 1",
		"1 ",
		"1a",
		"a",
		"1_000",
		"0x10",
		"\u(661)",
	].all(|text| UserId.from_str(text) == Err(NotAUserId))
# The order, both ways round, the same id, and by number rather than by
# text.
expect UserId.steve.compare(UserId.(2)) == Before
expect UserId.(2).compare(UserId.steve) == After
expect UserId.(2).compare(UserId.(2)) == Same
expect UserId.(9).compare(UserId.(10)) == Before

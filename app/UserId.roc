## This module is a user's id: the number of a person or an agent. An id is
## unique and permanent, and short enough for a URL and a file's name. The
## chat owner's id is 1.
##
## People and agents are numbered in one count, as their names share one
## namespace, so an id alone says who a user is.
##
## An id is a `U16`: every sign-up spends an id for good, and sign-up is open,
## so the chat wants room, and 65,535 is many times its people and agents.
## Every id that is kept is written as its decimal digits, in a file's name, a
## URL or a DM's pair, so a wider type later changes no byte on disk.
import Ascii
import FactFile

UserId :: U16.{

	## The chat owner's id: the first user's, and the admin's (`Admin`). The
	## owner's name is on disk like anyone's: `Directory.chat_owner` finds it.
	chat_owner : UserId
	chat_owner = UserId.(1)

	## The number after the highest id, which the counter of ids holds when
	## every id is taken.
	past_highest : U64
	past_highest = U16.highest.to_u64() + 1

	## The id after this one, or `Full` if this is the highest.
	next : UserId -> Try(UserId, [Full])
	next = |UserId.(n)|
		if n == U16.highest {
			Err(Full)
		} else {
			Ok(UserId.(n + 1))
		}

	## The id `text` spells, or `NotAUserId`. Only the spellings `to_str`
	## writes are read, the digits of 1 to 65,535 with no leading `0`, so each
	## id has exactly one spelling.
	from_str : Str -> Try(UserId, [NotAUserId])
	from_str = |text| id_from_digits(text.to_utf8())

	## The id a fact file holds (`FactFile`), as `to_file` writes it; unless
	## it holds anything else (`NotAUserId`).
	from_file : List(U8) -> Try(UserId, [NotAUserId])
	from_file = |bytes| id_from_digits(FactFile.word_from_file(bytes))

	## The id's decimal digits, as a URL, a file's name and a DM's pair
	## write it.
	to_str : UserId -> Str
	to_str = |UserId.(n)| n.to_str()

	## The id as a fact file keeps it (`FactFile`): its decimal digits, bare.
	to_file : UserId -> List(U8)
	to_file = |UserId.(n)| FactFile.number_to_file(n.to_u64())

	## Which of two ids comes first, by number. A DM's pair and a channel's
	## members are written in this order.
	compare : UserId, UserId -> [Before, Same, After]
	compare = |UserId.(n), UserId.(other)|
		if n < other {
			Before
		} else if n == other {
			Same
		} else {
			After
		}

	is_eq : _
	to_hash : _
}

## The id `digits` spell, a canonical number in range; else `NotAUserId`.
id_from_digits : List(U8) -> Try(UserId, [NotAUserId])
id_from_digits = |digits|
	match Ascii.canonical_number(digits, { most_digits: 5 }) {
		Ok(number) if number < UserId.past_highest => Ok(UserId.(number.to_u16_wrap()))
		_ => Err(NotAUserId)
	}

# ── tests
expect UserId.chat_owner.to_str() == "1"
# The next id, from the first, and at, under and over the highest.
expect UserId.chat_owner.next().map_ok(UserId.to_str) == Ok("2")
expect UserId.(65534).next().map_ok(UserId.to_str) == Ok("65535")
expect UserId.(65535).next() == Err(Full)
expect UserId.past_highest == 65536
# Read back as `to_str` writes it, at the ends of the range and at each
# count of digits.
expect
	[
		"1",
		"9",
		"10",
		"99",
		"100",
		"255",
		"256",
		"9999",
		"10000",
		"65534",
		"65535",
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
		"65536",
		"65537",
		"99999",
		"100000",
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
# A fact file: the digits written bare, read back with spaces and a line
# end at either end, and anything but an id's one spelling refused.
expect UserId.(65535).to_file() == "65535".to_utf8()
expect
	[
		("7", 7),
		("7\n", 7),
		(" \t65535\r\n", 65535),
	].all(|(text, number)| UserId.from_file(text.to_utf8()) == Ok(UserId.(number)))
expect
	[
		"",
		"\n",
		"0",
		"07",
		"65536",
		"7 7",
		"x",
		"\u(a0)7",
	].all(|text| UserId.from_file(text.to_utf8()) == Err(NotAUserId))
# The order, both ways round, the same id, and by number rather than by
# text.
expect UserId.chat_owner.compare(UserId.(2)) == Before
expect UserId.(2).compare(UserId.chat_owner) == After
expect UserId.(2).compare(UserId.(2)) == Same
expect UserId.(9).compare(UserId.(10)) == Before

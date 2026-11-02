## **A USER'S ID**: a human's or an agent's number, unique and permanent,
## handy in a URL and in a file's name (`UserStem`). Steve is always 1.
##
## **ONE COUNT FOR HUMANS AND AGENTS**, as they share one namespace: an id
## alone says who, with no kind beside it to keep in step, and `apoorva-2`
## and an agent's `cc-3` are never the same number.
##
## **WHY U8**: the chat is a small group of humans and their agents, and
## 255 is many times that. Every id that lasts is written as its decimal
## digits (a file's name, a URL, a DM's name), so a wider type later moves
## no byte on disk.
import Ascii

UserId :: U8.{

	## Steve's id, always: the first user, and the admin (`Admin`).
	steve : UserId
	steve = UserId.(1)

	## The id after this one, unless this is the last a chat holds.
	next : UserId -> Try(UserId, [Full])
	next = |UserId.(n)| if (n == U8.highest) Err(Full) else Ok(UserId.(n + 1))

	## **THE ID A URL OR A FILE'S NAME SPELLS**: exactly the spellings
	## `to_str` writes, the digits of 1 to 255 with no leading `0`, so an id
	## has one spelling; any other text is refused.
	from_str : Str -> Try(UserId, [NotAUserId])
	from_str = |text| {
		bytes = text.to_utf8()
		match bytes {
			[] => Err(NotAUserId)
			['0', ..] => Err(NotAUserId)
			_ if bytes.len() > 3 or !bytes.all(Ascii.is_digit) => Err(NotAUserId)
			_ => {
				number = bytes.fold(0, |so_far, b| so_far * 10 + (b - '0').to_u64())
				if (number > U8.highest.to_u64()) Err(NotAUserId) else Ok(UserId.(number.to_u8_wrap()))
			}
		}
	}

	## The number, as a URL, a file's name and a DM's name write it.
	to_str : UserId -> Str
	to_str = |UserId.(n)| n.to_str()

	## **WHICH COMES FIRST**, by number: a DM's pair and a channel's
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
expect UserId.steve.next().map_ok(UserId.to_str) == Ok("2")
# The last id at, under and over the highest.
expect UserId.(254).next().map_ok(UserId.to_str) == Ok("255")
expect UserId.(255).next() == Err(Full)
# Spelled as `to_str` writes it, at the ends of the range and at each
# count of digits; every other spelling refused.
expect
	[
		"1",
		"9",
		"10",
		"99",
		"100",
		"254",
		"255",
	].map(|text| UserId.from_str(text).map_ok(UserId.to_str))
		== [
			Ok("1"),
			Ok("9"),
			Ok("10"),
			Ok("99"),
			Ok("100"),
			Ok("254"),
			Ok("255"),
		]
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
	].map(UserId.from_str)
		== List.repeat(Err(NotAUserId), 17)
# The order, both ways round, and the same id.
expect
	[
		UserId.steve.compare(UserId.(2)),
		UserId.(2).compare(UserId.steve),
		UserId.(2).compare(UserId.(2)),
		UserId.(9).compare(UserId.(10)),
	]
		== [Before, After, Same, Before]

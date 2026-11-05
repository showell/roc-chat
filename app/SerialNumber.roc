## This module numbers what an agent holds in its folder, its keys and its
## invites: 1, 2, 3, each kind counted on its own, the next one after the
## highest given. Nothing is ever removed from an agent's folder, so a
## number is never given twice. `AgentKey.Id` and `AgentInvite.Id` are each
## a number from here, typed apart so one can't stand for the other.
##
## A number is written as its decimal digits, as a folder's name and a URL
## carry it, with no leading `0`, so each number has one spelling.
import Ascii

SerialNumber :: [].{

	## The number `text` spells: the digits of 1 to 4294967295, with no
	## leading `0`; unless it is anything else (`NotASerialNumber`).
	from_str : Str -> Try(U32, [NotASerialNumber])
	from_str = |text| {
		bytes = text.to_utf8()
		match bytes {
			[] => Err(NotASerialNumber)
			['0', ..] => Err(NotASerialNumber)
			_ if bytes.len() > 10 or !bytes.all(Ascii.is_digit) => Err(NotASerialNumber)
			_ => {
				number = bytes.fold(0, |so_far, b| so_far * 10 + (b - '0').to_u64())
				if number > U32.highest.to_u64() {
					Err(NotASerialNumber)
				} else {
					Ok(number.to_u32_wrap())
				}
			}
		}
	}

	## The number after the highest of `given`, or 1 when none is given;
	## unless the highest is the last (`Full`).
	next_after : List(U32) -> Try(U32, [Full])
	next_after = |given|
		match given.max() {
			Ok(highest) if highest == U32.highest => Err(Full)
			Ok(highest) => Ok(highest + 1)
			Err(ListWasEmpty) => Ok(1)
		}
}

# ── tests
expect
	[
		("1", 1),
		("9", 9),
		("10", 10),
		("4294967295", 4294967295),
	].all(|(text, number)| SerialNumber.from_str(text) == Ok(number))
expect
	[
		"",
		"0",
		"01",
		"4294967296",
		"99999999999",
		"+1",
		"1a",
		" 1",
	].all(|text| SerialNumber.from_str(text) == Err(NotASerialNumber))
expect SerialNumber.next_after([]) == Ok(1)
expect SerialNumber.next_after([1]) == Ok(2)
expect SerialNumber.next_after([3, 1, 2]) == Ok(4)
expect SerialNumber.next_after([2, 4294967294]) == Ok(4294967295)
expect SerialNumber.next_after([4294967295]) == Err(Full)

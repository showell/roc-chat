## This module is the one home of how the chat spells a fact file: a small
## file holding one decimal number or one word, written bare, with no line
## end. A reader takes the spaces, tabs and line ends at either end off
## first, so a file edited by hand still reads. What each number or word means is
## its own module's to say: an upload total (`UploadTotal`), a user's owner
## (`Users`), a key's expiry (`AgentKey`).
import Ascii

FactFile :: [].{

	## The number a file's decimal digits spell; unless the file holds
	## anything else, nothing included, or a number too big for a `U64`
	## (`NotANumber`).
	number_from_file : List(U8) -> Try(U64, [NotANumber])
	number_from_file = |bytes| {
		digits = FactFile.word_from_file(bytes)
		if digits.is_empty() or !digits.all(Ascii.is_digit) {
			Err(NotANumber)
		} else {
			number = U64.from_int_digits(digits.map(|b| b - '0')) ? |OutOfRange| NotANumber
			Ok(number)
		}
	}

	## The number as its file keeps it: its decimal digits.
	number_to_file : U64 -> List(U8)
	number_to_file = |number| number.to_str().to_utf8()

	## The time a file holds, in seconds since the epoch: its digits, at
	## most the largest `I64`; unless it holds anything else (`NotATime`),
	## a sign included.
	seconds_from_file : List(U8) -> Try(I64, [NotATime])
	seconds_from_file = |bytes|
		match FactFile.number_from_file(bytes) {
			Ok(number) if number <= I64.highest.to_u64_wrap() => Ok(number.to_i64_wrap())
			_ => Err(NotATime)
		}

	## The time as its file keeps it: its decimal digits.
	seconds_to_file : I64 -> List(U8)
	seconds_to_file = |seconds| seconds.to_str().to_utf8()

	## The file's bytes with the ASCII spaces at either end taken off
	## (`Ascii.trim_spaces`).
	word_from_file : List(U8) -> List(U8)
	word_from_file = |bytes| Ascii.trim_spaces(bytes)
}

# ── tests
expect FactFile.number_to_file(1761600000) == "1761600000".to_utf8()
expect
	[
		("0", 0),
		("7", 7),
		("42\n", 42),
		(" \t42\r\n", 42),
		("18446744073709551615", 18446744073709551615),
	].all(|(text, number)| FactFile.number_from_file(text.to_utf8()) == Ok(number))
expect
	[
		"",
		"\n",
		"12a",
		"-1",
		"+1",
		"1 2",
		"0x10",
		"\u(a0)42",
		"18446744073709551616",
	].all(|text| FactFile.number_from_file(text.to_utf8()) == Err(NotANumber))
expect FactFile.seconds_to_file(1761600000) == "1761600000".to_utf8()
expect FactFile.seconds_from_file("1761600000\n".to_utf8()) == Ok(1761600000)
expect FactFile.seconds_from_file("9223372036854775807".to_utf8()) == Ok(I64.highest)
expect FactFile.seconds_from_file("9223372036854775808".to_utf8()) == Err(NotATime)
expect FactFile.seconds_from_file("-1".to_utf8()) == Err(NotATime)
expect FactFile.word_from_file(" active\r\n".to_utf8()) == "active".to_utf8()
expect FactFile.word_from_file("a b".to_utf8()) == "a b".to_utf8()
expect FactFile.word_from_file(" \n".to_utf8()) == []
expect FactFile.word_from_file("\u(a0)x".to_utf8()) == "\u(a0)x".to_utf8()

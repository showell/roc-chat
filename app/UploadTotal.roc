## This module is a user's upload total: how many bytes of images they have
## uploaded over the life of their account. One user may upload at most
## 1 GiB in all (`most_bytes`). That is a backstop
## against abuse, not a tight quota.
##
## `FileSystem` keeps the total as a file of decimal digits in the user's
## folder (`UserFolder`). A user with no file has uploaded nothing. A file
## that doesn't hold a number refuses every upload, because reading it as 0
## would give the user their whole allowance again.
import FactFile

UploadTotal :: U64.{

	## The most one user may ever upload, in GiB, as a refusal words it.
	most_gib : U64
	most_gib = 1

	## The most bytes one user may ever upload.
	most_bytes : U64
	most_bytes = UploadTotal.most_gib * 1024 * 1024 * 1024

	## The total a user's file holds: none uploaded when there is no file
	## yet (`NoFile`), else the number the file spells (`FactFile`).
	## Anything else is `NotANumber`, a number too big for a `U64` included.
	from_file : [NoFile, File(List(U8))] -> Try(UploadTotal, [NotANumber])
	from_file = |file|
		match file {
			NoFile => Ok(UploadTotal.(0))
			File(bytes) => FactFile.number_from_file(bytes).map_ok(|number| UploadTotal.(number))
		}

	## The total as its file keeps it: its decimal digits.
	to_file : UploadTotal -> List(U8)
	to_file = |UploadTotal.(total)| FactFile.number_to_file(total)

	## The total after an upload of `adding` bytes, unless that would take it
	## past `most_bytes` (`LimitReached`).
	with_upload : UploadTotal, U64 -> Try(UploadTotal, [LimitReached])
	with_upload = |UploadTotal.(total), adding|
		if (total > UploadTotal.most_bytes or adding > UploadTotal.most_bytes - total)
			Err(LimitReached)
		else
			Ok(UploadTotal.(total + adding))

	is_eq : _
}

# ── tests
## A file of `text`, read as a total and written back, as a test reads it.
read_back : Str -> Try(Str, [NotANumber])
read_back = |text| UploadTotal.from_file(File(text.to_utf8())).map_ok(|total| Str.from_utf8_lossy(total.to_file()))

expect UploadTotal.most_bytes == 1073741824
# No file is none uploaded.
expect UploadTotal.from_file(NoFile) == Ok(UploadTotal.(0))
expect UploadTotal.from_file(NoFile).map_ok(|total| total.to_file()) == Ok("0".to_utf8())
# A file's digits, with spaces, tabs or line ends around them, and the most
# a U64 holds.
expect
	[
		("0", "0"),
		("7", "7"),
		("1073741824", "1073741824"),
		("42\n", "42"),
		(" \t42\r\n", "42"),
		("18446744073709551615", "18446744073709551615"),
	].all(|(text, total)| read_back(text) == Ok(total))
# Anything else is no number: empty, padding alone, a sign, a space or a
# letter inside, Roc's other number forms, a non-ASCII space around it, and
# one past the most a U64 holds.
expect
	[
		"",
		"\n",
		"lots",
		"12a",
		"-1",
		"+1",
		"1 2",
		"1_000",
		"0x10",
		"1e3",
		"\u(a0)42",
		"18446744073709551616",
	].all(|text| read_back(text) == Err(NotANumber))
# An upload that lands exactly on the most, and one byte past it, from
# nothing and from a total near it.
expect UploadTotal.(0).with_upload(UploadTotal.most_bytes) == Ok(UploadTotal.(UploadTotal.most_bytes))
expect UploadTotal.(0).with_upload(UploadTotal.most_bytes + 1) == Err(LimitReached)
expect UploadTotal.(UploadTotal.most_bytes - 10).with_upload(10) == Ok(UploadTotal.(UploadTotal.most_bytes))
expect UploadTotal.(UploadTotal.most_bytes - 10).with_upload(11) == Err(LimitReached)
expect UploadTotal.(5).with_upload(7) == Ok(UploadTotal.(12))
# A total already past the most refuses any upload, with no overflow at
# the top of U64.
expect UploadTotal.(UploadTotal.most_bytes).with_upload(1) == Err(LimitReached)
expect UploadTotal.(U64.highest).with_upload(1) == Err(LimitReached)

## A transcript opens each message with the separator line, thirteen dashes.
## This module owns that line: where it falls in a transcript's text
## (`records`), and how a message's markdown is written so that no line of
## it reads as one (`escape` and `unescape`).
##
## A markdown line that is the separator after any number of backslashes is
## written with one backslash more and read back with one fewer. So every
## markdown comes back exactly as it was written, and no line of a message
## on disk is the bare separator. A message that holds the bare separator
## was written by something other than `escape`, and `unescape` refuses it
## rather than accept a file it could not write back.
Separator :: [].{

	## The line that opens each message.
	line : Str
	line = "-------------"

	## The records `text` holds, in order: the text between one separator
	## and the next. `text` opens with the separator's line and ends with an
	## empty line, or it is `NotPrefixedProperly`. A record ends at an empty
	## line followed by the separator's line. Empty text holds no records.
	records : Str -> Try(List(Str), [NotPrefixedProperly])
	records = |text| {
		opening = "${Separator.line}\n"
		if (text.is_empty())
			Ok([])
		else if (!text.starts_with(opening) or !text.ends_with("\n\n"))
			Err(NotPrefixedProperly)
		else
			Ok(text.drop_prefix(opening).drop_suffix("\n\n").split_on("\n\n${opening}"))
	}

	## `markdown` as a transcript holds it, with each separator-like line
	## given one backslash more.
	escape : Str -> Str
	escape = |markdown| Str.join_with(
		markdown.split_on("\n").map(|l| if (is_backslashed_separator(l)) "\\${l}" else l),
		"\n",
	)

	## The markdown a transcript holds, as it was written, with each
	## separator-like line given one backslash fewer; unless a line is the
	## bare separator, which `escape` never writes.
	unescape : Str -> Try(Str, [BareSeparator])
	unescape = |written| {
		lines = written.split_on("\n")
		if (lines.any(|l| l == Separator.line))
			Err(BareSeparator)
		else
			Ok(
				Str.join_with(
					lines.map(|l| if (is_backslashed_separator(l)) l.drop_prefix("\\") else l),
					"\n",
				),
			)
	}
}

## Is `l` the separator after zero or more backslashes?
is_backslashed_separator : Str -> Bool
is_backslashed_separator = |l|
	l.ends_with(Separator.line) and l.drop_suffix(Separator.line).to_utf8().all(|b| b == '\\')

# ── tests
expect
	["-------------", "\\-------------", "\\\\-------------"].all(is_backslashed_separator)
expect
	[
		"a-------------",
		"-------------x",
		"\\x",
		"------------",
		"\\------------",
		"--------------",
		"\\a-------------",
	].all(|l| !is_backslashed_separator(l))
expect
	Separator.escape("a\n-------------\n\\-------------\nb")
		== "a\n\\-------------\n\\\\-------------\nb"
expect Separator.escape("------------\n\\x") == "------------\n\\x"
expect
	Separator.unescape("a\n\\-------------\n\\\\-------------\nb")
		== Ok("a\n-------------\n\\-------------\nb")
# A lone backslash, or one before a near miss, is no escape.
expect Separator.unescape("\\\n\\------------") == Ok("\\\n\\------------")
# The bare separator is refused alone, last or first; escaped, or one dash
# short, it is kept.
expect Separator.unescape("-------------") == Err(BareSeparator)
expect Separator.unescape("a\n-------------") == Err(BareSeparator)
expect Separator.unescape("-------------\na") == Err(BareSeparator)
expect Separator.unescape("\\-------------") == Ok("-------------")
expect Separator.unescape("------------") == Ok("------------")
# The records: one, two, none; a record's own trailing newline is kept.
expect Separator.records("-------------\na\n\n") == Ok(["a"])
expect Separator.records("-------------\na\n\n-------------\nb\n\n") == Ok(["a", "b"])
expect Separator.records("") == Ok([])
expect Separator.records("-------------\na\n\n\n") == Ok(["a\n"])
# No leading separator, or one not on a line of its own.
expect Separator.records("a\n\n") == Err(NotPrefixedProperly)
expect Separator.records("\n-------------\na\n\n") == Err(NotPrefixedProperly)
expect Separator.records("-------------a\n\n") == Err(NotPrefixedProperly)
expect Separator.records("------------\na\n\n") == Err(NotPrefixedProperly)
# No final empty line: one newline, or none.
expect Separator.records("-------------\na\n") == Err(NotPrefixedProperly)
expect Separator.records("-------------\na") == Err(NotPrefixedProperly)
expect Separator.records("\n") == Err(NotPrefixedProperly)
# CRLF is no newline here: at the start, at the end, or between records,
# where it splits nothing.
expect Separator.records("-------------\r\na\n\n") == Err(NotPrefixedProperly)
expect Separator.records("-------------\na\r\n\r\n") == Err(NotPrefixedProperly)
expect
	Separator.records("-------------\na\r\n\r\n-------------\nb\n\n")
		== Ok(["a\r\n\r\n-------------\nb"])
# An escaped separator after an empty line is a record's own line; so is a
# bare one with no empty line before it, for `unescape` to refuse.
expect
	Separator.records("-------------\na\n\n\\-------------\nb\n\n")
		== Ok(["a\n\n\\-------------\nb"])
expect Separator.records("-------------\na\n-------------\nb\n\n") == Ok(["a\n-------------\nb"])
# Escaping, then unescaping, gives the markdown back, separators and all.
expect
	[
		"",
		"plain",
		"-------------",
		"\\-------------\n\\\\-------------",
		"a\n-------------\nMSG_x_2\nfrom: Steve",
	].all(|md| Separator.unescape(Separator.escape(md)) == Ok(md))
# No escaped line is the separator.
expect
	!Separator.escape("-------------\nx\n-------------").split_on("\n").any(|l| l == Separator.line)

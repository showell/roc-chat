## **THE SEPARATOR, AND A MESSAGE THAT CAN'T FORGE ONE**: a transcript
## opens each message with the line `-------------`. A markdown line that is
## the separator, after any backslashes, is written with one backslash
## more, and read back with one fewer, so no message's markdown is ever a
## separator on disk, and every markdown comes back exactly as written. A
## written body holding the bare separator is one no writer made, so the
## reader refuses it rather than accept a file it could never write back.
## Where the separators fall in a transcript's text, its newlines and all,
## is this module's too (`records`); what a record holds is not.
Separator :: [].{

	## The line that opens each message.
	line : Str
	line = "-------------"

	## **THE RECORDS `text` HOLDS, THE SEPARATOR'S LAYOUT'S ONE HOME**: the
	## text between one separator and the next, in order. `text` opens with
	## the separator's line and ends with an empty line, or it is
	## `NotPrefixedProperly`; a record ends at a blank line followed by the
	## separator's line. No text holds no records.
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

	## `markdown` as the transcript writes it: no line of it the separator.
	escape : Str -> Str
	escape = |markdown| Str.join_with(
		markdown.split_on("\n").map(|l| if (is_separator_like(l)) "\\${l}" else l),
		"\n",
	)

	## The markdown a transcript holds, as it was written, unless a line of
	## it is the bare separator, which `escape` never writes.
	unescape : Str -> Try(Str, [BareSeparator])
	unescape = |written| {
		lines = written.split_on("\n")
		if (lines.any(|l| l == Separator.line))
			Err(BareSeparator)
		else
			Ok(Str.join_with(lines.map(|l| if (is_separator_like(l)) l.drop_prefix("\\") else l), "\n"))
	}
}

## Is `l` the separator after some backslashes?
is_separator_like : Str -> Bool
is_separator_like = |l| l.ends_with(Separator.line) and l.drop_suffix(Separator.line).to_utf8().all(|b| b == '\\')

# ── tests
expect is_separator_like("-------------")
expect is_separator_like("\\-------------")
expect is_separator_like("\\\\-------------")
expect !is_separator_like("a-------------")
expect !is_separator_like("-------------x")
expect !is_separator_like("\\x")
expect !is_separator_like("------------")
expect !is_separator_like("\\------------")
expect Separator.escape("a\n-------------\n\\-------------\nb") == "a\n\\-------------\n\\\\-------------\nb"
expect Separator.unescape("a\n\\-------------\n\\\\-------------\nb") == Ok("a\n-------------\n\\-------------\nb")
# A lone backslash, or one before a near miss, is no escape.
expect Separator.unescape("\\\n\\------------") == Ok("\\\n\\------------")
# The bare separator refused, alone, last or first; escaped, or one dash
# short, kept.
expect Separator.unescape("-------------") == Err(BareSeparator)
expect Separator.unescape("a\n-------------") == Err(BareSeparator)
expect Separator.unescape("-------------\na") == Err(BareSeparator)
expect Separator.unescape("\\-------------") == Ok("-------------")
expect Separator.unescape("------------") == Ok("------------")
# The records: one, two, none; a record's own trailing newline kept.
expect Separator.records("-------------\na\n\n") == Ok(["a"])
expect Separator.records("-------------\na\n\n-------------\nb\n\n") == Ok(["a", "b"])
expect Separator.records("") == Ok([])
expect Separator.records("-------------\na\n\n\n") == Ok(["a\n"])
# No leading separator, or one not on a line of its own.
expect Separator.records("a\n\n") == Err(NotPrefixedProperly)
expect Separator.records("\n-------------\na\n\n") == Err(NotPrefixedProperly)
expect Separator.records("-------------a\n\n") == Err(NotPrefixedProperly)
expect Separator.records("------------\na\n\n") == Err(NotPrefixedProperly)
# No final blank line: one newline, or none.
expect Separator.records("-------------\na\n") == Err(NotPrefixedProperly)
expect Separator.records("-------------\na") == Err(NotPrefixedProperly)
expect Separator.records("\n") == Err(NotPrefixedProperly)
# CRLF is no newline here: at the start, at the end, or between records,
# where it splits nothing.
expect Separator.records("-------------\r\na\n\n") == Err(NotPrefixedProperly)
expect Separator.records("-------------\na\r\n\r\n") == Err(NotPrefixedProperly)
expect Separator.records("-------------\na\r\n\r\n-------------\nb\n\n") == Ok(["a\r\n\r\n-------------\nb"])
# An escaped separator after a blank line is a record's own line; a bare
# one with no blank line before it is too, for `unescape` to refuse.
expect Separator.records("-------------\na\n\n\\-------------\nb\n\n") == Ok(["a\n\n\\-------------\nb"])
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
expect !Separator.escape("-------------\nx\n-------------").split_on("\n").any(|l| l == Separator.line)

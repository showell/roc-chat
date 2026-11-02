## **THE SEPARATOR, AND A MESSAGE THAT CAN'T FORGE ONE**: a transcript
## opens each message with the line `-------------`. A markdown line that is
## the separator, after any backslashes, is written with one backslash
## more, and read back with one fewer, so no message's markdown is ever a
## separator on disk, and every markdown comes back exactly as written.
Separator :: [].{

	## The line that opens each message.
	line : Str
	line = "-------------"

	## `markdown` as the transcript writes it: no line of it the separator.
	escape : Str -> Str
	escape = |markdown| Str.join_with(
		markdown.split_on("\n").map(|l| if (is_separator_like(l)) "\\${l}" else l),
		"\n",
	)

	## The markdown a transcript holds, as it was written.
	unescape : Str -> Str
	unescape = |written| Str.join_with(
		written.split_on("\n").map(|l| if (l.starts_with("\\") and is_separator_like(l)) l.drop_prefix("\\") else l),
		"\n",
	)
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
expect Separator.unescape("a\n\\-------------\n\\\\-------------\nb") == "a\n-------------\n\\-------------\nb"
# A lone backslash, or one before a near miss, is no escape.
expect Separator.unescape("\\\n\\------------") == "\\\n\\------------"
# Escaping, then unescaping, gives the markdown back, separators and all.
expect
	[
		"",
		"plain",
		"-------------",
		"\\-------------\n\\\\-------------",
		"a\n-------------\nMSG_x_2\nfrom: Steve",
	].all(|md| Separator.unescape(Separator.escape(md)) == md)
# No escaped line is the separator.
expect !Separator.escape("-------------\nx\n-------------").split_on("\n").any(|l| l == Separator.line)

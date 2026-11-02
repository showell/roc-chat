## **RECENT'S ROWS, DRAWN**: one tile per topic, as the old Recent page's
## client drew it (chat-client's js/recent.js, `buildTile`): a lead (the
## DM partner's initial, or a channel's bar), the place and topic, how long
## ago (written by the page's script from `data-ts`), and a line of
## "Who: excerpt". The server draws it, for the page and for each live
## update alike; who is "You" is the viewer's, so a live tile is drawn once
## per reader. The excerpt is the old one (angry-gopher's recent_feed.zig,
## `recentExcerpt`). Pure.
import md.MdFence
import Html

Recent := [].{

	## One row: where it goes (`url`, also its key), when its last message
	## was posted (`ts`, unix seconds, 0 for a topic with none), whether it
	## is a DM, its place's name (the DM partner's, or the channel's), its
	## topic, and its last message's author (as the reader calls them) and
	## excerpt, when it has one.
	Row : {
		url : Str,
		ts : I64,
		dm : Bool,
		place : Str,
		topic : Str,
		last : [NoMessage, Last({ who : Str, excerpt : Str })],
	}

	## **THE TILE**: a link to the topic. A DM's lead is its partner's
	## initial and its title the topic; a channel's lead is its bar (coloured
	## by the page's script from `data-channel`) and its context
	## `#<channel> · <topic>`. Every text is escaped.
	tile : Recent.Row -> Html
	tile = |r|
		Html.join([
			Html.markup("<a class=recent-tile href=\""),
			Html.text(r.url),
			Html.markup("\" data-key=\""),
			Html.text(r.url),
			Html.markup("\" data-ts="),
			Html.signed(r.ts),
			Html.markup("><div class=recent-lead>"),
			if r.dm {
				Html.join([
					Html.markup("<div class=recent-avatar>"),
					Html.text(initial(r.place)),
					Html.markup("</div>"),
				])
			} else {
				Html.join([
					Html.markup("<div class=recent-bar data-channel=\""),
					Html.text(r.place),
					Html.markup("\"></div>"),
				])
			},
			Html.markup("</div><div class=recent-body><div class=recent-top>"),
			if r.dm {
				Html.join([
					Html.markup("<div class=recent-title>"),
					Html.text(r.topic),
					Html.markup("</div>"),
				])
			} else {
				Html.join([
					Html.markup("<div class=recent-context><span>#"),
					Html.text(r.place),
					Html.markup("</span><span class=recent-dot>  ·  </span><span class=recent-topic>"),
					Html.text(r.topic),
					Html.markup("</span></div>"),
				])
			},
			Html.markup("<span class=recent-ago></span></div>"),
			match r.last {
				NoMessage => Html.join([])
				# An empty excerpt has no preview, as the old tile had none.
				Last({ who: _, excerpt: "" }) => Html.join([])
				Last({ who, excerpt }) =>
					Html.join([
						Html.markup("<div class=recent-preview><span class=recent-who>"),
						Html.text(first_word(who)),
						Html.markup(": </span>"),
						Html.text(excerpt),
						Html.markup("</div>"),
					])
			},
			Html.markup("</div></a>\n"),
		])

	## **A MESSAGE'S EXCERPT**, one line, the old rule: a `quote` fence (a
	## quote-reply's) becomes "[quoted text]", any other fence stays as it
	## is; an `<img ...>` or `![alt](url)` becomes "[image]"; whitespace
	## runs become one space; at most 350 characters, then "…".
	excerpt : List(U8) -> Str
	excerpt = |markdown| {
		lines = markdown.split_on('\n')
		unquoted = List.join(collapse_quotes(lines).map(|l| l.append('\n')))
		images = md_images(html_images(unquoted, []), [])
		one_line = spaced(images, { out: [], space: Bool.False })
		capped(one_line, 350)
	}
}

## A name's first character; the page's script upper-cases it (the old
## `charAt(0).toUpperCase()`), any letter, not ASCII alone.
initial : Str -> Str
initial = |name| if (name.is_empty()) "?" else first_char(name.to_utf8())

## The first UTF-8 character of `bytes`, as text.
first_char : List(U8) -> Str
first_char = |bytes| {
	len =
		match bytes.first() {
			Ok(b) if b >= 0xF0 => 4
			Ok(b) if b >= 0xE0 => 3
			Ok(b) if b >= 0xC0 => 2
			_ => 1
		}
	Str.from_utf8(bytes.take_first(len)) ?? "?"
}

## A name's first word, as the old tile's "Who:" (`who.split(' ')[0]`).
first_word : Str -> Str
first_word = |who|
	match who.to_utf8().split_on(' ') {
		[w, ..] => Str.from_utf8(w) ?? who
		[] => who
	}

## Each `quote` fence, to its close (or the end), as one "[quoted text]"
## line; any other fence kept whole, so its lines are never read as
## openers. One pass over the lines, as the old loop was.
collapse_quotes : List(List(U8)) -> List(List(U8))
collapse_quotes = |lines| {
	done = lines.fold(
		{ out: [], inside: Outside },
		|state, line|
			match state.inside {
				Outside =>
					match MdFence.open(line) {
						Err(NotAFence) => { out: state.out.append(line), inside: Outside }
						Ok(f) =>
							if f.lang == "quote".to_utf8() {
								{
									out: state.out.append("[quoted text]".to_utf8()),
									inside: Inside({
										char: f.char,
										count: f.count,
										quote: Bool.True,
									}),
								}
							} else {
								{
									out: state.out.append(line),
									inside: Inside({
										char: f.char,
										count: f.count,
										quote: Bool.False,
									}),
								}
							}
					}
				Inside(f) => {
					out = if (f.quote) state.out else state.out.append(line)
					inside = if (
						MdFence.is_close(
							line,
							{ char: f.char, count: f.count },
						)
					) Outside else Inside(f)
					{ out, inside }
				}
			},
	)
	done.out
}

## Each `<img` tag (any case, a whole word), to its `>`, as "[image]".
html_images : List(U8), List(U8) -> List(U8)
html_images = |s, out|
	match s {
		[] => out
		[
			'<',
			a,
			b,
			c,
			.. as rest,
		] if lower(a) == 'i' and lower(b) == 'm' and lower(c) == 'g' and !starts_word(rest) =>
			match index_of(rest, '>') {
				Ok(gt) => html_images(rest.drop_first(gt + 1), out.concat("[image]".to_utf8()))
				Err(NotFound) => html_images(s.drop_first(1), out.append('<'))
			}
		[x, .. as rest] => html_images(rest, out.append(x))
	}

## Each `![alt](url)` as "[image]".
md_images : List(U8), List(U8) -> List(U8)
md_images = |s, out|
	match s {
		[] => out
		['!', '[', .. as rest] =>
			match index_of(rest, ']') {
				Ok(close) =>
					match rest.drop_first(close + 1) {
						['(', .. as url] =>
							match index_of(url, ')') {
								Ok(end) => md_images(
									url.drop_first(end + 1),
									out.concat("[image]".to_utf8()),
								)
								Err(NotFound) => md_images(s.drop_first(1), out.append('!'))
							}
						_ => md_images(s.drop_first(1), out.append('!'))
					}
				Err(NotFound) => md_images(s.drop_first(1), out.append('!'))
			}
		[x, .. as rest] => md_images(rest, out.append(x))
	}

## Whitespace runs as one space, none leading or trailing.
spaced : List(U8), { out : List(U8), space : Bool } -> List(U8)
spaced = |s, { out, space }|
	match s {
		[] => out
		[c, .. as rest] =>
			if c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C {
				spaced(rest, { out, space: Bool.True })
			} else {
				spaced(
					rest,
					{
						out: (if (space and !out.is_empty()) out.append(' ') else out).append(c),
						space: Bool.False,
					},
				)
			}
	}

## At most `cap` characters; past it, the head (its trailing spaces cut)
## and "…".
capped : List(U8), U64 -> Str
capped = |s, cap| {
	cut = byte_at_char(
		s,
		{
			cap,
			at: 0,
			count: 0,
		},
	)
	text =
		match cut {
			Whole => s
			At(i) => trim_end_spaces(s.take_first(i)).concat("…".to_utf8())
		}
	Str.from_utf8(text) ?? ""
}

## Where the `cap`-th character ends, or the whole of `s` when shorter.
byte_at_char : List(U8),
{
	cap : U64,
	at : U64,
	count : U64,
} -> [Whole, At(U64)]
byte_at_char = |
	s,
	{
		cap,
		at,
		count,
	},
|
	if at >= s.len() {
		Whole
	} else if count == cap {
		At(at)
	} else {
		len =
			match s.get(at) {
				Ok(b) if b >= 0xF0 => 4
				Ok(b) if b >= 0xE0 => 3
				Ok(b) if b >= 0xC0 => 2
				_ => 1
			}
		byte_at_char(
			s,
			{
				cap,
				at: at + len,
				count: count + 1,
			},
		)
	}

trim_end_spaces : List(U8) -> List(U8)
trim_end_spaces = |s|
	match s.last() {
		Ok(' ') => trim_end_spaces(s.drop_last(1))
		_ => s
	}

lower : U8 -> U8
lower = |c| if (c >= 'A' and c <= 'Z') c + 32 else c

## Whether `rest` goes on a word (so `<imgx` is no `<img`).
starts_word : List(U8) -> Bool
starts_word = |rest|
	match rest {
		[c, ..] => (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'
		[] => Bool.False
	}

index_of : List(U8), U8 -> Try(U64, [NotFound])
index_of = |s, b|
	match s.find_first_index(|c| c == b) {
		Ok(i) => Ok(i)
		Err(_) => Err(NotFound)
	}

# ── tests: the old recentExcerpt's, and the edges
expect Recent.excerpt("In MSG_test_2 I said:\n~~~~ quote\nIn MSG_test_1 I said:\n~~~ quote\nhi\n~~~\n\nhello\n~~~~\n\nyo".to_utf8()) == "In MSG_test_2 I said: [quoted text] yo"
expect Recent.excerpt("```\n~~~ quote\n```\nafter".to_utf8()) == "``` ~~~ quote ``` after"
expect Recent.excerpt("look <IMG src=\"/user_uploads/a.png\"> and ![cat](/u/c.png) <imgx>".to_utf8()) == "look [image] and [image] <imgx>"
expect Recent.excerpt("  a \t\n\n b  ".to_utf8()) == "a b"
expect Recent.excerpt(Str.repeat("é", 351).to_utf8()) == Str.concat(Str.repeat("é", 350), "…")
expect Recent.excerpt(Str.repeat("x", 350).to_utf8()) == Str.repeat("x", 350)
expect Recent.excerpt(
	Str.concat(
		Str.repeat("a", 349),
		"  bc",
	).to_utf8(),
) == Str.concat(Str.repeat("a", 349), "…")
expect Recent.excerpt("![no close".to_utf8()) == "![no close"
expect Recent.excerpt([]) == ""
# An unclosed fence of tens of thousands of lines: one pass, its lines kept.
expect {
	body = Str.concat("~~~\n", Str.repeat("x\n", 40000)).to_utf8()
	Recent.excerpt(body).starts_with("~~~ x x x")
}
expect Recent.excerpt(
	Str.concat(
		"~~~ quote\n",
		Str.repeat("x\n", 40000),
	).to_utf8(),
) == "[quoted text]"
# A message whose excerpt is empty has no preview line.
expect {
	html = Recent.tile({
		url: "/u",
		ts: 1,
		dm: Bool.False,
		place: "L",
		topic: "T",
		last: Last({ who: "You", excerpt: "" }),
	}).bytes()
	!(Str.from_utf8(html) ?? "").contains("recent-preview")
}

# A DM's tile leads with its partner's initial; a channel's with its bar;
# every text escaped.
expect {
	html = Recent.tile({
		url: "/chat/dm/7_11/Hi",
		ts: 5,
		dm: Bool.True,
		place: "zoë",
		topic: "Hi",
		last: Last({ who: "You", excerpt: "<b>" }),
	}).bytes()
	html == "<a class=recent-tile href=\"/chat/dm/7_11/Hi\" data-key=\"/chat/dm/7_11/Hi\" data-ts=5><div class=recent-lead><div class=recent-avatar>z</div></div><div class=recent-body><div class=recent-top><div class=recent-title>Hi</div><span class=recent-ago></span></div><div class=recent-preview><span class=recent-who>You: </span>&lt;b&gt;</div></div></a>\n".to_utf8()
}
expect {
	html = Recent.tile({
		url: "/chat/channel/Lobby/T",
		ts: 0,
		dm: Bool.False,
		place: "Lobby",
		topic: "T",
		last: NoMessage,
	}).bytes()
	html == "<a class=recent-tile href=\"/chat/channel/Lobby/T\" data-key=\"/chat/channel/Lobby/T\" data-ts=0><div class=recent-lead><div class=recent-bar data-channel=\"Lobby\"></div></div><div class=recent-body><div class=recent-top><div class=recent-context><span>#Lobby</span><span class=recent-dot>  ·  </span><span class=recent-topic>T</span></div><span class=recent-ago></span></div></div></a>\n".to_utf8()
}
expect initial("Ö") == "Ö"
expect initial("zoë") == "z"
expect initial("") == "?"
expect first_word("Steve Howell") == "Steve"

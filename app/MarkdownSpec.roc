## Tests that a message's markdown, through `Markdown`, can name no element
## and no class of its own: no `id` comes out of it, which could take the
## name of an element the page or app/feed.js finds by its id, and every
## `class` is one roc-markdown or roc-syntax-color writes by design (a
## quote-reply's `chat-quote`, a reference's `msg-ref`, `md-malformed`, a
## colored span's `syn-...`), or a fence's language as `language-<word>`, one
## word, which no page class starts with, so it can't spoof a class a script
## styles or finds.
import ConversationKey
import Directory
import Markdown
import Name
import PageContract
import Topic
import UserId
import UserPair

MarkdownSpec :: [].{}

## `plans` in Steve's own DM.
plans : ConversationKey
plans = {
	directory = Directory.with_founder(Name.from_str("Steve") ?? crash "MarkdownSpec: a name")
	place = directory.place(
		Dm(UserPair.of({ one: UserId.chat_owner, other: UserId.chat_owner })),
	) ?? crash "MarkdownSpec: Steve's own DM"
	ConversationKey.of({ place, topic: Topic.from_str("plans") ?? crash "MarkdownSpec: a topic" })
}

## `markdown` rendered as a message of `plans`, as a test reads it.
message_html : Str -> Str
message_html = |markdown| Str.from_utf8(
	Markdown.message_html(markdown, plans).to_utf8(),
) ?? crash "MarkdownSpec: a render is UTF-8"

## The attributes of every tag in `html`, as (name, value). A member's text
## is escaped, so each `<` left opens a tag, and each `"` in a tag opens or
## closes a value: the pieces between them alternate, a stretch that ends
## with `name=`, then its value.
attributes : Str -> List((Str, Str))
attributes = |html|
	html.split_on("<").drop_first(1).join_map(
		|piece| {
			inside = piece.split_first(">").map_ok(|parts| parts.before) ?? piece
			inside.split_on("\"").fold(
				{ before: "", is_value: Bool.False, found: [] },
				|so_far, stretch|
					if so_far.is_value {
						name = (so_far.before.split_on(" ").last() ?? "").drop_suffix("=")
						{ before: stretch, is_value: Bool.False, found: so_far.found.append((name, stretch)) }
					} else {
						{ before: stretch, is_value: Bool.True, found: so_far.found }
					},
			).found
		},
	)

## Whether `value` is one class that markdown may write: one word (no byte
## HTML splits a class list on), and roc-markdown's own, a colored span's,
## or a fence's language.
is_markdown_class : Str -> Bool
is_markdown_class = |value| {
	bytes = value.to_utf8()
	is_one_word = bytes != [] and !bytes.any(|byte| byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 12)
	is_own = ["chat-quote", "msg-ref", "md-malformed"].contains(value)
	is_span = PageContract.syntax_classes.map(PageContract.syntax_class_name).contains(value)
	is_one_word and (is_own or is_span or value.starts_with("language-"))
}

## Markdown that tries for an id or a class: raw HTML, an image tag with
## more attributes, a heading and an attribute list, a footnote, and a
## fence whose info string holds each byte HTML splits a class list on, an
## escaped space and an entity.
attempts : List(Str)
attempts = [
	"<div id=\"top-bar\" class=\"sidebar\">x</div>",
	"<p id=x class=y>z</p>",
	"<img src=\"/chat/dm/1_1/plans/uploads/${"0a".repeat(16)}.png\" alt=\"cat\" id=\"top-bar\" class=\"sidebar\">",
	"<img src=\"/chat/dm/1_1/plans/uploads/${"0a".repeat(16)}.png\" class=\"sidebar\" alt=\"cat\">",
	"# Heading",
	"## Sub {#top-bar .sidebar}",
	"text {#top-bar .sidebar}",
	"a[^1]\n\n[^1]: note",
	"[a](#top-bar \"t\" id=x)",
	"```x\ttop-bar\n```",
	"```x\u(000C)top-bar\n```",
	"```x\rtop-bar\n```",
	"```x\u(000B)top-bar\n```",
	"```x\\ top-bar\n```",
	"```x&#32;top-bar\n```",
	"```x&#9;top-bar\n```",
	"```roc\na = 1 # b\n```",
	"```quote\nhi\n```",
	"see MSG_plans_3",
]

# No attempt makes an id, and each class it makes is markdown's own.
expect
	attempts.all(
		|markdown|
			attributes(message_html(markdown)).all(
				|(name, value)| name != "id" and (name != "class" or is_markdown_class(value)),
			),
	)
# The reading itself: an id and a class found, a class of two words or a
# page's own refused, markdown's own and a language kept.
expect attributes("<a href=\"#x\" class=\"msg-ref\">x</a> <img id=\"y\">") == [("href", "#x"), ("class", "msg-ref"), ("id", "y")]
expect !is_markdown_class("language-x\u(000C)top-bar") and !is_markdown_class("top-bar") and !is_markdown_class("")
expect ["chat-quote", "msg-ref", "md-malformed", "syn-keyword", "language-roc"].all(is_markdown_class)

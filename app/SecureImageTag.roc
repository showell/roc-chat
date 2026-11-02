## **SECURE IMAGE TAGS: WHICH IMAGES A MESSAGE MAY SHOW**, the one home of
## that rule. A message's markdown may hold an image (`![alt](src)` or an
## `<img>`, and a `<video>` too, which roc-markdown rules the same way);
## `Markdown.render` hands roc-markdown `is_conversation_upload` as its
## uploads rule, and roc-markdown shows as media only a source that passes
## it, after judging the source safe as a same-origin URL itself. A source
## that fails is left as text: an image becomes a plain link.
##
## **THE RULE** (`docs/design.md`, "Images"): an uploaded image belongs to
## one conversation, and exactly that conversation's readers can see it.
## So a message may show an image only from its own conversation's
## uploads, and every other source is refused.
##
## **WHAT ISN'T BUILT YET: UPLOADS.** No conversation has an upload, so
## today every source is refused, on purpose, not by oversight. When
## uploads exist, this rule asks the conversation for its own.
##
## What the renderer's output becomes on a page is vouched for at
## `TrustedHtml`'s one door; see its header for the others. Text from
## outside comes in only through `UnvalidatedString`.
SecureImageTag :: [].{

	## Is `source` one of the message's conversation's uploads? No
	## conversation has any yet, so no source is.
	is_conversation_upload : List(U8) -> Bool
	is_conversation_upload = |_source| Bool.False
}

# ── tests
# Every kind of source refused: relative, absolute, another origin, `data:`
# and `javascript:`, and the empty one.
expect
	[
		"a.png",
		"/user_uploads/a.png",
		"https://evil.example/a.png",
		"data:image/png;base64,AAAA",
		"javascript:alert(1)",
		"",
	]
		.map(|source| SecureImageTag.is_conversation_upload(source.to_utf8()))
		== List.repeat(Bool.False, 6)

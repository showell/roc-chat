## This module renders a message's markdown. It is the one entry to
## roc-markdown (the `md` package), and the only module that imports it.
## The dialect is "Steve flavor" markdown, roc-markdown's own.
## roc-markdown takes and gives bytes;
## this module takes a `Str` and gives `TrustedHtml`, so the rest of the
## chat never handles the renderer's bytes.
##
## The output is vouched for (`TrustedHtml`) because roc-markdown escapes
## every byte of a member's text through its one escape, lets through only
## the markup its own allowlist rebuilds, refuses a `javascript:` link, and
## shows media only from a source the uploads rule passes. That rule is
## `SecureImageTag.is_conversation_upload`, for the message's own
## conversation, chosen here and nowhere else.
##
## A code block in Roc, JavaScript, Shale or Zig (```` ```roc ````, `js`,
## `shale`, `zig`) is colored by roc-syntax-color (the `sc` package): a
## `<span class="syn-...">` around each comment, string, number, keyword,
## name and type, inside roc-markdown's own `<pre><code>`. roc-syntax-color
## escapes every byte of the block, the spans' insides and the text between
## them, through its one escape, so the colored block is vouched for as
## roc-markdown's own escape is; any other block is roc-markdown's escape.
## Its classes are `PageContract.SyntaxClass`'s, and app/feed.js colors them.
## A block past `Markdown.most_colored_bytes` is left plain, so coloring
## adds a bounded cost to each render of a message: at most about 30 ms of
## CPU a block on the box, at the worst text measured.
import md.Md
import sc.SyntaxColor
import ConversationKey
import SecureImageTag
import TrustedHtml

Markdown :: [].{

	## `markdown`, exactly as written, of a message in the conversation
	## `key`, as markup a page can hold: it shows an image only from that
	## conversation's own uploads.
	message_html : Str, ConversationKey -> TrustedHtml
	message_html = |markdown, key| {
		rendered = Md.render(
			markdown.to_utf8(),
			{
				uploads: |source| SecureImageTag.is_conversation_upload(key, source),
				code: colored_code,
			},
		)
		TrustedHtml.dangerously_trust(Str.from_utf8(rendered) ?? crash "Markdown.message_html: roc-markdown returned bytes that are not UTF-8, from UTF-8 input")
	}

	## The longest code block that is colored, 4 KiB, and a longer block is
	## roc-markdown's plain escape. roc-syntax-color's Roc lexer is
	## quadratic in the open brackets across a block's lines: 4 KiB of
	## `{` lines costs it about 29 ms on the box, and 8 KiB 97 ms. Its other
	## lexers, and ordinary Roc, are linear, about 3 ms a 4 KiB block at
	## their worst.
	most_colored_bytes : U64
	most_colored_bytes = 4 * 1024
}

## The code hook: a block in a language roc-syntax-color reads, colored and
## escaped; any other, roc-markdown's escape.
colored_code : { language : List(U8), body : List(U8) } -> [Colored(List(U8)), Plain]
colored_code = |{ language, body }|
	match colored_language(language) {
		Ok(_) if body.len() > Markdown.most_colored_bytes => Plain
		Ok(colored) => {
			text = Str.from_utf8(body) ?? crash "Markdown.colored_code: a block's body is not UTF-8, from UTF-8 input"
			Colored(SyntaxColor.html(colored, text).to_utf8())
		}
		Err(NotColored) => Plain
	}

## The language a fence names, by the word a member writes after its
## backticks.
colored_language : List(U8) -> Try(SyntaxColor.Language, [NotColored])
colored_language = |language|
	if language == "roc".to_utf8() {
		Ok(SyntaxColor.roc)
	} else if language == "js".to_utf8() {
		Ok(SyntaxColor.js)
	} else if language == "shale".to_utf8() {
		Ok(SyntaxColor.shale)
	} else if language == "zig".to_utf8() {
		Ok(SyntaxColor.zig)
	} else {
		Err(NotColored)
	}

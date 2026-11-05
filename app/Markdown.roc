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
import md.Md
import ConversationKey
import SecureImageTag
import TrustedHtml

Markdown :: [].{

	## `markdown`, exactly as written, of a message in the conversation
	## `key`, as markup a page can hold: it shows an image only from that
	## conversation's own uploads.
	render : Str, ConversationKey -> TrustedHtml
	render = |markdown, key| {
		rendered = Md.render(
			markdown.to_utf8(),
			{ uploads: |source| SecureImageTag.is_conversation_upload(key, source) },
		)
		TrustedHtml.dangerously_trust(Str.from_utf8(rendered) ?? crash "Markdown.render: roc-markdown returned bytes that are not UTF-8, from UTF-8 input")
	}
}

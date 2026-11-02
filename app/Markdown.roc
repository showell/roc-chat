## **A MESSAGE'S MARKDOWN, RENDERED**: the one entry to roc-markdown (the
## `md` package), and the only module that imports it. Its dialect is
## "Steve flavor" markdown, roc-markdown's own, held byte for byte to the
## Zig chat's renderer. roc-markdown takes and gives bytes; this module
## takes a `Str` and gives `TrustedHtml`, so the rest of the chat never
## handles the renderer's bytes.
##
## **WHY ITS OUTPUT IS VOUCHED FOR** (`TrustedHtml`): roc-markdown escapes
## every byte of a member's text through its one escape, lets through only
## the markup its own allowlist rebuilds, refuses a `javascript:` link, and
## shows media only from a source the uploads rule passes. That rule is
## `SecureImageTag.is_conversation_upload`, chosen here and nowhere else.
import md.Md
import SecureImageTag
import TrustedHtml

Markdown :: [].{

	## `markdown`, exactly as written, as markup a page can hold.
	render : Str -> TrustedHtml
	render = |markdown| {
		rendered = Md.render(markdown.to_utf8(), { uploads: SecureImageTag.is_conversation_upload })
		TrustedHtml.dangerously_trust(Str.from_utf8(rendered) ?? crash "Markdown.render: roc-markdown renders UTF-8 from UTF-8")
	}
}

# ── tests
# Its own markup kept, the text in it escaped.
expect Markdown.render("**hi** <b>").to_utf8() == "<p><strong>hi</strong> &lt;b&gt;</p>\n".to_utf8()
expect Markdown.render("a & <b>").to_utf8() == "<p>a &amp; &lt;b&gt;</p>\n".to_utf8()
# Rendered markup is trusted as it is: joined, its entities stay single.
expect
	TrustedHtml.join([TrustedHtml.dangerously_trust("&amp;"), Markdown.render("a & <b>")]).to_utf8()
		== "&amp;<p>a &amp; &lt;b&gt;</p>\n".to_utf8()
# No upload is known (SecureImageTag), so an image is its link; a
# `javascript:` link is text.
expect Markdown.render("![x](a.png)").to_utf8() == "<p><a href=\"a.png\">x</a></p>\n".to_utf8()
expect Markdown.render("[x](javascript:alert(1))").to_utf8() == "<p>[x](javascript:alert(1))</p>\n".to_utf8()

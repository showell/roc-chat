## A `TrustedHtml` is markup that code in this program has vouched for as
## ready to deliver in a page. A `Str` is text, never markup. The type says
## which a value is, so text can't reach a page unescaped, and markup can't
## be escaped a second time.
##
## The one way in is `dangerously_trust`, named so that every call stands
## out, and its callers are what a security reader audits. Each vouches
## only for markup it built or escaped itself, and each is small:
## `Escape.text` (text, escaped), `Html.element` (an element's tags, from
## closed sets and strict tokens), `Markdown.render` (roc-markdown's output,
## whose images `SecureImageTag` rules), and `Page`'s fixed doctype and
## style sheet. `join` builds only from markup already vouched for, so it
## vouches for nothing new.
##
## The one way out is bytes for the host (`to_utf8`). There is no way back
## to a `Str`, so trusted markup can't be handed to `Escape.text` and
## escaped again without a deliberate, fallible `Str.from_utf8`.
##
## This module is one of the program's five trust boundaries, and the way
## markup goes out to a page. The others are `UnvalidatedString`, the way
## text comes in; `SecureImageTag`, which images a message may show;
## `SignedIn`, who is acting; and `RequestOrigin`, which refuses a request
## from any origin but the server's own.
TrustedHtml :: Str.{

	## `html`, delivered as it is, with nothing escaped. This is dangerous.
	## The caller promises that its own code built or escaped every byte of
	## `html`, so no text a person, an agent or a file supplied is in it
	## unescaped. A wrong promise is an injection.
	dangerously_trust : Str -> TrustedHtml
	dangerously_trust = |html| TrustedHtml.(html)

	## The pieces, in order, each as it is.
	join : List(TrustedHtml) -> TrustedHtml
	join = |pieces| TrustedHtml.(Str.join_with(pieces.map(|TrustedHtml.(html)| html), ""))

	## The markup's bytes, for the host.
	to_utf8 : TrustedHtml -> List(U8)
	to_utf8 = |TrustedHtml.(html)| html.to_utf8()
}

# ── tests
expect TrustedHtml.dangerously_trust("<p>é</p>").to_utf8() == "<p>é</p>".to_utf8()
# Joined in order, each piece as it is, with nothing between them.
expect
	TrustedHtml.join([
		TrustedHtml.dangerously_trust("<p>"),
		TrustedHtml.dangerously_trust("&amp;"),
		TrustedHtml.dangerously_trust("</p>"),
	]).to_utf8()
		== "<p>&amp;</p>".to_utf8()
expect TrustedHtml.join([]).to_utf8() == []

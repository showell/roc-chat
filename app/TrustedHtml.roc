## **MARKUP SOME CODE HAS VOUCHED FOR**: a `TrustedHtml` is a string that
## code in this program has decided is ready to deliver as HTML. A `Str` is
## text, never markup. The type says which a value is, so text can't reach
## a page unescaped, and markup can't be escaped a second time.
##
## **THE ONE DOOR IS `dangerously_trust`, AND ITS CALLERS ARE THE AUDIT**,
## named to be seen at every call: each
## vouches only for HTML it built or escaped itself. They are few, and
## each is small: `Escape.text` (text, escaped), `HtmlElement.tag` (an
## element's tags, from closed sets and strict tokens), `Markdown.render`
## (roc-markdown's output, whose images `SecureImageTag` rules: the other
## trust boundary a security reader wants), and
## `Page`'s fixed head and style sheet. `join` builds only from what is
## already vouched for, so it vouches for nothing new.
##
## **THE WAY OUT IS BYTES**: `to_utf8`, for the host. There is no way back
## to a `Str`, so trusted markup can't be handed to `Escape.text` and
## escaped again without a deliberate, fallible `Str.from_utf8`.
TrustedHtml :: Str.{

	## **THE DOOR, AND IT IS DANGEROUS**: `html`, delivered as it is, with
	## nothing escaped. The caller promises that its own code built or
	## escaped every byte of `html`, so no text a person, an agent or a file
	## supplied is in it unescaped. A wrong promise is an injection.
	dangerously_trust : Str -> TrustedHtml
	dangerously_trust = |html| TrustedHtml.(html)

	## The pieces, in order, each as it is.
	join : List(TrustedHtml) -> TrustedHtml
	join = |pieces| TrustedHtml.(Str.join_with(pieces.map(|TrustedHtml.(html)| html), ""))

	## The page's bytes, for the host: the one way out.
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

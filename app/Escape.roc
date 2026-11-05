## This module turns text into markup a page can show. Every `Str` a page
## shows, whether a person, an agent or a file supplied it, goes through
## `Escape.text`. It vouches for its answer (`TrustedHtml`) because it has
## just escaped every character that could start markup, so no text it is
## given becomes markup, in an element or in an attribute.
import TrustedHtml

Escape :: [].{

	## `text`, escaped, as markup a page can hold.
	text : Str -> TrustedHtml
	text = |s| TrustedHtml.dangerously_trust(escaped_text(s))
}

## `s` with `&`, `<`, `>`, `"` and `'` written as entities. `&` is escaped
## first, so no entity written here is escaped again.
escaped_text : Str -> Str
escaped_text = |s|
	s
		.replace_each("&", "&amp;")
		.replace_each("<", "&lt;")
		.replace_each(">", "&gt;")
		.replace_each("\"", "&quot;")
		.replace_each("'", "&#39;")

# ── tests
## The bytes of `text`, escaped.
escaped_bytes : Str -> List(U8)
escaped_bytes = |text| Escape.text(text).to_utf8()

# Each of the five characters becomes its entity.
expect
	[
		("&", "&amp;"),
		("<", "&lt;"),
		(">", "&gt;"),
		("\"", "&quot;"),
		("'", "&#39;"),
	].all(|(text, expected)| escaped_bytes(text) == expected.to_utf8())
expect
	escaped_bytes("Bea <i>x</i> & \"co\" 'q'")
		== "Bea &lt;i&gt;x&lt;/i&gt; &amp; &quot;co&quot; &#39;q&#39;".to_utf8()
# Anything else is kept as it is.
expect escaped_bytes("café 🎉 =/;#") == "café 🎉 =/;#".to_utf8()
expect escaped_bytes("") == []
# Text is escaped exactly once: `&amp;` as text is `&amp;amp;`, and that
# markup, joined into more markup, is not escaped again.
expect {
	once = Escape.text("&amp;")
	[
		(once, "&amp;amp;"),
		(TrustedHtml.join([once]), "&amp;amp;"),
		(TrustedHtml.join([TrustedHtml.join([once]), once]), "&amp;amp;&amp;amp;"),
	].all(|(html, expected)| html.to_utf8() == expected.to_utf8())
}
expect TrustedHtml.join([Escape.text("a&b"), Escape.text("<")]).to_utf8() == "a&amp;b&lt;".to_utf8()

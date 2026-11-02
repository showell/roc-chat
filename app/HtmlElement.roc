## **AN HTML ELEMENT, BUILT ONLY FROM SAFE PARTS**: `tag` writes
## `<name a="v">inner</name>`, and vouches (`TrustedHtml`) for the two tags
## it writes around `inner`, which is already trusted. Each part of a tag
## is safe by its type, so nothing is escaped and nothing needs to be:
##
## - a name is from a closed set (`Name`), so a tag's name is never data;
## - an attribute's name is its tag (`Attribute`), so a name and its value
##   can't be swapped;
## - every value is a `Token` (ASCII letters, digits and `-`, checked by
##   `Token.from_str`) or a `DateTime` (its one form, digits and `-:TZ`),
##   so no value holds a quote, `&`, `<`, a space or a `:`.
##
## **NO LINK LEAVES THE PAGE**: `Href` always writes `#` and a token, a
## fragment of this page, and a token can't spell a scheme or a path.
## **NO CLASS IS FREE TEXT**: a class is a token, never a sentence or a
## list; which classes a page uses is the page's closed set (`Page.Class`).
import Ascii
import DateTime
import TrustedHtml

HtmlElement :: [].{

	## **AN ELEMENT A PAGE USES**: a closed set, so a tag's name is never data.
	Name : [A, Article, Div, H1, Header, P, Span, Time, Title]

	## **A STRICT TOKEN**: one or more ASCII letters, digits and `-`, so it
	## can stand in an attribute's quotes, and after a `#`, as it is.
	Token :: Str.{

		## The token `text` spells, or why it is refused.
		from_str : Str -> Try(HtmlElement.Token, [Empty, ForbiddenByte])
		from_str = |text|
			if (text.is_empty())
				Err(Empty)
			else if (text.to_utf8().all(is_token_byte))
				Ok(HtmlElement.Token.(text))
			else
				Err(ForbiddenByte)

		## The token as written.
		to_str : HtmlElement.Token -> Str
		to_str = |HtmlElement.Token.(text)| text

		is_eq : _
	}

	## **AN ATTRIBUTE, ITS NAME BY ITS TAG**: a class, an id and a link to
	## an id on this page, each a token, and a time.
	Attribute : [
		Class(HtmlElement.Token),
		Id(HtmlElement.Token),
		Href(HtmlElement.Token),
		DateTime(DateTime),
	]

	## **AN ELEMENT**: `<name a="v">inner</name>`, `inner` as it is,
	## already trusted.
	tag : {
		name : HtmlElement.Name,
		attrs : List(HtmlElement.Attribute),
		inner : TrustedHtml,
	} -> TrustedHtml
	tag = |
		{
			name,
			attrs,
			inner,
		},
	| {
		written = name_of(name)
		opened = Str.join_with(attrs.map(attribute), "")
		TrustedHtml.join([
			TrustedHtml.dangerously_trust("<${written}${opened}>"),
			inner,
			TrustedHtml.dangerously_trust("</${written}>"),
		])
	}
}

is_token_byte : U8 -> Bool
is_token_byte = |b| Ascii.is_letter(b) or Ascii.is_digit(b) or b == '-'

name_of : HtmlElement.Name -> Str
name_of = |name|
	match name {
		A => "a"
		Article => "article"
		Div => "div"
		H1 => "h1"
		Header => "header"
		P => "p"
		Span => "span"
		Time => "time"
		Title => "title"
	}

## One attribute as an element's open tag writes it, space first.
attribute : HtmlElement.Attribute -> Str
attribute = |attr|
	match attr {
		Class(token) => " class=\"${token.to_str()}\""
		Id(token) => " id=\"${token.to_str()}\""
		Href(token) => " href=\"#${token.to_str()}\""
		DateTime(time) => " datetime=\"${time.to_str()}\""
	}

# ── tests
## The token `text` spells, which a test knows is one.
token : Str -> HtmlElement.Token
token = |text| HtmlElement.Token.from_str(text) ?? crash "HtmlElement's tests: a token"

# A token: letters, digits and `-`, and the bytes beside each range refused.
expect HtmlElement.Token.from_str("aAzZ09-").map_ok(HtmlElement.Token.to_str) == Ok("aAzZ09-")
expect HtmlElement.Token.from_str("-").map_ok(HtmlElement.Token.to_str) == Ok("-")
expect HtmlElement.Token.from_str("msg-1").map_ok(HtmlElement.Token.to_str) == Ok("msg-1")
expect HtmlElement.Token.from_str("") == Err(Empty)
expect
	[
		"a/",
		"a:",
		"a@",
		"a[",
		"a`",
		"a{",
		"a,",
		"a.",
		"a b",
		"a\"b",
		"a'b",
		"a&b",
		"a<b",
		"a#b",
		"é",
	].map(HtmlElement.Token.from_str)
		== List.repeat(Err(ForbiddenByte), 15)
# No link leaves the page: a scheme, a path or another origin is no token.
expect
	[
		"javascript:alert(1)",
		"https://evil.example",
		"//evil.example",
		"/etc",
	].map(HtmlElement.Token.from_str)
		== List.repeat(Err(ForbiddenByte), 4)
# Every attribute, as an open tag writes it: a link is always `#` and a
# token.
expect
	[
		Class(token("author")),
		Id(token("msg-1")),
		Href(token("msg-1")),
		Href(token("msg-2")),
	].map(attribute)
		== [
			" class=\"author\"",
			" id=\"msg-1\"",
			" href=\"#msg-1\"",
			" href=\"#msg-2\"",
		]
expect
	DateTime.from_str("2026-11-02T19:11:32Z").map_ok(|time| attribute(DateTime(time)))
		== Ok(" datetime=\"2026-11-02T19:11:32Z\"")
expect [A, Article, Div, H1, Header, P, Span, Time, Title].map(name_of) == [
	"a",
	"article",
	"div",
	"h1",
	"header",
	"p",
	"span",
	"time",
	"title",
]
# An element: its attributes in order, `inner` as it is, never escaped
# again.
expect
	HtmlElement.tag({
		name: A,
		attrs: [Class(token("ref")), Href(token("msg-1"))],
		inner: TrustedHtml.dangerously_trust("&lt;i&gt;"),
	}).to_utf8()
		== "<a class=\"ref\" href=\"#msg-1\">&lt;i&gt;</a>".to_utf8()
expect
	HtmlElement.tag({
		name: P,
		attrs: [],
		inner: TrustedHtml.join([]),
	}).to_utf8()
		== "<p></p>".to_utf8()

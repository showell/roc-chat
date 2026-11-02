## **AN HTML ELEMENT, BUILT ONLY FROM SAFE PARTS**: `element` writes
## `<name a="v">inner</name>`, and vouches (`TrustedHtml`) for the two tags
## it writes around `inner`, which is already trusted. Each part of a tag
## is safe by its type, so nothing is escaped and nothing needs to be:
##
## - a name is from a closed set (`Name`), so a tag's name is never data;
## - an attribute's name is its tag (`Attribute`), so a name and its value
##   can't be swapped;
## - every value is a `Token` (ASCII letters, digits and `-`, checked by
##   `Token.from_str`), a `SitePath` (`/` and parts of letters, digits,
##   `-`, `_` and `.`, checked by `SitePath.from_str`) or a `DateTime` (its
##   one form, digits and `-:TZ`), so no value holds a quote, `&`, `<`, a
##   space or a `:`; a flag (`MethodPost`, `Required`) holds no value.
##
## **NO LINK LEAVES THE SITE**: `Href` always writes `#` and a token, a
## fragment of this page, and a token can't spell a scheme or a path; a
## form's `Action` and a script's `Src` are a `SitePath`, which starts
## with one `/` and can't spell a scheme or another host.
## **NO CLASS IS FREE TEXT**: a class is a token, never a sentence or a
## list; which classes a page uses is the page's closed set (`Page.Class`).
import Ascii
import DateTime
import TrustedHtml

Html :: [].{

	## **AN ELEMENT A PAGE USES**: a closed set, so a tag's name is never data.
	Name : [
		A,
		Article,
		Button,
		Div,
		Form,
		H1,
		Header,
		P,
		Script,
		Span,
		Textarea,
		Time,
		Title,
	]

	## **A STRICT TOKEN**: one or more ASCII letters, digits and `-`, so it
	## can stand in an attribute's quotes, and after a `#`, as it is.
	Token :: Str.{

		## The token `text` spells, or why it is refused.
		from_str : Str -> Try(Html.Token, [Empty, ForbiddenByte])
		from_str = |text|
			if (text.is_empty())
				Err(Empty)
			else if (text.to_utf8().all(is_token_byte))
				Ok(Html.Token.(text))
			else
				Err(ForbiddenByte)

		## The token as written.
		to_str : Html.Token -> Str
		to_str = |Html.Token.(text)| text

		is_eq : _
	}

	## **A PATH ON THIS SITE**: `/`, then one or more parts joined by `/`,
	## each of ASCII letters, digits, `-`, `_` and `.`, and none starting
	## with `.`. So it can stand in an attribute's quotes as it is, and can't
	## name another host (`//`), a scheme (`:`) or a folder above (`..`).
	SitePath :: Str.{

		## The path `text` spells, or why it is refused.
		from_str : Str -> Try(
			Html.SitePath,
			[
				NoLeadingSlash,
				EmptyPart,
				HiddenPart,
				ForbiddenByte,
			],
		)
		from_str = |text|
			if (text.starts_with("/"))
				text.drop_prefix("/").split_on("/").map_try(site_path_part).map_ok(|_| Html.SitePath.(text))
			else
				Err(NoLeadingSlash)

		## The path as written.
		to_str : Html.SitePath -> Str
		to_str = |Html.SitePath.(text)| text

		is_eq : _
	}

	## **AN ATTRIBUTE, ITS NAME BY ITS TAG**: a class, an id and a link to
	## an id on this page, each a token; a time; a form's field name, its
	## method (always POST) and where it posts; whether a field is required;
	## and a script's source.
	Attribute : [
		Class(Html.Token),
		Id(Html.Token),
		Href(Html.Token),
		DateTime(DateTime),
		FieldName(Html.Token),
		MethodPost,
		Action(Html.SitePath),
		Required,
		Src(Html.SitePath),
	]

	## **AN ELEMENT**: `<name a="v">inner</name>`, `inner` as it is,
	## already trusted.
	element : {
		name : Html.Name,
		attrs : List(Html.Attribute),
		inner : TrustedHtml,
	} -> TrustedHtml
	element = |
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

## Whether `part`, between a site path's `/`s, is one, or why not.
site_path_part : Str -> Try({}, [EmptyPart, HiddenPart, ForbiddenByte])
site_path_part = |part|
	if (part.is_empty())
		Err(EmptyPart)
	else if (part.starts_with("."))
		Err(HiddenPart)
	else if (part.to_utf8().all(|b| is_token_byte(b) or b == '_' or b == '.'))
		Ok({})
	else
		Err(ForbiddenByte)

name_of : Html.Name -> Str
name_of = |name|
	match name {
		A => "a"
		Article => "article"
		Button => "button"
		Div => "div"
		Form => "form"
		H1 => "h1"
		Header => "header"
		P => "p"
		Script => "script"
		Span => "span"
		Textarea => "textarea"
		Time => "time"
		Title => "title"
	}

## One attribute as an element's open tag writes it, space first.
attribute : Html.Attribute -> Str
attribute = |attr|
	match attr {
		Class(token) => " class=\"${token.to_str()}\""
		Id(token) => " id=\"${token.to_str()}\""
		Href(token) => " href=\"#${token.to_str()}\""
		DateTime(time) => " datetime=\"${time.to_str()}\""
		FieldName(token) => " name=\"${token.to_str()}\""
		MethodPost => " method=\"post\""
		Action(path) => " action=\"${path.to_str()}\""
		Required => " required"
		Src(path) => " src=\"${path.to_str()}\""
	}

# ── tests
## The token `text` spells, which a test knows is one.
token : Str -> Html.Token
token = |text| Html.Token.from_str(text) ?? crash "Html's tests: a token"

# A token: letters, digits and `-`, and the bytes beside each range refused.
expect Html.Token.from_str("aAzZ09-").map_ok(Html.Token.to_str) == Ok("aAzZ09-")
expect Html.Token.from_str("-").map_ok(Html.Token.to_str) == Ok("-")
expect Html.Token.from_str("msg-1").map_ok(Html.Token.to_str) == Ok("msg-1")
expect Html.Token.from_str("") == Err(Empty)
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
	].map(Html.Token.from_str)
		== List.repeat(Err(ForbiddenByte), 15)
# No link leaves the page: a scheme, a path or another origin is no token.
expect
	[
		"javascript:alert(1)",
		"https://evil.example",
		"//evil.example",
		"/etc",
	].map(Html.Token.from_str)
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
expect
	[
		A,
		Article,
		Button,
		Div,
		Form,
		H1,
		Header,
		P,
		Script,
		Span,
		Textarea,
		Time,
		Title,
	].map(name_of)
		== [
			"a",
			"article",
			"button",
			"div",
			"form",
			"h1",
			"header",
			"p",
			"script",
			"span",
			"textarea",
			"time",
			"title",
		]
# A site path: `/` and parts of letters, digits, `-`, `_` and `.`, both
# sides of each refusal.
expect
	[
		"/chat/channel/general/gopher-roc",
		"/chat/dm/1_1/plans",
		"/chat/assets/compose.js",
		"/a",
	].map(|text| Html.SitePath.from_str(text).map_ok(Html.SitePath.to_str))
		== [
			Ok("/chat/channel/general/gopher-roc"),
			Ok("/chat/dm/1_1/plans"),
			Ok("/chat/assets/compose.js"),
			Ok("/a"),
		]
expect
	[
		"chat/x",
		"",
		"https://evil.example",
		"/",
		"//evil.example",
		"/a//b",
		"/a/",
		"/a/../b",
		"/.hidden",
		"/a/.js",
		"/a:b",
		"/a b",
		"/a\"b",
		"/a?b",
		"/a#b",
		"/a%2e",
		"/é",
	].map(Html.SitePath.from_str)
		== [
			Err(NoLeadingSlash),
			Err(NoLeadingSlash),
			Err(NoLeadingSlash),
			Err(EmptyPart),
			Err(EmptyPart),
			Err(EmptyPart),
			Err(EmptyPart),
			Err(HiddenPart),
			Err(HiddenPart),
			Err(HiddenPart),
			Err(ForbiddenByte),
			Err(ForbiddenByte),
			Err(ForbiddenByte),
			Err(ForbiddenByte),
			Err(ForbiddenByte),
			Err(ForbiddenByte),
			Err(ForbiddenByte),
		]
# Every new attribute, as an open tag writes it.
expect {
	path = |text| Html.SitePath.from_str(text) ?? crash "Html's tests: a site path"
	[
		FieldName(token("markdown")),
		MethodPost,
		Action(path("/chat/dm/1_1/plans")),
		Required,
		Src(path("/chat/assets/compose.js")),
	].map(attribute)
		== [
			" name=\"markdown\"",
			" method=\"post\"",
			" action=\"/chat/dm/1_1/plans\"",
			" required",
			" src=\"/chat/assets/compose.js\"",
		]
}
# An element: its attributes in order, `inner` as it is, never escaped
# again.
expect
	Html.element({
		name: A,
		attrs: [Class(token("ref")), Href(token("msg-1"))],
		inner: TrustedHtml.dangerously_trust("&lt;i&gt;"),
	}).to_utf8()
		== "<a class=\"ref\" href=\"#msg-1\">&lt;i&gt;</a>".to_utf8()
expect
	Html.element({
		name: P,
		attrs: [],
		inner: TrustedHtml.join([]),
	}).to_utf8()
		== "<p></p>".to_utf8()

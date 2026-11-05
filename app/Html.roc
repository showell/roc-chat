## This module builds an HTML element only from safe parts. `element`
## writes `<name a="v">inner</name>`, and vouches (`TrustedHtml`) for the
## two tags it writes around `inner`, which is already trusted. Each part of
## a tag is safe by its type, so nothing is escaped and nothing needs to be:
##
## - a name is from a closed set (`Name`), so a tag's name is never data;
## - an attribute's name is its tag (`Attribute`), so a name and its value
##   can't be swapped; a `data-` attribute's name is a `Token`;
## - every value is a `Token` (ASCII letters, digits and `-`, checked by
##   `Token.from_str`), a `SitePath` (`/` and parts of letters, digits,
##   `-`, `_` and `.`, checked by `SitePath.from_str`) or a `DateTime` (its
##   one form, digits and `-:TZ`), so no value holds a quote, `&`, `<`, a
##   space or a `:`; a flag (`MethodPost`, `Required`) holds no value.
##
## An `<input>` has no end tag and holds nothing (`input`). Its value, the
## one an input field may carry, is a site path, a form's hidden `next`.
##
## No link leaves the site. `Href` always writes `#` and a token, a
## fragment of this page, and a token can't spell a scheme or a path. A
## `Link` to another page, a form's `Action` and a script's `Src` are a
## `SitePath`, which starts with one `/` and can't spell a scheme or another
## host.
##
## No class is free text. A class is a token, never a sentence or a list.
## Which classes a page uses, and which `data-` attributes, is the page's
## to say (`Page.Class`, `Page.DataAttribute`).
import Ascii
import DateTime
import TrustedHtml

Html :: [].{

	## An element a page uses: a closed set, so a tag's name is never data.
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

	## A strict token: one or more ASCII letters, digits and `-`, so it
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

	## A path on this site: `/`, then one or more parts joined by `/`,
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
				text.drop_prefix("/")
					.split_on("/")
					.map_try(site_path_part)
					.map_ok(|_| Html.SitePath.(text))
			else
				Err(NoLeadingSlash)

		## The path as written.
		to_str : Html.SitePath -> Str
		to_str = |Html.SitePath.(text)| text

		is_eq : _
	}

	## An attribute, its name by its tag: a class, an id and a link to an id
	## on this page, each a token; a link to another page of this site, a
	## site path; a time; a form's field name, its method
	## (always POST) and where it posts; whether a field is required; an
	## input's type, its value (a site path) and what a browser may fill it
	## with; a script's source; and a `data-` attribute for a page's
	## scripts: its name after `data-`, a token, then its value, a token or
	## a site path.
	Attribute : [
		Class(Html.Token),
		Id(Html.Token),
		Href(Html.Token),
		Link(Html.SitePath),
		LinkWithNext({ path : Html.SitePath, next : Html.SitePath }),
		DateTime(DateTime),
		FieldName(Html.Token),
		MethodPost,
		Action(Html.SitePath),
		Required,
		InputType([Hidden, Password, Text]),
		Value(Html.SitePath),
		Autocomplete([Username, CurrentPassword, NewPassword]),
		Src(Html.SitePath),
		Data(Html.Token, [Token(Html.Token), Path(Html.SitePath)]),
	]

	## An element: `<name a="v">inner</name>`, `inner` as it is, already
	## trusted.
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
		tag_name = name_of(name)
		attributes_text = Str.join_with(attrs.map(attribute), "")
		TrustedHtml.join([
			TrustedHtml.dangerously_trust("<${tag_name}${attributes_text}>"),
			inner,
			TrustedHtml.dangerously_trust("</${tag_name}>"),
		])
	}

	## An input: `<input a="v">`, which has no end tag and holds nothing.
	input : List(Html.Attribute) -> TrustedHtml
	input = |attrs|
		TrustedHtml.dangerously_trust("<input${Str.join_with(attrs.map(attribute), "")}>")
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
		Link(path) => " href=\"${path.to_str()}\""
		LinkWithNext({ path, next }) => " href=\"${path.to_str()}?next=${next.to_str()}\""
		DateTime(time) => " datetime=\"${time.to_str()}\""
		FieldName(token) => " name=\"${token.to_str()}\""
		MethodPost => " method=\"post\""
		Action(path) => " action=\"${path.to_str()}\""
		Required => " required"
		InputType(Hidden) => " type=\"hidden\""
		InputType(Password) => " type=\"password\""
		InputType(Text) => " type=\"text\""
		Value(path) => " value=\"${path.to_str()}\""
		Autocomplete(Username) => " autocomplete=\"username\""
		Autocomplete(CurrentPassword) => " autocomplete=\"current-password\""
		Autocomplete(NewPassword) => " autocomplete=\"new-password\""
		Src(path) => " src=\"${path.to_str()}\""
		Data(name, Token(token)) => " data-${name.to_str()}=\"${token.to_str()}\""
		Data(name, Path(path)) => " data-${name.to_str()}=\"${path.to_str()}\""
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
	].all(|text| Html.Token.from_str(text) == Err(ForbiddenByte))
# No link leaves the page: a scheme, a path or another origin is no token.
expect
	[
		"javascript:alert(1)",
		"https://evil.example",
		"//evil.example",
		"/etc",
	].all(|text| Html.Token.from_str(text) == Err(ForbiddenByte))
# Every attribute, as an open tag writes it: a link is always `#` and a
# token.
expect attribute(Class(token("author"))) == " class=\"author\""
expect attribute(Id(token("msg-1"))) == " id=\"msg-1\""
expect attribute(Href(token("msg-1"))) == " href=\"#msg-1\""
expect attribute(Href(token("msg-2"))) == " href=\"#msg-2\""
# A `data-` attribute: its name after `data-`, and a token or a site path.
expect attribute(Data(token("after"), Token(token("6")))) == " data-after=\"6\""
expect attribute(
	Data(
		token("image-byte-limit"),
		Token(token("10485760")),
	),
) == " data-image-byte-limit=\"10485760\""
expect
	Html.SitePath.from_str("/chat/dm/1_1/plans/stream").map_ok(
		|path| attribute(
			Data(
				token("stream"),
				Path(path),
			),
		),
	)
		== Ok(" data-stream=\"/chat/dm/1_1/plans/stream\"")
expect
	DateTime.from_str("2026-11-02T19:11:32Z").map_ok(|time| attribute(DateTime(time)))
		== Ok(" datetime=\"2026-11-02T19:11:32Z\"")
expect name_of(A) == "a"
expect name_of(Article) == "article"
expect name_of(Button) == "button"
expect name_of(Div) == "div"
expect name_of(Form) == "form"
expect name_of(H1) == "h1"
expect name_of(Header) == "header"
expect name_of(P) == "p"
expect name_of(Script) == "script"
expect name_of(Span) == "span"
expect name_of(Textarea) == "textarea"
expect name_of(Time) == "time"
expect name_of(Title) == "title"
# A site path: `/` and parts of letters, digits, `-`, `_` and `.`, both
# sides of each refusal.
expect
	[
		"/chat/channel/general/gopher-roc",
		"/chat/dm/1_1/plans",
		"/chat/assets/compose.js",
		"/a",
	].all(|text| Html.SitePath.from_str(text).map_ok(Html.SitePath.to_str) == Ok(text))
expect
	[
		"chat/x",
		"",
		"https://evil.example",
	].all(|text| Html.SitePath.from_str(text) == Err(NoLeadingSlash))
expect
	[
		"/",
		"//evil.example",
		"/a//b",
		"/a/",
	].all(|text| Html.SitePath.from_str(text) == Err(EmptyPart))
expect
	[
		"/a/../b",
		"/.hidden",
		"/a/.js",
	].all(|text| Html.SitePath.from_str(text) == Err(HiddenPart))
expect
	[
		"/a:b",
		"/a b",
		"/a\"b",
		"/a?b",
		"/a#b",
		"/a%2e",
		"/é",
	].all(|text| Html.SitePath.from_str(text) == Err(ForbiddenByte))
# Every new attribute, as an open tag writes it.
expect {
	path = |text| Html.SitePath.from_str(text) ?? crash "Html's tests: a site path"
	[
		(FieldName(token("markdown")), " name=\"markdown\""),
		(MethodPost, " method=\"post\""),
		(Action(path("/chat/dm/1_1/plans")), " action=\"/chat/dm/1_1/plans\""),
		(Required, " required"),
		(Src(path("/chat/assets/compose.js")), " src=\"/chat/assets/compose.js\""),
	].all(|(attr, expected)| attribute(attr) == expected)
}
# An input's attributes, each as an open tag writes it.
expect {
	path = Html.SitePath.from_str("/agents") ?? crash "Html's tests: a site path"
	[
		(InputType(Hidden), " type=\"hidden\""),
		(InputType(Password), " type=\"password\""),
		(InputType(Text), " type=\"text\""),
		(Value(path), " value=\"/agents\""),
		(Autocomplete(Username), " autocomplete=\"username\""),
		(Autocomplete(CurrentPassword), " autocomplete=\"current-password\""),
		(Autocomplete(NewPassword), " autocomplete=\"new-password\""),
	].all(|(attr, expected)| attribute(attr) == expected)
}
# A link to another page of this site: its site path, as it is.
expect
	Html.SitePath.from_str("/channels/general").map_ok(|path| attribute(Link(path)))
		== Ok(" href=\"/channels/general\"")
# An input: its attributes in order, no end tag.
expect
	Html.input([
		InputType(Password),
		FieldName(token("password")),
		Required,
	]).to_utf8()
		== "<input type=\"password\" name=\"password\" required>".to_utf8()
expect Html.input([]).to_utf8() == "<input>".to_utf8()
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

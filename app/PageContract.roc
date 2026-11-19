## This module is the one contract between the pages, which the Roc writes,
## and the scripts that run on them (app/chrome.js, app/compose.js,
## app/feed.js and app/panel.js, which `Script` serves). The server sends
## structure and class names only, and each script finds what it needs by
## the classes in `Class` and by the `data-` attributes in `DataAttribute`.
## Someone replacing the scripts reads this module, and its tests say which
## script reads which name.
##
## The messages pane names its stream (`data-stream`), how many messages it
## shows (`data-after`) and the viewer's id (`data-viewer`), all read by
## app/feed.js. A message names its author's id (`data-author`) when its
## author is a user of the chat. The compose box's form names where the
## script sends a message (`data-send`), where to upload an image
## (`data-upload`) and the most bytes an image may be
## (`data-image-byte-limit`), all read by app/compose.js.
import Html
import Script
import TrustedHtml

PageContract :: [].{

	## A class a page uses: a closed set, so a class is never data.
	Class : [
		Author,
		Body,
		Compose,
		Empty,
		Help,
		InviteCode,
		Layout,
		Message,
		Messages,
		Panel,
		Ref,
		TopBar,
		TopTitle,
		TopUser,
		Viewer,
	]

	## The class attribute for `class`, its one spelling.
	class : PageContract.Class -> Html.Attribute
	class = |chosen| Class(token(class_name(chosen)))

	## A `data-` attribute a page writes for its scripts, with its value:
	## a closed set, so `data_attribute` is the one spelling of each name.
	DataAttribute : [
		Stream(Html.SitePath),
		After(Html.Token),
		Viewer(Html.Token),
		Author(Html.Token),
		Send(Html.SitePath),
		Upload(Html.SitePath),
		ImageByteLimit(Html.Token),
	]

	## The `data-` attribute `chosen` names, with its value.
	data_attribute : PageContract.DataAttribute -> Html.Attribute
	data_attribute = |chosen|
		match chosen {
			Stream(path) => Data(token("stream"), Path(path))
			After(count) => Data(token("after"), Token(count))
			Viewer(id) => Data(token("viewer"), Token(id))
			Author(id) => Data(token("author"), Token(id))
			Send(path) => Data(token("send"), Path(path))
			Upload(path) => Data(token("upload"), Path(path))
			ImageByteLimit(count) => Data(token("image-byte-limit"), Token(count))
		}

	## An element `attrs` alone opens, as a test reads it.
	empty_paragraph : List(Html.Attribute) -> List(U8)
	empty_paragraph = |attrs|
		Html.element({ name: P, attrs, inner: TrustedHtml.join([]) }).to_utf8()
}

class_name : PageContract.Class -> Str
class_name = |chosen|
	match chosen {
		Author => "author"
		Body => "body"
		Compose => "compose"
		Empty => "empty"
		Help => "help"
		InviteCode => "invite-code"
		Layout => "layout"
		Message => "message"
		Messages => "messages"
		Panel => "panel"
		Ref => "ref"
		TopBar => "top-bar"
		TopTitle => "top-title"
		TopUser => "top-user"
		Viewer => "viewer"
	}

## The token `text` spells, for a name this module writes: one that isn't
## is this module's bug. (`PageKit.token` is the pages' own; this module
## stands below `PageKit`, which uses its classes, so it keeps its own.)
token : Str -> Html.Token
token = |text|
	Html.Token.from_str(text)
		?? crash "PageContract.token: \"${text}\" is a name this module writes, and not a token"

# ── tests
# Every class, each its one spelling.
expect
	[
		(Author, "author"),
		(Body, "body"),
		(Compose, "compose"),
		(Empty, "empty"),
		(Help, "help"),
		(InviteCode, "invite-code"),
		(Layout, "layout"),
		(Message, "message"),
		(Messages, "messages"),
		(Panel, "panel"),
		(Ref, "ref"),
		(TopBar, "top-bar"),
		(TopTitle, "top-title"),
		(TopUser, "top-user"),
		(Viewer, "viewer"),
	].all(
		|
			(chosen, spelled),
		| PageContract.empty_paragraph([PageContract.class(chosen)]) == "<p class=\"${spelled}\"></p>".to_utf8(),
	)
# Every `data-` attribute, each its one spelling, a path or a token.
expect {
	path = Html.SitePath.from_str("/chat/dm/1_1/plans") ?? crash "PageContract's tests: a site path"
	[
		(Stream(path), "<p data-stream=\"/chat/dm/1_1/plans\"></p>"),
		(After(token("6")), "<p data-after=\"6\"></p>"),
		(Viewer(token("1")), "<p data-viewer=\"1\"></p>"),
		(Author(token("3")), "<p data-author=\"3\"></p>"),
		(Send(path), "<p data-send=\"/chat/dm/1_1/plans\"></p>"),
		(Upload(path), "<p data-upload=\"/chat/dm/1_1/plans\"></p>"),
		(ImageByteLimit(token("10485760")), "<p data-image-byte-limit=\"10485760\"></p>"),
	].all(
		|(chosen, expected)|
			PageContract.empty_paragraph([PageContract.data_attribute(chosen)])
				== expected.to_utf8(),
	)
}

## Whether the script `bytes` finds the class `chosen` by its selector, a
## string literal in any of JavaScript's three quotes.
is_found_by : List(U8), PageContract.Class -> Bool
is_found_by = |bytes, chosen| has_quoted(bytes, ".${class_name(chosen)}")

## Whether the script `bytes` reads the attribute `name`, a string literal
## in any of JavaScript's three quotes.
is_read_by : List(U8), Str -> Bool
is_read_by = |bytes, name| has_quoted(bytes, name)

## Whether the script `bytes` holds `text` as a whole string literal, in
## single quotes, double quotes or backticks.
has_quoted : List(U8), Str -> Bool
has_quoted = |bytes, text| {
	script_text = Str.from_utf8_lossy(bytes)
	["'", "\"", "`"].any(|quote| script_text.contains("${quote}${text}${quote}"))
}

# A literal is found in each of the three quotes, and only whole.
expect ["'.x'", "\".x\"", "`.x`"].all(|held| has_quoted(held.to_utf8(), ".x"))
expect ["'.xy'", "\".x'", ".x", "'.x\""].all(|held| !has_quoted(held.to_utf8(), ".x"))

# Each script finds the elements it works on by the classes this module
# writes, and reads the attributes `Html` writes for it; a class or an
# attribute it leaves to another script is not in it.
expect [TopBar, TopUser].all(|chosen| is_found_by(Script.Chrome.bytes(), chosen))
expect
	[Layout, Messages, Compose, Help].all(|chosen| is_found_by(Script.Compose.bytes(), chosen))
expect
	[Messages, Compose, Message, Empty].all(|chosen| is_found_by(Script.Feed.bytes(), chosen))
expect [Panel, InviteCode].all(|chosen| is_found_by(Script.Panel.bytes(), chosen))
expect !is_found_by(Script.Panel.bytes(), Messages) and !is_found_by(Script.Feed.bytes(), Panel)
expect !is_found_by(Script.Compose.bytes(), Message) and !is_found_by(Script.Compose.bytes(), Empty)
expect !is_found_by(Script.Feed.bytes(), Help) and !is_found_by(Script.Chrome.bytes(), Messages)
expect
	["data-stream", "data-after", "data-viewer", "data-author"].all(
		|name| is_read_by(Script.Feed.bytes(), name) and !is_read_by(Script.Compose.bytes(), name),
	)
expect
	["data-send", "data-upload", "data-image-byte-limit"].all(
		|name| is_read_by(Script.Compose.bytes(), name) and !is_read_by(Script.Feed.bytes(), name),
	)
# The classes only styled are styled by the script that owns them.
expect [
	TopTitle,
	Viewer,
].all(|chosen| Str.from_utf8_lossy(Script.Chrome.bytes()).contains(".${class_name(chosen)} {"))

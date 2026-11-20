## This module is the one contract between the pages, which the Roc writes,
## and the scripts that run on them (app/chrome.js, app/sidebar.js,
## app/sidebar-popups.js,
## app/compose.js, app/emoji.js, app/feed.js, app/actions.js, app/panel.js and
## app/recent.js, which
## `Script` serves). The server sends
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
## (`data-image-byte-limit`), all read by app/compose.js. The messages pane
## also names where a reaction is posted (`data-react`) and where a
## message's markdown is read (`data-raw`), where the conversation's
## download is (`data-download`), and each reaction's button names
## its reactors' ids (`data-reactors`), all read by app/actions.js. Each place in the
## sidebar names its own path (`data-section`), which app/sidebar.js keeps
## its collapsed state by, and where a topic added to it belongs; a DM with
## another human names them (`data-person`) and says whether they are
## online (`data-presence`, by `Presence`), which app/sidebar.js draws as a
## dot; each place says how it starts (`data-opening`, by `SidebarOrder`),
## which app/sidebar.js opens or collapses it by. The places come in two
## groups, each naming itself (`data-group`), which app/sidebar.js keeps a
## group's collapsed state by, and the DMs group ends with the DMs that wait
## behind its "more" row (`sidebar-more`, by `DmShortlist`); a channel lists
## its members (`sidebar-members`, by `ChannelRoster`), each naming whether
## a human or an agent (`data-kind`), which app/sidebar-popups.js shows in
## the channel's card;
## app/sidebar-popups.js says when a DM's person joined (`data-joined`, not
## drawn yet). The top bar's notice line (`notice-strip`), on a
## conversation with a sidebar and on Recent, is where app/chrome.js shows
## that someone has come online, or has written in one of the viewer's
## places. An invite's link or code
## (`invite-code`) is its shown text alone: app/panel.js gives each one the
## button that copies it.
import Html
import Script
import SidebarOrder
import TrustedHtml

PageContract :: [].{

	## A class a page uses: a closed set, so a class is never data.
	Class : [
		Author,
		Body,
		BrowsePanes,
		CodeExpiry,
		CodeStatus,
		Compose,
		Current,
		EditedMarkdown,
		EditedNote,
		EditedOriginal,
		Empty,
		Help,
		InviteCode,
		InviteMade,
		InviteRow,
		Layout,
		Message,
		MessageReference,
		Messages,
		NoticeStrip,
		Panel,
		Problem,
		ReactionChip,
		ReactionEmoji,
		ReactionStrip,
		RecentAgo,
		RecentAvatar,
		RecentBar,
		RecentBody,
		RecentContext,
		RecentDot,
		RecentLead,
		RecentList,
		RecentMark,
		RecentPlace,
		RecentPreview,
		RecentTile,
		RecentTitle,
		RecentTop,
		RecentTopic,
		RecentWhere,
		RecentWho,
		Sidebar,
		SidebarMemberName,
		SidebarMembers,
		SidebarMemberWords,
		SidebarMore,
		SidebarMoreName,
		SidebarNewTopic,
		SidebarPlace,
		SidebarPlaceName,
		SidebarSection,
		SidebarSectionName,
		SidebarToggle,
		SidebarTopics,
		SignInCode,
		SignOut,
		TopBar,
		TopLinks,
		TopTitle,
		TopicLink,
		TopUser,
		Viewer,
		You,
	]

	## The class attribute for `class`, its one spelling.
	class : PageContract.Class -> Html.Attribute
	class = |chosen| Class(token(class_name(chosen)))

	## A class of a colored code block's spans: what roc-syntax-color writes
	## (`Markdown`'s code hook), not the Roc, and what app/feed.js colors.
	SyntaxClass : [Comment, String, Number, Keyword, Name, Type]

	## Every `SyntaxClass`, in the order roc-syntax-color names them.
	syntax_classes : List(PageContract.SyntaxClass)
	syntax_classes = [Comment, String, Number, Keyword, Name, Type]

	## The class roc-syntax-color spells for `chosen`.
	syntax_class_name : PageContract.SyntaxClass -> Str
	syntax_class_name = |chosen|
		match chosen {
			Comment => "syn-comment"
			String => "syn-string"
			Number => "syn-number"
			Keyword => "syn-keyword"
			Name => "syn-name"
			Type => "syn-type"
		}

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
		Section(Html.SitePath),
		React(Html.SitePath),
		Raw(Html.SitePath),
		Download(Html.SitePath),
		Reactors(Html.Token),
		Person(Html.Token),
		Presence([Online, Offline]),
		Opening(SidebarOrder.Opening),
		Group([Channels, Dms]),
		Joined(Html.Token),
		Kind([Human, Agent]),
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
			Section(path) => Data(token("section"), Path(path))
			React(path) => Data(token("react"), Path(path))
			Raw(path) => Data(token("raw"), Path(path))
			Download(path) => Data(token("download"), Path(path))
			Reactors(ids) => Data(token("reactors"), Token(ids))
			Person(id) => Data(token("person"), Token(id))
			Presence(Online) => Data(token("presence"), Token(token("online")))
			Presence(Offline) => Data(token("presence"), Token(token("offline")))
			Opening(AlwaysOpen) => Data(token("opening"), Token(token("always")))
			Opening(Collapsed) => Data(token("opening"), Token(token("collapsed")))
			Group(Channels) => Data(token("group"), Token(token("channels")))
			Group(Dms) => Data(token("group"), Token(token("dms")))
			Joined(seconds) => Data(token("joined"), Token(seconds))
			Kind(Human) => Data(token("kind"), Token(token("human")))
			Kind(Agent) => Data(token("kind"), Token(token("agent")))
		}

	## An element `attributes` alone opens, as a test reads it.
	empty_paragraph : List(Html.Attribute) -> List(U8)
	empty_paragraph = |attributes|
		Html.element({ name: P, attributes, inner: TrustedHtml.join([]) }).to_utf8()
}

class_name : PageContract.Class -> Str
class_name = |chosen|
	match chosen {
		Author => "author"
		Body => "body"
		BrowsePanes => "browse-panes"
		CodeExpiry => "code-expiry"
		CodeStatus => "code-status"
		Compose => "compose"
		Current => "current"
		EditedMarkdown => "edited-markdown"
		EditedNote => "edited-note"
		EditedOriginal => "edited-original"
		Empty => "empty"
		Help => "help"
		InviteCode => "invite-code"
		InviteMade => "invite-made"
		InviteRow => "invite-row"
		SignInCode => "sign-in-code"
		SignOut => "sign-out"
		Layout => "layout"
		Message => "message"
		MessageReference => "message-reference"
		Messages => "messages"
		NoticeStrip => "notice-strip"
		Panel => "panel"
		Problem => "problem"
		ReactionChip => "reaction-chip"
		ReactionEmoji => "reaction-emoji"
		ReactionStrip => "reaction-strip"
		RecentAgo => "recent-ago"
		RecentAvatar => "recent-avatar"
		RecentBar => "recent-bar"
		RecentBody => "recent-body"
		RecentContext => "recent-context"
		RecentDot => "recent-dot"
		RecentLead => "recent-lead"
		RecentList => "recent-list"
		RecentMark => "recent-mark"
		RecentPlace => "recent-place"
		RecentPreview => "recent-preview"
		RecentTile => "recent-tile"
		RecentTitle => "recent-title"
		RecentTop => "recent-top"
		RecentTopic => "recent-topic"
		RecentWhere => "recent-where"
		RecentWho => "recent-who"
		Sidebar => "sidebar"
		SidebarMemberName => "sidebar-member-name"
		SidebarMembers => "sidebar-members"
		SidebarMemberWords => "sidebar-member-words"
		SidebarMore => "sidebar-more"
		SidebarMoreName => "sidebar-more-name"
		SidebarNewTopic => "sidebar-new-topic"
		SidebarPlace => "sidebar-place"
		SidebarPlaceName => "sidebar-place-name"
		SidebarSection => "sidebar-section"
		SidebarSectionName => "sidebar-section-name"
		SidebarToggle => "sidebar-toggle"
		SidebarTopics => "sidebar-topics"
		TopBar => "top-bar"
		TopLinks => "top-links"
		TopTitle => "top-title"
		TopicLink => "topic-link"
		TopUser => "top-user"
		Viewer => "viewer"
		You => "you"
	}

## The token `text` spells, for a name this module writes: one that isn't
## is this module's bug. (`PageKit.token` is the pages' own; this module
## stands below `PageKit`, which uses its classes, so it keeps its own.)
token : Str -> Html.Token
token = |text|
	Html.Token.from_str(text)
		?? crash "PageContract.token: \"${text}\" is a name this module writes, and not a token"

# ── tests
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
expect is_found_by(Script.Emoji.bytes(), Compose) and !is_found_by(Script.Emoji.bytes(), Help)
expect
	[
		Panel,
		InviteCode,
		SignInCode,
		Problem,
		Help,
		BrowsePanes,
		InviteMade,
		InviteRow,
		TopicLink,
		You,
	].all(|chosen| is_found_by(Script.Panel.bytes(), chosen))
expect
	[CodeExpiry, CodeStatus, SignInCode].all(|chosen| is_found_by(Script.Devices.bytes(), chosen))
expect
	[
		Sidebar,
		SidebarToggle,
		SidebarPlace,
		SidebarPlaceName,
		SidebarTopics,
		SidebarNewTopic,
		SidebarSection,
		SidebarSectionName,
		SidebarMore,
		SidebarMoreName,
		SidebarMembers,
		Current,
		TopBar,
	].all(|chosen| is_found_by(Script.Sidebar.bytes(), chosen))
expect
	[Problem, SidebarMemberName, SidebarMemberWords].all(|chosen| is_found_by(Script.SidebarPopups.bytes(), chosen))
expect
	is_found_by(Script.Chrome.bytes(), NoticeStrip)
		and !is_found_by(Script.Sidebar.bytes(), NoticeStrip)
expect
	[Messages, Compose, Message, Panel].all(|chosen| !is_found_by(Script.Sidebar.bytes(), chosen))
expect
	[Sidebar, SidebarPlace, Current].all(
		|chosen| !is_found_by(
			Script.Compose.bytes(),
			chosen,
		) and !is_found_by(Script.Feed.bytes(), chosen),
	)
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
expect
	is_read_by(Script.Sidebar.bytes(), "data-section")
		and is_read_by(Script.Sidebar.bytes(), "data-person")
		and is_read_by(Script.Sidebar.bytes(), "data-presence")
		and is_read_by(Script.Sidebar.bytes(), "data-opening")
		and is_read_by(Script.Sidebar.bytes(), "data-group")
		and is_read_by(Script.SidebarPopups.bytes(), "data-joined")
		and is_read_by(Script.SidebarPopups.bytes(), "data-presence")
		and is_read_by(Script.SidebarPopups.bytes(), "data-kind")
		and !is_read_by(Script.Feed.bytes(), "data-opening")
		and !is_read_by(Script.Feed.bytes(), "data-person")
		and !is_read_by(Script.Compose.bytes(), "data-section")
		and !is_read_by(Script.Feed.bytes(), "data-section")
# A colored code block's classes are styled by app/feed.js, a rule each,
# and by no other script.
expect {
	feed = Str.from_utf8_lossy(Script.Feed.bytes())
	compose = Str.from_utf8_lossy(Script.Compose.bytes())
	PageContract.syntax_classes.all(
		|chosen| {
			name = PageContract.syntax_class_name(chosen)
			feed.contains(".${name} {") and !compose.contains(name)
		},
	)
}
# The classes only styled are styled by the script that owns them.
expect [
	TopTitle,
	TopLinks,
	Viewer,
].all(|chosen| Str.from_utf8_lossy(Script.Chrome.bytes()).contains(".${class_name(chosen)} {"))
# app/actions.js finds each message's reactions by their classes, styles
# its reactions' strip and an edited message's parts, and reads where to
# react, where to read a message's markdown, where the download is, and
# who reacted; no other
# conversation script does.
expect
	[
		Messages,
		Message,
		ReactionChip,
		ReactionEmoji,
	].all(|chosen| is_found_by(Script.Actions.bytes(), chosen))
expect
	[ReactionStrip, EditedNote, EditedOriginal, EditedMarkdown].all(
		|chosen| Str.from_utf8_lossy(Script.Actions.bytes()).contains("'.${class_name(chosen)} "),
	)
expect
	[ReactionStrip, ReactionChip, ReactionEmoji, EditedNote, EditedOriginal, EditedMarkdown].all(
		|chosen| !is_found_by(Script.Feed.bytes(), chosen) and !is_found_by(
			Script.Compose.bytes(),
			chosen,
		),
	)
expect
	[
		"data-react",
		"data-raw",
		"data-download",
		"data-reactors",
		"data-viewer",
	].all(|name| is_read_by(Script.Actions.bytes(), name))
expect
	["data-react", "data-raw", "data-download", "data-reactors"].all(
		|name| !is_read_by(Script.Feed.bytes(), name) and !is_read_by(Script.Compose.bytes(), name),
	)
# app/actions.js follows a reference in a message's markdown, roc-markdown's
# `a.msg-ref`, to the message whose header's reference is its label.
expect {
	script = Str.from_utf8_lossy(Script.Actions.bytes())
	script.contains("'a.msg-ref'")
		and script.contains("'.message header .${class_name(MessageReference)}'")
}
# app/recent.js finds Recent's list, its tiles, their bars and their times
# by their classes, and reads the list's stream; no conversation script
# finds them.
expect is_read_by(
	Script.Recent.bytes(),
	"data-stream",
) and is_found_by(Script.Recent.bytes(), Empty)
expect
	[RecentList, RecentTile, RecentBar, RecentAgo].all(
		|chosen| is_found_by(
			Script.Recent.bytes(),
			chosen,
		) and !is_found_by(Script.Feed.bytes(), chosen),
	)

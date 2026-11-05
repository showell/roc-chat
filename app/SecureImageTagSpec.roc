## Tests of `SecureImageTag` and `Markdown`, through the renderer. A
## message shows an image only from its own conversation's uploads: the
## exact URL path of an uploaded image of that conversation. Every other
## source, another conversation's uploads among them, comes out as the
## frozen rendering that is no image.
import ChannelName
import ConversationKey
import Directory
import Markdown
import Sample
import SecureImageTag
import TrustedHtml
import UnvalidatedString

SecureImageTagSpec :: [].{}

## The sample directory, with the channel `plans-room` created by Steve.
with_room : Directory
with_room = {
	name = ChannelName.from_str("plans-room") ?? crash "SecureImageTagSpec: a channel's name"
	(
		Sample.directory.create_channel({
			by: Sample.admin,
			name,
		}) ?? crash "SecureImageTagSpec: the name is free"
	).directory
}

## The conversation at the URL path `path` in `with_room`.
key_at : Str -> ConversationKey
key_at = |path|
	ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "SecureImageTagSpec: a path is UTF-8",
		directory: with_room,
	}).map_ok(|found| found.key) ?? crash "SecureImageTagSpec: a test's path is a conversation's"

## `plans` in Steve's own DM.
plans : ConversationKey
plans = key_at("/chat/dm/1_1/plans")

## A name of an uploaded image's shape.
image_name : Str
image_name = "${"0a".repeat(16)}.png"

## `markdown` rendered as a message of `plans`, as a test reads it.
message_html : Str -> Str
message_html = |markdown| Str.from_utf8(
	Markdown.render(
		markdown,
		plans,
	).to_utf8(),
) ?? crash "SecureImageTagSpec: a render is UTF-8"

# The rule: exactly the conversation's own uploaded image's path, each kind.
expect
	[
		"/chat/dm/1_1/plans/uploads/${image_name}",
		"/chat/dm/1_1/plans/uploads/${"f".repeat(32)}.jpg",
		"/chat/dm/1_1/plans/uploads/${"9".repeat(32)}.gif",
		"/chat/dm/1_1/plans/uploads/${"1".repeat(32)}.webp",
	].all(|source| SecureImageTag.is_conversation_upload(plans, source.to_utf8()))
expect SecureImageTag.is_conversation_upload(
	key_at("/chat/channel/plans-room/talk"),
	"/chat/channel/plans-room/talk/uploads/${image_name}".to_utf8(),
)
# Every other source: another conversation's uploads, in another topic,
# place or kind of place; a name of another shape; another path of this
# conversation; and the sources no conversation ever has.
expect
	[
		"/chat/dm/1_1/other/uploads/${image_name}",
		"/chat/dm/1_2/plans/uploads/${image_name}",
		"/chat/channel/plans-room/plans/uploads/${image_name}",
		"/chat/dm/1_1/plans/uploads/cat.png",
		"/chat/dm/1_1/plans/uploads/${"0A".repeat(16)}.png",
		"/chat/dm/1_1/plans/uploads/${image_name}.png",
		"/chat/dm/1_1/plans/uploads/x/${image_name}",
		"/chat/dm/1_1/plans/upload/${image_name}",
		"/chat/dm/1_1/plans/${image_name}",
		"/chat/dm/1_1/plans/stream",
		"/chat/dm/1_1/plans/uploads/",
		"/chat/dm/1_1/plans/../plans/uploads/${image_name}",
		"chat/dm/1_1/plans/uploads/${image_name}",
		"//chat/dm/1_1/plans/uploads/${image_name}",
		"http://localhost:9611/chat/dm/1_1/plans/uploads/${image_name}",
		"/chat/dm/1_1/plans/uploads/${image_name}?x=1",
		"/chat/dm/1_1/plans/uploads/${image_name}#x",
		"a.png",
		"/user_uploads/a.png",
		"https://evil.example/a.png",
		"data:image/png;base64,AAAA",
		"javascript:alert(1)",
		image_name,
		"",
	].all(|source| !SecureImageTag.is_conversation_upload(plans, source.to_utf8()))
expect !SecureImageTag.is_conversation_upload(
	plans,
	"/chat/dm/1_1/plans/uploads/".to_utf8().concat([0xFF]),
)

# Through the renderer: the conversation's own image is an image, by
# markdown or by an `<img>` tag, as the compose box inserts one.
expect message_html("![cat](/chat/dm/1_1/plans/uploads/${image_name})") == "<p><img src=\"/chat/dm/1_1/plans/uploads/${image_name}\" alt=\"cat\"></p>\n"
expect message_html("<img src=\"/chat/dm/1_1/plans/uploads/${image_name}\" alt=\"cat.png\">") == "<img src=\"/chat/dm/1_1/plans/uploads/${image_name}\" alt=\"cat.png\">"

# Another conversation's image is its link, or text.
expect message_html("![x](/chat/dm/1_2/plans/uploads/${image_name})") == "<p><a href=\"/chat/dm/1_2/plans/uploads/${image_name}\">x</a></p>\n"
expect message_html("<img src=\"/chat/dm/1_1/other/uploads/${image_name}\">") == "&lt;img src=&quot;/chat/dm/1_1/other/uploads/${image_name}&quot;&gt;"
# `![alt](src)`: a relative, an absolute, another origin's, a `data:` and
# a `javascript:` source. Each is a plain link, or text, never an image.
expect message_html("![x](a.png)") == "<p><a href=\"a.png\">x</a></p>\n"
expect message_html("![x](/user_uploads/a.png)") == "<p><a href=\"/user_uploads/a.png\">x</a></p>\n"
expect message_html("![x](https://evil.example/a.png)") == "<p><a href=\"https://evil.example/a.png\" target=\"_blank\" rel=\"noopener\">x</a></p>\n"
expect message_html("![x](data:image/png;base64,AAAA)") == "<p><a href=\"data:image/png;base64,AAAA\">x</a></p>\n"
expect message_html("![x](javascript:alert(1))") == "<p>![x](javascript:alert(1))</p>\n"
# An `<img>` tag, the same four sources: each is text, escaped.
expect message_html("<img src=\"a.png\">") == "&lt;img src=&quot;a.png&quot;&gt;"
expect message_html("<img src=\"/user_uploads/a.png\">") == "&lt;img src=&quot;/user_uploads/a.png&quot;&gt;"
expect message_html("<img src=\"data:image/png;base64,AAAA\">") == "&lt;img src=&quot;data:image/png;base64,AAAA&quot;&gt;"
expect message_html("<img src=\"javascript:alert(1)\">") == "&lt;img src=&quot;javascript:alert(1)&quot;&gt;"
# The renderer's own markup kept, the text in it escaped; a `javascript:`
# link is text.
expect message_html("**hi** <b>") == "<p><strong>hi</strong> &lt;b&gt;</p>\n"
expect message_html("a & <b>") == "<p>a &amp; &lt;b&gt;</p>\n"
expect message_html("[x](javascript:alert(1))") == "<p>[x](javascript:alert(1))</p>\n"
# Rendered markup is trusted as it is: joined, its entities stay single.
expect
	TrustedHtml.join([
		TrustedHtml.dangerously_trust("&amp;"),
		Markdown.render("a & <b>", plans),
	]).to_utf8()
		== "&amp;<p>a &amp; &lt;b&gt;</p>\n".to_utf8()

## A conversation key names one conversation: its place and its topic, the
## pair that is unique (a topic is unique only within its place). The type
## is opaque, so its ways in are `of`, from a place that exists, and
## `from_url_path`, which finds that place in a directory.
##
## This module is the one home of a conversation's URLs and its folder.
## Both are spelled from the same parts (`parts`), so a URL names its
## folder and no second spelling can drift:
##
##     /chat/channel/<channel>/<topic>     chat/channel/<channel>/<topic>/
##     /chat/dm/<pair>/<topic>             chat/dm/<pair>/<topic>/
##
## A place's own URL and folder are those without the topic (`place_parts`):
## its folder holds its conversations' folders, and a new topic's form posts
## to its URL. `browse_path` is the page that lists the places.
##
## A channel's folder holds its conversations' folders
## (`channel_folder_parts`), and its members file sits beside it
## (`Channels`).
##
## Each thing a conversation serves (`Resource`) is at its page's URL and
## a suffix: its stream at `/stream`, the send of its page's script at
## `/send`, an image's upload at `/upload`, an uploaded image at
## `/uploads/<name>`, and its transcript as plain text at `/raw`.
## `url_path` writes each, and `from_url_path` reads each back. `FileSystem`
## keeps an uploaded image in the conversation's folder, as `uploads/<name>`.
import ChannelName
import Directory
import Place
import Topic
import UnvalidatedString
import UploadedImage
import UserPair

ConversationKey :: { place : Place, topic : Topic }.{

	## What a conversation's URL names: its page, its stream, where its
	## page's script sends a message, where an image is uploaded to it, or
	## one of its uploaded images.
	Resource : [
		Page,
		Stream,
		Send,
		Upload,
		UploadedImage(UploadedImage),
		Raw,
	]

	## The conversation under `topic` in `place`.
	of : { place : Place, topic : Topic } -> ConversationKey
	of = |key| ConversationKey.(key)

	## Its place.
	place : ConversationKey -> Place
	place = |ConversationKey.(key)| key.place

	## Its topic.
	topic : ConversationKey -> Topic
	topic = |ConversationKey.(key)| key.topic

	## The parts of the folder of the channel `name`, which holds its
	## conversations' folders: `chat`, `channel`, and the name.
	channel_folder_parts : ChannelName -> List(Str)
	channel_folder_parts = |name| ConversationKey.channels_folder_parts.append(name.to_str())

	## The parts of the folder that holds every channel's folder: `chat`
	## and `channel`.
	channels_folder_parts : List(Str)
	channels_folder_parts = ["chat", "channel"]

	## The parts a place's URL and its folder both spell: `chat`, the kind of
	## place, and the place's name.
	place_parts : Place -> List(Str)
	place_parts = |found|
		match found.which() {
			Channel(name) => ConversationKey.channel_folder_parts(name)
			Dm(pair) =>
				["chat", "dm", pair.to_str()]
		}

	## The parts its URL and its folder both spell: its place's, then the
	## topic.
	parts : ConversationKey -> List(Str)
	parts = |ConversationKey.(key)|
		ConversationKey.place_parts(key.place).append(key.topic.to_str())

	## The URL path of a place.
	place_url_path : Place -> Str
	place_url_path = |found| "/${Str.join_with(ConversationKey.place_parts(found), "/")}"

	## The URL path of Browse.
	browse_path : Str
	browse_path = "/chat"

	## The URL path of the conversation's `resource`: `/`, its parts, then
	## the resource's own.
	url_path : ConversationKey, ConversationKey.Resource -> Str
	url_path = |
		key,
		resource,
	| "/${Str.join_with(key.parts().concat(resource_parts(resource)), "/")}"

	## The conversation a URL's path names, its place found in `directory`,
	## and which of its resources the path names. Unless the path is no
	## conversation's (`NotAConversationPath`), a part is no name
	## (`BadName`), or the directory holds no such place (`NoSuchChannel`,
	## `NoSuchHuman`, as `Directory.place` answers).
	from_url_path : { path : UnvalidatedString, directory : Directory } -> Try(
		{ key : ConversationKey, resource : ConversationKey.Resource },
		[NotAConversationPath, BadName, NoSuchChannel, NoSuchHuman],
	)
	from_url_path = |{ path, directory }| {
		path_parts = path.url_path_parts() ? |NotAPath| NotAConversationPath
		match path_parts {
			[chat, kind, name, topic_part, ..] if chat.is_exactly("chat") => {
				resource = resource_of_suffix(path_parts.drop_first(4))?
				named_place = place_named({ kind, name })?
				found_place = directory.place(named_place)?
				found_topic = topic_part.topic() ? |_| BadName
				Ok({ key: ConversationKey.({ place: found_place, topic: found_topic }), resource })
			}
			_ => Err(NotAConversationPath)
		}
	}

	## The place a URL's path names, found in `directory`; or why not, as
	## `from_url_path` says it.
	place_from_url_path : { path : UnvalidatedString, directory : Directory } -> Try(
		Place,
		[NotAConversationPath, BadName, NoSuchChannel, NoSuchHuman],
	)
	place_from_url_path = |{ path, directory }|
		match path.url_path_parts() {
			Ok([chat, kind, name]) if chat.is_exactly("chat") => {
				named_place = place_named({ kind, name })?
				directory.place(named_place)
			}
			_ => Err(NotAConversationPath)
		}

	is_eq : _
	to_hash : _
}

## The parts a resource's URL path adds after its conversation's.
resource_parts : ConversationKey.Resource -> List(Str)
resource_parts = |resource|
	match resource {
		Page => []
		Stream => ["stream"]
		Send => ["send"]
		Upload => ["upload"]
		UploadedImage(image) => ["uploads", image.name()]
		Raw => ["raw"]
	}

## The resource whose parts are `suffix`, the parts of a URL's path after
## its conversation's, as `resource_parts` writes them.
resource_of_suffix : List(UnvalidatedString) -> Try(
	ConversationKey.Resource,
	[NotAConversationPath],
)
resource_of_suffix = |suffix|
	match suffix {
		[] => Ok(Page)
		[last] if last.is_exactly("stream") => Ok(Stream)
		[last] if last.is_exactly("send") => Ok(Send)
		[last] if last.is_exactly("upload") => Ok(Upload)
		[last] if last.is_exactly("raw") => Ok(Raw)
		[uploads, image_name] if uploads.is_exactly("uploads") =>
			match image_name.uploaded_image() {
				Ok(image) => Ok(UploadedImage(image))
				Err(NotAnUploadName) => Err(NotAConversationPath)
			}
		_ => Err(NotAConversationPath)
	}

## The place a URL's `kind` (`channel` or `dm`) and `name` spell, still to
## be found in a directory.
place_named : { kind : UnvalidatedString, name : UnvalidatedString } -> Try(
	[Channel(ChannelName), Dm(UserPair)],
	[NotAConversationPath, BadName],
)
place_named = |{ kind, name }|
	if kind.is_exactly("channel") {
		name.channel_name().map_ok(|channel| Channel(channel)).map_err(|_| BadName)
	} else if kind.is_exactly("dm") {
		name.user_pair().map_ok(|pair| Dm(pair)).map_err(|_| BadName)
	} else {
		Err(NotAConversationPath)
	}

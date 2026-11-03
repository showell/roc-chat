## **WHICH CONVERSATION**: its place and its topic, the pair that names one
## conversation (a topic is unique only within its place). Opaque, so its
## doors are the only ways in: `of`, from a place that exists, and
## `from_url_path`, which finds that place in a directory.
##
## **THE LAYOUT, ITS ONE HOME**: a conversation's URL and its folder on disk
## are the same parts (`parts`), so a URL names its folder and no second
## spelling can drift:
##
##     /chat/channel/<channel>/<topic>     chat/channel/<channel>/<topic>/
##     /chat/dm/<pair>/<topic>             chat/dm/<pair>/<topic>/
##
## `from_url_path` reads those parts back, here beside the writer. A
## conversation's stream is at its page's URL and `/stream`, which
## `from_stream_url_path` reads back.
##
## An image is uploaded to a conversation by a POST to its page's URL and
## `/upload` (`from_upload_url_path`), and is served at its page's URL,
## `/uploads/` and the image's name (`from_uploaded_image_url_path`).
## `FileSystem` keeps it in the conversation's folder, as `uploads/<name>`.
import Directory
import Dm
import Place
import Topic
import UnvalidatedString
import UploadedImage

ConversationKey :: { place : Place, topic : Topic }.{

	## The conversation under `topic` in `place`.
	of : { place : Place, topic : Topic } -> ConversationKey
	of = |key| ConversationKey.(key)

	## Its place.
	place : ConversationKey -> Place
	place = |ConversationKey.(key)| key.place

	## Its topic.
	topic : ConversationKey -> Topic
	topic = |ConversationKey.(key)| key.topic

	## **ITS PARTS, AS ITS URL AND ITS FOLDER BOTH SPELL THEM**: `chat`,
	## the kind of place, the place's name, the topic.
	parts : ConversationKey -> List(Str)
	parts = |ConversationKey.(key)|
		match key.place.which() {
			Channel(name) =>
				[
					"chat",
					"channel",
					name.to_str(),
					key.topic.to_str(),
				]
			Dm(pair) =>
				[
					"chat",
					"dm",
					pair.to_str(),
					key.topic.to_str(),
				]
		}

	## Its page's URL path: `/` and its parts.
	url_path : ConversationKey -> Str
	url_path = |key| "/${Str.join_with(key.parts(), "/")}"

	## Its stream's URL path: its page's, then `/stream`.
	stream_url_path : ConversationKey -> Str
	stream_url_path = |key| "${key.url_path()}/${stream_part}"

	## **THE CONVERSATION A URL'S PATH NAMES**, its place found in
	## `directory`; unless the path is not a conversation's
	## (`NotAConversationPath`), a part is no name (`BadName`), no such
	## channel is there (`NoSuchChannel`), or a DM's member is no human
	## there (`NoSuchHuman`).
	from_url_path : { path : UnvalidatedString, directory : Directory } -> Try(
		ConversationKey,
		[
			NotAConversationPath,
			BadName,
			NoSuchChannel,
			NoSuchHuman,
		],
	)
	from_url_path = |{ path, directory }|
		match path.url_path_parts() {
			Ok(
				[
					chat,
					kind,
					name,
					topic_part,
				],
			) if chat.is_exactly("chat") =>
				key_named({
					kind,
					name,
					topic_part,
					directory,
				})
			_ => Err(NotAConversationPath)
		}

	## **THE CONVERSATION WHOSE STREAM A URL'S PATH NAMES**, refused as
	## `from_url_path` refuses a page's.
	from_stream_url_path : { path : UnvalidatedString, directory : Directory } -> Try(
		ConversationKey,
		[
			NotAConversationPath,
			BadName,
			NoSuchChannel,
			NoSuchHuman,
		],
	)
	from_stream_url_path = |{ path, directory }|
		key_before_last_part({
			path,
			last: stream_part,
			directory,
		})

	## The URL path an image is uploaded to: its page's, then `/upload`.
	upload_url_path : ConversationKey -> Str
	upload_url_path = |key| "${key.url_path()}/${upload_part}"

	## The conversation a URL's path uploads to, refused as
	## `from_url_path` refuses a page's.
	from_upload_url_path : { path : UnvalidatedString, directory : Directory } -> Try(
		ConversationKey,
		[
			NotAConversationPath,
			BadName,
			NoSuchChannel,
			NoSuchHuman,
		],
	)
	from_upload_url_path = |{ path, directory }|
		key_before_last_part({
			path,
			last: upload_part,
			directory,
		})

	## The URL path an uploaded image is served at: its page's, then
	## `/uploads/` and the image's name.
	uploaded_image_url_path : ConversationKey, UploadedImage -> Str
	uploaded_image_url_path = |key, image| "${key.url_path()}/${uploads_part}/${image.name()}"

	## The conversation and the uploaded image a URL's path names, refused
	## as `from_url_path` refuses a page's, and as `NotAConversationPath`
	## when the last part is no uploaded image's name.
	from_uploaded_image_url_path : { path : UnvalidatedString, directory : Directory } -> Try(
		{ key : ConversationKey, image : UploadedImage },
		[
			NotAConversationPath,
			BadName,
			NoSuchChannel,
			NoSuchHuman,
		],
	)
	from_uploaded_image_url_path = |{ path, directory }|
		match path.url_path_parts() {
			Ok(
				[
					chat,
					kind,
					name,
					topic_part,
					uploads,
					image_name,
				],
			) if chat.is_exactly("chat") and uploads.is_exactly(uploads_part) => {
				image = image_name.uploaded_image() ? |NotAnUploadName| NotAConversationPath
				key = key_named({
					kind,
					name,
					topic_part,
					directory,
				})?
				Ok({ key, image })
			}
			_ => Err(NotAConversationPath)
		}

	is_eq : _
	to_hash : _
}

## The last part of a stream's URL path.
stream_part : Str
stream_part = "stream"

## The last part of an upload's URL path.
upload_part : Str
upload_part = "upload"

## The part before an uploaded image's name in its URL path.
uploads_part : Str
uploads_part = "uploads"

## The conversation whose page's URL path, then `/` and `last`, is `path`.
key_before_last_part : {
	path : UnvalidatedString,
	last : Str,
	directory : Directory,
} -> Try(
	ConversationKey,
	[
		NotAConversationPath,
		BadName,
		NoSuchChannel,
		NoSuchHuman,
	],
)
key_before_last_part = |
	{
		path,
		last,
		directory,
	},
|
	match path.url_path_parts() {
		Ok(
			[
				chat,
				kind,
				name,
				topic_part,
				last_part,
			],
		) if chat.is_exactly("chat") and last_part.is_exactly(last) =>
			key_named({
				kind,
				name,
				topic_part,
				directory,
			})
		_ => Err(NotAConversationPath)
	}

## The conversation under `topic_part` in the place of `kind` that `name`
## names, if `directory` holds it.
key_named : {
	kind : UnvalidatedString,
	name : UnvalidatedString,
	topic_part : UnvalidatedString,
	directory : Directory,
} -> Try(
	ConversationKey,
	[
		NotAConversationPath,
		BadName,
		NoSuchChannel,
		NoSuchHuman,
	],
)
key_named = |
	{
		kind,
		name,
		topic_part,
		directory,
	},
| {
	found = place_named({
		kind,
		name,
		directory,
	})?
	named = topic_part.topic() ? |_| BadName
	Ok(ConversationKey.({ place: found, topic: named }))
}

## The place of `kind` (`channel` or `dm`) that `name` names, if
## `directory` holds it.
place_named : {
	kind : UnvalidatedString,
	name : UnvalidatedString,
	directory : Directory,
} -> Try(
	Place,
	[
		NotAConversationPath,
		BadName,
		NoSuchChannel,
		NoSuchHuman,
	],
)
place_named = |
	{
		kind,
		name,
		directory,
	},
|
	if (kind.is_exactly("channel"))
		channel_place({ name, directory })
	else if (kind.is_exactly("dm"))
		dm_place({ name, directory })
	else
		Err(NotAConversationPath)

## The channel `name` names, as a place, if `directory` holds it.
channel_place : { name : UnvalidatedString, directory : Directory } -> Try(Place, [BadName, NoSuchChannel])
channel_place = |{ name, directory }| {
	checked = name.channel_name() ? |_| BadName
	channel = directory.channels().channel(checked)?
	Ok(Place.channel(channel))
}

## The DM `name` spells, as a place, if both its members are humans in
## `directory`.
dm_place : { name : UnvalidatedString, directory : Directory } -> Try(Place, [BadName, NoSuchHuman])
dm_place = |{ name, directory }| {
	pair = name.user_pair() ? |_| BadName
	humans = pair.members().map_try(
		|id|
			match directory.users().user(id) {
				Ok(user) => user.as_human().map_err(|_| NoSuchHuman)
				Err(NoSuchUser) => Err(NoSuchHuman)
			},
	)?
	match humans {
		[alone] => Ok(Place.dm(Dm.between({ a: alone, b: alone })))
		[a, b] => Ok(Place.dm(Dm.between({ a, b })))
		_ => crash "ConversationKey.dm_place: a pair has one member or two"
	}
}

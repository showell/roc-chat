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
## `from_url_path` reads those parts back, here beside the writer.
import Directory
import Dm
import Place
import Topic
import UnvalidatedString

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
			) if chat.is_exactly("chat") => {
				found = place_named({
					kind,
					name,
					directory,
				})?
				named = topic_part.topic() ? |_| BadName
				Ok(ConversationKey.({ place: found, topic: named }))
			}
			_ => Err(NotAConversationPath)
		}

	is_eq : _
	to_hash : _
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

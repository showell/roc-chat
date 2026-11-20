## This module is Recent's live stream, as Gopher Chat's
## `/chat/recent/stream` was: each human's Recent page holds one stream on
## a bus key of its own (`bus_key`), live only, since the page itself is the
## backlog. Each message added to a conversation is sent, as its tile, to
## every human who may read it (`publish!`), the author included, each
## seeing it as their own page would ("You" for their own), and the page
## puts the tile at the top in place of the conversation's old one
## (app/recent.js). The viewer's own DM is left out, as Recent leaves it
## out.
import pf.Host
import pf.Http
import HttpAnswer
import ConversationKey
import DateTime
import Sample
import UnvalidatedString
import RecentFeed
import Presence
import ServerSentEvent
import Transcript
import UserId
import Users

RecentStream :: [].{

	## The bus key of `viewer`'s Recent pages.
	bus_key : UserId -> List(U8)
	bus_key = |viewer| "/recent/${viewer.to_str()}".to_utf8()

	## Who holds a Recent page's stream: its viewer, as their conversation
	## pages' streams are held, so the host's cap on one holder's streams
	## counts them together.
	holder : UserId -> List(U8)
	holder = |viewer| viewer.to_str().to_utf8()

	## `viewer`'s Recent stream: live only, since the page is the backlog;
	## each tile `publish!` sends them after, and what is sent to the viewer
	## alone (`Presence.viewer_stream_key`), the notices above the page among
	## it, as Gopher Chat's Recent page heard its notify stream.
	response : UserId -> Http.Response
	response = |viewer|
		HttpAnswer.stream({
			keys: [RecentStream.bus_key(viewer), Presence.viewer_stream_key(viewer)],
			holder: RecentStream.holder(viewer),
			backlog: [],
		})

	## The event that carries `tile`: `tile`, its data the tile's HTML.
	frame : RecentFeed.Tile -> List(U8)
	frame = |tile| ServerSentEvent.named_event({ name: "tile", html: RecentFeed.tile_html(tile) })

	## The tile `reader` sees for the conversation `key` whose last message is
	## now `latest`, its users `users`; or `NoTile` for no human, or for the
	## reader's own DM.
	reader_tile : {
		key : ConversationKey,
		reader : UserId,
		users : Users,
		latest : Transcript.LatestMessage,
	} -> [Tile(RecentFeed.Tile), NoTile]
	reader_tile = |{ key, reader, users, latest }|
		match users.user(reader) {
			Ok(user) => {
				label =
					match key.place().which() {
						Channel(name) => Ok("#${name.to_str()}")
						Dm(pair) =>
							match pair.members().drop_if(|member| member == reader) {
								[other, ..] =>
									users.user(other)
										.map_ok(|found| found.name().to_str())
										.map_err(|_| NoTile)
								[] => Err(NoTile)
							}
					}
				match (user.role(), label) {
					(Human, Ok(text)) => Tile(
						RecentFeed.tile({
							key,
							label: text,
							latest,
							viewer: user.name(),
						}),
					)
					_ => NoTile
				}
			}
			Err(NoSuchUser) => NoTile
		}

	## The conversation `key`'s new last message, `latest`, sent as its tile to
	## each of `readers`, everyone who may read it, found among `users`.
	publish! : {
		key : ConversationKey,
		readers : List(UserId),
		users : Users,
		latest : Transcript.LatestMessage,
	} => {}
	publish! = |{ key, readers, users, latest }|
		for reader in readers {
			match RecentStream.reader_tile({ key, reader, users, latest }) {
				Tile(tile) => Host.publish_bytes_to_streams_on_key!(
					RecentStream.bus_key(reader),
					RecentStream.frame(tile),
				)
				NoTile => {}
			}
		}
}

# ── tests
## The conversation at `path` in the sample directory with its default
## channel, `general`.
key_at : Str -> ConversationKey
key_at = |path|
	ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "RecentStream's tests: a path is UTF-8",
		directory: Sample.with_default_channel(Sample.directory),
	}).map_ok(|found| found.key) ?? crash "RecentStream's tests: a conversation's path"

## Steve's message saying "Hello", as a tile reads it.
hello : Transcript.LatestMessage
hello = {
	author: Sample.steve.author(),
	time: DateTime.from_str("2026-11-02T19:11:32Z") ?? crash "RecentStream's tests: a time",
	markdown: "Hello",
}

## What `reader`, the sample's user of that name, is sent for `hello` at
## `path`: the tile's label and who, or `none`.
sent_to : Str, Str -> Str
sent_to = |path, reader|
	match RecentStream.reader_tile({
		key: key_at(path),
		reader: Sample.user(reader).id(),
		users: Sample.directory.users(),
		latest: hello,
	}) {
		Tile(tile) => "${tile.label} ${tile.who}"
		NoTile => "none"
	}

# Each human reader sees their own tile: "You" for the author; a DM's label
# is the other human's name, a channel's its `#` name. An agent, and the
# reader's own DM, get none.
expect sent_to("/chat/dm/1_2/plans", "Steve") == "Apoorva You"
expect sent_to("/chat/dm/1_2/plans", "Apoorva") == "Steve Steve"
expect sent_to("/chat/channel/general/plans", "Apoorva") == "#general Steve"
expect sent_to("/chat/channel/general/plans", "CC") == "none"
expect sent_to("/chat/dm/1_1/plans", "Steve") == "none"
# Each viewer's key, and the tile's event.
expect RecentStream.bus_key(UserId.chat_owner) == "/recent/1".to_utf8()
expect RecentStream.holder(UserId.chat_owner) == "1".to_utf8()
expect {
	response = RecentStream.response(UserId.chat_owner)
	response.kind == Stream
		and response.body == []
		and response.stream_keys == ["/recent/1".to_utf8(), "/viewers/1".to_utf8()]
}
expect
	Str.from_utf8_lossy(
		RecentStream.frame({
			key: key_at("/chat/dm/1_2/plans"),
			label: "Apoorva",
			time: hello.time,
			who: "You",
			excerpt: "",
		}),
	).starts_with("event: tile\ndata: <a class=\"recent-tile\" href=\"/chat/dm/1_2/plans\">")

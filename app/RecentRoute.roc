## This module answers Recent's route (`Route` lists it). `RecentFeed`
## decides what is shown; this module reads, for each conversation of each
## place Recent lists, its transcript's last message
## (`Transcript.latest_message`, which reads the last record alone), and
## answers. A conversation with no messages yet has no tile.
##
## A Recent page holds a live stream (`RecentStream`), which this module
## opens too.
##
## Both routes are a human's, by their own session: a key is refused, as
## Browse refuses one.
import pf.Http
import Browse
import BrowseRoute
import Clock
import ConversationKey
import Directory
import FileFacts
import HttpAnswer
import Name
import PageKit
import PresenceNotices
import RecentFeed
import RecentStream
import SignedIn
import Transcript
import TranscriptFiles
import UserId

RecentRoute :: [].{

	## A GET of Recent, for `acting`.
	show! : { acting : SignedIn, directory : Directory } => Http.Response
	show! = |{ acting, directory }|
		match (acting.human_in_session(), Browse.places_for({ acting, directory })) {
			(Ok(reader), Ok(listed)) => {
				reader_id = reader.user().id()
				places = RecentFeed.places_without_own_dm({ listed, reader: reader_id })
				online_humans = PresenceNotices.load_online_humans!({
					humans: directory.users().to_list().keep_oks(|user| user.as_human()).map(|human| human.id()),
					now: Clock.read_clock!({}),
				})
				match load_tiles!({ places, reader: reader_id, viewer: reader.user().name(), online_humans }) {
					Ok(tiles) =>
						HttpAnswer.page(
							200,
							RecentFeed.page({
								viewer: acting,
								tiles: RecentFeed.newest_first(tiles),
							}),
						)
					Err(Unreadable(key)) => HttpAnswer.page(
						500,
						PageKit.notice({
							title: "Failed",
							text: "The last message of ${key.url_path(Page)} is not one this chat writes.",
						}),
					)
					Err(FileSystem(fault)) => HttpAnswer.page(
						500,
						PageKit.notice({ title: "Failed", text: FileFacts.fault_words(fault) }),
					)
				}
			}
			_ => key_refusal
		}

	## A GET of Recent's stream, for `acting`: live only, since the page is
	## the backlog; each tile `RecentStream.publish!` sends them after.
	open_stream : SignedIn -> Http.Response
	open_stream = |acting|
		match acting.human_in_session() {
			Ok(reader) => RecentStream.response(reader.user().id())
			Err(_) => key_refusal
		}

	## The last message of the conversation `key`, or `NoMessages` when it has
	## no transcript or an empty one; unless the read failed, or the last
	## message is not one the chat writes. A conversation's sidebar orders by
	## it too (`ConversationRoute`).
	load_latest_message! : ConversationKey => Try(
		[NoMessages, Latest(Transcript.LatestMessage)],
		[Unreadable(ConversationKey), FileSystem(FileFacts.Fault)],
	)
	load_latest_message! = |key|
		match TranscriptFiles.read_transcript!(key) ? |fault| FileSystem(fault) {
			NoFile => Ok(NoMessages)
			File(utf8) => Transcript.latest_message(utf8).map_err(|Unreadable| Unreadable(key))
		}
}

## The tile of each conversation of `places` that has a message, as the
## human `reader`, named `viewer`, sees it, the humans of `online_humans`
## online; unless a read failed, or a last message is not one the chat
## writes.
load_tiles! : {
	places : List(Browse.ListedPlace),
	reader : UserId,
	viewer : Name,
	online_humans : List(UserId),
} => Try(List(RecentFeed.Tile), [Unreadable(ConversationKey), FileSystem(FileFacts.Fault)])
load_tiles! = |{ places, reader, viewer, online_humans }| {
	with_topics = BrowseRoute.load_place_topics!(places) ? |fault| FileSystem(fault)
	var $tiles = []
	for { label, place, topics } in with_topics {
		for topic in topics {
			key = ConversationKey.of({ place, topic })
			$tiles =
				match RecentRoute.load_latest_message!(key)? {
					Latest(latest) =>
						$tiles.append(RecentFeed.tile({ key, label, latest, reader, viewer, online_humans }))
					NoMessages => $tiles
				}
		}
	}
	Ok($tiles)
}

## The 403 for a request with an API key.
key_refusal : Http.Response
key_refusal = HttpAnswer.page(
	403,
	PageKit.notice({ title: "Forbidden", text: "Recent is a human's, by their own session." }),
)

# ── tests
expect key_refusal.status == 403

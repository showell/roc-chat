## This module reads what a human's conversation page needs for its sidebar
## (`Sidebar`): the places Browse lists for them, each with its topics
## (`BrowseRoute.load_place_topics!`) and when each last had a message
## (`Transcript.latest_message`), each channel with its members ordered by
## who posted in it lately (`ChannelRoster`, from `Transcript.latest_posts`
## of the same transcript, read once), who of the humans is online, and the
## notice line a DM's page starts with (`PresenceNotices`). A key's page has
## no sidebar. `ConversationRoute` draws the page with it.
import Browse
import BrowseRoute
import ChannelRoster
import Clock
import ConversationKey
import ConversationPage
import DateTime
import Directory
import FileFacts
import Place
import PresenceNotices
import SidebarOrder
import SignedIn
import Transcript
import TranscriptFiles

SidebarRoute :: [].{

	## The sidebar of `acting`'s page of the conversation `key`, read from
	## `directory` and the files: none for an API key or an agent; unless a
	## read failed, or a message read is not one the chat writes.
	load_sidebar! : {
		key : ConversationKey,
		acting : SignedIn,
		directory : Directory,
	} => Try(
		ConversationPage.SidebarShown,
		[UnreadableLatest(ConversationKey), FileSystem(FileFacts.Fault)],
	)
	load_sidebar! = |{ key, acting, directory }| {
		match (Browse.places_for({ acting, directory }), acting.human_in_session()) {
			(Err(ByApiKey), _) => Ok(NoSidebar)
			(Err(Agent(_)), _) => Ok(NoSidebar)
			(_, Err(_)) => Ok(NoSidebar)
			(Ok(listed), Ok(reader)) => {
				with_topics = BrowseRoute.load_place_topics!(listed) ? |fault| FileSystem(fault)
				now = Clock.read_clock!({})
				sidebar_places = load_timed_places!({
					places: with_topics,
					since: ChannelRoster.since(now),
					directory,
				})?
				places = sidebar_places.timed
				rosters = sidebar_places.channel_posts.keep_oks(
					|{ place, posts }|
						match place.which() {
							Channel(name) =>
								directory.channels().channel(name).map_ok(
									|channel|
										ChannelRoster.roster({
											channel,
											users: directory.users(),
											viewer: reader,
											posts,
											now,
										}),
								)
							Dm(_) => Err(NoSuchChannel)
						},
				)
				humans = directory.users().to_list().keep_oks(|user| user.as_human())
				online_humans = PresenceNotices.load_online_humans!({
					humans: humans.map(|human| human.id()),
					now,
				})
				notice = PresenceNotices.load_dm_notice!({
					key,
					viewer: acting.user().id(),
					directory,
					now,
				})
				Ok(Sidebar({ places, online_humans, notice, rosters }))
			}
		}
	}
}

## Each of `places` with when each of its topics last had a message, which
## orders the sidebar (`SidebarOrder`), and each channel's members' latest
## posts from `since` on, among each topic's last
## `ChannelRoster.most_per_topic`, which order its members (`ChannelRoster`),
## its members found in `directory`; each transcript read once; unless a
## read failed, or a message read is not one the chat writes.
load_timed_places! : {
	places : List(Browse.PlaceWithTopics),
	since : DateTime,
	directory : Directory,
} => Try(
	{
		timed : List(SidebarOrder.TimedPlace),
		channel_posts : List({ place : Place, posts : List(Transcript.Post) }),
	},
	[UnreadableLatest(ConversationKey), FileSystem(FileFacts.Fault)],
)
load_timed_places! = |{ places, since, directory }| {
	var $timed = []
	var $channel_posts = []
	for { label, place, topics } in places {
		members =
			match place.which() {
				Channel(name) =>
					match directory.channels().channel(name) {
						Ok(channel) => channel.members().keep_oks(|id| directory.users().user(id)).map(|user| user.author())
						Err(NoSuchChannel) => []
					}
				Dm(_) => []
			}
		is_channel =
			match place.which() {
				Channel(_) => Bool.True
				Dm(_) => Bool.False
			}
		var $topics = []
		var $posts = []
		for topic in topics {
			key = ConversationKey.of({ place, topic })
			latest =
				match TranscriptFiles.read_transcript!(key) {
					Err(fault) => return Err(FileSystem(fault))
					Ok(NoFile) => NoMessages
					Ok(File(utf8)) => {
						if is_channel {
							match Transcript.latest_posts(utf8, { authors: members, most: ChannelRoster.most_per_topic, since }) {
								Ok(posts) => {
									$posts = List.concat($posts, posts)
								}
								Err(Unreadable) => return Err(UnreadableLatest(key))
							}
						}
						match Transcript.latest_message(utf8) {
							Ok(NoMessages) => NoMessages
							Ok(Latest(found)) => At(found.time)
							Err(Unreadable) => return Err(UnreadableLatest(key))
						}
					}
				}
			$topics = $topics.append({ topic, latest })
		}
		$timed = $timed.append({ label, place, topics: $topics })
		if is_channel {
			$channel_posts = $channel_posts.append({ place, posts: $posts })
		}
	}
	Ok({ timed: $timed, channel_posts: $channel_posts })
}

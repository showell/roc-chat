## This module is presence's effects; `Presence` decides. On each request a
## human makes that counts as activity, it has the host remember the second,
## and when the request brings them online it sends every other human, on
## their own stream, the dot for their sidebar and "<name> has come
## online.", linked to their DM with the human. It also tells a page which
## humans are online, for the dots it is drawn with, and what a DM's page
## says of the other human as it is drawn.
import pf.Host
import pf.Http
import ConversationKey
import Directory
import DirectoryFiles
import Dm
import HttpAnswer
import PageKit
import Place
import Presence
import Route
import SignedIn
import Timestamp
import UserId
import Users

PresenceNotices :: [].{

	## `acting`'s request for the route `asked`, at `now`, noted: a human's
	## that counts as activity is remembered, and when it brings them online
	## the other humans of `directory` are told. A DM's topics that can't be
	## listed are the failure answered, as nothing else is told.
	note_request! : {
		asked : Route.SignedInChoice,
		acting : SignedIn,
		directory : Directory,
		now : Timestamp,
	} => Try({}, [NotUtf8, PathRefused, Failed])
	note_request! = |{ asked, acting, directory, now }|
		match acting.human_in_session() {
			Ok(human) if Presence.counts_as_activity(asked) => {
				before = Host.replace_second_kept_under_key!(
					Presence.last_seen_key(human.id()),
					now.to_seconds_since_epoch(),
				)
				if Presence.comes_online({ last_seen: last_seen_of(before), now }) {
					tell_others!({ human, directory })
				} else {
					Ok({})
				}
			}
			_ => Ok({})
		}

	## The 500 for a request whose coming online could not be told, as
	## `note_request!` failed: a DM's topics could not be listed.
	presence_failure : Http.Response
	presence_failure =
		HttpAnswer.page(
			500,
			PageKit.notice({
				title: "Failed",
				text: "Your DMs' topics could not be read, to tell the others you are online.",
			}),
		)

	## The humans of `humans` who are online at `now`.
	load_online_humans! : { humans : List(UserId), now : Timestamp } => List(UserId)
	load_online_humans! = |{ humans, now }| {
		var $online_humans = []
		for human in humans {
			kept = Host.read_second_kept_under_key!(Presence.last_seen_key(human))
			if Presence.is_online({ last_seen: last_seen_of(kept), now }) {
				$online_humans = $online_humans.append(human)
			}
		}
		$online_humans
	}

	## What the notice line of `viewer`'s page of the conversation `key` says
	## as it is drawn at `now`: for a DM with another human of `directory`,
	## where they are (`Presence.presence_words`); nothing for a channel or
	## the viewer's own DM.
	load_dm_notice! : {
		key : ConversationKey,
		viewer : UserId,
		directory : Directory,
		now : Timestamp,
	} => [NoNotice, Notice(Str)]
	load_dm_notice! = |{ key, viewer, directory, now }|
		match key.place().which() {
			Channel(_) => NoNotice
			Dm(pair) =>
				match pair.members().drop_if(|id| id == viewer) {
					[other] =>
						match directory.users().user(other) {
							Ok(user) => {
								kept_key = Presence.last_seen_key(other)
								kept = Host.read_second_kept_under_key!(kept_key)
								Notice(
									Presence.presence_words({
										name: user.name().to_str(),
										last_seen: last_seen_of(kept),
										now,
									}),
								)
							}
							Err(NoSuchUser) => NoNotice
						}
					_ => NoNotice
				}
		}
}

## What the host answered of a kept second, as when a human was last seen.
last_seen_of : { second : I64, status : [Found, Missing] } -> Presence.LastSeen
last_seen_of = |kept|
	match kept.status {
		Found => SeenAt(Timestamp.at_second(kept.second))
		Missing => NeverSeen
	}

## Every human of `directory` but `human` sent the dot and the notice that
## `human` has come online, the notice linked to their DM with `human`.
tell_others! : {
	human : Users.Human,
	directory : Directory,
} => Try({}, [NotUtf8, PathRefused, Failed])
tell_others! = |{ human, directory }| {
	others =
		directory.users().to_list()
			.keep_oks(|user| user.as_human())
			.keep_if(|other| other.id() != human.id())
	for other in others {
		place = Place.dm(Dm.between({ one: other, other: human }))
		topics = DirectoryFiles.list_place_topics!(place)?
		key = ConversationKey.of({ place, topic: Presence.notice_topic(topics) })
		viewer_key = Presence.viewer_stream_key(other.id())
		name = human.user().name().to_str()
		Host.publish_bytes_to_streams_on_key!(viewer_key, Presence.online_frame(human.id()))
		Host.publish_bytes_to_streams_on_key!(
			viewer_key,
			Presence.notice_frame({ name, link: Presence.link_to(key) }),
		)
	}
	Ok({})
}

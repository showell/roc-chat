## This module is presence's effects; `Presence` decides. On each request a
## human makes that counts as activity, it has the host remember the second,
## and when the request brings them online it sends every other human, on
## their own stream, the dot for their sidebar and "<name> has come
## online.", linked to their DM with the human. It also tells a page which
## humans are online, for the dots it is drawn with.
import pf.Host
import ConversationKey
import Directory
import DirectoryFiles
import Dm
import Place
import Presence
import Route
import SignedIn
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
		now : I64,
	} => Try({}, [NotUtf8, PathRefused, Failed])
	note_request! = |{ asked, acting, directory, now }|
		match acting.human_in_session() {
			Ok(human) if Presence.counts_as_activity(asked) => {
				before = Host.remember_second_under_key!(Presence.last_seen_key(human.id()), now)
				if Presence.comes_online({ last_seen: last_seen_of(before), now }) {
					tell_others!({ human, directory })
				} else {
					Ok({})
				}
			}
			_ => Ok({})
		}

	## Which of `ids` are online at `now`.
	online_of! : { ids : List(UserId), now : I64 } => List(UserId)
	online_of! = |{ ids, now }| {
		var $online = []
		for id in ids {
			last_seen = last_seen_of(Host.second_remembered_under_key!(Presence.last_seen_key(id)))
			if Presence.is_online({ last_seen, now }) {
				$online = $online.append(id)
			}
		}
		$online
	}
}

## What the host answered of a remembered second, as when a human was last
## seen.
last_seen_of : { second : I64, status : [Found, Missing] } -> Presence.LastSeen
last_seen_of = |remembered|
	match remembered.status {
		Found => SeenAt(remembered.second)
		Missing => NeverSeen
	}

## Every human of `directory` but `human` sent the dot and the notice that
## `human` has come online, the notice linked to their DM with `human`.
tell_others! : { human : Users.Human, directory : Directory } => Try({}, [NotUtf8, PathRefused, Failed])
tell_others! = |{ human, directory }| {
	others =
		directory.users().to_list().keep_oks(|user| user.as_human()).keep_if(|other| other.id() != human.id())
	for other in others {
		place = Place.dm(Dm.between({ one: other, other: human }))
		topics = DirectoryFiles.list_place_topics!(place)?
		key = ConversationKey.of({ place, topic: Presence.notice_topic(topics) })
		viewer_key = Presence.viewer_stream_key(other.id())
		Host.publish_bytes_to_streams_on_key!(viewer_key, Presence.online_frame(human.id()))
		Host.publish_bytes_to_streams_on_key!(
			viewer_key,
			Presence.notice_frame({ name: human.user().name().to_str(), link: Presence.link_to(key) }),
		)
	}
	Ok({})
}

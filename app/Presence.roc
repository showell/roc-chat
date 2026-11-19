## This module decides who is online, as Gopher Chat's presence did
## (angry-gopher's zig-server/src/presence.zig). A human is online for five
## minutes after any request of theirs that is not a stream: a page, a
## post, a reaction, an upload. A stream is the browser's work, not the
## human's, so it never counts. The request that ends five minutes or more
## of quiet, or a human's first since the server started, brings them
## online: every other human is told, on their own stream
## (`viewer_stream_key`), with a dot for their sidebar (`online_frame`) and
## "<name> has come online." for the line above the page (`notice_frame`).
## Nobody is told when a human goes quiet; their dot goes hollow on the
## next page drawn. An agent is never online: no sidebar lists one.
##
## When a human was last seen is kept in the host's memory
## (`Host.remember_second_under_key!`), so a restart forgets it;
## `PresenceNotices` reads and writes it, and sends what this module writes.
import ConversationKey
import Escape
import Html
import Route
import ServerSentEvent
import Topic
import UserId

Presence :: [].{

	## When a human was last seen, as the host remembers it.
	LastSeen : [NeverSeen, SeenAt(I64)]

	## How long a human stays online after a request: five minutes, as
	## Gopher Chat's `PresenceWindow`.
	online_window_seconds : I64
	online_window_seconds = 5 * 60

	## Whether a human last seen at `last_seen` is online at `now`.
	is_online : { last_seen : Presence.LastSeen, now : I64 } -> Bool
	is_online = |{ last_seen, now }|
		match last_seen {
			NeverSeen => Bool.False
			SeenAt(second) => now - second < Presence.online_window_seconds
		}

	## Whether a request at `now`, by a human last seen at `last_seen`, brings
	## them online: they were not online the moment before.
	comes_online : { last_seen : Presence.LastSeen, now : I64 } -> Bool
	comes_online = |seen| !Presence.is_online(seen)

	## Whether the route `asked` counts as a human's activity: everything but
	## a stream.
	counts_as_activity : Route.SignedInChoice -> Bool
	counts_as_activity = |asked|
		match asked {
			OpenConversationStream(_) => Bool.False
			OpenAgentStream => Bool.False
			_ => Bool.True
		}

	## The key the host remembers when `human` was last seen under.
	last_seen_key : UserId -> List(U8)
	last_seen_key = |human| "last-seen/${human.to_str()}".to_utf8()

	## The bus key of what is sent to `viewer` alone, which every
	## conversation page's stream of theirs carries beside its conversation's.
	viewer_stream_key : UserId -> List(U8)
	viewer_stream_key = |viewer| "/viewers/${viewer.to_str()}".to_utf8()

	## The event that marks `human` online in a sidebar: `online`, its data
	## their id.
	online_frame : UserId -> List(U8)
	online_frame = |human| ServerSentEvent.named({ name: "online", html: Escape.text(human.to_str()) })

	## What is shown when a human named `name` comes online, as Gopher
	## Chat worded it.
	notice_words : Str -> Str
	notice_words = |name| "${name} has come online."

	## The event that says `name` has come online, above the page: `notice`,
	## its data a link to `link`, the recipient's DM with them.
	notice_frame : { name : Str, link : Html.SitePath } -> List(U8)
	notice_frame = |{ name, link }|
		ServerSentEvent.named({
			name: "notice",
			html: Html.element({
				name: A,
				attributes: [Link(link)],
				inner: Escape.text(Presence.notice_words(name)),
			}),
		})

	## The topic of a DM a notice links to, of the DM's `topics` in byte
	## order: the first, or `general` when it has none yet, as Browse
	## suggests for a place's first.
	notice_topic : List(Topic) -> Topic
	notice_topic = |topics|
		match topics.first() {
			Ok(topic) => topic
			Err(ListWasEmpty) => Topic.from_str("general") ?? crash "Presence.notice_topic: general is a topic"
		}

	## The site path of the conversation `key`, for a notice's link.
	link_to : ConversationKey -> Html.SitePath
	link_to = |key|
		Html.SitePath.from_str(key.url_path(Page))
			?? crash "Presence.link_to: a conversation's page is a site path"
}

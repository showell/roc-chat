## This module tells the sidebars of a place's humans that it has a new
## topic, as Gopher Chat's `topic-added` did (angry-gopher's
## zig-server/src/chat_fanout.zig): on a topic's first message, every
## member of its place, the author included, is sent the event on their own
## stream (`Presence.viewer_stream_key`), which every conversation page's
## stream of theirs carries, and app/sidebar.js adds the topic to its place
## in byte order (chat-client's js/chat_left_sidebar.js, `upsertSession`).
##
## The event carries Gopher's three fields, a line each: the place
## (Gopher's `conv`, here its path, the sidebar's `data-section`), the topic
## (`sid`) and the topic's page (`url`). It has no id, so the count of
## messages a browser has seen stays as it was. `ConversationRoute` sends it.
import ConversationKey
import Escape
import ServerSentEvent
import TrustedHtml

TopicAdded :: [].{

	## The event that tells a sidebar of the topic `key`: `topic-added`, its
	## data the place's path, the topic, and the topic's page, a line each.
	frame : ConversationKey -> List(U8)
	frame = |key|
		ServerSentEvent.named_event({
			name: "topic-added",
			html: TrustedHtml.join([
				Escape.text(ConversationKey.place_url_path(key.place())),
				Escape.text("\n"),
				Escape.text(key.topic().to_str()),
				Escape.text("\n"),
				Escape.text(key.url_path(Page)),
			]),
		})

}

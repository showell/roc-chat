## This module tells a place's humans that a message has come, as Gopher
## Chat's notify did (angry-gopher's zig-server/src/chat_fanout.zig,
## `Fan.notify`): every reader of the message but its author is sent
## `message-notice` on their own stream (`Presence.viewer_stream_key`), which
## their conversation pages' streams and their Recent page's stream carry.
## Its data is a link to the message's topic, worded as Gopher worded it:
## "Steve sent you a message on plans." in a DM, "Steve posted to general >
## plans." in a channel. app/chrome.js shows it in the top bar's notice line
## and paints the tab's icon violet, unless the page is that topic's own
## (chat-client's js/notify.js dropped a ping for the open topic). An edit is
## a message appended, so it is told too. `ConversationRoute` sends it to
## each of `recipients`.
import ConversationKey
import Escape
import Html
import Presence
import ServerSentEvent
import UserId

MessageNotice :: [].{

	## What the notice says of a message by `author` in the conversation
	## `key`, as Gopher Chat worded it.
	words : { author : Str, key : ConversationKey } -> Str
	words = |{ author, key }| {
		topic = key.topic().to_str()
		match key.place().which() {
			Channel(name) => "${author} posted to ${name.to_str()} > ${topic}."
			Dm(_) => "${author} sent you a message on ${topic}."
		}
	}

	## The event that tells of a message by `author` in `key`:
	## `message-notice`, its data a link to the topic's page.
	frame : { author : Str, key : ConversationKey } -> List(U8)
	frame = |given|
		ServerSentEvent.named_event({
			name: "message-notice",
			html: Html.element({
				name: A,
				attributes: [Link(Presence.link_to(given.key))],
				inner: Escape.text(MessageNotice.words(given)),
			}),
		})

	## Who of `readers` is told of a message by `author`: all but the author,
	## as Gopher Chat never told anyone of their own message.
	recipients : { readers : List(UserId), author : UserId } -> List(UserId)
	recipients = |{ readers, author }| readers.drop_if(|reader| reader == author)

}

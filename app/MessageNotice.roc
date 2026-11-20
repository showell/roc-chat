## This module tells a place's humans that a message has come, as Gopher
## Chat's notify did (angry-gopher's zig-server/src/chat_fanout.zig,
## `Fan.notify`): every reader of the message but its author is sent
## `message-notice` on their own stream (`Presence.viewer_stream_key`), which
## their conversation pages' streams and their Recent page's stream carry.
## Its data is a link to the message itself, on its topic's page with the
## message's anchor (`#msg-N`), which that page opens at and selects, so the
## click lands on the news. (Not `/chat/msg/<id>`, which comes to the same
## place by a redirect, but whose DM form names a topic alone and is
## ambiguous when two of the reader's DMs share a topic's name.) It is worded
## as Gopher worded it:
## "Steve sent you a message on plans." in a DM, "Steve posted to general >
## plans." in a channel. app/chrome.js shows it in the top bar's notice line
## and paints the tab's icon violet, unless the page is that topic's own
## (chat-client's js/notify.js dropped a ping for the open topic). An edit is
## a message appended, so it is told too. `ConversationRoute` sends it to
## each of `recipients`.
import ConversationKey
import Escape
import Html
import Message
import MessageAnchor
import PageKit
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

	## The event that tells of the message `id` by `author` in `key`:
	## `message-notice`, its data a link to that message on the topic's page.
	frame : {
		author : Str,
		key : ConversationKey,
		id : Message.Id,
	} -> List(U8)
	frame = |{ author, key, id }| {
		anchor = MessageAnchor.of({ topic: key.topic(), id })
		ServerSentEvent.named_event({
			name: "message-notice",
			html: Html.element({
				name: A,
				attributes: [
					LinkToPart({
						path: Presence.link_to(key),
						part: PageKit.token(anchor.page_anchor()),
					}),
				],
				inner: Escape.text(MessageNotice.words({ author, key })),
			}),
		})
	}

	## Who of `readers` is told of a message by `author`: all but the author,
	## as Gopher Chat never told anyone of their own message.
	recipients : { readers : List(UserId), author : UserId } -> List(UserId)
	recipients = |{ readers, author }| readers.drop_if(|reader| reader == author)

}

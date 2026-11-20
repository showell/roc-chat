## This module follows a link to a message (`MessageLink`), as Gopher Chat's
## `/chat/msg/<id>` did (angry-gopher's zig-server/src/chat.zig,
## `redirectToMsg`): a 302 to the message on its conversation's page, where
## the link names exactly one conversation the reader may read.
##
## A channel's link names that channel's topic and no other. `Dispatch` has
## asked `Access` that the reader may read its conversation, so a reader
## who isn't a member is refused as its page refuses them; a topic it
## doesn't have is a 404. A topic's link goes only where it can mean one
## place (`MessageLinkPlaces`): none is a 404, and two or more are
## ambiguous, a 409 saying so, never a guess.
##
## Neither looks at the message's number, as Gopher's didn't: a number past
## a topic's last is its page, scrolled nowhere.
import pf.Http
import ConversationKey
import Directory
import DirectoryFiles
import FileFacts
import FirstStart
import HttpAnswer
import MessageLink
import MessageLinkPlaces
import PageKit
import SignedIn
import UnvalidatedString

MessageLinkRoute :: [].{

	## A GET of a channel's `link`, to the conversation `key`, which `Access`
	## has let the reader read: a 302 to the message, or a 404 when the
	## channel has no such topic.
	answer_channel_link! : { key : ConversationKey, link : MessageLink } => Http.Response
	answer_channel_link! = |{ key, link }|
		match DirectoryFiles.list_place_topics!(key.place()) {
			Ok(topics) =>
				answer({ link, found_keys: [key].keep_if(|_| topics.contains(key.topic())) })
			Err(fault) => listing_failure(fault)
		}

	## A GET of a topic's `link` by `acting`: a 302 to the message in the one
	## place it can mean, a 404 for none, a 409 for more than one.
	answer_topic_link! : {
		link : MessageLink,
		acting : SignedIn,
		directory : Directory,
	} => Http.Response
	answer_topic_link! = |{ link, acting, directory }| {
		topic =
			match link.which() {
				InTopic(named) => named.topic
				InChannel(named) => named.topic
			}
		var $found = []
		var $fault = Ok({})
		for place in MessageLinkPlaces.readable_places({ acting, directory }) {
			match DirectoryFiles.list_place_topics!(place) {
				Ok(topics) if topics.contains(topic) => {
					$found = $found.append(ConversationKey.of({ place, topic }))
				}
				Ok(_) => {}
				Err(fault) => {
					$fault = Err(fault)
				}
			}
		}
		match $fault {
			Ok({}) => answer({ link, found_keys: $found })
			Err(fault) => listing_failure(fault)
		}
	}
}

## The answer to `link`, found in the conversations `found_keys`: a 302 to the
## message when there is one, a 404 for none, a 409 for more than one.
answer : { link : MessageLink, found_keys : List(ConversationKey) } -> Http.Response
answer = |{ link, found_keys }|
	match MessageLinkPlaces.destination(found_keys) {
		GoesTo(key) => HttpAnswer.found("${key.url_path(Page)}#${link.anchor().page_anchor()}")
		Nowhere => HttpAnswer.page(404, PageKit.not_found)
		Ambiguous => HttpAnswer.text(409, ambiguous_words)
	}

## What a link that means more than one place says, Gopher's words.
ambiguous_words : Str
ambiguous_words = "This reference is ambiguous: more than one of your conversations has a topic of that name."

## The 500 for a place whose topics could not be listed.
listing_failure : FileFacts.Fault -> Http.Response
listing_failure = |fault|
	HttpAnswer.page(500, PageKit.notice({ title: "Failed", text: FileFacts.fault_words(fault) }))

# ── tests
## The link `text` spells.
link_of : Str -> MessageLink
link_of = |text| MessageLink.from_str(text) ?? crash "MessageLinkRoute's tests: a link"

## The conversation at `path` in the first start's directory.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "MessageLinkRoute's tests: a path is UTF-8",
	directory: FirstStart.first_directory,
}).map_ok(|found| found.key) ?? crash "MessageLinkRoute's tests: a conversation's path"

## Whether `response` sends the browser anywhere.
sends_on : Http.Response -> Bool
sends_on = |response| response.headers.any(|header| header.name == "location".to_utf8())

# Found in one conversation: a 302 to the message on its page, by its
# anchor there; a channel's link as a topic's.
expect {
	found = answer({ link: link_of("plans_2"), found_keys: [key_at("/chat/dm/1_1/plans")] })
	found.status == 302
		and found.headers == [{ name: "location".to_utf8(), value: "/chat/dm/1_1/plans#msg-2".to_utf8() }]
}
expect
	answer({ link: link_of("general.roc-chat_6"), found_keys: [key_at("/chat/channel/general/roc-chat")] }).headers
		== [{ name: "location".to_utf8(), value: "/chat/channel/general/roc-chat#msg-6".to_utf8() }]
# Found nowhere: a 404, sent nowhere.
expect {
	nowhere = answer({ link: link_of("plans_2"), found_keys: [] })
	nowhere.status == 404 and !sends_on(nowhere)
}
# Found in two: ambiguous, a 409 in Gopher's words, never a guess.
expect {
	both = answer({
		link: link_of("plans_2"),
		found_keys: [key_at("/chat/dm/1_1/plans"), key_at("/chat/channel/general/plans")],
	})
	both.status == 409
		and both.body
			== "This reference is ambiguous: more than one of your conversations has a topic of that name.\n".to_utf8()
		and !sends_on(both)
}

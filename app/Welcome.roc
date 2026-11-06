## A new human is welcomed in a DM with the chat's owner: a first conversation,
## under `Welcome.topic`, holding one message from the owner. This module
## decides that conversation and spells its transcript's first record. The
## routes that make an account write it, and `FirstPage` sends the human there.
##
## The DM is named by ids and the message names only the owner, so neither
## changes when an invited human chooses another name as they join.
import ConversationKey
import DateTime
import Directory
import Dm
import Name
import Place
import Timestamp
import Topic
import Transcript
import Users

Welcome :: { key : ConversationKey, record : Transcript.Utf8TranscriptMessage }.{

	## The topic of the conversation that welcomes a human.
	topic : Topic
	topic = Topic.from_str("ChitChat") ?? crash "Welcome.topic: ChitChat is a topic"

	## The message, in the words of the owner named `owner`.
	markdown : Name -> Str
	markdown = |owner|
		"Welcome! If ${owner.to_str()} is not here, you can still send a message, and he will reply soon."

	## The conversation that welcomes `human`, in `directory`.
	conversation_key : { directory : Directory, human : Users.Human } -> ConversationKey
	conversation_key = |{ directory, human }|
		ConversationKey.of({
			place: Place.dm(Dm.between({ a: directory.chat_owner(), b: human })),
			topic: Welcome.topic,
		})

	## The welcome of `human`, a human of `directory`, dated `now` (seconds
	## since the epoch); unless the clock is out of range.
	make : {
		directory : Directory,
		human : Users.Human,
		now : Timestamp,
	} -> Try(Welcome, [ClockOutOfRange])
	make = |{ directory, human, now }| {
		time = DateTime.from_timestamp(now) ? |OutOfRange| ClockOutOfRange
		owner = directory.chat_owner()
		started = Dm.start({
			to: human,
			topic: Welcome.topic,
			first_message: {
				payload: { author: owner, markdown: Welcome.markdown(owner.user().name()) },
				time,
			},
		})
		message =
			started.conversation.messages().first()
				?? crash "Welcome.make: a DM starts with its first message"
		record =
			Transcript.message_record({
				conversation: started.conversation,
				message,
				file: NoFile,
			}) ?? crash "Welcome.make: one short message fits an empty transcript"
		Ok(Welcome.({ key: Welcome.conversation_key({ directory, human }), record }))
	}

	## The conversation it starts.
	key : Welcome -> ConversationKey
	key = |Welcome.(welcome)| welcome.key

	## Its record, the first of the conversation's transcript.
	first_record : Welcome -> Transcript.Utf8TranscriptMessage
	first_record = |Welcome.(welcome)| welcome.record
}

# ── tests
tests_name : Str -> Name
tests_name = |text| Name.from_str(text) ?? crash "Welcome's tests: a name"

## A chat owned by `owner`, and Zoe, its second human.
tests_chat : Str -> { directory : Directory, human : Users.Human }
tests_chat = |owner| {
	added =
		Directory.with_founder(tests_name(owner)).add_human(tests_name("Zoe"))
			?? crash "Welcome's tests: room"
	{
		directory: added.directory,
		human: added.user.as_human() ?? crash "Welcome's tests: Zoe is a human",
	}
}

## The record of the welcome in the chat of `owner`, as its file holds it.
record_text : Str -> Str
record_text = |owner| {
	chat = tests_chat(owner)
	made =
		Welcome.make({
			directory: chat.directory,
			human: chat.human,
			now: Timestamp.at_second(1793646692),
		}) ?? crash "Welcome's tests: the clock is in range"
	Str.from_utf8(made.first_record().to_utf8_bytes()) ?? crash "Welcome's tests: a record is UTF-8"
}

# The record is the transcript's own format, its author and its words the
# owner's name, whatever that is.
expect
	record_text("Steve")
		== "-------------\nMSG_ChitChat_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nWelcome! If Steve is not here, you can still send a message, and he will reply soon.\n\n"
expect
	record_text("Ada Lovelace")
		== "-------------\nMSG_ChitChat_1\nfrom: Ada Lovelace\ndate: 2026-11-02T19:11:32Z\n\nWelcome! If Ada Lovelace is not here, you can still send a message, and he will reply soon.\n\n"
# The record reads back as one message by the owner.
expect {
	text = record_text("Ada")
	read = Transcript.read(Welcome.topic, text) ?? crash "Welcome's tests: a record reads"
	read.messages().map(|message| message.author().to_str()) == ["Ada"]
}
# The DM is the owner's and the human's, by id, and its page is the same one
# `make` starts.
expect {
	chat = tests_chat("Steve")
	made =
		Welcome.make({
			directory: chat.directory,
			human: chat.human,
			now: Timestamp.at_second(0),
		}) ?? crash "Welcome's tests: the clock's first second"
	made.key() == Welcome.conversation_key(chat) and made.key().url_path(Page) == "/chat/dm/1_2/ChitChat"
}
# A clock before its first second makes no welcome.
expect {
	chat = tests_chat("Steve")
	made = Welcome.make({
		directory: chat.directory,
		human: chat.human,
		now: Timestamp.at_second(-1),
	})
	made.map_ok(|_| {}) == Err(ClockOutOfRange)
}
# A human who takes another name keeps the same conversation.
expect {
	chat = tests_chat("Steve")
	renamed =
		chat.directory.rename_human({ human: chat.human, name: tests_name("Zed") })
			?? crash "Welcome's tests: Zed is free"
	after = Welcome.conversation_key({ directory: renamed.directory, human: renamed.human })
	after == Welcome.conversation_key(chat)
}

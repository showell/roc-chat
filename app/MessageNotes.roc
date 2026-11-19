## What a page shows of a message beside the message itself: whether a later
## message edited it, and which (`Edit`), and its reactions (`Reactions`),
## an emoji a chip. A message never changes, but its notes do, so the page
## draws each message with its notes, and the stream sends a message again
## when its notes change (`ConversationStream`).
import Author
import Conversation
import DateTime
import Edit
import Message
import Reactions
import Topic
import UserId

MessageNotes :: { edited : [NotEdited, EditedIn(Message.Id)], chips : List(Reactions.Chip) }.{

	## A message just written: no edit, no reactions.
	fresh : MessageNotes
	fresh = MessageNotes.({ edited: NotEdited, chips: [] })

	## Each message's notes, oldest first, a note for each message.
	notes_of_messages : { conversation : Conversation, reactions : Reactions } -> List(MessageNotes)
	notes_of_messages = |{ conversation, reactions }|
		List.map2(
			Edit.edited_in(conversation),
			conversation.messages(),
			|edited, message| MessageNotes.({ edited, chips: reactions.chips(message.id()) }),
		)

	## Whether the message was edited, and in which message.
	edit_state : MessageNotes -> [NotEdited, EditedIn(Message.Id)]
	edit_state = |MessageNotes.(notes)| notes.edited

	## Its reactions, an emoji a chip, each in the order it was first used.
	chips : MessageNotes -> List(Reactions.Chip)
	chips = |MessageNotes.(notes)| notes.chips

	## Whether the notes are a fresh message's: no edit and no reactions.
	is_fresh : MessageNotes -> Bool
	is_fresh = |MessageNotes.(notes)| notes.edited == NotEdited and notes.chips.is_empty()

	is_eq : _
}

# ── tests
## The conversation `plans`: Steve's "Hello", then his edit of it.
plans : Conversation
plans = {
	topic = Topic.from_str("plans") ?? crash "MessageNotes' tests: a topic"
	time = DateTime.from_str("2026-11-02T19:11:32Z") ?? crash "MessageNotes' tests: a time"
	steve = Author.from_str("Steve") ?? crash "MessageNotes' tests: a name"
	["Hello", "Edit of MSG_plans_1\n\nHello!"].fold(
		Conversation.empty(topic),
		|so_far, markdown| (so_far.append({ payload: { author: steve, markdown }, time })
			?? crash "MessageNotes' tests: a message joins").conversation,
	)
}

## A thumbs up from user 1 on message 2.
thumbs_on_the_edit : Reactions
thumbs_on_the_edit = {
	reaction = {
		message: Message.Id.from_digits("2".to_utf8()) ?? crash "MessageNotes' tests: an id",
		user: UserId.chat_owner,
		emoji: Reactions.Emoji.from_str("👍") ?? crash "MessageNotes' tests: an emoji",
	}
	Reactions.empty.set({ reaction, wanted: On }) ?? crash "MessageNotes' tests: a reaction fits"
}

# The edited message names its edit and has no chips; the edit has its
# chip; and a fresh message's notes are fresh, while neither of these is.
expect {
	notes = MessageNotes.notes_of_messages({ conversation: plans, reactions: thumbs_on_the_edit })
	edit_id = Message.Id.from_digits("2".to_utf8()) ?? crash "MessageNotes' tests: an id"
	notes.map(MessageNotes.edit_state) == [EditedIn(edit_id), NotEdited]
		and notes.map(|one| one.chips().len()) == [0, 1]
		and notes.map(MessageNotes.is_fresh) == [Bool.False, Bool.False]
		and MessageNotes.fresh.is_fresh()
}
expect
	MessageNotes.notes_of_messages({
		conversation: plans,
		reactions: Reactions.empty,
	}).map(MessageNotes.is_fresh)
		== [Bool.False, Bool.True]

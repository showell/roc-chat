## An edit is a new message that takes the place of an earlier one by the
## same author, in the same conversation. Messages never change, so the
## original stays in the transcript as it was written, and its page shows it
## as edited, with a link to the edit.
##
## A message is an edit when its markdown starts `Edit of ` and the
## reference of the message it edits, `MSG_<topic>_<n>` (`MsgAnchor`), its
## topic the conversation's, then a space, a line end or nothing, as Gopher
## Chat's edits start. The compose box's script writes that line, and an
## agent may too. Only a message's author edits it: a post that would edit
## another author's message, or a message the conversation doesn't hold, is
## refused (`judge`). A message read from a transcript is an edit only when
## it is one of its author's own earlier messages (`edited_in`), so no
## message can hide another author's.
import Author
import Conversation
import DateTime
import Message
import Topic

Edit :: [].{

	## What a new message by `author` with `markdown` would be in
	## `conversation`: an edit of one of the author's messages (`EditOf`), or
	## no edit; unless it names a message the conversation doesn't hold
	## (`EditOfNoSuchMessage`), or another author's
	## (`EditOfAnotherAuthorsMessage`).
	judge : {
		conversation : Conversation,
		author : Author,
		markdown : Str,
	} -> Try(
		[EditOf(Message.Id), NotAnEdit],
		[EditOfNoSuchMessage, EditOfAnotherAuthorsMessage],
	)
	judge = |{ conversation, author, markdown }|
		match edited_id({ conversation, markdown }) {
			NotAnEdit => Ok(NotAnEdit)
			EditOf(id) =>
				match conversation.messages().get(id.to_u64() - 1) {
					Err(OutOfBounds) => Err(EditOfNoSuchMessage)
					Ok(original) if original.author() == author => Ok(EditOf(id))
					Ok(_) => Err(EditOfAnotherAuthorsMessage)
				}
		}

	## Each message of `conversation`, oldest first, as edited or not: an
	## edited message names its latest edit (`EditedIn`). An edit counts only
	## when it is by the author of the message it names, and comes after it.
	edited_in : Conversation -> List([NotEdited, EditedIn(Message.Id)])
	edited_in = |conversation| {
		messages = conversation.messages()
		messages.fold(
			List.repeat(NotEdited, messages.len()),
			|so_far, message|
				match edited_id({ conversation, markdown: message.markdown() }) {
					NotAnEdit => so_far
					EditOf(id) =>
						match messages.get(id.to_u64() - 1) {
							Ok(original) if is_own_earlier({ original, edit: message }) =>
								so_far.set(id.to_u64() - 1, EditedIn(message.id()))
									?? crash "Edit.edited_in: the original is one of the conversation's messages"
							_ => so_far
						}
				},
		)
	}

}

## Whether `edit` comes after `original` and is by its author.
is_own_earlier : { original : Message, edit : Message } -> Bool
is_own_earlier = |{ original, edit }|
	original.author() == edit.author() and original.id().to_u64() < edit.id().to_u64()

## What an edit's markdown starts with, before the reference.
edit_prefix : Str
edit_prefix = "Edit of "

## The message `markdown` names as the one it edits, in `conversation`'s
## topic, or `NotAnEdit`. Whether the conversation holds it is the caller's
## to ask.
edited_id : { conversation : Conversation, markdown : Str } -> [EditOf(Message.Id), NotAnEdit]
edited_id = |{ conversation, markdown }| {
	reference_prefix = "${edit_prefix}MSG_${conversation.topic().to_str()}_"
	if markdown.starts_with(reference_prefix) {
		rest = markdown.drop_prefix(reference_prefix).to_utf8()
		digits =
			match rest.find_first_index(|byte| byte == ' ' or byte == '\n' or byte == '\r') {
				Ok(end) => rest.take_first(end)
				Err(NotFound) => rest
			}
		match Message.Id.from_digits(digits) {
			Ok(id) => EditOf(id)
			Err(NotAMessageId) => NotAnEdit
		}
	} else {
		NotAnEdit
	}
}

# ── tests
## An author, by the name `name`.
author_of : Str -> Author
author_of = |name| Author.from_str(name) ?? crash "Edit's tests: an author's name"

## The conversation `plans`, holding a message of each author and markdown,
## in order, at one time.
plans_holding : List((Str, Str)) -> Conversation
plans_holding = |written| {
	plans = Topic.from_str("plans") ?? crash "Edit's tests: a topic"
	time = DateTime.from_str("2026-11-02T19:11:32Z") ?? crash "Edit's tests: a time"
	written.fold(
		Conversation.empty(plans),
		|so_far, (name, markdown)| {
			unnumbered = { payload: { author: author_of(name), markdown }, time }
			grown = so_far.append(unnumbered) ?? crash "Edit's tests: a message joins"
			grown.conversation
		},
	)
}

## The id `number`, which a test knows is one.
id_of : Str -> Message.Id
id_of = |number| Message.Id.from_digits(number.to_utf8()) ?? crash "Edit's tests: an id"

## What `judge` says of `markdown` by `name`, after Steve's message 1 and
## CC's message 2.
judgement_of : { name : Str, markdown : Str } -> Try([EditOf(Message.Id), NotAnEdit], _)
judgement_of = |{ name, markdown }|
	Edit.judge({
		conversation: plans_holding([("Steve", "Hello"), ("CC", "Hi")]),
		author: author_of(name),
		markdown,
	})

# Who may edit: the author edits their own message; another author's, and a
# message not there, are refused.
expect judgement_of({
	name: "Steve",
	markdown: "Edit of MSG_plans_1\n\nHello!",
}) == Ok(EditOf(id_of("1")))
expect judgement_of({ name: "CC", markdown: "Edit of MSG_plans_2" }) == Ok(EditOf(id_of("2")))
expect judgement_of({
	name: "CC",
	markdown: "Edit of MSG_plans_1\n\nHello!",
}) == Err(EditOfAnotherAuthorsMessage)
expect judgement_of({
	name: "Steve",
	markdown: "Edit of MSG_plans_2 typo",
}) == Err(EditOfAnotherAuthorsMessage)
expect judgement_of({
	name: "Steve",
	markdown: "Edit of MSG_plans_3\n\nx",
}) == Err(EditOfNoSuchMessage)
# What is no edit: another topic's reference, no id, a reference later in
# the message, and a near miss of the first words.
expect
	[
		"Edit of MSG_other_1\n\nx",
		"Edit of MSG_plans_\n\nx",
		"Edit of MSG_plans_x",
		"Edit of MSG_plans_01",
		"Edit of MSG_plans_1x",
		"Hello\nEdit of MSG_plans_1",
		"edit of MSG_plans_1",
		"Edit of MSG_plans",
		"Hello",
	].all(|markdown| judgement_of({ name: "Steve", markdown }) == Ok(NotAnEdit))
# Each message as edited or not: the latest of its author's edits counts;
# an edit by another author, or of a later message, does not.
expect
	Edit.edited_in(
		plans_holding([
			("Steve", "Hello"),
			("CC", "Edit of MSG_plans_1\n\nHijacked"),
			("Steve", "Edit of MSG_plans_1\n\nHello!"),
			("Steve", "Edit of MSG_plans_1\n\nHello!!"),
			("CC", "Edit of MSG_plans_6"),
			("CC", "Edit of MSG_plans_5"),
		]),
	)
		== [
			EditedIn(id_of("4")),
			NotEdited,
			NotEdited,
			NotEdited,
			EditedIn(id_of("6")),
			NotEdited,
		]
# An edit of an edit marks the edit, and the original keeps its own.
expect
	Edit.edited_in(
		plans_holding([
			("CC", "a"),
			("CC", "Edit of MSG_plans_1\n\nb"),
			("CC", "Edit of MSG_plans_2\n\nc"),
		]),
	)
		== [
			EditedIn(id_of("2")),
			EditedIn(id_of("3")),
			NotEdited,
		]
expect Edit.edited_in(plans_holding([])) == []

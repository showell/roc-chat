## This module answers a reaction's POST to a conversation's `/react`,
## which the page's script (app/actions.js) sends: the form's `msg` names
## the message by its number, `emoji` the emoji, and `on` is `1` to react or
## `0` to take the reaction back. Anyone who may post in the conversation
## may react (`Dispatch` asks `Access`). The reaction is set in the
## conversation's reactions (`Reactions`), their file is rewritten
## (`TranscriptFiles`), and the message is sent again on the conversation's
## stream with its reactions as they are now
## (`ConversationStream.publish_again!`), so every open page shows it, the
## page that reacted included. The answer is a 200 in plain words, or the
## refusal's status and words (`ConversationRefusal`).
import pf.Http
import ConversationKey
import ConversationRefusal
import ConversationStream
import HttpAnswer
import Reactions
import SignedIn
import Transcript
import TranscriptFiles
import UnvalidatedString
import UrlEncodedForm
import UserId
import Users

ReactionRoute :: [].{

	## A reaction's POST to the conversation `key`, by `acting`, its form in
	## `body`; each message's author is found among `users` as the page
	## draws it.
	post_reaction! : {
		key : ConversationKey,
		acting : SignedIn,
		users : Users,
		body : List(U8),
	} => Http.Response
	post_reaction! = |{ key, acting, users, body }|
		match set_reaction!({ key, acting, users, body }) {
			Ok({}) => HttpAnswer.text(200, "Reaction set.")
			Err(why) => {
				notice = ConversationRefusal.notice(why)
				HttpAnswer.text(notice.status, notice.words.text)
			}
		}
}

## The reaction in `body`, set in the conversation `key`'s reactions, kept,
## and sent to its stream; or why not.
set_reaction! : {
	key : ConversationKey,
	acting : SignedIn,
	users : Users,
	body : List(U8),
} => Try({}, _)
set_reaction! = |{ key, acting, users, body }| {
	asked = reaction_asked({ body, user: acting.user().id() })?
	file = TranscriptFiles.read_transcript!(key) ? |fault| FileSystem(fault)
	utf8 =
		match file {
			File(bytes) => bytes
			NoFile => Transcript.Utf8Transcript.unchecked_from_file([])
		}
	conversation = Transcript.decode(key.topic(), utf8) ? |why| Unreadable(why)
	if asked.reaction.message.to_u64() > conversation.messages().len() {
		Err(NoSuchMessage)
	} else {
		held = TranscriptFiles.read_reactions!(key) ? |fault| FileSystem(fault)
		reactions = held.set(asked)?
		TranscriptFiles.replace_reactions!(key, reactions) ? |fault| FileSystem(fault)
		ConversationStream.publish_again!({
			key,
			conversation,
			reactions,
			users,
			id: asked.reaction.message,
		})
		Ok({})
	}
}

## The reaction `body`'s form asks for, by `user`, and whether it is wanted
## on or off; or the form's first fault.
reaction_asked : { body : List(U8), user : UserId } -> Try(
	{ reaction : Reactions.Reaction, wanted : [On, Off] },
	[
		ReactionField({ fault : [MissingField, RepeatedField, BadEscape, NotUtf8], name : Str }),
		NotAMessageId,
		NotAnEmoji,
		NotOnOrOff,
	],
)
reaction_asked = |{ body, user }| {
	message_field = form_field({ body, name: "msg" })?
	emoji_field = form_field({ body, name: "emoji" })?
	on_field = form_field({ body, name: "on" })?
	message = message_field.message_id()?
	emoji = emoji_field.emoji()?
	wanted = reaction_wanted(on_field)?
	Ok({ reaction: { message, user, emoji }, wanted })
}

## Whether the field `on` asks for the reaction (`1`) or its end (`0`).
reaction_wanted : UnvalidatedString -> Try([On, Off], [NotOnOrOff])
reaction_wanted = |on_field|
	if on_field.is_exactly("1") {
		Ok(On)
	} else if on_field.is_exactly("0") {
		Ok(Off)
	} else {
		Err(NotOnOrOff)
	}

## The field `name` of a reaction's form, or its fault, naming the field.
form_field : { body : List(U8), name : Str } -> Try(
	UnvalidatedString,
	[ReactionField({ fault : [MissingField, RepeatedField, BadEscape, NotUtf8], name : Str })],
)
form_field = |{ body, name }|
	UrlEncodedForm.field({ body, name }).map_err(|fault| ReactionField({ fault, name }))

# ── tests
## What `reaction_asked` reads from the form `body`, by Steve, as a test
## reads it: the message's number, the emoji and on or off.
asked_of : Str -> Try((Str, Str, [On, Off]), _)
asked_of = |body|
	reaction_asked({ body: body.to_utf8(), user: UserId.chat_owner }).map_ok(
		|{ reaction, wanted }| (reaction.message.to_str(), reaction.emoji.to_str(), wanted),
	)

# A reaction's form: on and off, each field percent-encoded as a browser
# sends it, the user the one acting.
expect asked_of("msg=3&emoji=%F0%9F%91%8D&on=1") == Ok(("3", "👍", On))
expect asked_of("on=0&emoji=%F0%9F%8E%89&msg=65535") == Ok(("65535", "🎉", Off))
expect
	reaction_asked({
		body: "msg=3&emoji=%F0%9F%91%8D&on=1".to_utf8(),
		user: UserId.chat_owner,
	}).map_ok(|asked| asked.reaction.user)
		== Ok(UserId.chat_owner)
# What is refused: each field missing or repeated, no message's number, no
# emoji, and an `on` that is neither 1 nor 0.
expect asked_of("emoji=%F0%9F%91%8D&on=1") == Err(
	ReactionField({ fault: MissingField, name: "msg" }),
)
expect asked_of("msg=3&on=1") == Err(ReactionField({ fault: MissingField, name: "emoji" }))
expect asked_of("msg=3&emoji=%F0%9F%91%8D") == Err(
	ReactionField({ fault: MissingField, name: "on" }),
)
expect asked_of("msg=3&msg=4&emoji=%F0%9F%91%8D&on=1") == Err(
	ReactionField({ fault: RepeatedField, name: "msg" }),
)
expect asked_of("msg=3&emoji=%FF&on=1") == Err(ReactionField({ fault: NotUtf8, name: "emoji" }))
expect asked_of("msg=0&emoji=%F0%9F%91%8D&on=1") == Err(NotAMessageId)
expect asked_of("msg=three&emoji=%F0%9F%91%8D&on=1") == Err(NotAMessageId)
expect asked_of("msg=3&emoji=%2B1&on=1") == Err(NotAnEmoji)
expect asked_of("msg=3&emoji=%F0%9F%91%8D&on=yes") == Err(NotOnOrOff)
expect asked_of("msg=3&emoji=%F0%9F%91%8D&on=") == Err(NotOnOrOff)

## This module keeps the chat's conversations on disk: each conversation's
## transcript, the images uploaded to it, and each user's upload total and
## last conversation. It
## reads and writes them through `FileFacts`, and builds every path from a
## typed key, so no caller names a file.
##
## A conversation's folder is its key's parts (`ConversationKey`, the
## layout's one home for them), and its transcript is the file `transcript`
## in it. The transcript's types are `Transcript`'s making. A read answers a
## whole `Utf8Transcript`, untrusted until `Transcript.decode` reads it, and
## an append takes one message's `Utf8TranscriptMessage`, which only
## `Transcript` makes.
##
## A conversation's reactions are the file `reactions` beside its
## transcript, in `Reactions`' format, rewritten whole at each change.
##
## A conversation's uploaded images are kept in its folder, under
## `uploads/`, each by its own name (`UploadedImage`), as bytes.
##
## A user's own facts are kept in their folder (`UserFolder`), one small
## file per fact: their upload total (`UploadTotal`) is `upload-bytes`, and
## the conversation they last opened (`LastConversation`) is `last-conv`.
import ConversationKey
import Directory
import FileFacts
import LastConversation
import Name
import Reactions
import Transcript
import UploadTotal
import UnvalidatedString
import UploadedImage
import UserFolder
import UserId

TranscriptFiles :: [].{

	## A conversation's transcript, the whole file, unchecked, or `NoFile`
	## when there is none yet; unless the host's read failed.
	read_transcript! : ConversationKey => Try(
		[NoFile, File(Transcript.Utf8Transcript)],
		[NotUtf8, PathRefused, Failed],
	)
	read_transcript! = |key|
		match FileFacts.read_fact!(transcript_path(key))? {
			File(bytes) => Ok(File(Transcript.Utf8Transcript.unchecked_from_file(bytes)))
			NoFile => Ok(NoFile)
		}

	## One message's record, added at the end of its conversation's
	## transcript: the conversation's folder made as needed, then the record
	## appended (the file made when it is the first); unless the host
	## refused.
	append_message! : ConversationKey,
	Transcript.Utf8TranscriptMessage => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	append_message! = |key, record| {
		FileFacts.make_folder!(folder_path(key))?
		FileFacts.append_to_file!(transcript_path(key), record.to_utf8_bytes())
	}

	## A conversation's reactions, as its file holds them, or none when there
	## is no file yet; unless the file holds no reactions (`Damaged`), or the
	## host's read failed.
	read_reactions! : ConversationKey => Try(Reactions, [Damaged, NotUtf8, PathRefused, Failed])
	read_reactions! = |key|
		match FileFacts.read_fact!(reactions_path(key))? {
			File(bytes) => Reactions.from_file(bytes).map_err(|_| Damaged)
			NoFile => Ok(Reactions.empty)
		}

	## A conversation's reactions, written whole over the file before,
	## atomically, its folder made as needed; unless the host refused, and
	## then the file is as it was.
	replace_reactions! : ConversationKey,
	Reactions => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_reactions! = |key, reactions| {
		FileFacts.make_folder!(folder_path(key))?
		FileFacts.replace_fact!(reactions_path(key), reactions.to_file())
	}

	## An uploaded image's bytes, kept in its conversation's uploads folder
	## under its name, the folders made as needed; unless the host refused.
	## A name already there is `AlreadyExists`, and nothing is changed.
	store_uploaded_image! : ConversationKey,
	{ image : UploadedImage, bytes : List(U8) } => Try(
		{},
		[AlreadyExists, MissingDirectory, PathRefused, Failed],
	)
	store_uploaded_image! = |key, { image, bytes }| {
		FileFacts.make_folder!(uploads_folder_path(key))?
		FileFacts.create_binary_file!(uploaded_image_path(key, image), bytes)
	}

	## An uploaded image's bytes, as kept; unless the conversation has no
	## image of its name (`Missing`), or the host's read failed.
	read_uploaded_image! : ConversationKey,
	UploadedImage => Try(
		List(U8),
		[Missing, PathRefused, Failed],
	)
	read_uploaded_image! = |key, image| FileFacts.read_binary_file!(uploaded_image_path(key, image))

	## A user's upload total, as their folder keeps it, read by
	## `UploadTotal.from_file`; unless the host's read failed.
	read_upload_total! : UserFolder => Try(UploadTotal, [NotANumber, FileSystem(FileFacts.Fault)])
	read_upload_total! = |folder| {
		fact = FileFacts.read_fact!(upload_total_path(folder)) ? |fault| FileSystem(fault)
		UploadTotal.from_file(fact)
	}

	## A user's upload total, written whole over the one before, their folder
	## made as needed; unless the host refused, and then the file is as it
	## was.
	replace_upload_total! : UserFolder,
	UploadTotal => Try(
		{},
		[MissingDirectory, PathRefused, Failed],
	)
	replace_upload_total! = |folder, total| {
		FileFacts.make_folder!(user_folder_path(folder))?
		match FileFacts.replace_fact!(upload_total_path(folder), total.to_file()) {
			Ok({}) => Ok({})
			Err(MissingDirectory) => Err(MissingDirectory)
			Err(NotUtf8) => crash "TranscriptFiles.replace_upload_total!: a total's digits are UTF-8"
			Err(PathRefused) => Err(PathRefused)
			Err(Failed) => Err(Failed)
		}
	}

	## The file of the conversation a user last opened, unchecked, or
	## `NoFile` when there is none yet; unless the host's read failed.
	read_last_conversation! : UserFolder => Try(
		[NoFile, File(List(U8))],
		[NotUtf8, PathRefused, Failed],
	)
	read_last_conversation! = |folder| FileFacts.read_fact!(last_conversation_path(folder))

	## The conversation a user last opened, written whole over the one
	## before, their folder made as needed; unless the host refused.
	replace_last_conversation! : UserFolder,
	LastConversation => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_last_conversation! = |folder, last| {
		FileFacts.make_folder!(user_folder_path(folder))?
		FileFacts.replace_fact!(last_conversation_path(folder), last.to_file())
	}
}

## A user's folder: its parts.
user_folder_path : UserFolder -> Str
user_folder_path = |folder| Str.join_with(folder.parts(), "/")

## The path of a user's upload total.
upload_total_path : UserFolder -> Str
upload_total_path = |folder| "${user_folder_path(folder)}/upload-bytes"

## The path of the conversation a user last opened.
last_conversation_path : UserFolder -> Str
last_conversation_path = |folder| "${user_folder_path(folder)}/last-conv"

## The folder a conversation's uploaded images are kept in.
uploads_folder_path : ConversationKey -> Str
uploads_folder_path = |key| "${folder_path(key)}/uploads"

## The path of an uploaded image of the conversation.
uploaded_image_path : ConversationKey, UploadedImage -> Str
uploaded_image_path = |key, image| "${uploads_folder_path(key)}/${image.name()}"

## A conversation's folder: its key's parts. Its transcript is the file
## `transcript` in it.
folder_path : ConversationKey -> Str
folder_path = |key| Str.join_with(key.parts(), "/")

## The path of the conversation's transcript.
transcript_path : ConversationKey -> Str
transcript_path = |key| "${folder_path(key)}/transcript"

## The path of the conversation's reactions, beside its transcript.
reactions_path : ConversationKey -> Str
reactions_path = |key| "${folder_path(key)}/reactions"

# ── tests
# The paths each builder makes, under the users' folders and a
# conversation's folder.
## The key of `path`, a conversation's URL path, in the first start's
## directory.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8())
		?? crash "TranscriptFiles' tests: a path is UTF-8",
	directory: Directory.with_founder(Name.from_str("Steve") ?? crash "TranscriptFiles' tests: a name"),
}).map_ok(|found| found.key) ?? crash "TranscriptFiles' tests: a conversation's path"

expect user_folder_path(UserFolder.of(UserId.chat_owner)) == "users/1"
expect upload_total_path(UserFolder.of(UserId.chat_owner)) == "users/1/upload-bytes"
expect last_conversation_path(UserFolder.of(UserId.chat_owner)) == "users/1/last-conv"
expect {
	key = key_at("/chat/dm/1_1/plans")
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png")
			?? crash "TranscriptFiles' tests: an image's name"
	folder_path(key) == "chat/dm/1_1/plans"
		and transcript_path(key) == "chat/dm/1_1/plans/transcript"
		and reactions_path(key) == "chat/dm/1_1/plans/reactions"
		and uploads_folder_path(key) == "chat/dm/1_1/plans/uploads"
		and uploaded_image_path(key, image) == "chat/dm/1_1/plans/uploads/${"0a".repeat(16)}.png"
}

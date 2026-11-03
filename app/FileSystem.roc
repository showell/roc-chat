## This module is the chat's only way to its files: the one module that
## calls the host's file primitives (platform/Host.roc). Each function turns
## domain values into a path and calls one or two primitives, so the chat's
## rules are here and the host's stay general.
##
## Callers never pass a path. A path is built here from a typed key
## (`ConversationKey`, whose parts are the layout's one home), so no caller
## can name a file outside the layout.
##
## The transcript's types are `Transcript`'s making. A read answers a whole
## `Utf8Transcript`, untrusted until `Transcript.decode` reads it, and an
## append takes one message's `Utf8TranscriptMessage`, which only
## `Transcript` makes.
##
## Every failure is named (`Fault`): `Missing` (no such file yet),
## `AlreadyExists` (a name taken), and the host's own, passed on as it said
## them (`NotUtf8`, `PathRefused`, `MissingDirectory`, `Failed`). Each
## function answers only the ones it can meet. Every one but `Missing` is a
## bug or a broken disk, and the caller answers it loudly, in `fault_words`.
##
## A conversation's uploaded images are kept in its folder, under
## `uploads/`, each by its own name (`UploadedImage`), as bytes.
##
## A user's own facts are kept in their folder (`UserFolder`), one small
## file per fact: their upload total (`UploadTotal`) is `upload-bytes`.
import pf.Host
import ConversationKey
import Transcript
import UploadTotal
import UploadedImage
import UserFolder

FileSystem :: [].{

	## Every failure a function here answers, as `fault_words` takes it.
	Fault : [
		Missing,
		AlreadyExists,
		NotUtf8,
		PathRefused,
		MissingDirectory,
		Failed,
	]

	## What the file system answered, in words for a refusal. The host's
	## log says which file, and why.
	fault_words : FileSystem.Fault -> Str
	fault_words = |fault| "The file system answered ${fault_name(fault)}."

	## A conversation's transcript, the whole file, unchecked; unless there
	## is none yet (`Missing`), or the host's read failed.
	read_transcript! : ConversationKey => Try(
		Transcript.Utf8Transcript,
		[
			Missing,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	read_transcript! = |key| {
		read = Host.read_utf8_bytes_from_file!(transcript_path(key))
		match read.status {
			Found => Ok(Transcript.Utf8Transcript.unchecked_from_file(read.bytes))
			Missing => Err(Missing)
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## One message's record, added at the end of its conversation's
	## transcript: the conversation's folder made as needed, then the record
	## appended (the file made when it is the first); unless the host
	## refused.
	append_message! : ConversationKey,
	Transcript.Utf8TranscriptMessage => Try(
		{},
		[
			MissingDirectory,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	append_message! = |key, record| {
		make_folder!(folder_path(key))?
		match Host.append_utf8_bytes_to_file!(transcript_path(key), record.to_utf8_bytes()) {
			Appended => Ok({})
			MissingDirectory => Err(MissingDirectory)
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## An uploaded image's bytes, kept in its conversation's uploads folder
	## under its name, the folders made as needed; unless the host refused.
	## A name already there is `AlreadyExists`, and nothing is changed.
	store_uploaded_image! : ConversationKey,
	{ image : UploadedImage, bytes : List(U8) } => Try(
		{},
		[
			AlreadyExists,
			MissingDirectory,
			PathRefused,
			Failed,
		],
	)
	store_uploaded_image! = |key, { image, bytes }| {
		make_folder!(uploads_folder_path(key))?
		match Host.create_file_with_binary_bytes_unless_it_exists!(uploaded_image_path(key, image), bytes) {
			Created => Ok({})
			AlreadyExists => Err(AlreadyExists)
			MissingDirectory => Err(MissingDirectory)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## An uploaded image's bytes, as kept; unless the conversation has no
	## image of its name (`Missing`), or the host's read failed.
	read_uploaded_image! : ConversationKey,
	UploadedImage => Try(
		List(U8),
		[
			Missing,
			PathRefused,
			Failed,
		],
	)
	read_uploaded_image! = |key, image| {
		read = Host.read_binary_bytes_from_file!(uploaded_image_path(key, image))
		match read.status {
			Found => Ok(read.bytes)
			Missing => Err(Missing)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## A user's upload total, as their folder keeps it, read by
	## `UploadTotal.from_file`; unless the host's read failed.
	read_upload_total! : UserFolder => Try(
		UploadTotal,
		[
			NotANumber,
			NotUtf8,
			PathRefused,
			Failed,
		],
	)
	read_upload_total! = |folder| {
		read = Host.read_utf8_bytes_from_file!(upload_total_path(folder))
		match read.status {
			Found => UploadTotal.from_file(Kept(read.bytes))
			Missing => UploadTotal.from_file(NoFile)
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## A user's upload total, written whole over the one before, their folder
	## made as needed; unless the host refused, and then the file is as it
	## was.
	replace_upload_total! : UserFolder,
	UploadTotal => Try(
		{},
		[
			MissingDirectory,
			PathRefused,
			Failed,
		],
	)
	replace_upload_total! = |folder, total| {
		make_folder!(user_folder_path(folder))?
		match Host.replace_file_with_utf8_bytes_atomically!(upload_total_path(folder), total.to_file()) {
			Replaced => Ok({})
			MissingDirectory => Err(MissingDirectory)
			NotUtf8 => crash "FileSystem.replace_upload_total!: a total's digits are UTF-8"
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}
}

## A user's folder: its parts.
user_folder_path : UserFolder -> Str
user_folder_path = |folder| Str.join_with(folder.parts(), "/")

## The path of a user's upload total.
upload_total_path : UserFolder -> List(U8)
upload_total_path = |folder| "${user_folder_path(folder)}/upload-bytes".to_utf8()

## The folder a conversation's uploaded images are kept in.
uploads_folder_path : ConversationKey -> Str
uploads_folder_path = |key| "${folder_path(key)}/uploads"

## The path of an uploaded image of the conversation.
uploaded_image_path : ConversationKey, UploadedImage -> List(U8)
uploaded_image_path = |key, image| "${uploads_folder_path(key)}/${image.name()}".to_utf8()

## A conversation's folder: its key's parts. Its transcript is the file
## `transcript` in it.
folder_path : ConversationKey -> Str
folder_path = |key| Str.join_with(key.parts(), "/")

## The path of the conversation's transcript.
transcript_path : ConversationKey -> List(U8)
transcript_path = |key| "${folder_path(key)}/transcript".to_utf8()

## The folder `path`, and those above it, made as needed.
make_folder! : Str => Try({}, [PathRefused, Failed])
make_folder! = |path|
	match Host.make_directory_and_its_parents!(path.to_utf8()) {
		Made => Ok({})
		PathRefused => Err(PathRefused)
		Failed => Err(Failed)
	}

## A fault, by its tag's name.
fault_name : FileSystem.Fault -> Str
fault_name = |fault|
	match fault {
		Missing => "Missing"
		AlreadyExists => "AlreadyExists"
		NotUtf8 => "NotUtf8"
		PathRefused => "PathRefused"
		MissingDirectory => "MissingDirectory"
		Failed => "Failed"
	}

# ── tests
# Every fault, in words.
expect
	[
		(Missing, "Missing"),
		(AlreadyExists, "AlreadyExists"),
		(NotUtf8, "NotUtf8"),
		(PathRefused, "PathRefused"),
		(MissingDirectory, "MissingDirectory"),
		(Failed, "Failed"),
	].all(|(fault, name)| FileSystem.fault_words(fault) == "The file system answered ${name}.")

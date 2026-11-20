## This module answers a conversation's download, which the page's `d` key
## asks for: a GET of the conversation's `/download` is a `.tar.gz` of it,
## saved as `<topic>.tar.gz`, laid out as Gopher Chat's was:
##
##     <topic>/<topic>.md                the transcript, the bytes `/raw` serves
##     <topic>/<topic>.reactions.jsonl   its reactions file, when it has one
##     <topic>/uploads/<name>            each image uploaded to it
##
## A conversation with no transcript is a 404, as its `/raw` is. A download
## is the whole conversation or nothing, so a file that can't be read, or a
## name in its uploads folder that no upload has, is a 500.
##
## The files are read and the archive built in memory (`Tar`, then `Gzip`,
## which stores rather than compresses, its CRC-32 the host's), within the
## turn. So a download
## holds at most `most_mib` of files, and one that would hold more is a
## 409, saying so, its images read only up to the one that passes it. Every
## file in the archive is dated when it was asked for, as the host says no
## file's time. It has a minute to be written (`write_grace_ms`), so a
## reader that stalls holds its connection and the archive a minute at most.
import pf.Host
import pf.Http
import ConversationKey
import ConversationRefusal
import FileFacts
import Gzip
import HttpAnswer
import PageKit
import Tar
import Timestamp
import TranscriptFiles
import UploadedImage

DownloadRoute :: [].{

	## The most MiB of files a download holds.
	most_mib : U64
	most_mib = 32

	## How much longer than the host's write time (10 s, `Limits.write_ms` in
	## host/http.zig) a download has to be written: a minute in all
	## (docs/design.md, "Pages"), so `most_mib` needs about half a MiB
	## a second. A reader slower than that is cut off at the minute.
	write_grace_ms : U32
	write_grace_ms = 50 * 1000

	## A GET of the conversation `key`'s download, its files dated `now`.
	serve_download! : { key : ConversationKey, now : Timestamp } => Http.Response
	serve_download! = |{ key, now }|
		match load_files!(key) {
			Ok(files) =>
				match Tar.archive({ files, mtime: now.to_seconds_since_epoch().to_u64_wrap() }) {
					Ok(tar) => {
						crc32 = Host.crc32_of_bytes!(tar)
						HttpAnswer.gzip_download({
							filename: "${key.topic().to_str()}.tar.gz",
							bytes: Gzip.stored_file({ bytes: tar, crc32 }),
							write_grace_ms: DownloadRoute.write_grace_ms,
						})
					}
					Err(PathTooLong(path)) => download_refusal(PathTooLong(path))
				}
			Err(why) => download_refusal(why)
		}
}

## Every reason a download is refused.
Refusal : [
	NoTranscript(ConversationKey),
	TooLarge,
	NotAnUploadName(Str),
	PathTooLong(Str),
	FileSystem(FileFacts.Fault),
]

## The most bytes of files a download holds.
most_bytes : U64
most_bytes = DownloadRoute.most_mib * 1024 * 1024

## The conversation `key`'s files, as its archive holds them; or why not.
load_files! : ConversationKey => Try(List(Tar.File), _)
load_files! = |key| {
	transcript =
		match TranscriptFiles.read_transcript!(key) {
			Ok(File(utf8)) => utf8.to_plain_text()
			Ok(NoFile) => return Err(NoTranscript(key))
			Err(fault) => return Err(FileSystem(fault))
		}
	reactions = TranscriptFiles.read_reactions_file!(key) ? |fault| FileSystem(fault)
	images =
		match TranscriptFiles.list_uploaded_images!(key) {
			Ok(listed) => listed
			Err(NotAnUploadName(name)) => return Err(NotAnUploadName(name))
			Err(NotUtf8) => return Err(FileSystem(NotUtf8))
			Err(PathRefused) => return Err(FileSystem(PathRefused))
			Err(Failed) => return Err(FileSystem(Failed))
		}
	var $kept = []
	var $total = transcript.len() + reactions_size(reactions)
	for image in images {
		bytes = TranscriptFiles.read_uploaded_image!(key, image) ? |fault| FileSystem(fault)
		$total = $total + bytes.len()
		if $total > most_bytes {
			return Err(TooLarge)
		} else {
			$kept = $kept.append((image, bytes))
		}
	}
	if $total > most_bytes {
		Err(TooLarge)
	} else {
		Ok(
			files_of({
				topic: key.topic().to_str(),
				transcript,
				reactions,
				images: $kept,
			}),
		)
	}
}

## The size of a reactions file, none when there is none.
reactions_size : [NoFile, File(List(U8))] -> U64
reactions_size = |reactions|
	match reactions {
		File(bytes) => bytes.len()
		NoFile => 0
	}

## A conversation's archive's files: its transcript, its reactions file
## when it has one, and its images, each under the folder `topic`.
files_of : {
	topic : Str,
	transcript : List(U8),
	reactions : [NoFile, File(List(U8))],
	images : List((UploadedImage, List(U8))),
} -> List(Tar.File)
files_of = |{ topic, transcript, reactions, images }| {
	reactions_files =
		match reactions {
			File(bytes) => [{ path: "${topic}/${topic}.reactions.jsonl", bytes }]
			NoFile => []
		}
	image_files = images.map(|(image, bytes)| { path: "${topic}/uploads/${image.name()}", bytes })
	[
		[{ path: "${topic}/${topic}.md", bytes: transcript }],
		reactions_files,
		image_files,
	].join()
}

## A refused download, as a page saying why.
download_refusal : Refusal -> Http.Response
download_refusal = |why|
	match why {
		NoTranscript(key) => conversation_refusal(NoSuchConversation(key))
		FileSystem(fault) => conversation_refusal(FileSystem(fault))
		TooLarge =>
			HttpAnswer.page(
				409,
				PageKit.notice({
					title: "Too large",
					text: "This conversation's download would hold more than ${DownloadRoute.most_mib.to_str()} MiB of files.",
				}),
			)
		NotAnUploadName(name) =>
			download_failure("The conversation's uploads folder holds ${name}, which is no upload's name.")
		PathTooLong(path) => download_failure("The path ${path} is too long for a tar header.")
	}

## The conversation's refusal `why`, as a page.
conversation_refusal : ConversationRefusal.Cause -> Http.Response
conversation_refusal = |why| {
	notice = ConversationRefusal.notice(why)
	HttpAnswer.page(notice.status, PageKit.notice(notice.words))
}

## A download the server couldn't build, saying why: a 500.
download_failure : Str -> Http.Response
download_failure = |text| HttpAnswer.page(500, PageKit.notice({ title: "Failed", text }))

# ── tests
# The archive's files: the transcript, the reactions when there are any,
# then each image, each under the topic's folder.
expect {
	image =
		UploadedImage.from_name("${"0a".repeat(16)}.png") ?? crash "DownloadRoute's tests: an image's name"
	with_all = files_of({
		topic: "plans",
		transcript: "t".to_utf8(),
		reactions: File("r".to_utf8()),
		images: [(image, "i".to_utf8())],
	})
	bare = files_of({
		topic: "plans",
		transcript: "t".to_utf8(),
		reactions: NoFile,
		images: [],
	})
	with_all
		== [
			{ path: "plans/plans.md", bytes: "t".to_utf8() },
			{ path: "plans/plans.reactions.jsonl", bytes: "r".to_utf8() },
			{ path: "plans/uploads/${"0a".repeat(16)}.png", bytes: "i".to_utf8() },
		]
		and bare == [{ path: "plans/plans.md", bytes: "t".to_utf8() }]
}
# The cap, its time to be written, and each refusal's status.
expect most_bytes == 33554432
expect DownloadRoute.write_grace_ms == 50_000
expect reactions_size(File("abc".to_utf8())) == 3 and reactions_size(NoFile) == 0
expect
	[
		(TooLarge, 409),
		(NotAnUploadName("x"), 500),
		(PathTooLong("p"), 500),
		(FileSystem(Failed), 500),
	].all(|(why, status)| download_refusal(why).status == status)

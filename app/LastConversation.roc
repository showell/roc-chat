## This module is a human's last conversation: the one whose page they last
## opened, so that `/` takes them back to it, as the Zig chat's `last-conv`
## did. `TranscriptFiles` keeps it in the human's own folder (`UserFolder`) as
## the file `last-conv`, which holds the conversation's URL path, bare:
## `/chat/channel/general/roc-chat`. `ResumeRoute` writes it when the page
## is opened and reads it at `/`.
##
## The file is read against the directory as it is now, so it takes the
## human back only to a conversation they may still read. A human with no
## file, a file that names no conversation's page, and a place they may no
## longer read (a channel they left, or one removed) each go to Browse.
import Access
import ConversationKey
import Directory
import FactFile
import SignedIn
import UnvalidatedString

LastConversation :: ConversationKey.{

	## The conversation `key`, as the last one opened.
	of : ConversationKey -> LastConversation
	of = |key| LastConversation.(key)

	## The conversation as its file keeps it: its page's URL path.
	to_file : LastConversation -> List(U8)
	to_file = |LastConversation.(key)| key.url_path(Page).to_utf8()

	## Where `/` sends `acting`, whose file is `file`, in `directory`: the
	## page of the conversation the file names, when `acting` may read it;
	## else Browse.
	way_in : {
		file : [NoFile, File(List(U8))],
		acting : SignedIn,
		directory : Directory,
	} -> Str
	way_in = |{ file, acting, directory }|
		match readable_key({ file, acting, directory }) {
			Ok(key) => key.url_path(Page)
			Err(NoFile) => ConversationKey.browse_path
			Err(NotAConversation) => ConversationKey.browse_path
			Err(NotReadable) => ConversationKey.browse_path
		}
}

## The conversation `file` names, when `acting` may read it in `directory`;
## else why not: no file, a file that names no conversation's page, or one
## `acting` may not read.
readable_key : {
	file : [NoFile, File(List(U8))],
	acting : SignedIn,
	directory : Directory,
} -> Try(ConversationKey, [NoFile, NotAConversation, NotReadable])
readable_key = |{ file, acting, directory }| {
	bytes =
		match file {
			NoFile => return Err(NoFile)
			File(held) => FactFile.word_from_file(held)
		}
	path = UnvalidatedString.from_utf8(bytes) ? |NotUtf8| NotAConversation
	found = ConversationKey.from_url_path({ path, directory }) ? |_| NotAConversation
	match found.resource {
		Page => {}
		Stream => return Err(NotAConversation)
		Send => return Err(NotAConversation)
		Upload => return Err(NotAConversation)
		React => return Err(NotAConversation)
		UploadedImage(_) => return Err(NotAConversation)
		Raw => return Err(NotAConversation)
	}
	Access.check({
		acting,
		place: found.key.place(),
		directory,
		act: Read,
	}) ? |_| NotReadable
	Ok(found.key)
}

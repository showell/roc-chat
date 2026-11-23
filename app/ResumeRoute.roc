## This module resumes a human where they left off. Opening a
## conversation's page records it as their last conversation
## (`LastConversation`, a file in their own folder), and `/`, the way in,
## sends them back to it while they may still read it, and to Browse
## otherwise. Anyone else is sent to Browse, which sends someone with no
## session to sign in and answers a key with its refusal.
import pf.Http
import ConversationKey
import Directory
import FileFacts
import HttpAnswer
import LastConversation
import PageKit
import SignedIn
import TranscriptFiles
import UserFolder

ResumeRoute :: [].{

	## The answer to `/` for `actor`: a 303 to the conversation a human
	## signed in by their own session last opened, while they may read it in
	## `directory`; else a 303 to Browse.
	answer_way_in! : { actor : SignedIn.Actor, directory : Directory } => Http.Response
	answer_way_in! = |{ actor, directory }|
		match actor {
			Anonymous => browse_redirect
			SignedIn(acting) =>
				match acting.human_in_session() {
					Err(ByApiKey) => browse_redirect
					Err(Agent(_)) => browse_redirect
					Ok(human) => {
						folder = UserFolder.of(human.as_user().id())
						match TranscriptFiles.read_last_conversation!(folder) {
							Ok(file) => HttpAnswer.see_other(
								LastConversation.way_in({ file, acting, directory }),
							)
							Err(fault) =>
								HttpAnswer.page(
									500,
									PageKit.notice({
										title: "Failed",
										text: FileFacts.fault_words(fault),
									}),
								)
						}
					}
				}
		}

	## `key` recorded as the last conversation `acting` opened, when `acting`
	## is a human by their own session; the file is written only when it
	## names another conversation, or there is none. Unless the file system
	## failed.
	record_opened! : { key : ConversationKey, acting : SignedIn } => Try(
		{},
		[FileSystem(FileFacts.Fault)],
	)
	record_opened! = |{ key, acting }|
		match acting.human_in_session() {
			Err(ByApiKey) => Ok({})
			Err(Agent(_)) => Ok({})
			Ok(human) => {
				folder = UserFolder.of(human.as_user().id())
				last = LastConversation.of(key)
				held = TranscriptFiles.read_last_conversation!(folder) ? |fault| FileSystem(fault)
				if held == File(last.to_file()) {
					Ok({})
				} else {
					TranscriptFiles.replace_last_conversation!(folder, last)
						? |fault| FileSystem(fault)
					Ok({})
				}
			}
		}
}

## A 303 to Browse, which shows someone signed in their page and sends
## anyone else to sign in.
browse_redirect : Http.Response
browse_redirect = HttpAnswer.see_other(ConversationKey.browse_path)

# ── tests
expect
	browse_redirect.status == 303
		and browse_redirect.headers == [{ name: "location".to_utf8(), value: "/chat".to_utf8() }]

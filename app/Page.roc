## This module stands in for the pages app/main.roc builds, until its
## imports move to the page modules themselves: the pages are in
## `ConversationPage` and `PageKit` now, and this module only names them.
## It goes once main.roc imports those two (another lane is splitting
## main.roc), and nothing else may import it.
import Conversation
import ConversationKey
import ConversationPage
import PageKit
import SignedIn
import TrustedHtml
import Users

Page :: [].{

	## `PageKit.invites_path`.
	invites_path : Str
	invites_path = PageKit.invites_path

	## `ConversationPage.conversation`.
	conversation : {
		conversation : Conversation,
		key : ConversationKey,
		viewer : SignedIn,
		users : Users,
	} -> TrustedHtml
	conversation = |page| ConversationPage.conversation(page)

	## `PageKit.refusal`.
	refusal : Str -> TrustedHtml
	refusal = |why| PageKit.refusal(why)

	## `PageKit.notice`.
	notice : { title : Str, text : Str } -> TrustedHtml
	notice = |said| PageKit.notice(said)

	## `PageKit.not_found`.
	not_found : TrustedHtml
	not_found = PageKit.not_found
}

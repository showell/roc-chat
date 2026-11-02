## **THE ROUTES**: which answer a request's method and path ask for, a pure
## decision, so its tests reach every route. The host routes nothing.
##
##     GET  /chat/channel/<channel>/<topic>    the conversation's page
##     GET  /chat/dm/<pair>/<topic>
##     POST the same paths, a form field `markdown`: a message appended
##     GET  /chat/assets/compose.js            the page's script
##
## A conversation's path is `ConversationKey`'s to read, the layout's one
## home, and the script's is `ComposeScript`'s; a path that names no
## conversation the directory holds is not found.
import ComposeScript
import ConversationKey
import Directory
import UnvalidatedString

Route :: [].{

	## What a request asks for.
	Choice : [
		ShowConversation(ConversationKey),
		AppendToConversation(ConversationKey),
		ServeComposeScript,
		NotFound,
		MethodNotAllowed([GetAndPost, GetOnly]),
	]

	## **THE ROUTE FOR `method` AND `path`**, as the host handed them, each
	## place looked up in `directory`.
	choose : {
		method : List(U8),
		path : List(U8),
		directory : Directory,
	} -> Route.Choice
	choose = |
		{
			method,
			path,
			directory,
		},
	|
		if (path == ComposeScript.url_path.to_utf8())
			if (method == "GET".to_utf8()) ServeComposeScript else MethodNotAllowed(GetOnly)
		else {
			key =
				match UnvalidatedString.from_utf8(path) {
					Ok(unchecked) => ConversationKey.from_url_path({ path: unchecked, directory })
					Err(NotUtf8) => Err(NotAConversationPath)
				}
			match key {
				Ok(found) =>
					if (method == "GET".to_utf8())
						ShowConversation(found)
					else if (method == "POST".to_utf8())
						AppendToConversation(found)
					else
						MethodNotAllowed(GetAndPost)
				Err(_) => NotFound
			}
		}
}

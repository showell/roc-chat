## **THE ROUTES**: which answer a request's method and path ask for, a pure
## decision, so its tests reach every route. The host routes nothing.
##
##     GET  /chat/channel/<channel>/<topic>    the conversation's page
##     GET  /chat/dm/<pair>/<topic>
##     POST the same paths, a form field `markdown`: a message appended
##     GET  the same paths and `/stream`       the conversation's stream
##     POST the same paths and `/upload`       an image uploaded to it
##     GET  the same paths, `/uploads/<name>`  an image uploaded to it
##     GET  /chat/assets/compose.js            the page's script
##
## A conversation's path is `ConversationKey`'s to read, the layout's one
## home, and the script's is `ComposeScript`'s; a path that names no
## conversation the directory holds is not found.
import ComposeScript
import ConversationKey
import Directory
import UnvalidatedString
import UploadedImage

Route :: [].{

	## What a request asks for.
	Choice : [
		ShowConversation(ConversationKey),
		AppendToConversation(ConversationKey),
		OpenConversationStream(ConversationKey),
		UploadToConversation(ConversationKey),
		ServeUploadedImage({ key : ConversationKey, image : UploadedImage }),
		ServeComposeScript,
		NotFound,
		MethodNotAllowed([GetAndPost, GetOnly, PostOnly]),
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
		else
			match UnvalidatedString.from_utf8(path) {
				Ok(unchecked) =>
					conversation_choice({
						method,
						path: unchecked,
						directory,
					})
				Err(NotUtf8) => NotFound
			}
}

## The route for `method` and a conversation's `path`: its page, its
## stream, its upload or one of its uploaded images, each tried in turn.
conversation_choice : {
	method : List(U8),
	path : UnvalidatedString,
	directory : Directory,
} -> Route.Choice
conversation_choice = |
	{
		method,
		path,
		directory,
	},
| {
	is_get = method == "GET".to_utf8()
	is_post = method == "POST".to_utf8()
	match ConversationKey.from_url_path({ path, directory }) {
		Ok(key) =>
			if (is_get)
				ShowConversation(key)
			else if (is_post)
				AppendToConversation(key)
			else
				MethodNotAllowed(GetAndPost)
		Err(_) =>
			match ConversationKey.from_stream_url_path({ path, directory }) {
				Ok(key) => if (is_get) OpenConversationStream(key) else MethodNotAllowed(GetOnly)
				Err(_) =>
					match ConversationKey.from_upload_url_path({ path, directory }) {
						Ok(key) => if (is_post) UploadToConversation(key) else MethodNotAllowed(PostOnly)
						Err(_) =>
							match ConversationKey.from_uploaded_image_url_path({ path, directory }) {
								Ok(found) => if (is_get) ServeUploadedImage(found) else MethodNotAllowed(GetOnly)
								Err(_) => NotFound
							}
					}
			}
	}
}

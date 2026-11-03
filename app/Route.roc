## **THE ROUTES**: which answer a request's method and path ask for, a pure
## decision, so its tests reach every route. The host routes nothing.
##
##     GET  /chat/channel/<channel>/<topic>    the conversation's page
##     GET  /chat/dm/<pair>/<topic>
##     POST the same paths, a form field `markdown`: a message appended
##     GET  the same paths and `/stream`       the conversation's stream
##     POST the same paths and `/upload`       an image uploaded to it
##     GET  the same paths, `/uploads/<name>`  an image uploaded to it
##     GET  /chat/assets/palette.js            the pages' scripts
##     GET  /chat/assets/chrome.js
##     GET  /chat/assets/compose.js
##     GET  /chat/assets/feed.js
##
## A conversation's path is `ConversationKey`'s to read, the layout's one
## home, and each script's is its own module's (`PaletteScript` and the
## rest); a path that names no conversation the directory holds is not
## found.
import ChromeScript
import ComposeScript
import ConversationKey
import Directory
import FeedScript
import PaletteScript
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
		ServeScript(Route.Script),
		NotFound,
		MethodNotAllowed([GetAndPost, GetOnly, PostOnly]),
	]

	## A script the pages load, each served from its own module.
	Script : [
		Palette,
		Chrome,
		Compose,
		Feed,
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
		match scripts.find_first(|script| path == script_url_path(script).to_utf8()) {
			Ok(script) => if (method == "GET".to_utf8()) ServeScript(script) else MethodNotAllowed(GetOnly)
			Err(NotFound) =>
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
}

## Every script the pages load.
scripts : List(Route.Script)
scripts = [
	Palette,
	Chrome,
	Compose,
	Feed,
]

## Where `script` is served.
script_url_path : Route.Script -> Str
script_url_path = |script|
	match script {
		Palette => PaletteScript.url_path
		Chrome => ChromeScript.url_path
		Compose => ComposeScript.url_path
		Feed => FeedScript.url_path
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

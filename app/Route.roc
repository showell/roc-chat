## This module decides which answer a request's method and path ask for.
## It is a pure decision, so its tests (`RouteSpec`) reach every route, and
## the host routes nothing.
##
##     GET  /chat/channel/<channel>/<topic>    the conversation's page
##     GET  /chat/dm/<pair>/<topic>
##     POST the same paths, a form field `markdown`: a message appended
##     POST the same paths and `/send`, the same: the script's send
##     GET  the same paths and `/stream`       the conversation's stream
##     POST the same paths and `/upload`       an image uploaded to it
##     GET  the same paths, `/uploads/<name>`  an image uploaded to it
##     GET  /chat/assets/palette.js            the pages' scripts
##     GET  /chat/assets/chrome.js
##     GET  /chat/assets/compose.js
##     GET  /chat/assets/feed.js
##
## A conversation's path is `ConversationKey`'s to read, which says which
## of its resources the path names, and each script's is `Script`'s. A
## path that names no conversation the directory holds is not found.
import ConversationKey
import Directory
import Script
import UnvalidatedString
import UploadedImage

Route :: [].{

	## What a request asks for.
	Choice : [
		ShowConversation(ConversationKey),
		AppendToConversation(ConversationKey),
		SendToConversation(ConversationKey),
		OpenConversationStream(ConversationKey),
		UploadToConversation(ConversationKey),
		ServeUploadedImage({ key : ConversationKey, image : UploadedImage }),
		ServeScript(Script),
		NotFound,
		MethodNotAllowed([GetAndPost, GetOnly, PostOnly]),
	]

	## The route for `method` and `path`, as the host handed them, each
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
	| {
		asked = method_of(method)
		match Script.all_scripts.find_first(|script| path == script.url_path().to_utf8()) {
			Ok(script) =>
				match asked {
					Get => ServeScript(script)
					Post | Other => MethodNotAllowed(GetOnly)
				}
			Err(NotFound) =>
				match UnvalidatedString.from_utf8(path) {
					Ok(unchecked) =>
						match ConversationKey.from_url_path({ path: unchecked, directory }) {
							Ok(found) => conversation_choice({
								key: found.key,
								resource: found.resource,
								method: asked,
							})
							Err(_) => NotFound
						}
					Err(NotUtf8) => NotFound
				}
		}
	}
}

## The method the host handed, as a route takes it: GET, POST, or any other
## (a method is case-sensitive, so `get` is another).
method_of : List(U8) -> [Get, Post, Other]
method_of = |method|
	if (method == "GET".to_utf8())
		Get
	else if (method == "POST".to_utf8())
		Post
	else
		Other

## The route for `method` and the conversation `key`'s `resource`.
conversation_choice : {
	key : ConversationKey,
	resource : ConversationKey.Resource,
	method : [Get, Post, Other],
} -> Route.Choice
conversation_choice = |
	{
		key,
		resource,
		method,
	},
|
	match (resource, method) {
		(Page, Get) => ShowConversation(key)
		(Page, Post) => AppendToConversation(key)
		(Page, Other) => MethodNotAllowed(GetAndPost)
		(Stream, Get) => OpenConversationStream(key)
		(Stream, _) => MethodNotAllowed(GetOnly)
		(Send, Post) => SendToConversation(key)
		(Send, _) => MethodNotAllowed(PostOnly)
		(Upload, Post) => UploadToConversation(key)
		(Upload, _) => MethodNotAllowed(PostOnly)
		(UploadedImage(image), Get) => ServeUploadedImage({ key, image })
		(UploadedImage(_), _) => MethodNotAllowed(GetOnly)
	}

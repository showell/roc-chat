## THE ROC CHAT'S ROUTE TABLE: which module answers which request. The
## routes' work is in their modules: SignIn.roc's sign-in, Conversations.roc's
## conversations, Agents.roc's agents and API keys; the store is Store.roc's, the only module that names a
## file. Beside them, a hello page (rendered by roc-markdown, the chat's
## dialect) and the chat client's scripts (`serve_script!`).
app [handle!] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import pf.Chat
import pf.Host
import md.Md
import Agents
import Conversations
import SignIn

## The auth core, imported for its expects until a route uses it: with
## SignIn's and Conversations' imports, ConvKey and AuditCodec reach every
## one of its modules.
import ConvKey
import AuditCodec

handle! : Chat.Request => Chat.Answer
handle! = |req|
	if req.path == Str.to_utf8("/") {
		if req.method == Get or req.method == Head {
			hello
		} else {
			Chat.not_allowed(Get)
		}
	} else if req.path == Str.to_utf8("/login") {
		if req.method == Get SignIn.login!({}) else Chat.not_allowed(Get)
	} else if req.path == Str.to_utf8("/login/github") {
		if req.method == Get SignIn.callback!(req) else Chat.not_allowed(Get)
	} else if req.path == Str.to_utf8("/login/name") {
		if req.method == Post SignIn.name!({}) else Chat.not_allowed(Post)
	} else if req.path == Str.to_utf8("/me") {
		if req.method == Get SignIn.me!({}) else Chat.not_allowed(Get)
	} else {
		match (Conversations.route(req.path), Agents.route(req.path)) {
			(Ok(route), _) => Conversations.answer!(req, route)
			(_, Ok(route)) => Agents.answer!(req, route)
			(Err(_), Err(_)) =>
				match script_name(req.path) {
					Ok(name) =>
						match Host.serve_script!(name) {
							Served => Chat.answered
							Missing => Chat.not_found
						}
					Err(NotAScript) => Chat.not_found
				}
		}
	}

## The hello page, never cached.
hello : Chat.Answer
hello = {
	page = List.join([
		Str.to_utf8("<!doctype html>\n<title>roc-chat</title>\n"),
		Md.render_trusted(Str.to_utf8("**Hello** from roc-chat. Its pages are not here yet: sign in at `/login`, and the conversations are at `/conversations`.")),
	])
	Chat.respond(200, { content_type: Chat.html, body: page })
		|> Chat.with_header("cache-control", Str.to_utf8("no-store"))
}

## `/<name>.js`, one part: the script's name.
script_name : List(U8) -> Try(List(U8), [NotAScript])
script_name = |path| {
	name = List.drop_first(path, 1)
	if List.starts_with(path, ['/']) and List.ends_with(name, Str.to_utf8(".js")) and !List.contains(name, '/') {
		Ok(name)
	} else {
		Err(NotAScript)
	}
}

expect script_name(Str.to_utf8("/chat.js")) == Ok(Str.to_utf8("chat.js"))
expect script_name(Str.to_utf8("/a/chat.js")) == Err(NotAScript)
expect script_name(Str.to_utf8("/chat.css")) == Err(NotAScript)

## THE ROC CHAT'S ROUTE TABLE: which module answers which request. The
## routes' work is in their modules: SignIn.roc's sign-in, Topics.roc's
## channel topics, OneStream.roc's one stream per agent, Agents.roc's agents and API keys, Channels.roc's channels
## (an admin's), Pages.roc's pages, Browse.roc's, TopicPage.roc's and UsersPage.roc's (the
## browser client's); the store is Store.roc's, the only module that names a
## file. Beside them, the chat client's scripts (`serve_script!`); the
## hello page at `/` is SignIn's, as it says who is signed in.
app [handle!] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import pf.Chat
import pf.Host
import Agents
import Browse
import Channels
import ChannelLayout
import MessageRef
import Html
import HumanInvites
import Origin
import Pages
import SignIn
import OneStream
import RecentPage
import TopicPage
import UsersPage
import Topics
import Wire

handle! : Chat.Request => Chat.Answer
handle! = |req| {
	sent = {
		method: req.method,
		path: req.path,
		origin: Host.read_header!(Str.to_utf8("origin")),
		fetch_site: Host.read_header!(Str.to_utf8("sec-fetch-site")),
		has_cookie: !List.is_empty(Host.read_header!(Str.to_utf8("cookie"))),
		has_key: !List.is_empty(Host.read_header!(Str.to_utf8("authorization"))),
	}
	# The configured origin is read only where a write with a cookie asks
	# for it (a server without sign-in's config has none to read).
	configured = if (sent.has_cookie and !List.is_empty(sent.origin)) Host.read_config!(Origin) else []
	match Origin.check(sent, configured) {
		CrossOrigin => Wire.refused(403, "this write did not come from the chat's own pages")
		Allowed => route!(req)
	}
}

## The request, to its route's module.
route! : Chat.Request => Chat.Answer
route! = |req|
	if req.path == "/".to_utf8() {
		if req.method == Get or req.method == Head {
			SignIn.serve_hello!({})
		} else {
			Chat.not_allowed(Get)
		}
	} else if req.path == "/login".to_utf8() {
		if (req.method == Get) SignIn.login!({}) else Chat.not_allowed(Get)
	} else if req.path == "/login/github".to_utf8() {
		if (req.method == Get) SignIn.serve_callback!(req) else Chat.not_allowed(Get)
	} else if req.path == "/login/name".to_utf8() {
		if (req.method == Post) SignIn.serve_name!({}) else Chat.not_allowed(Post)
	} else if req.path == "/logout".to_utf8() {
		if (req.method == Post) SignIn.serve_logout!({}) else Chat.not_allowed(Post)
	} else if req.path == "/me".to_utf8() {
		if (req.method == Get) SignIn.serve_me!({}) else Chat.not_allowed(Get)
	} else if req.path == "/stream".to_utf8() {
		if (req.method == Get) OneStream.serve!({}) else Chat.not_allowed(Get)
	} else if HumanInvites.route(req.path).is_ok() {
		match HumanInvites.route(req.path) {
			Ok(r) => HumanInvites.answer!(req, r)
			Err(NotHumanInvites) => Chat.not_found
		}
	} else if Browse.route(req.path).is_ok() {
		match Browse.route(req.path) {
			Ok(r) => Browse.answer!(req, r)
			Err(NotBrowse) => Chat.not_found
		}
	} else if RecentPage.route(req.path).is_ok() {
		match RecentPage.route(req.path) {
			Ok(r) => RecentPage.answer!(req, r)
			Err(NotRecent) => Chat.not_found
		}
	} else if UsersPage.route(req.path).is_ok() {
		match UsersPage.route(req.path) {
			Ok(r) => UsersPage.answer!(req, r)
			Err(NotUsers) => Chat.not_found
		}
	} else if TopicPage.route(req.path).is_ok() {
		match TopicPage.route(req.path) {
			Ok(r) => TopicPage.answer!(req, r)
			Err(NotATopicPage) => Chat.not_found
		}
	} else if Topics.route(req.path).is_ok() {
		match Topics.route(req.path) {
			Ok(r) => Topics.answer!(req, r)
			Err(NotTopics) => Chat.not_found
		}
	} else {
		match (
			Agents.route(req.path),
			Channels.route(req.path),
			Pages.route(req.path),
		) {
			(
				Ok(route),
				_,
				_,
			) => Agents.answer!(req, route)
			(
				_,
				Ok(route),
				_,
			) => Channels.answer!(req, route)
			# The pages.
			(
				_,
				_,
				Ok(page),
			) => Pages.answer!(req, page)
			(
				Err(_),
				Err(_),
				Err(_),
			) =>
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

## `/<name>.js`, one part: the script's name.
script_name : List(U8) -> Try(List(U8), [NotAScript])
script_name = |path| {
	name = path.drop_first(1)
	if path.starts_with(['/']) and name.ends_with(".js".to_utf8()) and !name.contains('/') {
		Ok(name)
	} else {
		Err(NotAScript)
	}
}

expect script_name("/chat.js".to_utf8()) == Ok("chat.js".to_utf8())
expect script_name("/a/chat.js".to_utf8()) == Err(NotAScript)
expect script_name("/chat.css".to_utf8()) == Err(NotAScript)

## THE ROC CHAT'S ROUTE TABLE: which module answers which request. The
## routes' work is in their modules (SignIn.roc's sign-in; the store is
## Store.roc's, the only module that names a file). For now, beside
## sign-in: a hello page (rendered by roc-markdown, the chat's dialect), a
## POST echoed (the body through `read_body!`, a header through
## `read_header!`), and the chat client's scripts (`serve_script!`).
## `/stub/` is a stub of the bus (`serve_stub!`) and `/stub/notes` one of
## the files, which step 6 replaces. The chat itself comes after.
app [handle!] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import pf.Chat
import pf.Host
import pf.Sse
import md.Md
import SignIn

## The auth core, imported for its expects until a route uses it: with
## SignIn's imports, ConvKey and AuditCodec reach every one of its modules.
import ConvKey
import AuditCodec

## The most of a body `/echo` reads; the host's own cap is larger, so a body
## between the two is the Roc's to refuse (through the host's 413).
echo_most : U64
echo_most = 32 * 1024

handle! : Chat.Request => Chat.Answer
handle! = |req|
	if req.path == Str.to_utf8("/") {
		if req.method == Get or req.method == Head {
			hello
		} else {
			Chat.not_allowed(Get)
		}
	} else if req.path == Str.to_utf8("/echo") {
		if req.method == Post {
			echo!(req)
		} else {
			Chat.not_allowed(Post)
		}
	} else if req.path == Str.to_utf8("/stub/notes") {
		notes!(req)
	} else if req.path == Str.to_utf8("/login") {
		if req.method == Get SignIn.login!({}) else Chat.not_allowed(Get)
	} else if req.path == Str.to_utf8("/login/github") {
		if req.method == Get SignIn.callback!(req) else Chat.not_allowed(Get)
	} else if req.path == Str.to_utf8("/login/name") {
		if req.method == Post SignIn.name!({}) else Chat.not_allowed(Post)
	} else if req.path == Str.to_utf8("/me") {
		if req.method == Get SignIn.me!({}) else Chat.not_allowed(Get)
	} else if List.starts_with(req.path, stub_prefix) {
		match stub_route(req.path) {
			Ok(route) => serve_stub!(req, route)
			Err(NotAStub) => Chat.not_found
		}
	} else {
		match script_name(req.path) {
			Ok(name) =>
				match Host.serve_script!(name) {
					Served => Chat.answered
					Missing => Chat.not_found
				}
			Err(NotAScript) => Chat.not_found
		}
	}

## The hello page, never cached.
hello : Chat.Answer
hello = {
	page = List.join([
		Str.to_utf8("<!doctype html>\n<title>roc-chat</title>\n"),
		Md.render_trusted(Str.to_utf8("**Hello** from roc-chat. The chat is not here yet.")),
	])
	Chat.respond(200, { content_type: Chat.html, body: page })
		|> Chat.with_header("cache-control", Str.to_utf8("no-store"))
}

## The request said back: its path, its `x-probe` header's values, and its
## body.
echo! : Chat.Request => Chat.Answer
echo! = |req| {
	got = Host.read_body!(echo_most)
	match got.status {
		Answered => Chat.answered
		Read => {
			probes = Host.read_header!(Str.to_utf8("x-probe"))
			Chat.plain(
				List.join([
					Str.to_utf8("path "),
					req.path,
					Str.to_utf8("\nx-probe "),
					List.join(List.map(probes, |p| List.concat(p, [' ']))),
					Str.to_utf8("\nbody ${U64.to_str(List.len(got.bytes))} bytes\n"),
					got.bytes,
				]),
			)
		}
	}
}

## **A STUB OF THE FILES, WHICH STEP 6 REPLACES**: a POST's body appended
## to one file, its size after said back; a GET, the file. It proves
## `append!` and `read!` through the seam, and nothing more.
notes_path : List(U8)
notes_path = Str.to_utf8("stub/notes.txt")

notes! : Chat.Request => Chat.Answer
notes! = |req|
	if req.method == Post {
		got = Host.read_body!(echo_most)
		match got.status {
			Answered => Chat.answered
			Read => {
				appended = Host.append!(notes_path, got.bytes)
				match appended.status {
					Appended => Chat.plain(Str.to_utf8("size ${U64.to_str(appended.size)}\n"))
					Failed => Chat.failed
				}
			}
		}
	} else if req.method == Get {
		read = Host.read!(notes_path)
		match read.status {
			Found => Chat.plain(read.bytes)
			Missing => Chat.not_found
			Failed => Chat.failed
		}
	} else {
		Chat.not_allowed(Get)
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

## ── A STUB OF THE BUS, UNTIL STEP 6 ──────────────────────────────────────
##
## `GET /stub/stream/<key>` streams `<key>`: its frames so far, then each
## one posted after, live. `POST /stub/post/<key>` makes its body a frame,
## keeps it and publishes it. Its frames live in the host's memory
## (`stub_append!`, `stub_read!`); step 6's chat keeps them in its store.

stub_prefix : List(U8)
stub_prefix = Str.to_utf8("/stub/")

## What a stub path asks: to stream a key, or to post to it.
StubAct : [Post, Stream]

## `/stub/stream/<key>` or `/stub/post/<key>`, `<key>` one part, not empty.
stub_route : List(U8) -> Try({ act : StubAct, key : List(U8) }, [NotAStub])
stub_route = |path| {
	rest = List.drop_first(path, List.len(stub_prefix))
	(act, key) =
		if List.starts_with(rest, Str.to_utf8("stream/")) {
			(Ok(Stream), List.drop_first(rest, 7))
		} else if List.starts_with(rest, Str.to_utf8("post/")) {
			(Ok(Post), List.drop_first(rest, 5))
		} else {
			(Err(NotAStub), [])
		}
	match act {
		Ok(a) if !List.is_empty(key) and !List.contains(key, '/') => Ok({ act: a, key })
		_ => Err(NotAStub)
	}
}

expect stub_route(Str.to_utf8("/stub/stream/k1")) == Ok({ act: Stream, key: Str.to_utf8("k1") })
expect stub_route(Str.to_utf8("/stub/post/k1")) == Ok({ act: Post, key: Str.to_utf8("k1") })
expect stub_route(Str.to_utf8("/stub/post/")) == Err(NotAStub)
expect stub_route(Str.to_utf8("/stub/post/a/b")) == Err(NotAStub)
expect stub_route(Str.to_utf8("/stub/other/k")) == Err(NotAStub)

serve_stub! : Chat.Request, { act : StubAct, key : List(U8) } => Chat.Answer
serve_stub! = |req, { act, key }|
	match act {
		Stream =>
			if req.method == Get {
				Chat.stream({ key, backlog: List.join(Host.stub_read!(key)) })
			} else {
				Chat.not_allowed(Get)
			}
		Post =>
			if req.method == Post {
				post_stub!(key)
			} else {
				Chat.not_allowed(Post)
			}
	}

## The body as `key`'s next frame, kept, then published: its id is how many
## frames `key` had.
post_stub! : List(U8) => Chat.Answer
post_stub! = |key| {
	got = Host.read_body!(echo_most)
	match got.status {
		Answered => Chat.answered
		Read => {
			id = List.len(Host.stub_read!(key))
			match Sse.frame({ name: [], data: got.bytes, id: Str.to_utf8(U64.to_str(id)) }) {
				Ok(frame) => {
					Host.stub_append!(key, frame)
					Host.publish!(key, frame)
					Chat.plain(Str.to_utf8("posted ${U64.to_str(id)}\n"))
				}
				Err(LineBreak) => Chat.respond(400, { content_type: Chat.text, body: Str.to_utf8("a CR has no place in an event\n") })
			}
		}
	}
}

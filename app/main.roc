## THE ROC CHAT, A STUB FOR NOW: it proves the seam both ways and nothing
## more. A hello page (rendered by roc-markdown, the chat's dialect), a POST
## echoed (the body through `read_body!`, a header through `read_header!`),
## and the chat client's scripts (`serve_script!`). The chat itself comes
## after the server core.
app [handle!] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import pf.Chat
import pf.Host
import md.Md
## The auth core, imported for its expects alone until the routes use it:
## ConvKey and AuditCodec between them reach every one of its modules.
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

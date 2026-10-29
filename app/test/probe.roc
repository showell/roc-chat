## THE SERVER'S PROBE, FOR ITS TESTS ONLY (host/server_test.zig): an app on
## the chat's platform with the plainest routes that drive each part of the
## host, so the server's tests say what the host does without signing in.
## Never linked into a server. The chat's own routes are tested against the
## chat (host/chat_test.zig).
##
##     GET  /                 "Hello from the probe", for the turn's tests
##     POST /echo             the request said back: its path, its `x-probe`
##                            header's values, its body (at most 32 KiB)
##     GET  /notes            the file probe/notes.txt
##     POST /notes            the body appended to it, its size after said back
##     GET  /stream/<key>     `<key>`'s frames so far, then each one posted after
##     POST /post/<key>       the body made `<key>`'s next frame, kept and published
##
## A key's frames are kept in the file probe/frames/<key>, each an SSE frame
## whose id is its place (0, 1, 2...), so a stream's backlog is that file,
## read in the turn that subscribes it.
app [handle!] { pf: platform "../../platform/main.roc" }

import pf.Chat
import pf.Host
import pf.Sse

## The most of a body `/echo` and `/post` read; the host's own cap is
## larger, so a body between the two is the Roc's to refuse (the host's 413).
echo_most : U64
echo_most = 32 * 1024

handle! : Chat.Request => Chat.Answer
handle! = |req|
	if req.path == Str.to_utf8("/") {
		if req.method == Get or req.method == Head Chat.plain(Str.to_utf8("Hello from the probe\n")) else Chat.not_allowed(Get)
	} else if req.path == Str.to_utf8("/echo") {
		if req.method == Post echo!(req) else Chat.not_allowed(Post)
	} else if req.path == Str.to_utf8("/notes") {
		notes!(req)
	} else {
		match keyed(req.path) {
			Ok(Stream(key)) => if req.method == Get stream!(key) else Chat.not_allowed(Get)
			Ok(Post(key)) => if req.method == Post post!(key) else Chat.not_allowed(Post)
			Err(NotKeyed) => Chat.not_found
		}
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

notes_path : List(U8)
notes_path = Str.to_utf8("probe/notes.txt")

## A POST's body appended to one file, its size after said back; a GET, the
## file: `append!` and `read!` through the seam.
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

## `/stream/<key>` or `/post/<key>`, `<key>` one part, not empty.
keyed : List(U8) -> Try([Stream(List(U8)), Post(List(U8))], [NotKeyed])
keyed = |path| {
	stream = Str.to_utf8("/stream/")
	post = Str.to_utf8("/post/")
	if List.starts_with(path, stream) {
		key_of(List.drop_first(path, List.len(stream))).map_ok(|k| Stream(k))
	} else if List.starts_with(path, post) {
		key_of(List.drop_first(path, List.len(post))).map_ok(|k| Post(k))
	} else {
		Err(NotKeyed)
	}
}

key_of : List(U8) -> Try(List(U8), [NotKeyed])
key_of = |key| if List.is_empty(key) or List.contains(
	key,
	'/',
) or List.contains(key, '.') Err(NotKeyed) else Ok(key)

frames_path : List(U8) -> List(U8)
frames_path = |key| List.concat(Str.to_utf8("probe/frames/"), key)

## A key's frames so far: the file, or none.
frames! : List(U8) => Try(List(U8), [Failed])
frames! = |key| {
	read = Host.read!(frames_path(key))
	match read.status {
		Found => Ok(read.bytes)
		Missing => Ok([])
		Failed => Err(Failed)
	}
}

stream! : List(U8) => Chat.Answer
stream! = |key|
	match frames!(key) {
		Ok(backlog) => Chat.stream({ key, backlog })
		Err(Failed) => Chat.failed
	}

## The body as `key`'s next frame, kept, then published: its id is how many
## frames `key` had (each frame ends in a blank line, and none holds one).
post! : List(U8) => Chat.Answer
post! = |key| {
	got = Host.read_body!(echo_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match frames!(key) {
				Err(Failed) => Chat.failed
				Ok(before) => {
					id = count_frames(before)
					match Sse.frame({
						name: [],
						data: got.bytes,
						id: Str.to_utf8(U64.to_str(id)),
					}) {
						Err(LineBreak) => Chat.respond(
							400,
							{
								content_type: Chat.text,
								body: Str.to_utf8("a CR has no place in an event\n"),
							},
						)
						Ok(frame) =>
							match (Host.append!(frames_path(key), frame)).status {
								Failed => Chat.failed
								Appended => {
									Host.publish!(key, frame)
									Chat.plain(Str.to_utf8("posted ${U64.to_str(id)}\n"))
								}
							}
					}
				}
			}
	}
}

## How many frames `frames` holds: each ends in `\n\n`.
count_frames : List(U8) -> U64
count_frames = |frames| {
	var $n = 0
	var $i = 0
	len = List.len(frames)
	while $i + 1 < len {
		if List.get(frames, $i) == Ok('\n') and List.get(frames, $i + 1) == Ok('\n') {
			$n = $n + 1
			$i = $i + 2
		} else {
			$i = $i + 1
		}
	}
	$n
}

expect count_frames(Str.to_utf8("id: 0\ndata: a\n\nid: 1\ndata: b\ndata: c\n\n")) == 2
expect keyed(Str.to_utf8("/stream/k1")) == Ok(Stream(Str.to_utf8("k1")))
expect keyed(Str.to_utf8("/post/")) == Err(NotKeyed)
expect keyed(Str.to_utf8("/post/a/b")) == Err(NotKeyed)

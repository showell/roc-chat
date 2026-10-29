## PLANTED CRASHES, FOR THE TESTS ONLY (host/crash_test.zig): an app on the
## chat's platform that dies on purpose, one path per way a Roc can die, and
## answers `/ok` with a 200, so the host's answer to a crash (a 500 with its
## own fixed body, the turn released, the next request served, the crash
## logged once) is seen. Never linked into a server.
##
## **EACH PLANT READS THE REQUEST**, so the compiler cannot fold it to a
## constant and refuse to build: an overflow written with constants is a
## compile error, not a crash.
app [handle!] { pf: platform "../../platform/main.roc" }

import pf.Chat
import pf.Host

handle! : Chat.Request => Chat.Answer
handle! = |req| {
	path = req.path
	if path == Str.to_utf8("/ok") {
		Chat.plain(Str.to_utf8("ok\n"))
	} else if path == Str.to_utf8("/crash") {
		# A `crash` in the handler.
		crash "a planted crash"
	} else if path == Str.to_utf8("/crash-get") {
		# An out-of-bounds List.get, unwrapped by `crash`.
		at = List.len(path) + 100
		match List.get(path, at) {
			Ok(b) => Chat.plain([b])
			Err(_) => crash "a planted crash: List.get past the end"
		}
	} else if path == Str.to_utf8("/crash-overflow") {
		# A U8 overflow: the path's second byte, 'c' (99), times three.
		b = List.get(path, 1) ?? 0
		tripled = b * 3
		Chat.plain(Str.to_utf8("tripled ${U8.to_str(tripled)}\n"))
	} else if path == Str.to_utf8("/crash-divide") {
		# A U64 divided by zero: the path's length less itself.
		n = List.len(path)
		Chat.plain(Str.to_utf8("quotient ${U64.to_str(n // (n - n))}\n"))
	} else if path == Str.to_utf8("/crash-after-header") {
		# A crash in a hosted function's continuation: read_header! answered,
		# then the Roc dies with a value it read in its hands.
		probes = Host.read_header!(Str.to_utf8("x-probe"))
		if List.len(probes) > 0 {
			crash "a planted crash, after read_header!"
		} else {
			Chat.plain(Str.to_utf8("no x-probe\n"))
		}
	} else if path == Str.to_utf8("/crash-after-body") {
		# A crash in read_body!'s continuation, the body in the Roc's hands.
		got = Host.read_body!(1024)
		match got.status {
			Read => crash "a planted crash, after read_body!"
			Answered => crash "a planted crash, after the host answered the body"
		}
	} else if path == Str.to_utf8("/crash-after-script") {
		# The host has answered inside the call (a script), and then the Roc
		# dies: the answer is the crash's 500, never the script.
		match Host.serve_script!(Str.to_utf8("chat.js")) {
			Served => crash "a planted crash, after serve_script!"
			Missing => Chat.not_found
		}
	} else if path == Str.to_utf8("/crash-after-write") {
		# A file written, then a crash.
		match Host.write!(Str.to_utf8("planted/written"), Str.to_utf8("before the crash\n")) {
			Written => crash "a planted crash, after write!"
			Failed => Chat.plain(Str.to_utf8("write failed\n"))
		}
	} else if path == Str.to_utf8("/crash-big") {
		# A list grown a byte at a time, through many allocations, then a
		# crash: each allocation is one a test can make fail.
		big = List.fold(
			List.repeat(7.U8, 20000),
			[],
			|acc, b| List.append(acc, b),
		)
		if List.len(big) == 20000 {
			crash "a planted crash, after a big list"
		} else {
			Chat.not_found
		}
	} else if path == Str.to_utf8("/crash-forged") {
		# A crash message with a line break and a log line after it, as one
		# built from a request's bytes could carry.
		crash "a planted crash\nwarning(roc_chat): a forged line"
	} else if path == Str.to_utf8("/crash-long") {
		# A crash message longer than the host keeps.
		crash Str.repeat("long ", 100)
	} else if path == Str.to_utf8("/crash-dbg") {
		# A `dbg`, which a served build must never reach: roc_dbg, a crash.
		dbg path
		Chat.plain(Str.to_utf8("after dbg\n"))
	} else if path == Str.to_utf8("/crash-expect") {
		# An inline `expect` that fails, in a served build: a crash.
		expect List.len(path) == 0
		Chat.plain(Str.to_utf8("after expect\n"))
	} else if path == Str.to_utf8("/crash-deep") {
		# A recursion too deep for the stack: no `roc_crashed`, a fault on
		# the stack's guard page.
		Chat.plain(Str.to_utf8("depth ${U64.to_str(deep(List.len(path) * 100_000_000))}\n"))
	} else {
		Chat.not_found
	}
}

## 1 + 1 + ... `n` times, never a tail call.
deep : U64 -> U64
deep = |n| if n == 0 0 else 1 + deep(n - 1)

## This module refuses any request that does not come from this server's
## own origin. The server listens on 127.0.0.1 alone (host/http.zig), but a
## browser on this machine, or on a laptop through `ssh -L`, carries any web
## page's requests to it. A page elsewhere can POST a plain form to
## `http://localhost:<port>/...`, which needs no preflight; and a name an
## attacker rebinds to 127.0.0.1 lets their page GET a transcript and read
## it. Until sign-in exists, every request acts as Steve (main's `acting`),
## so either attack would write or read as him.
##
## A page elsewhere can also read through a browser here without reading
## the answer: an `EventSource` on a conversation's stream takes one of
## Steve's stream slots, ending his own tabs' streams, and makes the server
## render the whole transcript.
##
## So main checks every request here from its head, before the host reads
## its body:
##
## - Its `Host` must be exactly `127.0.0.1:<port>` or `localhost:<port>`,
##   where `<port>` is the one the server listens on (`Http.Request.port`).
##   A rebound name arrives under its own name, and is refused.
## - Any request carrying an `Origin` that is not `http://` and one of
##   those two is refused, whatever its method. A browser sends `Origin`
##   with every write and every script's fetch, an `EventSource` included.
## - A request that writes (every method but GET) is refused when its
##   `Sec-Fetch-Site` is not `same-origin`.
## - A GET is refused when its `Sec-Fetch-Site` says another site's page
##   asked for it (`cross-site` or `same-site`), unless its `Sec-Fetch-Mode`
##   is `navigate`: a link followed to a page here is served.
##
## A client that sends no `Origin` and no `Sec-Fetch-` headers (curl, as the
## README posts) passes. A header sent twice names no one value, and is
## refused as a foreign one. Each refusal is a named tag, which main answers
## with a 403.
##
## This module is one of the program's five trust boundaries. The others
## are `UnvalidatedString`, the way text comes in; `TrustedHtml`, the way
## markup goes out to a page; `SecureImageTag`, which images a message may
## show; and `SignedIn`, who is acting.
import pf.Http
import RequestHeader

RequestOrigin :: [].{

	## `Ok` when a request, by its `method` and `headers`, comes from the
	## origin of this server, listening on `port`; else why not.
	check : {
		method : List(U8),
		headers : List(Http.Header),
		port : U16,
	} -> Try({}, [MissingHost, ForeignHost, ForeignOrigin, CrossSiteFetch])
	check = |
		{
			method,
			headers,
			port,
		},
	| {
		hosts = ["127.0.0.1:${port.to_str()}".to_utf8(), "localhost:${port.to_str()}".to_utf8()]
		origins = hosts.map(|host| "http://".to_utf8().concat(host))
		match (RequestHeader.header_value(headers, "host"), RequestHeader.header_value(headers, "origin")) {
			(Unsent, _) => Err(MissingHost)
			(Sent(host), _) if !hosts.contains(host) => Err(ForeignHost)
			(Repeated, _) => Err(ForeignHost)
			(_, Sent(origin)) if !origins.contains(origin) => Err(ForeignOrigin)
			(_, Repeated) => Err(ForeignOrigin)
			_ =>
				if (method == "GET".to_utf8())
					read_verdict(headers)
				else
					write_verdict(headers)
		}
	}

	## Every refusal `check` answers, as `words` takes it. `check` lists its
	## own errors in place; this union is only the handler's input.
	Refusal : [
		MissingHost,
		ForeignHost,
		ForeignOrigin,
		CrossSiteFetch,
	]

	## Why a request is refused, in words for the 403's page.
	words : RequestOrigin.Refusal -> Str
	words = |why|
		match why {
			MissingHost => "The request names no Host."
			ForeignHost => "The request's Host is not this server's (127.0.0.1 or localhost, at its port)."
			ForeignOrigin => "The request comes from a page of another origin."
			CrossSiteFetch => "The browser says the request comes from another site's page."
		}
}

## The verdict on a request that writes, by its `headers`: refused when its
## `Sec-Fetch-Site` is not `same-origin`, or is sent twice.
write_verdict : List(Http.Header) -> Try({}, [CrossSiteFetch])
write_verdict = |headers|
	match RequestHeader.header_value(headers, "sec-fetch-site") {
		Sent(site) if site != "same-origin".to_utf8() => Err(CrossSiteFetch)
		Repeated => Err(CrossSiteFetch)
		_ => Ok({})
	}

## The verdict on a GET, by its `headers`: refused when its
## `Sec-Fetch-Site` names another site's page and its `Sec-Fetch-Mode` is
## not `navigate`, or when the site is sent twice.
read_verdict : List(Http.Header) -> Try({}, [CrossSiteFetch])
read_verdict = |headers|
	match (RequestHeader.header_value(headers, "sec-fetch-site"), RequestHeader.header_value(headers, "sec-fetch-mode")) {
		(Sent(site), Sent(mode)) if is_another_site(site) and mode == "navigate".to_utf8() => Ok({})
		(Sent(site), _) if is_another_site(site) => Err(CrossSiteFetch)
		(Repeated, _) => Err(CrossSiteFetch)
		_ => Ok({})
	}

## Whether a `Sec-Fetch-Site` value names a page of another site: one on
## another host, or on another port of this one (`same-site`).
is_another_site : List(U8) -> Bool
is_another_site = |site| site == "cross-site".to_utf8() or site == "same-site".to_utf8()

# ── tests
## The verdict on a request by `method`, with `headers` (name, value), at
## port 9611.
verdict : Str, List((Str, Str)) -> Try({}, _)
verdict = |method, headers|
	RequestOrigin.check({
		method: method.to_utf8(),
		headers: headers.map(|(name, value)| { name: name.to_utf8(), value: value.to_utf8() }),
		port: 9611,
	})

# The Host, both sides: exactly one of the two names, at the server's port.
expect verdict("GET", [("Host", "127.0.0.1:9611")]) == Ok({})
expect verdict("GET", [("host", "localhost:9611")]) == Ok({})
expect verdict("GET", [("HOST", "localhost:9611")]) == Ok({})
expect verdict("GET", []) == Err(MissingHost)
expect verdict("GET", [("Host", "evil.example:9611")]) == Err(ForeignHost)
expect verdict("GET", [("Host", "localhost:9612")]) == Err(ForeignHost)
expect verdict("GET", [("Host", "localhost")]) == Err(ForeignHost)
expect verdict("GET", [("Host", "LOCALHOST:9611")]) == Err(ForeignHost)
expect verdict("GET", [("Host", "127.0.0.1:9611"), ("Host", "127.0.0.1:9611")]) == Err(ForeignHost)
expect verdict("GET", [("X-Host", "localhost:9611")]) == Err(MissingHost)
# A write's Origin and Sec-Fetch-Site, both sides; neither sent (curl) passes.
## A POST to localhost:9611 with `more` headers.
post_verdict : List((Str, Str)) -> Try({}, _)
post_verdict = |more| verdict("POST", [("Host", "localhost:9611")].concat(more))

expect post_verdict([]) == Ok({})
expect post_verdict([("Origin", "http://localhost:9611")]) == Ok({})
expect post_verdict([("origin", "http://127.0.0.1:9611")]) == Ok({})
expect post_verdict([("Origin", "http://evil.example")]) == Err(ForeignOrigin)
expect post_verdict([("Origin", "null")]) == Err(ForeignOrigin)
expect post_verdict([("Origin", "https://localhost:9611")]) == Err(ForeignOrigin)
expect post_verdict([("Origin", "http://localhost:9612")]) == Err(ForeignOrigin)
expect post_verdict([("Origin", "http://localhost:9611/")]) == Err(ForeignOrigin)
expect
	post_verdict([("Origin", "http://localhost:9611"), ("Origin", "http://localhost:9611")])
		== Err(ForeignOrigin)
expect post_verdict([("Sec-Fetch-Site", "same-origin")]) == Ok({})
expect post_verdict([("Sec-Fetch-Site", "cross-site")]) == Err(CrossSiteFetch)
expect post_verdict([("Sec-Fetch-Site", "same-site")]) == Err(CrossSiteFetch)
expect post_verdict([("Sec-Fetch-Site", "none")]) == Err(CrossSiteFetch)
expect
	post_verdict([("Sec-Fetch-Site", "same-origin"), ("Sec-Fetch-Site", "same-origin")])
		== Err(CrossSiteFetch)
expect post_verdict([("Origin", "http://localhost:9611"), ("Sec-Fetch-Site", "same-origin")]) == Ok({})
expect
	post_verdict([("Origin", "http://localhost:9611"), ("Sec-Fetch-Site", "cross-site")])
		== Err(CrossSiteFetch)
expect
	post_verdict([("Origin", "http://evil.example"), ("Sec-Fetch-Site", "cross-site")])
		== Err(ForeignOrigin)
# A write still needs its Host first, and every method but GET is a write.
expect verdict("POST", [("Origin", "http://localhost:9611")]) == Err(MissingHost)
expect
	verdict("POST", [("Host", "evil.example"), ("Origin", "http://localhost:9611")])
		== Err(ForeignHost)
expect
	verdict("PUT", [("Host", "localhost:9611"), ("Origin", "http://evil.example")])
		== Err(ForeignOrigin)
expect
	verdict("HEAD", [("Host", "localhost:9611"), ("Origin", "http://evil.example")])
		== Err(ForeignOrigin)
expect
	verdict("get", [("Host", "localhost:9611"), ("Origin", "http://evil.example")])
		== Err(ForeignOrigin)
expect
	verdict("DELETE", [("Host", "localhost:9611"), ("Sec-Fetch-Site", "cross-site")])
		== Err(CrossSiteFetch)
# A GET's Origin, both sides: this server's passes, another's or two are
# refused, an EventSource's from another page included.
## A GET of localhost:9611 with `more` headers.
get_verdict : List((Str, Str)) -> Try({}, _)
get_verdict = |more| verdict("GET", [("Host", "localhost:9611")].concat(more))

expect get_verdict([]) == Ok({})
expect get_verdict([("Origin", "http://localhost:9611")]) == Ok({})
expect get_verdict([("Origin", "http://127.0.0.1:9611"), ("Sec-Fetch-Mode", "cors")]) == Ok({})
expect get_verdict([("Origin", "http://evil.example")]) == Err(ForeignOrigin)
expect get_verdict([("Origin", "http://localhost:3000")]) == Err(ForeignOrigin)
expect
	get_verdict([("Origin", "http://localhost:9611"), ("Origin", "http://localhost:9611")])
		== Err(ForeignOrigin)
expect
	get_verdict([
		("Origin", "http://evil.example"),
		("Sec-Fetch-Site", "cross-site"),
		("Sec-Fetch-Mode", "cors"),
	])
		== Err(ForeignOrigin)
# A GET's Sec-Fetch-Site and Sec-Fetch-Mode: another site's page is refused
# unless it navigates here; this origin's, the user's own (`none`), or no
# header (curl) passes.
expect
	[
		[("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "cors")],
		[("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "no-cors")],
		[("Sec-Fetch-Site", "same-site"), ("Sec-Fetch-Mode", "cors")],
		[("Sec-Fetch-Site", "same-site"), ("Sec-Fetch-Mode", "no-cors")],
		[("Sec-Fetch-Site", "cross-site")],
		[("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "Navigate")],
		[
			("Sec-Fetch-Site", "cross-site"),
			("Sec-Fetch-Mode", "navigate"),
			("Sec-Fetch-Mode", "navigate"),
		],
		[("Sec-Fetch-Site", "same-origin"), ("Sec-Fetch-Site", "same-origin")],
	].all(|more| get_verdict(more) == Err(CrossSiteFetch))
expect
	[
		[("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "navigate")],
		[("Sec-Fetch-Site", "same-site"), ("Sec-Fetch-Mode", "navigate")],
		[("Sec-Fetch-Site", "same-origin"), ("Sec-Fetch-Mode", "cors")],
		[("Sec-Fetch-Site", "same-origin"), ("Sec-Fetch-Mode", "no-cors")],
		[("Sec-Fetch-Site", "none"), ("Sec-Fetch-Mode", "navigate")],
		[("Sec-Fetch-Mode", "cors")],
	].all(|more| get_verdict(more) == Ok({}))
# Every refusal, in words.
expect RequestOrigin.words(MissingHost) == "The request names no Host."
expect
	RequestOrigin.words(ForeignHost)
		== "The request's Host is not this server's (127.0.0.1 or localhost, at its port)."
expect RequestOrigin.words(ForeignOrigin) == "The request comes from a page of another origin."
expect
	RequestOrigin.words(CrossSiteFetch)
		== "The browser says the request comes from another site's page."

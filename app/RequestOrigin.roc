## This module refuses any request that does not come from this server's
## own origin. The server listens on 127.0.0.1 alone (host/http.zig), but a
## browser on this machine, or on a laptop through `ssh -L`, carries any web
## page's requests to it. A page elsewhere can POST a plain form to
## `http://localhost:<port>/...`, which needs no preflight; and a name an
## attacker rebinds to 127.0.0.1 lets their page GET a transcript and read
## it. Until sign-in exists, every request acts as Steve (main's `acting`),
## so either attack would write or read as him.
##
## So main checks every request here before it routes it:
##
## - Its `Host` must be exactly `127.0.0.1:<port>` or `localhost:<port>`,
##   where `<port>` is the one the server listens on (`Http.Request.port`).
##   A rebound name arrives under its own name, and is refused.
## - A request that writes (every method but GET) is refused when it
##   carries an `Origin` that is not `http://` and one of those two, or a
##   `Sec-Fetch-Site` that is not `same-origin`. A client that sends
##   neither (curl, as the README posts) passes.
##
## A header sent twice names no one value, and is refused as a foreign one.
## Each refusal is a named tag, which main answers with a 403.
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
		match RequestHeader.sent(headers, "host") {
			Unsent => Err(MissingHost)
			Sent(host) if hosts.contains(host) =>
				if (method == "GET".to_utf8())
					Ok({})
				else
					write_verdict(headers, hosts)
			_ => Err(ForeignHost)
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

## The verdict on a request that writes, by its `headers`: refused when it
## sends an `Origin` that is not `http://` and one of `hosts`, or a
## `Sec-Fetch-Site` that is not `same-origin`, or either header twice.
write_verdict : List(Http.Header), List(List(U8)) -> Try({}, [ForeignOrigin, CrossSiteFetch])
write_verdict = |headers, hosts| {
	origins = hosts.map(|host| "http://".to_utf8().concat(host))
	match (RequestHeader.sent(headers, "origin"), RequestHeader.sent(headers, "sec-fetch-site")) {
		(Sent(origin), _) if !origins.contains(origin) => Err(ForeignOrigin)
		(Repeated, _) => Err(ForeignOrigin)
		(_, Sent(site)) if site != "same-origin".to_utf8() => Err(CrossSiteFetch)
		(_, Repeated) => Err(CrossSiteFetch)
		_ => Ok({})
	}
}

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
posted : List((Str, Str)) -> Try({}, _)
posted = |more| verdict("POST", [("Host", "localhost:9611")].concat(more))

expect posted([]) == Ok({})
expect posted([("Origin", "http://localhost:9611")]) == Ok({})
expect posted([("origin", "http://127.0.0.1:9611")]) == Ok({})
expect posted([("Origin", "http://evil.example")]) == Err(ForeignOrigin)
expect posted([("Origin", "null")]) == Err(ForeignOrigin)
expect posted([("Origin", "https://localhost:9611")]) == Err(ForeignOrigin)
expect posted([("Origin", "http://localhost:9612")]) == Err(ForeignOrigin)
expect posted([("Origin", "http://localhost:9611/")]) == Err(ForeignOrigin)
expect
	posted([("Origin", "http://localhost:9611"), ("Origin", "http://localhost:9611")])
		== Err(ForeignOrigin)
expect posted([("Sec-Fetch-Site", "same-origin")]) == Ok({})
expect posted([("Sec-Fetch-Site", "cross-site")]) == Err(CrossSiteFetch)
expect posted([("Sec-Fetch-Site", "same-site")]) == Err(CrossSiteFetch)
expect posted([("Sec-Fetch-Site", "none")]) == Err(CrossSiteFetch)
expect
	posted([("Sec-Fetch-Site", "same-origin"), ("Sec-Fetch-Site", "same-origin")])
		== Err(CrossSiteFetch)
expect posted([("Origin", "http://localhost:9611"), ("Sec-Fetch-Site", "same-origin")]) == Ok({})
expect
	posted([("Origin", "http://localhost:9611"), ("Sec-Fetch-Site", "cross-site")])
		== Err(CrossSiteFetch)
expect
	posted([("Origin", "http://evil.example"), ("Sec-Fetch-Site", "cross-site")])
		== Err(ForeignOrigin)
# A write still needs its Host first; a GET is held to its Host alone, and
# every other method is a write.
expect verdict("POST", [("Origin", "http://localhost:9611")]) == Err(MissingHost)
expect
	verdict("POST", [("Host", "evil.example"), ("Origin", "http://localhost:9611")])
		== Err(ForeignHost)
expect
	verdict(
		"GET",
		[
			("Host", "localhost:9611"),
			("Origin", "http://evil.example"),
			("Sec-Fetch-Site", "cross-site"),
		],
	)
		== Ok({})
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
# Every refusal, in words.
expect RequestOrigin.words(MissingHost) == "The request names no Host."
expect
	RequestOrigin.words(ForeignHost)
		== "The request's Host is not this server's (127.0.0.1 or localhost, at its port)."
expect RequestOrigin.words(ForeignOrigin) == "The request comes from a page of another origin."
expect
	RequestOrigin.words(CrossSiteFetch)
		== "The browser says the request comes from another site's page."

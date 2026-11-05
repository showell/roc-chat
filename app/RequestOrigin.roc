## This module refuses any request that does not come from one of this
## server's own origins. The server listens on 127.0.0.1 alone
## (host/http.zig), and has two kinds of origin: the local one, which a
## browser on this machine, or on a laptop through `ssh -L`, reaches; and
## the public one it was started with, `https://` and the name a proxy on
## this machine serves it under, if any (`Http.Request.public_origin`).
## A browser carries any web page's requests to either. A page elsewhere
## can POST a plain form to the server, which needs no preflight, and the
## browser sends the signed-in human's session cookie with a top-level
## one; and a name an attacker rebinds to 127.0.0.1 lets their page GET a
## transcript and read it. Either attack would write or read as the human.
##
## A page elsewhere can also read through a browser here without reading
## the answer: an `EventSource` on a conversation's stream takes one of the
## human's stream slots, ending their own tabs' streams, and makes the
## server render the whole transcript.
##
## So main checks every request here from its head, before the host reads
## its body:
##
## - Its `Host` must be exactly one of this server's: `127.0.0.1:<port>`
##   or `localhost:<port>`, where `<port>` is the one the server listens
##   on (`Http.Request.port`), or the public origin's name. A rebound name
##   arrives under its own name, and is refused.
## - Any request carrying an `Origin` that is not the one its `Host`
##   names is refused, whatever its method: `http://` and one of the two
##   local names for a local `Host`, and the public origin exactly for the
##   public one. A browser sends `Origin` with every write and every
##   script's fetch, an `EventSource` included. The check never relies on
##   a proxy taking an `Origin` off.
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

	## `Ok` when a request, by its `method` and `headers`, comes from one of
	## the origins of this server, listening on `port`, its public origin
	## `public_origin` (empty for none); else why not.
	check : {
		method : List(U8),
		headers : List(Http.Header),
		port : U16,
		public_origin : List(U8),
	} -> Try({}, [MissingHost, ForeignHost, ForeignOrigin, CrossSiteFetch])
	check = |{ method, headers, port, public_origin }| {
		own = own_origins({ port, public_origin })
		match RequestHeader.header_value(headers, "host") {
			Unsent => Err(MissingHost)
			Repeated => Err(ForeignHost)
			Sent(host) =>
				match own.find_first(|kind| kind.hosts.contains(host)) {
					Err(NotFound) => Err(ForeignHost)
					Ok(kind) =>
						match RequestHeader.header_value(headers, "origin") {
							Sent(origin) if !kind.origins.contains(origin) => Err(ForeignOrigin)
							Repeated => Err(ForeignOrigin)
							Sent(_) => fetch_verdict({ method, headers })
							Unsent => fetch_verdict({ method, headers })
						}
				}
		}
	}

	## The origin a request came to, by its `Host`: `http://` and the host
	## for one of the local names, or the public origin for its name. A
	## link the chat hands out starts with it, so it leads back here by the
	## way the asker came. Refused as `check` refuses a `Host`.
	origin_of_host : {
		headers : List(Http.Header),
		port : U16,
		public_origin : List(U8),
	} -> Try(Str, [MissingHost, ForeignHost])
	origin_of_host = |{ headers, port, public_origin }|
		match RequestHeader.header_value(headers, "host") {
			Unsent => Err(MissingHost)
			Repeated => Err(ForeignHost)
			Sent(host) => {
				pairs = own_origins({ port, public_origin }).join_map(
					|kind| kind.hosts.map2(kind.origins, |named, origin| (named, origin)),
				)
				match pairs.find_first(|(named, _)| named == host) {
					Ok((_, origin)) => Str.from_utf8(origin).map_err(|_| ForeignHost)
					Err(NotFound) => Err(ForeignHost)
				}
			}
		}

	## Every refusal `check` answers, as `words` takes it. `check` lists its
	## own errors in place; this union is only the handler's input.
	Refusal : [MissingHost, ForeignHost, ForeignOrigin, CrossSiteFetch]

	## Why a request is refused, in words for the 403's page.
	words : RequestOrigin.Refusal -> Str
	words = |why|
		match why {
			MissingHost => "The request names no Host."
			ForeignHost =>
				"The request's Host is not this server's (127.0.0.1 or localhost, at its port, or its public name)."
			ForeignOrigin => "The request comes from a page of another origin."
			CrossSiteFetch => "The browser says the request comes from another site's page."
		}
}

## Each kind of this server's own origin: the `Host`s that name it, and the
## `Origin`s a page of it sends. The local kind, at `port`; and the public
## kind, when `public_origin` names one: its name alone, and the origin
## exactly. The host takes only `https://` and a name for a public origin
## (host/main.zig), so any other is the host's bug.
own_origins : { port : U16, public_origin : List(U8) } -> List(
	{ hosts : List(List(U8)), origins : List(List(U8)) },
)
own_origins = |{ port, public_origin }| {
	local_hosts = ["127.0.0.1:${port.to_str()}".to_utf8(), "localhost:${port.to_str()}".to_utf8()]
	local = {
		hosts: local_hosts,
		origins: local_hosts.map(|host| "http://".to_utf8().concat(host)),
	}
	if public_origin.is_empty() {
		[local]
	} else if public_origin.starts_with(https_prefix) {
		[local, { hosts: [public_origin.drop_first(https_prefix.len())], origins: [public_origin] }]
	} else {
		crash "RequestOrigin.own_origins: a public origin is `https://` and a name"
	}
}

https_prefix : List(U8)
https_prefix = "https://".to_utf8()

## The verdict on a request whose origin is this server's, by its
## `method`: a GET's by `read_verdict`, any other's by `write_verdict`.
fetch_verdict : { method : List(U8), headers : List(Http.Header) } -> Try({}, [CrossSiteFetch])
fetch_verdict = |{ method, headers }|
	if method == "GET".to_utf8() {
		read_verdict(headers)
	} else {
		write_verdict(headers)
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
	match (
		RequestHeader.header_value(headers, "sec-fetch-site"),
		RequestHeader.header_value(headers, "sec-fetch-mode"),
	) {
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
## port 9611, with no public origin.
verdict : Str, List((Str, Str)) -> Try({}, _)
verdict = |method, headers| public_verdict({ method, headers, public_origin: "" })

## The verdict on a request by `method`, with `headers` (name, value), at
## port 9611, the server's public origin `public_origin`.
public_verdict : {
	method : Str,
	headers : List((Str, Str)),
	public_origin : Str,
} -> Try({}, _)
public_verdict = |{ method, headers, public_origin }|
	RequestOrigin.check({
		method: method.to_utf8(),
		headers: headers.map(|(name, value)| { name: name.to_utf8(), value: value.to_utf8() }),
		port: 9611,
		public_origin: public_origin.to_utf8(),
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
expect post_verdict([
	("Origin", "http://localhost:9611"),
	("Sec-Fetch-Site", "same-origin"),
]) == Ok({})
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
# The public origin, both sides: configured, its name is a Host of this
# server's, its origin the one Origin for it, and the local ones still
# serve the tunnel; not configured, its name is a stranger's.
## A request by `method` to the public name `chat.example.com`, with
## `more` headers, when the server has `public_origin`.
public_name_verdict : {
	method : Str,
	more : List((Str, Str)),
	public_origin : Str,
} -> Try({}, _)
public_name_verdict = |{ method, more, public_origin }|
	public_verdict({
		method,
		headers: [("Host", "chat.example.com")].concat(more),
		public_origin,
	})

expect
	[
		("GET", []),
		("GET", [("Origin", "https://chat.example.com"), ("Sec-Fetch-Site", "same-origin")]),
		("POST", [("Origin", "https://chat.example.com"), ("Sec-Fetch-Site", "same-origin")]),
		("POST", []),
		("GET", [("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "navigate")]),
	].all(
		|(method, more)| public_name_verdict({
			method,
			more,
			public_origin: "https://chat.example.com",
		}) == Ok({}),
	)
expect
	[
		[("Origin", "http://chat.example.com")],
		[("Origin", "https://chat.example.com:443")],
		[("Origin", "https://chat.example.com/")],
		[("Origin", "https://evil.example")],
		[("Origin", "http://localhost:9611")],
		[("Origin", "https://chat.example.com"), ("Origin", "https://chat.example.com")],
	].all(
		|more| public_name_verdict({
			method: "POST",
			more,
			public_origin: "https://chat.example.com",
		}) == Err(ForeignOrigin),
	)
expect public_name_verdict({
	method: "POST",
	more: [("Sec-Fetch-Site", "cross-site")],
	public_origin: "https://chat.example.com",
}) == Err(CrossSiteFetch)
expect public_name_verdict({
	method: "GET",
	more: [("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "cors")],
	public_origin: "https://chat.example.com",
}) == Err(CrossSiteFetch)
expect public_name_verdict({ method: "GET", more: [], public_origin: "" }) == Err(ForeignHost)
expect public_name_verdict({
	method: "POST",
	more: [("Origin", "https://chat.example.com")],
	public_origin: "",
}) == Err(ForeignHost)
expect
	["Chat.example.com", "chat.example.com:443", "chat.example.com.", "evil.example"].all(
		|host|
			public_verdict({
				method: "GET",
				headers: [("Host", host)],
				public_origin: "https://chat.example.com",
			})
				== Err(ForeignHost),
	)
# A local Host takes only a local Origin, the public origin configured or not.
expect
	public_verdict({
		method: "POST",
		headers: [("Host", "localhost:9611"), ("Origin", "https://chat.example.com")],
		public_origin: "https://chat.example.com",
	})
		== Err(ForeignOrigin)
expect
	public_verdict({
		method: "POST",
		headers: [
			("Host", "localhost:9611"),
			("Origin", "http://localhost:9611"),
			("Sec-Fetch-Site", "same-origin"),
		],
		public_origin: "https://chat.example.com",
	})
		== Ok({})
# A public origin with a port: its Host carries the port too.
expect
	public_verdict({
		method: "POST",
		headers: [("Host", "chat.example.com:8443"), ("Origin", "https://chat.example.com:8443")],
		public_origin: "https://chat.example.com:8443",
	})
		== Ok({})
# Every refusal, in words.
expect RequestOrigin.words(MissingHost) == "The request names no Host."
expect
	RequestOrigin.words(ForeignHost)
		== "The request's Host is not this server's (127.0.0.1 or localhost, at its port, or its public name)."
expect RequestOrigin.words(ForeignOrigin) == "The request comes from a page of another origin."
expect
	RequestOrigin.words(CrossSiteFetch)
		== "The browser says the request comes from another site's page."

## The origin a request came to by the `Host` `host`, at port 9611, the
## server's public origin `public_origin`.
origin_at : { host : Str, public_origin : Str } -> Try(Str, _)
origin_at = |{ host, public_origin }|
	RequestOrigin.origin_of_host({
		headers: [{ name: "host".to_utf8(), value: host.to_utf8() }],
		port: 9611,
		public_origin: public_origin.to_utf8(),
	})

# A link's origin is the one the request came to: either local name, or the
# public one; another name or port, or no `Host`, is refused.
expect origin_at({ host: "localhost:9611", public_origin: "" }) == Ok("http://localhost:9611")
expect origin_at({
	host: "127.0.0.1:9611",
	public_origin: "https://chat.example.com",
}) == Ok("http://127.0.0.1:9611")
expect origin_at({
	host: "chat.example.com",
	public_origin: "https://chat.example.com",
}) == Ok("https://chat.example.com")
expect origin_at({ host: "chat.example.com", public_origin: "" }) == Err(ForeignHost)
expect origin_at({ host: "localhost:9612", public_origin: "" }) == Err(ForeignHost)
expect
	RequestOrigin.origin_of_host({ headers: [], port: 9611, public_origin: [] })
		== Err(MissingHost)

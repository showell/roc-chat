## This module builds the responses the chat gives, each in one place: a
## page with its status, a script, the site's icon, a redirect after a POST,
## the refusal of a method, and an event stream; an uploaded image, and the
## JSON that answers an upload; a conversation's download; and a refusal in
## plain words, of an upload or a send, which the compose box shows as it
## is. It knows nothing of what a page
## says: the routes build their pages with the page modules (`PageKit`,
## `ConversationPage` and the rest) and hand them here.
##
## Every page carries its defences (`page_headers`, their one home): a
## Content-Security-Policy that lets the page load nothing but the styles
## its scripts add, same-origin images and same-origin scripts (never an
## inline one), be framed by no one and post only to itself; and
## `nosniff`, so a browser takes each answer as the type it says.
import pf.Http
import JsonOut
import StreamHolder
import TrustedHtml
import UserId

HttpAnswer :: [].{

	## `page`, with `status`, as UTF-8 HTML.
	page : U16, TrustedHtml -> Http.Response
	page = |status, html|
		whole_response({ status, headers: page_headers, body: html.to_utf8() })

	## `page` with `status`: the answer to a page that says its own status, as
	## a refusal's does (`GitHubTrip`'s, `JoinPage.refusal`).
	status_page : { status : U16, page : TrustedHtml } -> Http.Response
	status_page = |{ status, page: html }| HttpAnswer.page(status, html)

	## A 303 See Other, to `url_path`: after a POST, the browser GETs the
	## page, so a reload never posts again.
	see_other : Str -> Http.Response
	see_other = |url_path|
		whole_response({
			status: 303,
			headers: [{ name: "location".to_utf8(), value: url_path.to_utf8() }],
			body: [],
		})

	## A 302 Found, to `url_path`: where a link to a message was looked up
	## and found, as Gopher Chat's `/chat/msg/<id>` answered (`MessageLinkRoute`).
	found : Str -> Http.Response
	found = |url_path|
		whole_response({
			status: 302,
			headers: [{ name: "location".to_utf8(), value: url_path.to_utf8() }],
			body: [],
		})

	## A script, `bytes` (the app's own: `Script`), as UTF-8
	## JavaScript, which `nosniff` requires of a script a page runs.
	script : List(U8) -> Http.Response
	script = |bytes| asset({ content_type: "text/javascript; charset=utf-8", bytes })

	## The site's icon, `bytes` (the app's own: `Favicon`).
	favicon : List(U8) -> Http.Response
	favicon = |bytes| asset({ content_type: "image/x-icon", bytes })

	## An icon drawn in SVG, `bytes` (the app's own: `Favicon`).
	svg_icon : List(U8) -> Http.Response
	svg_icon = |bytes| asset({ content_type: "image/svg+xml", bytes })

	## An uploaded image, `bytes`, served as `content_type`, which
	## `nosniff` holds the browser to. The browser keeps it for good, since a
	## name is never given twice.
	image : { content_type : Str, bytes : List(U8) } -> Http.Response
	image = |{ content_type, bytes }|
		whole_response({
			status: 200,
			headers: [
				{ name: "content-type".to_utf8(), value: content_type.to_utf8() },
				{
					name: "cache-control".to_utf8(),
					value: "private, max-age=31536000, immutable".to_utf8(),
				},
				nosniff,
			],
			body: bytes,
		})

	## The JSON `answer`, a 200.
	json : JsonOut -> Http.Response
	json = |answer|
		whole_response({
			status: 200,
			headers: [
				{ name: "content-type".to_utf8(), value: "application/json".to_utf8() },
				nosniff,
			],
			body: answer.bytes(),
		})

	## A refusal in plain words, a line of text with `status`: the compose
	## box shows the refusal of an upload or of a send as the server words
	## it.
	text : U16, Str -> Http.Response
	text = |status, words|
		whole_response({
			status,
			headers: [
				{ name: "content-type".to_utf8(), value: "text/plain; charset=utf-8".to_utf8() },
				nosniff,
			],
			body: "${words}\n".to_utf8(),
		})

	## A file's text, `bytes`, as it is kept, served as plain UTF-8 text,
	## which `nosniff` holds the browser to: a transcript's `/raw`.
	plain_text_file : List(U8) -> Http.Response
	plain_text_file = |bytes|
		whole_response({
			status: 200,
			headers: [
				{ name: "content-type".to_utf8(), value: "text/plain; charset=utf-8".to_utf8() },
				nosniff,
			],
			body: bytes,
		})

	## A gzip file, `bytes`, that the browser saves as `filename` rather
	## than shows: a conversation's download. `filename` is the app's own,
	## a strict name and `.tar.gz`, so it needs no quoting.
	## It has `write_grace_ms` more to be written, the app's time for its
	## size on a slow link (`DownloadRoute.write_grace_ms`).
	gzip_download : {
		filename : Str,
		bytes : List(U8),
		write_grace_ms : U32,
	} -> Http.Response
	gzip_download = |{ filename, bytes, write_grace_ms }| {
		..whole_response({
			status: 200,
			headers: [
				{ name: "content-type".to_utf8(), value: "application/gzip".to_utf8() },
				{
					name: "content-disposition".to_utf8(),
					value: "attachment; filename=\"${filename}\"".to_utf8(),
				},
				nosniff,
			],
			body: bytes,
		}),
		write_grace_ms,
	}

	## A 405: the path takes only the methods `allowed` names: a
	## conversation's GET and POST, an upload's POST, or a script's, a
	## stream's or an uploaded image's GET.
	method_not_allowed : [GetAndPost, GetOnly, PostOnly] -> Http.Response
	method_not_allowed = |allowed| {
		methods =
			match allowed {
				GetAndPost => { header: "GET, POST", text: "GET or POST only\n" }
				GetOnly => { header: "GET", text: "GET only\n" }
				PostOnly => { header: "POST", text: "POST only\n" }
			}
		whole_response({
			status: 405,
			headers: [
				{ name: "allow".to_utf8(), value: methods.header.to_utf8() },
				{ name: "content-type".to_utf8(), value: "text/plain; charset=utf-8".to_utf8() },
				nosniff,
			],
			body: methods.text.to_utf8(),
		})
	}

	## `answer`, with `header` after its own.
	with_header : Http.Response, Http.Header -> Http.Response
	with_header = |answer, header| { ..answer, headers: answer.headers.append(header) }

	## `answer`, which no browser or proxy may keep (`cache-control:
	## no-store`): a page or a line that shows a secret, a key or an
	## invite's code, or answers a password.
	never_stored : Http.Response -> Http.Response
	never_stored = |answer|
		HttpAnswer.with_header(
			answer,
			{ name: "cache-control".to_utf8(), value: "no-store".to_utf8() },
		)

	## An event stream the host holds open on the bus keys `keys`, 1 to 4,
	## for `holder`: `backlog` first, then every frame published to any of
	## `keys`. The host writes the stream's type; it is not sniffed.
	stream : {
		keys : List(List(U8)),
		holder : StreamHolder,
		backlog : List(U8),
	} -> Http.Response
	stream = |{ keys, holder, backlog }| {
		status: 200,
		headers: [nosniff],
		body: backlog,
		kind: Stream,
		stream_keys: keys,
		stream_holder: holder.to_bytes(),
		write_grace_ms: 0,
	}
}

## A file the app compiles in, `bytes`, as `content_type`. A browser asks again
## before using its copy (`no-cache`), so a changed file is never stale.
asset : { content_type : Str, bytes : List(U8) } -> Http.Response
asset = |{ content_type, bytes }|
	whole_response({
		status: 200,
		headers: [
			{ name: "content-type".to_utf8(), value: content_type.to_utf8() },
			{ name: "cache-control".to_utf8(), value: "no-cache".to_utf8() },
			nosniff,
		],
		body: bytes,
	})

## An answer that is its body, naming no stream, written in the host's own
## time.
whole_response : {
	status : U16,
	headers : List(Http.Header),
	body : List(U8),
} -> Http.Response
whole_response = |{ status, headers, body }| {
	status,
	headers,
	body,
	kind: Whole,
	stream_keys: [],
	stream_holder: [],
	write_grace_ms: 0,
}

## A page's headers: its type, and its defences.
##
## The policy: nothing by default (`default-src 'none'`); inline styles
## (`style-src 'unsafe-inline'`), for the `<style>` each of the page's
## scripts adds and the styles a script sets on an element; scripts from
## this origin's own files alone (`script-src 'self'`: the files `Script`
## serves, never an inline `<script>` or an event attribute, so markup that
## slipped into a page still runs nothing); images and video from this
## origin alone (`img-src` and `media-src 'self'`), the most
## `SecureImageTag` will ever allow, a conversation's own uploads; no
## framing (`frame-ancestors 'none'`), no `<base>` (`base-uri 'none'`), a
## form posts only back here (`form-action 'self'`), and a script's
## stream, send or upload connects only here (`connect-src 'self'`).
page_headers : List(Http.Header)
page_headers = [
	{ name: "content-type".to_utf8(), value: "text/html; charset=utf-8".to_utf8() },
	{ name: "content-security-policy".to_utf8(), value: content_security_policy.to_utf8() },
	nosniff,
]

content_security_policy : Str
content_security_policy = Str.join_with(
	[
		"default-src 'none'",
		"style-src 'unsafe-inline'",
		"script-src 'self'",
		"img-src 'self'",
		"media-src 'self'",
		"frame-ancestors 'none'",
		"base-uri 'none'",
		"form-action 'self'",
		"connect-src 'self'",
	],
	"; ",
)

## The header that has a browser take the answer as the type it says,
## never guessing another.
nosniff : Http.Header
nosniff = { name: "x-content-type-options".to_utf8(), value: "nosniff".to_utf8() }

# ── tests
## An answer's headers, as a test reads them.
header_pairs : Http.Response -> List((Str, Str))
header_pairs = |response| response.headers.map(
	|h| (Str.from_utf8_lossy(h.name), Str.from_utf8_lossy(h.value)),
)

# A page has the status it is given and its HTML as the body, and carries
# its type, the policy and nosniff, whatever its status.
expect
	[200, 404, 500].all(
		|status| {
			response = HttpAnswer.page(status, TrustedHtml.dangerously_trust("<p>x</p>"))
			response.status == status
				and response.body == "<p>x</p>".to_utf8()
				and header_pairs(response)
					== [
						("content-type", "text/html; charset=utf-8"),
						(
							"content-security-policy",
							"default-src 'none'; style-src 'unsafe-inline'; script-src 'self'; img-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; connect-src 'self'",
						),
						("x-content-type-options", "nosniff"),
					]
		},
	)

## A 405's headers and words, as a test reads them.
method_refusal : [GetAndPost, GetOnly, PostOnly] -> (List((Str, Str)), Str)
method_refusal = |allowed| {
	response = HttpAnswer.method_not_allowed(allowed)
	(header_pairs(response), Str.from_utf8_lossy(response.body))
}

# The 405 is plain text, not sniffed, allowing each path's own methods.
expect
	method_refusal(GetAndPost)
		== (
			[
				("allow", "GET, POST"),
				("content-type", "text/plain; charset=utf-8"),
				("x-content-type-options", "nosniff"),
			],
			"GET or POST only\n",
		)
expect
	method_refusal(GetOnly)
		== (
			[
				("allow", "GET"),
				("content-type", "text/plain; charset=utf-8"),
				("x-content-type-options", "nosniff"),
			],
			"GET only\n",
		)
expect
	method_refusal(PostOnly)
		== (
			[
				("allow", "POST"),
				("content-type", "text/plain; charset=utf-8"),
				("x-content-type-options", "nosniff"),
			],
			"POST only\n",
		)
# The 303 has no body, only its place.
expect {
	response = HttpAnswer.see_other("/a")
	response.status == 303
		and response.body == []
		and header_pairs(response) == [("location", "/a")]
}
# An uploaded image: its type, kept for good, not sniffed, its bytes as
# given.
expect {
	response = HttpAnswer.image({ content_type: "image/png", bytes: [0x89, 0, 0xFF] })
	response.status == 200
		and header_pairs(response)
			== [
				("content-type", "image/png"),
				("cache-control", "private, max-age=31536000, immutable"),
				("x-content-type-options", "nosniff"),
			]
		and response.body == [0x89, 0, 0xFF]
}
# JSON and a plain refusal, each its type, not sniffed; the refusal one line.
expect {
	response = HttpAnswer.json(JsonOut.json_object([]))
	response.status == 200
		and header_pairs(response) == [
			("content-type", "application/json"),
			("x-content-type-options", "nosniff"),
		]
		and response.body == "{}".to_utf8()
}
expect {
	response = HttpAnswer.text(415, "no & <b>")
	response.status == 415
		and header_pairs(response) == [
			("content-type", "text/plain; charset=utf-8"),
			("x-content-type-options", "nosniff"),
		]
		and response.body == "no & <b>\n".to_utf8()
}
# Every whole answer names no stream; a stream is a 200 on its key, for its
# holder, its backlog first, not sniffed.
expect
	[
		HttpAnswer.page(404, TrustedHtml.join([])),
		HttpAnswer.see_other("/a"),
		HttpAnswer.script([]),
		HttpAnswer.favicon([]),
		HttpAnswer.svg_icon([]),
		HttpAnswer.method_not_allowed(GetOnly),
		HttpAnswer.image({ content_type: "image/png", bytes: [] }),
		HttpAnswer.json(JsonOut.json_object([])),
		HttpAnswer.text(400, "x"),
	].all(
		|response|
			response.kind == Whole
				and response.stream_keys == []
				and response.stream_holder == []
				and response.write_grace_ms == 0,
	)
expect {
	response = HttpAnswer.stream({
		keys: ["k".to_utf8()],
		holder: StreamHolder.user(UserId.chat_owner),
		backlog: "id: 1\n".to_utf8(),
	})
	response.kind == Stream
		and response.status == 200
		and response.stream_keys == ["k".to_utf8()]
		and response.stream_holder == "1".to_utf8()
		and response.write_grace_ms == 0
		and response.body == "id: 1\n".to_utf8()
		and header_pairs(response) == [("x-content-type-options", "nosniff")]
}
# An answer never stored: its own headers, then `no-store`; its status and
# body as they were.
expect {
	response = HttpAnswer.never_stored(HttpAnswer.text(200, "7-key"))
	response.status == 200
		and response.body == "7-key\n".to_utf8()
		and header_pairs(response)
			== [
				("content-type", "text/plain; charset=utf-8"),
				("x-content-type-options", "nosniff"),
				("cache-control", "no-store"),
			]
}
expect header_pairs(
	HttpAnswer.with_header(
		HttpAnswer.see_other("/a"),
		{ name: "x".to_utf8(), value: "y".to_utf8() },
	),
) == [("location", "/a"), ("x", "y")]
# A script: JavaScript, never cached unasked, not sniffed, its bytes as
# given; and no page's policy, which is a document's.
expect {
	response = HttpAnswer.script("x();\n".to_utf8())
	response.status == 200
		and header_pairs(response)
			== [
				("content-type", "text/javascript; charset=utf-8"),
				("cache-control", "no-cache"),
				("x-content-type-options", "nosniff"),
			]
		and response.body == "x();\n".to_utf8()
}
# The icon: as a script is but for its type, its bytes as given.
expect {
	response = HttpAnswer.favicon([0, 0, 1, 0])
	response.status == 200
		and header_pairs(response)
			== [
				("content-type", "image/x-icon"),
				("cache-control", "no-cache"),
				("x-content-type-options", "nosniff"),
			]
		and response.body == [0, 0, 1, 0]
}
# An SVG icon: the same, an SVG's type.
expect {
	response = HttpAnswer.svg_icon("<svg/>".to_utf8())
	response.status == 200
		and header_pairs(response)
			== [
				("content-type", "image/svg+xml"),
				("cache-control", "no-cache"),
				("x-content-type-options", "nosniff"),
			]
		and response.body == "<svg/>".to_utf8()
}
# A transcript's plain text: a 200, UTF-8 text, not sniffed, its bytes as
# kept, a final line end and all.
expect {
	response = HttpAnswer.plain_text_file("a <b>\n".to_utf8())
	response.status == 200
		and header_pairs(response) == [
			("content-type", "text/plain; charset=utf-8"),
			("x-content-type-options", "nosniff"),
		]
		and response.body == "a <b>\n".to_utf8()
		and response.kind == Whole
}

## **THE RESPONSES THE CHAT GIVES**, built once each: a page with its
## status, a script, a redirect after a POST, the refusal of a method, and
## an event stream; and for an upload, an uploaded image, the JSON that
## answers an upload, and a refusal in plain words, which the compose box
## shows as it is.
##
## **EVERY PAGE CARRIES ITS DEFENCES** (`page_headers`, their one home): a
## Content-Security-Policy that lets the page load nothing but its own
## inline style sheet, same-origin images and same-origin scripts (never
## an inline one), be framed by no one and post only to itself; and
## `nosniff`, so a browser takes each answer as the type it says.
import pf.Http
import Page
import TrustedHtml

HttpAnswer :: [].{

	## `page`, with `status`, as UTF-8 HTML.
	page : U16, TrustedHtml -> Http.Response
	page = |status, html|
		whole({
			status,
			headers: page_headers,
			body: html.to_utf8(),
		})

	## **A NOTICE PAGE** (`Page.notice`) with `status`.
	notice : U16, { title : Str, said : Str } -> Http.Response
	notice = |status, words| HttpAnswer.page(status, Page.notice(words))

	## **303 SEE OTHER**, to `url_path`: after a POST, the browser GETs the
	## page, so a reload never posts again.
	see_other : Str -> Http.Response
	see_other = |url_path|
		whole({
			status: 303,
			headers: [{ name: "location".to_utf8(), value: url_path.to_utf8() }],
			body: [],
		})

	## **A SCRIPT**, `bytes` (the app's own: `ComposeScript`), as UTF-8
	## JavaScript, which `nosniff` requires of a script a page runs. A
	## browser asks again before using its copy (`no-cache`), so a changed
	## script is never stale.
	script : List(U8) -> Http.Response
	script = |bytes|
		whole({
			status: 200,
			headers: [
				{ name: "content-type".to_utf8(), value: "text/javascript; charset=utf-8".to_utf8() },
				{ name: "cache-control".to_utf8(), value: "no-cache".to_utf8() },
				nosniff,
			],
			body: bytes,
		})

	## An uploaded image, `bytes`, served as `content_type`, which
	## `nosniff` holds the browser to. The browser keeps it for good, as the
	## old chat's did, since a name is never given twice.
	image : { content_type : Str, bytes : List(U8) } -> Http.Response
	image = |{ content_type, bytes }|
		whole({
			status: 200,
			headers: [
				{ name: "content-type".to_utf8(), value: content_type.to_utf8() },
				{ name: "cache-control".to_utf8(), value: "private, max-age=31536000, immutable".to_utf8() },
				nosniff,
			],
			body: bytes,
		})

	## JSON, `bytes`, with `status`.
	json : U16, List(U8) -> Http.Response
	json = |status, bytes|
		whole({
			status,
			headers: [
				{ name: "content-type".to_utf8(), value: "application/json".to_utf8() },
				nosniff,
			],
			body: bytes,
		})

	## A refusal in plain words, a line of text with `status`: the compose
	## box shows an upload's refusal as the server words it.
	text : U16, Str -> Http.Response
	text = |status, words|
		whole({
			status,
			headers: [
				{ name: "content-type".to_utf8(), value: "text/plain; charset=utf-8".to_utf8() },
				nosniff,
			],
			body: "${words}\n".to_utf8(),
		})

	## **405**: the path takes only the methods `allowed` names: a
	## conversation's GET and POST, an upload's POST, or a script's, a
	## stream's or an uploaded image's GET.
	method_not_allowed : [GetAndPost, GetOnly, PostOnly] -> Http.Response
	method_not_allowed = |allowed| {
		methods =
			match allowed {
				GetAndPost => { header: "GET, POST", said: "GET or POST only\n" }
				GetOnly => { header: "GET", said: "GET only\n" }
				PostOnly => { header: "POST", said: "POST only\n" }
			}
		whole({
			status: 405,
			headers: [
				{ name: "allow".to_utf8(), value: methods.header.to_utf8() },
				{ name: "content-type".to_utf8(), value: "text/plain; charset=utf-8".to_utf8() },
				nosniff,
			],
			body: methods.said.to_utf8(),
		})
	}

	## **AN EVENT STREAM** the host holds open on the bus key `key`, for
	## `holder`: `backlog` first, then every frame published to `key`. The
	## host writes the stream's type; it is not sniffed.
	stream : {
		key : List(U8),
		holder : List(U8),
		backlog : List(U8),
	} -> Http.Response
	stream = |
		{
			key,
			holder,
			backlog,
		},
	| {
		status: 200,
		headers: [nosniff],
		body: backlog,
		kind: Stream,
		stream_key: key,
		stream_holder: holder,
	}
}

## An answer that is its body, naming no stream.
whole : {
	status : U16,
	headers : List(Http.Header),
	body : List(U8),
} -> Http.Response
whole = |
	{
		status,
		headers,
		body,
	},
| {
	status,
	headers,
	body,
	kind: Whole,
	stream_key: [],
	stream_holder: [],
}

## **A PAGE'S HEADERS**: its type, and its defences.
##
## The policy: nothing by default (`default-src 'none'`); the one `<style>`
## Page writes inline (`style-src 'unsafe-inline'`), and the styles a
## script sets; scripts from this origin's own files alone (`script-src
## 'self'`: `ComposeScript`, never an inline `<script>` or an event
## attribute, so markup that slipped into a page still runs nothing); images and video from
## this origin alone (`img-src` and `media-src 'self'`), the most
## `SecureImageTag` will ever allow, a conversation's own uploads; no
## framing (`frame-ancestors 'none'`), no `<base>` (`base-uri 'none'`), a
## form posts only back here (`form-action 'self'`), and the script's
## stream connects only here (`connect-src 'self'`).
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

## **TAKE THE ANSWER AS THE TYPE IT SAYS**: no browser guesses another.
nosniff : Http.Header
nosniff = { name: "x-content-type-options".to_utf8(), value: "nosniff".to_utf8() }

# ── tests
## An answer's headers, as a test reads them.
header_pairs : Http.Response -> List((Str, Str))
header_pairs = |response| response.headers.map(|h| (Str.from_utf8_lossy(h.name), Str.from_utf8_lossy(h.value)))

# A page carries its type, the policy and nosniff, whatever its status.
expect
	[200, 404, 500].all(
		|status|
			header_pairs(HttpAnswer.notice(status, { title: "t", said: "s" }))
				== [
					("content-type", "text/html; charset=utf-8"),
					("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'self'; img-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; connect-src 'self'"),
					("x-content-type-options", "nosniff"),
				],
	)

## A 405's headers and words, as a test reads them.
refused_with : [GetAndPost, GetOnly, PostOnly] -> (List((Str, Str)), Str)
refused_with = |allowed| {
	answered = HttpAnswer.method_not_allowed(allowed)
	(header_pairs(answered), Str.from_utf8_lossy(answered.body))
}

# The 405 is plain text, not sniffed, allowing each path's own methods; the
# 303 has no body, so only its place.
expect
	refused_with(GetAndPost)
		== (
			[
				("allow", "GET, POST"),
				("content-type", "text/plain; charset=utf-8"),
				("x-content-type-options", "nosniff"),
			],
			"GET or POST only\n",
		)
expect
	refused_with(GetOnly)
		== (
			[
				("allow", "GET"),
				("content-type", "text/plain; charset=utf-8"),
				("x-content-type-options", "nosniff"),
			],
			"GET only\n",
		)
expect
	refused_with(PostOnly)
		== (
			[
				("allow", "POST"),
				("content-type", "text/plain; charset=utf-8"),
				("x-content-type-options", "nosniff"),
			],
			"POST only\n",
		)
expect header_pairs(HttpAnswer.see_other("/a")) == [("location", "/a")]
# An uploaded image: its type, kept for good, not sniffed, its bytes as
# given.
expect {
	answered = HttpAnswer.image({ content_type: "image/png", bytes: [0x89, 0, 0xFF] })
	answered.status == 200
		and header_pairs(answered)
			== [
				("content-type", "image/png"),
				("cache-control", "private, max-age=31536000, immutable"),
				("x-content-type-options", "nosniff"),
			]
		and answered.body == [0x89, 0, 0xFF]
}
# JSON and a plain refusal, each its type, not sniffed; the refusal one line.
expect {
	answered = HttpAnswer.json(200, "{}".to_utf8())
	answered.status == 200
		and header_pairs(answered) == [("content-type", "application/json"), ("x-content-type-options", "nosniff")]
		and answered.body == "{}".to_utf8()
}
expect {
	answered = HttpAnswer.text(415, "no & <b>")
	answered.status == 415
		and header_pairs(answered) == [("content-type", "text/plain; charset=utf-8"), ("x-content-type-options", "nosniff")]
		and answered.body == "no & <b>\n".to_utf8()
}
# Every whole answer names no stream; a stream is a 200 on its key, for its
# holder, its backlog first, not sniffed.
expect
	[
		HttpAnswer.notice(404, { title: "t", said: "s" }),
		HttpAnswer.see_other("/a"),
		HttpAnswer.script([]),
		HttpAnswer.method_not_allowed(GetOnly),
		HttpAnswer.image({ content_type: "image/png", bytes: [] }),
		HttpAnswer.json(200, []),
		HttpAnswer.text(400, "x"),
	].all(|answered| answered.kind == Whole and answered.stream_key == [] and answered.stream_holder == [])
expect {
	answered = HttpAnswer.stream({
		key: "k".to_utf8(),
		holder: "1".to_utf8(),
		backlog: "id: 1\n".to_utf8(),
	})
	answered.kind == Stream
		and answered.status == 200
		and answered.stream_key == "k".to_utf8()
		and answered.stream_holder == "1".to_utf8()
		and answered.body == "id: 1\n".to_utf8()
		and header_pairs(answered) == [("x-content-type-options", "nosniff")]
}
# A script: JavaScript, never cached unasked, not sniffed, its bytes as
# given; and no page's policy, which is a document's.
expect {
	answered = HttpAnswer.script("x();\n".to_utf8())
	answered.status == 200
		and header_pairs(answered)
			== [
				("content-type", "text/javascript; charset=utf-8"),
				("cache-control", "no-cache"),
				("x-content-type-options", "nosniff"),
			]
		and answered.body == "x();\n".to_utf8()
}

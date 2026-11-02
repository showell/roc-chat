## **THE RESPONSES THE CHAT GIVES**, built once each: a page with its
## status, a script, a redirect after a POST, and the refusal of a method.
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
	page = |status, html| {
		status,
		headers: page_headers,
		body: html.to_utf8(),
	}

	## **A NOTICE PAGE** (`Page.notice`) with `status`.
	notice : U16, { title : Str, said : Str } -> Http.Response
	notice = |status, words| HttpAnswer.page(status, Page.notice(words))

	## **303 SEE OTHER**, to `url_path`: after a POST, the browser GETs the
	## page, so a reload never posts again.
	see_other : Str -> Http.Response
	see_other = |url_path| {
		status: 303,
		headers: [{ name: "location".to_utf8(), value: url_path.to_utf8() }],
		body: [],
	}

	## **A SCRIPT**, `bytes` (the app's own: `ComposeScript`), as UTF-8
	## JavaScript, which `nosniff` requires of a script a page runs. A
	## browser asks again before using its copy (`no-cache`), so a changed
	## script is never stale.
	script : List(U8) -> Http.Response
	script = |bytes| {
		status: 200,
		headers: [
			{ name: "content-type".to_utf8(), value: "text/javascript; charset=utf-8".to_utf8() },
			{ name: "cache-control".to_utf8(), value: "no-cache".to_utf8() },
			nosniff,
		],
		body: bytes,
	}

	## **405**: the path takes only the methods `allowed` names: a
	## conversation's GET and POST, or a script's GET.
	method_not_allowed : [GetAndPost, GetOnly] -> Http.Response
	method_not_allowed = |allowed| {
		methods =
			match allowed {
				GetAndPost => { header: "GET, POST", said: "GET or POST only\n" }
				GetOnly => { header: "GET", said: "GET only\n" }
			}
		{
			status: 405,
			headers: [
				{ name: "allow".to_utf8(), value: methods.header.to_utf8() },
				{ name: "content-type".to_utf8(), value: "text/plain; charset=utf-8".to_utf8() },
				nosniff,
			],
			body: methods.said.to_utf8(),
		}
	}
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
## framing (`frame-ancestors 'none'`), no `<base>` (`base-uri 'none'`), and
## a form posts only back here (`form-action 'self'`).
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
	],
	"; ",
)

## **TAKE THE ANSWER AS THE TYPE IT SAYS**: no browser guesses another.
nosniff : Http.Header
nosniff = { name: "x-content-type-options".to_utf8(), value: "nosniff".to_utf8() }

# ── tests
## An answer's headers, as a test reads them.
said : Http.Response -> List((Str, Str))
said = |response| response.headers.map(|h| (Str.from_utf8_lossy(h.name), Str.from_utf8_lossy(h.value)))

# A page carries its type, the policy and nosniff, whatever its status.
expect
	[200, 404, 500].all(
		|status|
			said(HttpAnswer.notice(status, { title: "t", said: "s" }))
				== [
					("content-type", "text/html; charset=utf-8"),
					("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'self'; img-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"),
					("x-content-type-options", "nosniff"),
				],
	)

## A 405's headers and words, as a test reads them.
refused_with : [GetAndPost, GetOnly] -> (List((Str, Str)), Str)
refused_with = |allowed| {
	answered = HttpAnswer.method_not_allowed(allowed)
	(said(answered), Str.from_utf8_lossy(answered.body))
}

# The 405 is plain text, not sniffed, allowing each path's own methods; the
# 303 has no body, so only its place.
expect
	[GetAndPost, GetOnly].map(refused_with)
		== [
			(
				[
					("allow", "GET, POST"),
					("content-type", "text/plain; charset=utf-8"),
					("x-content-type-options", "nosniff"),
				],
				"GET or POST only\n",
			),
			(
				[
					("allow", "GET"),
					("content-type", "text/plain; charset=utf-8"),
					("x-content-type-options", "nosniff"),
				],
				"GET only\n",
			),
		]
expect said(HttpAnswer.see_other("/a")) == [("location", "/a")]
# A script: JavaScript, never cached unasked, not sniffed, its bytes as
# given; and no page's policy, which is a document's.
expect {
	answered = HttpAnswer.script("x();\n".to_utf8())
	(
		answered.status,
		said(answered),
		answered.body,
	)
		== (
			200,
			[
				("content-type", "text/javascript; charset=utf-8"),
				("cache-control", "no-cache"),
				("x-content-type-options", "nosniff"),
			],
			"x();\n".to_utf8(),
		)
}

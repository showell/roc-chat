## **THE RESPONSES THE CHAT GIVES**, built once each: a page with its
## status, a redirect after a POST, and the refusal of a method.
##
## **EVERY PAGE CARRIES ITS DEFENCES** (`page_headers`, their one home): a
## Content-Security-Policy that lets the page load nothing but its own
## inline style sheet and same-origin images, run no script, be framed by
## no one and post only to itself; and `nosniff`, so a browser takes each
## answer as the type it says.
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

	## **405**: the path is a conversation's, which takes only GET and POST.
	method_not_allowed : Http.Response
	method_not_allowed = {
		status: 405,
		headers: [
			{ name: "allow".to_utf8(), value: "GET, POST".to_utf8() },
			{ name: "content-type".to_utf8(), value: "text/plain; charset=utf-8".to_utf8() },
			nosniff,
		],
		body: "GET or POST only\n".to_utf8(),
	}
}

## **A PAGE'S HEADERS**: its type, and its defences.
##
## The policy: nothing by default (`default-src 'none'`); the one `<style>`
## Page writes inline (`style-src 'unsafe-inline'`); images and video from
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
					("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"),
					("x-content-type-options", "nosniff"),
				],
	)
# The 405 is plain text, not sniffed; the 303 has no body, so only its place.
expect
	said(HttpAnswer.method_not_allowed)
		== [
			("allow", "GET, POST"),
			("content-type", "text/plain; charset=utf-8"),
			("x-content-type-options", "nosniff"),
		]
expect said(HttpAnswer.see_other("/a")) == [("location", "/a")]

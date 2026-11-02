## **THE RESPONSES THE CHAT GIVES**, built once each: a page with its
## status, a redirect after a POST, and the refusal of a method.
import pf.Http
import Page
import TrustedHtml

HttpAnswer :: [].{

	## `page`, with `status`, as UTF-8 HTML.
	page : U16, TrustedHtml -> Http.Response
	page = |status, html| {
		status,
		headers: [{ name: "content-type".to_utf8(), value: "text/html; charset=utf-8".to_utf8() }],
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
		],
		body: "GET or POST only\n".to_utf8(),
	}
}

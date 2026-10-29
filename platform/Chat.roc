## A REQUEST AS THE HOST HANDS IT, AND THE ANSWER: each crosses as a C struct
## (host/seam/chat_abi.zig lays them out and asserts their sizes, and
## host/seam/glue_test.zig holds them to roc glue's layout).
##
## The path crosses as bytes, never `Str`: a request can name bytes that are
## not UTF-8, and the parts of the path a route hands back to the host must
## be the bytes that came in.
Chat := [].{

	## **THE TAGS CROSS AS ONE BYTE EACH, NUMBERED ALPHABETICALLY** (Roc's
	## layout of a tag union with no payloads): host/seam/chat_route.zig
	## lists each union's names in that order. A tag added here is added
	## there.

	## A request's method, as the router tells them apart.
	Method : [
		Get,
		Head,
		Post,
		Other,
	]

	## **WHAT GITHUB'S EXCHANGE CAME TO**, on the second call of a request
	## whose first answered `exchange` (decision D1): the host let the turn
	## go, exchanged the code with GitHub on the connection's own task, and
	## called again with the same request and this:
	## - `Known`: GitHub's numeric id and login for the code (`github_id`,
	##   `login`);
	## - `Refused`: GitHub said no to the code (bad or expired);
	## - `Failed`: no answer in time, or none that made sense;
	## - `NotAsked`: no exchange (every first call).
	## `github_id` and `login` are 0 and empty but for `Known`. The client
	## secret and GitHub's token never cross.
	Exchanged : {
		status : [Failed, Known, NotAsked, Refused],
		github_id : U64,
		login : List(U8),
	}

	## `path` is the request target up to its query: "/" or starting with
	## "/". `exchanged` is GitHub's answer on a second call.
	Request : {
		path : List(U8),
		method : Method,
		exchanged : Exchanged,
	}

	## The exchange's answer as a tag union: GitHub's identity, or why not.
	exchanged : Request -> [Known({ id : U64, login : List(U8) }), Refused, Failed, NotAsked]
	exchanged = |req|
		match req.exchanged.status {
			Known => Known({ id: req.exchanged.github_id, login: req.exchanged.login })
			Refused => Refused
			Failed => Failed
			NotAsked => NotAsked
		}

	## A response header the answer adds. **THE HOST SENDS ONLY THE NAMES
	## ON ITS LIST** (`set-cookie`, `cache-control`, `location`), and a name
	## off it, or a CR or LF in a name or value, is the Roc's bug: a 500.
	## What a cookie's attributes are is the Roc's policy.
	Header : {
		name : List(U8),
		value : List(U8),
	}

	## What the answer is:
	## - `Respond`: `status` with `body`, and a content-type when
	##   `content_type` is not empty (`sniff` `Forbid`: the browser is told
	##   not to guess another);
	## - `NotAllowed`: a 405 naming `allow`;
	## - `Answered`: answered by the host inside the call (a body too big, a
	##   script), which the host sends;
	## - `NotFound`: the plain 404;
	## - `Exchange`: GitHub's code (in `body`) to exchange outside the turn;
	##   the host calls again with the same request and what GitHub said
	##   (`Request.exchanged`). Once a request: a second is the Roc's bug, a
	##   500;
	## - `Stream`: an event stream held by the host on the bus key
	##   `stream_key`, subscribed in this call's turn: `body` first (the
	##   backlog the Roc read in the same turn), then each frame published to
	##   the key, verbatim, until the reader goes or falls behind.
	Kind : [
		Respond,
		NotAllowed,
		Answered,
		NotFound,
		Exchange,
		Stream,
	]

	## Whether the browser may guess a type other than `content_type`
	## (`Forbid`: the answer says `nosniff`).
	Sniff : [Allow, Forbid]

	Answer : {
		kind : Kind,
		status : U16,
		content_type : List(U8),
		body : List(U8),
		headers : List(Header),
		allow : Method,
		sniff : Sniff,
		stream_key : List(U8),
	}

	## The plain "not found", and every other answer's empty fields.
	not_found : Answer
	not_found = {
		kind: NotFound,
		status: 0,
		content_type: [],
		body: [],
		headers: [],
		allow: Other,
		sniff: Allow,
		stream_key: [],
	}

	## The content types the chat answers in.
	html : List(U8)
	html = Str.to_utf8("text/html; charset=utf-8")

	text : List(U8)
	text = Str.to_utf8("text/plain; charset=utf-8")

	## `status` with `body`, typed `content_type` when it is not empty.
	respond : U16, { content_type : List(U8), body : List(U8) } -> Answer
	respond = |status, { content_type, body }| {
		..not_found,
		kind: Respond,
		status,
		content_type,
		body,
	}

	## A 200 of text, never sniffed for another type.
	plain : List(U8) -> Answer
	plain = |body| {
		..respond(200, { content_type: text, body }),
		sniff: Forbid,
	}

	## `answer` with the header `name: value` added.
	with_header : Answer, Str, List(U8) -> Answer
	with_header = |answer, name, value| {
		..answer,
		headers: List.append(answer.headers, { name: Str.to_utf8(name), value }),
	}

	## A 405 naming `allow`.
	not_allowed : Method -> Answer
	not_allowed = |allow| {
		..not_found,
		kind: NotAllowed,
		allow,
	}

	## **ASK THE HOST TO EXCHANGE GITHUB'S `code`**, then to call again.
	exchange : List(U8) -> Answer
	exchange = |code| { ..not_found, kind: Exchange, body: code }

	## The host answered inside the call, or failed there.
	answered : Answer
	answered = { ..not_found, kind: Answered }

	## The stream on the bus key `key`: `backlog` first (finished frames,
	## read in this call), then each frame published to `key`.
	stream : { key : List(U8), backlog : List(U8) } -> Answer
	stream = |{ key, backlog }| {
		..not_found,
		kind: Stream,
		stream_key: key,
		body: backlog,
	}
}

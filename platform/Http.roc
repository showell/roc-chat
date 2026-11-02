## **A REQUEST AS THE HOST HANDS IT, AND THE RESPONSE THE APP GIVES BACK**:
## each crosses the seam as a C struct (host/seam.zig lays them out, and
## host/seam_test.zig holds them to `roc glue`'s layout). There is no
## routing here: the app reads the method and the path and decides.
##
## Every part crosses as bytes, never `Str`: a request can carry bytes that
## are not UTF-8, and the app decides at its own door what they are.
Http := [].{

	## A header as sent or as answered: its name and its value.
	Header : {
		name : List(U8),
		value : List(U8),
	}

	## **A REQUEST, PARSED BY THE HOST**: the method (`GET`), the path up to
	## any `?` (`/chat/dm/1_1/plans`), the query after the `?` (empty when
	## there is none), each header as sent, the body, read whole to the
	## host's cap, and the port the server listens on (a fact of the
	## server's, so the app can tell its own origin's `Host` from another's:
	## app/RequestOrigin.roc).
	Request : {
		method : List(U8),
		path : List(U8),
		query : List(U8),
		headers : List(Http.Header),
		body : List(U8),
		port : U16,
	}

	## **THE APP'S ANSWER**: the status, the headers and the body, written
	## by the host as given. A header name or value holding a CR, an LF or
	## a NUL is the app's bug: the host answers a 500 instead.
	Response : {
		status : U16,
		headers : List(Http.Header),
		body : List(U8),
	}
}

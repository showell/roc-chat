## **GOPHER-ROC'S PLATFORM**: two entries into the app, and the host's
## primitives as effects (Host.roc).
##
## - `roc_page` (the demo, host/demo.zig): a topic's name and its transcript
##   in, the page out.
## - `roc_handle_http_request` (the server, host/http.zig): a request in
##   (Http.roc), the response out. The host routes nothing: the app does.
##
## Each hosted function's symbol is its name in Host.roc, without the `!`.
platform ""
	requires {
		handle_http_request! : Http.Request => Http.Response,
		page : List(U8), List(U8) -> List(U8)
	}
	exposes [
		Host,
		Http,
	]
	packages {}
	provides {
		"roc_handle_http_request": handle_for_host!,
		"roc_page": page_for_host,
	}
	hosted {
		"append_utf8_bytes_to_file": Host.append_utf8_bytes_to_file!,
		"create_file_with_utf8_bytes_unless_it_exists": Host.create_file_with_utf8_bytes_unless_it_exists!,
		"current_utc_seconds_since_epoch": Host.current_utc_seconds_since_epoch!,
		"fill_with_random_bytes": Host.fill_with_random_bytes!,
		"list_names_in_directory": Host.list_names_in_directory!,
		"make_directory_and_its_parents": Host.make_directory_and_its_parents!,
		"publish_bytes_to_streams_on_key": Host.publish_bytes_to_streams_on_key!,
		"read_utf8_bytes_from_file": Host.read_utf8_bytes_from_file!,
		"replace_file_with_utf8_bytes_atomically": Host.replace_file_with_utf8_bytes_atomically!,
	}
	targets: {
		x64musl: {
			inputs: [app],
			output: Archive,
		},
	}

import Host
import Http

page_for_host : List(U8), List(U8) -> List(U8)
page_for_host = |topic, transcript| page(topic, transcript)

handle_for_host! : Http.Request => Http.Response
handle_for_host! = |request| handle_http_request!(request)

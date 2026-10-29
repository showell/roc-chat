## THE HOST'S ANSWERS, AS EFFECTS: each is asked when the app asks it, inside
## the request's call (host/seam/chat_abi.zig answers each).
Host := [].{

	## **THE REQUEST'S BODY, AT MOST `limit` BYTES**: the host has read it
	## whole before the call, to its own cap. `Read`, its bytes beside it;
	## `Answered` when it is longer than `limit` and the host has answered
	## the request instead (a 413).
	read_body! : U64 => { bytes : List(U8), status : [Answered, Read] }

	## **A REQUEST HEADER'S VALUES**, each as sent, by its name in any case:
	## none when it was not sent. The host copied them before it read the
	## body, which reuses the buffer they were in.
	read_header! : List(U8) => List(List(U8))

	## **A STATIC SCRIPT SERVED**: the script `name` of the chat client's
	## bundles, answered by the host (its hash its ETag, a 304 when the
	## browser has it). `Missing` when there is no script of the name:
	## nothing is answered.
	serve_script! : List(U8) => [Missing, Served]

	## **THE BUS** (host/bus.zig): `frame`, one SSE frame (`Sse.frame`
	## makes it), to every stream held on the bus key `key` (any bytes the
	## app chooses), each its own copy, written verbatim. It cannot fail: a
	## stream whose mailbox is full ends, and its browser resumes.
	publish! : List(U8), List(U8) => {}

	## **A STUB, FOR THE STUB ROUTE ALONE** (host/stub_log.zig): `frame`
	## kept after `key`'s others, in the host's memory. Step 6 replaces it
	## with the store's `append!`.
	stub_append! : List(U8), List(U8) => {}

	## **A STUB, FOR THE STUB ROUTE ALONE**: `key`'s frames, oldest first.
	## Step 6 replaces it with the store's `read!`.
	stub_read! : List(U8) => List(List(U8))
}

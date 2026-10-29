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

	## **THE FILES** under the data root (host/files.zig), `path` relative
	## to it. A path that is empty, absolute or has a `.`, `..` or empty
	## part is the Roc's bug: `Failed`, never `Missing`.
	##
	## **`Failed` HAS FAILED THE REQUEST**: its answer is a 500 whatever the
	## Roc answers, and the host does nothing more for it. A ranged read,
	## `read_at!`, is the exception: its failure is logged and the request
	## goes on, the Roc's to answer.
	##
	## **MISSING AND FAILED ARE NEVER ONE ANSWER**: what is read is often
	## rewritten, so a file that could not be read, taken for no file,
	## would be written over.

	## The file's bytes (`Found`), nothing there (`Missing`), or a read
	## that failed (`Failed`).
	read! : List(U8) => {
		bytes : List(U8),
		status : [
			Failed,
			Found,
			Missing,
		],
	}

	## **A RANGED READ** (a page of a transcript, Store.load_span!): at most
	## `max` bytes from `offset` (fewer where the file ends first, none
	## past its end). `Failed` is logged, never the request's failure.
	read_at! : List(U8),
	U64,
	U64 => {
		bytes : List(U8),
		status : [
			Failed,
			Found,
			Missing,
		],
	}

	## A file's size in bytes and its last change in whole seconds since
	## the epoch. A folder is `Failed`.
	read_stat! : List(U8) => {
		mtime : I64,
		size : U64,
		status : [
			Failed,
			Found,
			Missing,
		],
	}

	## A folder's entries, each one's name and kind, in the order the disk
	## gives them. A path that is a file is `Failed`.
	list! : List(U8) => {
		entries : List(
			{
				kind : [
					Dir,
					File,
					Other,
				],
				name : List(U8),
			},
		),
		status : [
			Failed,
			Found,
			Missing,
		],
	}

	## **THE WHOLE FILE AS `bytes`, ATOMICALLY AND DURABLY**: a temporary
	## beside it, synced, renamed over it, its folder synced; its folders
	## made as needed. A stop part-way leaves the old file whole.
	write! : List(U8), List(U8) => [Failed, Written]

	## **`bytes` AT THE FILE'S END, SYNCED**, the file and its folders made
	## as needed: the file's size after (`Appended`). What goes before the
	## bytes (a separator, a torn line's newline) is the Roc's.
	append! : List(U8), List(U8) => { size : U64, status : [Appended, Failed] }

	## The file removed; one not there is gone already.
	remove! : List(U8) => [Failed, Removed]

	## **SIGN-IN'S FACTS** (host/signin.zig, host/auth/): the request's
	## query and time, the OS's entropy, SHA-256, and the site key's MAC.
	## **THE ROC NEVER HOLDS THE SIGNING KEY**: `sign!` and `verify!` use the
	## host's. A failure (no entropy, no key) has failed the request, as a
	## file's does.

	## A query field's values, as written (not decoded), in order; none
	## when the target has no such field.
	read_query! : List(U8) => List(List(U8))

	## The request's time, Unix seconds: one time for the whole call.
	read_time! : {} => I64

	## `n` bytes of the OS's entropy (a nonce, a session's secret), at most
	## 1,024.
	random_bytes! : U64 => List(U8)

	## SHA-256 of the bytes: 32 bytes (Stored.SecretHash).
	hash! : List(U8) => List(U8)

	## HMAC-SHA256 of the bytes under the site's signing key: 32 bytes.
	sign! : List(U8) => List(U8)

	## Whether `mac` is the site key's MAC of `bytes`, compared in constant
	## time.
	verify! : List(U8), List(U8) => [Invalid, Valid]

	## A public setting, never a secret: the first admin's GitHub id (its
	## decimal digits, or empty), GitHub's base URL for the authorize page,
	## the OAuth app's client id, and the chat's public origin.
	read_config! : [
		FirstAdmin,
		GitHubAuthorize,
		GitHubClientId,
		Origin,
	] => List(U8)

	## **THE BUS** (host/bus.zig): `frame`, one SSE frame (`Sse.frame`
	## makes it), to every stream held on the bus key `key` (any bytes the
	## app chooses), each its own copy, written verbatim. It cannot fail: a
	## stream whose mailbox is full ends, and its browser resumes.
	publish! : List(U8), List(U8) => {}

}

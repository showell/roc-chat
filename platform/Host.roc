## **THE HOST'S PRIMITIVES, AS EFFECTS** (docs/platform.md describes each
## one; host/file_primitives.zig keeps them). They are general: they know
## nothing of chats. The app's `FileSystem` module is the only caller of the
## file primitives, and it alone knows which file holds what.
##
## **EVERY PATH IS RELATIVE TO THE DATA ROOT, AND CONFINED TO IT**: a path
## that is empty, absolute, holds an empty part or a part starting with `.`,
## or passes through a link, is `PathRefused`, and nothing is touched.
##
## **TEXT ONLY, BOTH WAYS**: bytes that are not UTF-8 are `NotUtf8`, on
## every write (nothing is written) and every read (nothing is handed back).
##
## **`Failed` IS EVERYTHING ELSE** (a disk error, a folder the server may
## not enter, a failed fsync): the host logs it, naming the primitive, the
## path and the error.
##
## **THE TAGS CROSS AS ONE BYTE, NUMBERED ALPHABETICALLY**, Roc's layout of
## a tag union with no payloads; host/seam_test.zig holds the host's enums
## to `roc glue`'s.
Host := [].{

	## The file's text (`Found`, in `bytes`), or why not: nothing there, it
	## or a folder on its path (`Missing`).
	read_utf8_bytes_from_file! : List(U8) => {
		bytes : List(U8),
		status : [
			Failed,
			Found,
			Missing,
			NotUtf8,
			PathRefused,
		],
	}

	## `bytes` added at the file's end (O_APPEND), then fsynced; the file
	## made when it is missing. Its folder must exist (`MissingDirectory`).
	append_utf8_bytes_to_file! : List(U8),
	List(U8) => [
		Appended,
		Failed,
		MissingDirectory,
		NotUtf8,
		PathRefused,
	]

	## **A ONE-TIME RECORD**: the file made holding exactly `bytes`
	## (O_EXCL), unless something is already at its name
	## (`AlreadyExists`, nothing changed). Its folder must exist.
	create_file_with_utf8_bytes_unless_it_exists! : List(U8),
	List(U8) => [
		AlreadyExists,
		Created,
		Failed,
		MissingDirectory,
		NotUtf8,
		PathRefused,
	]

	## **THE WHOLE FILE AS `bytes`, ATOMICALLY**: a temporary beside it,
	## fsynced, renamed over it, the folder fsynced; a failure before the
	## rename leaves the old file whole. Its folder must exist.
	replace_file_with_utf8_bytes_atomically! : List(U8),
	List(U8) => [
		Failed,
		MissingDirectory,
		NotUtf8,
		PathRefused,
		Replaced,
	]

	## The folder and each folder above it, made as needed (`Made` when
	## they all exist after, as they may before).
	make_directory_and_its_parents! : List(U8) => [Failed, Made, PathRefused]

	## The names in a folder, sorted bytewise, never one starting with `.`.
	list_names_in_directory! : List(U8) => {
		names : List(List(U8)),
		status : [
			Failed,
			Found,
			Missing,
			NotUtf8,
			PathRefused,
		],
	}

	## **THE CLOCK**: whole seconds since 1970-01-01T00:00:00Z.
	current_utc_seconds_since_epoch! : {} => I64

	## `count` bytes from the OS's secure random source, at most 1,024: more
	## is the app's bug, and the host stops.
	fill_with_random_bytes! : U64 => List(U8)

	## `bytes` sent, as they are, to every stream held open on `key`
	## (`Http.Response`'s `Stream`); none there, and nothing is sent.
	publish_bytes_to_streams_on_key! : List(U8), List(U8) => {}
}

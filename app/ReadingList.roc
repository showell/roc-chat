## **A HUMAN'S READING LIST: WHAT A SAVE DOES** (the old app's "save to
## reading list", chat-client's js/chat.js `doSave` and angry-gopher's
## reading_list.zig; there it was a Docs doc, here its own list). Each
## save is the saver's copy of a message as it was (SavedCodec), with a
## line about it, newest last. Pure.
##
## - **A NOTE** is the old `composeEntry`'s: its ends trimmed of spaces,
##   tabs and line breaks, each line break left inside made a space (the
##   old `oneLine`), and "read later" when nothing is left (the old popup's
##   default). Its length has no rule of its own; the list's is the one.
##   Any other control byte is kept, as the old one kept it; the store
##   escapes it (SavedCodec).
## - **A MESSAGE SAVED AGAIN** is the one save, its id kept, moved to the
##   newest end with its note and copy those of now: the nearest the list
##   comes to the old doc's appending a second block, without holding the
##   message twice.
## - **AN ID IS NEVER GIVEN TWICE**: a new save takes the list's `next`, and
##   `next` only grows, so a removed save's id is never another's.
## - **THE LIST HOLDS AT MOST `most_bytes`** as stored, as the old doc did;
##   a save or a note that would pass it is refused.
import Cast
import ChannelName
import SavedCodec
import Topic
import TopicName

ReadingList := [].{

	## The most a list holds, as stored: the old doc's 1 MiB.
	most_bytes : U64
	most_bytes = 1024 * 1024

	## **THE NOTE `raw` MAKES**, by the rule above.
	note_of : List(U8) -> Try(Str, [NotUtf8])
	note_of = |raw| {
		trimmed = trim_end(trim_start(raw))
		flat = trimmed.map(|b| if (b == '\n' or b == '\r') ' ' else b)
		text = Str.from_utf8(flat).map_err(|_| NotUtf8)?
		if (text.is_empty()) Ok("read later") else Ok(text)
	}

	## **THE LIST WITH `save` IN IT**, at its newest end: a message already
	## saved keeps its save's id; a new one takes `next`. Past `most_bytes`,
	## refused.
	saved : SavedCodec.Book, SavedCodec.Fields -> Try(SavedCodec.Book, [TooBig])
	saved = |book, save| {
		same = |e| e.place == save.place and e.n == save.n
		next =
			match book.saves.find_first(same) {
				Ok(e) => {
					next: book.next,
					saves: book.saves.drop_if(same).append({ ..save, id: e.id }),
				}
				Err(NotFound) => {
					next: book.next + 1,
					saves: book.saves.append({ ..save, id: book.next }),
				}
			}
		within(next)
	}

	## **WHICH OF `at`'S MESSAGES ARE ON THE LIST**, by number, ascending.
	numbers_in : SavedCodec.Book, Topic.At -> List(U64)
	numbers_in = |book, at|
		book.saves.keep_if(|e| e.place == at).map(|e| e.n).sort_with(
			|
				a,
				b,
			| if (a < b) Before else if (a > b) After else Same,
		)

	## The list without save `id`; its `next` as it was.
	without : SavedCodec.Book, U64 -> Try(SavedCodec.Book, [NoSuchSave])
	without = |book, id|
		if book.saves.any(|e| e.id == id) {
			Ok({ ..book, saves: book.saves.drop_if(|e| e.id == id) })
		} else {
			Err(NoSuchSave)
		}

	## The list with save `id`'s note changed, in its place; past
	## `most_bytes`, refused.
	renoted : SavedCodec.Book,
	{ id : U64, note : Str } -> Try(
		SavedCodec.Book,
		[NoSuchSave, TooBig],
	)
	renoted = |book, { id, note }|
		if book.saves.any(|e| e.id == id) {
			within({
				..book,
				saves: book.saves.map(|e| if (e.id == id) { ..e, note } else e),
			}).map_err(|TooBig| TooBig)
		} else {
			Err(NoSuchSave)
		}

	## Newest first, as the list's page shows it.
	newest_first : SavedCodec.Book -> List(SavedCodec.Fields)
	newest_first = |book| book.saves.fold(
		List.with_capacity(book.saves.len()),
		|done, e| List.prepend(done, e),
	)
}

## The list, if it is within `most_bytes` as stored.
within : SavedCodec.Book -> Try(SavedCodec.Book, [TooBig])
within = |book| if (SavedCodec.file(book).len() > ReadingList.most_bytes) Err(TooBig) else Ok(book)

## The bytes without the spaces, tabs and line breaks at their start (the
## old `std.mem.trim`'s set).
trim_start : List(U8) -> List(U8)
trim_start = |bytes|
	match bytes {
		[c, .. as rest] if is_trimmed(c) => trim_start(rest)
		_ => bytes
	}

## And at their end.
trim_end : List(U8) -> List(U8)
trim_end = |bytes|
	match bytes {
		[.. as rest, c] if is_trimmed(c) => trim_end(rest)
		_ => bytes
	}

is_trimmed : U8 -> Bool
is_trimmed = |c| c == ' ' or c == '\t' or c == '\r' or c == '\n'

# ── tests
place_of : Str, Str -> Topic.At
place_of = |c, t|
	match (ChannelName.from_str(c), TopicName.from_str(t)) {
		(Ok(channel), Ok(topic)) => { channel, topic }
		_ => crash "place_of: a test's names are names"
	}

save_of : {
	place : Topic.At,
	n : U64,
	note : Str,
} -> SavedCodec.Fields
save_of = |
	{
		place,
		n,
		note,
	},
| {
	id: 0,
	saved: 100,
	place,
	n,
	by: Cast.ann.id(),
	from: "Ann",
	at: 50,
	note,
	body: "hi".to_utf8(),
}

banana : Topic.At
banana = place_of("Orchard", "Banana")

## The book after each save, in turn.
saving : List(SavedCodec.Fields) -> SavedCodec.Book
saving = |saves| saves.fold(
	SavedCodec.empty,
	|book, s| ReadingList.saved(book, s) ?? crash "saving: a test's list is small",
)

# The note's rule: the old trim and `oneLine`, "read later" for nothing.
expect ReadingList.note_of("  ".to_utf8()) == Ok("read later")
expect ReadingList.note_of("".to_utf8()) == Ok("read later")
expect ReadingList.note_of(" \r\n look\r\nagain\t\n".to_utf8()) == Ok("look  again")
expect ReadingList.note_of("a\u(7)b".to_utf8()) == Ok("a\u(7)b")
expect ReadingList.note_of(
	List.repeat(
		'x',
		5000,
	),
) == Ok(Str.from_utf8(List.repeat('x', 5000)) ?? "")
expect ReadingList.note_of([0xFF]) == Err(NotUtf8)

# A new save takes `next`; a message saved again keeps its id and moves to
# the newest end with its new note.
expect {
	book = saving([
		save_of({
			place: banana,
			n: 5,
			note: "a",
		}),
		save_of({
			place: banana,
			n: 7,
			note: "b",
		}),
		save_of({
			place: banana,
			n: 5,
			note: "c",
		}),
	])
	book.saves.map(
		|e| (
			e.id,
			e.n,
			e.note,
		),
	) == [
		(
			2,
			7,
			"b",
		),
		(
			1,
			5,
			"c",
		),
	] and book.next == 3
}
# The same number in another topic is another message.
expect {
	book = saving([
		save_of({
			place: banana,
			n: 5,
			note: "a",
		}),
		save_of({
			place: place_of("Orchard", "Apple"),
			n: 5,
			note: "b",
		}),
	])
	ReadingList.numbers_in(book, banana) == [5] and book.saves.len() == 2
}
expect {
	book = saving([
		save_of({
			place: banana,
			n: 9,
			note: "x",
		}),
		save_of({
			place: banana,
			n: 3,
			note: "y",
		}),
		save_of({
			place: place_of("Meadow", "Banana"),
			n: 4,
			note: "z",
		}),
	])
	ReadingList.numbers_in(book, banana) == [3, 9]
}
# An id is never given twice: removed, its id stays spent.
expect {
	book = saving([
		save_of({
			place: banana,
			n: 5,
			note: "a",
		}),
		save_of({
			place: banana,
			n: 6,
			note: "b",
		}),
	])
	gone = ReadingList.without(book, 2) ?? book
	again = ReadingList.saved(
		gone,
		save_of({
			place: banana,
			n: 7,
			note: "c",
		}),
	) ?? gone
	again.saves.map(|e| e.id) == [1, 3] and again.next == 4
}
# Past the most, refused: a save, and a note.
expect ReadingList.saved(
	SavedCodec.empty,
	{ ..save_of({
		place: banana,
		n: 1,
		note: "a",
	}), body: List.repeat('x', ReadingList.most_bytes) },
) == Err(TooBig)
expect {
	book = saving([
		save_of({
			place: banana,
			n: 5,
			note: "a",
		}),
	])
	long = Str.from_utf8(List.repeat('x', ReadingList.most_bytes)) ?? ""
	ReadingList.renoted(book, { id: 1, note: long }) == Err(TooBig)
}
# Removed and renoted by id; an id not there is said.
expect {
	book = saving([
		save_of({
			place: banana,
			n: 5,
			note: "a",
		}),
	])
	ReadingList.without(book, 1) == Ok({
		next: 2,
		saves: [],
	}) and ReadingList.without(book, 2) == Err(NoSuchSave)
}
expect {
	book = saving([
		save_of({
			place: banana,
			n: 5,
			note: "a",
		}),
	])
	(ReadingList.renoted(book, { id: 1, note: "z" }) ?? book).saves.map(|e| e.note) == ["z"]
		and ReadingList.renoted(book, { id: 3, note: "z" }) == Err(NoSuchSave)
}

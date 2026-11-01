## **A HUMAN'S READING LIST: WHAT A SAVE DOES** (the old app's "save to
## reading list", chat-client's js/chat.js `doSave` and angry-gopher's
## reading_list.zig; there it was a Docs doc, here its own list). Each
## save is the saver's copy of a message as it was (SavedCodec), with a
## line about it, newest last. Pure.
##
## - **A NOTE** is one line: its ends trimmed, a line break or other
##   control byte made a space (the old `oneLine`), "read later" when it is
##   empty (the old popup's default), at most `note_most` bytes.
## - **A MESSAGE SAVED AGAIN** is the one save, its note, time and copy
##   those of now, moved to the end: the list never holds a message twice
##   (the old doc gained a second block).
## - **THE LIST HOLDS AT MOST `most_bytes`** as stored, as the old doc
##   did; a save past it is refused.
import Cast
import ChannelName
import Principal
import SavedCodec
import Topic
import TopicName

ReadingList := [].{

	## The most a list holds, as stored: the old doc's 1 MiB.
	most_bytes : U64
	most_bytes = 1024 * 1024

	## The longest note, in bytes.
	note_most : U64
	note_most = 200

	## **THE NOTE `raw` MAKES**, by the rule above.
	note_of : List(U8) -> Try(Str, [NotUtf8, TooLong])
	note_of = |raw| {
		flat = raw.map(|b| if (b < 0x20 or b == 0x7F) ' ' else b)
		trimmed = Str.from_utf8(flat).map_err(|_| NotUtf8)?.trim()
		if trimmed.is_empty() {
			Ok("read later")
		} else if trimmed.to_utf8().len() > ReadingList.note_most {
			Err(TooLong)
		} else {
			Ok(trimmed)
		}
	}

	## **THE LIST WITH `save` IN IT**, at its end: a message already saved
	## keeps its save's id; a new one takes one past the largest. Past
	## `most_bytes`, refused.
	saved : List(SavedCodec.Fields), SavedCodec.Fields -> Try(List(SavedCodec.Fields), [TooBig])
	saved = |list, save| {
		same = |e| e.place == save.place and e.n == save.n
		id =
			match list.find_first(same) {
				Ok(e) => e.id
				Err(NotFound) => list.fold(0, |most, e| U64.max(most, e.id)) + 1
			}
		next = list.drop_if(same).append({ ..save, id })
		if (SavedCodec.file(next).len() > ReadingList.most_bytes) Err(TooBig) else Ok(next)
	}

	## **WHICH OF `at`'S MESSAGES ARE ON THE LIST**, by number, ascending.
	numbers_in : List(SavedCodec.Fields), Topic.At -> List(U64)
	numbers_in = |
		list,
		at,
	| list.keep_if(|e| e.place == at).map(|e| e.n).sort_with(
		|
			a,
			b,
		| if (a < b) Before else if (a > b) After else Same,
	)

	## The list without save `id`.
	without : List(SavedCodec.Fields), U64 -> Try(List(SavedCodec.Fields), [NoSuchSave])
	without = |list, id|
		if (list.any(|e| e.id == id)) Ok(list.drop_if(|e| e.id == id)) else Err(NoSuchSave)

	## The list with save `id`'s note changed, in its place.
	renoted : List(SavedCodec.Fields),
	{ id : U64, note : Str } -> Try(
		List(SavedCodec.Fields),
		[NoSuchSave],
	)
	renoted = |list, { id, note }|
		if list.any(|e| e.id == id) {
			Ok(list.map(|e| if (e.id == id) { ..e, note } else e))
		} else {
			Err(NoSuchSave)
		}

	## Newest first, as the list's page shows it.
	newest_first : List(SavedCodec.Fields) -> List(SavedCodec.Fields)
	newest_first = |list| list.fold(List.with_capacity(list.len()), |done, e| List.prepend(done, e))
}

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
	at: 50,
	note,
	body: "hi".to_utf8(),
}

banana : Topic.At
banana = place_of("Orchard", "Banana")

# The note's rule.
expect ReadingList.note_of("  ".to_utf8()) == Ok("read later")
expect ReadingList.note_of("".to_utf8()) == Ok("read later")
expect ReadingList.note_of(" look\r\nagain\t".to_utf8()) == Ok("look  again")
expect ReadingList.note_of(List.repeat('x', 200)) == Ok(Str.from_utf8(List.repeat('x', 200)) ?? "")
expect ReadingList.note_of(List.repeat('x', 201)) == Err(TooLong)
expect ReadingList.note_of([0xFF]) == Err(NotUtf8)

# A new save takes one past the largest id; a message saved again keeps
# its id and moves to the end with its new note.
expect {
	one = ReadingList.saved(
		[],
		save_of({
			place: banana,
			n: 5,
			note: "a",
		}),
	) ?? []
	two = ReadingList.saved(
		one,
		save_of({
			place: banana,
			n: 7,
			note: "b",
		}),
	) ?? []
	again = ReadingList.saved(
		two,
		save_of({
			place: banana,
			n: 5,
			note: "c",
		}),
	) ?? []
	again.map(
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
	]
}
# The same number in another topic is another message.
expect {
	one = ReadingList.saved(
		[],
		save_of({
			place: banana,
			n: 5,
			note: "a",
		}),
	) ?? []
	two = ReadingList.saved(
		one,
		save_of({
			place: place_of("Orchard", "Apple"),
			n: 5,
			note: "b",
		}),
	) ?? []
	ReadingList.numbers_in(two, banana) == [5] and two.len() == 2
}
expect {
	list = [
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
	]
	ReadingList.numbers_in(list, banana) == [3, 9]
}
# Past the most, refused.
expect {
	big = { ..save_of({
		place: banana,
		n: 1,
		note: "a",
	}), body: List.repeat('x', ReadingList.most_bytes) }
	ReadingList.saved([], big) == Err(TooBig)
}
# Removed and renoted by id; an id not there is said.
expect {
	list = ReadingList.saved(
		[],
		save_of({
			place: banana,
			n: 5,
			note: "a",
		}),
	) ?? []
	ReadingList.without(list, 1) == Ok([]) and ReadingList.without(list, 2) == Err(NoSuchSave)
}
expect {
	list = ReadingList.saved(
		[],
		save_of({
			place: banana,
			n: 5,
			note: "a",
		}),
	) ?? []
	(ReadingList.renoted(list, { id: 1, note: "z" }) ?? []).map(|e| e.note) == ["z"]
		and ReadingList.renoted(list, { id: 3, note: "z" }) == Err(NoSuchSave)
}

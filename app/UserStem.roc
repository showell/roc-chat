## **A USER'S FILE STEM**: `apoorva-2`, from a user's name and id, the one
## home of that spelling. A user's files are named from it
## (`apoorva-2.info`); what each holds is not decided here.
##
## **STRICT, SO SAFE AS A FILE'S NAME AND IN A URL**: each word of the name
## (`Name`: letters, single spaces between words) as its ASCII letters in
## lower case, its accented letters left out, the words joined by `-`; then
## `-` and the id. A word with no ASCII letter is left out, and a name with
## none is the id alone. The id makes a stem unique, so the name's part is
## only for a reader finding the file.
import Ascii
import Name
import UserId

UserStem :: [].{

	## The stem of the user `id`, named `name`.
	of : { name : Name, id : UserId } -> Str
	of = |{ name, id }| {
		words = name.to_str().with_ascii_lowercased().split_on(" ").map(ascii_only).drop_if(Str.is_empty)
		if (words.is_empty()) id.to_str() else "${Str.join_with(words, "-")}-${id.to_str()}"
	}
}

## `word`'s ASCII letters, in order.
ascii_only : Str -> Str
ascii_only = |word|
	Str.from_utf8(word.to_utf8().keep_if(Ascii.is_letter)) ?? crash "UserStem.ascii_only: ASCII letters are UTF-8"

# ── tests
## The stem of `text`'s user, whose id is the one after `count` others'.
stem : Str, U64 -> Str
stem = |text, count| {
	name = Name.from_str(text) ?? crash "UserStem's tests: a test's name is a name"
	id = List.repeat({}, count).fold(
		UserId.steve,
		|at, {}| at.next() ?? crash "UserStem's tests: a test's id fits",
	)
	UserStem.of({ name, id })
}

expect stem("Steve", 0) == "steve-1"
expect stem("apoorva", 1) == "apoorva-2"
expect stem("Steve Howell", 0) == "steve-howell-1"
expect stem("CC", 2) == "cc-3"
# Accented letters left out, and a word left with none.
expect stem("Zoë Ann", 3) == "zo-ann-4"
expect stem("Élodie", 4) == "lodie-5"
expect stem("Zoë Ő Ann", 5) == "zo-ann-6"
# No ASCII letter at all: the id alone, at the first id and the last.
expect stem("Éé", 0) == "1"
expect stem("Ő Ű", 254) == "255"
expect stem("Zoë", 254) == "zo-255"

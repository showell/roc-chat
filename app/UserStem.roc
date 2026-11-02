## **A USER'S FILE STEM**: `apoorva-2`, from a user's name and id, the one
## home of that spelling. A user's files are named from it
## (`apoorva-2.info`); what each holds is not decided here.
##
## **STRICT, SO SAFE AS A FILE'S NAME AND IN A URL**: the name's ASCII
## letters in lower case, and its digits, with every run of anything else
## (a space, `-`, a letter past ASCII) one `-`, none at either end; then
## `-` and the id. A name with no ASCII letter or digit is the id alone.
## The id makes a stem unique, so the name's part is only for a reader
## finding the file.
import Ascii
import Name
import UserId

UserStem :: [].{

	## The stem of the user `id`, named `name`.
	of : { name : Name, id : UserId } -> Str
	of = |{ name, id }| {
		kept = name.to_str().with_ascii_lowercased().to_utf8().map(spelled)
		stem = Str.from_utf8(kept) ?? crash "UserStem.of: ASCII letters, digits and - are UTF-8"
		words = stem.split_on("-").drop_if(Str.is_empty)
		if (words.is_empty()) id.to_str() else "${Str.join_with(words, "-")}-${id.to_str()}"
	}
}

## A byte as a stem spells it: an ASCII letter or digit as it is, any
## other byte `-`.
spelled : U8 -> U8
spelled = |b| if (Ascii.is_letter(b) or Ascii.is_digit(b)) b else '-'

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
# Every run of what is not an ASCII letter or digit is one `-`, and none
# is left at either end; digits are kept.
expect stem("Zoë  Ann", 3) == "zo-ann-4"
expect stem("R2-D2", 4) == "r2-d2-5"
expect stem("-Bea-", 5) == "bea-6"
expect stem("a.b/c_d", 6) == "a-b-c-d-7"
expect stem("Ünal", 7) == "nal-8"
# No ASCII letter or digit: the id alone, at the first id and the last.
expect stem("李", 0) == "1"
expect stem("Zoë", 254) == "zo-255"
expect stem("😀 😀", 254) == "255"

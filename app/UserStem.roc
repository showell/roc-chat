## **A USER'S FILE STEM**: `apoorva-2`, from a user's name and id, the one
## home of that spelling. A user's files are named from it
## (`apoorva-2.info`); what each holds is not decided here.
##
## **STRICT, SO SAFE AS A FILE'S NAME AND IN A URL**: the name's ASCII
## spelling (`NameAlphabet.ascii_spelling`: each letter folded, then
## spelled in ASCII, so `Élodie` is `elodie`), its words joined by `-`;
## then `-` and the id. Every letter has a spelling, so no word is ever
## lost. The id makes a stem unique, so the name's part is only for a
## reader finding the file.
import Name
import NameAlphabet
import UserId

UserStem :: [].{

	## The stem of the user `id`, named `name`.
	of : { name : Name, id : UserId } -> Str
	of = |
		{
			name,
			id,
		},
	| "${NameAlphabet.ascii_spelling(name.written()).replace_each(" ", "-")}-${id.to_str()}"
}

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
# Accented letters as ASCII, one letter or several, in every word.
expect stem("Zoë Ann", 3) == "zoe-ann-4"
expect stem("Élodie", 4) == "elodie-5"
expect stem("Zoë Ő Ann", 5) == "zoe-o-ann-6"
expect stem("Æsir Þór Straße", 6) == "aesir-thor-strasse-7"
# A name of accented letters alone, at the first id and the last.
expect stem("Éé", 0) == "ee-1"
expect stem("Ő Ű", 254) == "o-u-255"

## This module spells a user's file stem, such as `elodie-5`, from the
## user's name and id. A user's files are named from their stem
## (`elodie-5.info`).
##
## The stem is the name's ASCII spelling (`NameAlphabet.ascii_spelling`),
## with `-` between its words, then `-` and the id. So it is safe as a
## file's name and in a URL. The id alone makes a stem unique; the name is
## there for a reader looking for the file.
import Name
import NameAlphabet
import UserId

UserStem :: [].{

	## The stem of the user `id`, named `name`.
	of : { name : Name, id : UserId } -> Str
	of = |
		{ name, id },
	| "${NameAlphabet.ascii_spelling(name.written_text()).replace_each(" ", "-")}-${id.to_str()}"
}

# ── tests
## The stem of the user whose name is `name` and whose id `id` spells.
stem : { name : Str, id : Str } -> Str
stem = |{ name, id }|
	UserStem.of({
		name: Name.from_str(name) ?? crash "UserStem's tests: a test's name is a name",
		id: UserId.from_str(id) ?? crash "UserStem's tests: a test's id is an id",
	})

expect stem({ name: "Steve", id: "1" }) == "steve-1"
expect stem({ name: "apoorva", id: "2" }) == "apoorva-2"
expect stem({ name: "Steve Howell", id: "1" }) == "steve-howell-1"
expect stem({ name: "CC", id: "3" }) == "cc-3"
# Accented letters in ASCII, spelled with one letter or several, in every
# word.
expect stem({ name: "Zoë Ann", id: "4" }) == "zoe-ann-4"
expect stem({ name: "Élodie", id: "5" }) == "elodie-5"
expect stem({ name: "Zoë Ő Ann", id: "6" }) == "zoe-o-ann-6"
expect stem({ name: "Æsir Þór Straße", id: "7" }) == "aesir-thor-strasse-7"
# A name of accented letters alone, at the lowest id and the highest.
expect stem({ name: "Éé", id: "1" }) == "ee-1"
expect stem({ name: "Ő Ű", id: "65535" }) == "o-u-65535"

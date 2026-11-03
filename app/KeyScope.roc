## A key's scope says what an agent's key may do beyond saying who the
## agent is: whether it may read (`read`) and whether it may post (`post`),
## each `Everywhere` the agent itself may, or `Off`. Where the agent may
## read and post is the chat's other rules' (`Access`); a scope only takes
## away. The human chooses it when inviting the agent, and the key it
## redeems to keeps it.
##
## Each reach is kept as a word in a fact file of its own, `everywhere` or
## `off`, roc-chat's words, and a form names it the same way.
import FactFile

KeyScope :: { read : KeyScope.Reach, post : KeyScope.Reach }.{

	## How far one of a key's powers reaches.
	Reach : [Everywhere, Off]

	## A scope that takes nothing away, which an invite gives unless asked
	## otherwise.
	everywhere : KeyScope
	everywhere = KeyScope.({ read: Everywhere, post: Everywhere })

	of : { read : KeyScope.Reach, post : KeyScope.Reach } -> KeyScope
	of = |scope| KeyScope.(scope)

	read : KeyScope -> KeyScope.Reach
	read = |KeyScope.(scope)| scope.read

	post : KeyScope -> KeyScope.Reach
	post = |KeyScope.(scope)| scope.post

	## The reach `word` names, `everywhere` or `off`; unless it is anything
	## else (`NotAReach`), another case included.
	reach_from_word : Str -> Try(KeyScope.Reach, [NotAReach])
	reach_from_word = |word|
		if (word == "everywhere")
			Ok(Everywhere)
		else if (word == "off")
			Ok(Off)
		else
			Err(NotAReach)

	## The word for `reach`, as a file and a form spell it.
	reach_word : KeyScope.Reach -> Str
	reach_word = |reach|
		match reach {
			Everywhere => "everywhere"
			Off => "off"
		}

	## The reach a fact file holds (`FactFile`), or `NotAReach`.
	reach_from_file : List(U8) -> Try(KeyScope.Reach, [NotAReach])
	reach_from_file = |bytes|
		match Str.from_utf8(FactFile.word_from_file(bytes)) {
			Ok(word) => KeyScope.reach_from_word(word)
			Err(_) => Err(NotAReach)
		}

	## The reach as its fact file keeps it.
	reach_to_file : KeyScope.Reach -> List(U8)
	reach_to_file = |reach| KeyScope.reach_word(reach).to_utf8()

	is_eq : _
}

# ── tests
expect KeyScope.everywhere.read() == Everywhere and KeyScope.everywhere.post() == Everywhere
expect KeyScope.of({ read: Off, post: Everywhere }).read() == Off
expect KeyScope.of({ read: Everywhere, post: Off }).post() == Off
# Each reach as its file keeps it, and read back.
expect
	[
		(Everywhere, "everywhere"),
		(Off, "off"),
	].all(
		|
			(
				reach,
				word,
			),
		| KeyScope.reach_to_file(reach) == word.to_utf8() and KeyScope.reach_from_file("${word}\n".to_utf8()) == Ok(reach),
	)
expect
	[
		"",
		"Off",
		"EVERYWHERE",
		"on",
		"every where",
	].all(|word| KeyScope.reach_from_word(word) == Err(NotAReach))
expect KeyScope.reach_from_file([0xff]) == Err(NotAReach)

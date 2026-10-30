## **WHO A POST NAMES**: the participants of its conversation whose display
## name the markdown holds as a word, `@Name` anywhere or `Name` leading the
## post (`CC, a question`), by the names the accounts give now. A word ends
## where an ASCII letter, digit or `_` cannot go on it, so `@CCX` and
## `a@CC.com` name nobody; a name is matched as its bytes are, case and all.
## Only the participants count: a name no participant goes by is text. The
## listeners (Shale's cookbook/listen.shale) and the cap on agents answering
## agents (Conversations.post!) both read this one answer. Pure.
import Ascii
import Bytes
import Principal

Mentions := [].{

	## A participant as a mention finds it: its id and the name it goes by.
	Named : { id : Principal.Id, name : Str }

	## The participants the markdown names, in the order given.
	of : List(U8), List(Mentions.Named) -> List(Principal.Id)
	of = |markdown, participants|
		participants.keep_if(|p| names(markdown, p.name.to_utf8())).map(|p| p.id)

	## **AN AGENT ANSWERING AN AGENT**: a post by an agent or a bot that
	## names another agent or bot. A human's post never is one.
	is_hop : Principal.Id, List(Principal.Id) -> Bool
	is_hop = |by, mentioned|
		!is_human(by) and mentioned.any(|m| !is_human(m) and m != by)
}

is_human : Principal.Id -> Bool
is_human = |id|
	match id {
		Human(_) => Bool.True
		Agent(_) | Bot(_) => Bool.False
	}

## Whether `name` is a word of `md`: leading it, or after an `@`.
names : List(U8), List(U8) -> Bool
names = |md, name|
	if name.is_empty() {
		Bool.False
	} else {
		lead = md.drop_first(Bytes.count_while(md, Ascii.is_whitespace))
		(lead.starts_with(name) and !continues(lead, name.len())) or at_names(md, name.prepend('@'), 0)
	}

## Whether `at_name` (`@` and the name) is in `md` from `from` on, with no
## word byte just before it or just after.
at_names : List(U8), List(U8), U64 -> Bool
at_names = |md, at_name, from|
	match Bytes.find(md, { needle: at_name, at: from }) {
		Err(NotFound) => Bool.False
		Ok(i) =>
			if (i == 0 or !is_word(md.get(i - 1) ?? ' ')) and !continues(md, i + at_name.len()) {
				Bool.True
			} else {
				at_names(md, at_name, i + 1)
			}
	}

## Whether a word byte comes at `i`, so a name there goes on.
continues : List(U8), U64 -> Bool
continues = |md, i| is_word(md.get(i) ?? ' ')

is_word : U8 -> Bool
is_word = |b| Ascii.is_alphanumeric(b) or b == '_'

lc : Mentions.Named
lc = { id: Principal.Id.Agent(aid(1)), name: "LC" }

cc : Mentions.Named
cc = { id: Principal.Id.Agent(aid(2)), name: "CC" }

steve : Mentions.Named
steve = { id: Principal.Id.Human(gid(7)), name: "Steve Howell" }

aid : U64 -> Principal.AgentId
aid = |n| Principal.AgentId.from_u64(n) ?? crash "aid: not 0"

gid : U64 -> Principal.GitHubId
gid = |n| Principal.GitHubId.from_u64(n) ?? crash "gid: not 0"

all : List(Mentions.Named)
all = [lc, cc, steve]

expect Mentions.of("@CC hi".to_utf8(), all) == [cc.id]
expect Mentions.of("  CC, a question".to_utf8(), all) == [cc.id]
expect Mentions.of("CC".to_utf8(), all) == [cc.id]
expect Mentions.of("ask @CC.".to_utf8(), all) == [cc.id]
expect Mentions.of("(@CC) and @LC".to_utf8(), all) == [lc.id, cc.id]
# Not a word: a name that goes on, or an `@` inside a word.
expect Mentions.of("see @CCX".to_utf8(), all) == []
expect Mentions.of("mail a@CC.com".to_utf8(), all) == []
expect Mentions.of("CCX said".to_utf8(), all) == []
expect Mentions.of("@cc".to_utf8(), all) == []
# A name with a space, and one that is no participant's.
expect Mentions.of("thanks @Steve Howell!".to_utf8(), all) == [steve.id]
expect Mentions.of("@Bea hi".to_utf8(), all) == []
# A later `@CC` counts when the first goes on.
expect Mentions.of("@CCX then @CC".to_utf8(), all) == [cc.id]
expect Mentions.is_hop(lc.id, [cc.id])
expect !Mentions.is_hop(lc.id, [lc.id])
expect !Mentions.is_hop(lc.id, [steve.id])
expect !Mentions.is_hop(steve.id, [cc.id])

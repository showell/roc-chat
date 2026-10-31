## **WHO A POST NAMES**: the participants of its conversation whose display
## name the markdown holds as a word, `@Name` anywhere or `Name` leading the
## post (`CC, a question`), by the names the accounts give now. A word ends
## where an ASCII letter, digit or `_` cannot go on it, so `@CCX` and
## `a@CC.com` name nobody; a name is matched as its bytes are, case and all.
## Only the participants count: a name no participant goes by is text.
## **ONLY WHAT THE POST SAYS ITSELF** (`spoken`): fenced code (``` and
## ~~~, the chat's `~~~ quote` reply among them) and `>` blockquotes are
## skipped, so quoting a post that named someone names nobody again. Their
## grammar is roc-markdown's: a fence opens and closes as MdFence (which the
## package exposes) says, and a quote is a line of up to three spaces and a
## `>`, with the lazy lines after it up to a blank one, as MdQuote reads it.
## roc-markdown has no indented code block (a line indented four spaces is a
## paragraph's text), so a name there is said, and counts. The
## listeners (Shale's cookbook/listen.shale) and the cap on agents answering
## agents (Conversations.post!) both read this one answer. Pure.
import md.MdFence
import Ascii
import Bytes
import Principal

Mentions := [].{

	## A participant as a mention finds it: its id and the name it goes by.
	Named : { id : Principal.Id, name : Str }

	## The participants the markdown names, in the order given.
	of : List(U8), List(Mentions.Named) -> List(Principal.Id)
	of = |markdown, participants| {
		said = spoken(markdown)
		participants.keep_if(|p| names(said, p.name.to_utf8())).map(|p| p.id)
	}

	## A post as the hop count reads it: when (`at`, seconds), who, what.
	Post : { at : I64, by : Principal.Id, body : List(U8) }

	## Whose hops are counted, by the participants' names, and the window's
	## opening: a post counts when later than `since`.
	HopWindow : { poster : Principal.Id, named : List(Mentions.Named), since : I64 }

	## **HOW MANY TIMES ONE AGENT ANSWERED AGENTS SINCE A HUMAN LAST SPOKE,
	## IN THE WINDOW**: the hops (`is_hop`) by `poster` among `posts`, oldest
	## first, after the last one by a human and later than `since` (a post
	## at `since` or before is out of the window). Another agent's hops never
	## count toward this one's. A post by an agent that names no other agent
	## (a status, an answer to a human) is no hop and does not end the count.
	own_hops : List(Mentions.Post), Mentions.HopWindow -> U64
	own_hops = |posts, asked|
		match posts.last() {
			Err(_) => 0
			Ok(p) =>
				if is_human(p.by) {
					0
				} else {
					mine = p.by == asked.poster and p.at > asked.since
					hop = if (mine and Mentions.is_hop(p.by, Mentions.of(p.body, asked.named))) 1 else 0
					hop + Mentions.own_hops(posts.drop_last(1), asked)
				}
		}

	## **AN AGENT ANSWERING AN AGENT**: a post by an agent or a bot that
	## names another agent or bot. A human's post never is one.
	is_hop : Principal.Id, List(Principal.Id) -> Bool
	is_hop = |by, mentioned|
		!is_human(by) and mentioned.any(|m| !is_human(m) and m != by)
}

## **THE POST'S OWN LINES**: the markdown without its fenced blocks and
## its blockquotes, each line kept that neither is, joined again.
spoken : List(U8) -> List(U8)
spoken = |md| {
	walked = md.split_on('\n').fold(
		{ mode: Said, kept: [] },
		|state, line|
			match state.mode {
				Fence(f) =>
					if MdFence.is_close(line, f) {
						{ mode: Said, kept: state.kept }
					} else {
						state
					}
				Quoted =>
					if Bytes.count_while(line, Ascii.is_whitespace) == line.len() {
						{ mode: Said, kept: state.kept.append(line.append('\n')) }
					} else {
						{ mode: opening(line, Quoted), kept: state.kept }
					}
				Said =>
					match opening(line, Said) {
						Said => { mode: Said, kept: state.kept.append(line.append('\n')) }
						other => { mode: other, kept: state.kept }
					}
			},
	)
	walked.kept.join()
}

## What a line opens: a fence (MdFence's), a quote (up to three spaces and a
## `>`), or neither, when it stays in `otherwise`.
opening : List(U8),
[
	Said,
	Quoted,
	Fence({ char : U8, count : U64 }),
] -> [
	Said,
	Quoted,
	Fence({ char : U8, count : U64 }),
]
opening = |line, otherwise|
	match MdFence.open(line) {
		Ok(f) => Fence({ char: f.char, count: f.count })
		Err(NotAFence) => {
			indent = Bytes.count_while(line, |c| c == ' ')
			if (indent <= 3 and line.get(indent) == Ok('>')) Quoted else otherwise
		}
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
		(lead.starts_with(name) and !continues(lead, name.len())) or at_names({
			md,
			at_name: name.prepend('@'),
			from: 0,
		})
	}

## Whether `at_name` (`@` and the name) is in `md` from `from` on, with no
## word byte just before it or just after.
at_names : {
	md : List(U8),
	at_name : List(U8),
	from : U64,
} -> Bool
at_names = |
	{
		md,
		at_name,
		from,
	},
|
	match Bytes.find(md, { needle: at_name, at: from }) {
		Err(NotFound) => Bool.False
		Ok(i) =>
			if (i == 0 or !is_word(md.get(i - 1) ?? ' ')) and !continues(md, i + at_name.len()) {
				Bool.True
			} else {
				at_names({
					md,
					at_name,
					from: i + 1,
				})
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
steve = { id: Principal.Id.Human(Principal.GitHubId.from_u64(7) ?? crash "steve: a test's GitHub id is not 0"), name: "Steve Howell" }

aid : U64 -> Principal.AgentId
aid = |n| Principal.AgentId.from_u64(n) ?? crash "aid: not 0"

all : List(Mentions.Named)
all = [
	lc,
	cc,
	steve,
]

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
post : Mentions.Named, I64, Str -> Mentions.Post
post = |who, at, text| { at, by: who.id, body: text.to_utf8() }

## LC's hops, the window opening after second 1000.
lc_hops : List(Mentions.Post) -> U64
lc_hops = |posts| Mentions.own_hops(posts, { poster: lc.id, named: all, since: 1000 })

expect lc_hops([]) == 0
# Under the cap and at it: each of LC's posts naming CC counts.
expect lc_hops(List.repeat(post(lc, 2000, "@CC again"), 14)) == 14
expect lc_hops(List.repeat(post(lc, 2000, "@CC again"), 15)) == 15
# A human's post resets the count; a status names no agent and is no hop.
expect lc_hops([
	post(lc, 2000, "@CC one"),
	post(steve, 2001, "hi"),
	post(lc, 2002, "@CC two"),
	post(lc, 2003, "status: building"),
]) == 1
expect lc_hops([post(steve, 2000, "@CC"), post(lc, 2001, "@CC building")]) == 1
# Posts older than the window do not count, nor one at its very edge.
expect lc_hops([
	post(lc, 999, "@CC old"),
	post(lc, 1000, "@CC edge"),
	post(lc, 1001, "@CC new"),
]) == 1
# Another agent's hops are its own, not LC's.
expect lc_hops([
	post(cc, 2000, "@LC one"),
	post(lc, 2001, "@CC two"),
	post(cc, 2002, "@LC three"),
]) == 1
# Quoted and fenced text names nobody: the chat's quote-reply, a code
# fence, a `>` quote and its lazy line; what follows each is said again.
expect Mentions.of("In MSG_3 you said:\n~~~ quote\n@CC look\n~~~\n\nthanks".to_utf8(), all) == []
expect Mentions.of("~~~~ quote\n~~~\n@CC inner\n~~~\n~~~~\n@LC now".to_utf8(), all) == [lc.id]
expect Mentions.of("```\n@CC in code\n```".to_utf8(), all) == []
expect Mentions.of("> @CC said\nlazy @LC too\n\n@Steve Howell, see?".to_utf8(), all) == [steve.id]
expect Mentions.of("   > @CC\n".to_utf8(), all) == []
# An unclosed fence runs to the end, as roc-markdown renders it.
expect Mentions.of("```\n@CC".to_utf8(), all) == []
# Four spaces is no code block in roc-markdown, and `x > y` is no quote.
expect Mentions.of("    @CC indented".to_utf8(), all) == [cc.id]
expect Mentions.of("x > y, @CC".to_utf8(), all) == [cc.id]
# The post leads with a name after a quote of another's.
expect Mentions.of("> earlier\n\nCC, your turn".to_utf8(), all) == [cc.id]
expect Mentions.is_hop(lc.id, [cc.id])
expect !Mentions.is_hop(lc.id, [lc.id])
expect !Mentions.is_hop(lc.id, [steve.id])
expect !Mentions.is_hop(steve.id, [cc.id])

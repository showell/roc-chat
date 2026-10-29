## **EVERY CAP ON WHAT ONE PERSON CAN MAKE GROW, AND WHY**: the one home of
## the numbers. Sign-up is open, and every request runs in one turn, so a
## list anyone can grow without bound is work every other request pays for
## (the security review of 2026-10-29, H1, H3 and H4). Each cap is refused
## by name where it binds; none is a silent truncation.
## The caps on keys, invites and conversations count a human's own index
## (Store's `load_*_count!`), never a scan of everyone's, and bind through
## `cap!`.
##
## The host keeps its own two (host/sse.zig): the streams one principal
## holds at once (8) and a stream's lifetime (10 minutes).
import pf.Host
import Stored

Limits := [].{

	## **THE ACCOUNTS, ALL TOLD**: every request loads the accounts whole
	## (Store.load_accounts!), so their count is every request's cost. Ten
	## thousand is far past the chat's people and agents, and well inside
	## what a load does in a millisecond or so.
	accounts_most : U64
	accounts_most = 10_000

	## **THE AGENTS AND BOTS ONE HUMAN OWNS**: the review's 32,000 agents
	## came from one account; twenty is several Claudes and a few bots.
	agents_per_human : U64
	agents_per_human = 20

	## **THE KEYS ONE HUMAN HAS MINTED, FOR THEMSELVES AND THEIR AGENTS**,
	## revoked ones counted (a key is never removed, so a cap on live ones
	## would let the folder grow without end).
	keys_per_human : U64
	keys_per_human = 200

	## **THE INVITES ONE HUMAN HAS MADE**, spent and revoked counted, as a
	## key's are.
	invites_per_human : U64
	invites_per_human = 200

	## **THE CONVERSATIONS ONE HUMAN HAS STARTED**, by session or by their
	## agents' keys.
	conversations_per_human : U64
	conversations_per_human = 1_000

	## **A TRANSCRIPT'S BYTES**: a post that would take it past this is
	## refused, and the conversation is full. Far below the host's 16 MiB
	## read (files.read_most), so a whole transcript always reads.
	transcript_bytes_most : U64
	transcript_bytes_most = 4_000_000

	## **THE MESSAGES A PAGE OF A TRANSCRIPT HOLDS**: `GET
	## /conversations/<id>` answers the newest this many, and `before=` pages
	## back.
	page_messages : U64
	page_messages = 100

	## **A CAP ON WHAT ONE HUMAN MAKES, AS IT BINDS NOW**: the number above,
	## or the end to end's smaller one where the host has one set
	## (Host.read_config!'s `CapForTest`, which only host/e2e.zig sets; prod
	## has none), so a step reaches a cap in a few requests.
	cap! : [ConversationsPerHuman, InvitesPerHuman, KeysPerHuman] => U64
	cap! = |which|
		match Stored.count(Host.read_config!(CapForTest), "cap") {
			Ok(n) => n
			Err(_) =>
				match which {
					ConversationsPerHuman => Limits.conversations_per_human
					InvitesPerHuman => Limits.invites_per_human
					KeysPerHuman => Limits.keys_per_human
				}
		}
}

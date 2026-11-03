# Code quality in gopher-roc

This is the standard the Roc code is held to. The general Roc rules are in roc-apps' `CLAUDE.md` and `docs/roc-style.md`. Read both, cover to cover, before judging any Roc. They are living documents: when work here shows a general lesson they lack, or a rule that is wrong, the guide changes too. This page adds what gopher-roc asks for on top of them. The shale hunts in `tools/verify.shale` catch some of it automatically; the rest is judgement.

## The model

`app/Conversation.roc` is the module to imitate. Steve called it the first piece of code he would hand a Roc newcomer building a chat, one that would fit almost any architecture. It is a pure type that stands alone, knowing nothing of storage, places or readers. It has one way in (`append`), so its rules live in the type, and its few comments are plain sentences.

## Show off Roc

Use Roc's types to make bad values impossible, rather than checking for them in many places. A message id is a `Message.Id`, made only by `first` and `next`, not a bare number. Give each domain number a nominal type, at the smallest integer that fits. Prefer an opaque type whose constructors enforce the rule over a comment that states it.

## Small modules with one job

Pure modules are small and easy to combine. Effects happen at the edges. A large module needs a reason not to be split; it's easier to combine modules than to split them. A tiny module is worth having when it keeps something opaque or decoupled: one module for each outside dependency (`Markdown` for roc-markdown) and one for each trust boundary (`TrustedHtml`, `SecureImageTag`).

The best edge module moves data across a boundary and changes its type on the way. `FileSystem` takes a `ConversationKey` and gives back a `Utf8Transcript`; `Transcript` turns that into a `Conversation`. Each module does one such step, rather than flipping state flags on one type.

## Trust boundaries are easy to find

A security reviewer should find every trust boundary from its name. Their headers point at each other, so a reader who starts at one finds the rest. A dangerous operation has a name that sounds dangerous wherever it's called (`TrustedHtml.dangerously_trust`, `SignedIn.dangerously_assume`), and its comment states what the caller promises.

## Failures are loud

There are no silent fallbacks. A bad case is ruled out by a type, refused with a named tag, or ends in a crash that names the broken promise.

## Names

- Two-part names that say what a thing is are better than short, clever ones: `Message.Unnumbered` and `unnumbered_message`, not `Arrival`.
- A name says what a thing is, not what it reminds you of.
- A name that sounds like a boolean belongs only to a boolean. A function that builds a refusal response is `post_refusal_response`, not `refused`.
- A name a caller sees says what happens for the caller (`post_sent_message!`), not how it's done (`append!`). Use judgement; don't force it.

## Comments

- Few comments. The bar is high: a comment stays only when it says something the code and its tests can't.
- A module's header is plain, complete sentences that say what the module does. It's never a `## **CAPS HEADLINE**: fragment` heading: a count in a heading goes out of date, and a fragment's "its" refers to nothing.
- Write for a reader who arrives cold: name what you refer to, explain or drop jargon, and say what does happen rather than what "never" happens.
- No history or anecdotes. They belong in commit messages.
- No comment that claims a rule enforced somewhere far away ("times never go backwards"). The code that enforces it, and its test, say it better.

## Tests

The tests sit at the bottom of each module (or in its `Spec`), and they read like a specification. Each input sits beside its expected answer. Test both sides of every boolean, every tag, and the values at and around each boundary. Every `expect` must pass exactly once, and the gate checks that.

## How a module is polished

1. A cold agent reads this page, both Roc guides cover to cover, the module and its callers, and fixes what falls short, keeping behaviour the same. It proposes any change the guides need.
2. `shale tools/verify.shale` passes.
3. Steve reviews the module on the essay surface when he wants to, and the agent's choices are checked against his replies.

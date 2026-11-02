# gopher-roc

A chat for a small group of humans and their agents, in Roc on a Zig host. `gopher-roc` is a code name. `docs/design.md` is the design, from first principles. This is a fresh start from roc-chat, which it cribs from as needed.

**Status (2026-11-02): the first demo only.** It is a pure core: `Conversation`, which grows only by `append` (so its ids are always 1, 2, 3...), `Message`, `MsgAnchor` (how one message is named: `MSG_<topic>_<n>` and `msg-<n>`), `Transcript` (the file in the Zig chat's format), and `Page`, built only from markup vouched for at `TrustedHtml`'s one door, `dangerously_trust`, whose few callers are the audit: `Escape` (text, escaped exactly once), `HtmlElement` (tags from closed sets and strict tokens), `Markdown` (roc-markdown's output, its images ruled by `SecureImageTag`) and `Page`'s fixed head and style sheet. Text from outside comes in only as an `UnvalidatedString`, whose only ways out are the checking doors. Who is acting is a `SignedIn`, whose door, `dangerously_assume`, stands in for the session check until sessions exist. A security reader starts at `UnvalidatedString`, `TrustedHtml`, `SecureImageTag` or `SignedIn`. It reads a conversation's transcript and renders it as one page. Beside it, pure and not yet served: `Directory` (the one namespace, holding `Users`, whose `Human` is a user known to be no agent, and `Channels`, shaped by an `Admin`), `Name` (letters from `NameAlphabet`), `Dm` and `Place`. There is no server yet.

    shale tools/verify.shale                                  the gate: format, tests (the app's, then every *Spec.roc's), hunts, the demo's frozen page
    zig build demo -- gopher-roc demo/gopher-roc.transcript   the sample's page, to stdout
    shale tools/note.shale                                    the page and all the code, as an essay note

It needs the Roc pinned in `roc-version` at `~/tools/roc-<pin>/roc`, and roc-markdown checked out beside this repo, because its package renders the markdown.

**Pitfall: a renamed or deleted module breaks `zig build demo`** with "checking cache failed: file_open FileNotFound app/<Old>.roc". Zig's cache still remembers the old file as an input. Delete `.zig-cache` (it's git-ignored) and build again.

**Pitfall: the demo's page is frozen.** The gate holds `zig build demo -- gopher-roc demo/gopher-roc.transcript` to `demo/gopher-roc.html` byte for byte. A deliberate change to the page rewrites that file from the demo's output, and the commit says what moved and why.

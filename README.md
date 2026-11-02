# gopher-roc

A chat for a small group of humans and their agents, in Roc on a Zig host. `gopher-roc` is a code name. `docs/design.md` is the design, from first principles. This is a fresh start from roc-chat, which it cribs from as needed.

**Status (2026-11-02): the first demo only.** It is a pure core: `Conversation`, which grows only by `append` (so its ids are always 1, 2, 3...), `Message`, `Transcript` (the file in the Zig chat's format), and `Page` and `TrustedHtml` (the page, safe by construction: text escaped exactly once). It reads a conversation's transcript and renders it as one page. There is no server yet.

    zig build test                                        the Roc tests: the app's, then every *Spec.roc's
    zig build demo -- gopher-roc demo/gopher-roc.transcript   the sample's page, to stdout
    shale tools/verify.shale                              the gate: format, tests, hunts, the demo's frozen page
    shale tools/note.shale                                the page and all the code, as an essay note

It needs the Roc pinned in `roc-version` at `~/tools/roc-<pin>/roc`, and roc-markdown checked out beside this repo, because its package renders the markdown.

**Pitfall: the demo's page is frozen.** The gate holds `zig build demo -- gopher-roc demo/gopher-roc.transcript` to `demo/gopher-roc.html` byte for byte. A deliberate change to the page rewrites that file from the demo's output, and the commit says what moved and why.

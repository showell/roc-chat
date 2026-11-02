# gopher-roc

A chat for a small group of humans and their agents, in Roc on a Zig host. `gopher-roc` is a code name. `docs/design.md` is the design, from first principles. This is a fresh start from roc-chat, which it cribs from as needed.

**Status (2026-11-02): the first demo only.** It is a pure core of `Message`, `Transcript` and `Conversation`. It reads a conversation's transcript, a file in the Zig chat's format, and renders it as one page. There is no server yet.

    zig build test                                        the Roc tests
    zig build demo -- gopher-roc demo/gopher-roc.transcript   the sample's page, to stdout
    shale tools/note.shale                                the page and all the code, as an essay note

It needs the Roc pinned in `roc-version` at `~/tools/roc-<pin>/roc`, and roc-markdown checked out beside this repo, because its package renders the markdown.

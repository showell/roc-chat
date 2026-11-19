# CLAUDE.md: working on roc-chat

This file is for a coding agent working on roc-chat. Read `README.md` first for what the chat is and how it's built. The general habits for Roc code live in roc-apps' `CLAUDE.md` (https://github.com/showell/roc-apps/blob/master/CLAUDE.md), and this repo follows them. This file covers only what's particular to roc-chat.

## The bar

- **One gate decides when a change is done:** `shale tools/verify.shale`. Run all of it before you call a change sound, and read its counts, not just its last line. A warning, a skipped check or a hunt finding is a failure.
- **Plant the fault a new test or check should catch,** see it fail in the right place, then take the plant out.
- **Commit each step,** and say in the message what the gate ran.

## How the code is shaped

- **Roc decides, and the host does I/O.** Logic belongs in `app/`. A new hosted function in `platform/` answers a fact, never a verdict, and secrets stay on the host's side. After any change to `platform/`, run `shale tools/glue.shale`.
- **The file system is the database.** Only `FileFacts` touches files. A feature's files are owned by that feature's `*Files` module. The storage format is the owner's call: don't change the layout on disk without asking.
- **Pages are HTML built in Roc, with small scripts.** The styles live in the JS (`app/*.js`), which injects minimal CSS. The server sends no stylesheet. Live updates come over server-sent events. `PageContract` is the one home of the class names and `data-` attributes that the Roc and the JS share. Change both sides together.
- **Security boundaries are types.** Outside text is an `UnvalidatedString`. HTML is trusted only at `TrustedHtml`'s one door. Who's acting is a `SignedIn`. Don't add a new way around any of them. A change to sign-in, sessions, keys or access gets a spec test for every side: refused, allowed, and the edge between.
- **Modules stay under 500 lines,** the whole file, tests included. Long tests move to a `*Spec.roc`, which has no limit.
- **The demo's page is frozen** (`demo/roc-chat.html`). Rewrite it only for a deliberate change to the page, and say in the commit what moved.

## Working style

- **Match before you invent.** When a feature exists in the older chat or in chat-client, match its behavior first, and propose improvements separately.
- **Deploys are the owner's call.** `tools/deploy.shale` changes production. Run it only when the owner has asked for it.
- **Keep long builds out of the inner loop.** Use the dev backend and `roc check` while editing, and run the full gate before you hand work back.

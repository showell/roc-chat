# CLAUDE.md: working on roc-chat

This file is for a coding agent working on roc-chat. Read `README.md` first for what the chat is and how it's built. The general habits for Roc code live in roc-apps' `CLAUDE.md` (https://github.com/showell/roc-apps/blob/master/CLAUDE.md), and this repo follows them. `docs/code-quality.md` is this repo's standard on top of them, and `docs/design.md` holds the owner's decisions. Read both before changing behavior or storage. This file covers only what's particular to roc-chat.

## The gate

`shale tools/verify.shale` is the gate. It fails on any warning and on every hunt it holds at zero. The counts it prints but doesn't gate (its header, step 3) are questions for you to look at, not failures.

## Rules

- **Logic belongs in Roc.** A new hosted function in `platform/` answers a fact, never a verdict, and secrets stay on the host's side.
- **Only `FileFacts` touches files,** through each feature's `*Files` module. Don't change the layout on disk (`docs/design.md`, "Storage") without asking.
- **No stylesheet:** a page's styles live in its script in `app/*.js`. `PageContract` is the one home of the names the Roc and the JS share, so change both sides together.
- **Don't add a new way around the security types** (`UnvalidatedString`, `TrustedHtml`, `SignedIn`). A change to sign-in, sessions, keys or access gets a spec test for every side: refused, allowed, and the edge between.
- **Modules stay under 500 lines,** the whole file, tests included. Long tests move to a `*Spec.roc`, which has no limit. No gate checks this yet, so check it yourself.

## Working style

- **Match before you invent.** When a feature exists in Gopher Chat (angry-gopher's zig-server) or in chat-client, match its behavior first, and propose improvements separately.
- **Deploys are the owner's call.** `tools/deploy.shale` changes production. Run it only when the owner has asked for it.
- **Keep the gate out of the inner loop.** While editing, run `roc check` from a root that reaches your change (`app/main.roc` or `app/Specs.roc`). Run the full gate before you hand work back.

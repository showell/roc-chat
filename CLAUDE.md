# CLAUDE.md: working on roc-chat

This file is for a coding agent working on roc-chat. Read `README.md` first for what the chat is and how it's built. The general habits for Roc code live in roc-apps' `CLAUDE.md` (https://github.com/showell/roc-apps/blob/master/CLAUDE.md), and this repo follows them. `docs/code-quality.md` is this repo's standard on top of them, and `docs/design.md` holds the owner's decisions. Read both before changing behavior or storage, and read `docs/ux.md` before changing a page. This file covers only what's particular to roc-chat.

## The gate

`shale tools/verify.shale` is the gate. It fails on any warning and on every hunt it holds at zero. The counts it prints but doesn't gate (its header, step 3) are questions for you to look at, not failures.

## Rules

- **Logic belongs in Roc.** A new hosted function in `platform/` answers a fact, never a verdict, and secrets stay on the host's side. Its Zig goes in the seam's part for its concern (`docs/platform.md`, "Where a new primitive goes").
- **Only `FileFacts` touches files,** through each feature's `*Files` module. Don't change the layout on disk (`docs/design.md`, "Storage") without asking.
- **No stylesheet:** a page's styles live in its script in `app/*.js`. `PageContract` is the one home of the names the Roc and the JS share, so change both sides together.
- **Don't add a new way around the security types** (`UnvalidatedString`, `TrustedHtml`, `SignedIn`). A change to sign-in, sessions, keys or access gets a spec test for every side: refused, allowed, and the edge between.
- **Modules stay under 500 lines,** the whole file, tests included. Long tests move to a `*Spec.roc`, which has no limit. No gate checks this yet, so check it yourself.

## Working style

- **Match before you invent.** When a feature exists in Gopher Chat (angry-gopher's zig-server) or in chat-client, match its behavior first, and propose improvements separately.
- **Deploys are the owner's call.** `tools/deploy.shale` changes production. Run it only when the owner has asked for it.
- **Keep the gate out of the inner loop.** While editing, run `roc check` from a root that reaches your change (`app/main.roc` or `app/Specs.roc`). Run the full gate before you hand work back, unless your brief says someone else runs it (see "Working as one of several lanes").
- **A change keeps the behaviour around it.** When you narrow, guard or extend a behaviour, list the nearby behaviours that must still work and check each one. Making the compose box refuse to close over unsent text also stopped Escape from closing an empty box, and nothing checked it.
- **Removing or hiding something is a question, not a call.** If you leave something out because it seems redundant (the viewer's own presence dot), or hide a notification (the violet tab for the topic you're reading), say so in your report as a question for the owner. Check what Gopher did first. Don't settle it by making a test pass.

## Working as one of several lanes

Several agents often work on roc-chat at once, each in its own git worktree on its own branch, while an orchestrator merges one branch at a time. When your brief says so, work this way:

- **Run targeted checks, not the full gate.** The orchestrator runs `tools/verify.shale` once per merge; two of them at once on a small machine more than double each one's time. Pick the checks your change reaches:
  - `roc fmt --check app platform`, then `roc check` and `roc test` on `app/main.roc` and `app/Specs.roc`;
  - `zig fmt --check host build.zig`, then `zig build test --summary all` or `zig build end-to-end` when host code or a route's behaviour changed;
  - `shale cookbook:check_syntax.shale files=<the files you touched>` for JS and Shale;
  - `shale tools/check_script_calls.shale` whenever a script's exports, globals or load order change (each page's order lives in `app/Script.roc`);
  - the style hunts verify runs (`check_stacking`, `hunt_names` and the rest, listed in its step 3) over the Roc files you touched;
  - `zig build demo`, compared with `demo/roc-chat.html`, when a conversation page's markup changed;
  - `tools/screenshot.shale` for any page you changed (see `docs/ux.md`).
- **Look at your pages.** Screenshot at desktop and phone, in both themes, and read the pictures before you report what a page looks like.
- **Rebase onto `origin/main` when asked, and keep both sides.** The usual conflicts are lists that every lane appends to: `tools/screenshot.shale`'s states and header, `app/palette.js`'s colours, `docs/design.md`, `app/PageSpec.roc` and `host/end_to_end.zig`. Keep every side's entries, then rerun the checks above.
- **Report so a reader can act:** what changed and why, the old behaviours you checked and how, anything you removed or made inconsistent with its neighbours (as a question), the checks you ran and the ones you skipped, and the branch head.

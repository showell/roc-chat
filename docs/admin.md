# Admin commands

roc-chat's admin work that has no page is done by Shale scripts in `tools/admin/`, run on the server's machine against its data root. Each common task has two scripts: one that reads and reports, and one that acts. There's no trial-run mode. You read the report, then run the script that acts, and it acts at once.

| Script | What it does |
|---|---|
| `user_footprint.shale user=<name or id>` | Prints everything in the data root that belongs to one user or names them, grouped. It never writes. |
| `remove_user.shale user=<id> confirm=<name>` | Removes that user completely, while the server is stopped. |
| `check_remove_user.shale` | Tests both scripts end to end on a throwaway chat, from roc-chat's root (below). |

`chat_data.shale` is their shared library: the reading of the layout in docs/design.md ("Storage") and the footprint itself, so the report and the removal can't disagree about what a user owns.

## Is there an admin page?

There are admin pages, but nothing links to them. The admin's pages are `/channels` (every channel, and a form that creates one) and `/channels/<name>` (a channel's members, each with a button to add or remove them), both `ChannelMembersRoute`'s. `/agents` holds the admin-only work with agents. The top bar (`PageKit.top_bar_titled`) links Browse, Recent, Invites and Add a device for everyone. It has no link for the admin, and no page links to `/channels`, so the admin has to type the address.

The smallest fix, not built: in `top_bar_titled`, when `Admin.of(viewer)` is `Ok`, add one more link after "Add a device", "Admin", to `/channels`, with its path held beside `invites_path` in `PageKit`. Only the owner would see it. Because the frozen demo page is drawn for Steve, `demo/roc-chat.html` and the page specs would be rewritten with it.

## user_footprint.shale

It prints these groups, each with its count and "none" when it's empty:

- **The user:** their id and name, whether they are a human or an agent (and their owner), whether the folder is an account, and the counter of ids.
- **Their account folder**, `auth/<id>/`: every file, their device keys (`device-keys/<n>/`), human invites and an agent's keys included. The words of plain facts (`name`, `inviter`, `joined`, an invite's `by`, `state` and times) are shown. Every other file is shown by its size alone, so no password hash, key hash or session word is ever printed.
- **Their user folder**, `users/<id>/`.
- **The channels whose members files list them.**
- **Their DMs**: each folder whose pair holds their id, with its topics, its message counts and its uploads.
- **The messages they wrote in topics that stay** (every topic outside their DMs): each transcript, the record's line, its `MSG_` reference, its date, and any image of the topic's that it references.
- **Their reactions in topics that stay**: each `reactions` file and line.
- **Other users' files that hold their id:** the agents they own (`owner`), the humans they invited (`inviter`), the invites they made for others (`human-invites/<n>/by`), and other humans' `last-conv` files that point into their DMs.
- **Lines of other people's messages that contain their name**, which stay as written.
- **What isn't on disk:** sessions, presence, the search index, rate limits and open streams, all held in the server's memory.

Its last line says whether `remove_user.shale` would act, and gives the command, or lists what blocks the removal.

## remove_user.shale

`user=` is the id the footprint names. `confirm=` is the user's name, exactly as written. A folder with no `name` file is confirmed by its id instead: either a sign-up cut short, or a removal that stopped partway.

It refuses, changing nothing, in these cases:
- the user is 1, the owner;
- they own an agent, because an agent whose owner is no human stops the chat from reading its directory (`Users.from_stored`'s `BadOwner`), so the agent goes first;
- they wrote a message in a topic that stays (see "Messages in topics that stay" below);
- the counter of ids isn't past their id;
- a `roc-chat` process serves this data root.

Then it works in this order. The storage rule is that the file that makes a thing exist is written last. A removal runs that rule backwards, with one exception, step 1. A crash between any two steps leaves a state the chat already handles, and running the script again finishes the job.

1. **Each channel's members file that lists them** is rewritten whole, atomically, without their id. This comes before the account goes, because a channel listing a member who is no user stops the chat from reading its directory. A human who is in no channel is a state the admin already handles.
2. **`auth/<id>/name` is removed.** From then on the folder is no account (`AccountFiles.read_accounts!`), and every session of theirs is refused.
3. **Their reaction lines in topics that stay** are removed, and each `reactions` file is rewritten whole, atomically.
4. **Each of their DMs is removed whole**: its topics, transcripts, reactions and uploads. A DM naming an id that no account has is one no one can reach, which docs/design.md already plans for after a crashed sign-up.
5. **Other humans' `last-conv` files that point into those DMs are removed.** For those humans, `/` then goes to Browse, as it does for anyone with no last conversation.
6. **Their account folder, `auth/<id>/`, and their user folder, `users/<id>/`, are removed.**

Last, it reads the data root again and stops unless nothing of theirs is left.

What it leaves alone, on purpose:

- **The counter of ids.** Ids are never given twice (docs/design.md: a session names its human by id alone), so their id stays spent.
- **Other humans' `inviter` files and invites' `by` files that hold their id.** These files are only read as digits. A human whose inviter is gone can be invited again by the admin alone (`HumanInvites.is_theirs_to_invite_again`). An invite whose maker is gone is shown to the admin as "user <id>" (`PeoplePages`). Removing an `inviter` file would be worse: a human with none can't be invited again by anyone.
- **Other people's messages that quote or name them,** citations of their DM messages included. Those are other people's words. A citation's link into a removed DM becomes a 404, and a `MSG_` reference to a topic that's gone finds no conversation.

**Stop the server first, and start it after.** The script refuses while the server runs, because the server holds parts of the user in memory: an open stream was admitted when it opened, and it runs to its hour (`Limits.stream_most_ms`), so it would keep sending the channels' new messages to the removed user's browser. The search index also holds their DMs' messages, and presence holds when they were last seen. A restart drops all of it.

## Messages in topics that stay

**Decided, not built** (Steve, 2026-11-20: "Your policy will be correct if we ever need to remove a spammer, but don't build out for that yet. We can do that reactively when we know the actual threats."). The blank-in-place approach below is the agreed one for a real removal, built when one is needed. Until then, `remove_user.shale` refuses a user who wrote in any topic outside their DMs, and the footprint lists each such message, so a case like that is handled by hand once its footprint is seen. A user who never really took part, like a test account, is removed with every trace, their DMs with the owner included, which is what the script does.

Two ways of handling those messages are ruled out:

- **Deleting the record** corrupts the transcript. A transcript is read by numbering its records in order: each record's `MSG_` line must be the next id (`Transcript.read_message`), so a gap makes the whole topic unreadable for everyone (`BadHead`). Renumbering the later records would break everything that names a message by its number: reactions (`"msg":<n>`), edits (`Edit of MSG_<topic>_<n>`), page anchors (`#msg-<n>`), `MSG_` references and citations in other topics, and the listener's stop on a gap in ids. Truncating the file works only for messages at the end, and then the next message would get the deleted id again.
- **Leaving the records as they are** leaves a dangling name. A transcript records its author by name alone (`Author`), and pages find the author's account by that name (`ConversationPage`'s `user_by_name`), as edits do (`Edit.judge`). Once the user is removed, their name is free again (`NameSkeleton` judges only the users there are). A new human who takes it would be shown as the author of those messages, and could edit them.

**The agreed approach: blank each message in place.** Each record keeps its `MSG_` line and its date, so ids and time order stand, and every reaction, reference and citation still lands. Its `from:` becomes one fixed author that no human can sign up as, for example `system`, which is on `NameSkeleton`'s reserved list. Its markdown becomes one line, "(removed with its author's account)". An image the message referenced is removed from the topic's `uploads/` when no other message references it. Each transcript is rewritten whole, atomically, while the server is stopped, and the restart rebuilds the search index from the files. Other people's quote-replies of those messages keep the quoted words, as they are part of their own messages. It would be about 30 more lines in `remove_user.shale`, as step 3b, plus the footprint's own line for it.

## Running them

**Both scripts need a data root mounted as `data:`.** It is read-only for the footprint and writable for the removal. They are run from `tools/admin` as Shale's root, so `use("./chat_data.shale")` loads the library beside them, and under a mounts file of their own:

```
# read.mounts
data = /var/lib/roc-chat/data ro
```

```
# write.mounts
data = /var/lib/roc-chat/data
```

`SHALE_MOUNTS=<file>` names the mounts file. `SHALE_PRELUDE=` (empty) runs without a user prelude. Neither script starts a program: they use only Shale's own file calls and `procs()`.

### The local proof

`shale tools/admin/check_remove_user.shale`, from roc-chat's root, builds the server, starts it on a fresh data root seeded from the demo, and fills it over HTTP with a user who has something in every group. Tam joins, writes in a DM with Steve, invites Ada, reacts in `general` and is in `#team`. Ada writes to Tam, Steve names Tam in `general` and last opened his DM with Tam, and Cy writes in `general`. Then it stops the server, writes the two mounts files over that root, and runs the scripts as prod would. It checks:

- the footprint names each of Tam's files and lines and no hash, and refuses Cy;
- a write through the read-only mount is refused, and so is a path out of the mount;
- the removal refuses Cy, a wrong `confirm=`, and Tam while the server is up;
- the removal then removes Tam, and the footprint finds no folder of Tam's;
- Tam's footprint lists the device key that Tam's phone signed in with (a real device code, redeemed);
- a second removal in a row works too: Ada, whose inviter was Tam, with the counter still 5;
- the server, started again, answers every page the others had: Browse, Recent, `general` (where Tam reacted), `#team`, the channels page, the invites pages, Cy's DM with Steve and its sidebar, and a search. Tam's and Ada's DMs are 404s, their sessions are refused (the phone's device-key session too), and Steve's `/` goes to Browse.

It takes about 2 seconds once the server is built (the first `zig build` of a fresh checkout takes about a minute and a half). It isn't part of `tools/verify.shale`, since the scripts change only when the layout does.

The same two scripts also ran under the static build described below, using `deploy/admin/`'s mounts files as written (their comments included, the path pointed at a scratch data root), with an empty home and no prelude. The footprint, then the removal, did what they do here.

### On prod

**Shale's binary** is built by `tools/deploy.shale` (step 4), static, beside roc-chat's own musl binary. C Shale links only the C library and makes no name lookups, so its release build links statically with glibc, with no warning and no change to Shale. The deploy builds it from the Shale checkout beside this repo (`repos:shale`), which must be clean: it generates the preludes (`tcc -run c/gen_preludes.c`, the build's own output in `c/out/gen`), then runs `gcc -std=c11 -Wall -Wextra -Werror -Ic/foundation -O2 -Ic/out/gen -Ic c/shale.c -static`, niced, about a minute on the box, and prints the Shale commit it built. Step 6 installs it as `/opt/roc-chat/shale`: root's, mode 755, proved by its sha256 and swapped in by a rename, as the server is. The scripts are run by that path, never by `PATH`, because prod may still have an older Zig `shale` on its `PATH`.

**The scripts and the mounts files** go to `/opt/roc-chat/admin/`, in step 6 too: the folder root's and 755, each file root's and 644, each proved by its sha256. They are `tools/admin/chat_data.shale`, `user_footprint.shale` and `remove_user.shale`, with `deploy/admin/read.mounts` and `deploy/admin/write.mounts` (`ADMIN_FILES` in the deploy). The folder is Shale's root when they run, and its owner is root, so a script can't write to it.

**They run as `rocchat`, the service's user,** inside a sandbox like the unit's, after a deploy has put them there. The orchestrator runs them over ssh: the footprint, read-only, then the stop, the removal **[PROD WRITE]** and the start, after Steve signs off. `<host>` is the deploy's `host=`:

```
ssh <host> 'sudo systemd-run --quiet --wait --pipe --uid=rocchat --gid=rocchat \
  -p WorkingDirectory=/opt/roc-chat/admin -p ProtectSystem=strict -p ProtectHome=yes \
  -p PrivateTmp=yes -p NoNewPrivileges=yes -p ReadOnlyPaths=/var/lib/roc-chat \
  -E SHALE_MOUNTS=/opt/roc-chat/admin/read.mounts -E SHALE_PRELUDE= -E HOME=/var/lib/roc-chat \
  /opt/roc-chat/shale user_footprint.shale user=Alice'
```

```
ssh <host> 'sudo systemctl stop roc-chat; sudo systemd-run --quiet --wait --pipe --uid=rocchat --gid=rocchat \
  -p WorkingDirectory=/opt/roc-chat/admin -p ProtectSystem=strict -p ProtectHome=yes \
  -p PrivateTmp=yes -p NoNewPrivileges=yes -p ReadWritePaths=/var/lib/roc-chat/data \
  -E SHALE_MOUNTS=/opt/roc-chat/admin/write.mounts -E SHALE_PRELUDE= -E HOME=/var/lib/roc-chat \
  /opt/roc-chat/shale remove_user.shale user=<id> confirm=<name>; sudo systemctl start roc-chat'
```

The server starts again whatever the removal did: a refusal changes nothing, and a removal that stopped partway leaves a state the chat already handles. The footprint is run again after, to see that the user is gone. A name with a space is passed on stdin instead, with `--args-stdin` and `--pipe`'s stdin. `sudo -u rocchat env SHALE_MOUNTS=... /opt/roc-chat/shale ...` from `/opt/roc-chat/admin` works too, with every layer below except the third.

**What protects the rest of the machine:**

1. **Unix permissions.** `rocchat` is a system user with no shell and no sudo rights. It owns `/var/lib/roc-chat` (mode 700) and nothing else that matters: the binaries, the scripts, `/etc`, Caddy's files and the other sites are root's.
2. **Shale's store.** Each script reads and writes only below its root (`/opt/roc-chat/admin`, which Unix makes read-only to it) and the `data` mount. A path with `..`, an absolute path or a symbolic link anywhere below the mount is refused before it's used. The footprint's mount is read-only, and Shale refuses every change through it before anything is written. A program a script starts isn't confined by Shale, but these scripts start none.
3. **The sandbox `systemd-run` gives, the kernel's.** The whole file system is read-only (`ProtectSystem=strict`, `ReadOnlyPaths`) except the data root for the removal (`ReadWritePaths`), home folders are hidden, `/tmp` is private, and no privilege can be gained. That holds whatever Shale does.
4. **Landlock isn't part of this.** Shale's Landlock work, which confines the programs `run` starts to the mounts, is on Shale's `landlock` branch: neither merged nor installed, with its install blockers still open. These scripts start no program, so it would add nothing here, and nothing here waits on it.

# Humans without GitHub

A human without a GitHub account joins roc-chat by an invite from any human
member, with no password, and is then an equal user. DECISIONS.md holds the
rules ("Who is who"); this doc is the plan for building them, in four steps.
The design discussion behind it is the essay `notes/humans-without-github.md`
in essay-repl-server, with Steve's answers.

| Step | What | State |
|---|---|---|
| 1 | One namespace of unique names; 30-day idle, 90-day sessions | done (337) |
| 2 | Humans get roc-chat's own ids; GitHub becomes one way to sign in | next |
| 3 | Human DMs, with topics, beside channels | after 2 |
| 4 | Human invites, the redeem page, device sessions, re-invites | after 3 |

## Step 2: roc-chat's own human ids

**Why:** today a human *is* their GitHub id (`Principal.Id.Human(GitHubId)`,
wire id `human:142908`). An invited human has no GitHub id, so identity has
to come from roc-chat, and GitHub has to become a sign-in method that maps
onto it.

**The shape:**
- **`HumanId`**, a counter like `AgentId`, given once and never reused.
  `Principal.Id.Human(HumanId)`; the wire form stays `human:<n>`, now
  roc-chat's number.
- **An account says how it signs in:** `sign_in : [GitHub(GitHubId)]` for
  now. Step 4 adds the invited kind. GitHub sign-in finds the account
  whose binding holds that GitHub id, or makes a new account with the next
  `HumanId`.
- **Everything that names a human by GitHub id moves to `HumanId`:**
  `answers_to`, an agent's owner, conversation participants, sessions,
  audit lines, channel members and admins.
- **What stays a GitHub id is GitHub's business:** the sign-in exchange,
  the `login` field shown beside a name, and the config's `first_admin`
  and `barred`, which are about GitHub accounts and are resolved when that
  account signs in.
- **Unchanged:** names (step 1's namespace), agents' ids, keys, the routes.
  Only what identifies a human changes.

**Tests, every side:**
- A human's id and their GitHub id differ in the e2e: one test human
  whose GitHub id isn't their `HumanId`, so a mix-up can't pass by
  coincidence.
- A wire `human:<github id>` that isn't an account's `HumanId` is refused.
- Two GitHub sign-ins by the same GitHub id land on the same account; two
  different GitHub ids get two accounts with consecutive ids.
- An id is never given twice, even after its account is deleted.

**Production's data: start over (Steve, 2026-10-31).** No migration code.
At step 2's deploy:
1. Back up `/var/lib/roc-chat/data` first (DEPLOY.md's backup).
2. Clear everything in `data/` **except `data/secrets/`**: the GitHub OAuth
   client id and secret live there, and so does the signing key.
   `config.zon` sits outside `data/` and is untouched.
3. Steve signs up through GitHub again and becomes `human:1`, then
   re-invites LC and CC as agents, which store their new keys.

Step 2's code may therefore assume an empty store: no old-format reader.

## Step 3: human DMs

A DM is a pair of humans with topics, the same topic machinery,
transcripts and message ids as a channel. Its references are the short
`MSG_<topic>_<n>` (DECISIONS.md, "Channels and topics"). The welcome in
step 4 needs it.

## Step 4: human invites

As DECISIONS.md says, with the details from the essay:
- **Any member invites** with a name, a topic (default `ChitChat`) and a
  welcome (default "Hi! This is an automated message from <inviter>").
- **All at once, or nothing:** a reserved account holding the name, a DM
  between inviter and invitee with the topic, the welcome posted as the
  inviter, and a single-use code shown once.
- **The link is `/join#<code>`:** the code after the `#` never reaches the
  server's logs. The page's script sends it in the redeem request's body.
- **Limits:** a code lives 7 days and can be revoked; at most 10 open
  invites per human; audited without the code.
- **The redeem page:**
  - It shows the name filled in, which the invitee may change to any free
    name.
  - The first paragraph is plain words: no password, this device, signed out
    after 30 idle days.
  - The mechanism follows, as fine print.
- **A re-invite,** from the inviter or an admin, signs an invited human in
  on another device, or back in after a lost one.

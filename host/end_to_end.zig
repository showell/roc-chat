//! The end to end runs the real server, with the app linked, on a free port
//! of 127.0.0.1, told a public origin (`public_origin`), on a task of this
//! process, against a temporary data root seeded from demo/data. It drives
//! the server over HTTP, one step a line, timed.
//!
//! First Steve signs in (`signInSteps`), his password's bcrypt hash written
//! to `auth/1/password` as its owner would write it:
//!
//!  0a. GET the seeded conversation with no session: a 303 to the sign-in
//!      page, naming the conversation as `next`; the sign-in page: 200,
//!      its form, `next` in it;
//!  0b. sign in with a wrong password, and as no such user: 401 each, the
//!      page again, no cookie, never stored;
//!  0c. sign in with the right one: a 303 to `next`, the session's cookie
//!      set for a year, `HttpOnly`, `Secure`, `SameSite=Lax`, signed by the
//!      server's secret over his password file's hash, never stored;
//!  0d. a cookie whose signature is forged, one a year and a second old,
//!      one signed ahead of the clock past its skew, and one for an id no
//!      human has: the page a 303 to sign in, a message a 401, nothing
//!      appended; one signed now, by the server's secret: the page;
//!  0e. no session at all: a message, a send, a stream, `/raw`, `/agents`'s
//!      POST and an upload are 401 each, nothing stored; `/agents` a 303
//!      to sign in; an upload past a form's room is a 413, its body never
//!      read, as the large room is only a member's.
//!  0f. Steve's password file rewritten, the same password under a new
//!      salt: his session's page a 303 to sign in; signed in again, the new
//!      session's page 200. Every step of his after 0f carries the new one.
//!
//! Then, as Steve:
//!
//!   1. GET the seeded conversation: exactly the demo's frozen page, with
//!      its content security policy (scripts from this origin alone) and
//!      `nosniff`; its compose box a form posting `markdown` to the
//!      conversation's own URL and naming its `/send` and its `/upload`, and
//!      its script's `src`;
//!   2. POST a message to it: a 303 to its page;
//!   3. GET it again: the message is there;
//!   4. the transcript on disk: the seed and exactly one record more, dated
//!      by the host's clock;
//!   4a. GET the page's script: 200, JavaScript, `nosniff`, exactly
//!      app/compose.js; palette.js, chrome.js and feed.js the same; a POST
//!      to compose.js is a 405 allowing GET;
//!   4aa. GET /favicon.ico: exactly app/favicon.ico, with every header a script
//!       has, to no one, to a cookie that admits no one, to Steve, and to a
//!       page's own request; another site's page: 403; a POST: 405;
//!   4ab. GET /chat/assets/alert-icon.svg: exactly app/alert-icon.svg, an
//!       SVG, with a script's headers, to anyone; a POST: 405;
//!   4b. POST exactly as a browser submits the compose box (form-encoded,
//!      its newline CRLF, `Origin` this server, `Sec-Fetch-Site`
//!      same-origin, a navigation's other headers): a 303 to the page, and
//!      exactly one record more on disk, its newline LF;
//!   5. GET a DM's conversation with no transcript: its page, saying it has no
//!      messages, with a compose box; its stream: a 200 event stream; its
//!      `/raw`: 404; nothing on disk, since only a message's POST starts a
//!      conversation;
//!   6. POST to it as a browser's own page would (its `Origin` and
//!      `Sec-Fetch-Site`): its transcript made, holding exactly the one
//!      record;
//!   7. GET under another `Host` (a rebound name): 403;
//!   8. POST from another origin's page: 403;
//!   9. POST that the browser says is cross-site: 403;
//!  10. both files on disk: exactly as before 7, nothing appended;
//!  11. open the channel's stream after its sixth message, and the DM's
//!      after its first: each a 200 event stream, not sniffed, the
//!      channel's first event exactly the seventh message's frame, its data
//!      the page's own HTML for it;
//!  12. while both are open, a plain GET of the channel's page: 200;
//!  13. POST to the channel: its stream gets exactly that message's frame;
//!  14. POST to the DM: its stream's first event is exactly that message's
//!      frame, so it got nothing of the channel's;
//!  15. POST to the channel again: its stream's next event is exactly that
//!      message's frame, so it got nothing of the DM's but its notice, as
//!      the DM is Steve's own, whose messages are news to him (57f);
//!  16. the stream under another `Host`: 403; with no count: 400.
//!  17. upload a PNG to the channel as the compose box does (a multipart
//!      form, `Origin` this server): 200, JSON naming its URL under the
//!      channel's page, a fresh name of 32 hex digits and `.png`;
//!  18. the image on disk in the channel's folder, byte for byte; Steve's
//!      upload total, `users/1/upload-bytes`, none before 17 and exactly
//!      the image's bytes after;
//!  19. GET its URL: 200, `image/png`, `nosniff`, kept for good, byte for
//!      byte;
//!  20. the same name under the DM's page: 404; a name never given under
//!      the channel's: 404;
//!  21. upload a file that is no image: 415, saying so;
//!  22. upload an image of exactly 10 MiB: 200; of one byte more: 413,
//!      saying so;
//!  23. upload from another origin's page, and one the browser says is
//!      cross-site: 403 each;
//!  24. the channel's uploads on disk: exactly the PNG and the 10 MiB image,
//!      nothing of 21, the second half of 22, or 23; the upload total
//!      exactly their bytes;
//!  25. a message holding an `<img>` of the PNG, as the compose box inserts
//!      it: on the channel's page an image; posted to the DM, text.
//!  26. the total seeded one byte short of room for the PNG: its upload a
//!      403 saying the limit is reached, nothing stored, the total unchanged;
//!  27. the total seeded with exactly room for it: 200, stored, the total
//!      exactly 1 GiB;
//!  28. the total seeded with text that is no number: its upload a 500
//!      saying so, nothing stored, the total unchanged.
//!  28a. a plain file where the DM's uploads folder would be, so an image
//!      uploaded there can't be stored: a 500 saying what the file system
//!      answered, and the image's bytes given back to the allowance, the
//!      total exactly as before;
//!  29. with the channel's stream open after its tenth message, send as the
//!      compose box's script does (form-encoded to `/send`, `Origin` this
//!      server, `Sec-Fetch-Site` same-origin): 201, HTML, exactly the
//!      message's HTML as the page writes it; one record more on disk; the
//!      stream's next event exactly that message's frame;
//!  30. the next message's frame comes next on that stream, so the sent one
//!      came exactly once;
//!  31. a blank send: 400, "The message is blank." in plain text, nothing
//!      stored;
//!  32. a send from another origin's page, and one the browser says is
//!      cross-site: 403 each, nothing stored.
//!  33. open the channel's stream as another site's page would (an
//!      `EventSource`, its `Origin` and `Sec-Fetch-Site` cross-site; or a
//!      `same-site` page on another port, no `Origin`): 403 each;
//!  34. open it as this server's own page does (`Origin` this server,
//!      `Sec-Fetch-Site` same-origin, `Sec-Fetch-Mode` cors): a 200 event
//!      stream that no other site may load;
//!  35. follow a link to the channel's page from another site (a
//!      navigation: `Sec-Fetch-Site` cross-site, `Sec-Fetch-Mode`
//!      navigate), its session cookie carried as `SameSite=Lax` allows:
//!      200, the page;
//! 35a. through the public origin: the page under its `Host`, 200; a POST
//!      to the DM from a page of it, a 303; one whose `Origin` is the local
//!      one, or another site's, 403 each.
//!
//! Then editing and reacting (`editAndReactSteps`), in a topic of their own,
//! `general/edits`, its stream open, as the page's scripts send:
//!
//! 35b. a first message: 201, its frame, and its markdown alone at
//!      `/raw?message=1`; a message not there, 404;
//! 35c. Steve's edit of it ("Edit of MSG_edits_1", a blank line, the new
//!      text): 201; the edit's frame, then the original again as an
//!      `event: replace` with no id, drawn as edited, exactly as the page
//!      now draws it; both records on disk; the edit's `MSG_edits_1`
//!      linked by the label the original's header writes, which the served
//!      actions.js follows (its `a.msg-ref`), as roc-markdown's
//!      `#msg-edits_1` names no element;
//! 35d. an edit of a message not there, or of LC's in roc-chat: 409 each, in
//!      words, nothing stored;
//! 35e. a reaction (`/react`, `msg=2`, 👍, `on=1`): 200; the reactions file
//!      its one line; the message again, with its reaction's button, exactly
//!      as the page draws it;
//! 35f. the same reaction again is still one; `on=0` empties the file and
//!      the message comes again with no reactions;
//! 35g. a reaction to no message, of no emoji, or with no `on`: 409, 400,
//!      400; a GET 405; another origin's 403; no one's 401; the file
//!      untouched;
//! 35h. a stream reopened after both messages: each message with an edit or
//!      a reaction sent again first, as it is now.
//!
//! Then a conversation's download (`downloadSteps`), the `d` key's
//! `.tar.gz`, read back by Zig's own gzip and tar readers:
//!
//! 35i. `general/edits`: 200, `application/gzip`, saved as
//!      `edits.tar.gz`; exactly `edits/edits.md`, the transcript's bytes,
//!      and `edits/edits.reactions.jsonl`, the reactions file's;
//! 35j. the seeded channel's: its transcript, then each image in its uploads
//!      folder, byte for byte, under `roc-chat/uploads/`;
//! 35k. a topic of 30 MiB of uploads: 200, whole; one image more, past the
//!      32 MiB a download holds: 409, saying so;
//! 35l. a topic with no transcript: 404; a POST: 405; no one: 401.
//!
//! Then the agents (`agentSteps`), on the users the server's first start
//! made:
//!
//!  36. the first start's files: Steve's account, `general` with him in it,
//!      the counter of ids at 2;
//!  37. GET /agents: Steve's page, a form that makes an agent, no agent;
//!  38. POST /agents `name=CC`: a 303 to /agents, CC's account on disk as
//!      Steve's agent, the counter at 3; Steve adds CC to `general` in its
//!      members file, and makes `private`, without CC, the same way;
//!  39. invite CC: the page shows its code, once, never stored; redeem it
//!      with no credential at all: 200, the key on one line, never stored;
//!      redeem it again: 401;
//!  40. an invite whose `expires` has passed (its file set back): 401;
//!  41. CC's stream opened with the key: a 200 event stream; asked for with
//!      no key: 403;
//!  42. POST as CC with the key: a 303, and the message's author on disk is
//!      CC; its stream's event is that message, in JSON;
//!  43. Steve posts in `private`, then in `general`: CC's stream's next
//!      event is `general`'s, so nothing of `private`'s came; CC's POST to
//!      `private` is a 403;
//!  44. a stream opened `?since=` CC's message's date: the messages of that
//!      second before it, then CC's, then #general's next, and nothing of
//!      #private's;
//!  45. GET `/raw` with the key: 200, plain text, the transcript's bytes;
//!  46. a wrong secret, a malformed bearer, and a key used to make an agent,
//!      to invite, to redeem, or to list agents: 401, 401, then 403 each;
//! 46a. a key invited `read=off&post=off`: reading, posting and listening
//!      are 403 each;
//!  47. revoke the key: a 303, CC's open streams ended at once, and the key
//!      is then a 401;
//!  48. on disk: the key's hash is SHA-256 of its secret, and no file under
//!      the data root holds the key's secret or any invite's code;
//!
//! Then the channels' pages (`memberSteps`), Steve the admin:
//!
//! 48a. GET /channels: each channel linked, and a form creating one;
//! 48b. create #crew: a 303 to its page, its members file empty; the name
//!      again in other letters: 409;
//! 48c. its page: no members, a button adding CC;
//! 48d. a new key for CC; its post in #crew before it is a member: 403;
//!      add CC: a 303, the members file `2`, again 409, no such user 404;
//!      CC then posts in #crew and reads it;
//! 48e. remove CC: a 303, the file empty, CC's open stream ended at once,
//!      again 409; CC's post and read then 403 each, its account standing;
//! 48f. CC's key listing, creating or adding: 403 each; no one: the page a
//!      303 to sign in, an add a 401;
//! 48g. a cross-site form post creating, adding or removing: 403 each,
//!      nothing changed.
//!
//! Then the human invites (`inviteSteps`):
//!
//! 48h. GET /invites: the page's card and a form inviting someone by name,
//!      saying nothing is open, and that GitHub signs people up here too;
//! 48i. invite Deb: the link `http://localhost:<port>/join#<code>` shown
//!      once, never stored; her account holding the name at once,
//!      `inviter` Steve, no password; the invite live, by Steve, for seven
//!      days, and said to be open; her name again: 409, the invites page
//!      again, saying why; signing in as her before she joins: 401;
//! 48j. GET /join: the form and its script; POST /join/name: her name as
//!      JSON; joining under a taken name, a name that is no name, or no
//!      password: 409, 400, 400, nothing spent; joining as Debbie: a 303 to
//!      #general's first topic and her session's cookie, never stored, her name Debbie,
//!      the invite spent, her password's bcrypt hash (cost 10) on disk, the
//!      session signed in; the code again, to join or for its name: 401;
//!      /invites/redeem: 404;
//! 48k. Debbie signs in with her password; adding a member or listing the
//!      channels, 403 each; Steve adds her to #crew, and she posts there;
//! 48l. Deb, the name she left, is free: Steve invites a new Deb; her
//!      invite past its expiry: 401, and said to be expired; its secret under
//!      another id: 401; Debbie's spent invite is said to be used;
//! 48m. Steve invites Debbie again: a new link, the same account; from a
//!      browser signed in, joining or asking the name: 409; joining under
//!      another name than the one she chose: 409; joining as Debbie with a
//!      new password: her old one is then a 401 and her new one signs in;
//!      Debbie inviting again someone Steve invited, and Steve inviting
//!      again the founder: 403 each; an agent: 404;
//! 48n. ten open invites: each made; an eleventh, again or new: 403;
//! 48o. CC's key inviting, joining or asking the name: 403 each; no one:
//!      /invites a 303 to sign in, an invite a 401;
//! 48p. a cross-site form post inviting, inviting again or joining: 403
//!      each, nothing made;
//! 48q. no file holds an invite's code or a password.
//!
//! Then GitHub sign-in (`gitHubSteps`), against a fake GitHub on a free port
//! (host/fake_github.zig), the server pointed at it by the `.github-` files
//! in its data root, as a real one is at GitHub:
//!
//! 48r. the sign-in page: a link to GitHub, going to `next`;
//! 48s. the start: a 303 to the fake's authorize page, naming the client id,
//!      this server's way back and a state, the state's cookie set; a `next`
//!      that is no path here, a 400;
//! 48t. an account no human holds, walked through the fake: the form that
//!      asks a name, empty as its login is no name, the sign-up's cookie set
//!      for ten minutes, the state forgotten, no session, no account;
//! 48u. no state, no cookie, another browser's cookie, a forged signature
//!      and an expired state: 403 each, and the fake is asked nothing;
//! 48v. the human saying no at GitHub, a code GitHub refuses, and an answer
//!      that makes no sense: 403, 403, 502;
//! 48w. Steve's `github-id` written: he signs in through the fake, a 303 to
//!      `next`, a session for a year, `github-session-secret` made; his old
//!      session ends, and the new one reads the page;
//! 48x. his password still signs him in, and both sessions read the page;
//! 48y. a human with no password, made by hand as the owner would, signs in
//!      through the fake; her password form is a 401;
//! 48z. her `github-session-secret` rewritten, then removed: her session ends
//!      each time, and she signs in again; her `github-id` removed: her
//!      session ends, and GitHub's sign-in asks for a name, as for anyone new;
//! 48za. two humans holding one id: 403, neither signed in; Steve's
//!      `github-id` damaged: his page and anyone's GitHub sign-in a 500, no
//!      account made, and his page again once it is mended;
//! 48zb. a key at any of the routes: 403; the wrong method to the name: 405;
//!      a cross-site form post of a name: 403, nothing made;
//! 48zc. a new human whose login is a free name: the form holds it; choosing
//!      it makes their account, `github-id` and `github-session-secret`
//!      written, a 303 to `next`, a session, the sign-up forgotten, and no
//!      password or inviter; the password form never signs them in;
//! 48zd. their next GitHub sign-in reaches the same account, and no other is
//!      made;
//! 48ze. a login that is taken offers nothing; a taken name, a channel's, and
//!      one that is no name are refused, the form again, the id unspent and
//!      the sign-up good, and a free name then makes the account;
//! 48zf. no sign-up, one rewritten by the browser, a state's signature
//!      passed as one, and an expired one: 403 each, nothing made; one nine
//!      minutes old is good;
//! 48zg. the same submit twice, and a second tab's sign-up: one account, and
//!      no session from the second;
//! 48zh. no chat file holds the client secret or a token, and no refusal says
//!      them;
//! 48zi. a human with a password links GitHub from /agents: their page offers
//!      it, and no agent work, which is the admin's (a make, an invite and a
//!      revoke of theirs 403 each), the trip binds `github-id` and `github-session-secret`, no account
//!      is made, their old session ends and the answer's own admits them, the
//!      offer is gone, and that GitHub then signs in to the same account;
//! 48zj. linking an id someone holds: 409, nothing bound, the session unbroken;
//!      linking twice, at the start or from a second tab: 409, the first
//!      binding kept;
//! 48zk. a forged state, a state naming another human, and a session that has
//!      gone: 403 each, nothing bound; a stale session secret is replaced;
//! 48zl. a key: 403; no one: 401; a GET: 405; a cross-site post: 403;
//! 48zm. a new human by GitHub lands, in #general, on a page they can read:
//!      the conversation they were heading for when they may read it and it
//!      exists, else general's first topic, whether they were heading for
//!      another channel's, /channels, /agents or a topic with no messages;
//! 48zn. with general's members file gone: a sign-up and an invite, a 500
//!      each, nothing made;
//! 48zo. with one id left, a new human takes 65535, whose session reads their
//!      page; the next is refused as the chat being full, nothing made;
//! 48zv. the sign-in page of someone signed in: no form and no GitHub, and
//!      its GitHub start, even from another site, a 303 to /agents (48zq);
//!  54. on a third server: twenty GitHub sign-ups in a day, then a 503 saying
//!      sign-ups are paused, at the way back and at the name, nothing made;
//!      an invite still makes its account;
//! 48zw. a key at Browse, and starting a topic: 403 each;
//! 48zy. a device code: Steve's page says he has made none; a code made, shown
//!      once as two groups of four digits with a thin space between,
//!      with the warning, never stored, and kept only as its HMAC; a second
//!      cancels the first, whose redemption from a phone is refused; the
//!      second, typed with a dash, signs the phone in as Steve,
//!      bound to a new device key, active, and Steve's open stream hears "A
//!      new device signed in"; it works once, and his page then says it was
//!      used; an expired code refused; the phone's "Sign out" asks first,
//!      changing nothing, refused from another site, and confirmed revokes
//!      the key, so the phone's old cookie is refused, ends its open stream,
//!      and cancels the live code; the key's state alone decides, a damaged or missing one
//!      refusing; every refusal the same page; a key may not make one, nor
//!      redeem one;
//! 48zz. a client's 10 failed codes lock the form for it, a 429 even for a
//!      right code, while another client's is still tried; an IPv6 client is
//!      its /64; a session a code started is marked, may not link GitHub or
//!      make agents or their invites, and a password sign-in after is
//!      ordinary and signs out at once, asked nothing; the page lists sign-ins by code, coarsely; "Sign out other
//!      devices" ends every other session of the human's.
//! 48zx. one `X-Forwarded-For` client at `requests_per_client_most`, 8 streams
//!      and the rest requests with their bodies held back: each admitted; one
//!      request more: a 429; another client and a request with no such
//!      header: 200; a held request answered: its count back, the client
//!      served, then at the limit again and refused; a stream ended for a
//!      newer one: its count back too.
//!
//!  49. sign out: a 303 to the sign-in page, the cookie cleared, never
//!      stored.
//!
//! Then a second server, on a chat of its own with no GitHub settings and no
//! conversation yet:
//!
//!  50. no link to GitHub on the sign-in page or /agents; each GitHub route a
//!      404 by any method, from no one and from Steve;
//!  51. an invited human joins: #general holds them, and with no conversation
//!      to land on they land on /agents, a 200;
//!  52. Browse for a stranger: the sign-in page, and back after; a new topic: 401;
//! 53a. presence: Uma, just joined, is away in Steve's sidebar; her first
//!      page sends Steve's open stream her dot and "Uma has come online.",
//!      linked to their DM; her next page tells no one, and Steve's page
//!      then draws her online;
//!  53. Browse lists a human's DMs and channels, and no other's;
//! 53a. Browse links to /invites for the owner and any other human, the link
//!      leading to the form; a conversation's top bar links there too, for
//!      each of them; the sign-in page doesn't, and a key reaches neither
//!      Browse nor /invites;
//!  54. every signed-in page has the Browse and Invites links, and none a sign-up, join or
//!      sign-in link or form;
//!  55. a topic where the human can't post, its page, its stream and its
//!      download: 403 each;
//!      no such human: 404; a GET: 405; a cross-site post: 403;
//!  56. a name that is no topic: Browse again, a 400, nothing made;
//!  57. the acceptance path: Browse, a person, a topic, an empty chat, compose,
//!      Send, and see it, live and on the page, and on Browse for its humans.
//! 57b. (in 53a) a DM's title is the other human "on" the topic, a link to
//!      the page itself; the line above Steve's DM with Uma says she hasn't
//!      been on since the server started, then that she is online;
//! 57a. a topic's first message tells its humans' open pages, the author's
//!      too, `topic-added`; Tam adds a topic, and Steve's open stream hears
//!      it; her next message there adds no topic again;
//! 57c. each message tells every other reader, as Gopher Chat's notify did:
//!      Steve's open stream hears `message-notice` for each of Tam's, linked
//!      to the message itself (its topic's page at `#msg-N`), even the page's
//!      own topic's (the page drops that one), and his
//!      open Recent page's stream hears it for her channel post; his own
//!      messages tell him nothing.
//! 57f. but a message in his own DM is news to him, as if someone else had
//!      sent it (Steve, 2026-11-20): his open stream on another page hears
//!      its `message-notice`, linked to it; a message of his to Tam again
//!      tells him nothing.
//! 57d. on the second server, a human just joined (Rita): her join writes
//!      `auth/<id>/joined`, the second, which a join after an invite again
//!      keeps; so she is new, her
//!      upload total seeded 100 MiB less a PNG, its upload a 200, the total
//!      exactly 100 MiB; one more: a 403 saying a new account's limit,
//!      nothing stored or counted;
//! 57e. Rita sends 30 messages to a topic: 201 each; the 31st a 429, saying
//!      so, and the transcript exactly the 30;
//! 57f. the disk's free space (the data root's `free_bytes_for_test`) a byte
//!      under 2 GiB: a message, an upload and an invite each a 507 saying
//!      the server is low on disk, nothing written; the page still 200; at
//!      2 GiB exactly, a message a 303.
//! 57g. Tam, who has a password and no `joined`, invited again and joined
//!      again: still no `joined`; Sam, whose `joined` a crash left empty,
//!      joins: it holds the second.
//!
//! Step 2 posts as the README's `curl` does: `Host: localhost:<port>`, the
//! session's cookie, no `Origin`, no `Sec-Fetch-Site`.
//!
//! The server stops and the data root goes before it returns, pass or
//! fail, so nothing is left running and nothing is left behind.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const sse = @import("sse.zig");
const files = @import("file_primitives.zig");
const fake_github = @import("fake_github.zig");
const github = @import("github_client.zig");

const seed_path = "demo/data/chat/channel/general/roc-chat/transcript";
const frozen_page = "demo/roc-chat.html";
const channel_url = "/chat/channel/general/roc-chat";
/// The origin the server is told a proxy serves it under.
const public_origin = "https://chat.example.test";
const script_url = "/chat/assets/compose.js";
const script_file = "app/compose.js";
/// The page's other scripts, each served as compose.js is.
const other_scripts = [_][]const u8{ "palette.js", "chrome.js", "sidebar.js", "feed.js", "citation.js", "panel.js" };
const dm_url = "/chat/dm/1_1/plans";
const dm_transcript = "chat/dm/1_1/plans/transcript";
const channel_uploads = "chat/channel/general/roc-chat/uploads";
/// Where the DM's uploads folder would be; step 28a puts a plain file there.
const dm_uploads = "chat/dm/1_1/plans/uploads";
/// Steve's upload total, the bytes he has uploaded, in his own folder.
const total_path = "users/1/upload-bytes";
/// What `uploadTotal` says when there is no total file.
const no_total = "(none)";
/// A browser's own boundary, as Chrome writes one.
const upload_type = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW";

const RunResult = @typeInfo(@TypeOf(http.Server.run)).@"fn".return_type.?;

/// Steve's password, which the run writes the hash of.
const steve_password = "correct horse battery staple";

/// The link to Browse, which every signed-in page has.
const browse_link = "<a href=\"/chat\">Browse</a>";

/// The Home link, app/HomeLink.roc's, which every signed-in page's top bar
/// opens its links with.
const home_link = "<a href=\"https://lynrummy.com/\">Home</a> · ";

/// The session cookie's header line that signs Steve in, once he has
/// signed in (step 0c): every request of his carries it.
var steve_session: []const u8 = "";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const a = init.arena.allocator();
    const cwd = Io.Dir.cwd();
    const began = Io.Clock.now(.awake, io);

    var name_buf: [64]u8 = undefined;
    var random: [8]u8 = undefined;
    io.random(&random);
    const data_name = try std.fmt.bufPrint(&name_buf, ".zig-cache/end-to-end-{x}", .{std.mem.readInt(u64, &random, .little)});
    try cwd.createDirPath(io, data_name);
    defer cwd.deleteTree(io, data_name) catch |e| std.debug.print("end-to-end: {s} not removed ({t})\n", .{ data_name, e });
    const data = try cwd.openDir(io, data_name, .{});
    defer data.close(io);

    const seed = try cwd.readFileAlloc(io, seed_path, a, .limited(1024 * 1024));
    try data.createDirPath(io, std.fs.path.dirname(seed_path["demo/data/".len..]).?);
    try data.writeFile(io, .{ .sub_path = seed_path["demo/data/".len..], .data = seed });

    const fake = try fake_github.Fake.start(io, gpa);
    defer fake.stop();
    try writeGitHubSettings(io, data, fake);

    const root: files.DataRoot = .{ .io = io, .dir = data };
    // The run signs in more often than the bucket of password checks
    // refills, so its burst is the run's sign-ins; host/http_test.zig tests
    // the bucket at its own size.
    var server = try http.Server.listen(io, gpa, .{ .port = 0, .root = &root, .public_origin = public_origin, .limits = .{ .password_check_burst = 50 } });
    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch |e| std.debug.print("end-to-end: the server's run: {t}\n", .{e});
    }
    const port = server.port();
    const t: Steps = .{ .io = io, .began = began };

    try signInSteps(a, io, port, data, t);

    // 1.
    const first = try get(a, io, port, channel_url);
    try t.check("GET the seeded conversation: 200, exactly the demo's frozen page", first.status == 200 and
        std.mem.eql(u8, first.body, try cwd.readFileAlloc(io, frozen_page, a, .limited(1024 * 1024))));
    const policy = first.header("content-security-policy") orelse "";
    try t.check("its defences: the content security policy, scripts from this origin alone, and nosniff, as sent", std.mem.startsWith(u8, policy, "default-src 'none'; ") and
        has(policy, "; script-src 'self'; ") and !has(policy, "unsafe-eval") and !has(policy, "script-src 'unsafe-inline'") and
        std.mem.eql(u8, first.header("x-content-type-options") orelse "", "nosniff"));
    try t.check("its compose box: a form posting `markdown` to the conversation's own URL, sending to its `/send`, uploading to its `/upload`, and the script", has(first.body, "<form method=\"post\" action=\"" ++ channel_url ++ "\" data-send=\"" ++ channel_url ++ "/send\" data-upload=\"" ++ channel_url ++ "/upload\" data-image-byte-limit=\"10485760\"><textarea name=\"markdown\"></textarea>") and
        has(first.body, "<script src=\"" ++ script_url ++ "\"></script>"));

    // 2.
    const before = files.current_utc_seconds_since_epoch(io);
    const posted = try post(a, io, port, .{ .path = channel_url, .form = "markdown=Hello+from+the+**end+to+end**%21%0D%0A%0D%0A-------------" });
    const after = files.current_utc_seconds_since_epoch(io);
    try t.check("POST a message as the README's curl does: 303 to the conversation's page", posted.status == 303 and
        std.mem.eql(u8, posted.header("location") orelse "", channel_url));

    // 3.
    const again = try get(a, io, port, channel_url);
    try t.check("GET it again: 200, the message rendered, as message 6", again.status == 200 and
        has(again.body, "<strong>end to end</strong>!") and has(again.body, "id=\"msg-6\"") and has(again.body, ">MSG_roc-chat_6</a>"));

    // 4.
    const body = "Hello from the **end to end**!\n\n\\-------------";
    const on_disk = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    try t.check("the file on disk: the seed and exactly one record, dated by the host's clock", recordFits(a, on_disk, seed, "roc-chat_6", body, before, after));

    // 4a.
    const script = try get(a, io, port, script_url);
    try t.check("GET the page's script: 200, JavaScript, nosniff, exactly app/compose.js", script.status == 200 and
        std.mem.eql(u8, script.header("content-type") orelse "", "text/javascript; charset=utf-8") and
        std.mem.eql(u8, script.header("x-content-type-options") orelse "", "nosniff") and
        std.mem.eql(u8, script.body, try cwd.readFileAlloc(io, script_file, a, .limited(1024 * 1024))));
    var others_served = true;
    inline for (other_scripts) |name| {
        const other = try get(a, io, port, "/chat/assets/" ++ name);
        others_served = others_served and other.status == 200 and
            std.mem.eql(u8, other.header("content-type") orelse "", "text/javascript; charset=utf-8") and
            std.mem.eql(u8, other.body, try cwd.readFileAlloc(io, "app/" ++ name, a, .limited(1024 * 1024)));
    }
    try t.check("GET the page's other scripts: 200, JavaScript, each exactly its app/ file", others_served);
    const script_post = try post(a, io, port, .{ .path = script_url, .form = "markdown=x" });
    try t.check("POST to the script: 405, allowing GET alone", script_post.status == 405 and
        std.mem.eql(u8, script_post.header("allow") orelse "", "GET"));

    // 4aa.
    const icon_file = try cwd.readFileAlloc(io, "app/favicon.ico", a, .limited(1024 * 1024));
    const icon_page_asks = "sec-fetch-site: same-origin\r\nsec-fetch-mode: no-cors\r\nsec-fetch-dest: image\r\n";
    const icon_answers = [_]Response{
        try anonymousGet(a, io, port, "/favicon.ico"),
        try getAs(a, io, port, "cookie: __Host-gopher_auth=MQ.1.bad\r\n", "/favicon.ico"),
        try get(a, io, port, "/favicon.ico"),
        try getAs(a, io, port, icon_page_asks, "/favicon.ico"),
    };
    var icon_served = true;
    for (icon_answers) |icon| {
        icon_served = icon_served and icon.status == 200 and
            std.mem.eql(u8, icon.header("content-type") orelse "", "image/x-icon") and std.mem.eql(u8, icon.body, icon_file);
        inline for (.{ "cache-control", "x-content-type-options", "cross-origin-resource-policy" }) |name| {
            icon_served = icon_served and icon.header(name) != null and
                std.mem.eql(u8, icon.header(name).?, script.header(name) orelse "");
        }
    }
    try t.check("GET /favicon.ico, by no one, a cookie that admits no one, Steve and a page: 200, exactly app/favicon.ico, an icon, a script's other headers", icon_served);
    const icon_elsewhere = try getAs(a, io, port, "sec-fetch-site: cross-site\r\nsec-fetch-mode: no-cors\r\nsec-fetch-dest: image\r\n", "/favicon.ico");
    const icon_post = try anonymousPost(a, io, port, "/favicon.ico", "");
    try t.check("the icon asked for by another site's page: 403; a POST: 405, allowing GET alone", icon_elsewhere.status == 403 and
        icon_post.status == 405 and std.mem.eql(u8, icon_post.header("allow") orelse "", "GET"));

    // 4ab.
    const alert_path = "/chat/assets/alert-icon.svg";
    const alert_file = try cwd.readFileAlloc(io, "app/alert-icon.svg", a, .limited(1024 * 1024));
    const alert_answers = [_]Response{
        try anonymousGet(a, io, port, alert_path),
        try get(a, io, port, alert_path),
        try getAs(a, io, port, icon_page_asks, alert_path),
    };
    var alert_served = true;
    for (alert_answers) |icon| {
        alert_served = alert_served and icon.status == 200 and
            std.mem.eql(u8, icon.header("content-type") orelse "", "image/svg+xml") and std.mem.eql(u8, icon.body, alert_file);
        inline for (.{ "cache-control", "x-content-type-options", "cross-origin-resource-policy" }) |name| {
            alert_served = alert_served and icon.header(name) != null and
                std.mem.eql(u8, icon.header(name).?, script.header(name) orelse "");
        }
    }
    const alert_post = try anonymousPost(a, io, port, alert_path, "");
    try t.check("GET the alert icon, by no one, Steve and a page: 200, exactly app/alert-icon.svg, an SVG, a script's other headers; a POST: 405", alert_served and
        alert_post.status == 405 and std.mem.eql(u8, alert_post.header("allow") orelse "", "GET"));

    // 4b.
    const before_box = files.current_utc_seconds_since_epoch(io);
    const browser = try std.fmt.allocPrint(a, "origin: http://localhost:{d}\r\n" ++
        "sec-fetch-site: same-origin\r\nsec-fetch-mode: navigate\r\nsec-fetch-user: ?1\r\nsec-fetch-dest: document\r\n" ++
        "referer: http://localhost:{d}" ++ channel_url ++ "\r\n" ++
        "accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\nupgrade-insecure-requests: 1\r\n", .{ port, port });
    const boxed = try post(a, io, port, .{ .path = channel_url, .form = "markdown=Sent+from+the+compose+box%0D%0Aa+second+line+%C2%B7+%26+more", .more = browser });
    const after_box = files.current_utc_seconds_since_epoch(io);
    const box_disk = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    try t.check("POST as the browser submits the compose box: 303 to the page, exactly one record more", boxed.status == 303 and
        std.mem.eql(u8, boxed.header("location") orelse "", channel_url) and
        recordFits(a, box_disk, on_disk, "roc-chat_7", "Sent from the compose box\na second line · & more", before_box, after_box));

    // 5.
    const empty = try get(a, io, port, dm_url);
    var empty_stream = try Stream.open(a, io, port, dm_url ++ "/stream?after=0");
    const empty_streams = empty_stream.isEventStream();
    empty_stream.close();
    const empty_raw = try get(a, io, port, dm_url ++ "/raw");
    try t.check("GET a DM's conversation with no transcript: its page, no messages, a compose box; its stream: 200; its /raw: 404; nothing on disk", empty.status == 200 and
        has(empty.body, "No messages yet.") and has(empty.body, "<form method=\"post\" action=\"" ++ dm_url ++ "\"") and
        empty_streams and empty_raw.status == 404 and has(empty_raw.body, "No such conversation: " ++ dm_url) and
        !(try exists(io, data, "chat/dm/1_1")));

    // 6.
    const before_dm = files.current_utc_seconds_since_epoch(io);
    const own_page = try std.fmt.allocPrint(a, "origin: http://localhost:{d}\r\nsec-fetch-site: same-origin\r\n", .{port});
    const started = try post(a, io, port, .{ .path = dm_url, .form = "markdown=Note+to+self", .more = own_page });
    const after_dm = files.current_utc_seconds_since_epoch(io);
    const dm_file = data.readFileAlloc(io, dm_transcript, a, .limited(1024 * 1024)) catch "";
    try t.check("POST to it from the server's own page: 303, its transcript made, exactly one record", started.status == 303 and
        recordFits(a, dm_file, "", "plans_1", "Note to self", before_dm, after_dm));

    // 7.
    const rebound = try exchange(a, io, port, try std.fmt.allocPrint(a, "GET " ++ channel_url ++ " HTTP/1.1\r\nhost: rebound.example:{d}\r\n\r\n", .{port}));
    try t.check("GET under another Host: 403, saying so", rebound.status == 403 and
        has(rebound.body, "The request&#39;s Host is not this server&#39;s"));

    // 8.
    const forged = try post(a, io, port, .{ .path = channel_url, .form = "markdown=forged", .more = "origin: http://evil.example\r\n" });
    try t.check("POST from another origin's page: 403, saying so", forged.status == 403 and
        has(forged.body, "another origin"));

    // 9.
    const cross = try post(a, io, port, .{ .path = dm_url, .form = "markdown=forged", .more = "sec-fetch-site: cross-site\r\n" });
    try t.check("POST the browser says is cross-site: 403, saying so", cross.status == 403 and
        has(cross.body, "another site"));

    // 10.
    const channel_now = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    const dm_now = try data.readFileAlloc(io, dm_transcript, a, .limited(1024 * 1024));
    try t.check("both files on disk: exactly as before, nothing appended", std.mem.eql(u8, channel_now, box_disk) and
        std.mem.eql(u8, dm_now, dm_file));

    // 11.
    var channel_stream = try Stream.open(a, io, port, channel_url ++ "/stream?after=6");
    defer channel_stream.close();
    var dm_stream = try Stream.open(a, io, port, dm_url ++ "/stream?after=1");
    defer dm_stream.close();
    const page_of_seven = try get(a, io, port, channel_url);
    try t.check("open the channel's stream and the DM's: 200 event streams, not sniffed, never cached", channel_stream.isEventStream() and dm_stream.isEventStream());
    try t.check("the channel's backlog: exactly the seventh message's frame, the page's own HTML", std.mem.eql(u8, try channel_stream.event(), try frameOf(a, page_of_seven.body, "7")));

    // 12.
    const while_open = try get(a, io, port, channel_url);
    try t.check("a plain GET while both streams are open: 200, the same page", while_open.status == 200 and std.mem.eql(u8, while_open.body, page_of_seven.body));

    // 13.
    const live = try post(a, io, port, .{ .path = channel_url, .form = "markdown=Live+on+the+**stream**" });
    const page_of_eight = try get(a, io, port, channel_url);
    try t.check("POST to the channel: 303, and its stream gets exactly that message's frame", live.status == 303 and
        std.mem.eql(u8, try channel_stream.event(), try frameOf(a, page_of_eight.body, "8")));

    // 14.
    const to_dm = try post(a, io, port, .{ .path = dm_url, .form = "markdown=Only+for+the+DM" });
    const dm_page = try get(a, io, port, dm_url);
    try t.check("POST to the DM: its stream's first event is exactly that message's frame, none of the channel's", to_dm.status == 303 and
        std.mem.eql(u8, try dm_stream.event(), try frameOf(a, dm_page.body, "2")));

    // 15.
    const again_live = try post(a, io, port, .{ .path = channel_url, .form = "markdown=Live+again" });
    const page_of_nine = try get(a, io, port, channel_url);
    // Steve's stream carries his own key too, so his own DM's message comes
    // to the channel's page as its notice, and only that.
    const dm_notice = try channel_stream.event();
    try t.check("POST to the channel again: its stream's next event is exactly that message's frame, none of the DM's but its notice, the DM being Steve's own", again_live.status == 303 and
        std.mem.eql(u8, dm_notice, "event: message-notice\ndata: <a href=\"" ++ dm_url ++ "#msg-2\">Steve sent you a message on plans.</a>\n\n") and
        std.mem.eql(u8, try channel_stream.event(), try frameOf(a, page_of_nine.body, "9")));

    // 16.
    const rebound_stream = try exchange(a, io, port, try std.fmt.allocPrint(a, "GET " ++ channel_url ++ "/stream?after=0 HTTP/1.1\r\nhost: rebound.example:{d}\r\n\r\n", .{port}));
    const uncounted = try get(a, io, port, channel_url ++ "/stream");
    try t.check("the stream under another Host: 403; with no count: 400", rebound_stream.status == 403 and uncounted.status == 400 and
        has(uncounted.body, "names no count"));

    // 17.
    const total_before = try uploadTotal(a, io, data);
    const png = try onePixelPng(a);
    const image_prefix = channel_url ++ "/uploads/";
    const uploaded = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "cat.png", png), .more = own_page });
    const url = jsonUrl(uploaded.body) orelse "";
    const name = if (url.len > image_prefix.len) url[image_prefix.len..] else "";
    try t.check("upload a PNG as the compose box does: 200, JSON naming its URL under the channel's page, a fresh name", uploaded.status == 200 and
        std.mem.eql(u8, uploaded.header("content-type") orelse "", "application/json") and
        std.mem.startsWith(u8, url, image_prefix) and isFreshName(name, ".png") and
        std.mem.endsWith(u8, uploaded.body, ",\"name\":\"cat.png\",\"kind\":\"image\",\"width\":0,\"height\":0}"));

    // 18.
    const kept = data.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ channel_uploads, name }), a, .limited(1024 * 1024)) catch "";
    try t.check("the image on disk in the channel's folder, byte for byte", std.mem.eql(u8, kept, png));
    try t.check("Steve's upload total: none before, exactly the image's bytes after", std.mem.eql(u8, total_before, no_total) and
        std.mem.eql(u8, try uploadTotal(a, io, data), try std.fmt.allocPrint(a, "{d}", .{png.len})));

    // 19.
    const served = try getAt(a, io, port, url);
    try t.check("GET its URL: 200, image/png, nosniff, kept for good, byte for byte", served.status == 200 and
        std.mem.eql(u8, served.header("content-type") orelse "", "image/png") and
        std.mem.eql(u8, served.header("x-content-type-options") orelse "", "nosniff") and
        std.mem.eql(u8, served.header("cache-control") orelse "", "private, max-age=31536000, immutable") and
        std.mem.eql(u8, served.body, png));

    // 20.
    const elsewhere = try getAt(a, io, port, try std.fmt.allocPrint(a, dm_url ++ "/uploads/{s}", .{name}));
    const never = try getAt(a, io, port, image_prefix ++ "00000000000000000000000000000000.png");
    try t.check("the same name under the DM's page: 404; a name never given under the channel's: 404", elsewhere.status == 404 and never.status == 404);

    // 21.
    const text = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "a.png", "hello, not an image"), .more = own_page });
    try t.check("upload a file that is no image: 415, saying so", text.status == 415 and
        std.mem.eql(u8, text.body, "unsupported file type (images: png, jpeg, gif, webp)\n"));

    // 22.
    const most = 10 * 1024 * 1024;
    const big = try a.alloc(u8, most + 1);
    @memset(big, 0);
    @memcpy(big[0..png.len], png);
    const at_most = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "big.png", big[0..most]), .more = own_page });
    const at_most_url = jsonUrl(at_most.body) orelse "";
    const over = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "big.png", big), .more = own_page });
    try t.check("upload an image of exactly 10 MiB: 200; of one byte more: 413, saying so", at_most.status == 200 and
        std.mem.startsWith(u8, at_most_url, image_prefix) and isFreshName(at_most_url[image_prefix.len..], ".png") and
        over.status == 413 and std.mem.eql(u8, over.body, "image too large — the limit is 10 MiB.\n"));

    // 23.
    const foreign = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "cat.png", png), .more = "origin: http://evil.example\r\n" });
    const cross_site = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "cat.png", png), .more = "sec-fetch-site: cross-site\r\n" });
    try t.check("upload from another origin's page, and one the browser says is cross-site: 403 each", foreign.status == 403 and cross_site.status == 403);

    // 24.
    const names = try namesIn(a, io, data, channel_uploads);
    const at_most_kept = data.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ channel_uploads, at_most_url[image_prefix.len..] }), a, .limited(most + 1)) catch "";
    try t.check("the channel's uploads on disk: exactly the PNG and the 10 MiB image, nothing refused kept", names.len == 2 and
        std.mem.eql(u8, kept, png) and std.mem.eql(u8, at_most_kept, big[0..most]) and
        (std.mem.eql(u8, names[0], name) or std.mem.eql(u8, names[1], name)));
    try t.check("Steve's upload total: exactly the two images' bytes, nothing refused counted", std.mem.eql(u8, try uploadTotal(a, io, data), try std.fmt.allocPrint(a, "{d}", .{png.len + most})));

    // 25.
    const img = try std.fmt.allocPrint(a, "<img src=\"{s}\" alt=\"cat.png\">", .{url});
    const with_image = try post(a, io, port, .{ .path = channel_url, .form = try formEncoded(a, img) });
    const channel_page = try get(a, io, port, channel_url);
    const dm_with_image = try post(a, io, port, .{ .path = dm_url, .form = try formEncoded(a, img) });
    const dm_page_now = try get(a, io, port, dm_url);
    try t.check("a message holding an <img> of the PNG: on the channel's page an image; posted to the DM, text", with_image.status == 303 and
        has(channel_page.body, img) and dm_with_image.status == 303 and !has(dm_page_now.body, img) and
        has(dm_page_now.body, try std.fmt.allocPrint(a, "&lt;img src=&quot;{s}&quot;", .{url})));

    // 26.
    const allowance = 1 << 30;
    const one_over = try std.fmt.allocPrint(a, "{d}", .{allowance - png.len + 1});
    try data.writeFile(io, .{ .sub_path = total_path, .data = one_over });
    const spent = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "cat.png", png), .more = own_page });
    try t.check("upload a PNG one byte past Steve's 1 GiB allowance: 403, saying the limit is reached; nothing stored or counted", spent.status == 403 and
        std.mem.eql(u8, spent.body, "Upload limit reached — you've used your 1 GiB upload allowance.\n") and
        (try namesIn(a, io, data, channel_uploads)).len == 2 and std.mem.eql(u8, try uploadTotal(a, io, data), one_over));

    // 27.
    try data.writeFile(io, .{ .sub_path = total_path, .data = try std.fmt.allocPrint(a, "{d}", .{allowance - png.len}) });
    const last_fit = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "cat.png", png), .more = own_page });
    try t.check("upload a PNG that fills the allowance exactly: 200, stored, the total exactly 1 GiB", last_fit.status == 200 and
        std.mem.startsWith(u8, jsonUrl(last_fit.body) orelse "", image_prefix) and
        (try namesIn(a, io, data, channel_uploads)).len == 3 and std.mem.eql(u8, try uploadTotal(a, io, data), "1073741824"));

    // 28.
    try data.writeFile(io, .{ .sub_path = total_path, .data = "lots" });
    const garbled = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "cat.png", png), .more = own_page });
    try t.check("upload with a total that is no number: 500, saying so; nothing stored, the total as it was", garbled.status == 500 and
        std.mem.eql(u8, garbled.body, "Upload failed: your upload total is not a number.\n") and
        (try namesIn(a, io, data, channel_uploads)).len == 3 and std.mem.eql(u8, try uploadTotal(a, io, data), "lots"));

    // 28a.
    try data.writeFile(io, .{ .sub_path = total_path, .data = "100" });
    try data.writeFile(io, .{ .sub_path = dm_uploads, .data = "a file, not a folder" });
    const unstored = try post(a, io, port, .{ .path = dm_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "cat.png", png), .more = own_page });
    try t.check("upload an image that can't be stored: 500, saying what the file system answered; its bytes given back, the total as it was", unstored.status == 500 and
        std.mem.startsWith(u8, unstored.body, "Upload failed. The file system answered ") and
        std.mem.eql(u8, try uploadTotal(a, io, data), "100") and
        std.mem.eql(u8, try data.readFileAlloc(io, dm_uploads, a, .limited(1024)), "a file, not a folder"));

    // 29.
    var send_stream = try Stream.open(a, io, port, channel_url ++ "/stream?after=10");
    defer send_stream.close();
    const script_fetch = try std.fmt.allocPrint(a, "origin: http://localhost:{d}\r\n" ++
        "sec-fetch-site: same-origin\r\nsec-fetch-mode: cors\r\nsec-fetch-dest: empty\r\n" ++
        "referer: http://localhost:{d}" ++ channel_url ++ "\r\naccept: */*\r\n", .{ port, port });
    const before_send = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    const sent_before = files.current_utc_seconds_since_epoch(io);
    const sent = try post(a, io, port, .{ .path = channel_url ++ "/send", .form = "markdown=Sent+**without**+a+reload%0Atwo+lines", .more = script_fetch });
    const sent_after = files.current_utc_seconds_since_epoch(io);
    const after_send = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    const page_of_eleven = try get(a, io, port, channel_url);
    try t.check("send as the compose box's script does: 201, HTML, exactly the message's HTML as the page writes it, one record more", sent.status == 201 and
        std.mem.eql(u8, sent.header("content-type") orelse "", "text/html; charset=utf-8") and
        std.mem.eql(u8, sent.body, try articleOf(page_of_eleven.body, "11")) and
        recordFits(a, after_send, before_send, "roc-chat_11", "Sent **without** a reload\ntwo lines", sent_before, sent_after));
    try t.check("the open stream's next event: exactly that message's frame", std.mem.eql(u8, try send_stream.event(), try frameOf(a, page_of_eleven.body, "11")));

    // 30.
    const next_sent = try post(a, io, port, .{ .path = channel_url ++ "/send", .form = "markdown=And+the+next", .more = script_fetch });
    const page_of_twelve = try get(a, io, port, channel_url);
    try t.check("send the next: 201, and the stream's next event is its frame, so the one before came once", next_sent.status == 201 and
        std.mem.eql(u8, try send_stream.event(), try frameOf(a, page_of_twelve.body, "12")));

    // 31.
    const before_refusals = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    const blank = try post(a, io, port, .{ .path = channel_url ++ "/send", .form = "markdown=+%0A", .more = script_fetch });
    try t.check("a blank send: 400, its words in plain text, nothing stored", blank.status == 400 and
        std.mem.eql(u8, blank.header("content-type") orelse "", "text/plain; charset=utf-8") and
        std.mem.eql(u8, blank.body, "The message is blank.\n") and
        std.mem.eql(u8, try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024)), before_refusals));

    // 32.
    const foreign_send = try post(a, io, port, .{ .path = channel_url ++ "/send", .form = "markdown=forged", .more = "origin: http://evil.example\r\n" });
    const cross_send = try post(a, io, port, .{ .path = channel_url ++ "/send", .form = "markdown=forged", .more = "sec-fetch-site: cross-site\r\n" });
    try t.check("a send from another origin's page, and one the browser says is cross-site: 403 each, nothing stored", foreign_send.status == 403 and
        has(foreign_send.body, "another origin") and cross_send.status == 403 and has(cross_send.body, "another site") and
        std.mem.eql(u8, try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024)), before_refusals));

    // 33. Opened as streams, so one wrongly held open ends at its watchdog
    // rather than hanging the run.
    var cross_stream = try Stream.openWith(a, io, port, channel_url ++ "/stream?after=0", "origin: http://evil.example\r\nsec-fetch-site: cross-site\r\nsec-fetch-mode: cors\r\nsec-fetch-dest: empty\r\n");
    defer cross_stream.close();
    var same_site_stream = try Stream.openWith(a, io, port, channel_url ++ "/stream?after=0", "sec-fetch-site: same-site\r\nsec-fetch-mode: no-cors\r\nsec-fetch-dest: script\r\n");
    defer same_site_stream.close();
    try t.check("open the channel's stream as another site's page would: 403 each", std.mem.startsWith(u8, cross_stream.head, "HTTP/1.1 403 ") and
        std.mem.startsWith(u8, same_site_stream.head, "HTTP/1.1 403 "));

    // 34.
    const own_stream_headers = try std.fmt.allocPrint(a, "origin: http://localhost:{d}\r\nsec-fetch-site: same-origin\r\nsec-fetch-mode: cors\r\nsec-fetch-dest: empty\r\n", .{port});
    var own_stream = try Stream.openWith(a, io, port, channel_url ++ "/stream?after=12", own_stream_headers);
    defer own_stream.close();
    try t.check("open it as this server's own page does: a 200 event stream no other site may load", own_stream.isEventStream() and
        std.mem.eql(u8, own_stream.header("cross-origin-resource-policy") orelse "", "same-origin"));

    // 35.
    const followed = try exchange(a, io, port, try std.fmt.allocPrint(a, "GET " ++ channel_url ++ " HTTP/1.1\r\nhost: localhost:{d}\r\n{s}" ++
        "sec-fetch-site: cross-site\r\nsec-fetch-mode: navigate\r\nsec-fetch-dest: document\r\nsec-fetch-user: ?1\r\n\r\n", .{ port, steve_session }));
    try t.check("follow a link to the channel's page from another site: 200, the page", followed.status == 200 and
        has(followed.body, "id=\"msg-12\""));

    // 35a.
    const public_host = public_origin["https://".len..];
    const public_page = try exchange(a, io, port, try std.fmt.allocPrint(a, "GET " ++ channel_url ++ " HTTP/1.1\r\nhost: {s}\r\n{s}\r\n", .{ public_host, steve_session }));
    const public_form = "markdown=Through+the+proxy";
    const public_post = try exchange(a, io, port, try std.fmt.allocPrint(a, "POST " ++ dm_url ++ " HTTP/1.1\r\nhost: {s}\r\n{s}origin: {s}\r\nsec-fetch-site: same-origin\r\ncontent-type: application/x-www-form-urlencoded\r\ncontent-length: {d}\r\n\r\n{s}", .{ public_host, steve_session, public_origin, public_form.len, public_form }));
    const local_origin = try exchange(a, io, port, try std.fmt.allocPrint(a, "POST " ++ dm_url ++ " HTTP/1.1\r\nhost: {s}\r\n{s}origin: http://localhost:{d}\r\ncontent-type: application/x-www-form-urlencoded\r\ncontent-length: {d}\r\n\r\n{s}", .{ public_host, steve_session, port, public_form.len, public_form }));
    const evil_origin = try exchange(a, io, port, try std.fmt.allocPrint(a, "POST " ++ dm_url ++ " HTTP/1.1\r\nhost: {s}\r\n{s}origin: https://evil.example\r\ncontent-type: application/x-www-form-urlencoded\r\ncontent-length: {d}\r\n\r\n{s}", .{ public_host, steve_session, public_form.len, public_form }));
    const dm_after_public = try get(a, io, port, dm_url);
    try t.check("through the public origin: the page, 200; a POST from its own page, 303; from the local origin's page or another site's, 403 each", public_page.status == 200 and
        has(public_page.body, "id=\"msg-12\"") and public_post.status == 303 and local_origin.status == 403 and evil_origin.status == 403 and
        std.mem.count(u8, dm_after_public.body, "Through the proxy") == 1);

    try editAndReactSteps(a, io, port, data, t, script_fetch);
    try downloadSteps(a, io, port, data, t);
    try agentSteps(a, io, port, data, t);
    const cc_bearer = try memberSteps(a, io, port, data, t);
    try inviteSteps(a, io, port, data, t, cc_bearer);
    try gitHubSteps(a, io, port, data, t, .{ .fake = fake, .cc_bearer = cc_bearer });
    try linkSteps(a, io, port, data, t, .{ .fake = fake, .cc_bearer = cc_bearer });
    try firstPageSteps(a, io, port, data, t, fake);

    // 48zv.
    const own_login = try get(a, io, port, "/login");
    try t.check("the sign-in page of someone signed in, on a server with GitHub: who they are, the Browse link and signing out; no form and no GitHub", own_login.status == 200 and
        has(own_login.body, "You are signed in as Steve.") and has(own_login.body, browse_link) and has(own_login.body, "action=\"/logout\"") and
        !has(own_login.body, "action=\"/login\"") and !has(own_login.body, "/login/github"));

    // 48zw.
    const back_in = try post(a, io, port, .{ .path = "/channels/crew/members/2/add", .form = "" });
    const key_browse = try getAs(a, io, port, cc_bearer, "/chat");
    const key_way_in = try getAs(a, io, port, cc_bearer, "/");
    const key_topic = try postAs(a, io, port, cc_bearer, "/chat/channel/crew", "topic=plans");
    try t.check("a key at Browse, and starting a topic in its own channel: 403 each, and / points a key at that same 403", back_in.status == 303 and key_browse.status == 403 and key_topic.status == 403 and
        key_way_in.status == 303 and std.mem.eql(u8, key_way_in.header("location") orelse "", "/chat") and
        has(key_browse.body, "by their own session") and has(key_topic.body, "by their own session"));

    try deviceCodeSteps(a, io, port, data, t, cc_bearer);
    try clientCapSteps(a, io, port, t);

    // 49.
    const signed_out = try post(a, io, port, .{ .path = "/logout", .form = "" });
    try t.check("sign out: a 303 to the sign-in page, the cookie cleared, never stored", signed_out.status == 303 and
        std.mem.eql(u8, signed_out.header("location") orelse "", "/login") and
        std.mem.eql(u8, signed_out.header("set-cookie") orelse "", "__Host-gopher_auth=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax") and
        std.mem.eql(u8, signed_out.header("cache-control") orelse "", "no-store"));

    try noGitHubSteps(a, io, gpa, t, data_name);
    try signUpCapSteps(a, io, gpa, t, .{ .data_name = data_name, .fake = fake });

    std.debug.print("end-to-end: every step passed, in {d} ms\n", .{began.untilNow(io, .awake).toMilliseconds()});
}

/// A POST with its head sent and its body held back. The `100 Continue` says
/// the server has read the head, so the request is counted when `open`
/// returns.
const HeldPost = struct {
    connection: Io.net.Stream,
    io: Io,

    fn open(a: std.mem.Allocator, io: Io, port: u16, more: []const u8) !HeldPost {
        const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
        const connection = try addr.connect(io, .{ .mode = .stream });
        errdefer connection.close(io);
        var w = connection.writer(io, &.{});
        try w.interface.writeAll(try std.fmt.allocPrint(a, "POST " ++ channel_url ++ " HTTP/1.1\r\nhost: localhost:{d}\r\n{s}{s}content-type: application/x-www-form-urlencoded\r\nexpect: 100-continue\r\ncontent-length: 10\r\n\r\n", .{ port, steve_session, more }));
        var buf: [256]u8 = undefined;
        var r = connection.reader(io, &buf);
        const line = try r.interface.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, line, "HTTP/1.1 100 ")) return error.NotContinued;
        return .{ .connection = connection, .io = io };
    }

    /// The body sent and the answer read to the close, whose status is
    /// whether it was a 303.
    fn finish(h: HeldPost, a: std.mem.Allocator) !bool {
        defer h.connection.close(h.io);
        var w = h.connection.writer(h.io, &.{});
        try w.interface.writeAll("markdown=x");
        var buf: [4096]u8 = undefined;
        var r = h.connection.reader(h.io, &buf);
        return has(try r.interface.allocRemaining(a, .limited(64 * 1024)), "HTTP/1.1 303 ");
    }
};

/// Step 48zx, at the server's own limit: a stream holder's 8 streams and
/// enough held requests to fill it.
/// Posting, editing and reacting, in a topic of their own, `edits_url`, as
/// the page's scripts do (`fetch` carries `fetch_headers`): each edit and
/// reaction kept on disk, drawn on the page, and sent live on the
/// conversation's stream as the message drawn again (`event: replace`).
fn editAndReactSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps, fetch_headers: []const u8) !void {
    const edits_url = "/chat/channel/general/edits";
    const transcript = "chat/channel/general/edits/transcript";
    const reactions = "chat/channel/general/edits/reactions";
    const thumbs = "%F0%9F%91%8D";
    var stream = try Stream.open(a, io, port, edits_url ++ "/stream?after=0");
    defer stream.close();

    // 35b.
    const first = try post(a, io, port, .{ .path = edits_url ++ "/send", .form = "markdown=Helo+there", .more = fetch_headers });
    const raw_first = try get(a, io, port, edits_url ++ "/raw?message=1");
    const raw_missing = try get(a, io, port, edits_url ++ "/raw?message=9");
    try t.check("post a message to a new topic: 201, its frame on the stream, then the topic told to Steve's sidebar, and its markdown alone at /raw?message=1; a message not there, 404", first.status == 201 and
        std.mem.startsWith(u8, try stream.event(), "id: 1\ndata: <article class=\"message\" id=\"msg-1\"") and
        std.mem.eql(u8, try stream.event(), "event: topic-added\ndata: /chat/channel/general\ndata: edits\ndata: " ++ edits_url ++ "\n\n") and
        raw_first.status == 200 and std.mem.eql(u8, raw_first.body, "Helo there") and raw_missing.status == 404);

    // 35c.
    const edited = try post(a, io, port, .{ .path = edits_url ++ "/send", .form = "markdown=Edit+of+MSG_edits_1%0A%0AHello+there", .more = fetch_headers });
    const edit_frame = try stream.event();
    const again = try stream.event();
    const edited_page = try get(a, io, port, edits_url);
    const kept = try data.readFileAlloc(io, transcript, a, .limited(1024 * 1024));
    try t.check("edit one's own message: 201; the edit's frame, then the original sent again as edited, with no id; the page shows it edited, its markdown kept; both records on disk", edited.status == 201 and
        std.mem.startsWith(u8, edit_frame, "id: 2\n") and
        std.mem.startsWith(u8, again, "event: replace\ndata: <article class=\"message\" id=\"msg-1\"") and !has(again, "\nid: ") and
        has(again, "Edited in <a class=\"message-reference\" href=\"#msg-2\">MSG_edits_2</a>") and
        std.mem.eql(u8, again["event: replace\n".len..], (try frameOf(a, edited_page.body, "1"))["id: 1\n".len..]) and
        has(edited_page.body, "<div class=\"edited-markdown\">Helo there</div>") and
        has(kept, "\n\nHelo there\n\n") and has(kept, "\n\nEdit of MSG_edits_1\n\nHello there\n\n"));
    const actions_script = try get(a, io, port, "/chat/assets/actions.js");
    try t.check("the edit's reference is a link whose label is the original's header reference, which the page's actions.js follows by its label", has(try articleOf(edited_page.body, "2"), "<p>Edit of <a href=\"#msg-edits_1\" class=\"msg-ref\">MSG_edits_1</a></p>") and
        has(try articleOf(edited_page.body, "1"), "<a class=\"message-reference\" href=\"#msg-1\">MSG_edits_1</a></header>") and
        actions_script.status == 200 and has(actions_script.body, "'a.msg-ref'") and has(actions_script.body, "'.message header .message-reference'"));

    // 35d.
    const not_there = try post(a, io, port, .{ .path = edits_url ++ "/send", .form = "markdown=Edit+of+MSG_edits_9%0A%0Ax", .more = fetch_headers });
    const before_theirs = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    const theirs = try post(a, io, port, .{ .path = channel_url ++ "/send", .form = "markdown=Edit+of+MSG_roc-chat_2%0A%0Ahijacked", .more = fetch_headers });
    try t.check("edit a message not there, or another author's: 409 each, in words, nothing stored", not_there.status == 409 and
        std.mem.eql(u8, not_there.body, "The edit names a message this conversation doesn't hold.\n") and
        theirs.status == 409 and std.mem.eql(u8, theirs.body, "Only a message's author may edit it.\n") and
        std.mem.eql(u8, try data.readFileAlloc(io, transcript, a, .limited(1024 * 1024)), kept) and
        std.mem.eql(u8, try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024)), before_theirs));

    // 35e.
    const reacted = try post(a, io, port, .{ .path = edits_url ++ "/react", .form = "msg=2&emoji=" ++ thumbs ++ "&on=1", .more = fetch_headers });
    const reacted_event = try stream.event();
    const reacted_page = try get(a, io, port, edits_url);
    try t.check("react: 200; the reaction its file's one line; the message sent again with its reaction, as the page now draws it", reacted.status == 200 and
        std.mem.eql(u8, try data.readFileAlloc(io, reactions, a, .limited(1024)), "{\"msg\":2,\"uid\":1,\"emoji\":\"👍\"}\n") and
        std.mem.startsWith(u8, reacted_event, "event: replace\ndata: <article class=\"message\" id=\"msg-2\"") and
        has(reacted_event, "<button class=\"reaction-chip\" data-reactors=\"1\"><span class=\"reaction-emoji\">👍</span> 1</button>") and
        std.mem.eql(u8, reacted_event["event: replace\n".len..], (try frameOf(a, reacted_page.body, "2"))["id: 2\n".len..]));

    // 35f.
    const twice = try post(a, io, port, .{ .path = edits_url ++ "/react", .form = "msg=2&emoji=" ++ thumbs ++ "&on=1", .more = fetch_headers });
    _ = try stream.event();
    const twice_file = try data.readFileAlloc(io, reactions, a, .limited(1024));
    const off = try post(a, io, port, .{ .path = edits_url ++ "/react", .form = "msg=2&emoji=" ++ thumbs ++ "&on=0", .more = fetch_headers });
    const off_event = try stream.event();
    try t.check("the same reaction again is still one; taking it back empties the file, and the message is sent again with no reactions", twice.status == 200 and
        std.mem.eql(u8, twice_file, "{\"msg\":2,\"uid\":1,\"emoji\":\"👍\"}\n") and off.status == 200 and
        std.mem.eql(u8, try data.readFileAlloc(io, reactions, a, .limited(1024)), "") and
        std.mem.startsWith(u8, off_event, "event: replace\ndata: <article class=\"message\" id=\"msg-2\"") and !has(off_event, "reaction-chip"));

    // 35g.
    const no_message = try post(a, io, port, .{ .path = edits_url ++ "/react", .form = "msg=9&emoji=" ++ thumbs ++ "&on=1", .more = fetch_headers });
    const no_emoji = try post(a, io, port, .{ .path = edits_url ++ "/react", .form = "msg=2&emoji=%2B1&on=1", .more = fetch_headers });
    const no_on = try post(a, io, port, .{ .path = edits_url ++ "/react", .form = "msg=2&emoji=" ++ thumbs, .more = fetch_headers });
    const got = try get(a, io, port, edits_url ++ "/react");
    const foreign = try post(a, io, port, .{ .path = edits_url ++ "/react", .form = "msg=2&emoji=" ++ thumbs ++ "&on=1", .more = "origin: http://evil.example\r\n" });
    const anonymous = try anonymousPost(a, io, port, edits_url ++ "/react", "msg=2&emoji=" ++ thumbs ++ "&on=1");
    try t.check("a reaction to no message, of no emoji, or with no `on`: 409, 400, 400, in words; a GET, 405; from another origin, 403; from no one, 401; the file untouched", no_message.status == 409 and
        std.mem.eql(u8, no_message.body, "The conversation holds no such message.\n") and
        no_emoji.status == 400 and std.mem.eql(u8, no_emoji.body, "The form's `emoji` is no emoji.\n") and
        no_on.status == 400 and std.mem.eql(u8, no_on.body, "The form has no field `on`.\n") and
        got.status == 405 and foreign.status == 403 and anonymous.status == 401 and
        std.mem.eql(u8, try data.readFileAlloc(io, reactions, a, .limited(1024)), ""));

    // 35h.
    const back_on = try post(a, io, port, .{ .path = edits_url ++ "/react", .form = "msg=2&emoji=" ++ thumbs ++ "&on=1", .more = fetch_headers });
    var reconnected = try Stream.open(a, io, port, edits_url ++ "/stream?after=2");
    defer reconnected.close();
    const first_again = try reconnected.event();
    const second_again = try reconnected.event();
    try t.check("a reader who reconnects having seen both: each message with an edit or a reaction sent again, as it is now, before anything new", back_on.status == 200 and
        std.mem.startsWith(u8, first_again, "event: replace\ndata: <article class=\"message\" id=\"msg-1\"") and has(first_again, "edited-note") and
        std.mem.startsWith(u8, second_again, "event: replace\ndata: <article class=\"message\" id=\"msg-2\"") and has(second_again, "reaction-chip"));
}

fn clientCapSteps(a: std.mem.Allocator, io: Io, port: u16, t: Steps) !void {
    const client = "x-forwarded-for: 203.0.113.7\r\n";
    const stream_path = channel_url ++ "/stream?after=0";
    var streams: [8]*Stream = undefined;
    for (&streams) |*s| s.* = try Stream.openWith(a, io, port, stream_path, client);
    defer for (streams[1..]) |s| s.close();
    var held: [(http.Limits{}).requests_per_client_most - streams.len]HeldPost = undefined;
    for (&held) |*h| h.* = try HeldPost.open(a, io, port, client);
    defer for (held[2..]) |h| h.connection.close(io);
    var all_streams = true;
    for (streams) |s| all_streams = all_streams and s.isEventStream();
    const past = try getWith(a, io, port, channel_url, client);
    const other = try getWith(a, io, port, channel_url, "x-forwarded-for: 203.0.113.8\r\n");
    const uncounted = try getWith(a, io, port, channel_url, "");
    try t.check("a client at its limit, its streams and held requests each admitted; one more: 429, saying so; another client and no such header: 200", all_streams and
        past.status == 429 and std.mem.eql(u8, past.body, "too many requests at once; try again\n") and other.status == 200 and uncounted.status == 200);

    const answered = try held[0].finish(a);
    const served = try getWith(a, io, port, channel_url, client);
    const refilled = try HeldPost.open(a, io, port, client);
    defer refilled.connection.close(io);
    const past_again = try getWith(a, io, port, channel_url, client);
    try t.check("a held request answered gives its count back: the client served, then at its limit again, and one more a 429", answered and served.status == 200 and past_again.status == 429);

    const room = try held[1].finish(a);
    const newest = try Stream.openWith(a, io, port, stream_path, client);
    defer newest.close();
    // The oldest stream's task ends after this one is answered.
    var got: u16 = 429;
    for (0..200) |_| {
        got = (try getWith(a, io, port, channel_url, client)).status;
        if (got != 429) break;
        try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io);
    }
    streams[0].close();
    try t.check("a stream ended for a newer one of its holder gives its count back: the client at one under its limit is served", room and newest.isEventStream() and got == 200);
}

/// Steps 57d to 57f: the abuse limits, a new account's uploads
/// (app/NewAccountUploads.roc), the message rate (app/MessageRate.roc) and
/// the disk floor (app/DiskFloor.roc), whose free space the run sets through
/// `free_bytes`, the data root's `free_bytes_for_test`.
fn limitSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps, free_bytes: *std.atomic.Value(u64)) !void {
    const own_page = try std.fmt.allocPrint(a, "origin: http://localhost:{d}\r\nsec-fetch-site: same-origin\r\n", .{port});
    const png = try onePixelPng(a);

    // 57d.
    const rita_id = try nextId(a, io, data);
    const joined_path = try std.fmt.allocPrint(a, "auth/{d}/joined", .{rita_id});
    const joining = files.current_utc_seconds_since_epoch(io);
    const first_session = try joinedHuman(a, io, port, steve_session, "Rita");
    const joined_at = try std.fmt.parseInt(i64, try readFile(a, io, data, joined_path), 10);
    const joined_by = files.current_utc_seconds_since_epoch(io);
    // Invited again and joined again: the first join is kept.
    const again = try postAs(a, io, port, steve_session, try std.fmt.allocPrint(a, "/invites/{d}/again", .{rita_id}), "");
    const again_link = between(again.body, "<p class=\"invite-code\">", "</p>") orelse return error.NoLink;
    const again_code = again_link[(std.mem.indexOfScalar(u8, again_link, '#') orelse return error.NoCode) + 1 ..];
    try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(1100) }, io);
    const rejoined = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Rita&password=their+new+own", .{again_code}));
    try t.check("Rita's join writes `joined`, the second she joined, its digits; invited again and joined again, it is kept", joined_at >= joining and joined_at <= joined_by and
        first_session.len > 0 and rejoined.status == 303 and std.mem.eql(u8, try readFile(a, io, data, joined_path), try std.fmt.allocPrint(a, "{d}", .{joined_at})));
    // Her new password ended the first session; the join's own signs her in.
    const rita = try cookieLine(a, rejoined);
    const rita_total = try std.fmt.allocPrint(a, "users/{d}/upload-bytes", .{rita_id});
    const new_most = 100 * 1024 * 1024;
    try data.createDirPath(io, std.fs.path.dirname(rita_total).?);
    try data.writeFile(io, .{ .sub_path = rita_total, .data = try std.fmt.allocPrint(a, "{d}", .{new_most - png.len}) });
    const at_most = try uploadAs(a, io, port, try std.fmt.allocPrint(a, "{s}{s}", .{ rita, own_page }), png);
    const at_most_total = try readFile(a, io, data, rita_total);
    const uploads_before = (try namesIn(a, io, data, channel_uploads)).len;
    const past = try uploadAs(a, io, port, try std.fmt.allocPrint(a, "{s}{s}", .{ rita, own_page }), png);
    try t.check("a new account, Rita, just joined: an upload landing on 100 MiB, 200; one more, 403, saying a new account's limit, nothing stored or counted", rita.len > 0 and
        at_most.status == 200 and std.mem.eql(u8, at_most_total, try std.fmt.allocPrint(a, "{d}", .{new_most})) and
        past.status == 403 and std.mem.eql(u8, past.body, "Upload limit reached — a new account may upload 100 MiB in its first 2 days.\n") and
        std.mem.eql(u8, try readFile(a, io, data, rita_total), at_most_total) and uploads_before == 1 and (try namesIn(a, io, data, channel_uploads)).len == 1);

    // 57e.
    const rate_send = "/chat/channel/general/rate/send";
    const rate_transcript = "chat/channel/general/rate/transcript";
    var sent_all = true;
    for (0..30) |n| {
        const sent = try postAs(a, io, port, try std.fmt.allocPrint(a, "{s}{s}", .{ rita, own_page }), rate_send, try std.fmt.allocPrint(a, "markdown=number+{d}", .{n + 1}));
        sent_all = sent_all and sent.status == 201;
    }
    const thirty_first = try postAs(a, io, port, try std.fmt.allocPrint(a, "{s}{s}", .{ rita, own_page }), rate_send, "markdown=one+too+many");
    const rate_file = try readFile(a, io, data, rate_transcript);
    try t.check("Rita sends 30 messages in a minute: 201 each; the 31st a 429, saying so; the transcript exactly the 30", sent_all and
        thirty_first.status == 429 and std.mem.eql(u8, thirty_first.body, "Too many messages: at most 30 a minute. Wait a moment, then send it again.\n") and
        std.mem.count(u8, rate_file, "\nMSG_rate_") == 30 and has(rate_file, "number 30") and !has(rate_file, "one too many"));

    // 57f.
    const floor = 2 * 1024 * 1024 * 1024;
    free_bytes.store(floor - 1, .release);
    const channel_file = channel_url["/".len..] ++ "/transcript";
    const before = try readFile(a, io, data, channel_file);
    const ids_before = try nextId(a, io, data);
    const low_post = try post(a, io, port, .{ .path = channel_url, .form = "markdown=Is+there+room%3F" });
    const low_upload = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "cat.png", png), .more = own_page });
    const low_invite = try post(a, io, port, .{ .path = "/invites", .form = "name=Lowell" });
    const low_page = try get(a, io, port, channel_url);
    const low_words = "The server is low on disk space, so nothing new can be saved for now. Reading still works; please try again later.\n";
    const nothing_written = std.mem.eql(u8, try readFile(a, io, data, channel_file), before) and
        (try namesIn(a, io, data, channel_uploads)).len == 1 and (try nextId(a, io, data)) == ids_before;
    free_bytes.store(floor, .release);
    const at_floor = try post(a, io, port, .{ .path = channel_url, .form = "markdown=Room+at+the+floor" });
    free_bytes.store(std.math.maxInt(u64), .release);
    try t.check("a byte under 2 GiB free: a message, an upload and an invite, 507 each, saying the server is low on disk, nothing written; the page still 200; at 2 GiB exactly, a message, 303", low_post.status == 507 and
        std.mem.eql(u8, low_post.body, low_words) and low_upload.status == 507 and low_invite.status == 507 and
        low_page.status == 200 and nothing_written and at_floor.status == 303 and
        has(try readFile(a, io, data, channel_file), "Room at the floor"));

    // 57g.
    // Tam, who has a password, with no `joined` as an account from before
    // the file: invited again and joined again, she is given none.
    try data.deleteFile(io, "auth/2/joined");
    const tam_again = try postAs(a, io, port, steve_session, "/invites/2/again", "");
    const tam_link = between(tam_again.body, "<p class=\"invite-code\">", "</p>") orelse return error.NoLink;
    const tam_code = tam_link[(std.mem.indexOfScalar(u8, tam_link, '#') orelse return error.NoCode) + 1 ..];
    const tam_rejoined = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Tam&password=a+new+one", .{tam_code}));
    // Sam's first join, after a crash left his `joined` empty: it is mended.
    const sam_id = try nextId(a, io, data);
    const sam_invited = try postAs(a, io, port, steve_session, "/invites", "name=Sam");
    const sam_link = between(sam_invited.body, "<p class=\"invite-code\">", "</p>") orelse return error.NoLink;
    const sam_code = sam_link[(std.mem.indexOfScalar(u8, sam_link, '#') orelse return error.NoCode) + 1 ..];
    const sam_joined_path = try std.fmt.allocPrint(a, "auth/{d}/joined", .{sam_id});
    try data.writeFile(io, .{ .sub_path = sam_joined_path, .data = "" });
    const sam_joined = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Sam&password=his+own", .{sam_code}));
    try t.check("a join by a human with a password writes no `joined`; a first join mends an empty one", tam_rejoined.status == 303 and
        !(try exists(io, data, "auth/2/joined")) and sam_joined.status == 303 and
        (try std.fmt.parseInt(i64, try readFile(a, io, data, sam_joined_path), 10)) > 0);
}

/// The compose box's upload of `png` to the seeded channel, with the
/// `Cookie` and page lines `headers`.
fn uploadAs(a: std.mem.Allocator, io: Io, port: u16, headers: []const u8, png: []const u8) !Response {
    const form = try uploadForm(a, "cat.png", png);
    return exchange(a, io, port, try std.fmt.allocPrint(a, "POST " ++ channel_url ++ "/upload HTTP/1.1\r\nhost: localhost:{d}\r\n{s}content-type: " ++ upload_type ++ "\r\ncontent-length: {d}\r\n\r\n{s}", .{ port, headers, form.len, form }));
}

/// Steps 48zy and 48zz: a device code made by Steve and redeemed by his
/// phone, and each way one is refused.
fn deviceCodeSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps, cc_bearer: []const u8) !void {
    const none_yet = try getAt(a, io, port, "/devices");
    try t.check("a device code: Steve's page says first to open the sign-in page on his phone, offers to make a code, never stored", none_yet.status == 200 and
        has(none_yet.body, "<li>On your phone, open this page:<p class=\"invite-code\">http://") and has(none_yet.body, "<form method=\"post\" action=\"/devices\"><button>Make a code</button></form>") and
        std.mem.eql(u8, none_yet.header("cache-control") orelse "", "no-store"));

    const first = try makeCode(a, io, port, steve_session);
    const first_code = first.code;
    const record = try readFile(a, io, data, "users/1/device-code");
    const flash = first.made.header("set-cookie") orelse "";
    try t.check("a code made: a 303 to the page, with a cookie for this host alone, for the browser's session, sent to no script and on no other site's request", first.made.status == 303 and
        std.mem.eql(u8, first.made.header("location") orelse "", "/devices") and std.mem.startsWith(u8, flash, "__Host-device_code=") and
        std.mem.endsWith(u8, flash, "; Path=/; HttpOnly; Secure; SameSite=Strict") and
        std.mem.eql(u8, first.made.header("cache-control") orelse "", "no-store"));
    try t.check("the page then shows it once, two groups of four digits, with its expiry, the warning and a button that cancels it; never stored; the cookie forgotten; its record holds its HMAC, not the code", first.page.status == 200 and
        isDeviceCode(first.shown) and has(first.page.body, "Type this only into your own device. Nobody will ever ask you for it.") and
        has(first.page.body, "<time class=\"code-expiry\" datetime=\"") and
        has(first.page.body, "<form method=\"post\" action=\"/devices/cancel\"><button>Cancel this code</button></form>") and
        has(first.page.body, "<p class=\"code-status\" data-stream=\"/devices/stream\">") and
        has(first.page.body, "<script src=\"/chat/assets/devices.js\"></script>") and
        std.mem.eql(u8, first.page.header("cache-control") orelse "", "no-store") and
        std.mem.eql(u8, first.page.header("set-cookie") orelse "", "__Host-device_code=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict") and
        std.mem.startsWith(u8, record, "live ") and !has(record, first_code) and !has(record, first_code[0..4]) and !has(record, first_code[4..]));
    const reloaded = try getAt(a, io, port, "/devices");
    try t.check("a reload of the page shows no code and makes none: it says one is waiting, with the button that cancels it", reloaded.status == 200 and
        !has(reloaded.body, "sign-in-code") and has(reloaded.body, "A code is waiting to be used, until ") and
        has(reloaded.body, "It is shown only once; make a new code to see one.") and
        has(reloaded.body, "action=\"/devices/cancel\"") and std.mem.eql(u8, try readFile(a, io, data, "users/1/device-code"), record));

    const second = try makeCode(a, io, port, steve_session);
    const second_code = second.code;
    const phone = "x-forwarded-for: 192.0.2.10\r\n";
    const replaced = try redeemFrom(a, io, port, phone, try std.fmt.allocPrint(a, "code={s}", .{first_code}));
    try t.check("a second code cancels the first: its redemption from a phone, a 401 saying only that it didn't work, no cookie, never stored", second.made.status == 303 and
        isDeviceCode(second.shown) and !std.mem.eql(u8, first_code, second_code) and isCodeRefusal(replaced));

    try data.writeFile(io, .{ .sub_path = "users/3/device-code", .data = "not a record\n" });
    defer data.deleteFile(io, "users/3/device-code") catch {};
    var steves_stream = try Stream.openWith(a, io, port, channel_url ++ "/stream?after=0", "");
    defer steves_stream.close();
    var devices_stream = try Stream.openWith(a, io, port, "/devices/stream", "");
    defer devices_stream.close();
    const signed_in = try redeemFrom(a, io, port, phone, try std.fmt.allocPrint(a, "code={s}-{s}", .{ second_code[0..4], second_code[4..] }));
    const phone_session = try cookieLine(a, signed_in);
    const phone_browse = try getAs(a, io, port, phone_session, "/chat");
    var heard = false;
    for (0..400) |_| {
        const event = try steves_stream.event();
        if (std.mem.startsWith(u8, event, "event: notice\n")) {
            heard = std.mem.eql(u8, event, "event: notice\ndata: <a href=\"/devices#sign-out-others\">A new device signed in as you, with a code you made. Not you? Sign your other devices out.</a>\n\n");
            break;
        }
    }
    const phone_key = deviceKeyOf(signed_in) orelse "(none)";
    const phone_key_state = try std.fmt.allocPrint(a, "auth/1/device-keys/{s}/state", .{phone_key});
    const phone_key_created = try std.fmt.allocPrint(a, "auth/1/device-keys/{s}/created", .{phone_key});
    try t.check("the second code, typed with a dash: a 303 to Browse with a session's cookie, marked as a code's and bound to a new device key, active, which reads Browse as Steve; his open stream hears that a new device signed in", signed_in.status == 303 and
        std.mem.eql(u8, signed_in.header("location") orelse "", "/chat") and
        std.mem.startsWith(u8, signed_in.header("set-cookie") orelse "", "__Host-gopher_auth=") and
        has(signed_in.header("set-cookie") orelse "", "; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax") and
        std.mem.eql(u8, try readFile(a, io, data, phone_key_state), "active") and
        std.mem.startsWith(u8, try readFile(a, io, data, phone_key_created), "17") and
        std.mem.eql(u8, signed_in.header("cache-control") orelse "", "no-store") and
        phone_browse.status == 200 and has(phone_browse.body, "<span class=\"viewer\">Steve</span>") and heard);
    const used_event = try devices_stream.expectEvent("event: device-used\n", &.{"event: notice\n"});
    try t.check("the device code page's own stream hears that the code was used, and when", devices_stream.isEventStream() and
        std.mem.startsWith(u8, used_event, "event: device-used\ndata: 20") and std.mem.endsWith(u8, used_event, "Z\n\n"));

    const again = try redeemFrom(a, io, port, phone, try std.fmt.allocPrint(a, "code={s}", .{second_code}));
    try t.check("with another human's record damaged, logged and taken as none, Steve's code signed the phone in all the same", signed_in.status == 303);
    const used = try getAt(a, io, port, "/devices");
    try t.check("a code works once: again, the same refusal; Steve's page lists the sign-in", isCodeRefusal(again) and
        std.mem.eql(u8, again.body, replaced.body) and has(used.body, "<li><time datetime=\"20"));

    const third = try makeCode(a, io, port, steve_session);
    const third_code = third.code;
    const live = try readFile(a, io, data, "users/1/device-code");
    var words = std.mem.splitScalar(u8, live, ' ');
    _ = words.next();
    _ = words.next();
    _ = words.next();
    const hmacs = words.rest();
    try data.writeFile(io, .{ .sub_path = "users/1/device-code", .data = try std.fmt.allocPrint(a, "live 1000 1300 {s}", .{hmacs}) });
    const expired = try redeemFrom(a, io, port, phone, try std.fmt.allocPrint(a, "code={s}", .{third_code}));
    const expired_page = try getAt(a, io, port, "/devices");
    try t.check("an expired code: the same refusal, and Steve's page says it expired unused", isDeviceCode(third.shown) and
        std.mem.eql(u8, expired.body, replaced.body) and isCodeRefusal(expired) and has(expired_page.body, "Your last code expired unused."));

    const fourth = try makeCode(a, io, port, steve_session);
    const fourth_code = fourth.code;
    const phone_page = try getAs(a, io, port, phone_session, "/chat");
    try t.check("a phone signed in by a code has \"Sign out\" in its top bar, a POST of /logout", phone_page.status == 200 and
        has(phone_page.body, "<form class=\"sign-out\" method=\"post\" action=\"/logout\"><button>Sign out</button></form></div></header>"));

    // Step 48zy: the phone signs out, which revokes its device key.
    const asked = try postAs(a, io, port, phone_session, "/logout", "next=%2Fchat%2Fdm%2F1_2%2Fplans");
    const after_ask = try getAs(a, io, port, phone_session, "/chat");
    try t.check("the phone's \"Sign out\" asks first: a 200 saying it removes this device's key, its button posting confirmed=yes, Cancel back to the page it was on; no cookie changed, the key active, the phone still signed in", asked.status == 200 and
        has(asked.body, "Signing out removes this device&#39;s key. To sign in on this device again, you&#39;ll make a new code on a signed-in computer.") and
        has(asked.body, "<input type=\"hidden\" name=\"confirmed\" value=\"yes\">") and
        has(asked.body, "<a href=\"/chat/dm/1_2/plans\">Cancel</a>") and asked.header("set-cookie") == null and
        std.mem.eql(u8, asked.header("cache-control") orelse "", "no-store") and
        std.mem.eql(u8, try readFile(a, io, data, phone_key_state), "active") and after_ask.status == 200);
    const forged_out = try postAs(a, io, port, try std.fmt.allocPrint(a, "{s}sec-fetch-site: cross-site\r\n", .{phone_session}), "/logout", "confirmed=yes");
    try t.check("a sign-out another site's page posts, confirmed: a 403, the key still active, the phone still signed in", forged_out.status == 403 and
        std.mem.eql(u8, try readFile(a, io, data, phone_key_state), "active") and (try getAs(a, io, port, phone_session, "/chat")).status == 200);
    // The phone's own open stream, opened by its session in place of Steve's.
    const steves = steve_session;
    steve_session = phone_session;
    var phone_stream = try Stream.openWith(a, io, port, "/devices/stream", "");
    defer phone_stream.close();
    steve_session = steves;
    const signing_out = Io.Clock.now(.awake, io);
    const phone_out = try postAs(a, io, port, phone_session, "/logout", "confirmed=yes&next=%2Fchat");
    const phone_stream_ended = if (phone_stream.event()) |_| false else |e| e == error.EndOfStream;
    const ended_ms = signing_out.untilNow(io, .awake).toMilliseconds();
    try t.check("the phone's stream, open as it signs out, is ended at once, as an open stream checks no key again", phone_stream.isEventStream() and
        phone_stream_ended and ended_ms < Stream.wait_ms / 2);
    const after_out = try getAs(a, io, port, phone_session, "/chat");
    try t.check("confirmed: the key's state revoked, then a 303 to sign in, the session's cookie and the one that shows a code forgotten; the old cookie, sent again, is refused (a 303 to sign in)", phone_out.status == 303 and
        std.mem.eql(u8, phone_out.header("location") orelse "", "/login") and
        has(phone_out.head, "\r\nset-cookie: __Host-gopher_auth=; Path=/; Max-Age=0; ") and
        has(phone_out.head, "\r\nset-cookie: __Host-device_code=; Path=/; Max-Age=0; ") and
        std.mem.eql(u8, try readFile(a, io, data, phone_key_state), "revoked") and
        after_out.status == 303 and std.mem.startsWith(u8, after_out.header("location") orelse "", "/login"));
    const after_sign_out = try redeemFrom(a, io, port, phone, try std.fmt.allocPrint(a, "code={s}", .{fourth_code}));
    try t.check("a code Steve makes, then his phone signs out: the code is cancelled, its redemption the same refusal", isDeviceCode(fourth.shown) and
        std.mem.startsWith(u8, try readFile(a, io, data, "users/1/device-code"), "cancelled ") and
        std.mem.eql(u8, after_sign_out.body, replaced.body) and isCodeRefusal(after_sign_out));
    try data.writeFile(io, .{ .sub_path = phone_key_state, .data = "active" });
    const revived = try getAs(a, io, port, phone_session, "/chat");
    try data.writeFile(io, .{ .sub_path = phone_key_state, .data = "lots\n" });
    const damaged = try getAs(a, io, port, phone_session, "/chat");
    try data.deleteFile(io, phone_key_state);
    const missing = try getAs(a, io, port, phone_session, "/chat");
    try data.writeFile(io, .{ .sub_path = phone_key_state, .data = "revoked" });
    try t.check("it is the key's state alone that decides: written active by hand, the old cookie reads Browse again; a state that is no state, or none, refuses it", revived.status == 200 and
        damaged.status == 303 and missing.status == 303);

    // A code whose material has changed since it was made: its record's
    // material HMAC rewritten, as a new password or a GitHub link would
    // leave it.
    const sixth = try makeCode(a, io, port, steve_session);
    const sixth_code = sixth.code;
    const kept = try readFile(a, io, data, "users/1/device-code");
    const zero_hmac: [64]u8 = @splat('0');
    const other_material = try std.fmt.allocPrint(a, "{s}{s}\n", .{ kept[0 .. kept.len - 65], &zero_hmac });
    try data.writeFile(io, .{ .sub_path = "users/1/device-code", .data = other_material });
    const changed = try redeemFrom(a, io, port, "x-forwarded-for: 192.0.2.20\r\n", try std.fmt.allocPrint(a, "code={s}", .{sixth_code}));
    try t.check("a code whose human's material changed since it was made: the same refusal, the record still live", isDeviceCode(sixth.shown) and
        isCodeRefusal(changed) and std.mem.eql(u8, changed.body, replaced.body) and
        std.mem.startsWith(u8, try readFile(a, io, data, "users/1/device-code"), "live "));

    const seventh = try makeCode(a, io, port, steve_session);
    const cancelled = try post(a, io, port, .{ .path = "/devices/cancel", .form = "" });
    const after_cancel = try redeemFrom(a, io, port, "x-forwarded-for: 192.0.2.21\r\n", try std.fmt.allocPrint(a, "code={s}", .{seventh.code}));
    try t.check("\"Cancel this code\": a 303 to the page, the record cancelled, the cookie forgotten; the code then the same refusal", cancelled.status == 303 and
        std.mem.eql(u8, cancelled.header("location") orelse "", "/devices") and
        std.mem.startsWith(u8, try readFile(a, io, data, "users/1/device-code"), "cancelled ") and
        std.mem.startsWith(u8, cancelled.header("set-cookie") orelse "", "__Host-device_code=; ") and isCodeRefusal(after_cancel));

    const by_key_make = try postAs(a, io, port, cc_bearer, "/devices", "");
    const by_key_redeem = try postAs(a, io, port, cc_bearer, "/login/code", "code=2222-2222");
    const by_no_one = try anonymousPost(a, io, port, "/devices", "");
    try t.check("a key may not make a code, nor redeem one: 403 each; no one may make one: 401", by_key_make.status == 403 and
        has(by_key_make.body, "Only a human signed in on this device makes a device code.") and by_key_redeem.status == 403 and by_no_one.status == 401);

    // 48zz.
    const fifth = try makeCode(a, io, port, steve_session);
    const fifth_code = fifth.code;
    const guesser = "x-forwarded-for: 198.51.100.7\r\n";
    var all_refused = true;
    for (0..10) |_| all_refused = all_refused and isCodeRefusal(try redeemFrom(a, io, port, guesser, "code=2222-2222"));
    const locked = try redeemFrom(a, io, port, guesser, try std.fmt.allocPrint(a, "code={s}", .{fifth_code}));
    const neighbour = try redeemFrom(a, io, port, "x-forwarded-for: 198.51.100.8\r\n", "code=2222-2222");
    try t.check("a client's 10 failed codes lock the form for it: a 429 saying so, even for a right code; another client's code is still tried", all_refused and
        locked.status == 429 and has(locked.body, "Too many codes have been tried. Wait 15 minutes") and
        isCodeRefusal(neighbour));

    // An entry of no code's shape says what a code looks like, and counts no
    // guess: six of them, then a wrong code, still a 401 and not a 429.
    const typist = "x-forwarded-for: 198.51.100.30\r\n";
    var all_malformed = true;
    for ([_][]const u8{ "code=ABC", "code=ABCD-EFG0", "code=", "code=ABCD-EFGHJ", "next=%2Fchat", "code=ab%20cd%20ef%20gL" }) |form| {
        const answer = try redeemFrom(a, io, port, typist, form);
        all_malformed = all_malformed and answer.status == 400 and has(answer.body, "A code is 8 digits, like 1234 5678.") and
            answer.header("set-cookie") == null;
    }
    const after_typos = try redeemFrom(a, io, port, typist, "code=2222-2222");
    try t.check("an entry of no code's shape: a 400 saying what a code looks like, counted as no guess, so a wrong code after six is still a 401", all_malformed and isCodeRefusal(after_typos));

    // An IPv6 client is its /64: another address of the same network shares
    // its lock, and the next network is a client of its own.
    const network = "x-forwarded-for: 2001:db8:1:2::5\r\n";
    var network_refused = true;
    for (0..10) |_| network_refused = network_refused and isCodeRefusal(try redeemFrom(a, io, port, network, "code=2222-2222"));
    const same_network = try redeemFrom(a, io, port, "x-forwarded-for: 2001:DB8:1:2:ffff::9\r\n", "code=2222-2222");
    const next_network = try redeemFrom(a, io, port, "x-forwarded-for: 2001:db8:1:3::5\r\n", "code=2222-2222");
    try t.check("an IPv6 client is its /64: 10 failures lock the form for another address of that network, a 429, and not for the next network's", network_refused and
        same_network.status == 429 and isCodeRefusal(next_network));

    try deviceSessionSteps(a, io, port, data, t);
}

/// Step 48zz2: a session a code started, marked and limited; the list of
/// sign-ins by code; and "Sign out other devices".
fn deviceSessionSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps) !void {
    const ipad = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
    const tablet = "x-forwarded-for: 192.0.2.40\r\nuser-agent: " ++ ipad ++ "\r\n";
    const code = try makeCode(a, io, port, steve_session);
    const signed_in = try redeemFrom(a, io, port, tablet, try std.fmt.allocPrint(a, "code={s}", .{code.code}));
    const cookie = signed_in.header("set-cookie") orelse "";
    const tablet_session = try cookieLine(a, signed_in);
    const browse = try getAs(a, io, port, tablet_session, "/chat");
    const devices = try getAt(a, io, port, "/devices");
    try t.check("a session a code started is marked in its cookie, reads Browse as any does, and Steve's page lists the sign-in, when and from what, not the whole User-Agent", signed_in.status == 303 and
        std.mem.startsWith(u8, cookie, "__Host-gopher_auth=") and deviceKeyOf(signed_in) != null and browse.status == 200 and
        has(devices.body, ": Safari on iOS</li>") and !has(devices.body, "Mobile/15E148") and
        has(try readFile(a, io, data, "users/1/device-sign-ins"), " safari ios\n"));

    const refusal = "This device signed in with a code from another device. To invite people, manage channels or agents, link GitHub, make device codes or sign other devices out, sign out here, then sign in with your password or GitHub.";
    const make_agent = try postAs(a, io, port, tablet_session, "/agents", "name=Tablet");
    const link = try postAs(a, io, port, tablet_session, "/login/github/link", "");
    const start = try getAs(a, io, port, tablet_session, "/login/github/start?next=/chat");
    const invite_agent = try postAs(a, io, port, tablet_session, "/agents/2/invites", "read=everywhere&post=everywhere");
    const agents_page = try getAs(a, io, port, tablet_session, "/agents");
    const tablet_devices = try getAs(a, io, port, tablet_session, "/devices");
    try t.check("its /agents and /devices pages show no button it couldn't use, and a line saying why", !has(agents_page.body, "<button>Make an agent</button>") and
        has(agents_page.body, "so it can&#39;t manage agents or link GitHub") and !has(tablet_devices.body, "action=\"/devices\"") and
        !has(tablet_devices.body, "action=\"/devices/sign-out-others\"") and has(tablet_devices.body, "so it can&#39;t make codes or sign other devices out"));
    const invite_human = try postAs(a, io, port, tablet_session, "/invites", "name=Tablet+Friend");
    const invite_again = try postAs(a, io, port, tablet_session, "/invites/3/again", "");
    const tablet_code = try postAs(a, io, port, tablet_session, "/devices", "");
    const tablet_cancel = try postAs(a, io, port, tablet_session, "/devices/cancel", "");
    const tablet_sign_out_others = try postAs(a, io, port, tablet_session, "/devices/sign-out-others", "");
    const tablet_channels = try getAs(a, io, port, tablet_session, "/channels");
    const tablet_create = try postAs(a, io, port, tablet_session, "/channels", "name=tablet-room");
    const tablet_add = try postAs(a, io, port, tablet_session, "/channels/crew/members/2/add", "");
    const tablet_remove = try postAs(a, io, port, tablet_session, "/channels/general/members/2/remove", "");
    try t.check("nor use the channels' admin pages, create a channel, or add or remove a member: a 403 each", tablet_channels.status == 403 and
        tablet_create.status == 403 and tablet_add.status == 403 and tablet_remove.status == 403 and has(tablet_create.body, "manage channels or agents"));
    try t.check("nor invite a human, nor invite one again (which sets their password), nor make or cancel a code, nor sign the other devices out: a 403 each, nothing written", invite_human.status == 403 and
        invite_again.status == 403 and tablet_code.status == 403 and tablet_cancel.status == 403 and tablet_sign_out_others.status == 403 and
        has(invite_again.body, "To invite people, manage channels or agents") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/1/session-generation"), "(none)"));
    try t.check("that session may not make an agent, invite one or link GitHub, by its button or through GitHub: a 403 each, saying to sign in with a password or GitHub; it reads /agents", make_agent.status == 403 and
        has(make_agent.body, "sign out here, then sign in with your password or GitHub.") and link.status == 403 and start.status == 403 and
        invite_agent.status == 403 and has(link.body, refusal[0..40]) and agents_page.status == 200);

    const out = try postAs(a, io, port, tablet_session, "/logout", "confirmed=yes");
    const by_password = try anonymousPost(a, io, port, "/login", "name=Steve&password=correct+horse+battery+staple");
    const ordinary = try cookieLine(a, by_password);
    const ordinary_link = try postAs(a, io, port, ordinary, "/login/github/link", "");
    try t.check("signed out, then in with the password on that device: an ordinary session, unmarked, which the limits leave alone", out.status == 303 and
        by_password.status == 303 and deviceKeyOf(by_password) == null and ordinary_link.status != 403);
    const laptop = try anonymousPost(a, io, port, "/login", "name=Steve&password=correct+horse+battery+staple");
    const laptop_out = try postAs(a, io, port, try cookieLine(a, laptop), "/logout", "");
    try t.check("a session a password started signs out at once, asked nothing: a 303 to sign in, its cookie forgotten", laptop_out.status == 303 and
        std.mem.eql(u8, laptop_out.header("location") orelse "", "/login") and
        has(laptop_out.head, "\r\nset-cookie: __Host-gopher_auth=; Path=/; Max-Age=0; "));

    const second = try makeCode(a, io, port, steve_session);
    const phone = try redeemFrom(a, io, port, "x-forwarded-for: 192.0.2.41\r\n", try std.fmt.allocPrint(a, "code={s}", .{second.code}));
    const phone_session = try cookieLine(a, phone);
    const phone_key_state = try std.fmt.allocPrint(a, "auth/1/device-keys/{s}/state", .{deviceKeyOf(phone) orelse "(none)"});
    const waiting = try makeCode(a, io, port, steve_session);
    const signed_out = try post(a, io, port, .{ .path = "/devices/sign-out-others", .form = "" });
    try t.check("signing other devices out cancels the live code first, and forgets the cookie that shows one", isDeviceCode(waiting.shown) and
        std.mem.startsWith(u8, try readFile(a, io, data, "users/1/device-code"), "cancelled ") and
        has(signed_out.head, "\r\nset-cookie: __Host-device_code=; Path=/; Max-Age=0; "));
    const steve_again = try cookieLine(a, signed_out);
    const old_steve = try getAs(a, io, port, steve_session, "/chat");
    const old_phone = try getAs(a, io, port, phone_session, "/chat");
    const old_ordinary = try getAs(a, io, port, ordinary, "/chat");
    const new_steve = try getAs(a, io, port, steve_again, "/chat");
    try t.check("\"Sign out other devices\": a 303 to the page, this device's session signed again, unmarked; every other session of Steve's, a code's and a password's, and this one's old cookie, sent to sign in; the phone's device key revoked", signed_out.status == 303 and
        std.mem.eql(u8, signed_out.header("location") orelse "", "/devices") and deviceKeyOf(signed_out) == null and
        new_steve.status == 200 and old_steve.status == 303 and old_phone.status == 303 and old_ordinary.status == 303 and
        std.mem.eql(u8, try readFile(a, io, data, phone_key_state), "revoked") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/1/session-generation"), "1"));
    steve_session = try std.fmt.allocPrint(a, "{s}", .{steve_again});

    // A session-generation file damaged by hand: Steve's session is refused,
    // a 303 to sign in, not a 500 on every request; a password sign-in is a
    // plain 500 saying so; mended, his session reads its page again.
    try data.writeFile(io, .{ .sub_path = "auth/1/session-generation", .data = "lots\n" });
    const refused_page = try getAt(a, io, port, "/chat");
    const refused_sign_in = try anonymousPost(a, io, port, "/login", "name=Steve&password=correct+horse+battery+staple");
    try data.writeFile(io, .{ .sub_path = "auth/1/session-generation", .data = "1" });
    const mended = try getAt(a, io, port, "/chat");
    try t.check("a damaged session-generation file: Steve's session refused, a 303 to sign in, not a 500; a password sign-in a plain 500 saying so; mended, his page again", refused_page.status == 303 and
        std.mem.startsWith(u8, refused_page.header("location") orelse "", "/login") and refused_sign_in.status == 500 and
        has(refused_sign_in.body, "Damaged") and refused_sign_in.header("set-cookie") == null and mended.status == 200);

    // A damaged device code record never stops a sign-out: logged, and the
    // session's cookie cleared all the same; signing other devices out
    // still advances the generation and signs this one again.
    try data.writeFile(io, .{ .sub_path = "users/1/device-code", .data = "not a record\n" });
    const spare = try cookieLine(a, try anonymousPost(a, io, port, "/login", "name=Steve&password=correct+horse+battery+staple"));
    const out_damaged = try postAs(a, io, port, spare, "/logout", "");
    const others_damaged = try post(a, io, port, .{ .path = "/devices/sign-out-others", .form = "" });
    const steve_now = try cookieLine(a, others_damaged);
    try t.check("a damaged device code record never stops a sign-out: the session's cookie cleared; signing other devices out still advances the generation", out_damaged.status == 303 and
        has(out_damaged.head, "\r\nset-cookie: __Host-gopher_auth=; Path=/; Max-Age=0") and others_damaged.status == 303 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/1/session-generation"), "2") and (try getAs(a, io, port, steve_now, "/chat")).status == 200);
    steve_session = try std.fmt.allocPrint(a, "{s}", .{steve_now});

    try data.writeFile(io, .{ .sub_path = "users/1/device-sign-ins", .data = "not a list\n" });
    const damaged = try getAt(a, io, port, "/devices");
    try t.check("a damaged list of sign-ins by code is logged and taken as none: the page, 200", damaged.status == 200 and
        has(damaged.body, "No device has signed in with a code yet."));
}

/// A device code made with the `Cookie` line `session`: the POST's answer,
/// the page it leads to, carried there by its cookie, the code as shown, and
/// its 8 digits, as a phone types them.
const Made = struct { made: Response, page: Response, shown: []const u8, code: []const u8 };

fn makeCode(a: std.mem.Allocator, io: Io, port: u16, session: []const u8) !Made {
    const made = try postAs(a, io, port, session, "/devices", "");
    const set = made.header("set-cookie") orelse "";
    const pair = set[0 .. std.mem.indexOfScalar(u8, set, ';') orelse set.len];
    const both = try std.fmt.allocPrint(a, "{s}; {s}\r\n", .{ std.mem.trimEnd(u8, session, "\r\n"), pair });
    const page = try getAs(a, io, port, both, "/devices");
    const shown = between(page.body, "<p class=\"sign-in-code\">", "</p>") orelse "";
    const code = try std.mem.replaceOwned(u8, a, shown, thin_space, "");
    return .{ .made = made, .page = page, .shown = shown, .code = code };
}

/// The thin space, U+2009, between a shown device code's two groups.
const thin_space = "\u{2009}";

/// Whether `shown` is as the page shows a device code: four digits, a thin
/// space, and four more.
fn isDeviceCode(shown: []const u8) bool {
    if (shown.len != 8 + thin_space.len or !std.mem.eql(u8, shown[4 .. 4 + thin_space.len], thin_space)) return false;
    for (shown[0..4]) |c| if (!std.ascii.isDigit(c)) return false;
    for (shown[4 + thin_space.len ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Whether `answer` is the one refusal of a device code: a 401, the
/// sign-in page saying only that it didn't work, no cookie, never stored.
fn isCodeRefusal(answer: Response) bool {
    return answer.status == 401 and has(answer.body, "That code didn&#39;t work. Check it and try again; a code lasts five minutes.") and
        answer.header("set-cookie") == null and std.mem.eql(u8, answer.header("cache-control") orelse "", "no-store");
}

/// A device code's form POSTed to `/login/code` from the phone `client` (an
/// `X-Forwarded-For` line), with no credential.
fn redeemFrom(a: std.mem.Allocator, io: Io, port: u16, client: []const u8, form: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "POST /login/code HTTP/1.1\r\nhost: localhost:{d}\r\n{s}content-type: application/x-www-form-urlencoded\r\ncontent-length: {d}\r\n\r\n{s}", .{ port, client, form.len, form }));
}

/// Steps 50 and 51, on a server of their own, beside the first, whose data
/// root is `data_name` and `-plain`.
fn noGitHubSteps(a: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, t: Steps, data_name: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const plain_name = try std.fmt.allocPrint(a, "{s}-plain", .{data_name});
    try cwd.createDirPath(io, plain_name);
    defer cwd.deleteTree(io, plain_name) catch |e| std.debug.print("end-to-end: {s} not removed ({t})\n", .{ plain_name, e });
    const data = try cwd.openDir(io, plain_name, .{});
    defer data.close(io);
    // The free space the server is told its disk has (`limitSteps`): all a
    // u64 holds, so the floor never bites, until a step lowers it.
    var free_bytes: std.atomic.Value(u64) = .init(std.math.maxInt(u64));
    const root: files.DataRoot = .{ .io = io, .dir = data, .free_bytes_for_test = &free_bytes };
    var server = try http.Server.listen(io, gpa, .{ .port = 0, .root = &root, .public_origin = public_origin });
    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch |e| std.debug.print("end-to-end: the second server's run: {t}\n", .{e});
    }
    const port = server.port();
    _ = try writePassword(a, io, data);
    const steve = try cookieLine(a, try anonymousPost(a, io, port, "/login", "name=Steve&password=correct+horse+battery+staple"));

    // 50.
    const login_page = try anonymousGet(a, io, port, "/login");
    const agents_page = try getAs(a, io, port, steve, "/agents");
    try t.check("no GitHub settings: the sign-in page and Steve's /agents, 200 each, name no GitHub route", login_page.status == 200 and
        agents_page.status == 200 and !has(login_page.body, "/login/github") and !has(agents_page.body, "/login/github"));
    for ([_][]const u8{ "", steve }) |browser| {
        const start = try getAs(a, io, port, browser, "/login/github/start");
        const way_back = try getAs(a, io, port, browser, "/login/github?code=user-id-7&state=x");
        const name = try postAs(a, io, port, browser, "/login/github/name", "name=Mallory");
        const link = try postAs(a, io, port, browser, "/login/github/link", "");
        const wrong_start = try postAs(a, io, port, browser, "/login/github/start", "");
        const wrong_back = try postAs(a, io, port, browser, "/login/github", "");
        const wrong_name = try getAs(a, io, port, browser, "/login/github/name");
        const wrong_link = try getAs(a, io, port, browser, "/login/github/link");
        // The link is a signed-in route, so no one asking for it is a 401.
        const link_status: u16 = if (browser.len == 0) 401 else 404;
        try t.check("no GitHub settings: the start, the way back, the name and the link (by no one, a 401), and each by the wrong method, a 404", start.status == 404 and
            way_back.status == 404 and name.status == 404 and link.status == link_status and wrong_start.status == 404 and wrong_back.status == 404 and
            wrong_name.status == 404 and wrong_link.status == 404 and has(name.body, "Nothing is here") and
            !(try exists(io, data, "auth/2")));
    }

    // 51.
    const invited = try postAs(a, io, port, steve, "/invites", "name=Tam");
    const link = between(invited.body, "<p class=\"invite-code\">", "</p>") orelse return error.NoLink;
    const hash = std.mem.indexOfScalar(u8, link, '#') orelse return error.NoCode;
    const joined = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Tam&password=their+own", .{link[hash + 1 ..]}));
    const first_page = try getAs(a, io, port, try cookieLine(a, joined), joined.header("location") orelse "");
    try t.check("no conversation yet: an invited human joins #general, and lands on their DM with the owner, a 200", joined.status == 303 and
        std.mem.eql(u8, joined.header("location") orelse "", "/chat/dm/1_2/ChitChat") and first_page.status == 200 and
        has(first_page.body, "If Steve is not here") and
        std.mem.eql(u8, try readFile(a, io, data, "chat/channel/general.channel"), "1\n2\n"));

    steve_session = steve;
    try browseSteps(a, io, port, data, t, try cookieLine(a, joined));
    try limitSteps(a, io, port, data, t, &free_bytes);
}

/// Step 54, the day's cap on GitHub sign-ups (app/SignUpLimits.roc), on a
/// third server of its own, whose memory holds no sign-up yet: its data root
/// is `data_name` and `-capped`.
fn signUpCapSteps(a: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, t: Steps, held: struct { data_name: []const u8, fake: *fake_github.Fake }) !void {
    const cwd = Io.Dir.cwd();
    const capped_name = try std.fmt.allocPrint(a, "{s}-capped", .{held.data_name});
    try cwd.createDirPath(io, capped_name);
    defer cwd.deleteTree(io, capped_name) catch |e| std.debug.print("end-to-end: {s} not removed ({t})\n", .{ capped_name, e });
    const data = try cwd.openDir(io, capped_name, .{});
    defer data.close(io);
    try writeGitHubSettings(io, data, held.fake);
    const root: files.DataRoot = .{ .io = io, .dir = data };
    var server = try http.Server.listen(io, gpa, .{ .port = 0, .root = &root, .public_origin = public_origin });
    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch |e| std.debug.print("end-to-end: the third server's run: {t}\n", .{e});
    }
    const port = server.port();
    _ = try writePassword(a, io, data);
    const steve = try cookieLine(a, try anonymousPost(a, io, port, "/login", "name=Steve&password=correct+horse+battery+staple"));

    // 54.
    // No I beside L, nor M or W, which look like others to a name's skeleton.
    const letters = "ABCDEFGHJKNOPQRSTUXY";
    var made: usize = 0;
    var waiting: []const u8 = "";
    for (letters, 0..) |letter, i| {
        if (i == 19) waiting = try signUpLine(a, try signInByGitHub(a, io, port, held.fake, "user-id-120"));
        const code = try std.fmt.allocPrint(a, "user-id-{d}", .{100 + i});
        const signed_up = try signUpHeadingTo(a, io, port, held.fake, channel_url, code, try std.fmt.allocPrint(a, "Cap+{c}", .{letter}));
        if (signed_up.status == 303 and has(signed_up.head, "__Host-gopher_auth=")) made += 1;
    }
    const counter = try readFile(a, io, data, "auth/next-id.txt");
    const one_more = try signInByGitHub(a, io, port, held.fake, "user-id-121");
    const late_name = try chooseName(a, io, port, waiting, "Late");
    const invited = try postAs(a, io, port, steve, "/invites", "name=Una");
    const paused = "Sign-ups are paused for now; please try again later.";
    try t.check("twenty GitHub sign-ups in a day make twenty accounts; the next is the sign-in page, a 503 saying sign-ups are paused, no form and no sign-up; a name for a sign-up begun before the twentieth, the same, nothing made; an invite still makes its account", made == 20 and
        std.mem.eql(u8, counter, "22\n") and
        one_more.status == 503 and has(one_more.body, paused) and !has(one_more.body, "action=\"/login/github/name\"") and !has(one_more.head, "__Host-gopher_github_sign_up=") and
        late_name.status == 503 and has(late_name.body, paused) and !has(late_name.head, "__Host-gopher_auth=") and
        invited.status == 200 and has(invited.body, "invite-code") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "23\n"));
}

/// Step 53a, presence, as Gopher Chat's: Uma (3), just joined, has made no
/// request that counts; Steve holds his DM with her open, its stream on.
fn presenceSteps(a: std.mem.Allocator, io: Io, port: u16, t: Steps, uma: []const u8) !void {
    const dm = "/chat/dm/1_3/ChitChat";
    const before = try getAs(a, io, port, steve_session, dm);
    var stream = try Stream.openWith(a, io, port, dm ++ "/stream?after=1", "");
    defer stream.close();
    const away = "data-section=\"/chat/dm/1_3\" data-opening=\"always\" data-person=\"3\" data-presence=\"offline\">";
    const here = "data-section=\"/chat/dm/1_3\" data-opening=\"always\" data-person=\"3\" data-presence=\"online\">";
    try t.check("presence: Uma, joined but never seen, is away in Steve's sidebar, and his own DM names him, online", before.status == 200 and has(before.body, away) and
        has(before.body, "data-section=\"/chat/dm/1_1\" data-opening=\"collapsed\" data-person=\"1\" data-presence=\"online\">") and stream.isEventStream());
    try t.check("presence: the line above Steve's DM with Uma says, as it is drawn, that she hasn't been on since the server started", has(before.body, "<p class=\"notice-strip\">Uma hasn&#39;t been on since the server started.</p>"));
    // Her first request that counts: Browse.
    const browsed = try getAs(a, io, port, uma, "/chat");
    const online = try stream.event();
    const notice = try stream.event();
    try t.check("presence: Uma's first page brings her online: Steve's open stream says so, her dot, then \"Uma has come online.\" linked to their DM", browsed.status == 200 and
        std.mem.eql(u8, online, "event: online\ndata: 3\n\n") and
        std.mem.eql(u8, notice, "event: notice\ndata: <a href=\"" ++ dm ++ "\">Uma has come online.</a>\n\n"));
    // Within five minutes, her pages tell no one again.
    const again = try getAs(a, io, port, uma, dm);
    const said = try postAs(a, io, port, steve_session, dm ++ "/send", "markdown=Hi+Uma");
    const next = try stream.event();
    const after = try getAs(a, io, port, steve_session, dm);
    try t.check("presence: her next page tells no one: Steve's next event is his own message; his page now draws her online", again.status == 200 and said.status == 201 and
        std.mem.startsWith(u8, next, "id: 2\ndata: <article") and has(after.body, here) and has(again.body, "data-section=\"/chat/dm/3_3\" data-opening=\"collapsed\" data-person=\"3\" data-presence=\"online\">"));
    try t.check("presence: the line above his DM with her now says, as it is drawn, \"Uma is online.\"", has(after.body, "<p class=\"notice-strip\">Uma is online.</p>"));
}

/// Steps 52 to 58, as Steve (1), Tam (2) and Uma (3), who are all in #general;
/// Steve alone is in #crew.
fn browseSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps, tam: []const u8) !void {
    // 52.
    const stranger = try anonymousGet(a, io, port, "/chat");
    const sign_in = try anonymousGet(a, io, port, stranger.header("location") orelse "");
    const stranger_topic = try anonymousPost(a, io, port, "/chat/dm/1_2", "topic=plans");
    try t.check("Browse for a stranger: a 303 to the sign-in page, which comes back to it and shows no link to it; a new topic: 401", stranger.status == 303 and
        std.mem.eql(u8, stranger.header("location") orelse "", "/login?next=/chat") and sign_in.status == 200 and
        has(sign_in.body, "name=\"next\" value=\"/chat\"") and !has(sign_in.body, browse_link) and stranger_topic.status == 401);

    // 52a.
    const way_in = try anonymousGet(a, io, port, "/");
    const way_in_query = try anonymousGet(a, io, port, "/?from=a-link");
    const way_in_on = try anonymousGet(a, io, port, way_in.header("location") orelse "");
    try t.check("/ for a stranger: a 303 to Browse, which sends them to sign in; a query changes nothing", way_in.status == 303 and way_in_query.status == 303 and
        std.mem.eql(u8, way_in.header("location") orelse "", "/chat") and std.mem.eql(u8, way_in_query.header("location") orelse "", "/chat") and
        way_in_on.status == 303 and std.mem.eql(u8, way_in_on.header("location") orelse "", "/login?next=/chat"));
    const stale = "cookie: __Host-gopher_auth=MQ.1.bad\r\n";
    const stale_way_in = try getAs(a, io, port, stale, "/");
    const stale_on = try getAs(a, io, port, stale, stale_way_in.header("location") orelse "");
    try t.check("/ for a cookie that admits no one: the same way to sign in", stale_way_in.status == 303 and
        std.mem.eql(u8, stale_way_in.header("location") orelse "", "/chat") and stale_on.status == 303 and
        std.mem.eql(u8, stale_on.header("location") orelse "", "/login?next=/chat"));
    const steves_page = try getAs(a, io, port, steve_session, channel_url);
    const steves_last = try readFile(a, io, data, "users/1/last-conv");
    const steves_way_in = try getAs(a, io, port, steve_session, "/");
    try t.check("a conversation's page for someone signed in: its sidebar, the page's topic marked; the page recorded, bare, as their last; and / a 303 back to it", steves_page.status == 200 and
        has(steves_page.body, "</a></span> <p class=\"notice-strip\"></p> <div class=\"top-user\">") and
        has(steves_page.body, "</header>\n<button class=\"sidebar-toggle\">Conversations</button>\n<div class=\"layout\"><nav class=\"sidebar\">") and
        has(steves_page.body, "<li><a class=\"current\" href=\"" ++ channel_url ++ "\">roc-chat</a></li>") and
        has(steves_page.body, "<script src=\"/chat/assets/sidebar.js\"></script>") and std.mem.eql(u8, steves_last, channel_url) and
        steves_way_in.status == 303 and std.mem.eql(u8, steves_way_in.header("location") orelse "", channel_url));
    try data.writeFile(io, .{ .sub_path = "users/1/last-conv", .data = "/chat/channel/gone/plans" });
    const unreadable_way_in = try getAs(a, io, port, steve_session, "/");
    const steves_way_on = try getAs(a, io, port, steve_session, unreadable_way_in.header("location") orelse "");
    try data.deleteFile(io, "users/1/last-conv");
    const no_last_way_in = try getAs(a, io, port, steve_session, "/");
    try t.check("/ for someone signed in whose last conversation they can't read, or who has none: a 303 to Browse, which shows them it, with no sign-in form", unreadable_way_in.status == 303 and
        std.mem.eql(u8, unreadable_way_in.header("location") orelse "", "/chat") and steves_way_on.status == 200 and
        has(steves_way_on.body, "<h1>Steve <span class=\"you\">(you)</span></h1>") and !has(steves_way_on.body, "action=\"/login\"") and
        no_last_way_in.status == 303 and std.mem.eql(u8, no_last_way_in.header("location") orelse "", "/chat"));
    const post_way_in = try anonymousPost(a, io, port, "/", "");
    const steves_post_way_in = try postAs(a, io, port, steve_session, "/", "");
    const put_way_in = try exchange(a, io, port, try std.fmt.allocPrint(a, "PUT / HTTP/1.1\r\nhost: localhost:{d}\r\ncontent-length: 0\r\n\r\n", .{port}));
    try t.check("/ takes GET alone: a POST, signed in or not, and a PUT are a 405", post_way_in.status == 405 and steves_post_way_in.status == 405 and put_way_in.status == 405 and
        std.mem.eql(u8, post_way_in.header("allow") orelse "", "GET"));

    // 53.
    const created = try postAs(a, io, port, steve_session, "/channels", "name=crew");
    const joined_crew = try postAs(a, io, port, steve_session, "/channels/crew/members/1/add", "");
    const uma = try joinedHuman(a, io, port, steve_session, "Uma");
    try presenceSteps(a, io, port, t, uma);
    const steves = try getAs(a, io, port, steve_session, "/chat");
    const tams = try getAs(a, io, port, tam, "/chat");
    try t.check("Steve's Browse: every human, himself too, each DM's topics, and both his channels, each with its form", created.status == 303 and joined_crew.status == 303 and steves.status == 200 and
        has(steves.body, "<h1>Steve <span class=\"you\">(you)</span></h1>") and has(steves.body, "<h1>Tam</h1>") and has(steves.body, "<h1>Uma</h1>") and has(steves.body, "<h1>#general</h1>") and has(steves.body, "<h1>#crew</h1>") and
        has(steves.body, "href=\"/chat/dm/1_2/ChitChat\"") and has(steves.body, "href=\"/chat/dm/1_3/ChitChat\"") and
        has(steves.body, "action=\"/chat/dm/1_1\"") and has(steves.body, "action=\"/chat/channel/crew\"") and has(steves.body, "action=\"/chat/channel/general\""));
    try t.check("Browse in its panel, ending with the scripts that style it, the frame's first", has(steves.body, "<div class=\"layout\"><div class=\"panel\">") and
        has(steves.body, "</div></div>\n<script src=\"/chat/assets/chrome.js\"></script>\n<script src=\"/chat/assets/panel.js\"></script>\n"));
    try t.check("Tam's Browse: her DMs and #general; not #crew, which she is not in, and not Steve's DM with Uma", tams.status == 200 and
        has(tams.body, "<h1>#general</h1>") and has(tams.body, "href=\"/chat/dm/1_2/ChitChat\"") and has(tams.body, "action=\"/chat/dm/2_3\"") and has(tams.body, "action=\"/chat/dm/2_2\"") and
        !has(tams.body, "crew") and !has(tams.body, "/chat/dm/1_3"));

    // 53a.
    const invite_link = "<a href=\"/invites\">Invites</a>";
    const invites_from_link = try getAs(a, io, port, steve_session, between(steves.body, "Recent</a> · <a href=\"", "\">Invites</a>") orelse "");
    const tams_invites = try getAs(a, io, port, tam, between(tams.body, "Recent</a> · <a href=\"", "\">Invites</a>") orelse "");
    try t.check("Browse's one link to /invites is the top bar's, which, for the owner and any other human, reaches the form that invites someone", has(steves.body, invite_link) and has(tams.body, invite_link) and
        !has(steves.body, "<p><a href=\"/invites\">") and
        invites_from_link.status == 200 and has(invites_from_link.body, "action=\"/invites\"") and tams_invites.status == 200 and has(tams_invites.body, "action=\"/invites\""));
    const top_bar_link = "<a href=\"/invites\">Invites</a>";
    const conversation_page = try getAs(a, io, port, steve_session, "/chat/dm/1_2/ChitChat");
    const tams_conversation = try getAs(a, io, port, tam, "/chat/dm/1_2/ChitChat");
    const invites_from_top_bar = try getAs(a, io, port, tam, between(tams_conversation.body, "Recent</a> · <a href=\"", "\">Invites</a>") orelse "");
    const tams_title = between(tams_conversation.body, "<span class=\"top-title\"><a href=\"", "\">Steve on ChitChat</a></span>") orelse "";
    const title_reloads = try getAs(a, io, port, tam, tams_title);
    try t.check("a DM's title names the other human on the topic, for each of them, and links to the page itself, which it reloads", has(conversation_page.body, "<span class=\"top-title\"><a href=\"/chat/dm/1_2/ChitChat\">Tam on ChitChat</a></span>") and
        std.mem.eql(u8, tams_title, "/chat/dm/1_2/ChitChat") and title_reloads.status == 200 and has(title_reloads.body, "Steve on ChitChat</a></span>"));
    try t.check("a conversation's top bar links to /invites, for the owner and any other human, and reaches the form", conversation_page.status == 200 and has(conversation_page.body, top_bar_link) and
        tams_conversation.status == 200 and has(tams_conversation.body, top_bar_link) and invites_from_top_bar.status == 200 and has(invites_from_top_bar.body, "action=\"/invites\""));
    try t.check("no link to /invites for a stranger, at sign-in", sign_in.status == 200 and !has(sign_in.body, "/invites"));

    // 54.
    var every_page_links = true;
    var no_page_signs_up = true;
    for ([_][]const u8{ "/chat", "/agents", "/invites", "/login", "/channels", "/channels/crew", "/chat/dm/1_2/ChitChat", "/chat/channel/general/empty-topic" }) |path| {
        const page = try getAs(a, io, port, steve_session, path);
        every_page_links = every_page_links and page.status == 200 and has(page.body, home_link) and has(page.body, browse_link) and has(page.body, top_bar_link);
        no_page_signs_up = no_page_signs_up and !has(page.body, "href=\"/join") and !has(page.body, "action=\"/join") and !has(page.body, "action=\"/login");
    }
    try t.check("every signed-in page has the Home, Browse and Invites links", every_page_links);
    try t.check("no signed-in page has a sign-up, join or sign-in link or form", no_page_signs_up);
    const join_while_signed_in = try getAs(a, io, port, steve_session, "/join");
    try t.check("a signed-in browser going to /join is sent to Browse", join_while_signed_in.status == 303 and std.mem.eql(u8, join_while_signed_in.header("location") orelse "", "/chat"));

    // 55.
    const not_her_channel = try postAs(a, io, port, tam, "/chat/channel/crew", "topic=plans");
    const not_her_dm = try postAs(a, io, port, tam, "/chat/dm/1_3", "topic=plans");
    const not_her_page = try getAs(a, io, port, tam, "/chat/channel/crew/plans");
    const not_her_stream = try getAs(a, io, port, tam, "/chat/dm/1_3/plans/stream?after=0");
    const not_her_download = try getAs(a, io, port, tam, "/chat/channel/crew/plans/download");
    const not_her_dm_download = try getAs(a, io, port, tam, "/chat/dm/1_3/plans/download");
    const no_such_human = try postAs(a, io, port, tam, "/chat/dm/2_9", "topic=plans");
    const by_get = try getAs(a, io, port, tam, "/chat/dm/2_3");
    const cross_site = try postAs(a, io, port, try std.fmt.allocPrint(a, "{s}sec-fetch-site: cross-site\r\n", .{tam}), "/chat/dm/2_3", "topic=plans");
    try t.check("a topic in a channel or DM she isn't in, and the page, stream and download of one: 403 each; no such human: 404; a GET: 405; a cross-site post: 403", not_her_channel.status == 403 and
        not_her_dm.status == 403 and not_her_page.status == 403 and not_her_stream.status == 403 and no_such_human.status == 404 and
        not_her_download.status == 403 and not_her_dm_download.status == 403 and
        by_get.status == 405 and std.mem.eql(u8, by_get.header("allow") orelse "", "POST") and cross_site.status == 403);

    // 56.
    const bad_name = try postAs(a, io, port, tam, "/chat/dm/2_3", "topic=two+words");
    const no_name = try postAs(a, io, port, tam, "/chat/dm/2_3", "");
    try t.check("a name that is no topic, and no name: Browse again, a 400 each, saying why, nothing made", bad_name.status == 400 and no_name.status == 400 and
        has(bad_name.body, "A topic&#39;s name starts with a letter") and has(bad_name.body, "<h1>#general</h1>") and has(bad_name.body, invite_link) and has(no_name.body, "no field") and
        !(try exists(io, data, "chat/dm/2_3")));

    // 57.
    const url = "/chat/dm/1_2/plans";
    const steves_again = try getAs(a, io, port, steve_session, "/chat");
    const started = try postAs(a, io, port, steve_session, "/chat/dm/1_2", "topic=plans");
    const empty = try getAs(a, io, port, steve_session, started.header("location") orelse "");
    try t.check("the acceptance path: from Browse, Tam's form, a topic: a 303 to its page, empty, ready to write in, nothing on disk", has(steves_again.body, "action=\"/chat/dm/1_2\"") and started.status == 303 and
        std.mem.eql(u8, started.header("location") orelse "", url) and empty.status == 200 and has(empty.body, "No messages yet.") and
        has(empty.body, "data-send=\"" ++ url ++ "/send\"") and !(try exists(io, data, "chat/dm/1_2/plans")));
    var stream = try Stream.open(a, io, port, url ++ "/stream?after=0");
    defer stream.close();
    const sent = try postAs(a, io, port, steve_session, url ++ "/send", "markdown=The+first+word");
    const page = try getAs(a, io, port, steve_session, url);
    try t.check("compose and send: 201; the open page's stream brings it; the page shows it, and no longer says it is empty", sent.status == 201 and stream.isEventStream() and
        std.mem.eql(u8, try stream.event(), try frameOf(a, page.body, "1")) and has(page.body, "The first word") and !has(page.body, "No messages yet."));
    const steves_now = try getAs(a, io, port, steve_session, "/chat");
    const tams_now = try getAs(a, io, port, tam, "/chat");
    const umas_now = try getAs(a, io, port, uma, "/chat");
    try t.check("the topic on Browse: linked for both its humans, and not for Uma", has(steves_now.body, "href=\"" ++ url ++ "\"") and
        has(tams_now.body, "href=\"" ++ url ++ "\"") and !has(umas_now.body, url));

    // 57a.
    try t.check("a topic's first message tells its humans' sidebars, its author too: Steve's open stream, after his message, says topic-added, the place, the topic and its page", std.mem.eql(u8, try stream.event(), "event: topic-added\ndata: /chat/dm/1_2\ndata: plans\ndata: " ++ url ++ "\n\n"));
    const lunch = "/chat/dm/1_2/lunch";
    const tams_first = try postAs(a, io, port, tam, lunch ++ "/send", "markdown=Lunch%3F");
    const told = try stream.event();
    const lunch_notice = try stream.event();
    const tams_second = try postAs(a, io, port, tam, lunch ++ "/send", "markdown=At+noon");
    const second_notice = try stream.event();
    const tams_reply = try postAs(a, io, port, tam, url ++ "/send", "markdown=Seen");
    const next = try stream.event();
    const here_notice = try stream.event();
    const lunch_said = "\">Tam sent you a message on lunch.</a>\n\n";
    const lunch_link = "event: message-notice\ndata: <a href=\"" ++ lunch;
    try t.check("Tam adds a topic to their DM: Steve's open page hears topic-added for it; her second message there adds no topic again, so after its notice his next event is her reply on his page", tams_first.status == 201 and tams_second.status == 201 and tams_reply.status == 201 and
        std.mem.eql(u8, told, "event: topic-added\ndata: /chat/dm/1_2\ndata: lunch\ndata: " ++ lunch ++ "\n\n") and
        std.mem.startsWith(u8, next, "id: 2\ndata: <article"));
    // 57c.
    try t.check("each of Tam's messages tells Steve's open stream, as Gopher Chat's notify did: message-notice, linked to the message itself on its topic's page, after the message's own events; for the page's own topic too, which the page drops", std.mem.eql(u8, lunch_notice, lunch_link ++ "#msg-1" ++ lunch_said) and
        std.mem.eql(u8, second_notice, lunch_link ++ "#msg-2" ++ lunch_said) and
        std.mem.eql(u8, here_notice, "event: message-notice\ndata: <a href=\"" ++ url ++ "#msg-2\">Tam sent you a message on plans.</a>\n\n"));
    // 57f.
    const self_notes = "/chat/dm/1_1/self-notes";
    const to_tam = try postAs(a, io, port, steve_session, lunch ++ "/send", "markdown=Noon+it+is");
    const to_self = try postAs(a, io, port, steve_session, self_notes ++ "/send", "markdown=A+note+to+myself");
    const self_told = try stream.event();
    const self_notice = try stream.event();
    const to_self_again = try postAs(a, io, port, steve_session, self_notes ++ "/send", "markdown=And+another");
    const self_notice_again = try stream.event();
    const self_said = "\">Steve sent you a message on self-notes.</a>\n\n";
    try t.check("a message in Steve's own DM is news to him, as if someone else had sent it: his open stream on his DM with Tam hears the new topic, then message-notice linked to the message, and again for the next; his message to Tam on another topic just before told him nothing, the new topic being his stream's next event", to_tam.status == 201 and to_self.status == 201 and to_self_again.status == 201 and
        std.mem.eql(u8, self_told, "event: topic-added\ndata: /chat/dm/1_1\ndata: self-notes\ndata: " ++ self_notes ++ "\n\n") and
        std.mem.eql(u8, self_notice, "event: message-notice\ndata: <a href=\"" ++ self_notes ++ "#msg-1" ++ self_said) and
        std.mem.eql(u8, self_notice_again, "event: message-notice\ndata: <a href=\"" ++ self_notes ++ "#msg-2" ++ self_said));
    try recentSteps(a, io, port, t, .{ .tam = tam, .uma = uma });
}

/// Steps 35i to 35l: a conversation's download, each archive read back
/// by Zig's own gzip and tar readers (`unpacked`), against the files on
/// disk.
fn downloadSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps) !void {
    // 35i.
    const edits = try get(a, io, port, "/chat/channel/general/edits/download");
    const edits_files = try unpacked(a, edits.body);
    try t.check("the edits topic's download: 200, a gzip saved as edits.tar.gz; exactly its transcript, then its reactions, byte for byte", edits.status == 200 and
        std.mem.eql(u8, edits.header("content-type") orelse "", "application/gzip") and
        std.mem.eql(u8, edits.header("content-disposition") orelse "", "attachment; filename=\"edits.tar.gz\"") and
        std.mem.eql(u8, edits.header("x-content-type-options") orelse "", "nosniff") and
        edits_files.len == 2 and std.mem.eql(u8, edits_files[0].name, "edits/edits.md") and
        std.mem.eql(u8, edits_files[0].bytes, try readFile(a, io, data, "chat/channel/general/edits/transcript")) and
        std.mem.eql(u8, edits_files[1].name, "edits/edits.reactions.jsonl") and
        std.mem.eql(u8, edits_files[1].bytes, try readFile(a, io, data, "chat/channel/general/edits/reactions")));

    // 35j.
    const channel = try get(a, io, port, channel_url ++ "/download");
    const channel_files = try unpacked(a, channel.body);
    const uploads = try namesIn(a, io, data, channel_uploads);
    var images_whole = channel_files.len == 1 + uploads.len;
    for (channel_files[1..]) |file| {
        const name = file.name["roc-chat/uploads/".len..];
        images_whole = images_whole and std.mem.startsWith(u8, file.name, "roc-chat/uploads/") and
            std.mem.eql(u8, file.bytes, try readFile(a, io, data, try std.fmt.allocPrint(a, "{s}/{s}", .{ channel_uploads, name })));
    }
    try t.check("the seeded channel's download: its transcript, then each of its uploads, byte for byte", channel.status == 200 and
        uploads.len >= 2 and std.mem.eql(u8, channel_files[0].name, "roc-chat/roc-chat.md") and
        std.mem.eql(u8, channel_files[0].bytes, try readFile(a, io, data, seed_path["demo/data/".len..])) and images_whole);

    // 35k.
    const big_url = "/chat/channel/general/big";
    const big_uploads = "chat/channel/general/big/uploads";
    const started = try post(a, io, port, .{ .path = big_url, .form = "markdown=Big" });
    const image = try a.alloc(u8, 10 * 1024 * 1024);
    @memset(image, 7);
    try data.createDirPath(io, big_uploads);
    for ([_][]const u8{ "11111111111111111111111111111111", "22222222222222222222222222222222", "33333333333333333333333333333333" }) |digits| {
        try data.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, big_uploads ++ "/{s}.png", .{digits}), .data = image });
    }
    const at_most = try get(a, io, port, big_url ++ "/download");
    const at_most_files = try unpacked(a, at_most.body);
    try data.writeFile(io, .{ .sub_path = big_uploads ++ "/44444444444444444444444444444444.png", .data = image });
    const past = try get(a, io, port, big_url ++ "/download");
    try t.check("a topic of 30 MiB of uploads: its download whole; one more image, past 32 MiB: 409, saying so", started.status == 303 and
        at_most.status == 200 and at_most_files.len == 4 and std.mem.eql(u8, at_most_files[3].bytes, image) and
        past.status == 409 and has(past.body, "more than 32 MiB of files"));

    // 35l.
    const no_transcript = try get(a, io, port, "/chat/channel/general/never-written/download");
    const by_post = try post(a, io, port, .{ .path = "/chat/channel/general/edits/download", .form = "" });
    const by_no_one = try anonymousGet(a, io, port, "/chat/channel/general/edits/download");
    try t.check("a topic with no transcript: 404; a POST: 405, allowing GET; no one: 401", no_transcript.status == 404 and
        by_post.status == 405 and std.mem.eql(u8, by_post.header("allow") orelse "", "GET") and by_no_one.status == 401);
}

/// A file of an archive `unpacked` read: its name and its bytes.
const Unpacked = struct { name: []const u8, bytes: []const u8 };

/// The files of the `.tar.gz` `gz`, in order, read by Zig's own gzip reader
/// (which checks the CRC-32 and the size) and tar reader (which checks each
/// header's sum).
fn unpacked(a: std.mem.Allocator, gz: []const u8) ![]const Unpacked {
    var input: Io.Reader = .fixed(gz);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    var gzip: std.compress.flate.Decompress = .init(&input, .gzip, window);
    const tar = try gzip.reader.allocRemaining(a, .unlimited);
    var reader: Io.Reader = .fixed(tar);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var read_back: std.ArrayList(Unpacked) = .empty;
    while (try it.next()) |file| {
        var bytes: Io.Writer.Allocating = .init(a);
        try it.streamRemaining(file, &bytes.writer);
        try read_back.append(a, .{ .name = try a.dupe(u8, file.name), .bytes = bytes.written() });
    }
    return read_back.items;
}

/// Step 58: Recent, after a post in two topics a second apart: Tam's in
/// #general's roc-chat, then Steve's in his DM with Tam.
fn recentSteps(a: std.mem.Allocator, io: Io, port: u16, t: Steps, who: struct { tam: []const u8, uma: []const u8 }) !void {
    const dm_plans = "/chat/dm/1_2/plans";
    var live = try Stream.open(a, io, port, "/chat/recent/stream");
    defer live.close();
    const in_channel = try postAs(a, io, port, who.tam, channel_url ++ "/send", "markdown=Tam+in+the+channel");
    try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(1100) }, io);
    const in_dm = try postAs(a, io, port, steve_session, dm_plans ++ "/send", "markdown=Steve+in+the+DM");
    const tams = try getAs(a, io, port, who.tam, "/chat/recent");
    const umas = try getAs(a, io, port, who.uma, "/chat/recent");
    const steves = try getAs(a, io, port, steve_session, "/chat/recent");
    const newest = std.mem.indexOf(u8, tams.body, "href=\"" ++ dm_plans ++ "\"") orelse tams.body.len;
    const older = std.mem.indexOf(u8, tams.body, "href=\"" ++ channel_url ++ "\"") orelse 0;
    const own_dm = "/chat/dm/1_1";
    const self_notes = own_dm ++ "/self-notes";
    const own_where = "<span class=\"recent-mark\"></span>DM with Steve <span class=\"you\">(you)</span></span>";
    const own_at = std.mem.indexOf(u8, steves.body, "href=\"" ++ self_notes ++ "\"") orelse 0;
    const steves_newest = std.mem.indexOf(u8, steves.body, "href=\"" ++ dm_plans ++ "\"") orelse steves.body.len;
    try t.check("Recent: both topics, the newest message's first, each with its last author and words; a DM only for its humans; Steve's own DM's topics in his alone, after his newer DM with Tam, \"DM with Steve (you)\" by his own green dot", in_channel.status == 201 and in_dm.status == 201 and
        tams.status == 200 and newest < older and older < tams.body.len and
        has(tams.body, "<span class=\"recent-who\">Steve: </span>Steve in the DM") and has(tams.body, "<span class=\"recent-who\">You: </span>Tam in the channel") and
        umas.status == 200 and has(umas.body, "href=\"" ++ channel_url ++ "\"") and !has(umas.body, dm_plans) and
        !has(tams.body, own_dm) and !has(umas.body, own_dm) and !has(tams.body, "(you)") and !has(umas.body, "(you)") and
        has(steves.body, "<a class=\"recent-tile\" href=\"" ++ self_notes ++ "\" data-person=\"1\" data-presence=\"online\">") and
        has(steves.body, own_where) and steves_newest < own_at and
        steves.status == 200 and has(steves.body, "<span class=\"recent-who\">Tam: </span>Tam in the channel") and
        has(steves.body, "<script src=\"/chat/assets/recent.js\"></script>\n<script src=\"/chat/assets/search.js\"></script>"));
    // The stream carries the viewer's own key too, so a new topic's
    // topic-added comes by as well, which the Recent page ignores.
    const notice = try live.expectEvent("event: message-notice\n", &.{"event: topic-added\n"});
    const first = try live.expectEvent("event: tile\n", &.{"event: topic-added\n"});
    const second = try live.expectEvent("event: tile\n", &.{"event: topic-added\n"});
    // The notice links to Tam's post itself: its anchor names the article on
    // the channel's page that holds her words.
    const notice_head = "event: message-notice\ndata: <a href=\"" ++ channel_url ++ "#msg-";
    const notice_tail = "\">Tam posted to general &gt; roc-chat.</a>\n\n";
    const shaped = std.mem.startsWith(u8, notice, notice_head) and std.mem.endsWith(u8, notice, notice_tail) and notice.len > notice_head.len + notice_tail.len;
    const notice_id = if (shaped) notice[notice_head.len .. notice.len - notice_tail.len] else "";
    const channel_page = try getAs(a, io, port, who.tam, channel_url);
    const article_head = try std.fmt.allocPrint(a, "<article class=\"message\" id=\"msg-{s}\"", .{notice_id});
    const article_at = std.mem.indexOf(u8, channel_page.body, article_head);
    const article_end = if (article_at) |at| std.mem.indexOfPos(u8, channel_page.body, at, "</article>") orelse at else 0;
    const linked_post = if (article_at) |at| has(channel_page.body[at..article_end], "Tam in the channel") else false;
    try t.check("Recent's stream: Steve's open Recent page hears the notice of Tam's channel post, as Gopher Chat's Recent did, linked to her post itself, and none of his own", shaped and linked_post);
    // A DM's tile names its other human, Tam, online since she just posted.
    try t.check("Recent's stream: Steve's open Recent page is sent each message's tile, as he sees it, Tam's first, then his own, naming Tam online", live.isEventStream() and
        has(steves.body, "data-stream=\"/chat/recent/stream\"") and
        std.mem.startsWith(u8, first, "event: tile\ndata: <a class=\"recent-tile\" href=\"" ++ channel_url ++ "\">") and
        has(first, "<span class=\"recent-who\">Tam: </span>Tam in the channel") and
        std.mem.startsWith(u8, second, "event: tile\ndata: <a class=\"recent-tile\" href=\"" ++ dm_plans ++ "\" data-person=\"2\" data-presence=\"online\">") and
        has(second, "<span class=\"recent-who\">You: </span>Steve in the DM"));
    // A message in Steve's own DM is a tile on his Recent stream, as any
    // other's is; its notice comes by too, since his own DM tells him.
    const to_self = try postAs(a, io, port, steve_session, self_notes ++ "/send", "markdown=Recent+hears+me");
    const own_tile = try live.expectEvent("event: tile\n", &.{ "event: topic-added\n", "event: message-notice\n" });
    try t.check("Recent's stream: a message in Steve's own DM is sent to his open Recent page as its tile, \"DM with Steve (you)\" by his green dot", to_self.status == 201 and
        std.mem.startsWith(u8, own_tile, "event: tile\ndata: <a class=\"recent-tile\" href=\"" ++ self_notes ++ "\" data-person=\"1\" data-presence=\"online\">") and
        has(own_tile, own_where) and has(own_tile, "<span class=\"recent-who\">You: </span>Recent hears me"));
    try searchSteps(a, io, port, t, .{ .tam = who.tam, .uma = who.uma, .dm_plans = dm_plans });
}

/// Step 59: search, after Recent's posts: each human finds only what they
/// may read, a key is refused, and a burst of searches meets the limit.
fn searchSteps(a: std.mem.Allocator, io: Io, port: u16, t: Steps, who: struct { tam: []const u8, uma: []const u8, dm_plans: []const u8 }) !void {
    const tams_words = try getAs(a, io, port, who.tam, "/chat/search/words?prefix=ST");
    const tams = try getAs(a, io, port, who.tam, "/chat/search/messages?word=steve");
    const umas = try getAs(a, io, port, who.uma, "/chat/search/messages?word=steve");
    const page = try std.fmt.allocPrint(a, "\"page\":\"{s}\"", .{who.dm_plans});
    try t.check("search: Tam is suggested `steve` and finds Steve's message in their DM, marked; Uma, in no DM with Steve, doesn't find it", tams_words.status == 200 and
        has(tams_words.body, "{\"prefix\":\"st\",\"most\":20,\"unreadable\":0,\"words\":[") and has(tams_words.body, "{\"word\":\"steve\",\"count\":") and
        tams.status == 200 and has(tams.body, page) and has(tams.body, "\"mark\":\"Steve\",\"after\":\" in the DM\"") and
        umas.status == 200 and has(umas.body, "\"word\":\"steve\"") and !has(umas.body, page));
    // The searches above filled the index with the DM's topic; a message
    // that lands after is in it at once, its id its transcript's.
    const later = try postAs(a, io, port, who.tam, try std.fmt.allocPrint(a, "{s}/send", .{who.dm_plans}), "markdown=Zanzibar%2C+after+the+search");
    const later_words = try getAs(a, io, port, who.tam, "/chat/search/words?prefix=zan");
    const later_hits = try getAs(a, io, port, who.tam, "/chat/search/messages?word=Zanzibar");
    try t.check("search: a message posted after a search filled the index is found by the next, suggested and marked, under its own id", later.status == 201 and
        has(later_words.body, "\"words\":[{\"word\":\"zanzibar\",\"count\":1}]") and
        has(later_hits.body, "\"matched\":1,") and has(later_hits.body, "\"mark\":\"Zanzibar\",\"after\":\", after the search\"") and
        has(later_hits.body, "\"id\":4,") and has(later_hits.body, "\"from\":\"Tam\""));
    const anonymous = try anonymousGet(a, io, port, "/chat/search/words?prefix=st");
    var refused: usize = 0;
    for (0..16) |_| {
        if ((try getAs(a, io, port, who.uma, "/chat/search/words?prefix=ta")).status == 429) refused += 1;
    }
    try t.check("search: no one is a 401; sixteen searches at once meet the limit of five a second, a 429", anonymous.status == 401 and refused > 0);
    try messageLinkSteps(a, io, port, t, .{ .tam = who.tam, .uma = who.uma });
}

/// Step 60: links to a message, `/chat/msg/<id>`, as Gopher Chat's were. A
/// topic's link goes to the reader's one conversation with that topic, never
/// their own DM; two are a 409, none a 404. A channel's link goes to its
/// topic, and a reader not in the channel is refused as its page refuses
/// them. No one is sent to sign in and back.
fn messageLinkSteps(a: std.mem.Allocator, io: Io, port: u16, t: Steps, who: struct { tam: []const u8, uma: []const u8 }) !void {
    const posts = [_]Response{
        try postAs(a, io, port, steve_session, "/chat/dm/1_2/solo/send", "markdown=Only+here"),
        try postAs(a, io, port, steve_session, "/chat/dm/1_2/trips/send", "markdown=A+trip+in+the+DM"),
        try postAs(a, io, port, steve_session, "/chat/channel/general/trips/send", "markdown=A+trip+in+the+channel"),
        try postAs(a, io, port, steve_session, "/chat/dm/1_1/mine/send", "markdown=Note+to+self"),
    };
    var posted = true;
    for (posts) |sent| posted = posted and sent.status == 201;
    const solo = try getAs(a, io, port, steve_session, "/chat/msg/solo_1");
    const in_channel = try getAs(a, io, port, steve_session, "/chat/msg/general.trips_1");
    const umas = try getAs(a, io, port, who.uma, "/chat/msg/trips_1");
    try t.check("a link to a message: a 302 to it on its topic's page; a topic's link to the one place it means for the reader, a channel's to that channel's topic", posted and
        solo.status == 302 and std.mem.eql(u8, solo.header("location") orelse "", "/chat/dm/1_2/solo#msg-1") and
        in_channel.status == 302 and std.mem.eql(u8, in_channel.header("location") orelse "", "/chat/channel/general/trips#msg-1") and
        umas.status == 302 and std.mem.eql(u8, umas.header("location") orelse "", "/chat/channel/general/trips#msg-1"));
    const steves = try getAs(a, io, port, steve_session, "/chat/msg/trips_1");
    const tams = try getAs(a, io, port, who.tam, "/chat/msg/trips_2");
    try t.check("a topic's link that means two of the reader's conversations: a 409 saying it is ambiguous, sent nowhere, for Steve and for Tam", steves.status == 409 and
        has(steves.body, "This reference is ambiguous") and steves.header("location") == null and tams.status == 409);
    var none_found = true;
    inline for (.{ "/chat/msg/nothing_1", "/chat/msg/general.nothing_1", "/chat/msg/mine_1", "/chat/msg/trips", "/chat/msg/1st.trips_1", "/chat/msg/nowhere.trips_1" }) |path| {
        const answer = try getAs(a, io, port, steve_session, path);
        none_found = none_found and answer.status == 404 and answer.header("location") == null;
    }
    try t.check("a link to no topic of the reader's, to his own DM's (as Gopher's never looked there), of no reference's shape, or to no channel: 404", none_found);
    const refused = try getAs(a, io, port, who.uma, "/chat/msg/crew.trips_1");
    const page = try getAs(a, io, port, who.uma, "/chat/channel/crew/trips");
    const anonymous = try anonymousGet(a, io, port, "/chat/msg/solo_1");
    try t.check("a channel's link for a reader not in it: refused exactly as its page is, a 403; no one: a 303 to sign in, and back to the link", refused.status == 403 and
        page.status == 403 and std.mem.eql(u8, refused.body, page.body) and anonymous.status == 303 and
        std.mem.eql(u8, anonymous.header("location") orelse "", "/login?next=/chat/msg/solo_1"));
}

/// Steps 0a to 0e: Steve's password written, each refusal of a sign-in and
/// of a session, Steve signed in (`steve_session`), and what no one may do.
fn signInSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps) !void {
    const hash = try writePassword(a, io, data);

    // 0a.
    const anonymous = try anonymousGet(a, io, port, channel_url);
    const page = try anonymousGet(a, io, port, "/login?next=" ++ channel_url);
    try t.check("GET the conversation with no session: a 303 to sign in, naming it next; the sign-in page: 200, its form", anonymous.status == 303 and
        std.mem.eql(u8, anonymous.header("location") orelse "", "/login?next=" ++ channel_url) and
        page.status == 200 and has(page.body, "<form method=\"post\" action=\"/login\"><input type=\"hidden\" name=\"next\" value=\"" ++ channel_url ++ "\">") and
        has(page.body, "<input type=\"password\" name=\"password\""));

    // 0b.
    const next_field = "next=%2Fchat%2Fchannel%2Fgeneral%2Froc-chat";
    const wrong = try anonymousPost(a, io, port, "/login", "name=Steve&password=correct+horse+battery+stapler&" ++ next_field);
    const nobody = try anonymousPost(a, io, port, "/login", "name=Nobody&password=correct+horse+battery+staple&" ++ next_field);
    try t.check("sign in with a wrong password, and as no such user: 401 each, the page again, no cookie, never stored", wrong.status == 401 and nobody.status == 401 and
        has(wrong.body, "don&#39;t match") and wrong.header("set-cookie") == null and nobody.header("set-cookie") == null and
        std.mem.eql(u8, wrong.header("cache-control") orelse "", "no-store"));

    // 0c.
    const before = files.current_utc_seconds_since_epoch(io);
    const signed_in = try anonymousPost(a, io, port, "/login", "name=Steve&password=correct+horse+battery+staple&" ++ next_field);
    const cookie = signed_in.header("set-cookie") orelse "";
    const value_end = std.mem.indexOfScalar(u8, cookie, ';') orelse 0;
    const name = "__Host-gopher_auth=";
    const value = if (std.mem.startsWith(u8, cookie, name)) cookie[name.len..value_end] else "";
    try t.check("sign in with the right password: a 303 to next, the session's cookie set for a year, HttpOnly, Secure, SameSite=Lax; never stored", signed_in.status == 303 and
        std.mem.eql(u8, signed_in.header("location") orelse "", channel_url) and
        std.mem.endsWith(u8, cookie, "; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax") and
        std.mem.eql(u8, signed_in.header("cache-control") orelse "", "no-store") and
        try sessionSignedNear(a, io, data, .{ .value = value, .from = before, .password_hash = hash }));

    // 0d.
    const secret = try data.readFileAlloc(io, ".session-secret", a, .limited(256));
    const now = files.current_utc_seconds_since_epoch(io);
    var forged_value = try a.dupe(u8, value);
    // A character in the signature's middle, all of whose bits it uses.
    const flipped = forged_value.len - 5;
    forged_value[flipped] = if (forged_value[flipped] == 'A') 'B' else 'A';
    const refused_cookies = [_][]const u8{
        forged_value,
        try sessionValue(a, secret, .{ .id = "1", .signed_at = now - 365 * 24 * 60 * 60 - 1, .password_hash = hash }),
        try sessionValue(a, secret, .{ .id = "1", .signed_at = now + 5 * 60 + 60, .password_hash = hash }),
        try sessionValue(a, secret, .{ .id = "7", .signed_at = now, .password_hash = hash }),
        try sessionValue(a, secret, .{ .id = "1", .signed_at = now, .password_hash = "" }),
    };
    const transcript_before = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    var refused_all = true;
    for (refused_cookies) |refused| {
        const line = try std.fmt.allocPrint(a, "cookie: {s}{s}\r\n", .{ name, refused });
        const refused_page = try getWith(a, io, port, channel_url, line);
        const refused_post = try exchange(a, io, port, try std.fmt.allocPrint(a, "POST " ++ channel_url ++ " HTTP/1.1\r\nhost: localhost:{d}\r\n{s}content-type: application/x-www-form-urlencoded\r\ncontent-length: 10\r\n\r\nmarkdown=x", .{ port, line }));
        refused_all = refused_all and refused_page.status == 303 and refused_post.status == 401;
    }
    const by_hand = try getWith(a, io, port, channel_url, try std.fmt.allocPrint(a, "cookie: {s}{s}\r\n", .{ name, try sessionValue(a, secret, .{ .id = "1", .signed_at = now, .password_hash = hash }) }));
    try t.check("a forged cookie, an expired one, one ahead of the clock, one for no human, one signed over no hash: the page a 303 to sign in, a message a 401, nothing appended; one signed now over his hash: the page", refused_all and
        by_hand.status == 200 and std.mem.eql(u8, try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024)), transcript_before));

    // 0e.
    const form = "markdown=Not+signed+in";
    const refused_post = try anonymousPost(a, io, port, channel_url, form);
    const refused_send = try anonymousPost(a, io, port, channel_url ++ "/send", form);
    const refused_make = try anonymousPost(a, io, port, "/agents", "name=Rogue");
    const refused_raw = try anonymousGet(a, io, port, channel_url ++ "/raw");
    const refused_agents = try anonymousGet(a, io, port, "/agents");
    var refused_stream = try Stream.openWith(a, io, port, channel_url ++ "/stream?after=0", "");
    defer refused_stream.close();
    const png = try onePixelPng(a);
    const small_upload = try anonymousUpload(a, io, port, try uploadForm(a, "cat.png", png));
    const big = try a.alloc(u8, 64 * 1024 + 1);
    @memset(big, 0);
    @memcpy(big[0..png.len], png);
    const big_upload = try anonymousUpload(a, io, port, try uploadForm(a, "big.png", big));
    try t.check("no session: a message, a send, an agent, /raw, a stream and an upload are 401 each; /agents a 303 to sign in; an upload past a form's room a 413; nothing stored", refused_post.status == 401 and
        refused_send.status == 401 and refused_make.status == 401 and refused_raw.status == 401 and
        std.mem.startsWith(u8, refused_stream.head, "HTTP/1.1 401 ") and small_upload.status == 401 and big_upload.status == 413 and
        refused_agents.status == 303 and std.mem.eql(u8, refused_agents.header("location") orelse "", "/login?next=/agents") and
        has(refused_post.body, "No one is signed in") and !(try exists(io, data, channel_uploads)) and !(try exists(io, data, "auth/2")) and
        std.mem.eql(u8, try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024)), transcript_before));

    // 0f.
    const old_line = try std.fmt.allocPrint(a, "cookie: {s}{s}\r\n", .{ name, value });
    const rewritten = try writePassword(a, io, data);
    const old_page = try getWith(a, io, port, channel_url, old_line);
    const again = try anonymousPost(a, io, port, "/login", "name=Steve&password=correct+horse+battery+staple&" ++ next_field);
    const again_cookie = again.header("set-cookie") orelse "";
    const again_value = if (std.mem.startsWith(u8, again_cookie, name)) again_cookie[name.len .. std.mem.indexOfScalar(u8, again_cookie, ';') orelse name.len] else "";
    const new_page = try getWith(a, io, port, channel_url, try std.fmt.allocPrint(a, "cookie: {s}{s}\r\n", .{ name, again_value }));
    try t.check("Steve's password file rewritten: his old session's page a 303 to sign in; signed in again, the new session's page 200", !std.mem.eql(u8, rewritten, hash) and
        old_page.status == 303 and again.status == 303 and new_page.status == 200 and !std.mem.eql(u8, again_value, value));

    // Every later step of Steve's carries his session, beside another cookie.
    steve_session = try std.fmt.allocPrint(a, "cookie: theme=dark; {s}{s}\r\n", .{ name, again_value });
}

/// Steve's password file written as its owner would write it: a fresh
/// bcrypt hash of `steve_password`, at the cost the server writes, and a
/// line end. Its hash.
fn writePassword(a: std.mem.Allocator, io: Io, data: Io.Dir) ![]const u8 {
    var salt: [std.crypto.pwhash.bcrypt.salt_length]u8 = undefined;
    io.random(&salt);
    const hash_buf = try a.alloc(u8, 60);
    const hash = try std.crypto.pwhash.bcrypt.strHashWithSalt(steve_password, .{
        .params = .{ .rounds_log = 10, .silently_truncate_password = false },
        .encoding = .crypt,
    }, hash_buf[0..60], salt);
    try data.writeFile(io, .{ .sub_path = "auth/1/password", .data = try std.fmt.allocPrint(a, "{s}\n", .{hash}) });
    return hash;
}

/// What a session cookie claims: whose it is, when it was signed, and the
/// hash its human's password file keeps.
const Claim = struct { id: []const u8, signed_at: i64, password_hash: []const u8 };

/// The value of a session cookie for `claim`, signed with `secret`, as
/// app/Session.roc spells one: a second opinion on it, from std's HMAC and
/// base64url.
fn sessionValue(a: std.mem.Allocator, secret: []const u8, claim: Claim) ![]const u8 {
    const id = claim.id;
    const signed_at = claim.signed_at;
    const signed = try std.fmt.allocPrint(a, "{s}\n{d}\n{s}", .{ id, signed_at, claim.password_hash });
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signed, secret);
    const b64 = std.base64.url_safe_no_pad.Encoder;
    const id_text = try a.alloc(u8, b64.calcSize(id.len));
    const mac_text = try a.alloc(u8, b64.calcSize(mac.len));
    return std.fmt.allocPrint(a, "{s}.{d}.{s}", .{ b64.encode(id_text, id), signed_at, b64.encode(mac_text, &mac) });
}

/// Whether `near.value` is Steve's session signed by the server's secret,
/// over `near.password_hash`, at a second from `near.from` to now.
fn sessionSignedNear(a: std.mem.Allocator, io: Io, data: Io.Dir, near: struct { value: []const u8, from: i64, password_hash: []const u8 }) !bool {
    const secret = try data.readFileAlloc(io, ".session-secret", a, .limited(256));
    var second = near.from;
    while (second <= files.current_utc_seconds_since_epoch(io)) : (second += 1) {
        if (std.mem.eql(u8, near.value, try sessionValue(a, secret, .{ .id = "1", .signed_at = second, .password_hash = near.password_hash }))) return true;
    }
    return false;
}

/// A GET of `path` with no credential at all.
fn anonymousGet(a: std.mem.Allocator, io: Io, port: u16, path: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nhost: localhost:{d}\r\n\r\n", .{ path, port }));
}

/// A form POSTed to `path` with no credential at all.
fn anonymousPost(a: std.mem.Allocator, io: Io, port: u16, path: []const u8, form: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nhost: localhost:{d}\r\ncontent-type: application/x-www-form-urlencoded\r\ncontent-length: {d}\r\n\r\n{s}", .{ path, port, form.len, form }));
}

/// An upload of `form` to the channel's conversation with no credential at
/// all.
fn anonymousUpload(a: std.mem.Allocator, io: Io, port: u16, form: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "POST " ++ channel_url ++ "/upload HTTP/1.1\r\nhost: localhost:{d}\r\ncontent-type: " ++ upload_type ++ "\r\ncontent-length: {d}\r\n\r\n{s}", .{ port, form.len, form }));
}

/// Steps 36 to 48: an agent made, invited, redeemed, posting, listening
/// and reading, each refusal, and what is on disk after.
fn agentSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps) !void {
    // 36.
    try t.check("the first start's files: Steve's account, #general's members, the counter of ids", std.mem.eql(u8, try readFile(a, io, data, "auth/1/name"), "Steve") and
        !(try exists(io, data, "auth/1/owner")) and
        std.mem.eql(u8, try readFile(a, io, data, "chat/channel/general.channel"), "1\n") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "2\n"));

    // 37.
    const empty = try get(a, io, port, "/agents");
    try t.check("GET /agents: Steve's page, a form making an agent, no agent yet", empty.status == 200 and
        has(empty.body, "<form method=\"post\" action=\"/agents\"><textarea name=\"name\" required></textarea>") and !has(empty.body, "<h1>"));

    // 38.
    const made = try post(a, io, port, .{ .path = "/agents", .form = "name=CC" });
    try t.check("POST /agents name=CC: 303 to /agents; CC's account on disk, Steve's; the counter at 3", made.status == 303 and
        std.mem.eql(u8, made.header("location") orelse "", "/agents") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/2/name"), "CC") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/2/owner"), "1") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "3\n"));
    try data.writeFile(io, .{ .sub_path = "chat/channel/general.channel", .data = "1\n2\n" });
    try data.writeFile(io, .{ .sub_path = "chat/channel/private.channel", .data = "1\n" });
    const listed = try get(a, io, port, "/agents");
    try t.check("Steve adds CC to #general by its members file; /agents lists CC with its invite button", listed.status == 200 and
        has(listed.body, "<h1>CC (id 2)</h1>") and has(listed.body, "action=\"/agents/2/invites\""));

    // 39.
    const invited = try post(a, io, port, .{ .path = "/agents/2/invites", .form = "" });
    const code = between(invited.body, "<p class=\"invite-code\">", "</p>") orelse "";
    const redeemed = try anonymousPost(a, io, port, "/agents/redeem", try std.fmt.allocPrint(a, "code={s}", .{code}));
    const key = std.mem.trimEnd(u8, redeemed.body, "\n");
    const again = try anonymousPost(a, io, port, "/agents/redeem", try std.fmt.allocPrint(a, "code={s}", .{code}));
    try t.check("invite CC: its code shown once, never stored; redeemed with no credential: 200, the key on one line, `2-` and 64 hex digits, never stored; redeemed again: 401", invited.status == 200 and
        std.mem.eql(u8, invited.header("cache-control") orelse "", "no-store") and
        isToken(code, "2-") and redeemed.status == 200 and isToken(key, "2-") and !std.mem.eql(u8, key, code) and
        std.mem.eql(u8, redeemed.header("content-type") orelse "", "text/plain; charset=utf-8") and
        std.mem.eql(u8, redeemed.header("cache-control") orelse "", "no-store") and
        again.status == 401 and std.mem.eql(u8, again.body, "The invite code is not live.\n"));
    const bearer = try std.fmt.allocPrint(a, "authorization: Bearer {s}\r\n", .{key});

    // 40.
    const second = try post(a, io, port, .{ .path = "/agents/2/invites", .form = "" });
    const late_code = between(second.body, "<p class=\"invite-code\">", "</p>") orelse "";
    try data.writeFile(io, .{ .sub_path = "auth/2/invites/2/expires", .data = "1000" });
    const late = try anonymousPost(a, io, port, "/agents/redeem", try std.fmt.allocPrint(a, "code={s}", .{late_code}));
    try t.check("an invite past its expiry (its file set back): 401, and it is still live on disk", isToken(late_code, "2-") and late.status == 401 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/2/invites/2/state"), "live"));

    // 41.
    var listening = try Stream.openWith(a, io, port, "/agents/stream", bearer);
    defer listening.close();
    var by_session = try Stream.openWith(a, io, port, "/agents/stream", "");
    defer by_session.close();
    try t.check("CC's stream, opened with its key: a 200 event stream; asked for with no key: 403", listening.isEventStream() and
        std.mem.startsWith(u8, by_session.head, "HTTP/1.1 403 "));

    // 42.
    const before_cc = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    const cc_posted = try post(a, io, port, .{ .path = channel_url, .form = "markdown=Hello+from+CC", .more = bearer });
    const after_cc = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    const added = after_cc[@min(before_cc.len, after_cc.len)..];
    const cc_event = try listening.event();
    try t.check("POST as CC with its key: 303; the record on disk is CC's", cc_posted.status == 303 and
        std.mem.startsWith(u8, added, "-------------\nMSG_roc-chat_13\nfrom: CC\ndate: ") and std.mem.endsWith(u8, added, "\n\nHello from CC\n\n"));
    try t.check("CC's stream: that message, one line of JSON, its author's id beside the name", std.mem.startsWith(u8, cc_event, "data: {\"conversation\":\"" ++ channel_url ++ "\",\"id\":13,\"from\":\"CC\",\"from_id\":2,\"date\":\"") and
        std.mem.endsWith(u8, cc_event, "\",\"markdown\":\"Hello from CC\"}\n\n"));

    // 43.
    const in_private = try post(a, io, port, .{ .path = "/chat/channel/private/secrets", .form = "markdown=Not+for+CC" });
    const in_general = try post(a, io, port, .{ .path = channel_url, .form = "markdown=For+CC+too" });
    const next_event = try listening.event();
    const cc_private = try post(a, io, port, .{ .path = "/chat/channel/private/secrets", .form = "markdown=Let+me+in", .more = bearer });
    const cc_private_read = try getWith(a, io, port, "/chat/channel/private/secrets/raw", bearer);
    try t.check("Steve posts in #private, then #general: CC's next event is #general's, none of #private's", in_private.status == 303 and in_general.status == 303 and
        std.mem.startsWith(u8, next_event, "data: {\"conversation\":\"" ++ channel_url ++ "\",\"id\":14,\"from\":\"Steve\",\"from_id\":1,") and
        has(next_event, "\"markdown\":\"For CC too\"") and !has(next_event, "Not for CC"));
    try t.check("CC's key posting to, or reading, #private, which CC is not in: 403 each", cc_private.status == 403 and cc_private_read.status == 403);

    // 44.
    const date = between(cc_event, "\"date\":\"", "\"") orelse "";
    var caught_up = try Stream.openWith(a, io, port, try std.fmt.allocPrint(a, "/agents/stream?since={s}", .{date}), bearer);
    defer caught_up.close();
    // Messages of the same second that came before CC's come first; then
    // CC's, then #general's next, and never #private's.
    var caught: std.ArrayList([]const u8) = .empty;
    while (caught.items.len < 12) {
        const event = try caught_up.event();
        try caught.append(a, event);
        if (std.mem.eql(u8, event, next_event)) break;
    }
    var at_cc: ?usize = null;
    var private_seen = false;
    for (caught.items, 0..) |event, i| {
        if (std.mem.eql(u8, event, cc_event)) at_cc = i;
        if (has(event, "Not for CC")) private_seen = true;
    }
    try t.check("a stream since CC's message's date: CC's message, then #general's next, none of #private's", caught_up.isEventStream() and
        at_cc != null and at_cc.? + 2 == caught.items.len and std.mem.eql(u8, caught.items[caught.items.len - 1], next_event) and !private_seen);

    // 45.
    const raw = try getWith(a, io, port, channel_url ++ "/raw", bearer);
    try t.check("GET /raw with the key: 200, plain text, exactly the transcript's bytes", raw.status == 200 and
        std.mem.eql(u8, raw.header("content-type") orelse "", "text/plain; charset=utf-8") and
        std.mem.eql(u8, raw.body, try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024))));

    // 46.
    const zeros: [64]u8 = @splat('0');
    const wrong = try std.fmt.allocPrint(a, "authorization: Bearer 2-{s}\r\n", .{&zeros});
    const by_wrong = try getWith(a, io, port, channel_url ++ "/raw", wrong);
    const by_malformed = try getWith(a, io, port, channel_url ++ "/raw", "authorization: Bearer 2-xyz\r\n");
    const key_makes = try post(a, io, port, .{ .path = "/agents", .form = "name=Rogue", .more = bearer });
    const key_invites = try post(a, io, port, .{ .path = "/agents/2/invites", .form = "", .more = bearer });
    const key_redeems = try post(a, io, port, .{ .path = "/agents/redeem", .form = try std.fmt.allocPrint(a, "code={s}", .{late_code}), .more = bearer });
    const key_lists = try getWith(a, io, port, "/agents", bearer);
    try t.check("a wrong secret and a malformed bearer: 401 each", by_wrong.status == 401 and by_malformed.status == 401);
    try t.check("a key making an agent, inviting, redeeming, listing: 403 each; nothing made", key_makes.status == 403 and key_invites.status == 403 and
        key_redeems.status == 403 and key_lists.status == 403 and !(try exists(io, data, "auth/3")) and
        !(try exists(io, data, "auth/2/invites/3")) and !(try exists(io, data, "auth/2/keys/2")));

    // 46a.
    const scoped = try post(a, io, port, .{ .path = "/agents/2/invites", .form = "read=off&post=off" });
    const scoped_code = between(scoped.body, "<p class=\"invite-code\">", "</p>") orelse "";
    const scoped_key = std.mem.trimEnd(u8, (try anonymousPost(a, io, port, "/agents/redeem", try std.fmt.allocPrint(a, "code={s}", .{scoped_code}))).body, "\n");
    const scoped_bearer = try std.fmt.allocPrint(a, "authorization: Bearer {s}\r\n", .{scoped_key});
    const scoped_read = try getWith(a, io, port, channel_url ++ "/raw", scoped_bearer);
    const scoped_post = try post(a, io, port, .{ .path = channel_url, .form = "markdown=Scoped", .more = scoped_bearer });
    var scoped_stream = try Stream.openWith(a, io, port, "/agents/stream", scoped_bearer);
    defer scoped_stream.close();
    try t.check("a key invited with read=off and post=off: reading, posting and listening are 403 each", isToken(scoped_key, "2-") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/2/keys/2/read"), "off") and
        scoped_read.status == 403 and scoped_post.status == 403 and std.mem.startsWith(u8, scoped_stream.head, "HTTP/1.1 403 "));

    // 47.
    const revoking = Io.Clock.now(.awake, io);
    const revoked = try post(a, io, port, .{ .path = "/agents/2/keys/1/revoke", .form = "" });
    const stream_ended = if (listening.event()) |_| false else |e| e == error.EndOfStream;
    const ended_ms = revoking.untilNow(io, .awake).toMilliseconds();
    const after_revoke = try getWith(a, io, port, channel_url ++ "/raw", bearer);
    try t.check("revoke the key: 303; CC's open stream ended at once; the key is then a 401; its state on disk revoked", revoked.status == 303 and
        stream_ended and ended_ms < Stream.wait_ms / 2 and after_revoke.status == 401 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/2/keys/1/state"), "revoked"));

    // 48.
    const secret_hex = key["2-".len..];
    var secret: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, secret_hex);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&secret, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const kept = try readFile(a, io, data, "auth/2/keys/1/hash");
    var secrets_on_disk: usize = 0;
    var on_disk: std.ArrayList([]const u8) = .empty;
    try allFiles(a, io, data, "", &on_disk);
    for (on_disk.items) |path| {
        const bytes = try data.readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
        for ([_][]const u8{ secret_hex, scoped_key["2-".len..], code["2-".len..], late_code["2-".len..], scoped_code["2-".len..] }) |hex| {
            if (has(bytes, hex)) secrets_on_disk += 1;
        }
    }
    try t.check("on disk: the key's hash is SHA-256 of its secret; no file holds the secret or a code", std.mem.eql(u8, kept, &digest_hex) and
        on_disk.items.len > 10 and secrets_on_disk == 0);
}

/// Steps 48a to 48g: a channel created, an agent added to it and removed
/// on its page, what the agent may do either side, and each refusal.
/// It gives back CC's key's `Authorization` line, which the invites' steps
/// use.
fn memberSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps) ![]const u8 {
    // 48a.
    const listed = try get(a, io, port, "/channels");
    try t.check("GET /channels: Steve's page, each channel linked, a form that creates one", listed.status == 200 and
        has(listed.body, "<a href=\"/channels/general\">#general</a>") and has(listed.body, "<a href=\"/channels/private\">#private</a>") and
        has(listed.body, "<form method=\"post\" action=\"/channels\">"));

    // 48b.
    const created = try post(a, io, port, .{ .path = "/channels", .form = "name=crew" });
    const taken = try post(a, io, port, .{ .path = "/channels", .form = "name=CREW" });
    try t.check("create #crew: 303 to its page, its members file on disk, empty; the name again in any case: 409", created.status == 303 and
        std.mem.eql(u8, created.header("location") orelse "", "/channels/crew") and
        std.mem.eql(u8, try readFile(a, io, data, "chat/channel/crew.channel"), "") and taken.status == 409);

    // 48c.
    const page = try get(a, io, port, "/channels/crew");
    try t.check("GET /channels/crew: no members, a button adding CC", page.status == 200 and has(page.body, "Members: 0.") and
        has(page.body, "<form method=\"post\" action=\"/channels/crew/members/2/add\"><button>Add CC (agent, id 2)</button></form>"));

    // 48d.
    const invited = try post(a, io, port, .{ .path = "/agents/2/invites", .form = "" });
    const code = between(invited.body, "<p class=\"invite-code\">", "</p>") orelse "";
    const key = std.mem.trimEnd(u8, (try anonymousPost(a, io, port, "/agents/redeem", try std.fmt.allocPrint(a, "code={s}", .{code}))).body, "\n");
    const bearer = try std.fmt.allocPrint(a, "authorization: Bearer {s}\r\n", .{key});
    const crew_url = "/chat/channel/crew/plans";
    const before = try post(a, io, port, .{ .path = crew_url, .form = "markdown=Before", .more = bearer });
    const added = try post(a, io, port, .{ .path = "/channels/crew/members/2/add", .form = "" });
    const twice = try post(a, io, port, .{ .path = "/channels/crew/members/2/add", .form = "" });
    const nobody = try post(a, io, port, .{ .path = "/channels/crew/members/99/add", .form = "" });
    const cc_post = try post(a, io, port, .{ .path = crew_url, .form = "markdown=CC+on+the+crew", .more = bearer });
    const cc_read = try getWith(a, io, port, crew_url ++ "/raw", bearer);
    try t.check("CC's key posting in #crew before it is a member: 403", isToken(key, "2-") and before.status == 403);
    try t.check("add CC to #crew: 303 to its page, the members file `2`; again: 409; no such user: 404", added.status == 303 and
        std.mem.eql(u8, added.header("location") orelse "", "/channels/crew") and
        std.mem.eql(u8, try readFile(a, io, data, "chat/channel/crew.channel"), "2\n") and twice.status == 409 and nobody.status == 404);
    try t.check("CC, a member now, posts in #crew and reads it: 303, then 200 holding its message", cc_post.status == 303 and
        cc_read.status == 200 and has(cc_read.body, "from: CC") and has(cc_read.body, "CC on the crew"));

    // 48e.
    var listening = try Stream.openWith(a, io, port, "/agents/stream", bearer);
    defer listening.close();
    const removing = Io.Clock.now(.awake, io);
    const removed = try post(a, io, port, .{ .path = "/channels/crew/members/2/remove", .form = "" });
    const stream_ended = if (listening.event()) |_| false else |e| e == error.EndOfStream;
    const ended_ms = removing.untilNow(io, .awake).toMilliseconds();
    const not_in = try post(a, io, port, .{ .path = "/channels/crew/members/2/remove", .form = "" });
    const after_post = try post(a, io, port, .{ .path = crew_url, .form = "markdown=Still+here%3F", .more = bearer });
    const after_read = try getWith(a, io, port, crew_url ++ "/raw", bearer);
    try t.check("remove CC from #crew: 303, the members file empty, CC's open stream ended at once; again: 409", listening.isEventStream() and
        removed.status == 303 and std.mem.eql(u8, try readFile(a, io, data, "chat/channel/crew.channel"), "") and
        stream_ended and ended_ms < Stream.wait_ms / 2 and not_in.status == 409);
    try t.check("CC, removed, posting in #crew and reading it: 403 each; its account stands", after_post.status == 403 and after_read.status == 403 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/2/name"), "CC"));

    // 48f.
    const key_lists = try getWith(a, io, port, "/channels", bearer);
    const key_creates = try post(a, io, port, .{ .path = "/channels", .form = "name=keyed", .more = bearer });
    const key_adds = try post(a, io, port, .{ .path = "/channels/crew/members/2/add", .form = "", .more = bearer });
    const anon_page = try anonymousGet(a, io, port, "/channels/crew");
    const anon_adds = try anonymousPost(a, io, port, "/channels/crew/members/2/add", "");
    try t.check("CC's key listing, creating or adding: 403 each; no one: the page a 303 to sign in, an add a 401; nothing changed", key_lists.status == 403 and
        key_creates.status == 403 and key_adds.status == 403 and anon_page.status == 303 and anon_adds.status == 401 and
        !(try exists(io, data, "chat/channel/keyed.channel")) and
        std.mem.eql(u8, try readFile(a, io, data, "chat/channel/crew.channel"), ""));

    // 48g.
    const evil = "origin: http://evil.example\r\n";
    const cross = "sec-fetch-site: cross-site\r\n";
    const forged_create = try post(a, io, port, .{ .path = "/channels", .form = "name=forged", .more = evil });
    const forged_add = try post(a, io, port, .{ .path = "/channels/crew/members/2/add", .form = "", .more = evil });
    const cross_add = try post(a, io, port, .{ .path = "/channels/crew/members/2/add", .form = "", .more = cross });
    const forged_remove = try post(a, io, port, .{ .path = "/channels/general/members/1/remove", .form = "", .more = evil });
    try t.check("a cross-site form post creating, adding or removing: 403 each; nothing changed", forged_create.status == 403 and
        forged_add.status == 403 and cross_add.status == 403 and forged_remove.status == 403 and
        !(try exists(io, data, "chat/channel/forged.channel")) and
        std.mem.eql(u8, try readFile(a, io, data, "chat/channel/crew.channel"), "") and
        std.mem.eql(u8, try readFile(a, io, data, "chat/channel/general.channel"), "1\n2\n"));
    return bearer;
}

/// Steps 48h to 48r: a human invited by name and redeemed with a password,
/// signing in and posting; each refusal of a redemption; an invite again;
/// the cap; and what a key, no one and another site may not do.
fn inviteSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps, cc_bearer: []const u8) !void {
    // 48h.
    const page = try get(a, io, port, "/invites");
    try t.check("GET /invites: Steve's page, a form inviting someone by name, in the card; nothing open, nothing past, and that GitHub signs people up too", page.status == 200 and has(page.body, "<div class=\"panel\">") and
        has(page.body, "<form method=\"post\" action=\"/invites\"><p>Their name <input type=\"text\" name=\"name\" required></p>") and
        has(page.body, "<p>No open invites.</p>") and !has(page.body, "Past invites") and has(page.body, "anyone with GitHub can sign up on their own"));

    // 48i.
    const invited = try post(a, io, port, .{ .path = "/invites", .form = "name=Deb" });
    const link = between(invited.body, "<p class=\"invite-code\">", "</p>") orelse "";
    const link_start = try std.fmt.allocPrint(a, "http://localhost:{d}/join#", .{port});
    const code = if (std.mem.startsWith(u8, link, link_start)) link[link_start.len..] else "";
    const created = try std.fmt.parseInt(i64, try readFile(a, io, data, "auth/3/human-invites/1/created"), 10);
    const expires = try std.fmt.parseInt(i64, try readFile(a, io, data, "auth/3/human-invites/1/expires"), 10);
    try t.check("invite Deb: 200, the link that joins by her code, http://localhost:<port>/join#<code>, shown once, never stored; her account holds the name at once, inviter Steve, no password; the invite live, by Steve, seven days", invited.status == 200 and
        std.mem.eql(u8, invited.header("cache-control") orelse "", "no-store") and isToken(code, "3-") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/name"), "Deb") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/inviter"), "1") and
        !(try exists(io, data, "auth/3/password")) and !(try exists(io, data, "auth/3/owner")) and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/human-invites/1/state"), "live") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/human-invites/1/by"), "1") and
        expires - created == 7 * 24 * 60 * 60 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "4\n"));
    try t.check("her account starts in #general", std.mem.eql(u8, try readFile(a, io, data, "chat/channel/general.channel"), "1\n2\n3\n"));
    const taken = try post(a, io, port, .{ .path = "/invites", .form = "name=DEB" });
    const unready = try anonymousPost(a, io, port, "/login", "name=Deb&password=anything");
    try t.check("her name again in any case: 409, the invites page again, saying why, with no link; signing in as her before she joins: 401", taken.status == 409 and
        has(taken.body, "value=\"DEB\"></p>\n<button>Invite someone</button></form><p class=\"problem\">The name is taken.</p>") and has(taken.body, "action=\"/invites\"") and has(taken.body, browse_link) and !has(taken.body, "invite-code") and
        unready.status == 401);
    const open_page = try get(a, io, port, "/invites");
    try t.check("her invite on the page: open, by Steve, the reader, so no maker said, and a button to invite her again; no link", has(open_page.body, "<h1>Open invites</h1>") and
        has(open_page.body, "<p>Deb hasn&#39;t joined · link expires ") and has(open_page.body, " (in 7 days)</p>") and !has(open_page.body, "made by") and has(open_page.body, "action=\"/invites/3/again\"") and
        !has(open_page.body, "invite-code") and !has(open_page.body, "No open invites."));

    // 48j.
    const join_page = try anonymousGet(a, io, port, "/join");
    const join_script = try anonymousGet(a, io, port, "/chat/assets/join.js");
    try t.check("GET /join, signed in by no one: 200, a form posting a hidden code, a name and a new password, and the script that reads the code from the link", join_page.status == 200 and
        has(join_page.body, "<form method=\"post\" action=\"/join\"><input type=\"hidden\" name=\"code\">") and
        has(join_page.body, "name=\"name\" autocomplete=\"username\" required") and
        has(join_page.body, "name=\"password\" autocomplete=\"new-password\" required") and
        has(join_page.body, "<script src=\"/chat/assets/join.js\"></script>") and
        join_script.status == 200 and has(join_script.body, "location.hash") and has(join_script.body, "\"/join/name\""));
    const code_form = try std.fmt.allocPrint(a, "code={s}", .{code});
    const looked_up = try anonymousPost(a, io, port, "/join/name", code_form);
    try t.check("POST /join/name with her code: 200, the name the invite holds, as JSON, never stored", looked_up.status == 200 and
        std.mem.eql(u8, looked_up.body, "{\"name\":\"Deb\"}") and
        std.mem.eql(u8, looked_up.header("content-type") orelse "", "application/json") and
        std.mem.eql(u8, looked_up.header("cache-control") orelse "", "no-store"));
    const taken_name = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=steve&password=x", .{code}));
    const no_name = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Deb%21&password=x", .{code}));
    const no_password = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Debbie&password=", .{code}));
    try t.check("join under a name taken in any case: 409; under a name that is no name: 400; with no password: 400; each spends nothing, her name and invite as they were", taken_name.status == 409 and
        no_name.status == 400 and no_password.status == 400 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/human-invites/1/state"), "live") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/name"), "Deb") and !(try exists(io, data, "auth/3/password")));
    const debbie_password = "debbie's own secret";
    const redeemed = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Debbie&password=debbie%27s+own+secret", .{code}));
    const hash = try readFile(a, io, data, "auth/3/password");
    try t.check("she joins as Debbie, not Deb: a 303 to her DM with the owner and her session's cookie, never stored; her name now Debbie; the invite spent; her password's bcrypt hash, cost 10, on disk", redeemed.status == 303 and
        std.mem.eql(u8, redeemed.header("location") orelse "", "/chat/dm/1_3/ChitChat") and
        std.mem.startsWith(u8, redeemed.header("set-cookie") orelse "", "__Host-gopher_auth=") and
        std.mem.eql(u8, redeemed.header("cache-control") orelse "", "no-store") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/name"), "Debbie") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/human-invites/1/state"), "spent") and
        std.mem.startsWith(u8, hash, "$2b$10$") and hash.len == 60 and !has(hash, debbie_password));
    // Debbie invites many in the steps after; her first day is set back, so
    // the first day's limit on invites (48zt6 tests it) doesn't stop them.
    try data.writeFile(io, .{ .sub_path = "auth/3/joined", .data = "1000" });
    const joined_page = try getAs(a, io, port, try cookieLine(a, redeemed), "/invites");
    const first_page = try getAs(a, io, port, try cookieLine(a, redeemed), redeemed.header("location") orelse "");
    try t.check("the session joining started: her first page, 200, the owner's welcome; her own /invites, 200, signed in as Debbie", first_page.status == 200 and
        has(first_page.body, "If Steve is not here") and joined_page.status == 200 and has(joined_page.body, "Debbie"));
    const again = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Debbie&password=another", .{code}));
    const again_name = try anonymousPost(a, io, port, "/join/name", code_form);
    const old_route = try anonymousPost(a, io, port, "/invites/redeem", try std.fmt.allocPrint(a, "code={s}&password=another", .{code}));
    try t.check("her code again, to join or for its name: 401 each, her password unchanged; /invites/redeem: 404", again.status == 401 and
        again_name.status == 401 and old_route.status == 404 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/password"), hash));

    // 48k.
    const signed_in = try anonymousPost(a, io, port, "/login", "name=Debbie&password=debbie%27s+own+secret");
    const debbie = try cookieLine(a, signed_in);
    const her_page = try getAs(a, io, port, debbie, "/invites");
    const her_add = try postAs(a, io, port, debbie, "/channels/crew/members/3/add", "");
    const her_list = try getAs(a, io, port, debbie, "/channels");
    const steve_adds = try post(a, io, port, .{ .path = "/channels/crew/members/3/add", .form = "" });
    const her_post = try postAs(a, io, port, debbie, "/chat/channel/crew/plans", "markdown=Hello+from+Debbie");
    const crew = try readFile(a, io, data, "chat/channel/crew/plans/transcript");
    try t.check("Debbie signs in with her password: 303; her own /invites, 200", signed_in.status == 303 and debbie.len > 0 and her_page.status == 200);
    try t.check("Debbie, no admin, adding a member or listing channels: 403 each", her_add.status == 403 and her_list.status == 403);
    try t.check("Steve adds Debbie to #crew; she posts there: 303, the record hers", steve_adds.status == 303 and her_post.status == 303 and
        std.mem.eql(u8, try readFile(a, io, data, "chat/channel/crew.channel"), "3\n") and
        has(crew, "\nfrom: Debbie\n") and has(crew, "\n\nHello from Debbie\n\n"));

    // 48l.
    const deb = try post(a, io, port, .{ .path = "/invites", .form = "name=Deb" });
    const deb_link = between(deb.body, "<p class=\"invite-code\">", "</p>") orelse "";
    const deb_code = if (std.mem.startsWith(u8, deb_link, link_start)) deb_link[link_start.len..] else "";
    try t.check("Deb, the name Debbie left, is free again: Steve invites her, 200, a new account 4 holding it", isToken(deb_code, "4-") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/4/name"), "Deb"));
    try data.writeFile(io, .{ .sub_path = "auth/4/human-invites/1/expires", .data = "1000" });
    const late = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Deb&password=debs", .{deb_code}));
    const late_name = try anonymousPost(a, io, port, "/join/name", try std.fmt.allocPrint(a, "code={s}", .{deb_code}));
    const wrong_user = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code=2-{s}&name=Deb&password=debs", .{deb_code["4-".len..]}));
    try t.check("an invite past its expiry (its file set back), to join or for its name: 401 each, still live, no password made; its secret under another id: 401", late.status == 401 and
        late_name.status == 401 and wrong_user.status == 401 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/4/human-invites/1/state"), "live") and !(try exists(io, data, "auth/4/password")));
    const standing_page = try get(a, io, port, "/invites");
    try t.check("on the page, Deb's invite past its expiry: expired, not open; Debbie's spent one: used; both past", has(standing_page.body, "<h1>Past invites</h1>") and
        has(standing_page.body, "<p>Deb&#39;s link expired Jan 1, 1970 (") and has(standing_page.body, "<p>No open invites.</p>") and
        !has(standing_page.body, "link expires") and has(standing_page.body, "<p>Debbie joined</p>"));

    // 48m.
    const reinvited = try post(a, io, port, .{ .path = "/invites/3/again", .form = "" });
    const re_link = between(reinvited.body, "<p class=\"invite-code\">", "</p>") orelse "";
    const re_code = if (std.mem.startsWith(u8, re_link, link_start)) re_link[link_start.len..] else "";
    const signed_in_join = try postAs(a, io, port, debbie, "/join", try std.fmt.allocPrint(a, "code={s}&name=Debbie&password=a+new+one", .{re_code}));
    const signed_in_name = try postAs(a, io, port, debbie, "/join/name", try std.fmt.allocPrint(a, "code={s}", .{re_code}));
    const renamed_again = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Debra&password=a+new+one", .{re_code}));
    try t.check("a browser signed in already, joining or asking the name: 409 each; joining again under another name than the one she chose: 409; the invite still live, her name Debbie", signed_in_join.status == 409 and
        signed_in_name.status == 409 and renamed_again.status == 409 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/human-invites/2/state"), "live") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/name"), "Debbie"));
    const re_redeemed = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Debbie&password=a+new+one", .{re_code}));
    const old_password = try anonymousPost(a, io, port, "/login", "name=Debbie&password=debbie%27s+own+secret");
    const new_password = try anonymousPost(a, io, port, "/login", "name=Debbie&password=a+new+one");
    try t.check("Steve invites Debbie again: 200, a new code for the same account, invite 2, by Steve; redeemed with a new password: 303", reinvited.status == 200 and
        isToken(re_code, "3-") and !std.mem.eql(u8, re_code, code) and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/human-invites/2/by"), "1") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/name"), "Debbie") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "5\n") and re_redeemed.status == 303);
    try t.check("then her old password: 401; her new one: 303", old_password.status == 401 and new_password.status == 303);
    const old_session = try getAs(a, io, port, debbie, "/invites");
    const redeemed_session = try getAs(a, io, port, try cookieLine(a, re_redeemed), "/invites");
    try t.check("her session from before the redemption: its page a 303 to sign in; the redemption's own session: 200", old_session.status == 303 and
        std.mem.startsWith(u8, old_session.header("location") orelse "", "/login") and redeemed_session.status == 200);
    const her_again = try postAs(a, io, port, try cookieLine(a, new_password), "/invites/4/again", "");
    const founder_again = try post(a, io, port, .{ .path = "/invites/1/again", .form = "" });
    const agent_again = try post(a, io, port, .{ .path = "/invites/2/again", .form = "" });
    try t.check("Debbie inviting Deb again, whom Steve invited: 403; Steve inviting the founder again, whom no one invited: 403; an agent: 404", her_again.status == 403 and
        founder_again.status == 403 and agent_again.status == 404 and !(try exists(io, data, "auth/1/human-invites")));

    // 48n.
    var capped_ok = true;
    for (0..10) |_| {
        const one = try post(a, io, port, .{ .path = "/invites/4/again", .form = "" });
        capped_ok = capped_ok and one.status == 200;
    }
    const eleventh = try post(a, io, port, .{ .path = "/invites/4/again", .form = "" });
    const new_one = try post(a, io, port, .{ .path = "/invites", .form = "name=Fay" });
    try t.check("ten open invites of Steve's: each 200; an eleventh, again or new: 403 each, nothing made", capped_ok and eleventh.status == 403 and
        new_one.status == 403 and (try exists(io, data, "auth/4/human-invites/11")) and
        !(try exists(io, data, "auth/4/human-invites/12")) and !(try exists(io, data, "auth/5")));

    // 48o.
    const key_invites = try post(a, io, port, .{ .path = "/invites", .form = "name=Gus", .more = cc_bearer });
    const key_redeems = try post(a, io, port, .{ .path = "/join", .form = try std.fmt.allocPrint(a, "code={s}&name=Deb&password=x", .{deb_code}), .more = cc_bearer });
    const key_names = try post(a, io, port, .{ .path = "/join/name", .form = try std.fmt.allocPrint(a, "code={s}", .{deb_code}), .more = cc_bearer });
    const anon_page = try anonymousGet(a, io, port, "/invites");
    const anon_invites = try anonymousPost(a, io, port, "/invites", "name=Gus");
    try t.check("CC's key inviting, joining or asking the name: 403 each; no one: /invites a 303 to sign in, an invite a 401; nothing made", key_invites.status == 403 and
        key_redeems.status == 403 and key_names.status == 403 and anon_page.status == 303 and anon_invites.status == 401 and !(try exists(io, data, "auth/5")));

    // 48p.
    const evil = "origin: http://evil.example\r\n";
    const forged_invite = try post(a, io, port, .{ .path = "/invites", .form = "name=Gus", .more = evil });
    const forged_again = try post(a, io, port, .{ .path = "/invites/3/again", .form = "", .more = evil });
    const forged_redeem = try exchange(a, io, port, try std.fmt.allocPrint(a, "POST /join HTTP/1.1\r\nhost: localhost:{d}\r\n{s}content-type: application/x-www-form-urlencoded\r\ncontent-length: {d}\r\n\r\ncode={s}&password=x", .{ port, evil, "code=&password=x".len + re_code.len, re_code }));
    const cross_redeem = try exchange(a, io, port, try std.fmt.allocPrint(a, "POST /join HTTP/1.1\r\nhost: localhost:{d}\r\nsec-fetch-site: cross-site\r\ncontent-type: application/x-www-form-urlencoded\r\ncontent-length: 16\r\n\r\ncode=&password=x", .{port}));
    try t.check("a cross-site form post inviting, inviting again or joining: 403 each; nothing made", forged_invite.status == 403 and
        forged_again.status == 403 and forged_redeem.status == 403 and cross_redeem.status == 403 and
        !(try exists(io, data, "auth/5")) and !(try exists(io, data, "auth/3/human-invites/3")));

    // 48q.
    var on_disk: std.ArrayList([]const u8) = .empty;
    try allFiles(a, io, data, "", &on_disk);
    var secrets_on_disk: usize = 0;
    for (on_disk.items) |path| {
        const bytes = try data.readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
        for ([_][]const u8{ code[2..], deb_code[2..], re_code[2..], debbie_password, "a new one" }) |secret| {
            if (has(bytes, secret)) secrets_on_disk += 1;
        }
    }
    try t.check("on disk: no file holds an invite's code or a password", secrets_on_disk == 0);
}

/// The `.github-` files that point the server at `fake`, as its owner would
/// write GitHub's own: readable by them alone.
fn writeGitHubSettings(io: Io, data: Io.Dir, fake: *fake_github.Fake) !void {
    const settings = [_][2][]const u8{
        .{ github.client_id_name, fake_github.client_id ++ "\n" },
        .{ github.client_secret_name, fake_github.client_secret ++ "\n" },
        .{ github.oauth_base_name, fake.base() },
        .{ github.api_base_name, fake.base() },
    };
    for (settings) |s| try data.writeFile(io, .{ .sub_path = s[0], .data = s[1], .flags = .{ .permissions = .fromMode(0o600) } });
}

/// A sign-in begun by a browser with no session: the `Cookie` line it holds
/// now, GitHub's page on the fake, and the state.
const GitHubStart = struct { cookie: []const u8, authorize: []const u8, state: []const u8 };

fn startGitHub(a: std.mem.Allocator, io: Io, port: u16, fake: *fake_github.Fake) !GitHubStart {
    return startGitHubTo(a, io, port, fake, channel_url);
}

/// The same, going to `next` after.
fn startGitHubTo(a: std.mem.Allocator, io: Io, port: u16, fake: *fake_github.Fake, next: []const u8) !GitHubStart {
    const started = try anonymousGet(a, io, port, try std.fmt.allocPrint(a, "/login/github/start?next={s}", .{next}));
    const location = started.header("location") orelse return error.NoLocation;
    if (!std.mem.startsWith(u8, location, fake.base())) return error.NotTheFake;
    const at = std.mem.indexOf(u8, location, "&state=") orelse return error.NoState;
    return .{ .cookie = try cookieLine(a, started), .authorize = location[fake.base().len..], .state = location[at + "&state=".len ..] };
}

/// The browser at the fake's page: its human agreeing, GitHub's code `code`,
/// or saying no, for none. Where it is sent back to on this server.
fn atGitHub(a: std.mem.Allocator, io: Io, port: u16, fake: *fake_github.Fake, at: struct { authorize: []const u8, code: ?[]const u8 }) ![]const u8 {
    const target = if (at.code) |code| try std.fmt.allocPrint(a, "{s}&as={s}", .{ at.authorize, code }) else at.authorize;
    const answer = try exchange(a, io, fake.port, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", .{target}));
    const location = answer.header("location") orelse return error.NoLocation;
    const here = try std.fmt.allocPrint(a, "http://localhost:{d}", .{port});
    if (!std.mem.startsWith(u8, location, here)) return error.NotThisServer;
    return location[here.len..];
}

/// The browser sent back to `path`, as GitHub's redirect brings it: a
/// navigation from another site, with the `Cookie` line `cookie`.
fn backFromGitHub(a: std.mem.Allocator, io: Io, port: u16, cookie: []const u8, path: []const u8) !Response {
    return getAs(a, io, port, try std.fmt.allocPrint(a, "{s}sec-fetch-site: cross-site\r\nsec-fetch-mode: navigate\r\n", .{cookie}), path);
}

/// A whole walk through the fake, its human agreeing as GitHub's code `code`
/// says, or saying no, for none.
fn signInByGitHub(a: std.mem.Allocator, io: Io, port: u16, fake: *fake_github.Fake, code: ?[]const u8) !Response {
    const begun = try startGitHub(a, io, port, fake);
    const back = try atGitHub(a, io, port, fake, .{ .authorize = begun.authorize, .code = code });
    return backFromGitHub(a, io, port, begun.cookie, back);
}

/// GitHub's way back for the state `state`, GitHub's code `user-id-7`.
fn wayBack(a: std.mem.Allocator, state: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "/login/github?code=user-id-7&state={s}", .{state});
}

/// The state with the nonce, the path and the errand of `state`, issued at
/// `second`, signed with `secret`.
fn stateSignedAt(a: std.mem.Allocator, secret: []const u8, state: []const u8, second: i64) ![]const u8 {
    return stateSigned(a, secret, state, .{ .second = second });
}

/// The state with the nonce and the path of `state`, signed with `secret`, as
/// app/GitHubState.roc spells one: a second opinion on it, from std's HMAC and
/// base64url. Issued at `second` when given, and for `errand` when given.
fn stateSigned(a: std.mem.Allocator, secret: []const u8, state: []const u8, change: struct { second: ?i64 = null, errand: ?[]const u8 = null }) ![]const u8 {
    var parts = std.mem.splitScalar(u8, state, '.');
    const nonce = parts.next() orelse return error.NotAState;
    const issued = parts.next() orelse return error.NotAState;
    const next = parts.next() orelse return error.NotAState;
    const errand = parts.next() orelse return error.NotAState;
    const second = if (change.second) |at| try std.fmt.allocPrint(a, "{d}", .{at}) else issued;
    const payload = try std.fmt.allocPrint(a, "{s}.{s}.{s}.{s}", .{ nonce, second, next, change.errand orelse errand });
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, try std.fmt.allocPrint(a, "github-state\n{s}", .{payload}), secret);
    const b64 = std.base64.url_safe_no_pad.Encoder;
    const mac_text = try a.alloc(u8, b64.calcSize(mac.len));
    return std.fmt.allocPrint(a, "{s}.{s}", .{ payload, b64.encode(mac_text, &mac) });
}

/// Whether `answer` sets no session and has the browser forget the state.
fn isRefusedAtTheDoor(answer: Response) bool {
    return !has(answer.head, "__Host-gopher_auth=") and
        has(answer.head, "set-cookie: __Host-gopher_github_state=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax") and
        std.mem.eql(u8, answer.header("cache-control") orelse "", "no-store");
}

/// The sign-up's cookie an answer sets, as a request's `Cookie` line.
fn signUpLine(a: std.mem.Allocator, asked: Response) ![]const u8 {
    const line = try cookieLine(a, asked);
    if (!has(line, "__Host-gopher_github_sign_up=")) return error.NoSignUp;
    return line;
}

/// Whether `answer`, GitHub's way back, sends the browser on to the form
/// that asks a name, with a sign-up and no session, never stored.
fn sentToNameForm(answer: Response) bool {
    return answer.status == 303 and std.mem.eql(u8, answer.header("location") orelse "", "/login/github/name") and
        has(answer.head, "set-cookie: __Host-gopher_github_sign_up=") and !has(answer.head, "__Host-gopher_auth=") and
        std.mem.eql(u8, answer.header("cache-control") orelse "", "no-store");
}

/// The form GitHub's way back `answer` sends its browser on to, the
/// browser holding the sign-up it set.
fn nameFormAfter(a: std.mem.Allocator, io: Io, port: u16, answer: Response) !Response {
    return getAs(a, io, port, try signUpLine(a, answer), "/login/github/name");
}

/// Whether `answer` is the form that asks a name, and starts no session.
fn asksForName(answer: Response, status: u16) bool {
    return answer.status == status and has(answer.body, "action=\"/login/github/name\"") and !has(answer.head, "__Host-gopher_auth=") and
        std.mem.eql(u8, answer.header("cache-control") orelse "", "no-store");
}

/// The sign-up with the id, the path and the login of the `Cookie` line `line`, issued
/// at `second`, signed with `secret`, as app/GitHubSignUp.roc spells one: a
/// second opinion on it, from std's HMAC and base64url. A `Cookie` line too.
fn signUpSignedAt(a: std.mem.Allocator, secret: []const u8, line: []const u8, second: i64) ![]const u8 {
    const prefix = "cookie: __Host-gopher_github_sign_up=";
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line[prefix.len..], "\r\n"), '.');
    const github_id = parts.next() orelse return error.NotASignUp;
    _ = parts.next();
    const next = parts.next() orelse return error.NotASignUp;
    const login = parts.next() orelse return error.NotASignUp;
    const payload = try std.fmt.allocPrint(a, "{s}.{d}.{s}.{s}", .{ github_id, second, next, login });
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, try std.fmt.allocPrint(a, "github-sign-up\n{s}", .{payload}), secret);
    const b64 = std.base64.url_safe_no_pad.Encoder;
    const mac_text = try a.alloc(u8, b64.calcSize(mac.len));
    return std.fmt.allocPrint(a, "{s}{s}.{s}\r\n", .{ prefix, payload, b64.encode(mac_text, &mac) });
}

/// The form field `name=<name>` posted to the sign-up with `line`.
fn chooseName(a: std.mem.Allocator, io: Io, port: u16, line: []const u8, name: []const u8) !Response {
    return postAs(a, io, port, line, "/login/github/name", try std.fmt.allocPrint(a, "name={s}", .{name}));
}

/// Whether `answer` is the sign-in page refusing a sign-up: a 403 saying
/// `words`, no session, and the sign-up forgotten.
fn signUpRefused(answer: Response, words: []const u8) bool {
    return answer.status == 403 and has(answer.body, words) and !has(answer.head, "__Host-gopher_auth=") and
        has(answer.head, "set-cookie: __Host-gopher_github_sign_up=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax");
}

/// Steps 48r to 48zh.
fn gitHubSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps, held: struct { fake: *fake_github.Fake, cc_bearer: []const u8 }) !void {
    const fake = held.fake;

    // 48r.
    const login_page = try anonymousGet(a, io, port, "/login?next=" ++ channel_url);
    try t.check("the sign-in page: first a link to sign in or sign up with GitHub, going to next, and a line for those with a password; then the password form", login_page.status == 200 and
        has(login_page.body, "<h1>Sign in</h1>\n<p><a href=\"/login/github/start?next=" ++ channel_url ++ "\">Sign in or sign up with GitHub</a></p>\n<p>Already have an account? Sign in with your password, then link GitHub.</p>\n<form method=\"post\" action=\"/login\">"));

    // 48s.
    const started = try anonymousGet(a, io, port, "/login/github/start?next=" ++ channel_url);
    const expected = try std.fmt.allocPrint(a, "{s}/login/oauth/authorize?client_id=" ++ fake_github.client_id ++ "&redirect_uri=http%3a%2f%2flocalhost%3a{d}%2flogin%2fgithub&state=", .{ fake.base(), port });
    const state_cookie = started.header("set-cookie") orelse "";
    const bad_next = try anonymousGet(a, io, port, "/login/github/start?next=//evil.example");
    try t.check("the start: a 303 to GitHub naming the client id, the way back and a state, its cookie set for ten minutes, never stored; a next that is no path here, a 400", started.status == 303 and
        std.mem.startsWith(u8, started.header("location") orelse "", expected) and
        std.mem.startsWith(u8, state_cookie, "__Host-gopher_github_state=") and
        std.mem.endsWith(u8, state_cookie, "; Path=/; Max-Age=600; HttpOnly; Secure; SameSite=Lax") and
        std.mem.eql(u8, started.header("cache-control") orelse "", "no-store") and bad_next.status == 400);

    // 48t.
    const counter_before = try readFile(a, io, data, "auth/next-id.txt");
    const unknown = try signInByGitHub(a, io, port, fake, "user-id-9");
    const sign_up_cookie = unknown.header("set-cookie") orelse "";
    const unknown_form = try nameFormAfter(a, io, port, unknown);
    const reloaded = try nameFormAfter(a, io, port, unknown);
    const no_login = try signInByGitHub(a, io, port, fake, "user-id-60");
    const no_login_form = try nameFormAfter(a, io, port, no_login);
    try t.check("an account no human holds, through the fake: a 303 to the form asking a name, which is empty as person9 is no name, says so, says the name is seen by everyone, is permanent, and lasts 10 minutes, and asks again on a reload; the sign-up's cookie for ten minutes, the state forgotten, no session, no account", sentToNameForm(unknown) and
        asksForName(unknown_form, 200) and has(unknown_form.body, "is not offered: a name here is letters") and has(unknown_form.body, "Everyone here sees this name") and
        has(unknown_form.body, "cannot be changed") and has(unknown_form.body, "10 minutes") and has(unknown_form.body, "maxlength=\"60\"") and asksForName(reloaded, 200) and
        sentToNameForm(no_login) and asksForName(no_login_form, 200) and has(no_login_form.body, "GitHub sent no login this chat can show") and
        !has(unknown_form.body, "value=") and std.mem.startsWith(u8, sign_up_cookie, "__Host-gopher_github_sign_up=9.") and
        std.mem.endsWith(u8, sign_up_cookie, "; Path=/; Max-Age=600; HttpOnly; Secure; SameSite=Lax") and isRefusedAtTheDoor(unknown) and
        std.mem.eql(u8, counter_before, try readFile(a, io, data, "auth/next-id.txt")));

    // 48u.
    const secret = try data.readFileAlloc(io, ".session-secret", a, .limited(256));
    const exchanges = fake.exchanges.load(.acquire);
    const begun = try startGitHub(a, io, port, fake);
    const other = try startGitHub(a, io, port, fake);
    var forged_state = try a.dupe(u8, begun.state);
    const flipped = forged_state.len - 5;
    forged_state[flipped] = if (forged_state[flipped] == 'A') 'B' else 'A';
    const now = files.current_utc_seconds_since_epoch(io);
    const stale = try stateSignedAt(a, secret, begun.state, now - 10 * 60);
    const in_time = try stateSignedAt(a, secret, begun.state, now - 10 * 60 + 60);
    const no_state = try backFromGitHub(a, io, port, begun.cookie, "/login/github?code=user-id-7");
    const no_cookie = try backFromGitHub(a, io, port, "", try wayBack(a, begun.state));
    const other_browser = try backFromGitHub(a, io, port, other.cookie, try wayBack(a, begun.state));
    const forged = try backFromGitHub(a, io, port, begun.cookie, try wayBack(a, forged_state));
    const expired = try backFromGitHub(a, io, port, begun.cookie, try wayBack(a, stale));
    try t.check("no state, no cookie, another browser's cookie, a forged signature, an expired state: 403 each, no session, and GitHub asked nothing", no_state.status == 403 and
        no_cookie.status == 403 and other_browser.status == 403 and forged.status == 403 and expired.status == 403 and
        has(expired.body, "took too long") and has(forged.body, "did not start in this browser") and isRefusedAtTheDoor(no_state) and
        isRefusedAtTheDoor(no_cookie) and isRefusedAtTheDoor(other_browser) and isRefusedAtTheDoor(forged) and isRefusedAtTheDoor(expired) and
        fake.exchanges.load(.acquire) == exchanges);

    // 48v.
    const near_miss = try backFromGitHub(a, io, port, begun.cookie, try wayBack(a, in_time));
    const reached = fake.exchanges.load(.acquire) == exchanges + 1;
    const denied = try signInByGitHub(a, io, port, fake, null);
    const refused = try signInByGitHub(a, io, port, fake, "bad");
    const malformed = try signInByGitHub(a, io, port, fake, "malformed");
    try t.check("a state nine minutes old is good, and reaches GitHub; its human saying no: 403; a code GitHub refuses: 403; an answer that makes no sense: 502; no session from any", sentToNameForm(near_miss) and
        reached and denied.status == 403 and has(denied.body, "did not sign you in") and refused.status == 403 and
        has(refused.body, "GitHub refused") and malformed.status == 502 and isRefusedAtTheDoor(near_miss) and isRefusedAtTheDoor(denied) and
        isRefusedAtTheDoor(refused) and isRefusedAtTheDoor(malformed));

    // 48w.
    try data.writeFile(io, .{ .sub_path = "auth/1/github-id", .data = "7\n" });
    const password_session = steve_session;
    const still_in = try getAs(a, io, port, password_session, channel_url);
    const steve_in = try signInByGitHub(a, io, port, fake, "user-id-7");
    const steve_cookie = steve_in.header("set-cookie") orelse "";
    const steve_line = try cookieLine(a, steve_in);
    const word = try readFile(a, io, data, "auth/1/github-session-secret");
    const his_page = try getAs(a, io, port, steve_line, channel_url);
    const old_page = try getAs(a, io, port, password_session, channel_url);
    try t.check("Steve's github-id written, his session unbroken; he signs in through the fake: a 303 to next, a session for a year, the state forgotten, never stored; github-session-secret 64 hex digits; his old session ends, the new one reads the page", still_in.status == 200 and
        steve_in.status == 303 and std.mem.eql(u8, steve_in.header("location") orelse "", channel_url) and
        std.mem.startsWith(u8, steve_cookie, "__Host-gopher_auth=") and std.mem.endsWith(u8, steve_cookie, "; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax") and
        has(steve_in.head, "set-cookie: __Host-gopher_github_state=; Path=/; Max-Age=0") and
        std.mem.eql(u8, steve_in.header("cache-control") orelse "", "no-store") and word.len == 64 and his_page.status == 200 and old_page.status == 303);

    // 48x.
    const by_password = try anonymousPost(a, io, port, "/login", "name=Steve&password=correct+horse+battery+staple");
    const password_line = try cookieLine(a, by_password);
    const password_page = try getAs(a, io, port, password_line, channel_url);
    const github_page = try getAs(a, io, port, steve_line, channel_url);
    try t.check("his password still signs him in, a 303; both sessions read the page", by_password.status == 303 and password_page.status == 200 and github_page.status == 200);
    steve_session = try std.fmt.allocPrint(a, "{s}", .{steve_line});

    // 48y.
    try data.createDirPath(io, "auth/5");
    try data.writeFile(io, .{ .sub_path = "auth/next-id.txt", .data = "6\n" });
    try data.writeFile(io, .{ .sub_path = "auth/5/name", .data = "Apoorva" });
    try data.writeFile(io, .{ .sub_path = "auth/5/github-id", .data = "8" });
    const by_form = try anonymousPost(a, io, port, "/login", "name=Apoorva&password=anything");
    const her_in = try signInByGitHub(a, io, port, fake, "user-id-8");
    const her = try cookieLine(a, her_in);
    const her_page = try getAs(a, io, port, her, "/invites");
    try t.check("a human with no password: the password form a 401; through the fake a 303, and her session reads her page", by_form.status == 401 and
        her_in.status == 303 and her_page.status == 200 and has(her_page.body, "Apoorva"));

    // 48z.
    try data.writeFile(io, .{ .sub_path = "auth/5/github-session-secret", .data = "abababababababababababababababababababababababababababababababab" });
    const after_rewrite = try getAs(a, io, port, her, "/invites");
    const her_again = try signInByGitHub(a, io, port, fake, "user-id-8");
    const her_second = try cookieLine(a, her_again);
    const second_page = try getAs(a, io, port, her_second, "/invites");
    try data.deleteFile(io, "auth/5/github-session-secret");
    const after_removal = try getAs(a, io, port, her_second, "/invites");
    const her_third = try cookieLine(a, try signInByGitHub(a, io, port, fake, "user-id-8"));
    const third_page = try getAs(a, io, port, her_third, "/invites");
    try data.deleteFile(io, "auth/5/github-id");
    const after_unbinding = try getAs(a, io, port, her_third, "/invites");
    const unbound = try signInByGitHub(a, io, port, fake, "user-id-8");
    try t.check("her github-session-secret rewritten, then removed: her session ends each time, and she signs in again; her github-id removed: her session ends, and GitHub's sign-in asks a name, as for anyone new", after_rewrite.status == 303 and
        her_again.status == 303 and second_page.status == 200 and after_removal.status == 303 and third_page.status == 200 and after_unbinding.status == 303 and
        sentToNameForm(unbound) and isRefusedAtTheDoor(unbound));

    // 48za.
    try data.writeFile(io, .{ .sub_path = "auth/5/github-id", .data = "7" });
    const shared = try signInByGitHub(a, io, port, fake, "user-id-7");
    try data.deleteFile(io, "auth/5/github-id");
    try t.check("two humans holding one GitHub id: 403, neither signed in", shared.status == 403 and has(shared.body, "more than one") and isRefusedAtTheDoor(shared));
    try data.writeFile(io, .{ .sub_path = "auth/1/github-id", .data = "x" });
    const counter_at_damage = try readFile(a, io, data, "auth/next-id.txt");
    const damaged_page = try get(a, io, port, "/agents");
    const damaged_sign_in = try signInByGitHub(a, io, port, fake, "user-id-8");
    try data.writeFile(io, .{ .sub_path = "auth/1/github-id", .data = "7\n" });
    const mended_page = try get(a, io, port, "/agents");
    try t.check("Steve's github-id damaged: his session's page and anyone's GitHub sign-in a 500, saying so, no account made; mended, his page again", damaged_page.status == 500 and
        has(damaged_page.body, "Damaged") and damaged_sign_in.status == 500 and has(damaged_sign_in.body, "Damaged") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), counter_at_damage) and mended_page.status == 200);

    // 48zb.
    const key_starts = try getAs(a, io, port, held.cc_bearer, "/login/github/start");
    const key_returns = try getAs(a, io, port, held.cc_bearer, "/login/github?code=user-id-7&state=x");
    const unbound_line = try signUpLine(a, unbound);
    const key_names = try postAs(a, io, port, try std.fmt.allocPrint(a, "{s}{s}", .{ held.cc_bearer, unbound_line }), "/login/github/name", "name=Mallory");
    const name_by_get = try anonymousGet(a, io, port, "/login/github/name");

    const cross_site = try postAs(a, io, port, try std.fmt.allocPrint(a, "{s}sec-fetch-site: cross-site\r\n", .{unbound_line}), "/login/github/name", "name=Mallory");
    try t.check("CC's key at any route: 403; a GET of the name form with no sign-up: 403; a cross-site post of a name: 403, nothing made", key_starts.status == 403 and key_returns.status == 403 and
        key_names.status == 403 and has(key_names.body, "An API key never signs in") and name_by_get.status == 403 and has(name_by_get.body, "did not start in this browser") and cross_site.status == 403 and !has(cross_site.head, "__Host-gopher_auth=") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "6\n"));

    // 48zc.
    const zoe_back = try signInByGitHub(a, io, port, fake, "user-id-20");
    const zoe_form = try nameFormAfter(a, io, port, zoe_back);
    const zoe_in = try chooseName(a, io, port, try signUpLine(a, zoe_back), "Zoe");
    const zoe = try cookieLine(a, zoe_in);
    const zoe_page = try getAs(a, io, port, zoe, "/invites");
    const zoe_by_form = try anonymousPost(a, io, port, "/login", "name=Zoe&password=anything");
    const zoe_secret = try readFile(a, io, data, "auth/6/github-session-secret");
    try t.check("a new human: the form offers Zoe; choosing it makes user 6 with github-id and github-session-secret, no password, no inviter; a 303 to next, a session, the sign-up forgotten; the password form a 401", asksForName(zoe_form, 200) and
        has(zoe_form.body, "value=\"Zoe\"") and zoe_in.status == 303 and std.mem.eql(u8, zoe_in.header("location") orelse "", channel_url) and
        std.mem.startsWith(u8, zoe_in.header("set-cookie") orelse "", "__Host-gopher_auth=") and
        has(zoe_in.head, "set-cookie: __Host-gopher_github_sign_up=; Path=/; Max-Age=0") and std.mem.eql(u8, zoe_in.header("cache-control") orelse "", "no-store") and
        zoe_page.status == 200 and has(zoe_page.body, "Zoe") and zoe_by_form.status == 401 and zoe_secret.len == 64 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/6/name"), "Zoe") and std.mem.eql(u8, try readFile(a, io, data, "auth/6/github-id"), "20") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "7\n") and
        !try exists(io, data, "auth/6/password") and !try exists(io, data, "auth/6/inviter"));

    try t.check("Zoe's account was made holding `joined`, the second, its digits", (try std.fmt.parseInt(i64, try readFile(a, io, data, "auth/6/joined"), 10)) > 0);

    // 48zd.
    const zoe_again = try signInByGitHub(a, io, port, fake, "user-id-20");
    const zoe_second = try getAs(a, io, port, try cookieLine(a, zoe_again), "/invites");
    try t.check("her next GitHub sign-in: a 303, no form, the same account, its secret kept; no other account", zoe_again.status == 303 and zoe_second.status == 200 and
        has(zoe_second.body, "Zoe") and std.mem.eql(u8, zoe_secret, try readFile(a, io, data, "auth/6/github-session-secret")) and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "7\n"));

    // 48ze.
    const taken_back = try signInByGitHub(a, io, port, fake, "user-id-21");
    const taken_login = try nameFormAfter(a, io, port, taken_back);
    const ravi_line = try signUpLine(a, taken_back);
    const taken = try chooseName(a, io, port, ravi_line, "STEVE");
    const channels_name = try chooseName(a, io, port, ravi_line, "General");
    const no_name = try chooseName(a, io, port, ravi_line, "R2D2");
    const no_field = try postAs(a, io, port, ravi_line, "/login/github/name", "");
    const unspent = std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "7\n");
    const ravi_in = try chooseName(a, io, port, ravi_line, "Ravi");
    try t.check("a login that is taken offers nothing; a taken name: 409, kept in the form; a channel's: 409; no name: 400, the form empty; no field: 400; nothing spent; a free name then makes user 7", asksForName(taken_login, 200) and
        !has(taken_login.body, "value=") and has(taken_login.body, "someone here has that name") and asksForName(taken, 409) and has(taken.body, "The name is taken.") and has(taken.body, "value=\"STEVE\"") and
        asksForName(channels_name, 409) and asksForName(no_name, 400) and !has(no_name.body, "value=") and has(no_name.body, "The name is not a name") and asksForName(no_field, 400) and unspent and
        !has(taken.head, "__Host-gopher_github_sign_up=") and ravi_in.status == 303 and std.mem.eql(u8, try readFile(a, io, data, "auth/7/name"), "Ravi") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/7/github-id"), "21"));

    // 48zf.
    const fresh = try signUpLine(a, try signInByGitHub(a, io, port, fake, "user-id-22"));
    var rewritten = try a.dupe(u8, fresh);
    const prefix_end = "cookie: __Host-gopher_github_sign_up=".len;
    rewritten[prefix_end] = if (rewritten[prefix_end] == '7') '6' else '7';
    const state_as_sign_up = try std.fmt.allocPrint(a, "cookie: __Host-gopher_github_sign_up={s}\r\n", .{begun.state});
    const sign_up_now = files.current_utc_seconds_since_epoch(io);
    const no_sign_up = try chooseName(a, io, port, "", "Mallory");
    const forged_up = try chooseName(a, io, port, rewritten, "Mallory");
    const state_up = try chooseName(a, io, port, state_as_sign_up, "Mallory");
    const expired_up = try chooseName(a, io, port, try signUpSignedAt(a, secret, fresh, sign_up_now - 10 * 60), "Mallory");
    const counter_refused = try readFile(a, io, data, "auth/next-id.txt");
    const in_time_up = try chooseName(a, io, port, try signUpSignedAt(a, secret, fresh, sign_up_now - 10 * 60 + 60), "Priya");
    try t.check("no sign-up, one the browser rewrote, a state passed as one, an expired one: 403 each, no session, nothing made; one nine minutes old makes user 8", signUpRefused(no_sign_up, "did not start in this browser") and
        signUpRefused(forged_up, "did not start in this browser") and signUpRefused(state_up, "did not start in this browser") and signUpRefused(expired_up, "took too long") and
        std.mem.eql(u8, counter_refused, "8\n") and in_time_up.status == 303 and std.mem.eql(u8, try readFile(a, io, data, "auth/8/name"), "Priya") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/8/github-id"), "22"));

    // 48zg.
    const first_tab = try signUpLine(a, try signInByGitHub(a, io, port, fake, "user-id-23"));
    const second_tab = try signUpLine(a, try signInByGitHub(a, io, port, fake, "user-id-23"));
    const first_submit = try chooseName(a, io, port, first_tab, "Ada");
    const double_submit = try chooseName(a, io, port, first_tab, "Ada");
    const other_tab = try chooseName(a, io, port, second_tab, "Grace");
    const signed_up_again = try signInByGitHub(a, io, port, fake, "user-id-23");
    try t.check("the same submit twice, and a second tab's: one account, user 9; each repeat a 403 with no session; GitHub then signs in to it", first_submit.status == 303 and
        signUpRefused(double_submit, "has an account here") and signUpRefused(other_tab, "has an account here") and signed_up_again.status == 303 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/9/name"), "Ada") and std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "10\n"));

    // 48zh.
    var on_disk: std.ArrayList([]const u8) = .empty;
    try allFiles(a, io, data, "", &on_disk);
    var secrets_on_disk: usize = 0;
    var files_read: usize = 0;
    for (on_disk.items) |path| {
        if (path[0] == '.') continue;
        files_read += 1;
        const bytes = try data.readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
        for ([_][]const u8{ fake_github.client_secret, "tok-id-" }) |held_secret| {
            if (has(bytes, held_secret)) secrets_on_disk += 1;
        }
    }
    try t.check("no chat file holds the client secret or a token, and no refusal says them", files_read > 0 and secrets_on_disk == 0 and
        !has(unknown.body, fake_github.client_secret) and !has(malformed.body, "tok-id-") and !has(refused.head, fake_github.client_secret));
}

/// A link begun by the browser with the `Cookie` line `session`: the state's
/// `Cookie` line it holds now, GitHub's page on the fake, and the state.
fn startLink(a: std.mem.Allocator, io: Io, port: u16, fake: *fake_github.Fake, session: []const u8) !GitHubStart {
    const started = try postAs(a, io, port, session, "/login/github/link", "");
    const location = started.header("location") orelse return error.NoLocation;
    if (!std.mem.startsWith(u8, location, fake.base())) return error.NotTheFake;
    const at = std.mem.indexOf(u8, location, "&state=") orelse return error.NoState;
    return .{ .cookie = try cookieLine(a, started), .authorize = location[fake.base().len..], .state = location[at + "&state=".len ..] };
}

/// The `Cookie` line of a browser holding both `session` and `state`.
fn bothCookies(a: std.mem.Allocator, session: []const u8, state: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}; {s}", .{ std.mem.trimEnd(u8, session, "\r\n"), state["cookie: ".len..] });
}

/// A link's way back through the fake, GitHub's code `code`, for a browser
/// holding `session` and the state of `begun`.
fn finishLink(a: std.mem.Allocator, io: Io, port: u16, fake: *fake_github.Fake, session: []const u8, begun: GitHubStart, code: []const u8) !Response {
    const back = try atGitHub(a, io, port, fake, .{ .authorize = begun.authorize, .code = code });
    return backFromGitHub(a, io, port, try bothCookies(a, session, begun.cookie), back);
}

/// A whole link through the fake, for the browser with the `Cookie` line
/// `session`.
fn linkByGitHub(a: std.mem.Allocator, io: Io, port: u16, fake: *fake_github.Fake, session: []const u8, code: []const u8) !Response {
    return finishLink(a, io, port, fake, session, try startLink(a, io, port, fake, session), code);
}

/// The session of a human `inviter` invites as `name`, who joins with a
/// password.
fn joinedHuman(a: std.mem.Allocator, io: Io, port: u16, inviter: []const u8, name: []const u8) ![]const u8 {
    const invited = try postAs(a, io, port, inviter, "/invites", try std.fmt.allocPrint(a, "name={s}", .{name}));
    const link = between(invited.body, "<p class=\"invite-code\">", "</p>") orelse return error.NoLink;
    const hash = std.mem.indexOfScalar(u8, link, '#') orelse return error.NoCode;
    const joined = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name={s}&password=their+own", .{ link[hash + 1 ..], name }));
    return cookieLine(a, joined);
}

/// Whether `answer` is a link refused with `status`, saying `words`: no
/// session, the state forgotten.
fn linkRefused(answer: Response, status: u16, words: []const u8) bool {
    return answer.status == status and has(answer.body, words) and isRefusedAtTheDoor(answer);
}

/// Steps 48zi to 48zl.
fn linkSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps, held: struct { fake: *fake_github.Fake, cc_bearer: []const u8 }) !void {
    const fake = held.fake;
    const offer = "<form method=\"post\" action=\"/login/github/link\"><button>Link GitHub</button></form>";

    // 48zi.
    const by_password = try anonymousPost(a, io, port, "/login", "name=Debbie&password=a+new+one");
    const debbie = try cookieLine(a, by_password);
    const her_page = try getAs(a, io, port, debbie, "/agents");
    const steve_page = try get(a, io, port, "/agents");
    try t.check("/agents offers a human with no github-id to link GitHub, and not Steve, who has one", her_page.status == 200 and
        has(her_page.body, offer) and steve_page.status == 200 and !has(steve_page.body, offer));
    const ids_before = try readFile(a, io, data, "auth/next-id.txt");
    const her_make = try postAs(a, io, port, debbie, "/agents", "name=Rogue");
    const her_invite = try postAs(a, io, port, debbie, "/agents/2/invites", "");
    const her_revoke = try postAs(a, io, port, debbie, "/agents/2/keys/1/revoke", "");
    try t.check("agents are the admin's: Debbie's /agents has no form that makes one, and her make, invite and revoke are 403 each, nothing made", !has(her_page.body, "action=\"/agents\"") and
        has(her_page.body, "Only the admin makes and manages agents.") and
        her_make.status == 403 and her_invite.status == 403 and her_revoke.status == 403 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), ids_before));
    const counter = try readFile(a, io, data, "auth/next-id.txt");
    const begun = try startLink(a, io, port, fake, debbie);
    const linked = try finishLink(a, io, port, fake, debbie, begun, "user-id-30");
    const linked_line = try cookieLine(a, linked);
    const old_session = try getAs(a, io, port, debbie, "/invites");
    const new_session = try getAs(a, io, port, linked_line, "/agents");
    try t.check("Debbie links GitHub: the state names her, a 303 to Browse, a session, the state forgotten, never stored; github-id and a 64-digit github-session-secret written, no account made; her old session ends, the new one reads her page, with no offer", has(begun.state, ".link-3.") and
        linked.status == 303 and std.mem.eql(u8, linked.header("location") orelse "", "/chat") and
        std.mem.startsWith(u8, linked.header("set-cookie") orelse "", "__Host-gopher_auth=") and
        has(linked.head, "set-cookie: __Host-gopher_github_state=; Path=/; Max-Age=0") and
        std.mem.eql(u8, linked.header("cache-control") orelse "", "no-store") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/3/github-id"), "30") and
        (try readFile(a, io, data, "auth/3/github-session-secret")).len == 64 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), counter) and
        old_session.status == 303 and new_session.status == 200 and has(new_session.body, "Debbie") and !has(new_session.body, offer));
    const by_github = try signInByGitHub(a, io, port, fake, "user-id-30");
    const github_page = try getAs(a, io, port, try cookieLine(a, by_github), "/invites");
    const password_again = try anonymousPost(a, io, port, "/login", "name=Debbie&password=a+new+one");
    const password_page = try getAs(a, io, port, try cookieLine(a, password_again), "/invites");
    try t.check("that GitHub then signs in to the same account, no form, no new id; her password still signs her in", by_github.status == 303 and
        github_page.status == 200 and has(github_page.body, "Debbie") and password_again.status == 303 and password_page.status == 200 and
        std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), counter));

    // 48zj.
    const hal = try joinedHuman(a, io, port, linked_line, "Hal");
    const held_by_her = try linkByGitHub(a, io, port, fake, hal, "user-id-30");
    const held_by_steve = try linkByGitHub(a, io, port, fake, hal, "user-id-7");
    const hal_page = try getAs(a, io, port, hal, "/invites");
    try t.check("Hal links an id Debbie holds, then Steve's: 409 each, plainly said, nothing bound, his session unbroken", linkRefused(held_by_her, 409, "linked to someone here") and
        linkRefused(held_by_steve, 409, "linked to someone here") and !(try exists(io, data, "auth/10/github-id")) and
        !(try exists(io, data, "auth/10/github-session-secret")) and hal_page.status == 200);
    const first_tab = try startLink(a, io, port, fake, hal);
    const second_tab = try startLink(a, io, port, fake, hal);
    const hal_linked = try finishLink(a, io, port, fake, hal, first_tab, "user-id-31");
    const hal_line = try cookieLine(a, hal_linked);
    const hal_word = try readFile(a, io, data, "auth/10/github-session-secret");
    const exchanges = fake.exchanges.load(.acquire);
    const at_the_start = try postAs(a, io, port, hal_line, "/login/github/link", "");
    const asked_nothing = fake.exchanges.load(.acquire) == exchanges;
    const from_second_tab = try finishLink(a, io, port, fake, hal_line, second_tab, "user-id-32");
    const hal_after = try getAs(a, io, port, hal_line, "/invites");
    try t.check("Hal links a free id: 303; again at the start: 409, no trip to GitHub; again from a second tab: 409; the first binding and his session kept", hal_linked.status == 303 and
        at_the_start.status == 409 and has(at_the_start.body, "linked GitHub already") and at_the_start.header("location") == null and asked_nothing and
        linkRefused(from_second_tab, 409, "linked GitHub already") and std.mem.eql(u8, try readFile(a, io, data, "auth/10/github-id"), "31") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/10/github-session-secret"), hal_word) and hal_after.status == 200);

    // 48zk.
    const ivy = try joinedHuman(a, io, port, linked_line, "Ivy");
    const secret = try data.readFileAlloc(io, ".session-secret", a, .limited(256));
    const ivy_begun = try startLink(a, io, port, fake, ivy);
    const both = try bothCookies(a, ivy, ivy_begun.cookie);
    var forged_state = try a.dupe(u8, ivy_begun.state);
    const flipped = forged_state.len - 5;
    forged_state[flipped] = if (forged_state[flipped] == 'A') 'B' else 'A';
    const before_forged = fake.exchanges.load(.acquire);
    const forged = try backFromGitHub(a, io, port, both, try std.fmt.allocPrint(a, "/login/github?code=user-id-33&state={s}", .{forged_state}));
    const no_exchange = fake.exchanges.load(.acquire) == before_forged;
    const for_another = try stateSigned(a, secret, ivy_begun.state, .{ .errand = "link-4" });
    const another = try backFromGitHub(a, io, port, both, try std.fmt.allocPrint(a, "/login/github?code=user-id-33&state={s}", .{for_another}));
    const no_session = try backFromGitHub(a, io, port, ivy_begun.cookie, try std.fmt.allocPrint(a, "/login/github?code=user-id-33&state={s}", .{ivy_begun.state}));
    const ivy_page = try getAs(a, io, port, ivy, "/invites");
    try t.check("a link's forged state: 403, GitHub asked nothing; a state naming another human, and a browser whose session has gone: 403 each; nothing bound, her session unbroken", linkRefused(forged, 403, "did not start in this browser") and
        no_exchange and linkRefused(another, 403, "did not start from this account") and linkRefused(no_session, 403, "did not start from this account") and
        !(try exists(io, data, "auth/4/github-id")) and !(try exists(io, data, "auth/11/github-id")) and ivy_page.status == 200);
    try data.writeFile(io, .{ .sub_path = "auth/11/github-session-secret", .data = "an old word" });
    const ivy_linked = try linkByGitHub(a, io, port, fake, ivy, "user-id-33");
    const ivy_after = try getAs(a, io, port, try cookieLine(a, ivy_linked), "/invites");
    try t.check("a github-session-secret left from an earlier binding is replaced as she links", ivy_linked.status == 303 and ivy_after.status == 200 and
        (try readFile(a, io, data, "auth/11/github-session-secret")).len == 64);

    // 48zl.
    const by_key = try post(a, io, port, .{ .path = "/login/github/link", .form = "", .more = held.cc_bearer });
    const by_no_one = try anonymousPost(a, io, port, "/login/github/link", "");
    const by_get = try getAs(a, io, port, hal_line, "/login/github/link");
    const cross_site = try postAs(a, io, port, try std.fmt.allocPrint(a, "{s}sec-fetch-site: cross-site\r\n", .{hal_line}), "/login/github/link", "");
    try t.check("a link by CC's key: 403; by no one: 401; by GET: 405; a cross-site post: 403", by_key.status == 403 and
        has(by_key.body, "An API key never signs in") and by_no_one.status == 401 and by_get.status == 405 and cross_site.status == 403);
}

/// A new human through the fake, heading for `next`, GitHub's code `code`,
/// who chooses `name`: the answer that makes their account.
fn signUpHeadingTo(a: std.mem.Allocator, io: Io, port: u16, fake: *fake_github.Fake, next: []const u8, code: []const u8, name: []const u8) !Response {
    const begun = try startGitHubTo(a, io, port, fake, next);
    const back = try atGitHub(a, io, port, fake, .{ .authorize = begun.authorize, .code = code });
    const asked = try backFromGitHub(a, io, port, begun.cookie, back);
    return chooseName(a, io, port, try signUpLine(a, asked), name);
}

/// The owner's words of welcome, under the owner named `owner`.
fn welcomeWords(a: std.mem.Allocator, owner: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "Welcome! If {s} is not here, you can still send a message, and they will reply soon.", .{owner});
}

/// The page of the DM that welcomes the human `id`.
fn welcomePage(a: std.mem.Allocator, id: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "/chat/dm/1_{d}/ChitChat", .{id});
}

/// The transcript of the DM that welcomes the human `id`.
fn welcomeFile(a: std.mem.Allocator, id: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "chat/dm/1_{d}/ChitChat/transcript", .{id});
}

/// The id the next user will get.
fn nextId(a: std.mem.Allocator, io: Io, data: Io.Dir) !u32 {
    return std.fmt.parseInt(u32, std.mem.trimEnd(u8, try readFile(a, io, data, "auth/next-id.txt"), "\n"), 10);
}

/// Whether the new human `made`, of id `id`, lands in their DM with Steve: a
/// page of theirs, a 200, holding his welcome.
fn landsInWelcome(a: std.mem.Allocator, io: Io, port: u16, made: Response, id: u32) !bool {
    const location = made.header("location") orelse return false;
    const page = try getAs(a, io, port, try cookieLine(a, made), location);
    return made.status == 303 and std.mem.eql(u8, location, try welcomePage(a, id)) and page.status == 200 and
        has(page.body, try welcomeWords(a, "Steve"));
}

/// A sign-in begun at the sign-in page's link by a browser signed in as no
/// one, going to `/invites` after; `signInAs` comes back signed in, as a
/// human who signs in meanwhile does. (A browser signed in already is sent
/// to /agents at the start: 48zq.)
fn startSignInAs(a: std.mem.Allocator, io: Io, port: u16, fake: *fake_github.Fake) !GitHubStart {
    const started = try anonymousGet(a, io, port, "/login/github/start?next=/invites");
    const location = started.header("location") orelse return error.NoLocation;
    if (!std.mem.startsWith(u8, location, fake.base())) return error.NotTheFake;
    const at = std.mem.indexOf(u8, location, "&state=") orelse return error.NoState;
    return .{ .cookie = try cookieLine(a, started), .authorize = location[fake.base().len..], .state = location[at + "&state=".len ..] };
}

/// A whole sign-in through the fake by a human signed in already.
fn signInAs(a: std.mem.Allocator, io: Io, port: u16, fake: *fake_github.Fake, session: []const u8, code: []const u8) !Response {
    return finishLink(a, io, port, fake, session, try startSignInAs(a, io, port, fake), code);
}

/// Steps 48zo, 48zt and 48zt2 to 48zt5: the welcome, one account per GitHub account, and
/// the names rules: a reserved or lookalike name is refused (48zt2), an expired invite frees its
/// name (48zt3), a request refused after its name is judged frees nothing
/// (48zt4), and a release from a channel besides #general leaves every page
/// answering (48zt5), and a person makes at most 3 new invites in their
/// first day (48zt6), a cut-short invite among them; a join that keeps its
/// name frees no look-alike (48zt7).
fn welcomeSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps, fake: *fake_github.Fake, debbie: []const u8) !void {
    // 48zo.
    const tess_id = try nextId(a, io, data);
    try data.writeFile(io, .{ .sub_path = "auth/1/name", .data = "Margaret" });
    const tess_in = try signUpHeadingTo(a, io, port, fake, "/agents", "user-id-50", "Tess");
    const tess_page = try getAs(a, io, port, try cookieLine(a, tess_in), try welcomePage(a, tess_id));
    const owner_page = try getAs(a, io, port, steve_session, try welcomePage(a, tess_id));
    const stranger_page = try getAs(a, io, port, debbie, try welcomePage(a, tess_id));
    const invited_under = try postAs(a, io, port, debbie, "/invites", "name=Tia");
    try data.writeFile(io, .{ .sub_path = "auth/1/name", .data = "Steve" });
    const tess_file = try readFile(a, io, data, try welcomeFile(a, tess_id));
    const tia_file = try readFile(a, io, data, try welcomeFile(a, tess_id + 1));
    const margaret_words = try welcomeWords(a, "Margaret");
    try t.check("an owner named Margaret: a GitHub sign-up and an invite each start a DM with her, her name read from her file; the sign-up lands there, a 200, and she reads it; another human doesn't; the transcript is one record in the usual format", invited_under.status == 200 and
        std.mem.eql(u8, tess_in.header("location") orelse "", try welcomePage(a, tess_id)) and tess_page.status == 200 and has(tess_page.body, margaret_words) and
        owner_page.status == 200 and has(owner_page.body, margaret_words) and stranger_page.status != 200 and
        std.mem.startsWith(u8, tess_file, "-------------\nMSG_ChitChat_1\nfrom: Margaret\ndate: ") and has(tess_file, try std.fmt.allocPrint(a, "Z\n\n{s}\n\n", .{margaret_words})) and
        std.mem.count(u8, tess_file, "-------------") == 1 and !has(tess_file, "Steve") and has(tia_file, "from: Margaret\n") and has(tia_file, margaret_words));

    // 48zp.
    const nan_id = try nextId(a, io, data);
    const invited = try postAs(a, io, port, debbie, "/invites", "name=Nan");
    const welcome_before = try readFile(a, io, data, try welcomeFile(a, nan_id));
    const link = between(invited.body, "<p class=\"invite-code\">", "</p>") orelse return error.NoLink;
    const hash = std.mem.indexOfScalar(u8, link, '#') orelse return error.NoCode;
    const joined = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Nell&password=their+own", .{link[hash + 1 ..]}));
    const nell = try cookieLine(a, joined);
    const steve_words = try welcomeWords(a, "Steve");
    const welcome_after = try readFile(a, io, data, try welcomeFile(a, nan_id));
    const owner_reads = try getAs(a, io, port, steve_session, try welcomePage(a, nan_id));
    try t.check("invited as Nan, she joins as Nell: the DM written at the invite, from Steve, unchanged by her new name; she lands in it, a 200, and he reads it", has(welcome_before, "from: Steve\n") and
        has(welcome_before, steve_words) and try landsInWelcome(a, io, port, joined, nan_id) and std.mem.eql(u8, welcome_before, welcome_after) and
        std.mem.eql(u8, try readFile(a, io, data, try std.fmt.allocPrint(a, "auth/{d}/name", .{nan_id})), "Nell") and owner_reads.status == 200 and has(owner_reads.body, steve_words));
    const reply = try postAs(a, io, port, nell, try welcomePage(a, nan_id), "markdown=Thanks+Steve");
    const owner_hears = try getAs(a, io, port, steve_session, try welcomePage(a, nan_id));
    try t.check("she answers there under her new name, a 303, and he reads it", reply.status == 303 and owner_hears.status == 200 and has(owner_hears.body, "Thanks Steve") and
        has(try readFile(a, io, data, try welcomeFile(a, nan_id)), "MSG_ChitChat_2\nfrom: Nell\n"));

    const bea_id = try nextId(a, io, data);
    const bea_invited = try postAs(a, io, port, debbie, "/invites", "name=Bea");
    const bea_link = between(bea_invited.body, "<p class=\"invite-code\">", "</p>") orelse return error.NoLink;
    const bea_hash = std.mem.indexOfScalar(u8, bea_link, '#') orelse return error.NoCode;
    try data.deleteFile(io, try welcomeFile(a, bea_id));
    const bea_joined = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Bea&password=their+own", .{bea_link[bea_hash + 1 ..]}));
    const bea_page = try getAs(a, io, port, try cookieLine(a, bea_joined), bea_joined.header("location") orelse "");
    try t.check("a human with no welcome on disk joins all the same, landing on Browse, a 200", bea_joined.status == 303 and
        std.mem.eql(u8, bea_joined.header("location") orelse "", "/chat") and bea_page.status == 200);

    // 48zq.
    const kit_id = try nextId(a, io, data);
    const kit = try joinedHuman(a, io, port, debbie, "Kit");
    const kit_github_id = try std.fmt.allocPrint(a, "auth/{d}/github-id", .{kit_id});
    const counter = try nextId(a, io, data);
    const cross_site_start = try getAs(a, io, port, try std.fmt.allocPrint(a, "{s}sec-fetch-site: cross-site\r\nsec-fetch-mode: navigate\r\n", .{kit}), "/login/github/start?next=/invites");
    const own_start = try getAs(a, io, port, kit, "/login/github/start?next=/invites");
    try t.check("Kit, signed in, at /login/github/start, from another site or his own: a 303 to /agents, whose button links by a POST; no state, no trip to GitHub, nothing bound", cross_site_start.status == 303 and
        std.mem.eql(u8, cross_site_start.header("location") orelse "", "/agents") and !has(cross_site_start.head, "__Host-gopher_github_state=") and
        own_start.status == 303 and std.mem.eql(u8, own_start.header("location") orelse "", "/agents") and
        !(try exists(io, data, kit_github_id)));
    const linked = try signInAs(a, io, port, fake, kit, "user-id-51");
    const kit_line = try cookieLine(a, linked);
    const kit_page = try getAs(a, io, port, kit_line, "/invites");
    try t.check("Kit, signed in, takes the sign-in page's link to GitHub with an id no one holds: a 303 to where it was going, a new session, the id bound to him; no form, no account", linked.status == 303 and
        std.mem.eql(u8, linked.header("location") orelse "", "/invites") and !asksForName(linked, 200) and std.mem.startsWith(u8, linked.header("set-cookie") orelse "", "__Host-gopher_auth=") and
        kit_page.status == 200 and has(kit_page.body, "Kit") and std.mem.eql(u8, try readFile(a, io, data, kit_github_id), "51") and try nextId(a, io, data) == counter);
    const own_again = try signInAs(a, io, port, fake, kit_line, "user-id-51");
    const kit_again = try cookieLine(a, own_again);
    const another_id = try signInAs(a, io, port, fake, kit_again, "user-id-52");
    const by_no_one = try signInByGitHub(a, io, port, fake, "user-id-51");
    const by_no_one_page = try getAs(a, io, port, try cookieLine(a, by_no_one), "/invites");
    try t.check("his own id again: signed in, a 303; a second id: 409, plainly said, the first kept; signed out, the id reaches his account; never a new one", own_again.status == 303 and
        linkRefused(another_id, 409, "linked GitHub already") and std.mem.eql(u8, try readFile(a, io, data, kit_github_id), "51") and by_no_one.status == 303 and
        by_no_one_page.status == 200 and has(by_no_one_page.body, "Kit") and try nextId(a, io, data) == counter);

    // 48zr.
    const lee_id = try nextId(a, io, data);
    const lee = try joinedHuman(a, io, port, debbie, "Lee");
    const lee_github_id = try std.fmt.allocPrint(a, "auth/{d}/github-id", .{lee_id});
    const after_lee = try nextId(a, io, data);
    const taken = try signInAs(a, io, port, fake, lee, "user-id-51");
    const lee_page = try getAs(a, io, port, lee, "/invites");
    try t.check("Lee, signed in, comes back with Kit's id: 409, plainly said, nothing bound, no account, not signed in as Kit, her session unbroken", linkRefused(taken, 409, "linked to someone here") and
        !(try exists(io, data, lee_github_id)) and try nextId(a, io, data) == after_lee and lee_page.status == 200 and has(lee_page.body, "Lee"));

    // 48zs.
    const form_line = try signUpLine(a, try signInByGitHub(a, io, port, fake, "user-id-53"));
    const by_lee = try postAs(a, io, port, try bothCookies(a, lee, form_line), "/login/github/name", "name=Mallory");
    const lee_links = try signInAs(a, io, port, fake, lee, "user-id-53");
    try t.check("a sign-up's name posted from a browser signed in by then: 409, saying so, no account, no new session, the sign-up forgotten; going through GitHub then links it", by_lee.status == 409 and
        has(by_lee.body, "You are signed in") and !has(by_lee.head, "__Host-gopher_auth=") and has(by_lee.head, "set-cookie: __Host-gopher_github_sign_up=; Path=/; Max-Age=0") and
        try nextId(a, io, data) == after_lee and lee_links.status == 303 and std.mem.eql(u8, try readFile(a, io, data, lee_github_id), "53"));

    // 48zt.
    const blocked_up = try nextId(a, io, data);
    const in_the_way = try std.fmt.allocPrint(a, "chat/dm/1_{d}", .{blocked_up});
    try data.writeFile(io, .{ .sub_path = in_the_way, .data = "not a folder" });
    const noor_line = try signUpLine(a, try signInByGitHub(a, io, port, fake, "user-id-54"));
    const failed_up = try chooseName(a, io, port, noor_line, "Noor");
    const noor_after_failure = try exists(io, data, try std.fmt.allocPrint(a, "auth/{d}", .{blocked_up}));
    const noor_in = try chooseName(a, io, port, noor_line, "Noor");
    try data.deleteFile(io, in_the_way);
    try t.check("a DM that can't be written: the sign-up a 500, no session, no account, the GitHub id bound to no one; the same sign-up then makes the next id, with its DM", failed_up.status == 500 and
        !has(failed_up.head, "__Host-gopher_auth=") and !noor_after_failure and noor_in.status == 303 and has(try readFile(a, io, data, try welcomeFile(a, blocked_up + 1)), try welcomeWords(a, "Steve")) and
        std.mem.eql(u8, try readFile(a, io, data, try std.fmt.allocPrint(a, "auth/{d}/github-id", .{blocked_up + 1})), "54"));
    const blocked_invite = try nextId(a, io, data);
    const in_the_invites_way = try std.fmt.allocPrint(a, "chat/dm/1_{d}", .{blocked_invite});
    try data.writeFile(io, .{ .sub_path = in_the_invites_way, .data = "not a folder" });
    const failed_invite = try postAs(a, io, port, debbie, "/invites", "name=Odile");
    const odile_after_failure = try exists(io, data, try std.fmt.allocPrint(a, "auth/{d}", .{blocked_invite}));
    const retried_invite = try postAs(a, io, port, debbie, "/invites", "name=Odile");
    try data.deleteFile(io, in_the_invites_way);
    try t.check("and the invite a 500, no code, no account, the name free; the same invite then makes the next id, with its DM", failed_invite.status == 500 and
        !has(failed_invite.body, "invite-code") and !odile_after_failure and retried_invite.status == 200 and has(retried_invite.body, "invite-code") and
        has(try readFile(a, io, data, try welcomeFile(a, blocked_invite + 1)), steve_words));

    const before_noor = try nextId(a, io, data);

    // 48zt2.
    const reserved_invite = try postAs(a, io, port, debbie, "/invites", "name=Admin");
    const close_invite = try postAs(a, io, port, debbie, "/invites", "name=Odlle");
    const spaced_invite = try postAs(a, io, port, debbie, "/invites", "name=Ste+ve");
    const sign_up_line = try signUpLine(a, try signInByGitHub(a, io, port, fake, "user-id-55"));
    const reserved_up = try chooseName(a, io, port, sign_up_line, "Support");
    const close_up = try chooseName(a, io, port, sign_up_line, "N+oor");
    try t.check("a reserved name or one that looks like another's, by invite or sign-up: 409 each, saying which, nothing made", reserved_invite.status == 409 and
        has(reserved_invite.body, "The name is reserved") and close_invite.status == 409 and has(close_invite.body, "too close to one the chat already has") and
        spaced_invite.status == 409 and has(spaced_invite.body, "too close") and asksForName(reserved_up, 409) and has(reserved_up.body, "The name is reserved") and
        asksForName(close_up, 409) and has(close_up.body, "too close") and try nextId(a, io, data) == before_noor);

    // 48zt3.
    const pia_id = try nextId(a, io, data);
    const pia_invited = try postAs(a, io, port, debbie, "/invites", "name=Pia");
    const pia_link = between(pia_invited.body, "<p class=\"invite-code\">", "</p>") orelse return error.NoLink;
    const pia_hash = std.mem.indexOfScalar(u8, pia_link, '#') orelse return error.NoCode;
    const while_open = try postAs(a, io, port, debbie, "/invites", "name=Pla");
    try data.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "auth/{d}/human-invites/1/expires", .{pia_id}), .data = "1000" });
    const anew = try postAs(a, io, port, debbie, "/invites", "name=Pia");
    const general = try readFile(a, io, data, "chat/channel/general.channel");
    const old_code = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Pia&password=x", .{pia_link[pia_hash + 1 ..]}));
    const owner_browse = try getAs(a, io, port, steve_session, "/chat");
    try t.check("an invite open holds its name, a lookalike too: 409; once it expires unredeemed, the name is free: a new account holds it, the old one released, out of #general, its code refused; the owner's pages still answer", pia_invited.status == 200 and
        while_open.status == 409 and anew.status == 200 and has(anew.body, "invite-code") and
        std.mem.eql(u8, try readFile(a, io, data, try std.fmt.allocPrint(a, "auth/{d}/name", .{pia_id + 1})), "Pia") and
        (try std.fmt.parseInt(i64, try readFile(a, io, data, try std.fmt.allocPrint(a, "auth/{d}/name-released", .{pia_id})), 10)) > 1000 and
        !has(general, try std.fmt.allocPrint(a, "\n{d}\n", .{pia_id})) and has(general, try std.fmt.allocPrint(a, "\n{d}\n", .{pia_id + 1})) and
        old_code.status == 401 and owner_browse.status == 200);

    // 48zt4.
    const quin_id = try nextId(a, io, data);
    const quin_invited = try postAs(a, io, port, debbie, "/invites", "name=Quin");
    const annex = try postAs(a, io, port, steve_session, "/channels", "name=annex");
    const quin_in_annex = try postAs(a, io, port, steve_session, try std.fmt.allocPrint(a, "/channels/annex/members/{d}/add", .{quin_id}), "");
    try data.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "auth/{d}/human-invites/1/expires", .{quin_id}), .data = "1000" });
    const quin_released = try std.fmt.allocPrint(a, "auth/{d}/name-released", .{quin_id});
    const quin_line = try std.fmt.allocPrint(a, "{d}\n", .{quin_id});
    const replayed = try chooseName(a, io, port, noor_line, "Quin");
    const after_replay = try nextId(a, io, data);
    try t.check("a sign-up refused once its name is judged (Noor's sign-up, its id holding an account, replayed with a lapsed invitee's name): nothing released, Quin still in #annex, no id spent", quin_invited.status == 200 and
        annex.status == 303 and quin_in_annex.status == 303 and replayed.status != 303 and !has(replayed.head, "__Host-gopher_auth=") and
        !(try exists(io, data, quin_released)) and has(try readFile(a, io, data, "chat/channel/annex.channel"), quin_line) and after_replay == quin_id + 1);

    // 48zt5.
    const quin_anew = try postAs(a, io, port, debbie, "/invites", "name=Quin");
    const annex_after = try readFile(a, io, data, "chat/channel/annex.channel");
    var all_answer = true;
    for ([_][]const u8{ "/chat", "/channels", "/channels/annex", "/channels/general", "/invites", "/agents", "/devices" }) |path| {
        const page = try getAs(a, io, port, steve_session, path);
        if (page.status != 200) all_answer = false;
    }
    const debbies = try getAs(a, io, port, debbie, "/invites");
    const debbies_browse = try getAs(a, io, port, debbie, "/chat");
    try t.check("Quin's name asked for again: released, out of #annex as well as #general, and the owner's pages and Debbie's each a 200", quin_anew.status == 200 and
        try exists(io, data, quin_released) and !has(annex_after, quin_line) and all_answer and debbies.status == 200 and debbies_browse.status == 200);

    // 48zt6.
    const rhea_id = try nextId(a, io, data);
    const rhea = try cookieLine(a, try signUpHeadingTo(a, io, port, fake, "/invites", "user-id-56", "Rhea"));
    var first_three = true;
    for ([_][]const u8{ "Sela", "Tova", "Uli" }) |name| {
        const made = try postAs(a, io, port, rhea, "/invites", try std.fmt.allocPrint(a, "name={s}", .{name}));
        if (made.status != 200 or !has(made.body, "invite-code")) first_three = false;
    }
    // Uli's invite cut short as it was written, its hash never made: still
    // counted, as an account Rhea made.
    try data.deleteFile(io, try std.fmt.allocPrint(a, "auth/{d}/human-invites/1/hash", .{rhea_id + 3}));
    const before_fourth = try nextId(a, io, data);
    const fourth = try postAs(a, io, port, rhea, "/invites", "name=Vida");
    const rhea_page = try getAs(a, io, port, rhea, "/invites");
    const again = try postAs(a, io, port, rhea, try std.fmt.allocPrint(a, "/invites/{d}/again", .{rhea_id + 1}), "");
    const limit_words = "In your first day here you can make at most 3 invites. You can invite again from ";
    try t.check("a GitHub sign-up in their first day: three invites, 200 each; the fourth a 403 saying when they may again, nothing made; their invites page has no form, saying so; inviting one of the three again, 200", first_three and
        fourth.status == 403 and has(fourth.body, limit_words) and try nextId(a, io, data) == before_fourth and
        rhea_page.status == 200 and !has(rhea_page.body, "action=\"/invites\"") and has(rhea_page.body, limit_words) and
        again.status == 200 and has(again.body, "invite-code"));
    try data.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "auth/{d}/joined", .{rhea_id}), .data = "1000" });
    const after_a_day = try postAs(a, io, port, rhea, "/invites", "name=Vida");
    try t.check("a day after joining, the fourth: 200", after_a_day.status == 200 and has(after_a_day.body, "invite-code"));

    // 48zt7.
    const opal_id = try nextId(a, io, data);
    const opal_invited = try postAs(a, io, port, debbie, "/invites", "name=Opal");
    const opal_link = between(opal_invited.body, "<p class=\"invite-code\">", "</p>") orelse return error.NoLink;
    const opal_hash = std.mem.indexOfScalar(u8, opal_link, '#') orelse return error.NoCode;
    const omar_id = try nextId(a, io, data);
    const omar_invited = try postAs(a, io, port, debbie, "/invites", "name=Omar");
    try data.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "auth/{d}/human-invites/1/expires", .{omar_id}), .data = "1000" });
    // A look-alike of Opal's name, from before the rule, written by hand.
    try data.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "auth/{d}/name", .{omar_id}), .data = "Opai" });
    const opal_joined = try anonymousPost(a, io, port, "/join", try std.fmt.allocPrint(a, "code={s}&name=Opal&password=their+own", .{opal_link[opal_hash + 1 ..]}));
    try t.check("a join that keeps its name frees no look-alike: Opal joins as Opal, and Opai, lapsed, keeps her name; the owner's Browse a 200", opal_invited.status == 200 and
        omar_invited.status == 200 and opal_joined.status == 303 and opal_id + 1 == omar_id and
        !(try exists(io, data, try std.fmt.allocPrint(a, "auth/{d}/name-released", .{omar_id}))) and
        std.mem.eql(u8, try readFile(a, io, data, try std.fmt.allocPrint(a, "auth/{d}/name", .{omar_id})), "Opai") and
        (try getAs(a, io, port, steve_session, "/chat")).status == 200);
}

/// Whether the new human `made` lands in #general: at `expected`, a page of
/// theirs, a 200.
fn landsAt(a: std.mem.Allocator, io: Io, port: u16, made: Response, expected: []const u8) !bool {
    const location = made.header("location") orelse return false;
    const page = try getAs(a, io, port, try cookieLine(a, made), location);
    return made.status == 303 and std.mem.eql(u8, location, expected) and page.status == 200 and has(page.body, "id=\"msg-12\"");
}

/// Steps 48zm, 48zn and 48zu, around the welcome's.
fn firstPageSteps(a: std.mem.Allocator, io: Io, port: u16, data: Io.Dir, t: Steps, fake: *fake_github.Fake) !void {
    // 48zm.
    const heading_there = try signUpHeadingTo(a, io, port, fake, channel_url, "user-id-40", "Una");
    try t.check("a new human heading for a conversation in #general: there, a 200, as a member; #general's file holds her", try landsAt(a, io, port, heading_there, channel_url) and
        has(try readFile(a, io, data, "chat/channel/general.channel"), "\n12\n"));
    const heading_to_crew = try signUpHeadingTo(a, io, port, fake, "/chat/channel/crew/plans", "user-id-41", "Vic");
    const heading_to_channels = try signUpHeadingTo(a, io, port, fake, "/channels", "user-id-42", "Wes");
    const heading_to_agents = try signUpHeadingTo(a, io, port, fake, "/agents", "user-id-43", "Xan");
    const heading_nowhere = try signUpHeadingTo(a, io, port, fake, "/chat/channel/general/no-such-topic", "user-id-44", "Yao");
    try t.check("heading for another channel's conversation, the admin's /channels, /agents, or a topic with no messages: their DM with the owner, a 200 each", try landsInWelcome(a, io, port, heading_to_crew, 13) and
        try landsInWelcome(a, io, port, heading_to_channels, 14) and try landsInWelcome(a, io, port, heading_to_agents, 15) and
        try landsInWelcome(a, io, port, heading_nowhere, 16));

    // 48zn.
    const members_path = "chat/channel/general.channel";
    const members = try readFile(a, io, data, members_path);
    const counter = try readFile(a, io, data, "auth/next-id.txt");
    const debbie = try cookieLine(a, try anonymousPost(a, io, port, "/login", "name=Debbie&password=a+new+one"));
    const begun = try startGitHub(a, io, port, fake);
    const back = try atGitHub(a, io, port, fake, .{ .authorize = begun.authorize, .code = "user-id-45" });
    const asked = try backFromGitHub(a, io, port, begun.cookie, back);
    try data.deleteFile(io, members_path);
    const signed_up = try chooseName(a, io, port, try signUpLine(a, asked), "Zed");
    const invited = try postAs(a, io, port, debbie, "/invites", "name=Zed");
    const counter_after = try readFile(a, io, data, "auth/next-id.txt");
    try data.writeFile(io, .{ .sub_path = members_path, .data = members });
    try t.check("with #general's members file gone, a sign-up and an invite: 500 each, saying so, no session, nothing made", signed_up.status == 500 and
        has(signed_up.body, "no general channel") and !has(signed_up.head, "__Host-gopher_auth=") and invited.status == 500 and has(invited.body, "no general channel") and
        std.mem.eql(u8, counter_after, counter));

    try welcomeSteps(a, io, port, data, t, fake, debbie);

    // 48zu.
    try data.writeFile(io, .{ .sub_path = "auth/next-id.txt", .data = "65535\n" });
    const last = try signUpHeadingTo(a, io, port, fake, channel_url, "user-id-46", "Omar");
    const last_page = try getAs(a, io, port, try cookieLine(a, last), "/invites");
    const past_the_last = try signUpHeadingTo(a, io, port, fake, channel_url, "user-id-47", "Pia");
    try t.check("one id left: a new human takes 65535, in #general, their session reading their page; the counter 65536; the next sign-up, a 409 saying the chat is full, nothing made", try landsAt(a, io, port, last, channel_url) and
        last_page.status == 200 and has(last_page.body, "Omar") and std.mem.eql(u8, try readFile(a, io, data, "auth/65535/name"), "Omar") and
        has(try readFile(a, io, data, members_path), "\n65535\n") and std.mem.eql(u8, try readFile(a, io, data, "auth/next-id.txt"), "65536\n") and
        past_the_last.status == 409 and has(past_the_last.body, "holds as many as it can") and !(try exists(io, data, "auth/65536")));
}

/// The number of the device key the session `signed_in` sets is bound to,
/// its cookie's fourth part after its `d`; null for a session no code
/// started.
fn deviceKeyOf(signed_in: Response) ?[]const u8 {
    const cookie = signed_in.header("set-cookie") orelse return null;
    const end = std.mem.indexOfScalar(u8, cookie, ';') orelse return null;
    const value = cookie[0..end];
    if (std.mem.count(u8, value, ".") != 3) return null;
    const part = value[std.mem.lastIndexOfScalar(u8, value, '.').? + 1 ..];
    if (part.len < 2 or part[0] != 'd') return null;
    for (part[1..]) |c| if (!std.ascii.isDigit(c)) return null;
    return part[1..];
}

/// The session cookie a sign-in's answer sets, as a request's `Cookie`
/// line, or none.
fn cookieLine(a: std.mem.Allocator, signed_in: Response) ![]const u8 {
    const cookie = signed_in.header("set-cookie") orelse return "";
    const end = std.mem.indexOfScalar(u8, cookie, ';') orelse return "";
    return std.fmt.allocPrint(a, "cookie: {s}\r\n", .{cookie[0..end]});
}

/// A GET of `path` with the `Cookie` line `cookie`.
fn getAs(a: std.mem.Allocator, io: Io, port: u16, cookie: []const u8, path: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nhost: localhost:{d}\r\n{s}\r\n", .{ path, port, cookie }));
}

/// A form POSTed to `path` with the `Cookie` line `cookie`.
fn postAs(a: std.mem.Allocator, io: Io, port: u16, cookie: []const u8, path: []const u8, form: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nhost: localhost:{d}\r\n{s}content-type: application/x-www-form-urlencoded\r\ncontent-length: {d}\r\n\r\n{s}", .{ path, port, cookie, form.len, form }));
}

/// The file `path` of `dir`, whole.
fn readFile(a: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) ![]const u8 {
    return dir.readFileAlloc(io, path, a, .limited(32 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => "(none)",
        else => e,
    };
}

/// Whether anything is at `path` in `dir`.
fn exists(io: Io, dir: Io.Dir, path: []const u8) !bool {
    _ = dir.statFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    return true;
}

/// Every file under the folder `path` of `dir` (`""` for `dir` itself),
/// each by its path from `dir`, appended to `out`.
fn allFiles(a: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var folder = if (path.len == 0) try dir.openDir(io, ".", .{ .iterate = true }) else try dir.openDir(io, path, .{ .iterate = true });
    defer folder.close(io);
    var it = folder.iterate();
    while (try it.next(io)) |entry| {
        const sub = if (path.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ path, entry.name });
        switch (entry.kind) {
            .directory => try allFiles(a, io, dir, sub, out),
            .file => try out.append(a, sub),
            else => {},
        }
    }
}

/// The text of `body` between the first `from` and the `to` after it.
fn between(body: []const u8, from: []const u8, to: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, body, from) orelse return null) + from.len;
    const end = std.mem.indexOfPos(u8, body, start, to) orelse return null;
    return body[start..end];
}

/// Whether `text` is `prefix` and then 64 lowercase hex digits.
fn isToken(text: []const u8, prefix: []const u8) bool {
    if (text.len != prefix.len + 64 or !std.mem.startsWith(u8, text, prefix)) return false;
    for (text[prefix.len..]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// A GET of `path`, with `more` headers (each ending CRLF).
fn getWith(a: std.mem.Allocator, io: Io, port: u16, path: []const u8, more: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nhost: localhost:{d}\r\n{s}{s}\r\n", .{ path, port, steve_session, more }));
}

/// A stream held open: its head read whole, then its events one at a
/// time. Each of those waits has `wait_ms`, after which a watchdog shuts
/// the connection, so a frame that never comes fails its step rather than
/// hang the run. No watchdog runs between waits, so a stream may stay open
/// across any number of requests.
const Stream = struct {
    a: std.mem.Allocator,
    io: Io,
    connection: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    head: []const u8,
    buf: *[64 * 1024]u8,

    const wait_ms = 5_000;

    fn open(a: std.mem.Allocator, io: Io, port: u16, comptime path: []const u8) !*Stream {
        return openWith(a, io, port, path, "");
    }

    /// A stream opened with `more` headers, each ending CRLF.
    fn openWith(a: std.mem.Allocator, io: Io, port: u16, path: []const u8, more: []const u8) !*Stream {
        const s = try a.create(Stream);
        s.a = a;
        s.io = io;
        s.buf = try a.create([64 * 1024]u8);
        const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
        s.connection = try addr.connect(io, .{ .mode = .stream });
        var watchdog = try io.concurrent(shutAfter, .{ io, s.connection, wait_ms });
        s.head = s.request(path, port, more) catch |e| return s.waitFailed(&watchdog, e);
        _ = watchdog.cancel(io);
        return s;
    }

    /// The stream's GET sent, and its head read whole.
    fn request(s: *Stream, path: []const u8, port: u16, more: []const u8) ![]const u8 {
        var w = s.connection.writer(s.io, &.{});
        try w.interface.writeAll(try std.fmt.allocPrint(s.a, "GET {s} HTTP/1.1\r\nhost: localhost:{d}\r\naccept: text/event-stream\r\n{s}{s}\r\n", .{ path, port, steve_session, more }));
        s.reader = s.connection.reader(s.io, s.buf);
        var head: std.ArrayList(u8) = .empty;
        while (!std.mem.endsWith(u8, head.items, "\r\n\r\n")) try head.append(s.a, try s.reader.interface.takeByte());
        return head.items;
    }

    /// `e`, a wait's failure, once its watchdog is ended, saying so when
    /// the watchdog is what shut the stream.
    fn waitFailed(s: *Stream, watchdog: *Io.Future(bool), e: anyerror) anyerror {
        if (watchdog.cancel(s.io)) std.debug.print("the stream sent nothing for {d} ms, so its watchdog shut it\n", .{wait_ms});
        return e;
    }

    fn close(s: *Stream) void {
        s.connection.close(s.io);
    }

    fn header(s: *const Stream, comptime name: []const u8) ?[]const u8 {
        const r: Response = .{ .status = 0, .head = s.head[0 .. s.head.len - 2], .body = "" };
        return r.header(name);
    }

    fn isEventStream(s: *const Stream) bool {
        return std.mem.startsWith(u8, s.head, "HTTP/1.1 200 ") and
            std.mem.eql(u8, s.header("content-type") orelse "", "text/event-stream") and
            std.mem.eql(u8, s.header("cache-control") orelse "", "no-cache") and
            std.mem.eql(u8, s.header("x-content-type-options") orelse "", "nosniff");
    }

    /// The next event, its lines to the blank one that ends it. The
    /// server's keepalive (`sse.ping`), a comment, is no event and is
    /// passed.
    fn event(s: *Stream) ![]const u8 {
        while (true) {
            var watchdog = try s.io.concurrent(shutAfter, .{ s.io, s.connection, wait_ms });
            const got = s.frame() catch |e| return s.waitFailed(&watchdog, e);
            _ = watchdog.cancel(s.io);
            if (!std.mem.eql(u8, got, sse.ping)) return got;
        }
    }

    /// The next frame, a ping's included.
    fn frame(s: *Stream) ![]const u8 {
        var bytes: std.ArrayList(u8) = .empty;
        while (true) {
            const line = try s.reader.interface.takeDelimiterInclusive('\n');
            try bytes.appendSlice(s.a, line);
            if (line.len == 1) return bytes.items;
        }
    }

    /// The next event that starts with none of `skip`. One that doesn't
    /// start with `want` is printed, then given back all the same, so the
    /// step that reads it fails by its own name with the event in view.
    fn expectEvent(s: *Stream, comptime want: []const u8, comptime skip: []const []const u8) ![]const u8 {
        next: while (true) {
            const e = try s.event();
            inline for (skip) |passed| if (std.mem.startsWith(u8, e, passed)) continue :next;
            if (!std.mem.startsWith(u8, e, want)) std.debug.print("wanted an event starting `{s}`, got:\n{s}", .{ want, e });
            return e;
        }
    }
};

/// Whether it shut `connection`, having slept `ms` without being cancelled.
fn shutAfter(io: Io, connection: Io.net.Stream, ms: u32) bool {
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch return false;
    connection.shutdown(io, .both) catch {};
    return true;
}

/// The frame a stream sends for the message `id` that `page` shows: `id:`,
/// then its article's HTML, to the line after it, a `data:` line a line,
/// then a blank line.
fn frameOf(a: std.mem.Allocator, page: []const u8, comptime id: []const u8) ![]const u8 {
    const from = std.mem.indexOf(u8, page, "<article class=\"message\" id=\"msg-" ++ id ++ "\"") orelse return error.NoSuchMessage;
    const to = (std.mem.indexOfPos(u8, page, from, "</article>\n") orelse return error.NoSuchMessage) + "</article>\n".len;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "id: " ++ id ++ "\n");
    var lines = std.mem.splitScalar(u8, page[from..to], '\n');
    while (lines.next()) |line| try out.print(a, "data: {s}\n", .{line});
    try out.append(a, '\n');
    return out.items;
}

/// The HTML of the message `id` that `page` shows, as the page writes it:
/// its article, and the line feed after it.
fn articleOf(page: []const u8, comptime id: []const u8) ![]const u8 {
    const from = std.mem.indexOf(u8, page, "<article class=\"message\" id=\"msg-" ++ id ++ "\"") orelse return error.NoSuchMessage;
    const to = (std.mem.indexOfPos(u8, page, from, "</article>\n") orelse return error.NoSuchMessage) + "</article>\n".len;
    return page[from..to];
}

/// Each step said on its own line, with the time since the start; a step
/// that fails fails the run, naming it.
const Steps = struct {
    io: Io,
    began: Io.Timestamp,

    fn check(s: Steps, comptime what: []const u8, ok: bool) !void {
        const ms: u64 = @intCast(s.began.untilNow(s.io, .awake).toMilliseconds());
        std.debug.print("{s}  {d:>5} ms  " ++ what ++ "\n", .{ if (ok) "PASS" else "FAIL", ms });
        if (!ok) return error.EndToEndStepFailed;
    }
};

/// Whether `file` is `seed` and one record more, `MSG_<reference>`, by
/// Steve, its markdown `body`, dated a second from `from` to `to`.
fn recordFits(a: std.mem.Allocator, file: []const u8, seed: []const u8, reference: []const u8, body: []const u8, from: i64, to: i64) bool {
    var second = from;
    while (second <= to) : (second += 1) {
        const want = std.fmt.allocPrint(a, "{s}-------------\nMSG_{s}\nfrom: Steve\ndate: {f}\n\n{s}\n\n", .{ seed, reference, Iso{ .seconds = second }, body }) catch return false;
        if (std.mem.eql(u8, file, want)) return true;
    }
    return false;
}

/// A time as a transcript writes it, YYYY-MM-DDTHH:MM:SSZ: std's calendar,
/// a second opinion on app/DateTime.roc's.
const Iso = struct {
    seconds: i64,

    pub fn format(t: Iso, w: *Io.Writer) Io.Writer.Error!void {
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(t.seconds) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            yd.year,
            md.month.numeric(),
            md.day_index + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        });
    }
};

const Response = struct {
    status: u16,
    head: []const u8,
    body: []const u8,

    fn header(r: Response, comptime name: []const u8) ?[]const u8 {
        const at = std.mem.indexOf(u8, r.head, "\r\n" ++ name ++ ": ") orelse return null;
        const from = at + name.len + 4;
        const to = std.mem.indexOfPos(u8, r.head, from, "\r\n") orelse return null;
        return r.head[from..to];
    }
};

/// A GET of `path`, its Host this server's, as Steve's browser's would be,
/// his session carried, as every helper here but the anonymous ones does.
fn get(a: std.mem.Allocator, io: Io, port: u16, comptime path: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "GET " ++ path ++ " HTTP/1.1\r\nhost: localhost:{d}\r\n{s}\r\n", .{ port, steve_session }));
}

/// A form POSTed to `path`, its Host this server's, of `content_type`, with
/// `more` headers (each ending CRLF; none, as curl sends).
const Post = struct { path: []const u8, form: []const u8, content_type: []const u8 = "application/x-www-form-urlencoded", more: []const u8 = "" };

fn post(a: std.mem.Allocator, io: Io, port: u16, p: Post) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(
        a,
        "POST {s} HTTP/1.1\r\nhost: localhost:{d}\r\n{s}content-type: {s}\r\ncontent-length: {d}\r\n{s}\r\n{s}",
        .{ p.path, port, steve_session, p.content_type, p.form.len, p.more, p.form },
    ));
}

/// A GET of `path`, a path made as the run goes.
fn getAt(a: std.mem.Allocator, io: Io, port: u16, path: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nhost: localhost:{d}\r\n{s}\r\n", .{ path, port, steve_session }));
}

/// The compose box's form for one file, `data`, named `filename`, as a
/// browser sends it under `upload_type`.
fn uploadForm(a: std.mem.Allocator, filename: []const u8, data: []const u8) ![]const u8 {
    const boundary = upload_type["multipart/form-data; boundary=".len..];
    return std.fmt.allocPrint(a, "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: image/png\r\n\r\n{s}\r\n--{s}--\r\n", .{ boundary, filename, data, boundary });
}

/// `markdown` as the compose box's form field, percent-encoded.
fn formEncoded(a: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "markdown=");
    for (markdown) |c| {
        if (std.ascii.isAlphanumeric(c)) try out.append(a, c) else try out.print(a, "%{X:0>2}", .{c});
    }
    return out.items;
}

/// The `url` an upload's JSON answer names, or null.
fn jsonUrl(body: []const u8) ?[]const u8 {
    const key = "{\"url\":\"";
    if (!std.mem.startsWith(u8, body, key)) return null;
    const end = std.mem.indexOfScalarPos(u8, body, key.len, '"') orelse return null;
    return body[key.len..end];
}

/// Whether `name` is a fresh image's: 32 lowercase hex digits, then `ext`.
fn isFreshName(name: []const u8, comptime ext: []const u8) bool {
    if (name.len != 32 + ext.len or !std.mem.endsWith(u8, name, ext)) return false;
    for (name[0..32]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// The names in the folder `path` of `dir`.
fn namesIn(a: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) ![]const []const u8 {
    var folder = try dir.openDir(io, path, .{ .iterate = true });
    defer folder.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = folder.iterate();
    while (try it.next(io)) |entry| try names.append(a, try a.dupe(u8, entry.name));
    return names.items;
}

/// Steve's upload total file, as it is on disk, or `no_total`.
fn uploadTotal(a: std.mem.Allocator, io: Io, dir: Io.Dir) ![]const u8 {
    return dir.readFileAlloc(io, total_path, a, .limited(1024)) catch |e| switch (e) {
        error.FileNotFound => no_total,
        else => e,
    };
}

/// A PNG of one pixel, whole and valid: its signature, then the IHDR,
/// IDAT and IEND chunks, the pixel's row in a stored zlib block.
fn onePixelPng(a: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n");
    // One by one, 8 bits, RGB.
    try pngChunk(a, &out, "IHDR", "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00");
    const row = "\x00\x80\x00\xff";
    var idat: std.ArrayList(u8) = .empty;
    try idat.appendSlice(a, "\x78\x01\x01\x04\x00\xfb\xff" ++ row);
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(row), .big);
    try idat.appendSlice(a, &adler);
    try pngChunk(a, &out, "IDAT", idat.items);
    try pngChunk(a, &out, "IEND", "");
    return out.items;
}

fn pngChunk(a: std.mem.Allocator, out: *std.ArrayList(u8), comptime kind: []const u8, bytes: []const u8) !void {
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, @intCast(bytes.len), .big);
    try out.appendSlice(a, &word);
    const start = out.items.len;
    try out.appendSlice(a, kind);
    try out.appendSlice(a, bytes);
    std.mem.writeInt(u32, &word, std.hash.Crc32.hash(out.items[start..]), .big);
    try out.appendSlice(a, &word);
}

/// `request` on a connection of its own, and the response, read to the
/// close.
fn exchange(a: std.mem.Allocator, io: Io, port: u16, request: []const u8) !Response {
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const connection = try addr.connect(io, .{ .mode = .stream });
    defer connection.close(io);
    var w = connection.writer(io, &.{});
    try w.interface.writeAll(request);
    var buf: [4096]u8 = undefined;
    var r = connection.reader(io, &buf);
    const bytes = try r.interface.allocRemaining(a, .limited(64 * 1024 * 1024));
    if (!std.mem.startsWith(u8, bytes, "HTTP/1.1 ") or bytes.len < 12) return error.NotAResponse;
    const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.NoHeadEnd;
    return .{ .status = try std.fmt.parseInt(u16, bytes[9..12], 10), .head = bytes[0 .. end + 2], .body = bytes[end + 4 ..] };
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

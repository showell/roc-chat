//! The end to end runs the real server, with the app linked, on a free port
//! of 127.0.0.1, on a task of this process, against a temporary data root
//! seeded from demo/data. It drives the server over HTTP, one step a line,
//! timed:
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
//!   4b. POST exactly as a browser submits the compose box (form-encoded,
//!      its newline CRLF, `Origin` this server, `Sec-Fetch-Site`
//!      same-origin, a navigation's other headers): a 303 to the page, and
//!      exactly one record more on disk, its newline LF;
//!   5. GET a DM's conversation with no transcript, and its stream: the
//!      404 page each, since only a message's POST starts a conversation;
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
//!      message's frame, so it got nothing of the DM's;
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
//!  21. upload a file that is no image: 415, in the old words;
//!  22. upload an image of exactly 10 MiB: 200; of one byte more: 413, in
//!      the old words;
//!  23. upload from another origin's page, and one the browser says is
//!      cross-site: 403 each;
//!  24. the channel's uploads on disk: exactly the PNG and the 10 MiB image,
//!      nothing of 21, the second half of 22, or 23; the upload total
//!      exactly their bytes;
//!  25. a message holding an `<img>` of the PNG, as the compose box inserts
//!      it: on the channel's page an image; posted to the DM, text.
//!  26. the total seeded one byte short of room for the PNG: its upload a
//!      403 in the Zig chat's words, nothing stored, the total unchanged;
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
//!      navigate): 200, the page.
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
//!  39. invite CC: the page shows its code, once; redeem it: 200, the key on
//!      one line; redeem it again: 401;
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
//!  47. revoke the key: a 303, and the key is then a 401;
//!  48. on disk: the key's hash is SHA-256 of its secret, and no file under
//!      the data root holds the key's secret or any invite's code.
//!
//! Step 2 posts as the README's `curl` does: `Host: localhost:<port>`, no
//! `Origin`, no `Sec-Fetch-Site`.
//!
//! The server stops and the data root goes before it returns, pass or
//! fail, so nothing is left running and nothing is left behind.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const files = @import("file_primitives.zig");

const seed_path = "demo/data/chat/channel/general/gopher-roc/transcript";
const frozen_page = "demo/gopher-roc.html";
const channel_url = "/chat/channel/general/gopher-roc";
const script_url = "/chat/assets/compose.js";
const script_file = "app/compose.js";
/// The page's other scripts, each served as compose.js is.
const other_scripts = [_][]const u8{ "palette.js", "chrome.js", "feed.js" };
const dm_url = "/chat/dm/1_1/plans";
const dm_transcript = "chat/dm/1_1/plans/transcript";
const channel_uploads = "chat/channel/general/gopher-roc/uploads";
/// Where the DM's uploads folder would be; step 28a puts a plain file there.
const dm_uploads = "chat/dm/1_1/plans/uploads";
/// Steve's upload total, the bytes he has uploaded, in his own folder.
const total_path = "users/1/upload-bytes";
/// What `uploadTotal` says when there is no total file.
const no_total = "(none)";
/// A browser's own boundary, as Chrome writes one.
const upload_type = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW";

const RunResult = @typeInfo(@TypeOf(http.Server.run)).@"fn".return_type.?;

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

    const root: files.DataRoot = .{ .io = io, .dir = data };
    var server = try http.Server.listen(io, gpa, 0, .{}, &root);
    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch |e| std.debug.print("end-to-end: the server's run: {t}\n", .{e});
    }
    const port = server.port();
    const t: Steps = .{ .io = io, .began = began };

    // 1.
    const first = try get(a, io, port, channel_url);
    try t.check("GET the seeded conversation: 200, exactly the demo's frozen page", first.status == 200 and
        std.mem.eql(u8, first.body, try cwd.readFileAlloc(io, frozen_page, a, .limited(1024 * 1024))));
    const policy = first.header("content-security-policy") orelse "";
    try t.check("its defences: the content security policy, scripts from this origin alone, and nosniff, as sent", std.mem.startsWith(u8, policy, "default-src 'none'; ") and
        has(policy, "; script-src 'self'; ") and !has(policy, "unsafe-eval") and !has(policy, "script-src 'unsafe-inline'") and
        std.mem.eql(u8, first.header("x-content-type-options") orelse "", "nosniff"));
    try t.check("its compose box: a form posting `markdown` to the conversation's own URL, sending to its `/send`, uploading to its `/upload`, and the script", has(first.body, "<form method=\"post\" action=\"" ++ channel_url ++ "\" data-send=\"" ++ channel_url ++ "/send\" data-upload=\"" ++ channel_url ++ "/upload\" data-image-byte-limit=\"10485760\"><textarea name=\"markdown\" required></textarea>") and
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
        has(again.body, "<strong>end to end</strong>!") and has(again.body, "id=\"msg-6\"") and has(again.body, ">MSG_gopher-roc_6</a>"));

    // 4.
    const body = "Hello from the **end to end**!\n\n\\-------------";
    const on_disk = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    try t.check("the file on disk: the seed and exactly one record, dated by the host's clock", recordFits(a, on_disk, seed, "gopher-roc_6", body, before, after));

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
        recordFits(a, box_disk, on_disk, "gopher-roc_7", "Sent from the compose box\na second line · & more", before_box, after_box));

    // 5.
    const missing = try get(a, io, port, dm_url);
    const missing_stream = try get(a, io, port, dm_url ++ "/stream?after=0");
    try t.check("GET a DM's conversation with no transcript, and its stream: 404 each, saying so", missing.status == 404 and
        has(missing.body, "No such conversation: " ++ dm_url) and missing_stream.status == 404 and
        has(missing_stream.body, "No such conversation: " ++ dm_url));

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
    try t.check("POST to the channel again: its stream's next event is exactly that message's frame, none of the DM's", again_live.status == 303 and
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
    try t.check("upload a file that is no image: 415, in the old words", text.status == 415 and
        std.mem.eql(u8, text.body, "unsupported file type (images: png, jpeg, gif, webp)\n"));

    // 22.
    const most = 10 * 1024 * 1024;
    const big = try a.alloc(u8, most + 1);
    @memset(big, 0);
    @memcpy(big[0..png.len], png);
    const at_most = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "big.png", big[0..most]), .more = own_page });
    const at_most_url = jsonUrl(at_most.body) orelse "";
    const over = try post(a, io, port, .{ .path = channel_url ++ "/upload", .content_type = upload_type, .form = try uploadForm(a, "big.png", big), .more = own_page });
    try t.check("upload an image of exactly 10 MiB: 200; of one byte more: 413, in the old words", at_most.status == 200 and
        std.mem.startsWith(u8, at_most_url, image_prefix) and isFreshName(at_most_url[image_prefix.len..], ".png") and
        over.status == 413 and std.mem.eql(u8, over.body, "image too large — the limit is 10 MB.\n"));

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
    try t.check("upload a PNG one byte past Steve's 1 GiB allowance: 403, in the Zig chat's words; nothing stored or counted", spent.status == 403 and
        std.mem.eql(u8, spent.body, "Upload limit reached — you've used your 1 GB upload allowance.\n") and
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
        recordFits(a, after_send, before_send, "gopher-roc_11", "Sent **without** a reload\ntwo lines", sent_before, sent_after));
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
    const followed = try exchange(a, io, port, try std.fmt.allocPrint(a, "GET " ++ channel_url ++ " HTTP/1.1\r\nhost: localhost:{d}\r\n" ++
        "sec-fetch-site: cross-site\r\nsec-fetch-mode: navigate\r\nsec-fetch-dest: document\r\nsec-fetch-user: ?1\r\n\r\n", .{port}));
    try t.check("follow a link to the channel's page from another site: 200, the page", followed.status == 200 and
        has(followed.body, "id=\"msg-12\""));

    try agentSteps(a, io, port, data, t);

    std.debug.print("end-to-end: every step passed, in {d} ms\n", .{began.untilNow(io, .awake).toMilliseconds()});
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
    const redeemed = try post(a, io, port, .{ .path = "/agents/redeem", .form = try std.fmt.allocPrint(a, "code={s}", .{code}) });
    const key = std.mem.trimEnd(u8, redeemed.body, "\n");
    const again = try post(a, io, port, .{ .path = "/agents/redeem", .form = try std.fmt.allocPrint(a, "code={s}", .{code}) });
    try t.check("invite CC: its code shown once; redeemed: 200, the key on one line, `2-` and 64 hex digits; redeemed again: 401", invited.status == 200 and
        isToken(code, "2-") and redeemed.status == 200 and isToken(key, "2-") and !std.mem.eql(u8, key, code) and
        std.mem.eql(u8, redeemed.header("content-type") orelse "", "text/plain; charset=utf-8") and
        again.status == 401 and std.mem.eql(u8, again.body, "The invite code is not live.\n"));
    const bearer = try std.fmt.allocPrint(a, "authorization: Bearer {s}\r\n", .{key});

    // 40.
    const second = try post(a, io, port, .{ .path = "/agents/2/invites", .form = "" });
    const late_code = between(second.body, "<p class=\"invite-code\">", "</p>") orelse "";
    try data.writeFile(io, .{ .sub_path = "auth/2/invites/2/expires", .data = "1000" });
    const late = try post(a, io, port, .{ .path = "/agents/redeem", .form = try std.fmt.allocPrint(a, "code={s}", .{late_code}) });
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
        std.mem.startsWith(u8, added, "-------------\nMSG_gopher-roc_13\nfrom: CC\ndate: ") and std.mem.endsWith(u8, added, "\n\nHello from CC\n\n"));
    try t.check("CC's stream: that message, one line of JSON", std.mem.startsWith(u8, cc_event, "data: {\"conversation\":\"" ++ channel_url ++ "\",\"id\":13,\"from\":\"CC\",\"date\":\"") and
        std.mem.endsWith(u8, cc_event, "\",\"markdown\":\"Hello from CC\"}\n\n"));

    // 43.
    const in_private = try post(a, io, port, .{ .path = "/chat/channel/private/secrets", .form = "markdown=Not+for+CC" });
    const in_general = try post(a, io, port, .{ .path = channel_url, .form = "markdown=For+CC+too" });
    const next_event = try listening.event();
    const cc_private = try post(a, io, port, .{ .path = "/chat/channel/private/secrets", .form = "markdown=Let+me+in", .more = bearer });
    const cc_private_read = try getWith(a, io, port, "/chat/channel/private/secrets/raw", bearer);
    try t.check("Steve posts in #private, then #general: CC's next event is #general's, none of #private's", in_private.status == 303 and in_general.status == 303 and
        std.mem.startsWith(u8, next_event, "data: {\"conversation\":\"" ++ channel_url ++ "\",\"id\":14,\"from\":\"Steve\",") and
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
    const scoped_key = std.mem.trimEnd(u8, (try post(a, io, port, .{ .path = "/agents/redeem", .form = try std.fmt.allocPrint(a, "code={s}", .{scoped_code}) })).body, "\n");
    const scoped_bearer = try std.fmt.allocPrint(a, "authorization: Bearer {s}\r\n", .{scoped_key});
    const scoped_read = try getWith(a, io, port, channel_url ++ "/raw", scoped_bearer);
    const scoped_post = try post(a, io, port, .{ .path = channel_url, .form = "markdown=Scoped", .more = scoped_bearer });
    var scoped_stream = try Stream.openWith(a, io, port, "/agents/stream", scoped_bearer);
    defer scoped_stream.close();
    try t.check("a key invited with read=off and post=off: reading, posting and listening are 403 each", isToken(scoped_key, "2-") and
        std.mem.eql(u8, try readFile(a, io, data, "auth/2/keys/2/read"), "off") and
        scoped_read.status == 403 and scoped_post.status == 403 and std.mem.startsWith(u8, scoped_stream.head, "HTTP/1.1 403 "));

    // 47.
    const revoked = try post(a, io, port, .{ .path = "/agents/2/keys/1/revoke", .form = "" });
    const after_revoke = try getWith(a, io, port, channel_url ++ "/raw", bearer);
    try t.check("revoke the key: 303; the key is then a 401; its state on disk revoked", revoked.status == 303 and after_revoke.status == 401 and
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

/// The file `path` of `dir`, whole.
fn readFile(a: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) ![]const u8 {
    return dir.readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |e| switch (e) {
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
    return exchange(a, io, port, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nhost: localhost:{d}\r\n{s}\r\n", .{ path, port, more }));
}

/// A stream held open: its head read whole, then its events one at a
/// time. A watchdog shuts it after `stream_ms`, so a frame that never comes
/// fails its step rather than hang the run.
const Stream = struct {
    a: std.mem.Allocator,
    io: Io,
    connection: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    watchdog: Io.Future(void),
    head: []const u8,
    buf: *[64 * 1024]u8,

    const stream_ms = 5_000;

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
        s.watchdog = try io.concurrent(shutAfter, .{ io, s.connection, stream_ms });
        var w = s.connection.writer(io, &.{});
        try w.interface.writeAll(try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nhost: localhost:{d}\r\naccept: text/event-stream\r\n{s}\r\n", .{ path, port, more }));
        s.reader = s.connection.reader(io, s.buf);
        var head: std.ArrayList(u8) = .empty;
        while (!std.mem.endsWith(u8, head.items, "\r\n\r\n")) try head.append(a, try s.reader.interface.takeByte());
        s.head = head.items;
        return s;
    }

    fn close(s: *Stream) void {
        s.watchdog.cancel(s.io);
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

    /// The next event, its lines to the blank one that ends it.
    fn event(s: *Stream) ![]const u8 {
        var bytes: std.ArrayList(u8) = .empty;
        while (true) {
            const line = try s.reader.interface.takeDelimiterInclusive('\n');
            try bytes.appendSlice(s.a, line);
            if (line.len == 1) return bytes.items;
        }
    }
};

fn shutAfter(io: Io, connection: Io.net.Stream, ms: u32) void {
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch return;
    connection.shutdown(io, .both) catch {};
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

/// A GET of `path`, its Host this server's, as a browser's would be.
fn get(a: std.mem.Allocator, io: Io, port: u16, comptime path: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "GET " ++ path ++ " HTTP/1.1\r\nhost: localhost:{d}\r\n\r\n", .{port}));
}

/// A form POSTed to `path`, its Host this server's, of `content_type`, with
/// `more` headers (each ending CRLF; none, as curl sends).
const Post = struct { path: []const u8, form: []const u8, content_type: []const u8 = "application/x-www-form-urlencoded", more: []const u8 = "" };

fn post(a: std.mem.Allocator, io: Io, port: u16, p: Post) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(
        a,
        "POST {s} HTTP/1.1\r\nhost: localhost:{d}\r\ncontent-type: {s}\r\ncontent-length: {d}\r\n{s}\r\n{s}",
        .{ p.path, port, p.content_type, p.form.len, p.more, p.form },
    ));
}

/// A GET of `path`, a path made as the run goes.
fn getAt(a: std.mem.Allocator, io: Io, port: u16, path: []const u8) !Response {
    return exchange(a, io, port, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nhost: localhost:{d}\r\n\r\n", .{ path, port }));
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
    const bytes = try r.interface.allocRemaining(a, .limited(4 * 1024 * 1024));
    if (!std.mem.startsWith(u8, bytes, "HTTP/1.1 ") or bytes.len < 12) return error.NotAResponse;
    const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.NoHeadEnd;
    return .{ .status = try std.fmt.parseInt(u16, bytes[9..12], 10), .head = bytes[0 .. end + 2], .body = bytes[end + 4 ..] };
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

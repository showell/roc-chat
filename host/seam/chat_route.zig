//! **WHAT THE ROC CHAT ANSWERS, AND THE TAGS THAT CROSS THE SEAM**: the
//! decision a request's Roc call ends in, as the host sends it, and each
//! tag union of Chat.roc's and Host.roc's, as an enum.
//!
//! **EVERY ENUM HERE IS A ROC TAG UNION, IN ROC'S ORDER.** A tag union
//! whose tags carry nothing crosses the seam as one byte, its tags numbered
//! in the order of their names (Roc's layout). So each enum lists the tags,
//! snake_case for PascalCase, in that order, with no numbers written:
//! glue_test.zig holds each one's numbers to roc glue's at compile time. A
//! tag added in the Roc is added here, where it sorts.

const std = @import("std");

/// Chat.roc's `Method`: a request's method, as the router tells them apart.
pub const Method = enum(u8) {
    get,
    head,
    other,
    post,

    pub fn of(m: std.http.Method) Method {
        return switch (m) {
            .GET => .get,
            .HEAD => .head,
            .POST => .post,
            else => .other,
        };
    }
};

/// Chat.roc's `Sniff`: `forbid` when the answer says `nosniff`.
pub const Sniff = enum(u8) { allow, forbid };

/// Chat.roc's `Kind`: what an answer is (Chat.roc says each).
pub const Kind = enum(u8) {
    answered,
    exchange,
    not_allowed,
    not_found,
    respond,
    stream,
};

/// Host.roc's `read_body!` answer's `status`: the body read (its bytes beside
/// it), or answered by the host instead (too big).
pub const BodyStatus = enum(u8) { answered, read };

/// Host.roc's `serve_script!` answer.
pub const ScriptServed = enum(u8) { missing, served };

// ── the files (Host.roc's read!, read_at!, read_stat!, list!, write!,
// append!, remove!), answered by host/files.zig ────────────────────────────

/// Host.roc's file answers' `status`: the bytes (or stat, or entries), nothing
/// there, or a read that failed. **NEVER ONE ANSWER FOR MISSING AND FAILED.**
pub const ReadStatus = enum(u8) { failed, found, missing };

/// A `list!` entry's kind.
pub const EntryKind = enum(u8) { dir, file, other };

/// Host.roc's `append!` answer's `status`.
pub const AppendStatus = enum(u8) { appended, failed };

/// Host.roc's `write!` answer.
pub const Written = enum(u8) { failed, written };

/// Host.roc's `remove!` answer.
pub const Removed = enum(u8) { failed, removed };

/// A file as the host read it (`read!`, `read_at!`).
pub const Read = union(ReadStatus) { failed, found: []const u8, missing };

/// A folder's entry: its name and its kind.
pub const Entry = struct { name: []const u8, kind: EntryKind };

/// A folder as the host listed it, in the order the disk gives it.
pub const Listing = union(ReadStatus) { failed, found: []const Entry, missing };

/// A file's size in bytes and its last change in whole seconds since the
/// epoch (`read_stat!`).
pub const Stat = union(ReadStatus) {
    failed,
    found: struct { size: u64, mtime: i64 },
    missing,
};

/// `append!`'s answer: the file's size after the bytes.
pub const Appended = union(AppendStatus) { appended: u64, failed };

// ── sign-in: the crypto, the clock, the config, and GitHub's exchange ──────

/// Host.roc's `verify!` answer: whether the MAC is the site key's.
pub const Verified = enum(u8) { invalid, valid };

/// Host.roc's `read_config!` argument: a public setting the Roc needs.
pub const ConfigName = enum(u8) { first_admin, github_authorize, github_client_id, origin };

/// Chat.roc's `Exchanged.status`: what GitHub's exchange came to, or that
/// none was asked for.
pub const ExchangeStatus = enum(u8) { failed, known, not_asked, refused };

/// **GITHUB'S EXCHANGE, AS THE ROC'S SECOND CALL HEARS IT** (Chat.roc's
/// `Request.exchanged`): who the code belongs to (`known`), GitHub's no to
/// the code or its token (`refused`), no answer or no sense from it in time
/// (`failed`), or no exchange asked (`not_asked`, every first call).
pub const Exchanged = union(ExchangeStatus) {
    failed,
    known: struct { id: u64, login: []const u8 },
    not_asked,
    refused,
};

/// A response header the Roc's answer adds (Chat.roc's `Header`), its bytes
/// copied out of the call. The host checks each before it is sent
/// (host/call.zig).
pub const Header = struct { name: []const u8, value: []const u8 };

/// **THE LONGEST A STREAM'S HOLDER MAY BE** (Chat.roc's `stream_holder`):
/// host/sse.zig's Slots keep it inline. Longer is the Roc's bug, a 500.
pub const holder_most = 64;

/// What the router decided, its bytes copied out of the call.
pub const Decision = union(enum) {
    /// A status and its body, typed `content_type` when it is not empty,
    /// with the Roc's headers.
    respond: struct {
        status: u16,
        content_type: []const u8 = "",
        body: []const u8 = "",
        nosniff: bool = false,
        headers: []const Header = &.{},
    },
    /// A 405 naming the one method the route takes.
    not_allowed: std.http.Method,
    /// Answered already by the host, inside the call (a body too big, a
    /// script): the host has what to send.
    answered,
    /// The plain 404.
    not_found,
    /// **GITHUB'S CODE TO EXCHANGE, OUTSIDE THE TURN**: the host exchanges
    /// it, then calls the Roc again with the same request and what GitHub
    /// said (`Exchanged`). Once per request.
    exchange: []const u8,
    /// An event stream on the bus key `key`, subscribed in the call's turn:
    /// `backlog` first, then each frame published to the key. `holder` is
    /// who holds it (host/sse.zig's Slots keep a few a holder).
    stream: struct { key: []const u8, backlog: []const u8, holder: []const u8 },

    pub fn format(d: Decision, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (d) {
            .respond => |r| try w.print("{d} \"{s}\"{s} {d} bytes, {d} headers", .{
                r.status,
                r.content_type,
                if (r.nosniff) " nosniff" else "",
                r.body.len,
                r.headers.len,
            }),
            .not_allowed => |m| try w.print("405 allow {t}", .{m}),
            .answered => try w.writeAll("answered by the host"),
            .not_found => try w.writeAll("404"),
            .exchange => try w.writeAll("exchange a code with GitHub"),
            .stream => |s| try w.print("stream {s}, {d} bytes of backlog", .{ s.key, s.backlog.len }),
        }
    }
};

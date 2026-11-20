//! **THE APP'S FIVE ENTRIES**, part of the seam (host/seam.zig):
//! `roc_page` (the demo), `roc_start`, `roc_admission` and
//! `roc_handle_http_request` (the server), and `roc_password_verdict`
//! (`roc-chat hash-password`), with the records the server's take and
//! answer (platform/Http.roc) and platform/main.roc's answers.

const std = @import("std");
const seam_call = @import("seam_call.zig");
const RocBytes = seam_call.RocBytes;
const RocBytesList = seam_call.RocBytesList;

// ── the HTTP records (platform/Http.roc) ────────────────────────────────────

/// Http.roc's `Header`: `{ name, value : List(U8) }`, by name.
pub const HeaderRec = extern struct { name: RocBytes, value: RocBytes };

pub const HeaderList = seam_call.RocList(HeaderRec, std.http.Header, struct {
    fn rec(h: std.http.Header) HeaderRec {
        return .{ .name = .from(h.name), .value = .from(h.value) };
    }
}.rec);

/// Http.roc's `Request`: six lists, by name, then the U16.
pub const Request = extern struct {
    body: RocBytes,
    headers: HeaderList,
    method: RocBytes,
    path: RocBytes,
    public_origin: RocBytes,
    query: RocBytes,
    port: u16,
};

/// Http.roc's `Response`'s `kind`, alphabetical.
pub const AnswerKind = enum(u8) { stream, whole };

/// Http.roc's `Response`: the lists by name, then the U32, the U16, then
/// the tag.
pub const Response = extern struct {
    body: RocBytes,
    headers: HeaderList,
    stream_holder: RocBytes,
    stream_keys: RocBytesList,
    write_grace_ms: u32,
    status: u16,
    kind: AnswerKind,
};

/// Http.roc's `RequestHead`: four lists, by name, then the U16.
pub const RequestHead = extern struct {
    headers: HeaderList,
    method: RocBytes,
    path: RocBytes,
    public_origin: RocBytes,
    port: u16,
};

/// platform/main.roc's `start!` answer, alphabetical.
pub const StartAnswer = enum(u8) { failed, ready };

/// platform/main.roc's `password_verdict` answer, alphabetical.
pub const PasswordRule = enum(u8) { accepted, refused };

/// The admission's `verdict`, alphabetical.
pub const Verdict = enum(u8) { admit, refuse };

/// Http.roc's `Admission`, as platform/main.roc lays it flat for the host:
/// the U64, the response, the U32, then the tag. Only the fields of its
/// `verdict` mean anything.
pub const Admission = extern struct {
    body_most: u64,
    refusal: Response,
    body_grace_ms: u32,
    verdict: Verdict,
};

comptime {
    const w = @sizeOf(usize);
    std.debug.assert(@sizeOf(HeaderRec) == 6 * w and @sizeOf(Request) == 19 * w and @sizeOf(Response) == 13 * w);
    std.debug.assert(@sizeOf(RequestHead) == 13 * w and @sizeOf(Admission) == 15 * w);
}

// ── the entries ─────────────────────────────────────────────────────────────

pub extern fn roc_page(topic: RocBytes, transcript: RocBytes) callconv(.c) RocBytes;
pub extern fn roc_start() callconv(.c) StartAnswer;
pub extern fn roc_admission(head: RequestHead) callconv(.c) Admission;
pub extern fn roc_handle_http_request(request: Request) callconv(.c) Response;
pub extern fn roc_password_verdict(bytes: RocBytes) callconv(.c) PasswordRule;

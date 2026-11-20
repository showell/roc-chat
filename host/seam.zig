//! **THE SEAM**: what the Roc archive (app/ on platform/) needs from its
//! host, and what crosses between them, gathered from its parts:
//!
//!   - host/seam_call.zig: the call the Roc runs in, its arena, the Roc
//!     lists the host makes, and the runtime (`roc_alloc`, `roc_realloc`,
//!     `roc_dealloc`, `roc_crashed`, `roc_dbg` and `roc_expect_failed`);
//!   - host/seam_entries.zig: the app's five entries, `roc_page` (the
//!     demo), `roc_start`, `roc_admission` and `roc_handle_http_request`
//!     (the server), and `roc_password_verdict` (`roc-chat
//!     hash-password`), and the records the server's take and answer
//!     (platform/Http.roc);
//!   - `primitive_parts`, the hosted functions (platform/Host.roc), each
//!     exported under its Roc name from the part for its concern.
//!
//! **A NEW HOSTED FUNCTION GOES IN THE PART FOR ITS CONCERN**, or in a new
//! part named in `primitive_parts`, as `pub export fn`. host/seam_test.zig
//! gathers the seam's names from these parts alone: a part left out of the
//! list fails it, since roc glue declares functions no listed part has.
//!
//! **EVERY RECORD IS LAID OUT AS ROC LAYS IT**: fields by alignment, then
//! by name; a tag union with no payloads is one byte, its tags numbered
//! alphabetically. host/seam_test.zig holds every record of the parts,
//! field by field, and every enum, tag by tag, to what `roc glue` makes of
//! the platform.

const seam_call = @import("seam_call.zig");

/// The app's entries and their records.
pub const entries = @import("seam_entries.zig");

/// **EVERY PART THAT EXPORTS HOSTED FUNCTIONS**, each answered by the host
/// module its header names.
pub const primitive_parts = .{
    @import("seam_files.zig"),
    @import("seam_system.zig"),
    @import("seam_streams.zig"),
    @import("seam_remembered_seconds.zig"),
    @import("seam_search.zig"),
    @import("seam_sign_in.zig"),
    @import("seam_github.zig"),
};

comptime {
    for (primitive_parts) |part| _ = part;
}

// ── what the host's callers name ────────────────────────────────────────────

pub const Call = seam_call.Call;
pub const begin = seam_call.begin;
pub const end = seam_call.end;

pub const RocBytes = seam_call.RocBytes;
pub const RocBytesList = seam_call.RocBytesList;
pub const HeaderList = entries.HeaderList;
pub const Request = entries.Request;
pub const Response = entries.Response;
pub const AnswerKind = entries.AnswerKind;
pub const PasswordRule = entries.PasswordRule;

pub const roc_page = entries.roc_page;
pub const roc_start = entries.roc_start;
pub const roc_admission = entries.roc_admission;
pub const roc_handle_http_request = entries.roc_handle_http_request;
pub const roc_password_verdict = entries.roc_password_verdict;

//! **GITHUB'S SIGN-IN**, part of the seam (host/seam.zig): GitHub's
//! settings the browser may see, and GitHub's word on a code, answered by
//! host/github_client.zig. The client secret and the token never cross.

const std = @import("std");
const github = @import("github_client.zig");
const seam_call = @import("seam_call.zig");
const RocBytes = seam_call.RocBytes;

const log = std.log.scoped(.seam);

// ── the answers ─────────────────────────────────────────────────────────────

/// Host.roc's `github_sign_in_settings!` status, alphabetical.
pub const GitHubSettingsStatus = enum(u8) { configured, not_configured };
/// Host.roc's `github_sign_in_settings!` answer: the lists by name, then the
/// tag.
pub const GitHubSettingsRec = extern struct { authorize_base: RocBytes, client_id: RocBytes, status: GitHubSettingsStatus };
/// Host.roc's `github_identity_for_code!` status, alphabetical.
pub const GitHubIdentityStatus = enum(u8) { busy, denied, failed, identified };
/// Host.roc's `github_identity_for_code!` answer: the U64, the list, then the
/// tag.
pub const GitHubIdentityRec = extern struct { github_id: u64, login: RocBytes, status: GitHubIdentityStatus };

// ── the hosted functions ────────────────────────────────────────────────────

/// The server's exchanges with GitHub in flight (`github_identity_for_code`).
var exchanges: github.ExchangeGate = .{};

/// The client id and GitHub's site, which the browser sees anyway. The client
/// secret never crosses.
pub export fn github_sign_in_settings() callconv(.c) GitHubSettingsRec {
    const settings = seam_call.call("github_sign_in_settings").github orelse
        return .{ .authorize_base = .from(""), .client_id = .from(""), .status = .not_configured };
    return .{ .authorize_base = .from(settings.oauth_base.slice()), .client_id = .from(settings.client_id.slice()), .status = .configured };
}

/// GitHub's exchange, with the turn let go, so no request waits on GitHub:
/// the call is set aside (`seam_call.set_aside`) until the turn is held
/// again, as for a password's check. The code lives in this call's arena. A
/// failure is logged here by its name alone, and neither the code nor the
/// token reaches the log; the token never leaves the client. A task
/// canceled as the server stops answers `failed`. Past
/// `github.exchanges_most` at once, it answers `busy` and asks GitHub
/// nothing; the gate is counted while the turn is held.
pub export fn github_identity_for_code(code: RocBytes) callconv(.c) GitHubIdentityRec {
    const what = "github_identity_for_code";
    const this_call = seam_call.call(what);
    const io = seam_call.io_of(what);
    const settings = this_call.github orelse @panic(what ++ ": this call has no GitHub settings (the app asks only when it has them)");
    const gpa = this_call.gpa orelse @panic(what ++ ": this call has no allocator (only the server's asks GitHub)");
    const turn = this_call.turn orelse @panic(what ++ ": this call holds no turn (only the server's asks GitHub)");
    if (!exchanges.enter()) {
        log.warn(what ++ ": {d} exchanges with GitHub at once already: answered busy", .{github.exchanges_most});
        return .{ .github_id = 0, .login = .from(""), .status = .busy };
    }
    seam_call.set_aside();
    turn.unlock(io);
    const identity = github.identify_code(gpa, io, settings, code.slice());
    turn.lockUncancelable(io);
    seam_call.take_back(this_call);
    exchanges.leave();
    const who = identity catch |e| switch (e) {
        error.Denied => return .{ .github_id = 0, .login = .from(""), .status = .denied },
        error.Timeout, error.Refused, error.BadResponse, error.Canceled => {
            log.warn(what ++ ": {t}", .{e});
            return .{ .github_id = 0, .login = .from(""), .status = .failed };
        },
    };
    return .{ .github_id = who.github_id, .login = .from(who.login()), .status = .identified };
}

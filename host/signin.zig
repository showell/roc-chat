//! **SIGN-IN'S HOST SIDE**: what the host holds for it (the secrets, the
//! GitHub settings, the public origin) and GitHub's code exchange, which the
//! server runs **OUTSIDE THE TURN**, between two Roc calls, so no request
//! waits on GitHub: the first call answers `exchange` with GitHub's code, the
//! host exchanges it on the connection's own task, and the second call hears
//! what GitHub said (`route.Exchanged`) beside the same request.
//!
//! **THE CLIENT SECRET AND THE TOKEN NEVER CROSS INTO THE ROC**: the exchange
//! (host/github/client.zig) keeps both, and wipes the token before it
//! returns; what crosses is GitHub's id and login, or a failure's kind.

const std = @import("std");
const Io = std.Io;
const github = @import("github/client.zig");
const secrets = @import("auth/secrets.zig");
const route = @import("seam/chat_route.zig");

const log = std.log.scoped(.roc_chat);

/// What the host holds for sign-in, for the server's life.
pub const Auth = struct {
    secrets: secrets.Secrets,
    github: github.Config,
    /// The public origin (`https://chat.lynrummy.com`), for GitHub's
    /// `redirect_uri`.
    origin: []const u8,
    /// The first admin's GitHub id, as decimal digits; empty for none (the
    /// config's `.bootstrap_admin`).
    first_admin: []const u8 = "",
    /// **THE END TO END'S CAP** on what one human makes (Limits.cap!), in
    /// place of each of Limits' own; 0 for none, as in prod, where nothing
    /// sets it. host/e2e.zig sets it around a step.
    cap_for_test: std.atomic.Value(u32) = .init(0),

    /// A public setting the Roc asks for (Host.read_config!). Never a
    /// secret: the client id is public (the authorize URL carries it).
    pub fn config(a: *const Auth, name: route.ConfigName) []const u8 {
        return switch (name) {
            .cap_for_test => "", // a number, spelled by call.zig's read_config
            .first_admin => a.first_admin,
            .github_authorize => a.github.oauth_base,
            .github_client_id => a.secrets.client_id.bytes,
            .origin => a.origin,
        };
    }
};

/// **GITHUB'S EXCHANGE, OFF THE TURN**: `code` exchanged for a token, the
/// token asked who it is, under the client's deadlines; the login copied
/// into `arena`. A denial (a bad code, bad credentials) is `refused`;
/// anything else that is not an identity (a timeout, no connection, a
/// malformed answer) is `failed`.
pub fn exchange(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, auth: *const Auth, code: []const u8) Io.Cancelable!route.Exchanged {
    const creds: github.Credentials = .{
        .client_id = auth.secrets.client_id.bytes,
        .client_secret = auth.secrets.client_secret.bytes,
    };
    const who = github.signIn(gpa, io, auth.github, creds, code) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        error.Denied => return .refused,
        error.Timeout, error.Refused, error.BadResponse, error.BaseUrlRefused => {
            log.warn("GitHub's exchange failed: {t}", .{e});
            return .failed;
        },
    };
    const login = arena.dupe(u8, who.login()) catch return .failed;
    return .{ .known = .{ .id = who.id, .login = login } };
}

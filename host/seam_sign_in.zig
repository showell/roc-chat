//! **A PASSWORD AND A SIGNATURE**, part of the seam (host/seam.zig):
//! bcrypt's hash and check, and the HMAC with the server's secret,
//! answered by host/sign_in_primitives.zig. The secret never crosses.

const std = @import("std");
const Io = std.Io;
const sign_in = @import("sign_in_primitives.zig");
const seam_call = @import("seam_call.zig");
const RocBytes = seam_call.RocBytes;
const io_of = seam_call.io_of;
const secret_of = seam_call.secret_of;

const log = std.log.scoped(.seam);

comptime {
    for (.{ sign_in.PasswordVerdict, sign_in.MacVerdict }) |E| {
        std.debug.assert(@sizeOf(E) == 1);
    }
}

pub export fn bcrypt_hash_of_password(password: RocBytes) callconv(.c) RocBytes {
    var out: [sign_in.bcrypt_hash_length]u8 = undefined;
    return .from(sign_in.bcrypt_hash_of_password(io_of("bcrypt_hash_of_password"), password.slice(), &out));
}

/// The check is spent from the bucket in the turn, and refused there when
/// the bucket is empty, nothing compared. Then bcrypt runs with the turn
/// let go, so the server answers other requests meanwhile: the call is set
/// aside (`seam_call.set_aside`) until the turn is held again. The check
/// reads only the two lists, which live in this call's arena. A stored hash
/// that is no bcrypt hash is logged here, since the app answers it as a
/// wrong password.
pub export fn password_matches_bcrypt_hash(password: RocBytes, hash: RocBytes) callconv(.c) sign_in.PasswordVerdict {
    const what = "password_matches_bcrypt_hash";
    const this_call = seam_call.call(what);
    const io = io_of(what);
    const checks = this_call.password_checks orelse @panic(what ++ ": this call has no bucket (only the server's checks a password)");
    const turn = this_call.turn orelse @panic(what ++ ": this call holds no turn (only the server's checks a password)");
    if (!checks.take(Io.Clock.now(.awake, io).toMilliseconds())) return .too_many_checks;
    _ = checks.spent.fetchAdd(1, .monotonic);
    seam_call.set_aside();
    turn.unlock(io);
    const verdict = sign_in.password_matches_bcrypt_hash(password.slice(), hash.slice());
    turn.lockUncancelable(io);
    seam_call.take_back(this_call);
    if (verdict == .matches or verdict == .does_not_match) _ = checks.compared.fetchAdd(1, .monotonic);
    if (verdict == .not_a_bcrypt_hash) log.warn(what ++ ": a stored hash is no bcrypt hash this server checks (`$2a$`, `$2b$` or `$2y$` at a cost of {d} to {d}), answered as a wrong password", .{ sign_in.bcrypt_cost_lowest, sign_in.bcrypt_cost_highest });
    return verdict;
}

pub export fn hmac_sha256_with_server_secret(bytes: RocBytes) callconv(.c) RocBytes {
    const mac = sign_in.hmac_sha256(secret_of("hmac_sha256_with_server_secret"), bytes.slice());
    return .from(&mac);
}

pub export fn hmac_sha256_with_server_secret_matches(bytes: RocBytes, mac: RocBytes) callconv(.c) sign_in.MacVerdict {
    return sign_in.hmac_sha256_matches(secret_of("hmac_sha256_with_server_secret_matches"), bytes.slice(), mac.slice());
}

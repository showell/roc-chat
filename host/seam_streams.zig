//! **THE STREAMS**, part of the seam (host/seam.zig): a frame published on
//! a key (host/bus.zig), and a holder's streams ended (host/sse.zig).

const seam_call = @import("seam_call.zig");
const RocBytes = seam_call.RocBytes;

/// The hub copies the bytes, so they outlive the call's arena.
pub export fn publish_bytes_to_streams_on_key(key: RocBytes, bytes: RocBytes) callconv(.c) void {
    seam_call.hub_of("publish_bytes_to_streams_on_key").publish(key.slice(), bytes.slice());
}

pub export fn end_every_stream_of_holder(holder: RocBytes) callconv(.c) void {
    const what = "end_every_stream_of_holder";
    seam_call.slots_of(what).end_holder(seam_call.io_of(what), holder.slice());
}

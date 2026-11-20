//! The search index: texts the app hands the host, each under a key and
//! with a label, and the words of each (host/search_tokens.zig), held in
//! the server's memory so a search reads no disk. A port of Gopher Chat's
//! search_index.zig (angry-gopher's zig-server), made general: the host
//! knows nothing of chats. The app keys a topic's messages by its
//! conversation, labels each with its author and time, and decides who may
//! search which keys; the index answers only which words and which texts
//! of the keys it is asked about match.
//!
//! **A CACHE, NEVER THE DATABASE.** Nothing here is written to disk, and a
//! restart forgets it all. The app fills a key from its transcript the
//! first time a search reaches it (`open`, then `append` for each message)
//! and appends to a held key each message that lands after (`append` after
//! the file's own append). A key the app could not read is held as
//! unsearchable, so a search says it may miss it.
//!
//! **BOUNDED**: every key's labels and texts come to at most
//! `text_most_total` (64 MiB, Gopher's cap). A text past it makes its key
//! unsearchable, said once, and what the key held is let go. A key is at
//! most `key_most` bytes. No memory, or a key out of bounds, stops the
//! server, as `RememberedSeconds` does: the first is a server that can't go
//! on, the second the app's bug.
//!
//! **FEW ALLOCATIONS** (Gopher's measurements): a key's labels and texts are
//! one buffer, its refs one list, its words one arena.
//!
//! Only the app's calls reach it, one at a time (the turn, host/http.zig),
//! so it takes no lock of its own.

const std = @import("std");
const tokens = @import("search_tokens.zig");
const Alloc = std.mem.Allocator;

/// The most bytes of labels and texts the index holds, all keys together.
pub const text_most_total: u64 = 64 << 20;

/// The most bytes a key may be.
pub const key_most = 1024;

/// Where one text's label and text are in its key's buffer, one after the
/// other.
const Ref = struct { start: u32, label: u32, text: u32 };

/// One key's texts, or none when it is unsearchable.
const Held = struct {
    searchable: bool,
    bytes: std.ArrayList(u8) = .empty,
    refs: std.ArrayList(Ref) = .empty,
    /// A word (folded, in `words`) → how many of its texts hold it.
    counts: std.StringHashMapUnmanaged(u32) = .empty,
    words: std.heap.ArenaAllocator,

    fn deinit(h: *Held, gpa: Alloc) void {
        h.bytes.deinit(gpa);
        h.refs.deinit(gpa);
        h.counts.deinit(gpa);
        h.words.deinit();
    }

    fn label_of(h: *const Held, r: Ref) []const u8 {
        return h.bytes.items[r.start..][0..r.label];
    }

    fn text_of(h: *const Held, r: Ref) []const u8 {
        return h.bytes.items[r.start + r.label ..][0..r.text];
    }
};

pub const WordCount = struct { word: []const u8, count: u64 };

pub const Words = struct {
    words: []const WordCount,
    /// The keys asked about that are held unsearchable.
    unsearchable: u64,
};

pub const Hit = struct {
    /// Its key's place in the keys asked about, from 0.
    key_at: u64,
    /// Its place among its key's texts, from 0.
    text_at: u64,
    label: []const u8,
    text: []const u8,
};

pub const Texts = struct {
    hits: []const Hit,
    /// Every text holding the word in the keys asked about, listed or not.
    matched: u64,
    unsearchable: u64,
};

pub const SearchIndex = struct {
    gpa: Alloc,
    keys: std.StringHashMapUnmanaged(*Held) = .empty,
    /// One text's words, each once: kept between texts, cleared.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    fold: std.ArrayList(u8) = .empty,
    /// Every held key's labels and texts, in all.
    text_bytes: u64 = 0,
    /// `text_most_total`, or a test's own.
    total_most: u64 = text_most_total,

    pub fn init(gpa: Alloc) SearchIndex {
        return .{ .gpa = gpa };
    }

    pub fn deinit(x: *SearchIndex) void {
        var it = x.keys.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit(x.gpa);
            x.gpa.destroy(e.value_ptr.*);
            x.gpa.free(e.key_ptr.*);
        }
        x.keys.deinit(x.gpa);
        x.seen.deinit(x.gpa);
        x.fold.deinit(x.gpa);
    }

    /// Whether `key` is held, searchable or not.
    pub fn is_held(x: *const SearchIndex, key: []const u8) bool {
        return x.keys.contains(key);
    }

    /// `key` held with no texts (`searchable`), or as unsearchable, in
    /// place of whatever it held.
    pub fn open(x: *SearchIndex, key: []const u8, searchable: bool) void {
        const what = "open_search_index_key";
        if (key.len == 0 or key.len > key_most) std.debug.panic(what ++ ": a key of {d} bytes (1 to {d})", .{ key.len, key_most });
        const gop = x.keys.getOrPut(x.gpa, key) catch out_of_memory(what);
        if (gop.found_existing) {
            x.let_go(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = x.gpa.dupe(u8, key) catch out_of_memory(what);
            gop.value_ptr.* = x.gpa.create(Held) catch out_of_memory(what);
        }
        gop.value_ptr.*.* = .{ .searchable = searchable, .words = .init(x.gpa) };
    }

    /// What `h` held, let go, its bytes no longer counted.
    fn let_go(x: *SearchIndex, h: *Held) void {
        x.text_bytes -= h.bytes.items.len;
        h.deinit(x.gpa);
        h.* = .{ .searchable = false, .words = .init(x.gpa) };
    }

    /// `text`, labelled `label`, at the end of `key`'s texts, its words
    /// counted. Nothing when `key` is not held (the app reads it from its
    /// file when a search first reaches it) or is unsearchable. Past
    /// `total_most`, or past what a key's offsets hold, the key becomes
    /// unsearchable.
    pub fn append(x: *SearchIndex, key: []const u8, label: []const u8, text: []const u8) void {
        const what = "append_text_to_search_index_key";
        const h = x.keys.get(key) orelse return;
        if (!h.searchable) return;
        const start = h.bytes.items.len;
        const len = label.len + text.len;
        if (x.text_bytes + len > x.total_most or start + len > std.math.maxInt(u32)) {
            x.let_go(h);
            return;
        }
        h.refs.ensureUnusedCapacity(x.gpa, 1) catch out_of_memory(what);
        h.bytes.ensureUnusedCapacity(x.gpa, len) catch out_of_memory(what);
        h.bytes.appendSliceAssumeCapacity(label);
        h.bytes.appendSliceAssumeCapacity(text);
        h.refs.appendAssumeCapacity(.{ .start = @intCast(start), .label = @intCast(label.len), .text = @intCast(text.len) });
        x.text_bytes += len;

        x.seen.clearRetainingCapacity();
        var it = tokens.words(text);
        while (it.next()) |w| {
            x.fold.resize(x.gpa, w.len) catch out_of_memory(what);
            const k = tokens.fold(w, x.fold.items);
            const p = h.counts.getOrPut(x.gpa, k) catch out_of_memory(what);
            if (!p.found_existing) {
                p.key_ptr.* = h.words.allocator().dupe(u8, k) catch out_of_memory(what);
                p.value_ptr.* = 0;
            }
            // Keyed by the map's own copy, which lives as long as the key.
            const once = x.seen.getOrPut(x.gpa, p.key_ptr.*) catch out_of_memory(what);
            if (!once.found_existing) p.value_ptr.* += 1;
        }
    }

    /// The places in `keys` of those not held.
    pub fn not_held(x: *const SearchIndex, alloc: Alloc, keys: []const []const u8) ![]const u64 {
        var out: std.ArrayList(u64) = .empty;
        for (keys, 0..) |k, at| if (!x.is_held(k)) try out.append(alloc, at);
        return out.items;
    }

    fn unsearchable_in(x: *const SearchIndex, keys: []const []const u8) u64 {
        var n: u64 = 0;
        for (keys) |k| if (x.keys.get(k)) |h| {
            if (!h.searchable) n += 1;
        };
        return n;
    }

    /// At most `most` words beginning with `prefix` (folded), each with how
    /// many texts of `keys` hold it, and none of other keys': the most held
    /// first, then in byte order. No word longer than `tokens.longest_key`.
    pub fn words_for(x: *const SearchIndex, alloc: Alloc, keys: []const []const u8, prefix: []const u8, most: u64) !Words {
        var sums: std.StringHashMapUnmanaged(u64) = .empty;
        for (keys) |k| {
            const h = x.keys.get(k) orelse continue;
            var it = h.counts.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.len > tokens.longest_key) continue;
                if (!std.mem.startsWith(u8, e.key_ptr.*, prefix)) continue;
                const g = try sums.getOrPut(alloc, e.key_ptr.*);
                if (!g.found_existing) g.value_ptr.* = 0;
                g.value_ptr.* += e.value_ptr.*;
            }
        }
        var out: std.ArrayList(WordCount) = .empty;
        var it = sums.iterator();
        while (it.next()) |e| try out.append(alloc, .{ .word = e.key_ptr.*, .count = e.value_ptr.* });
        std.mem.sort(WordCount, out.items, {}, most_held_first);
        return .{ .words = out.items[0..@min(most, out.items.len)], .unsearchable = x.unsearchable_in(keys) };
    }

    /// The texts of `keys` that hold `word` (folded) as a word of their own,
    /// in `keys`' order, each key's in the order they came: at most `most`
    /// listed, and every one counted.
    pub fn texts_for(x: *const SearchIndex, alloc: Alloc, keys: []const []const u8, word: []const u8, most: u64) !Texts {
        var hits: std.ArrayList(Hit) = .empty;
        var matched: u64 = 0;
        for (keys, 0..) |k, key_at| {
            const h = x.keys.get(k) orelse continue;
            const n = h.counts.get(word) orelse continue;
            matched += n;
            var left = n;
            for (h.refs.items, 0..) |r, text_at| {
                if (left == 0 or hits.items.len == most) break;
                const text = h.text_of(r);
                if (!holds(text, word)) continue;
                left -= 1;
                try hits.append(alloc, .{ .key_at = key_at, .text_at = text_at, .label = h.label_of(r), .text = text });
            }
        }
        return .{ .hits = hits.items, .matched = matched, .unsearchable = x.unsearchable_in(keys) };
    }
};

fn out_of_memory(comptime what: []const u8) noreturn {
    std.debug.panic(what ++ ": no memory for the search index", .{});
}

fn most_held_first(_: void, a: WordCount, b: WordCount) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.word, b.word);
}

/// Whether `text` holds `word` (folded) as a word of its own.
fn holds(text: []const u8, word: []const u8) bool {
    if (std.ascii.findIgnoreCase(text, word) == null) return false;
    var it = tokens.words(text);
    while (it.next()) |w| {
        if (w.len == word.len and std.ascii.eqlIgnoreCase(w, word)) return true;
    }
    return false;
}

// ── tests: Gopher's search_index.zig's that still apply, on
// std.testing.allocator, so anything left unfreed fails

const testing = std.testing;

test "words by prefix, counted by text, only in the keys asked about" {
    var x = SearchIndex.init(testing.allocator);
    defer x.deinit();
    x.open("a", true);
    x.open("b", true);
    x.append("a", "l", "The layout, the LAYOUT, and a layover");
    x.append("a", "l", "a player plays");
    x.append("b", "l", "the layaway plan");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try x.words_for(a, &.{"a"}, "lay", 20);
    try testing.expectEqual(2, got.words.len);
    try testing.expectEqualStrings("layout", got.words[0].word);
    try testing.expectEqual(1, got.words[0].count);
    try testing.expectEqualStrings("layover", got.words[1].word);
    try testing.expectEqual(1, (try x.words_for(a, &.{"a"}, "the", 20)).words[0].count);
    try testing.expectEqual(2, (try x.words_for(a, &.{ "a", "b" }, "the", 20)).words[0].count);
    try testing.expectEqual(1, (try x.words_for(a, &.{ "a", "b" }, "", 1)).words.len);
}

test "texts for a word: at most so many listed, every one counted, each with its key's place and its own" {
    var x = SearchIndex.init(testing.allocator);
    defer x.deinit();
    x.open("a", true);
    for (0..7) |i| x.append("a", "l", if (i % 2 == 0) "dinner tonight?" else "no");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try x.texts_for(arena.allocator(), &.{ "z", "a" }, "tonight", 3);
    try testing.expectEqual(4, f.matched);
    try testing.expectEqual(3, f.hits.len);
    try testing.expectEqual(1, f.hits[0].key_at);
    try testing.expectEqual(0, f.hits[0].text_at);
    try testing.expectEqual(2, f.hits[1].text_at);
    try testing.expectEqualStrings("dinner tonight?", f.hits[0].text);
    try testing.expectEqualStrings("l", f.hits[0].label);
    // A word that is only a prefix finds nothing: words are whole.
    try testing.expectEqual(0, (try x.texts_for(arena.allocator(), &.{"a"}, "tonig", 10)).matched);
}

test "a word too long to ask for is never suggested, and one at the longest is, and found" {
    var x = SearchIndex.init(testing.allocator);
    defer x.deinit();
    x.open("a", true);
    const longest: [tokens.longest_key]u8 = @splat('a');
    const past: [tokens.longest_key + 1]u8 = @splat('a');
    x.append("a", "l", &past ++ " " ++ &longest);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try x.words_for(arena.allocator(), &.{"a"}, "aaa", 20);
    try testing.expectEqual(1, got.words.len);
    try testing.expectEqual(tokens.longest_key, got.words[0].word.len);
    try testing.expectEqual(1, (try x.texts_for(arena.allocator(), &.{"a"}, &longest, 10)).matched);
}

test "a key not held takes no text, and is said not held; one held unsearchable is counted, once" {
    var x = SearchIndex.init(testing.allocator);
    defer x.deinit();
    x.append("a", "l", "lost words");
    try testing.expect(!x.is_held("a"));
    x.open("b", false);
    x.append("b", "l", "lost words");
    x.open("c", true);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualSlices(u64, &.{0}, try x.not_held(a, &.{ "a", "b", "c" }));
    const w = try x.words_for(a, &.{ "a", "b", "c" }, "lo", 20);
    try testing.expectEqual(0, w.words.len);
    try testing.expectEqual(1, w.unsearchable);
    try testing.expectEqual(1, (try x.texts_for(a, &.{ "b", "c" }, "lost", 20)).unsearchable);
    try testing.expectEqual(0, x.text_bytes);
}

test "past the total, the key a text lands in is unsearchable, what it held let go; opening it again starts it afresh" {
    var x = SearchIndex.init(testing.allocator);
    defer x.deinit();
    x.total_most = 30;
    x.open("a", true);
    x.open("b", true);
    x.append("a", "l", "a word here"); // 12
    x.append("b", "l", "a word here"); // 24
    x.append("b", "l", "a word here"); // 36: past it
    try testing.expectEqual(12, x.text_bytes);
    x.append("b", "l", "x");
    try testing.expectEqual(12, x.text_bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try x.texts_for(arena.allocator(), &.{ "a", "b" }, "word", 10);
    try testing.expectEqual(1, f.matched);
    try testing.expectEqual(1, f.unsearchable);
    x.open("a", true);
    try testing.expectEqual(0, x.text_bytes);
    try testing.expectEqual(0, (try x.texts_for(arena.allocator(), &.{"a"}, "word", 10)).matched);
}

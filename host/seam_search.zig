//! **THE SEARCH INDEX**, part of the seam (host/seam.zig): a key's texts
//! opened and appended, and words and texts found, answered by
//! host/search_index.zig.

const std = @import("std");
const search_index = @import("search_index.zig");
const seam_call = @import("seam_call.zig");
const RocBytes = seam_call.RocBytes;
const RocBytesList = seam_call.RocBytesList;
const call = seam_call.call;

// ── the answers ─────────────────────────────────────────────────────────────

/// Host.roc's `open_search_index_key!` argument, alphabetical.
pub const SearchIndexKeyKind = enum(u8) { searchable, unsearchable };
/// Host.roc's `find_words_in_search_index!` word: the U64, then the list.
pub const WordCountRec = extern struct { count: u64, word: RocBytes };
pub const WordCountList = seam_call.RocList(WordCountRec, search_index.WordCount, struct {
    fn rec(w: search_index.WordCount) WordCountRec {
        return .{ .count = w.count, .word = .from(w.word) };
    }
}.rec);
/// Host.roc's `find_words_in_search_index!` answer: the U64, then the list.
pub const SearchWordsRec = extern struct { unsearchable: u64, words: WordCountList };
/// Host.roc's `find_texts_in_search_index!` hit: the U64s, then the lists, each
/// by name (a list's alignment is a word's, a U64's at least that).
pub const SearchHitRec = extern struct { key_at: u64, text_at: u64, label: RocBytes, text: RocBytes };
pub const SearchHitList = seam_call.RocList(SearchHitRec, search_index.Hit, struct {
    fn rec(h: search_index.Hit) SearchHitRec {
        return .{ .key_at = h.key_at, .label = .from(h.label), .text = .from(h.text), .text_at = h.text_at };
    }
}.rec);
/// Host.roc's `find_texts_in_search_index!` answer: the U64s, then the list.
pub const SearchTextsRec = extern struct { matched: u64, unsearchable: u64, hits: SearchHitList };

// ── the hosted functions ────────────────────────────────────────────────────

fn search_of(comptime what: []const u8) *search_index.SearchIndex {
    return call(what).search orelse @panic(what ++ ": this call has no search index (only the server's keeps one)");
}

/// The keys of a Roc `List(List(U8))`, as slices, in the call's arena.
fn key_slices(comptime what: []const u8, keys: RocBytesList) []const []const u8 {
    const held = keys.slice();
    const out = call(what).arena.alloc([]const u8, held.len) catch std.debug.panic(what ++ ": out of memory", .{});
    for (held, 0..) |*k, i| out[i] = k.slice();
    return out;
}

pub export fn open_search_index_key(key: RocBytes, kind: SearchIndexKeyKind) callconv(.c) void {
    search_of("open_search_index_key").open(key.slice(), kind == .searchable);
}

pub export fn append_text_to_search_index_key(key: RocBytes, label: RocBytes, text: RocBytes) callconv(.c) void {
    search_of("append_text_to_search_index_key").append(key.slice(), label.slice(), text.slice());
}

pub export fn search_index_keys_not_held(keys: RocBytesList) callconv(.c) seam_call.RocU64List {
    const what = "search_index_keys_not_held";
    const got = search_of(what).not_held(call(what).arena, key_slices(what, keys)) catch std.debug.panic(what ++ ": out of memory", .{});
    return .from(got);
}

/// The answer's words live in the index until the call ends: they are
/// copied into Roc's lists here.
pub export fn find_words_in_search_index(keys: RocBytesList, prefix: RocBytes, most: u64) callconv(.c) SearchWordsRec {
    const what = "find_words_in_search_index";
    const got = search_of(what).words_for(call(what).arena, key_slices(what, keys), prefix.slice(), most) catch std.debug.panic(what ++ ": out of memory", .{});
    return .{ .unsearchable = got.unsearchable, .words = .from(got.words) };
}

pub export fn find_texts_in_search_index(keys: RocBytesList, word: RocBytes, most: u64) callconv(.c) SearchTextsRec {
    const what = "find_texts_in_search_index";
    const got = search_of(what).texts_for(call(what).arena, key_slices(what, keys), word.slice(), most) catch std.debug.panic(what ++ ": out of memory", .{});
    return .{ .hits = .from(got.hits), .matched = got.matched, .unsearchable = got.unsearchable };
}

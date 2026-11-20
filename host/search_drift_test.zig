//! **THE DRIFT GATE, THE HOST'S HALF**: the search index must answer what
//! app/Search.roc's own search answers, word rules and all, since the route
//! asks the index and the Roc search stays as the reference. One fixed
//! corpus (app/search_drift_corpus.txt) and one file of questions with
//! their answers (app/search_drift_answers.txt) hold both sides:
//! app/SearchDriftSpec.roc runs the questions through the Roc search, and
//! this test through the index, and each must give every answer exactly.
//!
//! The corpus is topics, each opened by a line `=== <topic>`, its messages
//! split by a line `---`. Each answer line is `words`, the key and the
//! words it suggests as `word=count`, or `messages`, the key and
//! `matched=N` then each hit as `topic#id`, tab-separated. The keys are
//! as `SearchWords.SearchKey.of_typed` makes them (the spec checks it), so
//! the index is asked what the route would ask it. When the two disagree,
//! this test prints the index's answers whole.

const std = @import("std");
const search_index = @import("search_index.zig");

const corpus = @embedFile("search_drift_corpus");
const answers = @embedFile("search_drift_answers");

test "the search index gives every answer of the drift corpus, as app/Search.roc does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var index = search_index.SearchIndex.init(std.testing.allocator);
    defer index.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    var topics = std.mem.splitSequence(u8, corpus, "=== ");
    _ = topics.next(); // before the first topic: nothing
    while (topics.next()) |piece| {
        const end = std.mem.indexOfScalar(u8, piece, '\n') orelse return error.TopicWithoutMessages;
        const name = piece[0..end];
        try names.append(a, name);
        index.open(name, true);
        const body = std.mem.trimEnd(u8, piece[end + 1 ..], "\n");
        var messages = std.mem.splitSequence(u8, body, "\n---\n");
        while (messages.next()) |m| index.append(name, "", m);
    }

    var got: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, answers, "\n"), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next().?;
        const key = fields.next() orelse return error.LineWithoutKey;
        try got.print(a, "{s}\t{s}\t", .{ kind, key });
        if (std.mem.eql(u8, kind, "words")) {
            const w = try index.words_for(a, names.items, key, 20);
            for (w.words, 0..) |wc, i| try got.print(a, "{s}{s}={d}", .{ if (i == 0) "" else " ", wc.word, wc.count });
        } else {
            const f = try index.texts_for(a, names.items, key, 500);
            try got.print(a, "matched={d}", .{f.matched});
            for (f.hits) |h| try got.print(a, " {s}#{d}", .{ names.items[h.key_at], h.text_at + 1 });
        }
        try got.append(a, '\n');
    }
    if (!std.mem.eql(u8, got.items, answers)) {
        std.debug.print("the index's answers to app/search_drift_answers.txt's questions:\n{s}", .{got.items});
        return error.SearchIndexDrifted;
    }
}

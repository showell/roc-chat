//! The words of a text as the search index holds them: **A PORT OF
//! app/SearchWords.roc**, which is the rule's home, and of Gopher Chat's
//! search_tokens.zig, which both were ported from. The index counts words
//! with this reading and the app reads keys and excerpts with the Roc's, so
//! the two must never drift: app/search_drift_corpus.txt and
//! app/search_drift_answers.txt hold both to one set of answers
//! (host/search_drift_test.zig and app/SearchDriftSpec.roc), and the tests
//! below are SearchWords.roc's, one for one.
//!
//! - **Words split on ASCII whitespace** alone (`std.ascii.isWhitespace`: a
//!   space, a tab, a line feed, a CR, a vertical tab, a form feed).
//! - **Edge punctuation is trimmed**, from both ends, again and again:
//!   ASCII punctuation and `trimmed`. What is inside a word stays.
//! - **ASCII letters fold to lower case**; a byte of 128 or more is a
//!   word's, matched byte for byte.
//! - **Two bytes or more** once trimmed (`shortest_word`).
//!
//! Pure: no I/O, no allocation but the caller's.

const std = @import("std");

/// The shortest word, in bytes (SearchWords.roc's `shortest_word_bytes`).
pub const shortest_word = 2;

/// The longest key the app reads, in bytes (SearchWords.roc's
/// `longest_key_bytes`): no longer word is suggested, so a word suggested is
/// always one a search finds.
pub const longest_key = 256;

/// What a word's ends lose besides ASCII punctuation, as UTF-8
/// (SearchWords.roc's `trimmed_marks`, in its order).
pub const trimmed = [_][]const u8{
    "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", // ‘ ’ ‚ ‛
    "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", // “ ” „ ‟
    "\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}", // « » ‹ ›
    "\u{2026}", "\u{2013}", "\u{2014}", "\u{2015}", // … – — ―
    "\u{00A1}", "\u{00BF}", "\u{2032}", "\u{2033}", // ¡ ¿ ′ ″
    "\u{00A0}", // no-break space
};

fn is_ascii_punctuation(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

/// `word` with its edge punctuation trimmed, from both ends until neither
/// end is any: an ASCII mark first, then a mark of `trimmed` at the start,
/// then one at the end, as SearchWords.roc's `trim` does.
pub fn trim(word: []const u8) []const u8 {
    var w = word;
    outer: while (w.len > 0) {
        if (is_ascii_punctuation(w[0])) {
            w = w[1..];
            continue;
        }
        if (is_ascii_punctuation(w[w.len - 1])) {
            w = w[0 .. w.len - 1];
            continue;
        }
        for (trimmed) |t| if (std.mem.startsWith(u8, w, t)) {
            w = w[t.len..];
            continue :outer;
        };
        for (trimmed) |t| if (std.mem.endsWith(u8, w, t)) {
            w = w[0 .. w.len - t.len];
            continue :outer;
        };
        break;
    }
    return w;
}

/// The words of `text`, in order, each trimmed but not folded: slices of
/// `text`.
pub const Words = struct {
    text: []const u8,
    at: usize = 0,

    pub fn next(self: *Words) ?[]const u8 {
        while (self.at < self.text.len) {
            while (self.at < self.text.len and std.ascii.isWhitespace(self.text[self.at])) self.at += 1;
            const start = self.at;
            while (self.at < self.text.len and !std.ascii.isWhitespace(self.text[self.at])) self.at += 1;
            const w = trim(self.text[start..self.at]);
            if (w.len >= shortest_word) return w;
        }
        return null;
    }
};

pub fn words(text: []const u8) Words {
    return .{ .text = text };
}

/// `word` with its ASCII capitals made small, into `out` (as long as it).
pub fn fold(word: []const u8, out: []u8) []u8 {
    for (word, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out[0..word.len];
}

// ── tests: SearchWords.roc's, one for one ──────────────────────────────────

const testing = std.testing;

fn expect_words(text: []const u8, want: []const []const u8) !void {
    var it = words(text);
    var buf: [512]u8 = undefined;
    for (want) |w| {
        const got = it.next() orelse return error.TooFewWords;
        try testing.expectEqualStrings(w, fold(got, &buf));
    }
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "words split on whitespace, ASCII lowercased" {
    try expect_words("The page  LAYOUT\tis\noff", &.{ "the", "page", "layout", "is", "off" });
    try expect_words("", &.{});
    try expect_words(" \t\n \x0b\x0c", &.{});
}

test "edge punctuation is trimmed, from both ends and again; what is inside stays" {
    try expect_words("Hello, world!", &.{ "hello", "world" });
    try expect_words("(\"quoted\"), [x1] {braces}...", &.{ "quoted", "x1", "braces" });
    try expect_words("don't e.g. 3.14 a-b", &.{ "don't", "e.g", "3.14", "a-b" });
    try expect_words("--dashes-- **bold** _em_ `code`", &.{ "dashes", "bold", "em", "code" });
}

test "the curly quotes and apostrophes a phone types are trimmed, and their kin; inside a word one stays" {
    try expect_words("\u{201C}Hello\u{201D} \u{2018}there\u{2019}", &.{ "hello", "there" });
    try expect_words("\u{00AB}Bonjour\u{00BB} \u{2039}x1\u{203A} wait\u{2026} \u{00BF}Qu\u{00E9}?", &.{ "bonjour", "x1", "wait", "qu\u{00E9}" });
    try expect_words("don\u{2019}t", &.{"don\u{2019}t"});
    try expect_words("\u{201C}(\u{2018}word\u{2019})\u{201D}", &.{"word"});
}

test "a byte of 128 or more is a word's, matched exactly; only ASCII folds; an emoji alone is a word" {
    try expect_words("Caf\u{00E9} \u{00C9}t\u{00E9} \u{65E5}\u{672C}", &.{ "caf\u{00E9}", "\u{00C9}t\u{00E9}", "\u{65E5}\u{672C}" });
    try expect_words("ok \u{1F600}", &.{ "ok", "\u{1F600}" });
}

test "a word is two bytes or more" {
    try expect_words("a I x. ab (c) \u{00E9}", &.{ "ab", "\u{00E9}" });
    try expect_words("!!! ... \u{201C}\u{201D}", &.{});
}

test "a no-break space inside a word glues it; at its edge it is trimmed" {
    try expect_words("a\u{00A0}b \u{00A0}cd", &.{ "a\u{00A0}b", "cd" });
}

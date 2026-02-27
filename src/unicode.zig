/// Unicode utilities for parinfer: grapheme iteration and display width.
///
/// For Clojure code, we need:
/// 1. UTF-8 codepoint iteration (with byte offsets)
/// 2. Display width calculation (ASCII=1, CJK fullwidth=2, combining=0)
/// 3. Mapping from display column to byte offset
const std = @import("std");

/// Returns the display width of a single Unicode codepoint.
/// - Most characters: 1
/// - CJK Unified Ideographs, fullwidth forms, etc.: 2
/// - Combining marks, zero-width characters: 0
pub fn codepointWidth(cp: u21) u2 {
    // Zero-width characters
    if (cp == 0) return 0;

    // Combining marks (General_Category Mn, Mc, Me)
    if (isCombining(cp)) return 0;

    // Zero-width joiners and similar
    if (cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF) return 0;

    // CJK and fullwidth characters
    if (isWide(cp)) return 2;

    return 1;
}

/// Check if a codepoint is a combining mark (General_Category M).
fn isCombining(cp: u21) bool {
    // Combining Diacritical Marks
    if (cp >= 0x0300 and cp <= 0x036F) return true;
    // Combining Diacritical Marks Extended
    if (cp >= 0x1AB0 and cp <= 0x1AFF) return true;
    // Combining Diacritical Marks Supplement
    if (cp >= 0x1DC0 and cp <= 0x1DFF) return true;
    // Combining Diacritical Marks for Symbols
    if (cp >= 0x20D0 and cp <= 0x20FF) return true;
    // Combining Half Marks
    if (cp >= 0xFE20 and cp <= 0xFE2F) return true;
    // Common combining ranges in various scripts
    if (cp >= 0x0483 and cp <= 0x0489) return true; // Cyrillic
    if (cp >= 0x0591 and cp <= 0x05BD) return true; // Hebrew
    if (cp >= 0x05BF and cp <= 0x05BF) return true;
    if (cp >= 0x05C1 and cp <= 0x05C2) return true;
    if (cp >= 0x05C4 and cp <= 0x05C5) return true;
    if (cp >= 0x05C7 and cp <= 0x05C7) return true;
    if (cp >= 0x0610 and cp <= 0x061A) return true; // Arabic
    if (cp >= 0x064B and cp <= 0x065F) return true;
    if (cp >= 0x0670 and cp <= 0x0670) return true;
    if (cp >= 0x06D6 and cp <= 0x06DC) return true;
    if (cp >= 0x06DF and cp <= 0x06E4) return true;
    if (cp >= 0x06E7 and cp <= 0x06E8) return true;
    if (cp >= 0x06EA and cp <= 0x06ED) return true;
    if (cp >= 0x0900 and cp <= 0x0903) return true; // Devanagari
    if (cp >= 0x093A and cp <= 0x094F) return true;
    if (cp >= 0x0951 and cp <= 0x0957) return true;
    if (cp >= 0x0962 and cp <= 0x0963) return true;
    if (cp >= 0x0E31 and cp <= 0x0E31) return true; // Thai
    if (cp >= 0x0E34 and cp <= 0x0E3A) return true;
    if (cp >= 0x0E47 and cp <= 0x0E4E) return true;
    return false;
}

/// Check if a codepoint is a wide (fullwidth/CJK) character.
fn isWide(cp: u21) bool {
    // Fullwidth Forms (FF01-FF60, FFE0-FFE6)
    if (cp >= 0xFF01 and cp <= 0xFF60) return true;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return true;

    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true;
    // CJK Unified Ideographs Extension A
    if (cp >= 0x3400 and cp <= 0x4DBF) return true;
    // CJK Unified Ideographs Extension B
    if (cp >= 0x20000 and cp <= 0x2A6DF) return true;
    // CJK Compatibility Ideographs
    if (cp >= 0xF900 and cp <= 0xFAFF) return true;

    // CJK Radicals Supplement, Kangxi Radicals
    if (cp >= 0x2E80 and cp <= 0x2FDF) return true;

    // Enclosed CJK Letters and Months
    if (cp >= 0x3200 and cp <= 0x32FF) return true;
    // CJK Compatibility
    if (cp >= 0x3300 and cp <= 0x33FF) return true;
    // CJK Compatibility Forms
    if (cp >= 0xFE30 and cp <= 0xFE4F) return true;

    // Hangul Syllables
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true;
    // Hangul Jamo
    if (cp >= 0x1100 and cp <= 0x115F) return true;
    if (cp >= 0x2329 and cp <= 0x232A) return true;

    // CJK Symbols and Punctuation (partial)
    if (cp >= 0x3000 and cp <= 0x303E) return true;
    // Hiragana
    if (cp >= 0x3040 and cp <= 0x309F) return true;
    // Katakana
    if (cp >= 0x30A0 and cp <= 0x30FF) return true;
    // Bopomofo
    if (cp >= 0x3100 and cp <= 0x312F) return true;
    // Bopomofo Extended
    if (cp >= 0x31A0 and cp <= 0x31BF) return true;

    return false;
}

/// Iterator over grapheme clusters in a UTF-8 string.
/// For simplicity, this treats each base codepoint + its following combining marks
/// as one grapheme cluster. This handles the common cases correctly.
pub const GraphemeIterator = struct {
    bytes: []const u8,
    pos: usize,

    pub fn init(text: []const u8) GraphemeIterator {
        return .{ .bytes = text, .pos = 0 };
    }

    pub const Grapheme = struct {
        bytes: []const u8,
        byte_offset: usize,
        width: usize,
    };

    pub fn next(self: *GraphemeIterator) ?Grapheme {
        if (self.pos >= self.bytes.len) return null;

        const start = self.pos;

        // Decode the base codepoint
        const base_len = std.unicode.utf8ByteSequenceLength(self.bytes[self.pos]) catch {
            // Invalid UTF-8: treat single byte as one grapheme
            self.pos += 1;
            return Grapheme{
                .bytes = self.bytes[start..self.pos],
                .byte_offset = start,
                .width = 1,
            };
        };
        if (self.pos + base_len > self.bytes.len) {
            self.pos = self.bytes.len;
            return Grapheme{
                .bytes = self.bytes[start..self.pos],
                .byte_offset = start,
                .width = 1,
            };
        }

        const base_cp = std.unicode.utf8Decode(self.bytes[self.pos..][0..base_len]) catch {
            self.pos += 1;
            return Grapheme{
                .bytes = self.bytes[start..self.pos],
                .byte_offset = start,
                .width = 1,
            };
        };
        self.pos += base_len;

        // Consume following combining marks
        while (self.pos < self.bytes.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(self.bytes[self.pos]) catch break;
            if (self.pos + cp_len > self.bytes.len) break;

            const cp = std.unicode.utf8Decode(self.bytes[self.pos..][0..cp_len]) catch break;
            if (!isCombining(cp)) break;
            self.pos += cp_len;
        }

        return Grapheme{
            .bytes = self.bytes[start..self.pos],
            .byte_offset = start,
            .width = codepointWidth(base_cp),
        };
    }
};

/// Get the display width of a UTF-8 string (sum of grapheme widths).
pub fn displayWidth(text: []const u8) usize {
    var iter = GraphemeIterator.init(text);
    var w: usize = 0;
    while (iter.next()) |g| {
        w += g.width;
    }
    return w;
}

/// Map a display column position to a byte index in a UTF-8 string.
/// Returns the byte index of the grapheme at display column `x`.
/// If `x` is beyond the string, returns `text.len`.
pub fn columnByteIndex(text: []const u8, x: usize) usize {
    var iter = GraphemeIterator.init(text);
    var col: usize = 0;
    while (iter.next()) |g| {
        if (col == x) return g.byte_offset;
        col += g.width;
    }
    return text.len;
}

// Tests
test "displayWidth ascii" {
    try std.testing.expectEqual(@as(usize, 3), displayWidth("abc"));
}

test "displayWidth accented" {
    // é (U+00E9) is a single codepoint, width 1
    try std.testing.expectEqual(@as(usize, 3), displayWidth("åbc"));
}

test "displayWidth fullwidth" {
    // ｗｏ are fullwidth, each width 2
    try std.testing.expectEqual(@as(usize, 4), displayWidth("ｗｏ"));
}

test "columnByteIndex ascii" {
    try std.testing.expectEqual(@as(usize, 1), columnByteIndex("abc", 1));
    try std.testing.expectEqual(@as(usize, 3), columnByteIndex("abc", 3));
}

test "columnByteIndex accented" {
    // å is 2 bytes (U+00E5)
    try std.testing.expectEqual(@as(usize, 2), columnByteIndex("åbc", 1));
    try std.testing.expectEqual(@as(usize, 4), columnByteIndex("åbc", 3));
}

test "columnByteIndex fullwidth" {
    // ｗ is 3 bytes, width 2; ｏ is 3 bytes, width 2
    try std.testing.expectEqual(@as(usize, 0), columnByteIndex("ｗｏ", 0));
    try std.testing.expectEqual(@as(usize, 3), columnByteIndex("ｗｏ", 2));
    try std.testing.expectEqual(@as(usize, 6), columnByteIndex("ｗｏ", 4));
}

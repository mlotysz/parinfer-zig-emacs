/// Computes text changes between two strings.
/// Port of src/changes.rs
const std = @import("std");
const types = @import("types.zig");
const Change = types.Change;
const Column = types.Column;
const LineNumber = types.LineNumber;

/// Compare two texts and return a single Change describing the difference, or null if identical.
/// Caller owns the returned Change's old_text and new_text (allocated copies).
pub fn computeTextChange(allocator: std.mem.Allocator, prev_text: []const u8, text: []const u8) !?Change {
    var x: Column = 0;
    var line_no: LineNumber = 0;
    var start_prev: usize = 0;
    var start_text: usize = 0;
    var end_prev: usize = prev_text.len;
    var end_text: usize = text.len;
    var different: bool = false;

    // Find first difference (forward scan)
    var pi: usize = 0;
    var ti: usize = 0;
    while (pi < prev_text.len and ti < text.len) {
        const pc_len = std.unicode.utf8ByteSequenceLength(prev_text[pi]) catch 1;
        const tc_len = std.unicode.utf8ByteSequenceLength(text[ti]) catch 1;

        if (pi + pc_len > prev_text.len or ti + tc_len > text.len) break;

        const pc = prev_text[pi .. pi + pc_len];
        const tc = text[ti .. ti + tc_len];

        if (!std.mem.eql(u8, pc, tc)) {
            start_prev = pi;
            start_text = ti;
            different = true;
            break;
        }

        if (pc.len == 1 and pc[0] == '\n') {
            x = 0;
            line_no += 1;
        } else {
            x += 1;
        }

        pi += pc_len;
        ti += tc_len;
    }

    // If one string is a prefix of the other
    if (!different) {
        if (pi < prev_text.len) {
            start_prev = pi;
            start_text = ti;
            different = true;
        } else if (ti < text.len) {
            start_prev = pi;
            start_text = ti;
            different = true;
        }
    }

    if (!different) return null;

    // Find last difference (reverse scan)
    // Mirrors the Rust: break when chars differ or indices cross below start positions
    var rpi = prev_text.len;
    var rti = text.len;
    while (rpi > 0 and rti > 0) {
        // Find start of previous character by scanning backward
        var prev_cp_start = rpi - 1;
        while (prev_cp_start > 0 and (prev_text[prev_cp_start] & 0xC0) == 0x80) {
            prev_cp_start -= 1;
        }
        var text_cp_start = rti - 1;
        while (text_cp_start > 0 and (text[text_cp_start] & 0xC0) == 0x80) {
            text_cp_start -= 1;
        }

        const pc = prev_text[prev_cp_start..rpi];
        const tc = text[text_cp_start..rti];

        if (!std.mem.eql(u8, pc, tc) or prev_cp_start < start_prev or text_cp_start < start_text) {
            break;
        }

        rpi = prev_cp_start;
        rti = text_cp_start;
    }
    end_prev = rpi;
    end_text = rti;

    const old_text = try allocator.dupe(u8, prev_text[start_prev..end_prev]);
    errdefer allocator.free(old_text);
    const new_text = try allocator.dupe(u8, text[start_text..end_text]);

    return Change{
        .x = x,
        .line_no = line_no,
        .old_text = old_text,
        .new_text = new_text,
    };
}

test "identical texts return null" {
    const allocator = std.testing.allocator;
    const result = try computeTextChange(allocator, "hello", "hello");
    try std.testing.expect(result == null);
}

test "single char change" {
    const allocator = std.testing.allocator;
    const result = (try computeTextChange(allocator, "hello", "hexlo")).?;
    defer allocator.free(result.old_text);
    defer allocator.free(result.new_text);
    try std.testing.expectEqual(@as(usize, 2), result.x);
    try std.testing.expectEqual(@as(usize, 0), result.line_no);
    try std.testing.expectEqualStrings("l", result.old_text);
    try std.testing.expectEqualStrings("x", result.new_text);
}

test "change on second line" {
    const allocator = std.testing.allocator;
    const result = (try computeTextChange(allocator, "he\nllo", "he\nxlo")).?;
    defer allocator.free(result.old_text);
    defer allocator.free(result.new_text);
    try std.testing.expectEqual(@as(usize, 0), result.x);
    try std.testing.expectEqual(@as(usize, 1), result.line_no);
    try std.testing.expectEqualStrings("l", result.old_text);
    try std.testing.expectEqualStrings("x", result.new_text);
}

test "insertion" {
    const allocator = std.testing.allocator;
    const result = (try computeTextChange(allocator, "hello", "helllo")).?;
    defer allocator.free(result.old_text);
    defer allocator.free(result.new_text);
    try std.testing.expectEqual(@as(usize, 4), result.x);
    try std.testing.expectEqual(@as(usize, 0), result.line_no);
    try std.testing.expectEqualStrings("", result.old_text);
    try std.testing.expectEqualStrings("l", result.new_text);
}

test "deletion" {
    const allocator = std.testing.allocator;
    const result = (try computeTextChange(allocator, "helllo", "hello")).?;
    defer allocator.free(result.old_text);
    defer allocator.free(result.new_text);
    try std.testing.expectEqual(@as(usize, 4), result.x);
    try std.testing.expectEqual(@as(usize, 0), result.line_no);
    try std.testing.expectEqualStrings("l", result.old_text);
    try std.testing.expectEqualStrings("", result.new_text);
}

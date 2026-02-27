/// Core parinfer algorithm, ported from src/parinfer.rs.
/// Simplified for Clojure-only (no lisp_vline_symbols, block comments, janet strings, etc).
/// Hardcoded: comment_char = ';', string_delimiters = '"'
const std = @import("std");
const types = @import("types.zig");
const changes_mod = @import("changes.zig");
const unicode = @import("unicode.zig");

const LineNumber = types.LineNumber;
const Column = types.Column;
const Delta = types.Delta;
const Change = types.Change;
const Options = types.Options;
const Mode = types.Mode;
const ErrorName = types.ErrorName;
const Paren = types.Paren;
const ParenTrail = types.ParenTrail;
const TabStop = types.TabStop;
const Closer = types.Closer;
const Answer = types.Answer;
const Request = types.Request;

// {{{1 Constants

const BACKSLASH: u8 = '\\';
const BLANK_SPACE: u8 = ' ';
const NEWLINE: u8 = '\n';
const TAB: u8 = '\t';
const SEMICOLON: u8 = ';';
const DOUBLE_QUOTE: u8 = '"';

fn matchParen(ch: u8) ?u8 {
    return switch (ch) {
        '{' => '}',
        '}' => '{',
        '[' => ']',
        ']' => '[',
        '(' => ')',
        ')' => '(',
        else => null,
    };
}

fn isCloseParen(ch: u8) bool {
    return ch == ')' or ch == ']' or ch == '}';
}

fn isOpenParen(ch: u8) bool {
    return ch == '(' or ch == '[' or ch == '{';
}

// {{{1 Transform changes

const TransformedChange = struct {
    old_end_x: Column,
    new_end_x: Column,
    lookup_line_no: LineNumber,
    lookup_x: Column,
};

fn chompCr(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\r') {
        return text[0 .. text.len - 1];
    }
    return text;
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) !std.array_list.Managed([]const u8) {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    var start: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte == '\n') {
            try lines.append(chompCr(text[start..i]));
            start = i + 1;
        }
    }
    try lines.append(chompCr(text[start..]));
    return lines;
}

fn transformChange(change: Change) TransformedChange {
    var new_lines = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer new_lines.deinit();
    var old_lines = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer old_lines.deinit();

    // Split new_text
    {
        var start: usize = 0;
        for (change.new_text, 0..) |byte, i| {
            if (byte == '\n') {
                new_lines.append(chompCr(change.new_text[start..i])) catch {};
                start = i + 1;
            }
        }
        new_lines.append(chompCr(change.new_text[start..])) catch {};
    }

    // Split old_text
    {
        var start: usize = 0;
        for (change.old_text, 0..) |byte, i| {
            if (byte == '\n') {
                old_lines.append(chompCr(change.old_text[start..i])) catch {};
                start = i + 1;
            }
        }
        old_lines.append(chompCr(change.old_text[start..])) catch {};
    }

    const last_old_line_len = unicode.displayWidth(old_lines.items[old_lines.items.len - 1]);
    const last_new_line_len = unicode.displayWidth(new_lines.items[new_lines.items.len - 1]);

    const old_end_x = (if (old_lines.items.len == 1) change.x else 0) + last_old_line_len;
    const new_end_x = (if (new_lines.items.len == 1) change.x else 0) + last_new_line_len;
    const new_end_line_no = change.line_no + (new_lines.items.len - 1);

    return TransformedChange{
        .old_end_x = old_end_x,
        .new_end_x = new_end_x,
        .lookup_line_no = new_end_line_no,
        .lookup_x = new_end_x,
    };
}

const ChangeLookupKey = struct {
    line_no: LineNumber,
    x: Column,
};

const ChangeMap = std.HashMap(ChangeLookupKey, TransformedChange, struct {
    pub fn hash(_: @This(), key: ChangeLookupKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.line_no));
        h.update(std.mem.asBytes(&key.x));
        return h.final();
    }
    pub fn eql(_: @This(), a: ChangeLookupKey, b: ChangeLookupKey) bool {
        return a.line_no == b.line_no and a.x == b.x;
    }
}, std.hash_map.default_max_load_percentage);

fn transformChanges(allocator: std.mem.Allocator, input_changes: []const Change) !ChangeMap {
    var map = ChangeMap.init(allocator);
    for (input_changes) |change| {
        const tc = transformChange(change);
        try map.put(.{ .line_no = tc.lookup_line_no, .x = tc.lookup_x }, tc);
    }
    return map;
}

// {{{1 State structure

const TrackingArgTabStop = enum {
    not_searching,
    space,
    arg,
};

const EscapeState = enum {
    normal,
    escaping,
    escaped,
};

const Context = enum {
    code,
    comment,
    string,
};

const InternalMode = enum {
    indent,
    paren,
};

const ParenTrailClamped = struct {
    start_x: ?Column,
    end_x: ?Column,
    openers: std.array_list.Managed(Paren),
};

const InternalParenTrail = struct {
    line_no: ?LineNumber,
    start_x: ?Column,
    end_x: ?Column,
    openers: std.array_list.Managed(Paren),
    clamped: ParenTrailClamped,
};

/// A line that may be borrowed (from input) or owned (modified).
const Line = struct {
    data: []const u8,
    owned: ?[]u8, // if non-null, this was allocated and needs freeing
};

const ProcessError = error{
    Restart,
    ParinferError,
    OutOfMemory,
};

const ErrorPosCache = std.EnumArray(ErrorName, ?types.Error);

const State = struct {
    mode: InternalMode,
    smart: bool,

    orig_text: []const u8,
    orig_cursor_x: ?Column,
    orig_cursor_line: ?LineNumber,

    input_lines: std.array_list.Managed([]const u8),
    input_line_no: LineNumber,
    input_x: Column,

    lines: std.array_list.Managed(Line),
    line_no: LineNumber,
    ch: []const u8, // current grapheme (slice into input or constant)
    x: Column,
    indent_x: ?Column,

    paren_stack: std.array_list.Managed(Paren),

    tab_stops: std.array_list.Managed(TabStop),

    paren_trail: InternalParenTrail,
    paren_trails: std.array_list.Managed(ParenTrail),

    return_parens: bool,
    parens: std.array_list.Managed(Paren),

    cursor_x: ?Column,
    cursor_line: ?LineNumber,
    prev_cursor_x: ?Column,
    prev_cursor_line: ?Column,

    selection_start_line: ?LineNumber,

    changes: ChangeMap,

    context: Context,
    comment_x: ?Column,
    escape: EscapeState,

    quote_danger: bool,
    tracking_indent: bool,
    skip_char: bool,
    success: bool,
    partial_result: bool,
    force_balance: bool,

    max_indent: ?Column,
    indent_delta: Delta,

    tracking_arg_tab_stop: TrackingArgTabStop,

    err: ?types.Error,
    error_pos_cache: ErrorPosCache,

    allocator: std.mem.Allocator,

    fn isInCode(self: *const State) bool {
        return self.context == .code;
    }

    fn isInComment(self: *const State) bool {
        return self.context == .comment;
    }

    fn isInString(self: *const State) bool {
        return self.context == .string;
    }

    fn isEscaping(self: *const State) bool {
        return self.escape == .escaping;
    }

    fn isEscaped(self: *const State) bool {
        return self.escape == .escaped;
    }

    fn lineData(self: *const State, line_idx: usize) []const u8 {
        return self.lines.items[line_idx].data;
    }
};

fn initialParenTrail(allocator: std.mem.Allocator) InternalParenTrail {
    return InternalParenTrail{
        .line_no = null,
        .start_x = null,
        .end_x = null,
        .openers = std.array_list.Managed(Paren).init(allocator),
        .clamped = ParenTrailClamped{
            .start_x = null,
            .end_x = null,
            .openers = std.array_list.Managed(Paren).init(allocator),
        },
    };
}

fn getInitialState(allocator: std.mem.Allocator, text: []const u8, options: *const Options, mode: InternalMode, smart: bool) !State {
    var input_lines = try splitLines(allocator, text);
    _ = &input_lines;

    return State{
        .mode = mode,
        .smart = smart,

        .orig_text = text,
        .orig_cursor_x = options.cursor_x,
        .orig_cursor_line = options.cursor_line,

        .input_lines = input_lines,
        .input_line_no = 0,
        .input_x = 0,

        .lines = std.array_list.Managed(Line).init(allocator),
        .line_no = std.math.maxInt(usize),
        .ch = text[0..0], // empty slice
        .x = 0,
        .indent_x = null,

        .paren_stack = std.array_list.Managed(Paren).init(allocator),
        .tab_stops = std.array_list.Managed(TabStop).init(allocator),

        .paren_trail = initialParenTrail(allocator),
        .paren_trails = std.array_list.Managed(ParenTrail).init(allocator),

        .return_parens = options.return_parens,
        .parens = std.array_list.Managed(Paren).init(allocator),

        .cursor_x = options.cursor_x,
        .cursor_line = options.cursor_line,
        .prev_cursor_x = options.prev_cursor_x,
        .prev_cursor_line = options.prev_cursor_line,

        .selection_start_line = options.selection_start_line,

        .changes = try transformChanges(allocator, options.changes),

        .context = .code,
        .comment_x = null,
        .escape = .normal,

        .quote_danger = false,
        .tracking_indent = false,
        .skip_char = false,
        .success = false,
        .partial_result = options.partial_result,
        .force_balance = options.force_balance,

        .max_indent = null,
        .indent_delta = 0,

        .tracking_arg_tab_stop = .not_searching,

        .err = null,
        .error_pos_cache = ErrorPosCache.initFill(null),

        .allocator = allocator,
    };
}

// {{{1 Error handling

fn cacheErrorPos(result: *State, name: ErrorName) void {
    result.error_pos_cache.set(name, types.Error{
        .name = name,
        .msg = "",
        .line_no = result.line_no,
        .x = result.x,
        .input_line_no = result.input_line_no,
        .input_x = result.input_x,
    });
}

fn parinferError(result: *State, name: ErrorName) ProcessError {
    const cached = result.error_pos_cache.get(name);
    const line_no, const x = if (cached) |cache|
        if (result.partial_result)
            .{ cache.line_no, cache.x }
        else
            .{ cache.input_line_no, cache.input_x }
    else if (result.partial_result)
        .{ result.line_no, result.x }
    else
        .{ result.input_line_no, result.input_x };

    var e = types.Error{
        .name = name,
        .msg = name.message(),
        .line_no = line_no,
        .x = x,
        .input_line_no = result.input_line_no,
        .input_x = result.input_x,
    };

    if (name == .unclosed_paren) {
        if (peek(Paren, &result.paren_stack, 0)) |opener| {
            e.line_no = if (result.partial_result) opener.line_no else opener.input_line_no;
            e.x = if (result.partial_result) opener.x else opener.input_x;
        }
    }

    result.err = e;
    return ProcessError.ParinferError;
}

fn restartError() ProcessError {
    return ProcessError.Restart;
}

// {{{1 String operations

fn replaceWithinString(allocator: std.mem.Allocator, orig: []const u8, start: Column, end: Column, replace: []const u8) ![]u8 {
    const start_i = unicode.columnByteIndex(orig, start);
    const end_i = unicode.columnByteIndex(orig, end);
    const new_len = start_i + replace.len + (orig.len - end_i);
    const result = try allocator.alloc(u8, new_len);
    @memcpy(result[0..start_i], orig[0..start_i]);
    @memcpy(result[start_i .. start_i + replace.len], replace);
    @memcpy(result[start_i + replace.len ..], orig[end_i..]);
    return result;
}

fn repeatString(allocator: std.mem.Allocator, ch: u8, n: usize) ![]u8 {
    const result = try allocator.alloc(u8, n);
    @memset(result, ch);
    return result;
}

fn getLineEnding(text: []const u8) []const u8 {
    for (text) |byte| {
        if (byte == '\r') return "\r\n";
    }
    return "\n";
}

// {{{1 Misc utils

fn clamp(val: Delta, min_n: ?Delta, max_n: ?Delta) Delta {
    if (min_n) |low| {
        if (low >= val) return low;
    }
    if (max_n) |high| {
        if (high <= val) return high;
    }
    return val;
}

fn peek(comptime T: type, array: *const std.array_list.Managed(T), i: usize) ?*const T {
    if (i >= array.items.len) return null;
    return &array.items[array.items.len - 1 - i];
}

fn peekMut(comptime T: type, array: *std.array_list.Managed(T), i: usize) ?*T {
    if (i >= array.items.len) return null;
    return &array.items[array.items.len - 1 - i];
}

// {{{1 Character questions

fn isValidCloseParen(paren_stack: *const std.array_list.Managed(Paren), ch: u8) bool {
    if (paren_stack.items.len == 0) return false;
    if (peek(Paren, paren_stack, 0)) |opener| {
        if (matchParen(ch)) |close| {
            return opener.ch == close;
        }
    }
    return false;
}

fn isWhitespace(result: *const State) bool {
    return !result.isEscaped() and result.ch.len == 1 and result.ch[0] == BLANK_SPACE;
}

fn isDoubleSpace(result: *const State) bool {
    // Tab gets converted to two spaces
    return !result.isEscaped() and std.mem.eql(u8, result.ch, "  ");
}

fn isWhitespaceOrDoubleSpace(result: *const State) bool {
    return isWhitespace(result) or isDoubleSpace(result);
}

fn isClosable(result: *const State) bool {
    if (result.ch.len == 0) return false;
    if (!result.isInCode()) return false;
    if (isWhitespaceOrDoubleSpace(result)) return false;
    if (result.ch.len == 1 and isCloseParen(result.ch[0]) and !result.isEscaped()) return false;
    return true;
}

// {{{1 Line operations

fn isCursorAffected(result: *const State, start: Column, end: Column) bool {
    if (result.cursor_x) |cx| {
        if (cx == start and cx == end) return cx == 0;
        return cx >= end;
    }
    return false;
}

fn shiftCursorOnEdit(result: *State, line_no: LineNumber, start: Column, end: Column, replace: []const u8) void {
    const old_length = end - start;
    const new_length = unicode.displayWidth(replace);
    const dx = @as(Delta, @intCast(new_length)) - @as(Delta, @intCast(old_length));

    if (result.cursor_x != null and result.cursor_line != null) {
        const cursor_x = result.cursor_x.?;
        const cursor_line = result.cursor_line.?;
        if (dx != 0 and cursor_line == line_no and isCursorAffected(result, start, end)) {
            const new_cx = @as(Delta, @intCast(cursor_x)) + dx;
            result.cursor_x = @intCast(@max(0, new_cx));
        }
    }
}

fn replaceWithinLine(result: *State, line_no: LineNumber, start: Column, end: Column, replace: []const u8) !void {
    const line = result.lineData(line_no);
    const new_line = try replaceWithinString(result.allocator, line, start, end, replace);

    // Free old owned data if any
    if (result.lines.items[line_no].owned) |old| {
        result.allocator.free(old);
    }
    result.lines.items[line_no] = Line{ .data = new_line, .owned = new_line };

    shiftCursorOnEdit(result, line_no, start, end, replace);
}

fn insertWithinLine(result: *State, line_no: LineNumber, idx: Column, insert: []const u8) !void {
    try replaceWithinLine(result, line_no, idx, idx, insert);
}

fn initLine(result: *State) void {
    result.x = 0;
    result.line_no = result.line_no +% 1;

    result.indent_x = null;
    result.comment_x = null;
    result.indent_delta = 0;

    result.error_pos_cache.set(.unmatched_close_paren, null);
    result.error_pos_cache.set(.unmatched_open_paren, null);
    result.error_pos_cache.set(.leading_close_paren, null);

    result.tracking_arg_tab_stop = .not_searching;
    result.tracking_indent = !result.isInString();
}

fn commitChar(result: *State, orig_ch: []const u8) !void {
    const ch = result.ch;
    const ch_width = unicode.displayWidth(ch);
    if (!std.mem.eql(u8, orig_ch, ch)) {
        const orig_ch_width = unicode.displayWidth(orig_ch);
        try replaceWithinLine(result, result.line_no, result.x, result.x + orig_ch_width, ch);
        result.indent_delta -= @as(Delta, @intCast(orig_ch_width)) - @as(Delta, @intCast(ch_width));
    }
    result.x += ch_width;
}

// {{{1 Advanced operations on characters

fn checkCursorHolding(result: *const State) ProcessError!bool {
    const opener = peek(Paren, &result.paren_stack, 0).?;
    const hold_min_x: Column = if (peek(Paren, &result.paren_stack, 1)) |p| p.x + 1 else 0;
    const hold_max_x = opener.x;

    const holding = result.cursor_line != null and result.cursor_line.? == opener.line_no and
        result.cursor_x != null and result.cursor_x.? >= hold_min_x and
        result.cursor_x.? <= hold_max_x;

    const should_check_prev = result.changes.count() == 0 and result.prev_cursor_line != null;
    if (should_check_prev) {
        const prev_holding = result.prev_cursor_line != null and result.prev_cursor_line.? == opener.line_no and
            result.prev_cursor_x != null and result.prev_cursor_x.? >= hold_min_x and
            result.prev_cursor_x.? <= hold_max_x;
        if (prev_holding and !holding) {
            return restartError();
        }
    }

    return holding;
}

fn trackArgTabStop(result: *State, state: TrackingArgTabStop) void {
    if (state == .space) {
        if (result.isInCode() and isWhitespaceOrDoubleSpace(result)) {
            result.tracking_arg_tab_stop = .arg;
        }
    } else if (state == .arg and !isWhitespaceOrDoubleSpace(result)) {
        if (result.paren_stack.items.len > 0) {
            result.paren_stack.items[result.paren_stack.items.len - 1].arg_x = result.x;
        }
        result.tracking_arg_tab_stop = .not_searching;
    }
}

// {{{1 Literal character events

fn inCodeOnOpenParen(result: *State) !void {
    const opener = Paren{
        .input_line_no = result.input_line_no,
        .input_x = result.input_x,
        .line_no = result.line_no,
        .x = result.x,
        .ch = result.ch[0],
        .indent_delta = result.indent_delta,
        .max_child_indent = null,
        .arg_x = null,
        .closer = null,
        .children = std.array_list.Managed(Paren).init(result.allocator),
    };

    if (result.return_parens) {
        if (result.paren_stack.items.len > 0) {
            try result.paren_stack.items[result.paren_stack.items.len - 1].children.append(try opener.clone(result.allocator));
        } else {
            try result.parens.append(try opener.clone(result.allocator));
        }
    }
    try result.paren_stack.append(opener);
    result.tracking_arg_tab_stop = .space;
}

fn inCodeOnMatchedCloseParen(result: *State) ProcessError!void {
    var opener = (peek(Paren, &result.paren_stack, 0).?).*;
    if (result.return_parens) {
        opener.closer = Closer{
            .line_no = result.line_no,
            .x = result.x,
            .ch = result.ch[0],
            .trail = null,
        };
    }

    result.paren_trail.end_x = result.x + 1;
    result.paren_trail.openers.append(opener) catch return ProcessError.OutOfMemory;

    if (result.mode == .indent and result.smart and try checkCursorHolding(result)) {
        const orig_start_x = result.paren_trail.start_x;
        const orig_end_x = result.paren_trail.end_x;
        var orig_openers = std.array_list.Managed(Paren).init(result.allocator);
        orig_openers.appendSlice(result.paren_trail.openers.items) catch {};
        resetParenTrail(result, result.line_no, result.x + 1);
        // Free old clamped openers before replacing (resetParenTrail retains its capacity)
        result.paren_trail.clamped.openers.deinit();
        result.paren_trail.clamped = ParenTrailClamped{
            .start_x = orig_start_x,
            .end_x = orig_end_x,
            .openers = orig_openers,
        };
    }
    _ = result.paren_stack.pop();
    result.tracking_arg_tab_stop = .not_searching;
}

fn inCodeOnUnmatchedCloseParen(result: *State) ProcessError!void {
    switch (result.mode) {
        .paren => {
            const in_leading_paren_trail = result.paren_trail.line_no != null and
                result.paren_trail.line_no.? == result.line_no and
                result.paren_trail.start_x != null and
                result.indent_x != null and
                result.paren_trail.start_x.? == result.indent_x.?;
            const can_remove = result.smart and in_leading_paren_trail;
            if (!can_remove) {
                return parinferError(result, .unmatched_close_paren);
            }
        },
        .indent => {
            if (result.error_pos_cache.get(.unmatched_close_paren) == null) {
                cacheErrorPos(result, .unmatched_close_paren);
                if (peek(Paren, &result.paren_stack, 0)) |opener| {
                    cacheErrorPos(result, .unmatched_open_paren);
                    {
                        const err_ptr = result.error_pos_cache.getPtr(.unmatched_open_paren);
                        if (err_ptr.* != null) {
                            err_ptr.*.?.input_line_no = opener.input_line_no;
                            err_ptr.*.?.input_x = opener.input_x;
                        }
                    }
                }
            }
        },
    }
    result.ch = "";
}

fn inCodeOnCloseParen(result: *State) ProcessError!void {
    if (result.ch.len > 0 and isValidCloseParen(&result.paren_stack, result.ch[0])) {
        try inCodeOnMatchedCloseParen(result);
    } else {
        try inCodeOnUnmatchedCloseParen(result);
    }
}

fn inCodeOnTab(result: *State) void {
    result.ch = "  ";
}

fn inCodeOnCommentChar(result: *State) void {
    result.context = .comment;
    result.comment_x = result.x;
    result.tracking_arg_tab_stop = .not_searching;
}

fn onNewline(result: *State) void {
    if (result.isInComment()) {
        result.context = .code;
    }
    result.ch = "";
}

fn inCodeOnQuote(result: *State) void {
    result.context = .string;
    cacheErrorPos(result, .unclosed_quote);
}

fn inCommentOnQuote(result: *State) void {
    result.quote_danger = !result.quote_danger;
    if (result.quote_danger) {
        cacheErrorPos(result, .quote_danger);
    }
}

fn inStringOnQuote(result: *State) void {
    result.context = .code;
}

fn onBackslash(result: *State) void {
    result.escape = .escaping;
}

fn afterBackslash(result: *State) ProcessError!void {
    result.escape = .escaped;

    if (result.ch.len == 1 and result.ch[0] == NEWLINE) {
        if (result.isInCode()) {
            return parinferError(result, .eol_backslash);
        }
    }
}

// {{{1 Character dispatch

fn onContext(result: *State) ProcessError!void {
    if (result.ch.len == 0) return;
    const ch0 = result.ch[0];

    switch (result.context) {
        .code => {
            if (ch0 == SEMICOLON) {
                inCodeOnCommentChar(result);
            } else if (ch0 == DOUBLE_QUOTE) {
                inCodeOnQuote(result);
            } else if (isOpenParen(ch0)) {
                try inCodeOnOpenParen(result);
            } else if (isCloseParen(ch0)) {
                try inCodeOnCloseParen(result);
            } else if (ch0 == TAB) {
                inCodeOnTab(result);
            }
        },
        .comment => {
            if (ch0 == DOUBLE_QUOTE) {
                inCommentOnQuote(result);
            }
        },
        .string => {
            if (ch0 == DOUBLE_QUOTE) {
                inStringOnQuote(result);
            }
        },
    }
}

fn onChar(result: *State) ProcessError!void {
    if (result.isEscaped()) {
        result.escape = .normal;
    }

    if (result.isEscaping()) {
        try afterBackslash(result);
    } else if (result.ch.len == 1 and result.ch[0] == BACKSLASH) {
        onBackslash(result);
    } else if (result.ch.len == 1 and result.ch[0] == NEWLINE) {
        onNewline(result);
    } else {
        try onContext(result);
    }

    if (isClosable(result)) {
        const ch_width = unicode.displayWidth(result.ch);
        resetParenTrail(result, result.line_no, result.x + ch_width);
    }

    if (result.tracking_arg_tab_stop != .not_searching) {
        trackArgTabStop(result, result.tracking_arg_tab_stop);
    }
}

// {{{1 Cursor functions

fn isCursorLeftOf(cursor_x: ?Column, cursor_line: ?LineNumber, x: ?Column, line_no: LineNumber) bool {
    if (x != null and cursor_x != null) {
        return cursor_line != null and cursor_line.? == line_no and cursor_x.? <= x.?;
    }
    return false;
}

fn isCursorRightOf(cursor_x: ?Column, cursor_line: ?LineNumber, x: ?Column, line_no: LineNumber) bool {
    if (x != null and cursor_x != null) {
        return cursor_line != null and cursor_line.? == line_no and cursor_x.? > x.?;
    }
    return false;
}

fn isCursorInComment(result: *const State, cursor_x: ?Column, cursor_line: ?LineNumber) bool {
    return isCursorRightOf(cursor_x, cursor_line, result.comment_x, result.line_no);
}

fn handleChangeDelta(result: *State) void {
    if (result.changes.count() != 0 and (result.smart or result.mode == .paren)) {
        const key = ChangeLookupKey{ .line_no = result.input_line_no, .x = result.input_x };
        if (result.changes.get(key)) |change| {
            result.indent_delta += @as(Delta, @intCast(change.new_end_x)) - @as(Delta, @intCast(change.old_end_x));
        }
    }
}

// {{{1 Paren Trail functions

fn resetParenTrail(result: *State, line_no: LineNumber, x: Column) void {
    result.paren_trail.line_no = line_no;
    result.paren_trail.start_x = x;
    result.paren_trail.end_x = x;
    result.paren_trail.openers.clearRetainingCapacity();
    result.paren_trail.clamped.start_x = null;
    result.paren_trail.clamped.end_x = null;
    result.paren_trail.clamped.openers.clearRetainingCapacity();
}

fn isCursorClampingParenTrail(result: *const State, cursor_x: ?Column, cursor_line: ?LineNumber) bool {
    return isCursorRightOf(cursor_x, cursor_line, result.paren_trail.start_x, result.line_no) and
        !isCursorInComment(result, cursor_x, cursor_line);
}

fn clampParenTrailToCursor(result: *State) !void {
    const clamping = isCursorClampingParenTrail(result, result.cursor_x, result.cursor_line);
    if (!clamping) return;

    const start_x = result.paren_trail.start_x.?;
    const end_x = result.paren_trail.end_x.?;

    const new_start_x = @max(start_x, result.cursor_x.?);
    const new_end_x = @max(end_x, result.cursor_x.?);

    const line = result.lineData(result.line_no);
    var remove_count: usize = 0;
    var iter = unicode.GraphemeIterator.init(line);
    var col: usize = 0;
    while (iter.next()) |g| {
        if (col >= start_x and col < new_start_x) {
            if (g.bytes.len == 1 and isCloseParen(g.bytes[0])) {
                remove_count += 1;
            }
        }
        col += g.width;
    }

    // Save clamped portion
    var clamped_openers = std.array_list.Managed(Paren).init(result.allocator);
    if (remove_count > 0 and remove_count <= result.paren_trail.openers.items.len) {
        try clamped_openers.appendSlice(result.paren_trail.openers.items[0..remove_count]);
    }

    var remaining = std.array_list.Managed(Paren).init(result.allocator);
    if (remove_count < result.paren_trail.openers.items.len) {
        try remaining.appendSlice(result.paren_trail.openers.items[remove_count..]);
    }

    result.paren_trail.openers.deinit();
    result.paren_trail.openers = remaining;
    result.paren_trail.start_x = new_start_x;
    result.paren_trail.end_x = new_end_x;

    result.paren_trail.clamped.openers.deinit();
    result.paren_trail.clamped.openers = clamped_openers;
    result.paren_trail.clamped.start_x = start_x;
    result.paren_trail.clamped.end_x = end_x;
}

fn popParenTrail(result: *State) !void {
    if (result.paren_trail.start_x == null or result.paren_trail.end_x == null) return;
    if (result.paren_trail.start_x.? == result.paren_trail.end_x.?) return;

    while (result.paren_trail.openers.items.len > 0) {
        const paren = result.paren_trail.openers.pop().?;
        try result.paren_stack.append(paren);
    }
}

fn getParentOpenerIndex(result: *State, indent_x: usize) usize {
    for (0..result.paren_stack.items.len) |i| {
        const opener = (peek(Paren, &result.paren_stack, i)).?;
        const opener_index = result.paren_stack.items.len - i - 1;

        const curr_outside = opener.x < indent_x;
        const prev_indent_x = @as(Delta, @intCast(indent_x)) - result.indent_delta;
        const prev_outside = @as(Delta, @intCast(opener.x)) - opener.indent_delta < prev_indent_x;

        var is_parent = false;

        if (prev_outside and curr_outside) {
            is_parent = true;
        } else if (!prev_outside and !curr_outside) {
            is_parent = false;
        } else if (prev_outside and !curr_outside) {
            // Possible fragmentation
            if (result.indent_delta == 0) {
                is_parent = true;
            } else if (opener.indent_delta == 0) {
                is_parent = false;
            } else {
                is_parent = false;
            }
        } else if (!prev_outside and curr_outside) {
            // Possible adoption
            const next_opener = peek(Paren, &result.paren_stack, i + 1);

            if (next_opener) |no| {
                if (no.indent_delta <= opener.indent_delta) {
                    if (@as(Delta, @intCast(indent_x)) + no.indent_delta > @as(Delta, @intCast(opener.x))) {
                        is_parent = true;
                    } else {
                        is_parent = false;
                    }
                } else if (no.indent_delta > opener.indent_delta) {
                    is_parent = true;
                }
            } else {
                if (result.indent_delta > opener.indent_delta) {
                    is_parent = true;
                }
            }

            if (is_parent) {
                result.paren_stack.items[opener_index].indent_delta = 0;
            }
        }

        if (is_parent) {
            return i;
        }
    }

    return result.paren_stack.items.len;
}

fn correctParenTrail(result: *State, indent_x: usize) !void {
    var parens = std.array_list.Managed(u8).init(result.allocator);
    defer parens.deinit();

    const index = getParentOpenerIndex(result, indent_x);
    for (0..index) |i| {
        var opener = result.paren_stack.pop().?;
        const close_ch = matchParen(opener.ch).?;
        if (result.return_parens) {
            opener.closer = Closer{
                .line_no = result.paren_trail.line_no.?,
                .x = result.paren_trail.start_x.? + i,
                .ch = close_ch,
                .trail = null,
            };
        }
        try result.paren_trail.openers.append(opener);
        try parens.append(close_ch);
    }

    if (result.paren_trail.line_no) |trail_line_no| {
        const start_x = result.paren_trail.start_x.?;
        const end_x = result.paren_trail.end_x.?;
        try replaceWithinLine(result, trail_line_no, start_x, end_x, parens.items);
        result.paren_trail.end_x = if (result.paren_trail.start_x) |sx| sx + parens.items.len else null;
        rememberParenTrail(result);
    }
}

fn cleanParenTrail(result: *State) !void {
    if (result.paren_trail.start_x == null or result.paren_trail.end_x == null) return;
    if (result.paren_trail.start_x.? == result.paren_trail.end_x.?) return;
    if (result.paren_trail.line_no == null or result.paren_trail.line_no.? != result.line_no) return;

    const start_x = result.paren_trail.start_x.?;
    const end_x = result.paren_trail.end_x.?;

    var new_trail = std.array_list.Managed(u8).init(result.allocator);
    defer new_trail.deinit();
    var space_count: usize = 0;

    const line = result.lineData(result.line_no);
    var iter = unicode.GraphemeIterator.init(line);
    var col: usize = 0;
    while (iter.next()) |g| {
        if (col >= start_x and col < end_x) {
            if (g.bytes.len == 1 and isCloseParen(g.bytes[0])) {
                try new_trail.append(g.bytes[0]);
            } else {
                space_count += 1;
            }
        }
        col += g.width;
    }

    if (space_count > 0) {
        try replaceWithinLine(result, result.line_no, start_x, end_x, new_trail.items);
        if (result.paren_trail.end_x) |*ex| {
            ex.* -= space_count;
        }
    }
}

fn setCloser(opener: *Paren, line_no: LineNumber, x: Column, ch: u8) void {
    opener.closer = Closer{
        .line_no = line_no,
        .x = x,
        .ch = ch,
        .trail = null,
    };
}

fn appendParenTrail(result: *State) !void {
    var opener = result.paren_stack.pop().?;
    const close_ch = matchParen(opener.ch).?;
    if (result.return_parens) {
        setCloser(&opener, result.paren_trail.line_no.?, result.paren_trail.end_x.?, close_ch);
    }

    setMaxIndent(result, &opener);
    const trail_line_no = result.paren_trail.line_no.?;
    const end_x = result.paren_trail.end_x.?;
    try insertWithinLine(result, trail_line_no, end_x, &[_]u8{close_ch});

    if (result.paren_trail.end_x) |*ex| {
        ex.* += 1;
    }
    try result.paren_trail.openers.append(opener);
    updateRememberedParenTrail(result);
}

fn invalidateParenTrail(result: *State) void {
    result.paren_trail = initialParenTrail(result.allocator);
}

fn checkUnmatchedOutsideParenTrail(result: *State) ProcessError!void {
    if (result.error_pos_cache.get(.unmatched_close_paren)) |cache| {
        if (result.paren_trail.start_x) |sx| {
            if (cache.x < sx) {
                return parinferError(result, .unmatched_close_paren);
            }
        }
    }
}

fn setMaxIndent(result: *State, opener: *const Paren) void {
    if (result.paren_stack.items.len > 0) {
        result.paren_stack.items[result.paren_stack.items.len - 1].max_child_indent = opener.x;
    } else {
        result.max_indent = opener.x;
    }
}

fn rememberParenTrail(result: *State) void {
    if (result.paren_trail.clamped.openers.items.len > 0 or result.paren_trail.openers.items.len > 0) {
        const is_clamped = result.paren_trail.clamped.start_x != null;
        const short_trail = ParenTrail{
            .line_no = result.paren_trail.line_no.?,
            .start_x = if (is_clamped) result.paren_trail.clamped.start_x.? else result.paren_trail.start_x.?,
            .end_x = if (is_clamped) result.paren_trail.clamped.end_x.? else result.paren_trail.end_x.?,
        };

        result.paren_trails.append(short_trail) catch {};

        if (result.return_parens) {
            for (result.paren_trail.openers.items) |*opener| {
                if (opener.closer) |*closer| {
                    closer.trail = short_trail;
                }
            }
        }
    }
}

fn updateRememberedParenTrail(result: *State) void {
    if (result.paren_trails.items.len == 0 or
        result.paren_trail.line_no == null or
        result.paren_trails.items[result.paren_trails.items.len - 1].line_no != result.paren_trail.line_no.?)
    {
        rememberParenTrail(result);
    } else {
        const n = result.paren_trails.items.len - 1;
        result.paren_trails.items[n].end_x = result.paren_trail.end_x.?;
        if (result.return_parens) {
            if (result.paren_trail.openers.items.len > 0) {
                const last = &result.paren_trail.openers.items[result.paren_trail.openers.items.len - 1];
                if (last.closer) |*closer| {
                    closer.trail = result.paren_trails.items[n];
                }
            }
        }
    }
}

fn finishNewParenTrail(result: *State) !void {
    if (result.isInString()) {
        invalidateParenTrail(result);
    } else if (result.mode == .indent) {
        try clampParenTrailToCursor(result);
        try popParenTrail(result);
    } else if (result.mode == .paren) {
        if (peek(Paren, &result.paren_trail.openers, 0)) |paren| {
            setMaxIndent(result, paren);
        }
        if (result.cursor_line == null or result.cursor_line.? != result.line_no) {
            try cleanParenTrail(result);
        }
        rememberParenTrail(result);
    }
}

// {{{1 Indentation functions

fn addIndent(result: *State, delta: Delta) !void {
    const orig_indent = result.x;
    const new_indent_signed = @as(Delta, @intCast(orig_indent)) + delta;
    const new_indent: usize = if (new_indent_signed < 0) 0 else @intCast(new_indent_signed);
    const indent_str = try repeatString(result.allocator, BLANK_SPACE, new_indent);
    defer result.allocator.free(indent_str);
    try replaceWithinLine(result, result.line_no, 0, orig_indent, indent_str);
    result.x = new_indent;
    result.indent_x = new_indent;
    result.indent_delta += delta;
}

fn shouldAddOpenerIndent(result: *const State, opener: *const Paren) bool {
    return opener.indent_delta != result.indent_delta;
}

fn correctIndent(result: *State) !void {
    const orig_indent = @as(Delta, @intCast(result.x));
    var new_indent = orig_indent;
    var min_indent: Delta = 0;
    var max_indent: ?Delta = if (result.max_indent) |m| @intCast(m) else null;

    if (peek(Paren, &result.paren_stack, 0)) |opener| {
        min_indent = @as(Delta, @intCast(opener.x)) + 1;
        max_indent = if (opener.max_child_indent) |m| @intCast(m) else null;
        if (shouldAddOpenerIndent(result, opener)) {
            new_indent += opener.indent_delta;
        }
    }

    new_indent = clamp(new_indent, min_indent, max_indent);

    if (new_indent != orig_indent) {
        try addIndent(result, new_indent - orig_indent);
    }
}

fn onIndent(result: *State) ProcessError!void {
    result.indent_x = result.x;
    result.tracking_indent = false;

    if (result.quote_danger) {
        return parinferError(result, .quote_danger);
    }

    switch (result.mode) {
        .indent => {
            const x = result.x;
            correctParenTrail(result, x) catch return ProcessError.OutOfMemory;

            var to_add: ?Delta = null;
            if (peek(Paren, &result.paren_stack, 0)) |opener| {
                if (shouldAddOpenerIndent(result, opener)) {
                    to_add = opener.indent_delta;
                }
            }

            if (to_add) |adjust| {
                addIndent(result, adjust) catch return ProcessError.OutOfMemory;
            }
        },
        .paren => {
            correctIndent(result) catch return ProcessError.OutOfMemory;
        },
    }
}

fn checkLeadingCloseParen(result: *State) ProcessError!void {
    if (result.error_pos_cache.get(.leading_close_paren) != null and
        result.paren_trail.line_no != null and
        result.paren_trail.line_no.? == result.line_no)
    {
        return parinferError(result, .leading_close_paren);
    }
}

fn onLeadingCloseParen(result: *State) ProcessError!void {
    switch (result.mode) {
        .indent => {
            if (!result.force_balance) {
                if (result.smart) {
                    return restartError();
                }
                if (result.error_pos_cache.get(.leading_close_paren) == null) {
                    cacheErrorPos(result, .leading_close_paren);
                }
            }
            result.skip_char = true;
        },
        .paren => {
            if (result.ch.len > 0 and !isValidCloseParen(&result.paren_stack, result.ch[0])) {
                if (result.smart) {
                    result.skip_char = true;
                } else {
                    return parinferError(result, .unmatched_close_paren);
                }
            } else if (isCursorLeftOf(result.cursor_x, result.cursor_line, result.x, result.line_no)) {
                resetParenTrail(result, result.line_no, result.x);
                try onIndent(result);
            } else {
                appendParenTrail(result) catch return ProcessError.OutOfMemory;
                result.skip_char = true;
            }
        },
    }
}

fn onCommentLine(result: *State) !void {
    const paren_trail_length = result.paren_trail.openers.items.len;

    if (result.mode == .paren) {
        var j: usize = 0;
        while (j < paren_trail_length) : (j += 1) {
            if (peek(Paren, &result.paren_trail.openers, j)) |opener| {
                try result.paren_stack.append(opener.*);
            }
        }
    }

    const x = result.x;
    const i = getParentOpenerIndex(result, x);
    var indent_to_add: Delta = 0;
    if (peek(Paren, &result.paren_stack, i)) |opener| {
        if (shouldAddOpenerIndent(result, opener)) {
            indent_to_add = opener.indent_delta;
        }
    }
    if (indent_to_add != 0) {
        try addIndent(result, indent_to_add);
    }

    if (result.mode == .paren) {
        var j: usize = 0;
        while (j < paren_trail_length) : (j += 1) {
            _ = result.paren_stack.pop();
        }
    }
}

fn checkIndent(result: *State) ProcessError!void {
    if (result.ch.len > 0 and result.ch.len == 1 and isCloseParen(result.ch[0])) {
        try onLeadingCloseParen(result);
    } else if (result.ch.len == 1 and result.ch[0] == SEMICOLON) {
        onCommentLine(result) catch return ProcessError.OutOfMemory;
        result.tracking_indent = false;
    } else if (result.ch.len > 0 and
        !(result.ch.len == 1 and result.ch[0] == NEWLINE) and
        !(result.ch.len == 1 and result.ch[0] == BLANK_SPACE) and
        !(result.ch.len == 1 and result.ch[0] == TAB))
    {
        try onIndent(result);
    }
}

fn makeTabStop(opener: *const Paren) TabStop {
    return TabStop{
        .ch = opener.ch,
        .x = opener.x,
        .line_no = opener.line_no,
        .arg_x = opener.arg_x,
    };
}

fn getTabStopLine(result: *const State) ?LineNumber {
    return result.selection_start_line orelse result.cursor_line;
}

fn setTabStops(result: *State) !void {
    if (getTabStopLine(result) != result.line_no) return;

    result.tab_stops.clearRetainingCapacity();
    for (result.paren_stack.items) |*opener| {
        try result.tab_stops.append(makeTabStop(opener));
    }

    if (result.mode == .paren) {
        var i = result.paren_trail.openers.items.len;
        while (i > 0) {
            i -= 1;
            try result.tab_stops.append(makeTabStop(&result.paren_trail.openers.items[i]));
        }
    }

    // Remove argX if it falls to the right of the next stop
    if (result.tab_stops.items.len > 1) {
        for (1..result.tab_stops.items.len) |j| {
            const x_val = result.tab_stops.items[j].x;
            if (result.tab_stops.items[j - 1].arg_x) |prev_arg_x| {
                if (prev_arg_x >= x_val) {
                    result.tab_stops.items[j - 1].arg_x = null;
                }
            }
        }
    }
}

// {{{1 High-level processing functions

fn processChar(result: *State, ch: []const u8) ProcessError!void {
    const orig_ch = ch;
    result.ch = ch;
    result.skip_char = false;

    handleChangeDelta(result);

    if (result.tracking_indent) {
        try checkIndent(result);
    }

    if (result.skip_char) {
        result.ch = "";
    } else {
        try onChar(result);
    }

    commitChar(result, orig_ch) catch return ProcessError.OutOfMemory;
}

fn processLine(result: *State, line_no: usize) ProcessError!void {
    initLine(result);
    result.lines.append(Line{
        .data = result.input_lines.items[line_no],
        .owned = null,
    }) catch return ProcessError.OutOfMemory;

    setTabStops(result) catch return ProcessError.OutOfMemory;

    const input_line = result.input_lines.items[line_no];
    var iter = unicode.GraphemeIterator.init(input_line);
    var col: usize = 0;
    while (iter.next()) |g| {
        result.input_x = col;
        try processChar(result, g.bytes);
        col += g.width;
    }
    // Don't update input_x for newline — it should stay at the last grapheme's column
    // (Rust code also doesn't update it before process_char(result, NEWLINE))
    try processChar(result, "\n");

    if (!result.force_balance) {
        try checkUnmatchedOutsideParenTrail(result);
        try checkLeadingCloseParen(result);
    }

    if (result.paren_trail.line_no != null and result.paren_trail.line_no.? == result.line_no) {
        finishNewParenTrail(result) catch return ProcessError.OutOfMemory;
    }
}

fn finalizeResult(result: *State) ProcessError!void {
    if (result.quote_danger) {
        return parinferError(result, .quote_danger);
    }
    if (result.isInString()) {
        return parinferError(result, .unclosed_quote);
    }

    if (result.paren_stack.items.len != 0) {
        if (result.mode == .paren) {
            return parinferError(result, .unclosed_paren);
        }
    }
    if (result.mode == .indent) {
        initLine(result);
        try onIndent(result);
    }
    result.success = true;
}

fn processText(allocator: std.mem.Allocator, text: []const u8, options: *const Options, mode: InternalMode, smart: bool) !State {
    var result = try getInitialState(allocator, text, options, mode, smart);

    var process_result: ProcessError!void = {};
    for (0..result.input_lines.items.len) |i| {
        result.input_line_no = i;
        process_result = processLine(&result, i);
        if (process_result) |_| {} else |_| break;
    }

    if (process_result) |_| {
        process_result = finalizeResult(&result);
    } else |_| {}

    if (process_result) |_| {} else |err| {
        switch (err) {
            ProcessError.Restart => {
                // Free state and retry in paren mode
                freeState(&result);
                return processText(allocator, text, options, .paren, smart);
            },
            ProcessError.ParinferError => {
                result.success = false;
                // err details already stored in result.err
            },
            ProcessError.OutOfMemory => return ProcessError.OutOfMemory,
        }
    }

    return result;
}

fn freeParenList(list: *std.array_list.Managed(Paren)) void {
    for (list.items) |*paren| {
        freeParenList(&paren.children);
    }
    list.deinit();
}

fn freeState(state: *State) void {
    // Free owned lines
    for (state.lines.items) |line| {
        if (line.owned) |owned| {
            state.allocator.free(owned);
        }
    }
    state.lines.deinit();
    state.input_lines.deinit();
    // Recursively free Paren children in all Paren-containing lists
    for (state.paren_stack.items) |*p| freeParenList(&p.children);
    state.paren_stack.deinit();
    state.tab_stops.deinit();
    for (state.paren_trail.openers.items) |*p| freeParenList(&p.children);
    state.paren_trail.openers.deinit();
    for (state.paren_trail.clamped.openers.items) |*p| freeParenList(&p.children);
    state.paren_trail.clamped.openers.deinit();
    state.paren_trails.deinit();
    for (state.parens.items) |*p| freeParenList(&p.children);
    state.parens.deinit();
    state.changes.deinit();
}

// {{{1 Public API

fn publicResult(allocator: std.mem.Allocator, result: *State) !Answer {
    const line_ending = getLineEnding(result.orig_text);

    // Join lines
    var total_len: usize = 0;
    for (result.lines.items, 0..) |line, i| {
        total_len += line.data.len;
        if (i < result.lines.items.len - 1) {
            total_len += line_ending.len;
        }
    }

    if (result.success) {
        const text = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (result.lines.items, 0..) |line, i| {
            @memcpy(text[pos .. pos + line.data.len], line.data);
            pos += line.data.len;
            if (i < result.lines.items.len - 1) {
                @memcpy(text[pos .. pos + line_ending.len], line_ending);
                pos += line_ending.len;
            }
        }

        const tab_stops = try allocator.dupe(TabStop, result.tab_stops.items);
        const paren_trails = try allocator.dupe(ParenTrail, result.paren_trails.items);
        const parens = try allocator.dupe(Paren, result.parens.items);

        return Answer{
            .text = text,
            .cursor_x = result.cursor_x,
            .cursor_line = result.cursor_line,
            .success = true,
            .tab_stops = tab_stops,
            .paren_trails = paren_trails,
            .parens = parens,
            .err = null,
        };
    } else {
        const text = if (result.partial_result) blk: {
            const t = try allocator.alloc(u8, total_len);
            var pos: usize = 0;
            for (result.lines.items, 0..) |line, i| {
                @memcpy(t[pos .. pos + line.data.len], line.data);
                pos += line.data.len;
                if (i < result.lines.items.len - 1) {
                    @memcpy(t[pos .. pos + line_ending.len], line_ending);
                    pos += line_ending.len;
                }
            }
            break :blk t;
        } else blk: {
            break :blk try allocator.dupe(u8, result.orig_text);
        };

        return Answer{
            .text = text,
            .cursor_x = if (result.partial_result) result.cursor_x else result.orig_cursor_x,
            .cursor_line = if (result.partial_result) result.cursor_line else result.orig_cursor_line,
            .paren_trails = try allocator.dupe(ParenTrail, result.paren_trails.items),
            .success = false,
            .tab_stops = try allocator.dupe(TabStop, result.tab_stops.items),
            .err = result.err,
            .parens = try allocator.dupe(Paren, result.parens.items),
        };
    }
}

pub fn indentMode(allocator: std.mem.Allocator, text: []const u8, options: *const Options) !Answer {
    var result = try processText(allocator, text, options, .indent, false);
    defer freeState(&result);
    return publicResult(allocator, &result);
}

pub fn parenMode(allocator: std.mem.Allocator, text: []const u8, options: *const Options) !Answer {
    var result = try processText(allocator, text, options, .paren, false);
    defer freeState(&result);
    return publicResult(allocator, &result);
}

pub fn smartMode(allocator: std.mem.Allocator, text: []const u8, options: *const Options) !Answer {
    const smart = options.selection_start_line == null;
    var result = try processText(allocator, text, options, .indent, smart);
    defer freeState(&result);
    return publicResult(allocator, &result);
}

pub fn process(allocator: std.mem.Allocator, request: *const Request) !Answer {
    var options = request.options;

    if (request.options.prev_text) |prev_text| {
        if (try changes_mod.computeTextChange(allocator, prev_text, request.text)) |change| {
            const changes = try allocator.alloc(Change, 1);
            changes[0] = change;
            options.changes = changes;
            options._changes_owned = true;
        }
    }
    defer {
        if (options._changes_owned) {
            for (options.changes) |ch| {
                allocator.free(ch.old_text);
                allocator.free(ch.new_text);
            }
            allocator.free(options.changes);
            options._changes_owned = false;
        }
    }

    return switch (request.mode) {
        .paren => parenMode(allocator, request.text, &options),
        .indent => indentMode(allocator, request.text, &options),
        .smart => smartMode(allocator, request.text, &options),
    };
}

/// Free an Answer that was allocated by process/indentMode/parenMode/smartMode.
pub fn freeAnswer(allocator: std.mem.Allocator, answer: *const Answer) void {
    if (answer.text.len > 0) allocator.free(answer.text);
    if (answer.tab_stops.len > 0) allocator.free(answer.tab_stops);
    if (answer.paren_trails.len > 0) allocator.free(answer.paren_trails);
    if (answer.parens.len > 0) allocator.free(answer.parens);
}

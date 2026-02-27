const std = @import("std");

pub const LineNumber = usize;
pub const Column = usize;
pub const Delta = i64;

pub const Change = struct {
    x: Column,
    line_no: LineNumber,
    old_text: []const u8,
    new_text: []const u8,
};

pub const Options = struct {
    cursor_x: ?Column = null,
    cursor_line: ?LineNumber = null,
    prev_cursor_x: ?Column = null,
    prev_cursor_line: ?LineNumber = null,
    selection_start_line: ?LineNumber = null,
    changes: []const Change = &.{},
    partial_result: bool = false,
    force_balance: bool = false,
    return_parens: bool = false,
    prev_text: ?[]const u8 = null,

    // Allocator-managed fields that need cleanup
    _changes_owned: bool = false,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        if (self._changes_owned) {
            for (self.changes) |ch| {
                allocator.free(ch.old_text);
                allocator.free(ch.new_text);
            }
            allocator.free(self.changes);
        }
        if (self.prev_text) |pt| {
            allocator.free(pt);
        }
    }
};

pub const Mode = enum {
    indent,
    paren,
    smart,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "indent")) return .indent;
        if (std.mem.eql(u8, s, "paren")) return .paren;
        if (std.mem.eql(u8, s, "smart")) return .smart;
        return null;
    }
};

pub const ErrorName = enum {
    quote_danger,
    eol_backslash,
    unclosed_quote,
    unclosed_paren,
    unmatched_close_paren,
    unmatched_open_paren,
    leading_close_paren,

    pub fn toString(self: ErrorName) []const u8 {
        return switch (self) {
            .quote_danger => "quote-danger",
            .eol_backslash => "eol-backslash",
            .unclosed_quote => "unclosed-quote",
            .unclosed_paren => "unclosed-paren",
            .unmatched_close_paren => "unmatched-close-paren",
            .unmatched_open_paren => "unmatched-open-paren",
            .leading_close_paren => "leading-close-paren",
        };
    }

    pub fn message(self: ErrorName) []const u8 {
        return switch (self) {
            .quote_danger => "Quotes must balanced inside comment blocks.",
            .eol_backslash => "Line cannot end in a hanging backslash.",
            .unclosed_quote => "String is missing a closing quote.",
            .unclosed_paren => "Unclosed open-paren.",
            .unmatched_close_paren => "Unmatched close-paren.",
            .unmatched_open_paren => "Unmatched open-paren.",
            .leading_close_paren => "Line cannot lead with a close-paren.",
        };
    }
};

pub const Error = struct {
    name: ErrorName = .quote_danger,
    msg: []const u8 = "",
    x: Column = 0,
    line_no: LineNumber = 0,
    input_x: Column = 0,
    input_line_no: LineNumber = 0,
};

pub const TabStop = struct {
    ch: u8, // always an ASCII paren: ( [ {
    x: Column,
    line_no: LineNumber,
    arg_x: ?Column,
};

pub const ParenTrail = struct {
    line_no: LineNumber,
    start_x: Column,
    end_x: Column,
};

pub const Closer = struct {
    line_no: LineNumber,
    x: Column,
    ch: u8,
    trail: ?ParenTrail,
};

pub const Paren = struct {
    line_no: LineNumber,
    x: Column,
    ch: u8, // opening paren character
    indent_delta: Delta,
    max_child_indent: ?Column,
    arg_x: ?Column,
    input_line_no: LineNumber,
    input_x: Column,
    closer: ?Closer,
    children: std.array_list.Managed(Paren),

    pub fn clone(self: Paren, allocator: std.mem.Allocator) !Paren {
        var new_children = std.array_list.Managed(Paren).init(allocator);
        try new_children.ensureTotalCapacity(self.children.items.len);
        for (self.children.items) |child| {
            try new_children.append(try child.clone(allocator));
        }
        return Paren{
            .line_no = self.line_no,
            .x = self.x,
            .ch = self.ch,
            .indent_delta = self.indent_delta,
            .max_child_indent = self.max_child_indent,
            .arg_x = self.arg_x,
            .input_line_no = self.input_line_no,
            .input_x = self.input_x,
            .closer = self.closer,
            .children = new_children,
        };
    }
};

pub const Answer = struct {
    text: []const u8,
    success: bool,
    err: ?Error,
    cursor_x: ?Column,
    cursor_line: ?LineNumber,
    tab_stops: []const TabStop,
    paren_trails: []const ParenTrail,
    parens: []const Paren,

    pub fn fromError(e: Error) Answer {
        return Answer{
            .text = "",
            .success = false,
            .err = e,
            .cursor_x = null,
            .cursor_line = null,
            .tab_stops = &.{},
            .paren_trails = &.{},
            .parens = &.{},
        };
    }
};

pub const Request = struct {
    mode: Mode,
    text: []const u8,
    options: Options,
};

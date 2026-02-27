/// Emacs module wrapper for parinfer.
/// Exports all functions that parinfer-rust-mode expects.
const std = @import("std");
const emacs = @import("emacs.zig");
const types = @import("types.zig");
const parinfer = @import("parinfer.zig");

const Env = emacs.Env;
const Value = emacs.Value;
const Allocator = std.mem.Allocator;

const allocator = std.heap.c_allocator;

const VERSION = "0.5.0";

// ============================================================
// User pointer types and finalizers
// ============================================================

const OptionsBox = struct {
    options: types.Options,
};

const ChangeListBox = struct {
    changes: std.array_list.Managed(types.Change),
};

const ChangeBox = struct {
    change: types.Change,
    old_text_owned: []u8,
    new_text_owned: []u8,
};

const RequestBox = struct {
    request: types.Request,
    text_owned: []u8,
    mode_str: []u8,
};

const AnswerBox = struct {
    answer: types.Answer,
    // Keep a reference to ensure text stays alive if it references request
    text_owned: bool,
};

fn optionsFinalizer(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const box: *OptionsBox = @ptrCast(@alignCast(p));
        allocator.destroy(box);
    }
}

fn changeListFinalizer(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const box: *ChangeListBox = @ptrCast(@alignCast(p));
        box.changes.deinit();
        allocator.destroy(box);
    }
}

fn changeFinalizer(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const box: *ChangeBox = @ptrCast(@alignCast(p));
        allocator.free(box.old_text_owned);
        allocator.free(box.new_text_owned);
        allocator.destroy(box);
    }
}

fn requestFinalizer(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const box: *RequestBox = @ptrCast(@alignCast(p));
        allocator.free(box.text_owned);
        allocator.free(box.mode_str);
        allocator.destroy(box);
    }
}

fn answerFinalizer(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const box: *AnswerBox = @ptrCast(@alignCast(p));
        parinfer.freeAnswer(allocator, &box.answer);
        allocator.destroy(box);
    }
}

// ============================================================
// Helper: extract typed pointer from user_ptr
// ============================================================

fn getUserPtr(comptime T: type, env: *Env, val: Value) ?*T {
    const raw = env.getUserPtr(val) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn signalError(env: *Env, msg: []const u8) Value {
    const sym = env.internStr("error");
    const data = env.list(&.{env.makeStr(msg)});
    env.non_local_exit_signal(env, sym, data);
    return env.nil();
}

// ============================================================
// Exported functions
// ============================================================

/// (parinfer-rust-make-option) → user_ptr(Options)
fn makeOption(env: *Env, _: isize, _: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const box = allocator.create(OptionsBox) catch return signalError(env, "out of memory");
    box.* = OptionsBox{ .options = .{} };
    return env.makeUserPtr(optionsFinalizer, box);
}

/// (parinfer-rust-new-options cursor_x cursor_line sel_start old_opts changes) → user_ptr(Options)
fn newOptions(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const cursor_x: ?usize = blk: {
        if (env.is_not_nil(env, args[0])) {
            const v = env.extractInt(args[0]);
            if (v >= 0) break :blk @intCast(v);
        }
        break :blk null;
    };
    const cursor_line: ?usize = blk: {
        if (env.is_not_nil(env, args[1])) {
            const v = env.extractInt(args[1]);
            if (v >= 0) break :blk @intCast(v);
        }
        break :blk null;
    };
    const sel_start: ?usize = blk: {
        if (env.is_not_nil(env, args[2])) {
            const v = env.extractInt(args[2]);
            if (v >= 0) break :blk @intCast(v);
        }
        break :blk null;
    };

    const old_opts_box = getUserPtr(OptionsBox, env, args[3]) orelse return signalError(env, "invalid options");
    const change_list_box = getUserPtr(ChangeListBox, env, args[4]) orelse return signalError(env, "invalid change list");

    const box = allocator.create(OptionsBox) catch return signalError(env, "out of memory");
    box.* = OptionsBox{
        .options = .{
            .cursor_x = cursor_x,
            .cursor_line = cursor_line,
            .prev_cursor_x = old_opts_box.options.cursor_x,
            .prev_cursor_line = old_opts_box.options.cursor_line,
            .selection_start_line = sel_start,
            .changes = change_list_box.changes.items,
            .prev_text = null,
            .partial_result = old_opts_box.options.partial_result,
            .force_balance = old_opts_box.options.force_balance,
            .return_parens = old_opts_box.options.return_parens,
        },
    };

    return env.makeUserPtr(optionsFinalizer, box);
}

/// (parinfer-rust-set-option opts keyword value)
fn setOption(env: *Env, nargs: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const box = getUserPtr(OptionsBox, env, args[0]) orelse return signalError(env, "invalid options");
    const keyword = args[1];

    const new_value: ?Value = if (nargs >= 3) args[2] else null;

    // Dispatch on keyword
    if (env.eq(env, keyword, env.internStr(":cursor-x"))) {
        box.options.cursor_x = if (new_value) |v| if (env.is_not_nil(env, v)) @intCast(env.extractInt(v)) else null else null;
    } else if (env.eq(env, keyword, env.internStr(":cursor-line"))) {
        box.options.cursor_line = if (new_value) |v| if (env.is_not_nil(env, v)) @intCast(env.extractInt(v)) else null else null;
    } else if (env.eq(env, keyword, env.internStr(":prev-cursor-x"))) {
        box.options.prev_cursor_x = if (new_value) |v| if (env.is_not_nil(env, v)) @intCast(env.extractInt(v)) else null else null;
    } else if (env.eq(env, keyword, env.internStr(":prev-cursor-line"))) {
        box.options.prev_cursor_line = if (new_value) |v| if (env.is_not_nil(env, v)) @intCast(env.extractInt(v)) else null else null;
    } else if (env.eq(env, keyword, env.internStr(":selection-start-line"))) {
        box.options.selection_start_line = if (new_value) |v| if (env.is_not_nil(env, v)) @intCast(env.extractInt(v)) else null else null;
    } else if (env.eq(env, keyword, env.internStr(":partial-result"))) {
        box.options.partial_result = if (new_value) |v| env.is_not_nil(env, v) else false;
    } else if (env.eq(env, keyword, env.internStr(":force-balance"))) {
        box.options.force_balance = if (new_value) |v| env.is_not_nil(env, v) else false;
    } else if (env.eq(env, keyword, env.internStr(":return-parens"))) {
        box.options.return_parens = if (new_value) |v| env.is_not_nil(env, v) else false;
    } else {
        // Silently ignore unknown keywords (e.g. language-specific options
        // like :comment-char, :string-delimiters, :lisp-vline-symbols that
        // parinfer-rust-mode sends but we don't need for Clojure-only).
    }

    return env.nil();
}

/// (parinfer-rust-get-option opts keyword)
fn getOption(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const box = getUserPtr(OptionsBox, env, args[0]) orelse return signalError(env, "invalid options");
    const keyword = args[1];

    if (env.eq(env, keyword, env.internStr(":cursor-x"))) {
        return if (box.options.cursor_x) |v| env.makeInt(v) else env.nil();
    } else if (env.eq(env, keyword, env.internStr(":cursor-line"))) {
        return if (box.options.cursor_line) |v| env.makeInt(v) else env.nil();
    } else if (env.eq(env, keyword, env.internStr(":prev-cursor-x"))) {
        return if (box.options.prev_cursor_x) |v| env.makeInt(v) else env.nil();
    } else if (env.eq(env, keyword, env.internStr(":prev-cursor-line"))) {
        return if (box.options.prev_cursor_line) |v| env.makeInt(v) else env.nil();
    } else if (env.eq(env, keyword, env.internStr(":selection-start-line"))) {
        return if (box.options.selection_start_line) |v| env.makeInt(v) else env.nil();
    } else if (env.eq(env, keyword, env.internStr(":partial-result"))) {
        return env.boolToValue(box.options.partial_result);
    } else if (env.eq(env, keyword, env.internStr(":force-balance"))) {
        return env.boolToValue(box.options.force_balance);
    } else if (env.eq(env, keyword, env.internStr(":return-parens"))) {
        return env.boolToValue(box.options.return_parens);
    }

    // Unknown keyword — return nil for language-specific options we don't support
    return env.nil();
}

/// (parinfer-rust-print-options opts) → string
fn printOptions(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const box = getUserPtr(OptionsBox, env, args[0]) orelse return signalError(env, "invalid options");
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "Options{{ cursor_x={?d}, cursor_line={?d}, partial_result={}, force_balance={}, return_parens={} }}", .{
        box.options.cursor_x,
        box.options.cursor_line,
        box.options.partial_result,
        box.options.force_balance,
        box.options.return_parens,
    }) catch "Options{...}";
    return env.makeStr(s);
}

/// (parinfer-rust-make-changes) → user_ptr(ChangeList)
fn makeChanges(env: *Env, _: isize, _: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const box = allocator.create(ChangeListBox) catch return signalError(env, "out of memory");
    box.* = ChangeListBox{ .changes = std.array_list.Managed(types.Change).init(allocator) };
    return env.makeUserPtr(changeListFinalizer, box);
}

/// (parinfer-rust-new-change line x old_text new_text) → user_ptr(Change)
fn newChange(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const line_no: usize = @intCast(@max(0, env.extractInt(args[0])));
    const x: usize = @intCast(@max(0, env.extractInt(args[1])));

    const old_text = env.extractString(allocator, args[2]) catch return signalError(env, "failed to extract old_text");
    const new_text = env.extractString(allocator, args[3]) catch {
        allocator.free(old_text);
        return signalError(env, "failed to extract new_text");
    };

    const box = allocator.create(ChangeBox) catch {
        allocator.free(old_text);
        allocator.free(new_text);
        return signalError(env, "out of memory");
    };
    box.* = ChangeBox{
        .change = .{
            .x = x,
            .line_no = line_no,
            .old_text = old_text,
            .new_text = new_text,
        },
        .old_text_owned = old_text,
        .new_text_owned = new_text,
    };
    return env.makeUserPtr(changeFinalizer, box);
}

/// (parinfer-rust-add-change changes change)
fn addChange(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const list_box = getUserPtr(ChangeListBox, env, args[0]) orelse return signalError(env, "invalid change list");
    const change_box = getUserPtr(ChangeBox, env, args[1]) orelse return signalError(env, "invalid change");
    list_box.changes.append(change_box.change) catch return signalError(env, "out of memory");
    return env.nil();
}

/// (parinfer-rust-print-changes changes) → string
fn printChanges(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const box = getUserPtr(ChangeListBox, env, args[0]) orelse return signalError(env, "invalid change list");
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "Changes({d} items)", .{box.changes.items.len}) catch "Changes{...}";
    return env.makeStr(s);
}

/// (parinfer-rust-make-request mode text opts) → user_ptr(Request)
fn makeRequest(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const mode_str = env.extractString(allocator, args[0]) catch return signalError(env, "failed to extract mode");
    const text = env.extractString(allocator, args[1]) catch {
        allocator.free(mode_str);
        return signalError(env, "failed to extract text");
    };

    const opts_box = getUserPtr(OptionsBox, env, args[2]) orelse {
        allocator.free(mode_str);
        allocator.free(text);
        return signalError(env, "invalid options");
    };

    const mode = types.Mode.fromString(mode_str) orelse {
        allocator.free(mode_str);
        allocator.free(text);
        return signalError(env, "invalid mode: expected 'indent', 'paren', or 'smart'");
    };

    const box = allocator.create(RequestBox) catch {
        allocator.free(mode_str);
        allocator.free(text);
        return signalError(env, "out of memory");
    };
    box.* = RequestBox{
        .request = .{
            .mode = mode,
            .text = text,
            .options = opts_box.options,
        },
        .text_owned = text,
        .mode_str = mode_str,
    };
    return env.makeUserPtr(requestFinalizer, box);
}

/// (parinfer-rust-print-request request) → string
fn printRequest(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const box = getUserPtr(RequestBox, env, args[0]) orelse return signalError(env, "invalid request");
    var buf: [512]u8 = undefined;
    const mode_name: []const u8 = switch (box.request.mode) {
        .indent => "indent",
        .paren => "paren",
        .smart => "smart",
    };
    const s = std.fmt.bufPrint(&buf, "Request{{ mode={s}, text_len={d} }}", .{ mode_name, box.request.text.len }) catch "Request{...}";
    return env.makeStr(s);
}

/// (parinfer-rust-execute request) → user_ptr(Answer)
fn execute(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const req_box = getUserPtr(RequestBox, env, args[0]) orelse return signalError(env, "invalid request");

    const answer = parinfer.process(allocator, &req_box.request) catch {
        return signalError(env, "parinfer processing failed");
    };

    const box = allocator.create(AnswerBox) catch {
        var ans_copy = answer;
        parinfer.freeAnswer(allocator, &ans_copy);
        return signalError(env, "out of memory");
    };
    box.* = AnswerBox{
        .answer = answer,
        .text_owned = true,
    };
    return env.makeUserPtr(answerFinalizer, box);
}

/// (parinfer-rust-get-answer answer keyword) → value
fn getAnswer(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const box = getUserPtr(AnswerBox, env, args[0]) orelse return signalError(env, "invalid answer");
    const keyword = args[1];
    const answer = &box.answer;

    if (env.eq(env, keyword, env.internStr(":text"))) {
        return env.makeStr(answer.text);
    } else if (env.eq(env, keyword, env.internStr(":success"))) {
        return env.boolToValue(answer.success);
    } else if (env.eq(env, keyword, env.internStr(":error"))) {
        if (answer.err) |err| {
            const items = [_]Value{
                env.internStr(":name"),
                env.makeStr(err.name.toString()),
                env.internStr(":message"),
                env.makeStr(err.msg),
                env.internStr(":line_no"),
                env.makeInt(err.line_no),
                env.internStr(":x"),
                env.makeInt(err.x),
            };
            return env.list(&items);
        }
        return env.nil();
    } else if (env.eq(env, keyword, env.internStr(":cursor-x"))) {
        if (answer.cursor_x) |cx| return env.makeInt(cx);
        return env.nil();
    } else if (env.eq(env, keyword, env.internStr(":cursor-line"))) {
        if (answer.cursor_line) |cl| return env.makeInt(cl);
        return env.nil();
    } else if (env.eq(env, keyword, env.internStr(":tab-stops"))) {
        // Build list of tab stop plists
        var tab_list = std.array_list.Managed(Value).init(allocator);
        defer tab_list.deinit();
        for (answer.tab_stops) |ts| {
            const items = [_]Value{
                env.internStr(":x"),
                env.makeInt(ts.x),
                env.internStr(":arg-x"),
                if (ts.arg_x) |ax| env.makeInt(ax) else env.nil(),
                env.internStr(":line-no"),
                env.makeInt(ts.line_no),
                env.internStr(":ch"),
                env.makeStr(&[_]u8{ts.ch}),
            };
            tab_list.append(env.list(&items)) catch return env.nil();
        }
        return env.list(tab_list.items);
    } else if (env.eq(env, keyword, env.internStr(":paren-trails"))) {
        var trail_list = std.array_list.Managed(Value).init(allocator);
        defer trail_list.deinit();
        for (answer.paren_trails) |pt| {
            const items = [_]Value{
                env.internStr(":line-no"),
                env.makeInt(pt.line_no),
                env.internStr(":start-x"),
                env.makeInt(pt.start_x),
                env.internStr(":end-x"),
                env.makeInt(pt.end_x),
            };
            trail_list.append(env.list(&items)) catch return env.nil();
        }
        return env.list(trail_list.items);
    } else if (env.eq(env, keyword, env.internStr(":parens"))) {
        var paren_list = std.array_list.Managed(Value).init(allocator);
        defer paren_list.deinit();
        for (answer.parens) |p| {
            const items = [_]Value{
                env.internStr(":line-no"),
                env.makeInt(p.line_no),
                env.internStr(":x"),
                env.makeInt(p.x),
            };
            paren_list.append(env.list(&items)) catch return env.nil();
        }
        return env.list(paren_list.items);
    }

    return signalError(env, "unknown answer keyword");
}

/// (parinfer-rust-print-answer answer) → string
fn printAnswer(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const box = getUserPtr(AnswerBox, env, args[0]) orelse return signalError(env, "invalid answer");
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "Answer{{ success={}, text_len={d}, cursor_x={?d}, cursor_line={?d} }}", .{
        box.answer.success,
        box.answer.text.len,
        box.answer.cursor_x,
        box.answer.cursor_line,
    }) catch "Answer{...}";
    return env.makeStr(s);
}

/// (parinfer-rust-debug filename opts answer)
fn debug(env: *Env, _: isize, args: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    const filename = env.extractString(allocator, args[0]) catch return signalError(env, "failed to extract filename");
    defer allocator.free(filename);
    const opts_box = getUserPtr(OptionsBox, env, args[1]);
    const answer_box = getUserPtr(AnswerBox, env, args[2]);

    const file = std.fs.cwd().createFile(filename, .{ .truncate = false }) catch {
        env.message("Unable to open debug file");
        return env.nil();
    };
    defer file.close();

    // Seek to end for append behavior
    file.seekFromEnd(0) catch {};

    var buf: [4096]u8 = undefined;
    if (opts_box) |ob| {
        const s = std.fmt.bufPrint(&buf, "Options:\ncursor_x={?d}, cursor_line={?d}, partial_result={}, force_balance={}\n", .{
            ob.options.cursor_x,
            ob.options.cursor_line,
            ob.options.partial_result,
            ob.options.force_balance,
        }) catch "";
        _ = file.write(s) catch {};
    }
    if (answer_box) |ab| {
        const s = std.fmt.bufPrint(&buf, "Answer:\nsuccess={}, text_len={d}, cursor_x={?d}, cursor_line={?d}\n", .{
            ab.answer.success,
            ab.answer.text.len,
            ab.answer.cursor_x,
            ab.answer.cursor_line,
        }) catch "";
        _ = file.write(s) catch {};
    }

    env.message("Wrote debug information");
    return env.nil();
}

/// (parinfer-rust-version) → string
fn version(env: *Env, _: isize, _: [*]Value, _: ?*anyopaque) callconv(.c) Value {
    return env.makeStr(VERSION);
}

// ============================================================
// Module initialization
// ============================================================

pub fn init(env: *Env) void {
    env.defun("parinfer-rust-make-option", 0, 0, makeOption, "Create default options");
    env.defun("parinfer-rust-new-options", 5, 5, newOptions, "Create options from cursor state");
    env.defun("parinfer-rust-set-option", 2, 3, setOption, "Set an option field");
    env.defun("parinfer-rust-get-option", 2, 2, getOption, "Get an option field");
    env.defun("parinfer-rust-print-options", 1, 1, printOptions, "Print options as string");
    env.defun("parinfer-rust-make-changes", 0, 0, makeChanges, "Create empty change list");
    env.defun("parinfer-rust-new-change", 4, 4, newChange, "Create a change");
    env.defun("parinfer-rust-add-change", 2, 2, addChange, "Add change to list");
    env.defun("parinfer-rust-print-changes", 1, 1, printChanges, "Print changes as string");
    env.defun("parinfer-rust-make-request", 3, 3, makeRequest, "Create a request");
    env.defun("parinfer-rust-print-request", 1, 1, printRequest, "Print request as string");
    env.defun("parinfer-rust-execute", 1, 1, execute, "Execute parinfer on request");
    env.defun("parinfer-rust-get-answer", 2, 2, getAnswer, "Get field from answer");
    env.defun("parinfer-rust-print-answer", 1, 1, printAnswer, "Print answer as string");
    env.defun("parinfer-rust-debug", 3, 3, debug, "Write debug info to file");
    env.defun("parinfer-rust-version", 0, 0, version, "Get library version");

    // Provide the feature
    _ = env.call1(env.internStr("provide"), env.internStr("parinfer-rust"));
}

/// Zig bindings for the Emacs dynamic module API (emacs-module.h).
/// Covers Emacs 25+ ABI. Fields are in exact ABI order.
const std = @import("std");

pub const Value = ?*anyopaque;
pub const ModuleFn = *const fn (*Env, isize, [*]Value, ?*anyopaque) callconv(.c) Value;
pub const Finalizer = ?*const fn (?*anyopaque) callconv(.c) void;

pub const FuncallExit = enum(c_int) {
    @"return" = 0,
    signal = 1,
    throw = 2,
};

pub const Runtime = extern struct {
    size: isize,
    private_members: ?*anyopaque,
    get_environment: *const fn (*Runtime) callconv(.c) *Env,
};

/// Emacs environment struct. Function pointers in Emacs 25 ABI order.
pub const Env = extern struct {
    size: isize,
    private_members: ?*anyopaque,

    // Emacs 25 function pointers
    make_global_ref: *const fn (*Env, Value) callconv(.c) Value,
    free_global_ref: *const fn (*Env, Value) callconv(.c) void,
    non_local_exit_check: *const fn (*Env) callconv(.c) FuncallExit,
    non_local_exit_clear: *const fn (*Env) callconv(.c) void,
    non_local_exit_get: *const fn (*Env, *Value, *Value) callconv(.c) FuncallExit,
    non_local_exit_signal: *const fn (*Env, Value, Value) callconv(.c) void,
    non_local_exit_throw: *const fn (*Env, Value, Value) callconv(.c) void,
    make_function: *const fn (*Env, isize, isize, ModuleFn, ?[*:0]const u8, ?*anyopaque) callconv(.c) Value,
    funcall: *const fn (*Env, Value, isize, ?[*]Value) callconv(.c) Value,
    intern: *const fn (*Env, [*:0]const u8) callconv(.c) Value,
    type_of: *const fn (*Env, Value) callconv(.c) Value,
    is_not_nil: *const fn (*Env, Value) callconv(.c) bool,
    eq: *const fn (*Env, Value, Value) callconv(.c) bool,
    extract_integer: *const fn (*Env, Value) callconv(.c) i64,
    make_integer: *const fn (*Env, i64) callconv(.c) Value,
    extract_float: *const fn (*Env, Value) callconv(.c) f64,
    make_float: *const fn (*Env, f64) callconv(.c) Value,
    copy_string_contents: *const fn (*Env, Value, ?[*]u8, *isize) callconv(.c) bool,
    make_string: *const fn (*Env, [*]const u8, isize) callconv(.c) Value,
    make_user_ptr: *const fn (*Env, Finalizer, ?*anyopaque) callconv(.c) Value,
    get_user_ptr: *const fn (*Env, Value) callconv(.c) ?*anyopaque,
    set_user_ptr: *const fn (*Env, Value, ?*anyopaque) callconv(.c) void,
    set_user_finalizer: *const fn (*Env, Value, Finalizer) callconv(.c) void,
    vec_get: *const fn (*Env, Value, isize) callconv(.c) Value,
    vec_set: *const fn (*Env, Value, isize, Value) callconv(.c) void,
    vec_size: *const fn (*Env, Value) callconv(.c) isize,

    // --- Helper methods ---

    pub fn nil(self: *Env) Value {
        return self.intern(self, "nil");
    }

    pub fn t(self: *Env) Value {
        return self.intern(self, "t");
    }

    pub fn isNil(self: *Env, val: Value) bool {
        return !self.is_not_nil(self, val);
    }

    pub fn makeStr(self: *Env, s: []const u8) Value {
        return self.make_string(self, s.ptr, @intCast(s.len));
    }

    pub fn makeInt(self: *Env, n: anytype) Value {
        return self.make_integer(self, @intCast(n));
    }

    pub fn extractInt(self: *Env, val: Value) i64 {
        return self.extract_integer(self, val);
    }

    pub fn internStr(self: *Env, name: [*:0]const u8) Value {
        return self.intern(self, name);
    }

    pub fn call(self: *Env, func: Value, args: []Value) Value {
        return self.funcall(self, func, @intCast(args.len), if (args.len > 0) args.ptr else null);
    }

    pub fn call0(self: *Env, func: Value) Value {
        return self.funcall(self, func, 0, null);
    }

    pub fn call1(self: *Env, func: Value, arg: Value) Value {
        var args = [_]Value{arg};
        return self.funcall(self, func, 1, &args);
    }

    pub fn call2(self: *Env, func: Value, a1: Value, a2: Value) Value {
        var args = [_]Value{ a1, a2 };
        return self.funcall(self, func, 2, &args);
    }

    pub fn makeUserPtr(self: *Env, finalizer: Finalizer, ptr: ?*anyopaque) Value {
        return self.make_user_ptr(self, finalizer, ptr);
    }

    pub fn getUserPtr(self: *Env, val: Value) ?*anyopaque {
        return self.get_user_ptr(self, val);
    }

    /// Extract a string from an Emacs value. Caller owns the returned slice.
    pub fn extractString(self: *Env, allocator: std.mem.Allocator, val: Value) ![]u8 {
        var len: isize = 0;
        // First call: get required buffer size (includes null terminator)
        _ = self.copy_string_contents(self, val, null, &len);
        if (self.non_local_exit_check(self) != .@"return") {
            self.non_local_exit_clear(self);
            return error.EmacsError;
        }
        if (len <= 0) return allocator.alloc(u8, 0);

        const buf = try allocator.alloc(u8, @intCast(len));
        _ = self.copy_string_contents(self, val, buf.ptr, &len);
        if (self.non_local_exit_check(self) != .@"return") {
            self.non_local_exit_clear(self);
            allocator.free(buf);
            return error.EmacsError;
        }
        // len includes null terminator, return without it
        return buf[0..@as(usize, @intCast(len)) -| 1];
    }

    pub fn defun(self: *Env, name: [*:0]const u8, min: isize, max: isize, func: ModuleFn, doc: ?[*:0]const u8) void {
        const sym = self.internStr(name);
        const fun = self.make_function(self, min, max, func, doc, null);
        _ = self.call2(self.internStr("defalias"), sym, fun);
    }

    pub fn boolToValue(self: *Env, b: bool) Value {
        return if (b) self.t() else self.nil();
    }

    pub fn message(self: *Env, msg: []const u8) void {
        var args = [_]Value{self.makeStr(msg)};
        _ = self.funcall(self, self.internStr("message"), 1, &args);
    }

    /// Build an Elisp list from a slice of values.
    pub fn list(self: *Env, items: []const Value) Value {
        const list_fn = self.internStr("list");
        // We need to cast away const for the C API
        if (items.len == 0) return self.nil();
        return self.funcall(self, list_fn, @intCast(items.len), @constCast(@ptrCast(items.ptr)));
    }
};

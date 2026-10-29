const std = @import("std");
const Io = std.Io;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const value = @import("value.zig");
const Value = value.Value;

const Diagnostic = @import("diag.zig").Diagnostic;

pub const Error = value.Error;

pub const Kwarg = struct {
    name: []const u8,
    value: Value,
};

pub const Args = struct {
    pos: []const Value = &.{},
    kw: []const Kwarg = &.{},

    /// The `i`-th positional argument, or the keyword of that name.
    pub fn get(self: Args, i: usize, name: []const u8) ?Value {
        if (i < self.pos.len) return self.pos[i];
        for (self.kw) |k| if (std.mem.eql(u8, k.name, name)) return k.value;
        return null;
    }

    pub fn byName(self: Args, name: []const u8) ?Value {
        for (self.kw) |k| if (std.mem.eql(u8, k.name, name)) return k.value;
        return null;
    }
};

pub const Ctx = struct {
    arena: Allocator,
    io: Io,
    autoescape: bool,
    strict: bool,
    diag: *Diagnostic,
    user: *const anyopaque,
    callFilter: *const fn (ctx: *Ctx, name: []const u8, input: Value, args: Args) Error!Value,
    callTest: *const fn (ctx: *Ctx, name: []const u8, input: Value, args: Args) Error!bool,

    /// `str(v)`, refusing undefined when the policy is strict. This is the one
    /// place the undefined policy reaches the filter library.
    pub fn toStr(self: *Ctx, v: Value) Error![]const u8 {
        if (v == .undef and self.strict) return error.UndefinedValue;
        return value.strAlloc(self.arena, v);
    }
};

pub const FilterFn = *const fn (ctx: *Ctx, input: Value, args: Args) Error!Value;
pub const TestFn = *const fn (ctx: *Ctx, input: Value, args: Args) Error!bool;
pub const GlobalFn = *const fn (ctx: *Ctx, args: Args) Error!Value;
pub const MethodFn = *const fn (ctx: *Ctx, input: Value, args: Args) Error!Value;

/// A float in a position that needs an integer. The reference refuses one
/// outright here (`range(1e300)` → `TypeError`); this module is deliberately
/// more permissive and truncates, but a magnitude `i64` cannot hold is a named
/// error rather than a `@intFromFloat` that traps in ReleaseSafe and produces a
/// junk integer in ReleaseFast.
pub fn intFromFloatChecked(f: f64) Error!i64 {
    if (!std.math.isFinite(f)) return error.BadArgument;
    const t = @trunc(f);
    // Both bounds are exactly representable: -2^63 and +2^63.
    if (t < -9223372036854775808.0 or t >= 9223372036854775808.0) return error.OutOfRange;
    return @intFromFloat(t);
}

pub fn intArg(v: Value, dflt: i64) Error!i64 {
    return switch (v) {
        .integer => |i| i,
        .boolean => |b| @intFromBool(b),
        .float => |f| intFromFloatChecked(f),
        .undef => error.UndefinedValue,
        .none => dflt,
        else => error.BadArgument,
    };
}

pub fn boolArg(args: Args, i: usize, name: []const u8, dflt: bool) bool {
    const v = args.get(i, name) orelse return dflt;
    return v.truthy();
}

pub fn strArg(ctx: *Ctx, args: Args, i: usize, name: []const u8, dflt: []const u8) Error![]const u8 {
    const v = args.get(i, name) orelse return dflt;
    return ctx.toStr(v);
}

/// The markup bit of a filter whose result is built **only out of the input's
/// own bytes** — a case fold, a trim, a reversal, a prefix removal. markupsafe
/// does exactly this (`Markup.upper()`, `Markup.strip()`, `Markup.removeprefix()`
/// all return `Markup` without escaping anything).
pub fn markupAware(ctx: *Ctx, input: Value, bytes: []const u8) Value {
    const safe = ctx.autoescape and input == .string and input.string.safe;
    return .{ .string = .{ .bytes = bytes, .safe = safe } };
}

pub fn isMarkup(v: Value) bool {
    return v == .string and v.string.safe;
}

/// The elements a sequence filter works on.
pub fn seq(ctx: *Ctx, v: Value) Error![]const Value {
    // Matches the reference: its default `Undefined` is an empty iterable, so
    // `missing|list` is `[]`; `StrictUndefined` refuses.
    if (v == .undef) return if (ctx.strict) error.UndefinedValue else &.{};
    return value.iterate(ctx.arena, v);
}

/// `attribute=` support, shared by sort/min/max/sum/unique/map/groupby-likes.
/// A dotted path (`a.b`) and an integer index both work, as in the reference.
pub fn attrOf(ctx: *Ctx, item: Value, spec: Value) Error!Value {
    switch (spec) {
        .integer => |i| {
            const items = value.iterate(ctx.arena, item) catch return .{ .undef = .{ .name = "index" } };
            if (i < 0 or i >= items.len) return .{ .undef = .{ .name = "index" } };
            return items[@intCast(i)];
        },
        .string => |s| {
            var cur = item;
            var it = std.mem.splitScalar(u8, s.bytes, '.');
            while (it.next()) |part| {
                if (std.fmt.parseInt(i64, part, 10) catch null) |idx| {
                    const items = value.iterate(ctx.arena, cur) catch return .{ .undef = .{ .name = part } };
                    if (idx < 0 or idx >= items.len) return .{ .undef = .{ .name = part } };
                    cur = items[@intCast(idx)];
                    continue;
                }
                cur = switch (cur) {
                    .map => |m| m.get(part) orelse return .{ .undef = .{ .name = part } },
                    .namespace => |ns| ns.get(part) orelse return .{ .undef = .{ .name = part } },
                    else => return .{ .undef = .{ .name = part } },
                };
            }
            return cur;
        },
        else => return error.BadArgument,
    }
}

pub fn isTitleBoundary(c: u8) bool {
    return switch (c) {
        '-', ' ', '\t', '\r', '\n', 0x0b, 0x0c, '(', '{', '[', '<' => true,
        else => false,
    };
}

/// `do_xmlattr`'s `re.compile(r"[\s/>=]", re.ASCII)`: ASCII whitespace, `/`,
/// `>` and `=` cannot appear in an attribute name.
pub fn invalidAttrKey(key: []const u8) bool {
    for (key) |c| switch (c) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, '/', '>', '=' => return true,
        else => {},
    };
    return false;
}

pub fn pairsToList(ctx: *Ctx, pairs: []const value.Pair) Error!Value {
    const out = try ctx.arena.alloc(Value, pairs.len);
    for (pairs, 0..) |p, i| {
        const two = try ctx.arena.alloc(Value, 2);
        two[0] = p.key;
        two[1] = p.value;
        out[i] = .{ .tuple = two };
    }
    return .{ .list = out };
}

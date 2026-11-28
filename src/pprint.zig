const std = @import("std");
const Allocator = std.mem.Allocator;

const value = @import("value.zig");

const Value = value.Value;
const Error = value.Error;

const width: usize = 80;

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0d) or (c >= 0x1c and c <= 0x1f);
}

fn cpLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c & 0xc0 != 0x80) n += 1;
    }
    return n;
}

fn reprBytes(arena: Allocator, v: Value) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try value.reprTo(&aw.writer, v);
    return aw.written();
}

fn typeName(v: Value) []const u8 {
    return switch (v) {
        .boolean => "bool",
        .float => "float",
        .integer => "int",
        .none => "NoneType",
        .string => "str",
        .tuple => "tuple",
        .list => "list",
        .map => "dict",
        else => "object",
    };
}

fn numOf(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .boolean => |b| if (b) 1.0 else 0.0,
        else => null,
    };
}

fn keyLess(a: Value, b: Value) bool {
    if (a == .string and b == .string) return std.mem.lessThan(u8, a.string.bytes, b.string.bytes);
    if (numOf(a)) |x| if (numOf(b)) |y| return x < y;
    if (a == .tuple and b == .tuple) {
        for (a.tuple, 0..) |e, i| {
            if (i >= b.tuple.len) return false;
            if (keyLess(e, b.tuple[i])) return true;
            if (keyLess(b.tuple[i], e)) return false;
        }
        return a.tuple.len < b.tuple.len;
    }
    return std.mem.lessThan(u8, typeName(a), typeName(b));
}

fn sortedPairs(arena: Allocator, pairs: []const value.Pair) Error![]value.Pair {
    const out = try arena.dupe(value.Pair, pairs);
    std.mem.sort(value.Pair, out, {}, struct {
        fn f(_: void, a: value.Pair, b: value.Pair) bool {
            return keyLess(a.key, b.key);
        }
    }.f);
    return out;
}

fn srepr(arena: Allocator, v: Value, depth: usize) Error![]const u8 {
    if (depth > 64) return error.OutOfRange;
    switch (v) {
        .list, .tuple => |items| {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, if (v == .list) "[" else "(");
            for (items, 0..) |e, i| {
                if (i != 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, try srepr(arena, e, depth + 1));
            }
            if (v == .tuple and items.len == 1) try out.append(arena, ',');
            try out.appendSlice(arena, if (v == .list) "]" else ")");
            return out.items;
        },
        .map => |m| {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, "{");
            for (try sortedPairs(arena, m.pairs), 0..) |p, i| {
                if (i != 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, try srepr(arena, p.key, depth + 1));
                try out.appendSlice(arena, ": ");
                try out.appendSlice(arena, try srepr(arena, p.value, depth + 1));
            }
            try out.appendSlice(arena, "}");
            return out.items;
        },
        else => return reprBytes(arena, v),
    }
}

const Print = struct {
    arena: Allocator,
    out: std.ArrayList(u8) = .empty,

    fn format(self: *Print, v: Value, indent: usize, allowance: usize, level: usize) Error!void {
        const rep = try srepr(self.arena, v, 0);
        const max_width: i64 = @as(i64, @intCast(width)) - @as(i64, @intCast(indent)) - @as(i64, @intCast(allowance));
        if (@as(i64, @intCast(cpLen(rep))) > max_width) {
            switch (v) {
                .map => |m| return self.dict(m.pairs, indent, allowance, level + 1),
                .list => |xs| {
                    try self.writeBytes("[");
                    try self.items(xs, indent, allowance + 1, level + 1);
                    return self.writeBytes("]");
                },
                .tuple => |xs| {
                    try self.writeBytes("(");
                    const end: []const u8 = if (xs.len == 1) ",)" else ")";
                    try self.items(xs, indent, allowance + end.len, level + 1);
                    return self.writeBytes(end);
                },
                .string => |s| return self.str(s.bytes, indent, allowance, level + 1),
                else => {},
            }
        }
        try self.writeBytes(rep);
    }

    fn items(self: *Print, xs: []const Value, indent_in: usize, allowance: usize, level: usize) Error!void {
        const indent = indent_in + 1;
        for (xs, 0..) |e, i| {
            if (i != 0) {
                try self.writeBytes(",\n");
                try self.spaces(indent);
            }
            const last = i + 1 == xs.len;
            try self.format(e, indent, if (last) allowance else 1, level);
        }
    }

    fn dict(self: *Print, pairs: []const value.Pair, indent_in: usize, allowance: usize, level: usize) Error!void {
        try self.writeBytes("{\n");
        if (pairs.len != 0) {
            const sorted = try sortedPairs(self.arena, pairs);
            const indent = indent_in + 1;
            for (sorted, 0..) |p, i| {
                const last = i + 1 == sorted.len;

                try self.spaces(indent);
                const rep = try srepr(self.arena, p.key, 0);
                try self.writeBytes(rep);
                try self.writeBytes(": ");
                try self.format(p.value, indent + cpLen(rep) + 2, if (last) allowance + 1 else 1, level);
                if (!last) {
                    try self.writeBytes(",\n");
                }
            }
        }
        try self.writeBytes("\n}");
    }

    fn str(self: *Print, s: []const u8, indent_in: usize, allowance_in: usize, level: usize) Error!void {
        if (s.len == 0) return self.writeBytes(try reprBytes(self.arena, Value.fromString(s)));
        var indent = indent_in;
        var allowance = allowance_in;
        if (level == 1) {
            indent += 1;
            allowance += 1;
        }

        const max_width: i64 = @as(i64, @intCast(width)) - @as(i64, @intCast(indent));
        var max_width1 = max_width;
        var chunks: std.ArrayList([]const u8) = .empty;

        var lines: std.ArrayList([]const u8) = .empty;
        var st: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            var brk: usize = 0;
            if (c == '\r' and i + 1 < s.len and s[i + 1] == '\n') brk = 2 else if (c == '\n' or c == '\r' or c == 0x0b or c == 0x0c or (c >= 0x1c and c <= 0x1e)) brk = 1;
            if (brk != 0) {
                try lines.append(self.arena, s[st .. i + brk]);
                i += brk;
                st = i;
            } else i += 1;
        }

        if (st < s.len) try lines.append(self.arena, s[st..]);
        var last_rep: []const u8 = "";
        for (lines.items, 0..) |line, li| {
            const rep = try reprBytes(self.arena, Value.fromString(line));
            last_rep = rep;
            const is_last_line = li + 1 == lines.items.len;
            if (is_last_line) max_width1 -= @intCast(allowance);
            if (@as(i64, @intCast(cpLen(rep))) <= max_width1) {
                try chunks.append(self.arena, rep);
                continue;
            }

            var parts: std.ArrayList([]const u8) = .empty;
            var p: usize = 0;
            while (p < line.len) {
                var q = p;
                while (q < line.len and !isSpace(line[q])) q += 1;
                while (q < line.len and isSpace(line[q])) q += 1;
                try parts.append(self.arena, line[p..q]);
                p = q;
            }

            var max_width2 = max_width;
            var current: []const u8 = "";
            for (parts.items, 0..) |part, j| {
                const cand = try std.mem.concat(self.arena, u8, &.{ current, part });
                if (j + 1 == parts.items.len and is_last_line) max_width2 -= @intCast(allowance);
                if (@as(i64, @intCast(cpLen(try reprBytes(self.arena, Value.fromString(cand))))) > max_width2) {
                    if (current.len != 0) try chunks.append(self.arena, try reprBytes(self.arena, Value.fromString(current)));
                    current = part;
                } else current = cand;
            }
            if (current.len != 0) try chunks.append(self.arena, try reprBytes(self.arena, Value.fromString(current)));
        }

        if (chunks.items.len == 1) return self.writeBytes(last_rep);
        if (level == 1) try self.writeBytes("(");
        for (chunks.items, 0..) |c, ci| {
            if (ci > 0) {
                try self.writeBytes("\n");
                try self.spaces(indent);
            }
            try self.writeBytes(c);
        }
        if (level == 1) try self.writeBytes(")");
    }

    fn writeBytes(self: *Print, s: []const u8) Error!void {
        try self.out.appendSlice(self.arena, s);
    }

    fn spaces(self: *Print, n: usize) Error!void {
        try self.out.appendNTimes(self.arena, ' ', n);
    }
};

pub fn pformat(arena: Allocator, v: Value, indent: usize) Error![]const u8 {
    var p: Print = .{ .arena = arena };
    try p.format(v, indent, 0, 0);
    return p.out.items;
}

const std = @import("std");

const value = @import("value.zig");
const filters = @import("filters.zig");

pub const GlobalEntry = struct { name: []const u8, func: filters.GlobalFn };

const Cycler = struct {
    items: []const value.Value,
    pos: usize = 0,

    pub fn callFn(ctx: *anyopaque, fctx: *filters.Ctx, method: []const u8, args: filters.Args) filters.Error!value.Value {
        _ = fctx;
        _ = args;

        var self: *Cycler = @ptrCast(@alignCast(ctx));

        if (std.mem.eql(u8, method, "reset")) {
            self.pos = 0;
            return .empty_string;
        }

        if (std.mem.eql(u8, method, "current")) {
            return self.items[self.pos];
        }

        if (std.mem.eql(u8, method, "next")) {
            const rv = self.items[self.pos];
            self.pos = (self.pos + 1) % self.items.len;
            return rv;
        }

        return error.InvalidMethod;
    }
};

fn gCycler(ctx: *filters.Ctx, args: filters.Args) filters.Error!value.Value {
    if (args.pos.len == 0) {
        return error.BadArgument;
    }

    const cycler_ptr = try ctx.arena.create(Cycler);
    cycler_ptr.* = .{
        .items = args.pos,
        .pos = 0,
    };

    return .fromCallable(.{
        .ctx = cycler_ptr,
        .call = Cycler.callFn,
    });
}

const Joiner = struct {
    sep: value.Value,
    used: bool = false,

    pub fn callFn(ctx: *anyopaque, fctx: *filters.Ctx, args: filters.Args) filters.Error!value.Value {
        _ = fctx;
        _ = args;

        var self: *Joiner = @ptrCast(@alignCast(ctx));

        if (!self.used) {
            self.used = true;
            return .empty_string;
        }

        return self.sep;
    }
};

fn gJoiner(ctx: *filters.Ctx, args: filters.Args) filters.Error!value.Value {
    const sep = args.get(0, "sep") orelse return error.BadArgument;

    const joiner_ptr = try ctx.arena.create(Joiner);
    joiner_ptr.* = .{
        .sep = sep,
    };

    return .fromCaller(.{
        .ctx = joiner_ptr,
        .call = Joiner.callFn,
    });
}

pub const builtin_globals = [_]GlobalEntry{
    .{ .name = "cycler", .func = gCycler },
    .{ .name = "joiner", .func = gJoiner },
};

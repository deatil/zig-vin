const std = @import("std");
const testing = std.testing;

const vin = @import("vin.zig");
const filters = vin.filters;
const value = vin.value;

test "DirLoader use dir" {
    const io = testing.io;
    const alloc = testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const a = arena.allocator();

    const dl: vin.DirLoader = .{ 
        .io = io, 
        .root = try std.Io.Dir.cwd().openDir(io, "src/testdata/views", .{}), 
        .options = .{ 
            .suffix = ".htm",
        },
    };

    var env = try vin.Environment.initWithLoader(a, .{}, dl.loader());
    defer env.deinit();

    {
        const out = try env.renderTemplateAlloc(a, "show", .none, null);
        defer a.free(out);
        try testing.expectEqualStrings("[42]", out);
    }

    {
        const out = try env.renderTemplateAlloc(a, "sub/show1", .none, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222]", out);
    }

    {
        const ctx = try vin.valueFrom(a, .{
            .name = "test name",
        });
        const out = try env.renderTemplateAlloc(a, "sub/show2", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }
}

test "MapLoader renderTemplateAlloc" {
    const alloc = testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const a = arena.allocator();

    var map: vin.MapLoader = .{ .entries = &.{
        .{ .name = "base",   .source = @embedFile("testdata/views/base.htm") },
        .{ .name = "show", .source = @embedFile("testdata/views/show.htm") },
        .{ .name = "sub/show1", .source = @embedFile("testdata/views/sub/show1.htm") },
        .{ .name = "sub/show2", .source = @embedFile("testdata/views/sub/show2.htm") },
    } };

    var env = try vin.Environment.initWithLoader(a, .{}, map.loader());
    defer env.deinit();

    {
        const out = try env.renderTemplateAlloc(a, "show", .none, null);
        defer a.free(out);
        try testing.expectEqualStrings("[42]", out);
    }

    {
        const out = try env.renderTemplateAlloc(a, "sub/show1", .none, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222]", out);
    }

    {
        const ctx = try vin.valueFrom(a, .{
            .name = "test name",
        });
        const out = try env.renderTemplateAlloc(a, "sub/show2", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }
}

test "DirLoader with json" {
    const io = testing.io;
    const alloc = testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const a = arena.allocator();

    const dl: vin.DirLoader = .{ 
        .io = io, 
        .root = try std.Io.Dir.cwd().openDir(io, "src/testdata/views", .{}), 
        .options = .{ 
            .suffix = ".htm",
        },
    };

    var env = try vin.Environment.initWithLoader(a, .{}, dl.loader());
    defer env.deinit();

    {
        const text = 
            \\{"name": "test name"}
        ;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        const ctx = try vin.valueFromJson(a, parsed.value);

        const out = try env.renderTemplateAlloc(a, "sub/show2", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }

    {
        var map: vin.value.Namespace = .{};
        try map.set(a, "name", vin.Value.fromString("test name"));
        const ctx: vin.Value = .fromNamespace(&map);

        const out = try env.renderTemplateAlloc(a, "sub/show2", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }

    {
        var map: *vin.Namespace = try .create(a);
        try map.set(a, "name", .fromString("test name"));
        const ctx: vin.Value = .fromNamespace(map);

        const out = try env.renderTemplateAlloc(a, "sub/show2", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }

    {
        const ctx = try vin.valueFrom(a, .{ .name = "test name", .vlans = [_]u16{ 10, 20 } });

        const out = try env.renderTemplateAlloc(a, "sub/show3", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name10,20,]", out);
    }

    {
        const map: vin.Map = try .create(a, &.{
            try .create(a, "name", .fromString("test name")),
        });
        const ctx: vin.Value = .fromMap(map);

        const out = try env.renderTemplateAlloc(a, "sub/show2", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }
}

test "DirLoader create" {
    const io = testing.io;
    const alloc = testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const a = arena.allocator();

    const dl: *vin.DirLoader = try .create(
        a, io, 
        try std.Io.Dir.cwd().openDir(io, "src/testdata/views", .{}), 
        .{ 
            .suffix = ".htm",
        },
    );

    var env = try vin.Environment.initWithLoader(a, .{}, dl.loader());
    defer env.deinit();

    {
        const ctx = try vin.valueFrom(a, .{ .name = "test name", .vlans = [_]u16{ 10, 20 } });

        const out = try env.renderTemplateAlloc(a, "sub/show3", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name10,20,]", out);
    }

}

test "MapLoader renderTemplateAlloc 2" {
    const alloc = testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const a = arena.allocator();

    var map: *vin.MapLoader = try .create(a, &.{
        .{ .name = "base1",  .source = @embedFile("testdata/views/base1.htm") },
        .{ .name = "sub/show5", .source = @embedFile("testdata/views/sub/show5.htm") },
    });

    var env = try vin.Environment.initWithLoader(a, .{}, map.loader());
    defer env.deinit();

    {
        const ctx = try vin.valueFrom(a, .{
            .name = "test name",
        });
        const out = try env.renderTemplateAlloc(a, "sub/show5", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }
}

test "DirLoader create with Value create" {
    const io = testing.io;
    const alloc = testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const dl: *vin.DirLoader = try .create(
        a, io, 
        try std.Io.Dir.cwd().openDir(io, "src/testdata/views", .{}), 
        .{ 
            .suffix = ".htm",
        },
    );

    var env = try vin.Environment.initWithLoader(a, .{}, dl.loader());
    defer env.deinit();

    {
        const ctx = try vin.valueFrom(a, .{ 
            .name = try vin.Value.create(a, .fromString("test name")), 
            .vlans = [_]u16{ 10, 20 },
        });

        const out = try env.renderTemplateAlloc(a, "sub/show3", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name10,20,]", out);
    }

}

fn greet_fn(ctx: *vin.FilterCtx, args: vin.FilterArgs) filters.Error!value.Value {
    const name_val = args.get(0, "name") orelse return error.BadArgument;
    const s = ctx.toStr(name_val) catch return error.BadArgument;
    const out = try ctx.arena.dupe(u8, s);
    return .{ .string = .{ .bytes = out, .safe = false } };
}

fn greet2_fn(ctx: *vin.FilterCtx, args: vin.FilterArgs) filters.Error!value.Value {
    const name_val = args.get(0, "name") orelse return error.BadArgument;
    const tul_val = args.get(1, "tul") orelse return error.BadArgument;

    const s = ctx.toStr(name_val) catch return error.BadArgument;
    const t = ctx.toStr(tul_val) catch return error.BadArgument;

    const out = try ctx.arena.print("fn2: {s},{s}", .{s, t});
    return .{ .string = .{ .bytes = out, .safe = false } };
}

fn greet3_fn(ctx: *vin.FilterCtx, args: vin.FilterArgs) filters.Error!value.Value {
    const name_val = args.byName("name") orelse return error.BadArgument;
    const tul_val = args.byName("tul") orelse return error.BadArgument;

    const s = ctx.toStr(name_val) catch return error.BadArgument;
    const t = ctx.toStr(tul_val) catch return error.BadArgument;

    const out = try ctx.arena.print("fn2: {s},{s}", .{s, t});
    return .{ .string = .{ .bytes = out, .safe = false } };
}

test "Env addGlobal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    try env.addGlobal("greet", greet_fn);
    try env.addGlobal("greet2", greet2_fn);

    var tpl = try env.compile("\\{{ greet('Alice') }}={{ greet2('Blue', 33) }}", null);
    defer tpl.deinit();

    const ctx = try vin.valueFrom(alloc, .{});
    const out = try tpl.render(alloc, ctx, null);

    try testing.expectEqualStrings("\\Alice=fn2: Blue,33", out);
}

test "Env addGlobal 2" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    try env.addGlobal("greet3", greet3_fn);

    var tpl = try env.compile("<{{ greet3(tul=23678, name='Text') }}", null);
    defer tpl.deinit();

    const ctx = try vin.valueFrom(alloc, .{});
    const out = try tpl.render(alloc, ctx, null);

    try testing.expectEqualStrings("<fn2: Text,23678", out);
}

test "Env addGlobal fail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    try env.addGlobal("greet3", greet3_fn);

    var tpl = try env.compile("<{{ greet31(tul=23678, name='Text') }}", null);
    defer tpl.deinit();

    var diag: vin.Diagnostic = undefined;

    const ctx = try vin.valueFrom(alloc, .{});
    _ = tpl.render(alloc, ctx, &diag) catch {};

    const msg = try alloc.print("{f}", .{diag});
    try testing.expectEqualStrings("line 1: 'greet31' is not callable", msg);
}
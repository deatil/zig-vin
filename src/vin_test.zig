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
        const out = try env.renderTemplateAlloc("show", .none, null);
        defer a.free(out);
        try testing.expectEqualStrings("[42]", out);
    }

    {
        const out = try env.renderTemplateAlloc("sub/show1", .none, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222]", out);
    }

    {
        const ctx = try vin.valueFrom(a, .{
            .name = "test name",
        });
        const out = try env.renderTemplateAlloc("sub/show2", ctx, null);
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
        const out = try env.renderTemplateAlloc("show", .none, null);
        defer a.free(out);
        try testing.expectEqualStrings("[42]", out);
    }

    {
        const out = try env.renderTemplateAlloc("sub/show1", .none, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222]", out);
    }

    {
        const ctx = try vin.valueFrom(a, .{
            .name = "test name",
        });
        const out = try env.renderTemplateAlloc("sub/show2", ctx, null);
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

        const out = try env.renderTemplateAlloc("sub/show2", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }

    {
        var map: vin.value.Namespace = .{};
        try map.set(a, "name", vin.Value.fromString("test name"));
        const ctx: vin.Value = .fromNamespace(&map);

        const out = try env.renderTemplateAlloc("sub/show2", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }

    {
        var map: *vin.Namespace = try .create(a);
        try map.set(a, "name", .fromString("test name"));
        const ctx: vin.Value = .fromNamespace(map);

        const out = try env.renderTemplateAlloc("sub/show2", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }

    {
        const ctx = try vin.valueFrom(a, .{ .name = "test name", .vlans = [_]u16{ 10, 20 } });

        const out = try env.renderTemplateAlloc("sub/show3", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name10,20,]", out);
    }

    {
        const map: vin.Map = try .create(a, &.{
            try .create(a, "name", .fromString("test name")),
        });
        const ctx: vin.Value = .fromMap(map);

        const out = try env.renderTemplateAlloc("sub/show2", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }
}

test "DirLoader with json 2" {
    const io = testing.io;
    const alloc = testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const a = arena.allocator();

    var env = try vin.Environment.init(a, .{});
    defer env.deinit();

    const dl: vin.DirLoader = .{ 
        .io = io, 
        .root = try std.Io.Dir.cwd().openDir(io, "src/testdata/views", .{}), 
        .options = .{ 
            .suffix = ".htm",
        },
    };

    env.withLoader(dl.loader());

    {
        const text = 
            \\{"name": "test name"}
        ;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        const ctx = try vin.valueFromJson(a, parsed.value);

        const out = try env.renderTemplateAlloc("sub/show2", ctx, null);
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

        const out = try env.renderTemplateAlloc("sub/show3", ctx, null);
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
        const out = try env.renderTemplateAlloc("sub/show5", ctx, null);
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

        const out = try env.renderTemplateAlloc("sub/show3", ctx, null);
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
    const out = tpl.render(alloc, ctx, &diag);

    try testing.expectError(error.NotCallable, out);

    const msg = try alloc.print("{f}", .{diag});
    try testing.expectEqualStrings("line 1: 'greet31' is not callable", msg);
}

test "Env addGlobal fail 2" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    try env.addGlobal("greet3", greet3_fn);

    var tpl = try env.compile("<{{ greet3(tulu=23678, name='Text') }}", null);
    defer tpl.deinit();

    var diag: vin.Diagnostic = undefined;

    const ctx = try vin.valueFrom(alloc, .{});
    const out = tpl.render(alloc, ctx, &diag);

    try testing.expectError(error.BadArgument, out);

    const msg = try alloc.print("{f}", .{diag});
    try testing.expectEqualStrings("line 1: 'greet3' call fail", msg);
}

fn greet_io_fn(ctx: *vin.FilterCtx, args: vin.FilterArgs) filters.Error!value.Value {
    const name_val = args.byName("name") orelse return error.BadArgument;
    const tul_val = args.byName("tul") orelse return error.BadArgument;

    const s = ctx.toStr(name_val) catch return error.BadArgument;
    const t = ctx.toStr(tul_val) catch return error.BadArgument;

    const io = ctx.io;
    const ts = std.Io.Timestamp.now(io, .real).toSeconds();
    const ts2 = @divTrunc(ts, 100000000);

    const out = try ctx.arena.print("fn2: {s},{s},{d}", .{s, t, ts2});
    return .{ .string = .{ .bytes = out, .safe = false } };
}

test "Env addGlobal with io" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    env.withIo(testing.io);

    try env.addGlobal("greet_io", greet_io_fn);

    var tpl = try env.compile("<{{ greet_io(tul=23678, name='Text') }}", null);
    defer tpl.deinit();

    const ctx = try vin.valueFrom(alloc, .{});
    const out = try tpl.render(alloc, ctx, null);

    try testing.expectEqualStrings("<fn2: Text,23678,17", out);
}

fn addString_fn(ctx: *vin.FilterCtx, input: value.Value, args: vin.FilterArgs) filters.Error!value.Value {
    const name_val = args.byName("name") orelse return error.BadArgument;
    const n = ctx.toStr(name_val) catch return error.BadArgument;

    const in = ctx.toStr(input) catch return error.BadArgument;

    const out = try ctx.arena.print("addstr: {s},{s}", .{n, in});
    return .{ .string = .{ .bytes = out, .safe = false } };
}

test "Env addMethod" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    try env.addMethod("addString", addString_fn);

    var tpl = try env.compile("<>{{ str.addString(name='Text') }}", null);
    defer tpl.deinit();

    const ctx = try vin.valueFrom(alloc, .{
        .str = "user",
    });
    const out = try tpl.render(alloc, ctx, null);

    try testing.expectEqualStrings("<>addstr: Text,user", out);
}

test "Env addMethod fail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    try env.addMethod("addString", addString_fn);

    var tpl = try env.compile("<>{{ str.addString(nameh='Text') }}", null);
    defer tpl.deinit();

    var diag: vin.Diagnostic = undefined;

    const ctx = try vin.valueFrom(alloc, .{
        .str = "user",
    });
    const out = tpl.render(alloc, ctx, &diag);

    try testing.expectError(error.BadArgument, out);

    const msg = try alloc.print("{f}", .{diag});
    try testing.expectEqualStrings("line 1: 'addString' method call fail", msg);
}

fn cy_set_fn(ctx: *vin.FilterCtx, input: value.Value, args: vin.FilterArgs) filters.Error!value.Value {
    const name_val = args.byName("name") orelse return error.BadArgument;

    if (input != .namespace) return error.TypeMismatch;

    const ns = input.namespace;
    try ns.set(ctx.arena, "foo", name_val);
    return .empty_string;
}

test "Env addMethod set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    try env.addMethod("cy_set", cy_set_fn);

    var tpl = try env.compile("{{ data.cy_set(name='Text') }}<>{{data}}", null);
    defer tpl.deinit();

    var map: vin.value.Namespace = .{};
    try map.set(alloc, "foo", .fromString("val"));

    const data: vin.Value = .fromNamespace(&map);

    const ctx = try vin.valueFrom(alloc, .{
        .data = data,
    });
    const out = try tpl.render(alloc, ctx, null);

    try testing.expectEqualStrings("<>{'foo': 'Text'}", out);
}

test "DynMapLoader renderTemplateAlloc" {
    const alloc = testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const a = arena.allocator();

    var map: *vin.DynMapLoader = try .create(a);
    try map.put("base2", @embedFile("testdata/views/base2.htm"));
    try map.put("sub/show6", @embedFile("testdata/views/sub/show6.htm"));

    var env = try vin.Environment.initWithLoader(a, .{}, map.loader());
    defer env.deinit();

    {
        const ctx = try vin.valueFrom(a, .{
            .name = "test name",
        });
        const out = try env.renderTemplateAlloc("sub/show6", ctx, null);
        defer a.free(out);
        try testing.expectEqualStrings("[4222==test name]", out);
    }
}

const TestH = struct {
    line: usize,
    name: []const u8,
    data: []const vin.Node,

    pub fn test_fn(ctx: *const anyopaque, render: *anyopaque) vin.AstError![]const vin.Node {
        const self: *const TestH = @ptrCast(@alignCast(ctx));
        var r: *vin.Renderer = @ptrCast(@alignCast(render));

        r.emit(.fromString(self.name), self.line) catch return vin.AstError.TemplateSyntaxError;

        return self.data;
    }
};

fn tag_addstrings_fn(parser: *vin.Parser, rest: []const vin.Token, line: usize, out: *std.ArrayList(vin.Node)) vin.CompileError!void {
    var ts: vin.Stream = .{ .toks = rest, .p = parser };
    const name = try ts.expect(.name, line, "expected a addstrings name");
    const body = try parser.parseBody(&.{"endaddstrings"});

    const h = TestH{
        .line = line,
        .name = name.text,
        .data = body.nodes,
    };

    const def = try parser.arena.create(vin.ast.Generic);
    def.* = .{
        .ctx = &h,
        .renderFn = TestH.test_fn,
        .line = line,
    };

    try out.append(parser.arena, .{ .generic = def.* });
}

test "Env addTag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    try env.addTag("addstrings", tag_addstrings_fn);

    var tpl = try env.compile("<>{% addstrings title %}123{% endaddstrings %}", null);
    defer tpl.deinit();

    const ctx = try vin.valueFrom(alloc, .{
        .str = "user",
    });
    const out = try tpl.render(alloc, ctx, null);

    try testing.expectEqualStrings("<>title123", out);
}

test "Env addTag fail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    try env.addTag("addstrings", tag_addstrings_fn);

    var diag: vin.Diagnostic = undefined;

    const tpl = env.compile("<>{% addstrings title %}123{% endaddstring %}", &diag);

    try testing.expectError(error.TemplateSyntaxError, tpl);

    const msg = try alloc.print("{f}", .{diag});
    try testing.expectEqualStrings("line 1: invalid tag", msg);
}

const TestH2 = struct {
    line: usize,
    name: []const u8,
    data: []const vin.Node,

    pub fn test_fn(ctx: *const anyopaque, render: *anyopaque) vin.AstError![]const vin.Node {
        _ = ctx;
        _ = render;

        return vin.AstError.TemplateSyntaxError;
    }
};

fn tag_addstrings_fn2(parser: *vin.Parser, rest: []const vin.Token, line: usize, out: *std.ArrayList(vin.Node)) vin.CompileError!void {
    var ts: vin.Stream = .{ .toks = rest, .p = parser };
    const name = try ts.expect(.name, line, "expected a addstrings name");
    const body = try parser.parseBody(&.{"endaddstrings"});

    const h = TestH2{
        .line = line,
        .name = name.text,
        .data = body.nodes,
    };

    const def = try parser.arena.create(vin.ast.Generic);
    def.* = .{
        .ctx = &h,
        .renderFn = TestH2.test_fn,
        .line = line,
    };

    try out.append(parser.arena, .{ .generic = def.* });
}

test "Env addTag fail 2" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = try vin.Environment.init(alloc, .{});
    defer env.deinit();

    try env.addTag("addstrings", tag_addstrings_fn2);

    var tpl = try env.compile("<>{% addstrings title %}123{% endaddstrings %}", null);
    defer tpl.deinit();

    var diag: vin.Diagnostic = undefined;

    const ctx = try vin.valueFrom(alloc, .{
        .str = "user",
    });
    const out = tpl.render(alloc, ctx, &diag);

    try testing.expectError(error.TemplateSyntaxError, out);

    const msg = try alloc.print("{f}", .{diag});
    try testing.expectEqualStrings("line 1: tag use invalid", msg);
}

test "Value is and to" {
    const alloc = testing.allocator;

    {
        const v = vin.Value.fromBool(true);
        try testing.expectEqual(true, v.isBool());
        try testing.expectEqual(true, v.toBool().?);
    }
    {
        const v = vin.Value.fromInt(6);
        try testing.expectEqual(true, v.isInt());
        try testing.expectEqual(false, v.isBool());
        try testing.expectEqual(6, v.toInt().?);
    }
    {
        const v = vin.Value.fromFloat(7.6);
        try testing.expectEqual(true, v.isFloat());
        try testing.expectEqual(7.6, v.toFloat().?);
    }
    {
        const v = vin.Value.fromString("test-data");
        try testing.expectEqual(true, v.isString());
        try testing.expectEqual("test-data", v.toString().?.bytes);
    }
    {
        const v = vin.Value.fromString("test-data");
        try testing.expectEqual(true, v.isString());
        try testing.expectEqual("test-data", v.toStrings().?);
    }
    {
        const v = vin.Value.fromMarkup("test-data2");
        try testing.expectEqual(true, v.isString());
        try testing.expectEqual("test-data2", v.toString().?.bytes);
    }
    {
        const list: []const vin.Value = &.{
            .fromInt(8),
            .fromString("test"),
        };
        const v = vin.Value.fromList(list);
        try testing.expectEqual(true, v.isArray());
        try testing.expectEqual(list, v.toArray().?);
    }
    {
        const list: []const vin.Value = &.{
            .fromInt(8),
            .fromString("test"),
        };
        const v = vin.Value.fromTuple(list);
        try testing.expectEqual(true, v.isArray());
        try testing.expectEqual(list, v.toArray().?);
    }
    {
        const m: vin.Map = .empty;
        const v = vin.Value.fromMap(m);
        try testing.expectEqual(true, v.isMap());
        try testing.expectEqual(m.pairs, v.toMap(alloc).?);
    }
    {
        var m: vin.Namespace = .empty;
        const v = vin.Value.fromNamespace(&m);
        try testing.expectEqual(true, v.isMap());
        try testing.expectEqual(m.pairs.toOwnedSlice(alloc) catch &.{}, v.toMap(alloc).?);
    }
    {
        var m: vin.value.Loop = .{
            .items = &.{
                .fromInt(8),
                .fromString("test"),
            },
        };
        const v = vin.Value.fromLoop(&m);
        try testing.expectEqual(true, v.isLoop());
        try testing.expectEqual(m.items, v.toLoop().?.items);
    }
    {
        const m: vin.value.MacroRef = .{
            .name = "test",
            .impl = &.{
                vin.Value.fromInt(8),
            },
        };
        const v: vin.Value = .fromMacro(m);
        try testing.expectEqual(true, v.isMacro());
        try testing.expectEqual(m, v.toMacro().?);
    }
    {
        const v: vin.Value = .{ .undef = .{ .name = "test" } };
        try testing.expectEqual(true, v.isUndefined());
    }
    {
        const v: vin.Value = .none;
        try testing.expectEqual(true, v.isNone());
    }
}

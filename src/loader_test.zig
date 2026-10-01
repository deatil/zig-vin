const std = @import("std");
const testing = std.testing;
const vin = @import("vin.zig");

/// A root with a template in it, a secret next to it, and the symlinks an
/// attacker would plant.
const Tree = struct {
    tmp: testing.TmpDir,
    io: std.Io,
    root: std.Io.Dir,
    symlinks: bool,

    fn init(io: std.Io) !Tree {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        try tmp.dir.writeFile(io, .{ .sub_path = "SECRET", .data = "TOP SECRET" });
        try tmp.dir.createDirPath(io, "root");
        try tmp.dir.createDirPath(io, "root/sub");
        try tmp.dir.writeFile(io, .{ .sub_path = "root/ok.html", .data = "ok:{{ v }}" });
        try tmp.dir.writeFile(io, .{ .sub_path = "root/sub/deep.html", .data = "deep" });

        var symlinks = true;
        // A symlinked FILE inside the root pointing at the secret…
        tmp.dir.symLink(io, "../SECRET", "root/leak.html", .{}) catch {
            symlinks = false;
        };
        // …and a symlinked DIRECTORY component, which refusing to follow only
        // the final component would not catch.
        if (symlinks) {
            tmp.dir.symLink(io, "..", "root/up", .{ .is_directory = true }) catch {
                symlinks = false;
            };
        }

        const root = try tmp.dir.openDir(io, "root", .{});
        return .{ .tmp = tmp, .io = io, .root = root, .symlinks = symlinks };
    }

    fn deinit(self: *Tree) void {
        self.root.close(self.io);
        self.tmp.cleanup();
    }
};

test "DirLoader serves what is inside the root" {
    var tree = try Tree.init(testing.io);
    defer tree.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dl: vin.DirLoader = .{ .io = tree.io, .root = tree.root, .options = .{ .suffix = ".html" } };
    const l = dl.loader();

    try testing.expectEqualStrings("ok:{{ v }}", (try l.load(l.ctx, a, "ok")).?);
    try testing.expectEqualStrings("deep", (try l.load(l.ctx, a, "sub/deep")).?);
    try testing.expect((try l.load(l.ctx, a, "absent")) == null);
}

test "DirLoader refuses every route out of the root" {
    var tree = try Tree.init(testing.io);
    defer tree.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dl: vin.DirLoader = .{ .io = tree.io, .root = tree.root };
    const l = dl.loader();

    const attacks = [_][]const u8{
        "../SECRET",
        "../../SECRET",
        "sub/../../SECRET",
        "./../SECRET",
        "/etc/passwd",
        "//etc/passwd",
        "sub/../../../../../../etc/passwd",
        "..",
        "sub/..",
        "\\..\\SECRET",
        "..\\SECRET",
        "SECRET\x00.html",
    };
    for (attacks) |name| {
        const got = l.load(l.ctx, a, name) catch |e| {
            // A refusal is fine however it is spelled.
            try testing.expect(e == error.LoaderFailed);
            continue;
        };
        if (got) |bytes| {
            std.debug.print("\nDirLoader SERVED a hostile name '{s}': '{s}'\n", .{ name, bytes });
            return error.ContainmentBreached;
        }
    }
}

test "a template cannot escape the root through a name taken from the context" {
    const gpa = testing.allocator;
    var tree = try Tree.init(testing.io);
    defer tree.deinit();

    const dl: vin.DirLoader = .{ .io = tree.io, .root = tree.root };
    var env = try vin.Environment.initWithLoader(gpa, .{ .undefined_policy = .lenient }, dl.loader());
    defer env.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ctx = try vin.valueFrom(arena.allocator(), .{ .theme = "../SECRET" });

    // A hostile name is refused LOUDLY (`LoaderFailed`), not reported as
    // merely absent: `{% include theme ignore missing %}` must not swallow an
    // escape attempt as if the file simply were not there.
    var diag: vin.Diagnostic = .{};
    try testing.expectError(
        error.LoaderFailed,
        env.renderAlloc(gpa, "{% include theme %}", ctx, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.message(), "refused") != null);

    var diag2: vin.Diagnostic = .{};
    try testing.expectError(
        error.LoaderFailed,
        env.renderAlloc(gpa, "{% include theme ignore missing %}", ctx, &diag2),
    );
}

test "DirLoader refuses a template over its size cap" {
    const gpa = testing.allocator;
    var tree = try Tree.init(testing.io);
    defer tree.deinit();

    const big = try gpa.alloc(u8, 4096);
    defer gpa.free(big);
    @memset(big, 'x');
    try tree.tmp.dir.writeFile(tree.io, .{ .sub_path = "root/big", .data = big });

    const dl: vin.DirLoader = .{ .io = tree.io, .root = tree.root, .options = .{ .max_bytes = 1024 } };
    const l = dl.loader();
    try testing.expectError(error.LoaderFailed, l.load(l.ctx, gpa, "big"));
}

/// Render `src` against `templates` with the render arena confined to `budget`
/// bytes, and return whatever error comes back.
///
/// The budget is the point. A bomb that outran its structural cap would exhaust
/// the buffer and surface as `OutOfMemory`, so asserting the *specific* cap
/// error is what proves the bound holds before memory grows — rather than
/// proving only that something eventually went wrong.
fn renderBombErr(
    templates: []const vin.MapLoader.Entry,
    src: []const u8,
    budget: usize,
) anyerror {
    const gpa = testing.allocator;
    const buf = gpa.alloc(u8, budget) catch return error.OutOfMemory;
    defer gpa.free(buf);
    var fba: std.heap.FixedBufferAllocator = .init(buf);

    var map: vin.MapLoader = .{ .entries = templates };
    var env = vin.Environment.initWithLoader(gpa, .{ .undefined_policy = .lenient }, map.loader()) catch |e| return e;
    defer env.deinit();

    var tmpl = env.compile(src, null) catch |e| return e;
    defer tmpl.deinit();

    const out = tmpl.render(fba.allocator(), .{ .map = .{ .pairs = &.{} } }, null) catch |e| return e;
    fba.allocator().free(out);
    return error.BombRenderedSuccessfully;
}

test "an inheritance cycle is caught by name, not by running out of stack" {
    try testing.expectEqual(@as(anyerror, error.TemplateCycle), renderBombErr(&.{
        .{ .name = "a", .source = "{% extends 'b' %}" },
        .{ .name = "b", .source = "{% extends 'a' %}" },
    }, "{% extends 'a' %}", 1 << 20));
}

test "a self-extending template is caught immediately" {
    try testing.expectEqual(
        @as(anyerror, error.TemplateCycle),
        renderBombErr(&.{.{ .name = "a", .source = "{% extends 'a' %}" }}, "{% extends 'a' %}", 1 << 20),
    );
}

test "a three-template inheritance cycle is caught" {
    try testing.expectEqual(@as(anyerror, error.TemplateCycle), renderBombErr(&.{
        .{ .name = "a", .source = "{% extends 'b' %}" },
        .{ .name = "b", .source = "{% extends 'c' %}" },
        .{ .name = "c", .source = "{% extends 'a' %}" },
    }, "{% extends 'a' %}", 1 << 20));
}

test "an include that includes itself hits the depth cap inside a small budget" {
    try testing.expectEqual(
        @as(anyerror, error.TooDeep),
        renderBombErr(&.{.{ .name = "a", .source = "x{% include 'a' %}" }}, "{% include 'a' %}", 1 << 20),
    );
}

test "a mutually-including pair hits the depth cap" {
    try testing.expectEqual(@as(anyerror, error.TooDeep), renderBombErr(&.{
        .{ .name = "a", .source = "{% include 'b' %}" },
        .{ .name = "b", .source = "{% include 'a' %}" },
    }, "{% include 'a' %}", 1 << 20));
}

test "an exponential include bomb is stopped by the depth cap, not by memory" {
    // Each level includes the next TWICE, so an unbounded engine expands
    // 2^depth times. This is the shape that cost a desktop 15.4 GB elsewhere in
    // this repository; here it must die at the cap, inside 1 MiB.
    try testing.expectEqual(@as(anyerror, error.TooDeep), renderBombErr(&.{
        .{ .name = "a", .source = "{% include 'b' %}{% include 'b' %}" },
        .{ .name = "b", .source = "{% include 'a' %}{% include 'a' %}" },
    }, "{% include 'a' %}", 1 << 20));
}

test "an infinitely recursive macro hits the call cap" {
    try testing.expectEqual(
        @as(anyerror, error.TooDeep),
        renderBombErr(&.{}, "{% macro f() %}{{ f() }}{% endmacro %}{{ f() }}", 1 << 20),
    );
}

test "a mutually recursive macro pair hits the call cap" {
    try testing.expectEqual(@as(anyerror, error.TooDeep), renderBombErr(
        &.{},
        "{% macro a() %}{{ b() }}{% endmacro %}{% macro b() %}{{ a() }}{% endmacro %}{{ a() }}",
        1 << 20,
    ));
}

test "a self-feeding recursive loop hits the call cap" {
    try testing.expectEqual(
        @as(anyerror, error.TooDeep),
        renderBombErr(&.{}, "{% for i in [1] recursive %}{{ loop([1]) }}{% endfor %}", 1 << 20),
    );
}

test "an include of many distinct templates (no recursion) hits the total-load cap" {
    // `max_templates` (default 256) bounds the total COUNT of templates
    // loaded in one render; `max_template_depth` (32) bounds NESTING. A
    // wide, flat template that includes many distinct siblings in
    // sequence — no recursion, no cycle, nesting depth 1 throughout —
    // exercises `max_templates` specifically. Every other bomb test in
    // this file is a depth/cycle bomb that trips `max_template_depth`
    // long before `max_templates` could ever matter, so this is the only
    // place the total-load cap itself gets checked.
    const gpa = testing.allocator;
    const n = 300; // > the default max_templates (256)

    var entries: std.ArrayList(vin.MapLoader.Entry) = .empty;
    defer entries.deinit(gpa);
    var owned_names: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_names.items) |nm| gpa.free(nm);
        owned_names.deinit(gpa);
    }
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);

    for (0..n) |i| {
        const name = try std.fmt.allocPrint(gpa, "t{d}", .{i});
        try owned_names.append(gpa, name);
        try entries.append(gpa, .{ .name = name, .source = "x" });
        const tag = try std.fmt.allocPrint(gpa, "{{% include '{s}' %}}", .{name});
        defer gpa.free(tag);
        try src.appendSlice(gpa, tag);
    }

    try testing.expectEqual(
        @as(anyerror, error.TooDeep),
        renderBombErr(entries.items, src.items, 1 << 20),
    );
}

test "an import cycle hits the depth cap" {
    try testing.expectEqual(@as(anyerror, error.TooDeep), renderBombErr(&.{
        .{ .name = "a", .source = "{% import 'b' as b %}" },
        .{ .name = "b", .source = "{% import 'a' as a %}" },
    }, "{% import 'a' as a %}", 1 << 20));
}

test "the caps are configurable and the error names the limit" {
    const gpa = testing.allocator;
    var map: vin.MapLoader = .{ .entries = &.{.{ .name = "a", .source = "{% include 'a' %}" }} };
    var env = try vin.Environment.initWithLoader(
        gpa,
        .{ .max_template_depth = 4, .undefined_policy = .lenient },
        map.loader(),
    );
    defer env.deinit();

    var diag: vin.Diagnostic = .{};
    try testing.expectError(
        error.TooDeep,
        env.renderAlloc(gpa, "{% include 'a' %}", .{ .map = .{ .pairs = &.{} } }, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.message(), "4") != null);
}

test "a legitimate deep chain still renders — the cap is not just 'no nesting'" {
    const gpa = testing.allocator;
    var map: vin.MapLoader = .{ .entries = &.{
        .{ .name = "l1", .source = "1{% include 'l2' %}" },
        .{ .name = "l2", .source = "2{% include 'l3' %}" },
        .{ .name = "l3", .source = "3{% include 'l4' %}" },
        .{ .name = "l4", .source = "4" },
    } };
    var env = try vin.Environment.initWithLoader(gpa, .{}, map.loader());
    defer env.deinit();
    const out = try env.renderAlloc(gpa, "[{% include 'l1' %}]", .{ .map = .{ .pairs = &.{} } }, null);
    defer gpa.free(out);
    try testing.expectEqualStrings("[1234]", out);
}

test "a template included in a loop is loaded and compiled once" {
    const gpa = testing.allocator;
    var map: vin.MapLoader = .{ .entries = &.{.{ .name = "row", .source = "<{{ i }}>" }} };
    var env = try vin.Environment.initWithLoader(gpa, .{}, map.loader());
    defer env.deinit();
    const out = try env.renderAlloc(
        gpa,
        "{% for i in range(5) %}{% include 'row' %}{% endfor %}",
        .{ .map = .{ .pairs = &.{} } },
        null,
    );
    defer gpa.free(out);
    try testing.expectEqualStrings("<0><1><2><3><4>", out);
}

test "a regular file in the middle of a path is absence, a symlinked one is a refusal" {
    var tree = try Tree.init(testing.io);
    defer tree.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dl: vin.DirLoader = .{ .io = tree.io, .root = tree.root };
    const l = dl.loader();

    // `root/ok.html` is a regular file, so `ok.html/x` is `ENOTDIR` — the same
    // errno a refused symlinked directory gives. Conflating them made
    // `{% include 'ok.html/x' ignore missing %}` fail the render instead of
    // being ignored, which contradicts D17's own wording: only genuine
    // absence is ignorable (W2 re-audit, F-E2).
    try testing.expect((try l.load(l.ctx, a, "ok.html/x")) == null);
    try testing.expect((try l.load(l.ctx, a, "absentdir/x")) == null);

    // …and the symlinked directory component is still refused, not reported
    // absent. That is the half the F13 fix was about, and it must not regress.
    if (tree.symlinks) {
        try testing.expectError(error.LoaderFailed, l.load(l.ctx, a, "up/SECRET"));
    }
}

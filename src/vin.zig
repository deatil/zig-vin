const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const loader_mod = @import("loader.zig");
const render_mod = @import("render.zig");
const filters_mod = @import("filters.zig");

pub const value = @import("value.zig");

pub const Value = value.Value;
pub const Str = value.Str;
pub const Pair = value.Pair;
pub const Map = value.Map;
pub const Namespace = value.Namespace;
pub const Undefined = value.Undefined;

// first code from https://github.com/zaxified/zig-libs

/// Build a `Value` from ordinary Zig data — structs become ordered maps in
/// field order, `[]const u8` becomes a string, slices become lists.
pub const valueFrom = value.from;
/// Adapter for `std.json.Value`. See SPEC.md §2 for why this, and not a
/// dependency on the `yaml` module, is the shipped adapter.
pub const valueFromJson = value.fromJson;
/// markupsafe's escape set, exposed because callers registering their own
/// filters need exactly it.
pub const escapeAlloc = value.escapeAlloc;

pub const Diagnostic = @import("diag.zig").Diagnostic;

/// Where `{% extends %}`, `{% include %}` and `{% import %}` find templates.
pub const Loader = loader_mod.Loader;
pub const MapLoader = loader_mod.MapLoader;
pub const DirLoader = loader_mod.DirLoader;
pub const LoaderError = loader_mod.Error;
/// The lexical half of `DirLoader`'s containment, exported so a caller writing
/// its own filesystem loader can reuse exactly the same rules.
pub const checkTemplateName = loader_mod.checkName;
pub const UndefinedPolicy = render_mod.UndefinedPolicy;

pub const Options = struct {
    autoescape: bool = false,
    undefined_policy: UndefinedPolicy = .strict,
    trim_blocks: bool = false,
    lstrip_blocks: bool = false,
    keep_trailing_newline: bool = false,
    max_output_bytes: usize = 64 << 20,
    /// Total bytes one render may take from its scratch arena.
    ///
    /// The depth caps below bound DEPTH; the per-operation caps in `value.zig`
    /// (`max_alloc`, `max_items`) bound ONE operation. Neither bounds a
    /// render's total work, and the arena is not reclaimed until the render
    /// ends, so both compose into an unbounded one: `{% macro m(n) %}…{{ m(n-1) }}{{ m(n-1) }}…`
    /// at depth 22 — a third of `max_call_depth` — took 3.8 GB and emitted
    /// **zero bytes**, so `max_output_bytes` never saw one, and
    /// `{{ ('a' * 30000)|replace('', 'b' * 30000) }}` multiplied two 64 MiB
    /// caps together from a 53-byte template
    max_render_bytes: usize = 256 << 20,
    /// Combined nesting bound for `{% extends %}`/`{% include %}`/
    /// `{% import %}`. An inheritance *cycle* is caught by name before this
    /// ever fires; this bounds everything a name check cannot see.
    max_template_depth: usize = 32,
    /// Nesting bound for macro calls, `{% call %}` bodies and `loop()`.
    max_call_depth: usize = 64,
    /// How many distinct templates one render may load.
    max_templates: usize = 256,
    /// Bound on how deep one template's syntax may nest: brackets, `not`/unary
    /// chains, `else` arms, each link of a `1+1+1`/`x|f|g`/`a.b.c` chain, each
    /// nested block body and each `{% elif %}`. Enforced at compile time, and
    /// therefore bounding the recursive evaluator too, since it bounds the tree
    /// the evaluator walks. Without it a template of 8 000 `(` overflows the
    /// parser's stack, one of 8 000 `|string` overflows the evaluator's, and
    /// 16 000 nested `{% if %}` overflow the parser's again — a segfault rather
    /// than an error. See `parser.Limits` for why the default is 256.
    max_nesting_depth: usize = 256,
};

pub const CompileError = parser.Error;
pub const RenderError = render_mod.Error;
pub const Error = CompileError || RenderError;

/// Filter/test authoring surface, for `Environment.addFilter`/`addTest`.
pub const FilterCtx = filters_mod.Ctx;
pub const FilterFn = filters_mod.Fn;
pub const TestFn = filters_mod.TestFn;
pub const FilterArgs = filters_mod.Args;
pub const FilterError = filters_mod.Error;
pub const FilterKwarg = filters_mod.Kwarg;

/// Owns the filter and test registries and the syntax options. Compiling a
/// template resolves every filter and test name against this environment, so
/// an environment must outlive the templates compiled from it.
pub const Environment = struct {
    gpa: Allocator,
    options: Options,
    filters: std.StringHashMapUnmanaged(FilterFn) = .empty,
    tests: std.StringHashMapUnmanaged(TestFn) = .empty,
    /// Optional; without one, any composition tag is `error.NoLoader`.
    loader: ?Loader = null,

    const Self = @This();

    pub fn init(gpa: Allocator, options: Options) error{OutOfMemory}!Environment {
        return initWithLoader(gpa, options, null);
    }

    /// As `init`, with the loader that `{% extends %}`, `{% include %}` and
    /// `{% import %}` will use. The loader is borrowed and must outlive the
    /// environment.
    pub fn initWithLoader(
        gpa: Allocator,
        options: Options,
        template_loader: ?Loader,
    ) error{OutOfMemory}!Environment {
        var env: Environment = .{ .gpa = gpa, .options = options, .loader = template_loader };
        errdefer env.deinit();
        for (filters_mod.builtin_filters) |e| try env.filters.put(gpa, e.name, e.func);
        for (filters_mod.builtin_tests) |e| try env.tests.put(gpa, e.name, e.func);
        return env;
    }

    pub fn deinit(self: *Environment) void {
        self.filters.deinit(self.gpa);
        self.tests.deinit(self.gpa);
        self.* = undefined;
    }

    /// Register (or replace) a filter. `name` is borrowed and must outlive the
    /// environment.
    pub fn addFilter(self: *Environment, name: []const u8, func: FilterFn) error{OutOfMemory}!void {
        try self.filters.put(self.gpa, name, func);
    }

    pub fn addTest(self: *Environment, name: []const u8, func: TestFn) error{OutOfMemory}!void {
        try self.tests.put(self.gpa, name, func);
    }

    /// Parse `source` into a reusable `Template`. The template copies the
    /// source, so `source` need not outlive the call. `diag` (optional) is
    /// filled in on `error.TemplateSyntaxError`.
    pub fn compile(self: *const Environment, source: []const u8, diag: ?*Diagnostic) CompileError!Template {
        var scratch: Diagnostic = .{};
        const d = diag orelse &scratch;

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned = try a.dupe(u8, source);

        const lexed = lexer.lex(a, owned, .{
            .trim_blocks = self.options.trim_blocks,
            .lstrip_blocks = self.options.lstrip_blocks,
            .keep_trailing_newline = self.options.keep_trailing_newline,
        }, d) catch |e| return e;

        const parsed = try parser.parse(a, lexed.pieces, .{
            .ctx = self,
            .hasFilter = hasFilterThunk,
            .hasTest = hasTestThunk,
        }, .{ .max_nesting_depth = self.options.max_nesting_depth }, d);

        return .{ .arena = arena, .parsed = parsed, .env = self };
    }

    /// Compile and render in one step, for the one-shot case.
    pub fn renderAlloc(
        self: *const Environment,
        gpa: Allocator,
        source: []const u8,
        context: Value,
        diag: ?*Diagnostic,
    ) Error![]u8 {
        var tmpl = try self.compile(source, diag);
        defer tmpl.deinit();
        return tmpl.render(gpa, context, diag);
    }

    pub fn renderTemplate(
        self: *const Self,
        gpa: Allocator,
        tpl: []const u8,
        diag: ?*Diagnostic,
    ) !Template {
        if (self.loader) |loader| {
            const source = try loader.load(loader.ctx, gpa, tpl);
            if (source) |val| {
                defer gpa.free(val);

                const tmpl = try self.compile(val, diag);
                return tmpl;
            }
        }

        return error.LoaderInvalid;
    }

    pub fn renderTemplateAlloc(
        self: *const Self,
        gpa: Allocator,
        tpl: []const u8,
        context: Value,
        diag: ?*Diagnostic,
    ) ![]u8 {
        var tmpl = try self.renderTemplate(gpa, tpl, diag);
        defer tmpl.deinit();

        return tmpl.render(gpa, context, diag);
    }

    fn hasFilterThunk(ctx: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.filters.contains(name);
    }

    fn hasTestThunk(ctx: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.tests.contains(name);
    }

    fn filterLookup(ctx: *const anyopaque, name: []const u8) ?FilterFn {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.filters.get(name);
    }

    fn testLookup(ctx: *const anyopaque, name: []const u8) ?TestFn {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.tests.get(name);
    }

    /// Compiles a *loaded* template into the render arena. Loaded templates go
    /// through exactly the same lexer, options and name resolution as the entry
    /// template — an included template naming a missing filter fails as loudly
    /// as a top-level one, just later, because it is only compiled when reached.
    fn compileInto(
        ctx: *const anyopaque,
        arena: Allocator,
        source: []const u8,
        diag: *Diagnostic,
    ) parser.Error!ast.Parsed {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        const lexed = try lexer.lex(arena, source, .{
            .trim_blocks = self.options.trim_blocks,
            .lstrip_blocks = self.options.lstrip_blocks,
            .keep_trailing_newline = self.options.keep_trailing_newline,
        }, diag);
        return parser.parse(arena, lexed.pieces, .{
            .ctx = self,
            .hasFilter = hasFilterThunk,
            .hasTest = hasTestThunk,
        }, .{ .max_nesting_depth = self.options.max_nesting_depth }, diag);
    }
};

/// A compiled template: an arena holding the source copy and the tree, plus a
/// borrowed pointer to the environment that compiled it. Immutable after
/// compilation, so one template may be rendered from several threads at once
/// (each render allocates its own scratch arena).
pub const Template = struct {
    arena: std.heap.ArenaAllocator,
    parsed: ast.Parsed,
    env: *const Environment,

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Render to a freshly allocated buffer owned by the caller.
    pub fn render(
        self: *const Template,
        gpa: Allocator,
        context: Value,
        diag: ?*Diagnostic,
    ) RenderError![]u8 {
        var aw: Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try self.renderTo(gpa, &aw.writer, context, diag);
        return aw.toOwnedSlice() catch error.OutOfMemory;
    }

    /// Render into `out`. `gpa` backs a scratch arena that is released before
    /// this returns, so intermediate values never outlive the call.
    pub fn renderTo(
        self: *const Template,
        gpa: Allocator,
        out: *Writer,
        context: Value,
        diag: ?*Diagnostic,
    ) RenderError!void {
        var scratch: Diagnostic = .{};
        const d = diag orelse &scratch;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var budget: RenderBudget = .{
            .parent = arena.allocator(),
            .remaining = self.env.options.max_render_bytes,
        };
        render_mod.render(budget.allocator(), self.parsed, context, .{
            .autoescape = self.env.options.autoescape,
            .undefined_policy = self.env.options.undefined_policy,
            .max_output_bytes = self.env.options.max_output_bytes,
            .max_template_depth = self.env.options.max_template_depth,
            .max_call_depth = self.env.options.max_call_depth,
            .max_templates = self.env.options.max_templates,
        }, .{
            .ctx = self.env,
            .filter = Environment.filterLookup,
            .test_fn = Environment.testLookup,
            .loader = self.env.loader,
            .compile = Environment.compileInto,
        }, out, d) catch |e| {
            // An exhausted budget arrives as `OutOfMemory` because that is the
            // only thing an allocator may report. Reporting it as `OutOfMemory`
            // to the caller would be the same misclassification a real OOM is
            // not: the machine has memory, this render asked for too much.
            if (e == error.OutOfMemory and budget.exhausted) {
                d.set(0, "render exceeded max_render_bytes ({d})", .{self.env.options.max_render_bytes});
                return error.RenderBudgetExceeded;
            }
            return e;
        };
    }
};

/// Charges a render's scratch arena against `Options.max_render_bytes`. Only
/// `alloc`/`remap` grow the total; the arena never really frees, so neither
/// does this.
const RenderBudget = struct {
    parent: Allocator,
    remaining: usize,
    exhausted: bool = false,

    fn allocator(self: *RenderBudget) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn take(self: *RenderBudget, n: usize) bool {
        if (n > self.remaining) {
            self.exhausted = true;
            return false;
        }
        self.remaining -= n;
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *RenderBudget = @ptrCast(@alignCast(ctx));
        if (!self.take(len)) return null;
        return self.parent.rawAlloc(len, a, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *RenderBudget = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.take(new_len - memory.len)) return false;
        return self.parent.rawResize(memory, a, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *RenderBudget = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.take(new_len - memory.len)) return null;
        return self.parent.rawRemap(memory, a, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *RenderBudget = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, a, ra);
    }
};

/// The one-liner: default options, compile and render, caller owns the result.
pub fn renderAlloc(
    gpa: Allocator,
    source: []const u8,
    context: Value,
    options: Options,
    diag: ?*Diagnostic,
) Error![]u8 {
    var env = try Environment.init(gpa, options);
    defer env.deinit();
    return env.renderAlloc(gpa, source, context, diag);
}

test {
    _ = @import("value.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("ast.zig");
    _ = @import("render.zig");
    _ = @import("filters.zig");
    _ = @import("diag.zig");
    _ = @import("engine_test.zig");
    _ = @import("conform.zig");
    _ = @import("reference_test.zig");
    _ = @import("loader.zig");
    _ = @import("loader_test.zig");
    _ = @import("vin_test.zig");
}

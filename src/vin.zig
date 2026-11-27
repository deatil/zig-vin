const std = @import("std");
const Io = std.Io;
const Writer = std.Io.Writer;
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;

pub const value = @import("value.zig");
pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const args = @import("args.zig");
pub const errors = @import("errors.zig");
pub const diags = @import("diag.zig");
pub const parser = @import("parser.zig");
pub const renders = @import("render.zig");
pub const loaders = @import("loader.zig");

pub const Expr = ast.Expr;
pub const Node = ast.Node;
pub const Generic = ast.Generic;
pub const Parser = parser.Parser;
pub const Stream = parser.Stream;
pub const Token = lexer.Token;
pub const Delimiters = lexer.Delimiters;
pub const Renderer = renders.Renderer;
pub const Value = value.Value;
pub const Str = value.Str;
pub const Pair = value.Pair;
pub const Map = value.Map;
pub const Namespace = value.Namespace;
pub const Dict = value.Dict;
pub const Array = value.Array;
pub const Callable = value.Callable;
pub const Undefined = value.Undefined;

pub const valueNone = value.none;
pub const valueUndef = value.undef;
pub const valueBool = value.booler;
pub const valueInt = value.int;
pub const valueFloat = value.floater;
pub const valueString = value.string;
pub const valueMarkup = value.markup;
pub const valueMaps = value.maps;
pub const valueNamespaces = value.namespaces;
pub const valueDict = value.dict;
pub const valueArray = value.array;
/// Build a `Value` from ordinary Zig data — structs become ordered maps in
/// field order, `[]const u8` becomes a string, slices become lists.
pub const valueFrom = value.from;
/// Adapter for `std.json.Value`.
pub const valueFromJson = value.fromJson;
/// markupsafe's escape set, exposed because callers registering their own
/// filters need exactly it.
pub const escapeAlloc = value.escapeAlloc;

pub const Diagnostic = diags.Diagnostic;

/// Where `{% extends %}`, `{% include %}` and `{% import %}` find templates.
pub const Loader = loaders.Loader;
pub const MapLoader = loaders.MapLoader;
pub const DynMapLoader = loaders.DynMapLoader;
pub const DirLoader = loaders.DirLoader;
pub const MultiLoader = loaders.MultiLoader;
pub const LoaderError = loaders.Error;
/// The lexical half of `DirLoader`'s containment, exported so a caller writing
/// its own filesystem loader can reuse exactly the same rules.
pub const checkTemplateName = loaders.checkName;
pub const UndefinedPolicy = renders.UndefinedPolicy;

pub const AstError = ast.Error;
pub const ArgsError = args.Error;
pub const CompileError = parser.Error;
pub const RenderError = renders.Error;
pub const VinError = errors.VinError;
pub const Error = AstError || CompileError || RenderError;

pub const Ctx = args.Ctx;
pub const Args = args.Args;
pub const Kwarg = args.Kwarg;

pub const FilterFn = args.FilterFn;
pub const TestFn = args.TestFn;
pub const GlobalFn = args.GlobalFn;
pub const MethodFn = args.MethodFn;
pub const FunctionFn = args.FunctionFn;
pub const TagFn = parser.TagFn;

pub const Options = struct {
    autoescape: bool = false,
    undefined_policy: UndefinedPolicy = .strict,
    trim_blocks: bool = false,
    lstrip_blocks: bool = false,
    keep_trailing_newline: bool = false,
    /// Optional custom tag delimiters.
    /// Defaults remain: {{ }}, {% %}, {# #}
    delimiters: Delimiters = .{},
    max_output_bytes: usize = 64 << 20,
    /// Total bytes one render may take from its scratch arena.
    max_render_bytes: usize = 256 << 20,
    /// Combined nesting bound for `{% extends %}`/`{% include %}`/
    /// `{% import %}`.
    max_template_depth: usize = 32,
    /// Nesting bound for macro calls, `{% call %}` bodies and `loop()`.
    max_call_depth: usize = 64,
    /// How many distinct templates one render may load.
    max_templates: usize = 256,
    /// Maximum number of iterations for one `{% while %}` tag.
    max_while_iterations: usize = 1_000_000,
    /// Bound on how deep one template's syntax may nest: brackets.
    max_nesting_depth: usize = 256,
};

const builtin = @import("builtin.zig");

var diagn: Diagnostic = .{};

/// Owns the filter and test registries and the syntax options. Compiling a
/// template resolves every filter and test name against this environment, so
/// an environment must outlive the templates compiled from it.
pub const Environment = struct {
    gpa: Allocator,
    io: Io = std.Options.debug_io,
    options: Options,
    filters: std.StringHashMapUnmanaged(FilterFn) = .empty,
    tests: std.StringHashMapUnmanaged(TestFn) = .empty,
    globals: std.StringHashMapUnmanaged(GlobalFn) = .empty,
    global_values: std.StringHashMapUnmanaged(Value) = .empty,
    methods: std.StringHashMapUnmanaged(MethodFn) = .empty,
    tags: std.StringHashMapUnmanaged(TagFn) = .empty,
    /// Cache parse template
    template_caches: std.StringHashMapUnmanaged(Template) = .empty,
    /// Optional; without one, any composition tag is `error.NoLoader`.
    loader: ?Loader = null,
    diag: ?*Diagnostic = null,

    const Self = @This();

    pub fn init(gpa: Allocator, options: Options) VinError!Self {
        return initWithLoader(gpa, options, null);
    }

    /// As `init`, with the loader that `{% extends %}`, `{% include %}` and
    /// `{% import %}` will use. The loader is borrowed and must outlive the
    /// environment.
    pub fn initWithLoader(gpa: Allocator, options: Options, template_loader: ?Loader) VinError!Self {
        var env: Self = .{ .gpa = gpa, .options = options, .loader = template_loader };
        errdefer env.deinit();

        for (builtin.builtin_filters) |e| {
            try env.filters.put(gpa, e.name, e.func);
        }
        for (builtin.builtin_tests) |e| {
            try env.tests.put(gpa, e.name, e.func);
        }
        for (builtin.builtin_globals) |e| {
            try env.globals.put(gpa, e.name, e.func);
        }
        for (builtin.builtin_methods) |e| {
            try env.methods.put(gpa, e.name, e.func);
        }
        for (builtin.builtin_tags) |e| {
            try env.tags.put(gpa, e.name, e.func);
        }

        env.diag = &diagn;

        return env;
    }

    pub fn deinit(self: *Self) void {
        self.filters.deinit(self.gpa);
        self.tests.deinit(self.gpa);
        self.globals.deinit(self.gpa);
        self.global_values.deinit(self.gpa);
        self.methods.deinit(self.gpa);
        self.tags.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn getError(self: Self) ![]const u8 {
        if (self.diag) |d| {
            const err = try self.gpa.print("{f}", .{d});
            return err;
        }

        return "";
    }

    pub fn withLoader(self: *Self, template_loader: Loader) void {
        self.loader = template_loader;
    }

    // when need io, this must set.
    pub fn withIo(self: *Self, io: Io) void {
        self.io = io;
    }

    pub fn withDiag(self: *Self, diag: *Diagnostic) void {
        self.diag = diag;
    }

    /// Register (or replace) a filter. `name` is borrowed and must outlive the
    /// environment.
    pub fn addFilter(self: *Self, name: []const u8, func: FilterFn) VinError!void {
        try self.filters.put(self.gpa, name, func);
    }

    pub fn addTest(self: *Self, name: []const u8, func: TestFn) VinError!void {
        try self.tests.put(self.gpa, name, func);
    }

    /// Register (or replace) a global function. `name` is borrowed and must
    /// outlive the environment.
    pub fn addGlobal(self: *Self, name: []const u8, func: GlobalFn) VinError!void {
        try self.globals.put(self.gpa, name, func);
    }

    pub fn addGlobalValue(self: *Self, name: []const u8, val: Value) VinError!void {
        try self.global_values.put(self.gpa, name, val);
    }

    pub fn addMethod(self: *Self, name: []const u8, func: MethodFn) VinError!void {
        try self.methods.put(self.gpa, name, func);
    }

    pub fn addTag(self: *Self, name: []const u8, func: TagFn) VinError!void {
        try self.tags.put(self.gpa, name, func);
    }

    pub fn addFunction(self: *Self, name: []const u8, func: FunctionFn) VinError!void {
        try self.addGlobalValue(name, .{ .caller = .{ .call = func } });
    }

    pub fn banFilter(self: *Self, name: []const u8) bool {
        return self.filters.remove(name);
    }

    pub fn banTest(self: *Self, name: []const u8) bool {
        return self.tests.remove(name);
    }

    pub fn banGlobal(self: *Self, name: []const u8) bool {
        return self.globals.remove(name);
    }

    pub fn banGlobalValue(self: *Self, name: []const u8) bool {
        return self.global_values.remove(name);
    }

    pub fn banMethod(self: *Self, name: []const u8) bool {
        return self.methods.remove(name);
    }

    pub fn banTag(self: *Self, name: []const u8) bool {
        return self.tags.remove(name);
    }

    /// Parse `source` into a reusable `Template`. The template copies the
    /// source, so `source` need not outlive the call. `diag` (optional) is
    /// filled in on `error.TemplateSyntaxError`.
    pub fn parse(self: *Self, source: []const u8) CompileError!Template {
        var scratch: Diagnostic = .{};
        const d = self.diag orelse &scratch;

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const owned = try a.dupe(u8, source);

        const lexed = lexer.lex(a, owned, .{
            .trim_blocks = self.options.trim_blocks,
            .lstrip_blocks = self.options.lstrip_blocks,
            .keep_trailing_newline = self.options.keep_trailing_newline,
            .delimiters = self.options.delimiters,
        }, d) catch |e| return e;

        const parsed = try parser.parse(a, lexed.pieces, .{
            .ctx = self,
            .hasFilter = hasFilterThunk,
            .hasTest = hasTestThunk,
            .hasGlobal = hasGlobalThunk,
            .hasMethod = hasMethodThunk,
            .hasTag = hasTagThunk,
            .hasGlobalValue = hasGlobalValueThunk,
            .tag = tagLookup,
        }, .{ .max_nesting_depth = self.options.max_nesting_depth }, d);

        return .{
            .gpa = self.gpa,
            .arena = arena,
            .io = self.io,
            .parsed = parsed,
            .env = self,
            .diag = d,
        };
    }

    pub fn compile(self: *Self, source: []const u8) CompileError!Template {
        return self.parse(source);
    }

    pub fn fromString(self: *Self, source: []const u8) CompileError!Template {
        return self.parse(source);
    }

    /// Compile and render in one step, for the one-shot case.
    pub fn execute(self: *Self, source: []const u8, context: Value) Error![]u8 {
        var tmpl = try self.parse(source);
        defer tmpl.deinit();

        return tmpl.render(context);
    }

    pub fn getTemplate(self: *Self, tpl: []const u8) !Template {
        var scratch: Diagnostic = .{};
        var d = self.diag orelse &scratch;

        if (self.loader) |loader| {
            const source = loader.load(loader.ctx, self.gpa, tpl) catch |err| {
                d.with(0, "Template '{s}' load fail", .{tpl});
                return err;
            };

            if (source) |val| {
                var tmpl = try self.parse(val);
                tmpl.template_name = tpl;
                return tmpl;
            }
        }

        d.with(0, "Template '{s}' not found", .{tpl});
        return error.LoaderInvalid;
    }

    pub fn fromFile(self: *Self, filename: []const u8) !Template {
        return self.getTemplate(filename);
    }

    pub fn fromCache(self: *Self, filename: []const u8) !Template {
        if (self.template_caches.get(filename)) |t| {
            return t;
        }

        const t = try self.getTemplate(filename);
        try self.template_caches.put(self.gpa, filename, t);

        return t;
    }

    pub fn cleanCache(self: *Self) void {
        self.template_caches.clearAndFree(self.gpa);
    }

    pub fn render(self: *Self, filename: []const u8, context: Value) ![]u8 {
        var tmpl = try self.getTemplate(filename);
        defer tmpl.deinit();

        return tmpl.render(context);
    }

    fn hasFilterThunk(ctx: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.filters.contains(name);
    }

    fn hasTestThunk(ctx: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.tests.contains(name);
    }

    fn hasGlobalThunk(ctx: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.globals.contains(name);
    }

    fn hasGlobalValueThunk(ctx: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.global_values.contains(name);
    }

    fn hasMethodThunk(ctx: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.methods.contains(name);
    }

    fn hasTagThunk(ctx: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.tags.contains(name);
    }

    fn filterLookup(ctx: *const anyopaque, name: []const u8) ?FilterFn {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.filters.get(name);
    }

    fn testLookup(ctx: *const anyopaque, name: []const u8) ?TestFn {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.tests.get(name);
    }

    fn globalLookup(ctx: *const anyopaque, name: []const u8) ?GlobalFn {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.globals.get(name);
    }

    fn globalValueLookup(ctx: *const anyopaque, name: []const u8) ?Value {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.global_values.get(name);
    }

    fn methodLookup(ctx: *const anyopaque, name: []const u8) ?MethodFn {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.methods.get(name);
    }

    fn tagLookup(ctx: *const anyopaque, name: []const u8) ?TagFn {
        const self: *const Environment = @ptrCast(@alignCast(ctx));
        return self.tags.get(name);
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
            .delimiters = self.options.delimiters,
        }, diag);

        return parser.parse(arena, lexed.pieces, .{
            .ctx = self,
            .hasFilter = hasFilterThunk,
            .hasTest = hasTestThunk,
            .hasGlobal = hasGlobalThunk,
            .hasMethod = hasMethodThunk,
            .hasTag = hasTagThunk,
            .hasGlobalValue = hasGlobalValueThunk,
            .tag = tagLookup,
        }, .{ .max_nesting_depth = self.options.max_nesting_depth }, diag);
    }
};

/// A compiled template: an arena holding the source copy and the tree, plus a
/// borrowed pointer to the environment that compiled it. Immutable after
/// compilation, so one template may be rendered from several threads at once
/// (each render allocates its own scratch arena).
pub const Template = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    io: Io,
    parsed: ast.Parsed,
    env: *const Environment,
    template_name: []const u8 = "<string>",
    diag: ?*Diagnostic = null,

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn withDiag(self: *Template, diag: *Diagnostic) void {
        self.diag = diag;
    }

    pub fn getError(self: Template) ![]const u8 {
        if (self.diag) |d| {
            const err = try self.gpa.print("{f}", .{d});
            return err;
        }

        return "";
    }

    /// Render to a freshly allocated buffer owned by the caller.
    pub fn render(self: *Template, context: Value) RenderError![]u8 {
        var aw: Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();

        try self.renderTo(&aw.writer, context);
        return aw.toOwnedSlice() catch error.OutOfMemory;
    }

    /// Execute to a freshly allocated buffer owned by the caller.
    pub fn execute(self: *Template, context: Value) RenderError![]u8 {
        return self.render(context);
    }

    /// Render into `out` backs a scratch arena that is released before
    /// this returns, so intermediate values never outlive the call.
    pub fn renderTo(self: *Template, out: *Writer, context: Value) RenderError!void {
        var scratch: Diagnostic = .{};
        const d = self.diag orelse &scratch;

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();

        var budget: RenderBudget = .{
            .parent = arena.allocator(),
            .remaining = self.env.options.max_render_bytes,
        };

        renders.render(budget.allocator(), self.io, self.parsed, context, .{
            .autoescape = self.env.options.autoescape,
            .undefined_policy = self.env.options.undefined_policy,
            .max_output_bytes = self.env.options.max_output_bytes,
            .max_template_depth = self.env.options.max_template_depth,
            .max_call_depth = self.env.options.max_call_depth,
            .max_templates = self.env.options.max_templates,
            .max_while_iterations = self.env.options.max_while_iterations,
            .template_name = self.template_name,
        }, .{
            .ctx = self.env,
            .filter = Environment.filterLookup,
            .test_fn = Environment.testLookup,
            .global = Environment.globalLookup,
            .method = Environment.methodLookup,
            .global_value = Environment.globalValueLookup,
            .loader = self.env.loader,
            .compile = Environment.compileInto,
        }, out, d) catch |e| {
            // An exhausted budget arrives as `OutOfMemory` because that is the
            // only thing an allocator may report. Reporting it as `OutOfMemory`
            // to the caller would be the same misclassification a real OOM is
            // not: the machine has memory, this render asked for too much.
            if (e == error.OutOfMemory and budget.exhausted) {
                d.with(0, "render exceeded max_render_bytes ({d})", .{self.env.options.max_render_bytes});
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

    fn alloc(ctx: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
        const self: *RenderBudget = @ptrCast(@alignCast(ctx));
        if (!self.take(len)) return null;
        return self.parent.rawAlloc(len, a, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, a: Alignment, new_len: usize, ra: usize) bool {
        const self: *RenderBudget = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.take(new_len - memory.len)) return false;
        return self.parent.rawResize(memory, a, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *RenderBudget = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.take(new_len - memory.len)) return null;
        return self.parent.rawRemap(memory, a, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, a: Alignment, ra: usize) void {
        const self: *RenderBudget = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, a, ra);
    }
};

pub const RenderOpts = struct {
    options: Options = .{},
    io: ?Io = null,
    diag: ?*Diagnostic = null,
};

/// The one-liner: default options, compile and render, caller owns the result.
pub fn render(
    gpa: Allocator,
    source: []const u8,
    context: Value,
    opts: RenderOpts,
) Error![]u8 {
    var env = try Environment.init(gpa, opts.options);
    defer env.deinit();

    if (opts.io) |io| env.withIo(io);
    if (opts.diag) |d| env.withDiag(d);

    return env.execute(source, context);
}

test {
    _ = @import("value.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("ast.zig");
    _ = @import("render.zig");
    _ = @import("args.zig");
    _ = @import("diag.zig");
    _ = @import("engine_test.zig");
    _ = @import("reference_test.zig");
    _ = @import("loader.zig");
    _ = @import("loader_test.zig");
    _ = @import("vin_test.zig");
}

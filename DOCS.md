```zig
var env = try vin.Environment.init(gpa, .{});
defer env.deinit();

var tmpl = try env.compile(
    \\interface {{ name }}
    \\{%- for v in vlans %}
    \\ switchport trunk allowed vlan add {{ v }}
    \\{%- endfor %}
, null);
defer tmpl.deinit();

var arena: std.heap.ArenaAllocator = .init(gpa);
defer arena.deinit();
const ctx = try vin.valueFrom(arena.allocator(), .{
    .name = "Gi1/0/1",
    .vlans = [_]u16{ 10, 20, 30 },
});
const out = try tmpl.render(gpa, ctx, null);
defer gpa.free(out);
```

## What is covered

`{{ … }}`, `{# … #}`, `{% if/elif/else %}`, `{% for %}` (with the full
`loop` object, an inline `if` filter, `{% else %}` and `recursive`),
`{% set %}` in both inline and block form, `{% filter %}`, `{% with %}`,
`{% do %}`, `{% raw %}`, the whole expression grammar including chained
comparisons, conditional expressions, slices, filters and tests, and every
whitespace control (`{%-`, `-%}`, `trim_blocks`, `lstrip_blocks`,
`keep_trailing_newline`).

Template composition needs a `Loader` (`Environment.initWithLoader`):
`{% extends %}` + `{% block %}` with `super()`, `scoped`, `required` and
`{{ self.name() }}`; `{% include %}` with `ignore missing`,
`with`/`without context` and candidate lists; `{% import %}` and
`{% from … import … as … %}`; `{% macro %}` with defaults, `varargs`,
`kwargs` and introspection attributes; `{% call %}` / `caller()`. Without a
loader those tags are `error.NoLoader`, never a quiet nothing. What remains
unimplemented (i18n, the `{% autoescape %}` block, eight filters) is a
compile error naming it.

## Two things a caller must decide, and this module refuses to guess

**Undefined.** The default here is `.strict`: using a variable the context
does not have is an error. The reference implementation's default is the
opposite, and renders empty. For the workload this module exists for —
generating device configuration — an empty string where an address belonged
is worse than a failed render, so the default is inverted deliberately. Pass
`.undefined_policy = .lenient` for the reference's behaviour. Documented as
divergence D1 in SPEC.md.

**Autoescaping.** Off unless `.autoescape = true`. There is no guessing from
a file extension (this module has no file loader), and `|safe`/`|escape`
behave as markupsafe's `Markup` does in both settings.

# =================

A Jinja2-compatible template engine in pure Zig. It takes a template string and
a context value and produces bytes: `{{ expression }}` output, `{# comments #}`,
`{% if %}` / `{% for %}` / `{% set %}` / `{% filter %}` / `{% with %}` /
`{% do %}` / `{% raw %}` statements, template composition (`{% extends %}` +
`{% block %}` with `super()`, `scoped` and `required`; `{% include %}`;
`{% import %}` / `{% from … import … %}`; `{% macro %}` and `{% call %}` /
`caller()`), the full Jinja expression grammar (chained comparisons, conditional
expressions, slices, list/dict literals, filters, tests and method calls), 46
built-in filters, 29 built-in tests, the complete `loop` object including
`{% for … recursive %}`, `namespace()`, and every whitespace control the
reference implementation has. Semantics follow Python, not C: `/` always yields a float, `//` and `%`
floor (`-7 % 2 == 1`), `round` is banker's rounding of the value's exact binary
magnitude, and values print with CPython's `repr` — `True`, `None`, `1.0`,
`['a', 1]`, `('a', 1)`, `{'a': 1}`. It is built for generating configuration
(device configs, unit files, manifests), so the two decisions that quietly
corrupt such output — what happens to an undefined variable, and whether output
is HTML-escaped — are explicit options rather than defaults you discover in
production.

Anything the reference has that this does not — i18n (`{% trans %}`), the
`{% autoescape %}` block, eight filters, four tests, three globals — is a
**compile error naming the tag or name**, never a silent no-op. `SPEC.md` §6
lists every one.


## The context

A context is a `vin.Value`. Three ways to build one, none of which requires a
second value type in your program:

```zig
// 1. Zig data, reflected at comptime. Structs become ORDERED maps in field
//    order, `[]const u8` is a string, slices/arrays are lists, `?T` is None
//    when null, enums are their tag name.
const ctx = try vin.valueFrom(arena, .{ .name = "eth0", .vlans = [_]u16{ 10, 20 } });

// 2. std.json.Value — std only, so no module dependency.
const parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
const ctx = try vin.valueFromJson(arena, parsed.value);

// 3. Hand-built, when you want exact control (including markup-safe strings).
const ctx: vin.Value = .{ .map = .{ .pairs = &.{
    .{ .key = vin.Value.str("name"), .value = vin.Value.str("eth0") },
} } };
```

Maps are **ordered pair slices**, so the order you supply keys in is the order
`{% for k in d %}` walks them and `{{ d }}` prints them.

### Using it with the `yaml` module

`vin` deliberately depends on nothing but std (see `SPEC.md` §2). A context
from `modules/yaml` is a twenty-line conversion, and ordering survives it
because both sides keep mappings as ordered pairs:

```zig
fn fromYaml(arena: std.mem.Allocator, v: yaml.Value) !vin.Value {
    return switch (v) {
        .null => .none,
        .bool => |b| .{ .boolean = b },
        .int => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| vin.Value.str(s),
        .sequence => |seq| blk: {
            const items = try arena.alloc(vin.Value, seq.len);
            for (seq, 0..) |e, i| items[i] = try fromYaml(arena, e);
            break :blk .{ .list = items };
        },
        .mapping => |m| blk: {
            const pairs = try arena.alloc(vin.Pair, m.len);
            for (m, 0..) |p, i| pairs[i] = .{
                .key = try fromYaml(arena, p.key),
                .value = try fromYaml(arena, p.value),
            };
            break :blk .{ .map = .{ .pairs = pairs } };
        },
    };
}
```

## Options

| Option | Default | Meaning |
|---|---|---|
| `undefined_policy` | **`.strict`** | `.strict`: any *use* of a missing variable is an error. `.lenient`: the reference implementation's default `Undefined` — renders empty, is falsey, iterates empty, but errors on attribute access and arithmetic. |
| `autoescape` | `false` | HTML-escape every rendered value that is not marked safe. |
| `trim_blocks` | `false` | Drop the first newline after a statement or comment tag. |
| `lstrip_blocks` | `false` | Strip leading whitespace from line start to a statement or comment tag. |
| `keep_trailing_newline` | `false` | Keep the template's final newline. |
| `max_output_bytes` | 64 MiB | Ceiling on rendered output; a runaway loop fails loudly. |
| `max_template_depth` | 32 | Combined `{% extends %}`/`{% include %}`/`{% import %}` nesting bound. |
| `max_call_depth` | 64 | Macro, `{% call %}` and `loop()` recursion bound. |
| `max_templates` | 256 | Distinct templates one render may load. |
| `max_nesting_depth` | 256 | How deep one template's syntax may nest — brackets, `not`/unary chains, `else` arms, each link of a `1+1+1`/`x\|f\|g`/`a.b.c` chain, each nested block body, each `{% elif %}`. Refused at compile time as `error.TooDeep`, which also bounds the recursive evaluator. Bounds the **syntax** tree only; `value.max_value_depth` (256) bounds how deep a *value* may be walked. |
| `max_render_bytes` | 256 MiB | Total scratch one render may take. The depth caps bound depth and the `value.zig` caps bound one operation; neither bounds total work, and a macro fan-out well inside `max_call_depth` took 3.8 GB while emitting nothing. `error.RenderBudgetExceeded`. |

**The `.strict` default inverts the reference implementation's.** That is
deliberate and is the module's one behavioural divergence in the default path:
for configuration output, an empty string where an IP address belonged is worse
than a failed render. Pass `.undefined_policy = .lenient` to get the reference's
behaviour on attribute access and arithmetic; a few operations still refuse an
undefined value under both policies (`~`, `|length`), which SPEC's divergence
table names. `x is defined`, `x is undefined` and `x|default(…)` keep
working under both policies.

Autoescaping is off unless you ask for it, and there is no guessing from a file
extension (this module has no loader). With it on, `|safe` marks a string as
markup, `|escape` produces markup, and markup propagates through `~`, `+`,
`|join` and the case-changing filters exactly as markupsafe's `Markup` does. A
filter *argument* spliced into a markup result is escaped first, so `|safe` is
the only thing that puts context data in the output raw — with one inherited
exception, `|indent` with a string width, which the reference splices raw too
(SPEC §5).

## Composition

Everything that needs a second template needs a **loader** — without one, every
composition tag is `error.NoLoader` rather than a quiet nothing:

```zig
var map: vin.MapLoader = .{ .entries = &.{
    .{ .name = "base",   .source = @embedFile("templates/base.j2") },
    .{ .name = "macros", .source = @embedFile("templates/macros.j2") },
} };
var env = try vin.Environment.initWithLoader(gpa, .{}, map.loader());
```

```vin
{% extends 'base' %}
{% import 'macros' as m %}
{% block interfaces %}
{% for i in interfaces %}{{ m.iface(i.name, i.addr, i.mask) }}{% endfor %}
{% endblock %}
{% block routing %}{{ super() }}
ip routing
{% endblock %}
```

Supported in full: multi-level `{% extends %}` chains with a computed
(non-literal) parent name, `{% block %}` with `super()`, nesting, `scoped` and
`required`, `{{ self.blockname() }}`, `{% include %}` with `ignore missing`,
`with`/`without context` and a list of candidates, `{% import %}` and
`{% from … import … as … %}`, `{% macro %}` with defaults, `varargs`, `kwargs`
and the `name`/`arguments`/`catch_varargs`/`catch_kwargs`/`caller` introspection
attributes, and `{% call(args) %}` / `caller()`.

Four behaviours are worth knowing because guessing them wrong is easy — all four
are pinned against the reference:

- **`{% include %}` defaults to *with* context; `{% import %}` defaults to
  *without*.** An included template sees everything currently in scope,
  including loop variables; an imported one sees nothing at all — not even the
  render context — unless you write `with context`.
- **`import … with context` is a snapshot, not a live view.** A `{% set %}`
  *after* the import is not visible to the imported macros.
- **A block does not see the loop it sits in.** `{% block x %}` inside a
  `{% for %}` renders with the loop variable *undefined*; `{% block x scoped %}`
  is the opt-in.
- **A child template's top-level `{% set %}` still runs.** Its output is
  discarded, but the assignment is visible to every block — which is how
  `{% set which = 'b' %}{% extends which %}` works at all.

## Loaders

```zig
pub const Loader = struct {
    ctx: *const anyopaque,
    /// Source for `name` from `arena`, or null when there is no such template.
    load: *const fn (ctx: *const anyopaque, arena, name: []const u8) LoaderError!?[]const u8,
};
```

`null` means "absent" and drives `ignore missing` and the candidate-list form;
an error means "the loader refused or failed". Two are shipped:

- **`MapLoader`** — a slice of `{ name, source }`, which can be a comptime
  constant. The natural choice for `@embedFile`d template sets and for tests.
- **`DirLoader`** — a directory, and **contained within it**. Name validation
  refuses absolute paths, `..`, `.`, backslashes, NULs and empty components;
  then the path is walked one component at a time with `follow_symlinks = false`
  on every open, so no symlink anywhere along it is traversed and no re-resolved
  string is ever handed back to the kernel. `resolve_beneath` is requested too,
  where the platform has it. See `SPEC.md` §10 for the guarantee, the two
  deliberate strictnesses, and the one thing it does not promise.

```zig
var dl: vin.DirLoader = .{
    .io = io,
    .root = try std.Io.Dir.cwd().openDir(io, "templates", .{}),
    .options = .{ .suffix = ".j2", .max_bytes = 1 << 20 },
};
var env = try vin.Environment.initWithLoader(gpa, .{}, dl.loader());
```

A caller's own loader is just a `Loader` — reuse `vin.checkTemplateName` if it
touches a filesystem.

Cycles and runaway expansion are bounded structurally, not by hoping: an
inheritance cycle is caught by *name* while the chain is built, and include /
import nesting, macro recursion and `loop()` recursion each hit a depth cap.
`SPEC.md` §10 names the tests that fire the bombs.

## Whitespace control

`{%-`/`-%}`, `{{-`/`-}}` and `{#-`/`-#}` strip all whitespace on that side;
`{%+`/`+%}` disables `trim_blocks`/`lstrip_blocks` for that one side. A `-`
always wins over the environment options.

```vin
interface {{ i }}
{%- for v in vlans %}
 vlan {{ v }}
{%- endfor %}
```

## Filters

All 46 resolve at **compile time** when the template names one directly: a
template naming a filter that is not here fails `env.compile`, with a
diagnostic. The exception is a filter or test named by a *string argument* to
`map`, `select`, `reject`, `selectattr` or `rejectattr` — `{{ xs|map('nope') }}`
is resolved during the render, as it is in the reference, and surfaces as
`error.BadArgument`. The earlier wording here said resolution "can never
surface halfway through a render", which was a false absolute.

| | | | |
|---|---|---|---|
| `abs` | `batch` | `capitalize` | `center` |
| `count` | `d` | `default` | `dictsort` |
| `e` | `escape` | `first` | `float` |
| `forceescape` | `indent` | `int` | `items` |
| `join` | `last` | `length` | `list` |
| `lower` | `map` | `max` | `min` |
| `reject` | `rejectattr` | `replace` | `reverse` |
| `round` | `safe` | `select` | `selectattr` |
| `slice` | `sort` | `string` | `striptags` |
| `sum` | `title` | `tojson` | `trim` |
| `truncate` | `unique` | `upper` | `urlencode` |
| `wordcount` | `xmlattr` | | |

Keyword arguments work as in the reference (`sort(reverse=true,
attribute='n')`, `join(', ', attribute='name')`, `default('x', true)`,
`round(2, 'ceil')`, `map(attribute='n', default=0)`, `tojson(2)`). `sort`,
`min`, `max`, `unique` and `dictsort` are case-**insensitive** by default, as
there.

Filters deliberately **not** implemented — `attr`, `filesizeformat`, `format`,
`groupby`, `pprint`, `random`, `urlize`, `wordwrap` — and why, are listed in
`SPEC.md` §6.

### Registering your own

```zig
try env.addFilter("netmask", struct {
    fn f(ctx: *vin.FilterCtx, input: vin.Value, args: vin.FilterArgs) vin.FilterError!vin.Value {
        _ = args;
        const bits = switch (input) { .integer => |i| i, else => return error.TypeMismatch };
        // ctx.arena is the render arena; ctx.toStr(v) honours the undefined policy.
        const s = try std.fmt.allocPrint(ctx.arena, "/{d}", .{bits});
        return vin.Value.str(s);
    }
}.f);
```

`env.addTest` takes the same shape returning `bool`. Register before compiling —
name resolution happens at compile time.

## Tests

`boolean` · `defined` · `divisibleby` · `eq` · `equalto` · `escaped` · `even` ·
`false` · `float` · `ge` · `greaterthan` · `gt` · `in` · `integer` ·
`iterable` · `le` · `lessthan` · `lower` · `lt` · `mapping` · `ne` · `none` ·
`number` · `odd` · `sequence` · `string` · `true` · `undefined` · `upper`

Both call forms work: `x is divisibleby(3)` and `x is divisibleby 3`, and
`is not` negates.

## Globals and methods

Globals: `range(stop)` / `range(start, stop[, step])`, `dict(k=v, …)`,
`namespace(k=v, …)`.

`namespace()` is the way to accumulate across a `{% for %}` body, because a
`{% set %}` inside a loop does not outlive the loop (that is the reference's
scoping, reproduced exactly):

```vin
{% set ns = namespace(total=0) %}
{% for x in values %}{% set ns.total = ns.total + x %}{% endfor %}
{{ ns.total }}
```

Methods on values: strings have `upper` `lower` `title` `capitalize` `strip`
`lstrip` `rstrip` `split` `splitlines` `startswith` `endswith` `replace`
`count` `find` `join` `isdigit` `isalpha` `removeprefix` `removesuffix`; maps
have `items` `keys` `values` `get`; lists have `count` `index`; `loop` has
`cycle` and `changed`.

## Diagnostics

```zig
var diag: vin.Diagnostic = .{};
var tmpl = env.compile(src, &diag) catch {
    std.debug.print("template error: {f}\n", .{&diag});   // "line 12: unknown filter — …"
    return;
};
const out = tmpl.render(gpa, ctx, &diag) catch {
    std.debug.print("render error: {f}\n", .{&diag});     // "line 4: 'address' is undefined"
    return;
};
```

`Diagnostic` owns a fixed buffer, so a message stays valid after the template
and the render arena are gone.


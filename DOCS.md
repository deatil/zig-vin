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
compile error naming it — see SPEC.md §6.

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

## Zig-vin 

A template library like jinja for zig.


### Env

 - Zig >= 0.17.0


### Adding zig-vin as a dependency

Add the dependency to your project:

```sh
zig fetch --save=zig-vin git+https://github.com/deatil/zig-vin#main
```

or use local path to add dependency at `build.zig.zon` file

```zig
.{
    .dependencies = .{
        .@"zig-vin" = .{
            .path = "./lib/zig-vin",
        },
        ...
    },
    ...
}
```

And the following to your `build.zig` file:

```zig
    const zig_vin_dep = b.dependency("zig-vin", .{});
    exe.root_module.addImport("zig-vin", zig_vin_dep.module("zig-vin"));
```

The `zig-vin` structure can be imported in your application with:

```zig
const vin = @import("zig-vin");
```


### Get Starting

~~~zig
const std = @import("std");
const vin = @import("zig-vin");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    var env = try vin.Environment.init(alloc, .{
        .trim_blocks = true,
        .lstrip_blocks = true,
    });
    defer env.deinit();

    var tmpl = try env.compile(
        \\hostname {{ host }}
        \\!
        \\{% for i in interfaces %}
        \\interface {{ i.name }}
        \\ ip address {{ i.address }} {{ i.mask }}
        \\ {{ 'shutdown' if i.shutdown else 'no shutdown' }}
        \\!
        \\{% endfor %}
    , null);
    defer tmpl.deinit();

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const ctx = try vin.valueFrom(arena.allocator(), .{
        .host = "sw1",
        .interfaces = [_]struct {
            name: []const u8,
            address: []const u8,
            mask: []const u8,
            shutdown: bool,
        }{
            .{ .name = "Gi0/1", .address = "196.56.0.1", .mask = "255.255.255.0", .shutdown = false },
        },
    });

    const out = try tmpl.render(alloc, ctx, null);
    defer alloc.free(out);
}
~~~


### LICENSE

*  The library LICENSE is `Apache2`, using the library need keep the LICENSE.


### Copyright

*  Copyright deatil(https://github.com/deatil).

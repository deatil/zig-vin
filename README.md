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

    const tpl = 
        \\hostname {{ host }}
        \\!
        \\{% for i in interfaces %}
        \\interface {{ i.name }}
        \\ ip address {{ i.address }} {{ i.mask }}
        \\ {{ 'shutdown' if i.shutdown else 'no shutdown' }}
        \\!
        \\{% endfor %}
    ;

    const ctx = try vin.valueFrom(alloc, .{
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

    var env = try vin.Environment.init(alloc, .{
        .trim_blocks = true,
        .lstrip_blocks = true,
    });
    defer env.deinit();

    var diag: vin.Diagnostic = undefined;

    const out = try env.renderAlloc(alloc, tpl, ctx, &diag);
    defer alloc.free(out);

    const err_msg = try alloc.print("{f}", .{diag});
    if (err_msg.len > 0) {
        std.debug.print("error: {s} \n", .{err_msg});
        return;
    }

    std.debug.print("html: {s} \n", .{out});
}
~~~


### Use DirLoader

~~~zig
const std = @import("std");
const vin = @import("zig-vin");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    const ctx = try vin.valueFrom(alloc, .{
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

    const dl: *vin.DirLoader = try .create(
        a, io, 
        try std.Io.Dir.cwd().openDir(io, "views", .{}), 
        .{ 
            .suffix = ".htm",
        },
    );

    var env = try vin.Environment.initWithLoader(alloc, .{
        .trim_blocks = true,
        .lstrip_blocks = true,
    }, dl.loader());
    defer env.deinit();

    var diag: vin.Diagnostic = undefined;

    const out = try env.renderTemplateAlloc(alloc, tpl, ctx, &diag);
    defer alloc.free(out);

    const err_msg = try alloc.print("{f}", .{diag});
    if (err_msg.len > 0) {
        std.debug.print("error: {s} \n", .{err_msg});
        return;
    }

    std.debug.print("html: {s} \n", .{out});
}
~~~


### LICENSE

*  The library LICENSE is `Apache2`, using the library need keep the LICENSE.


### Copyright

*  Copyright deatil(https://github.com/deatil).

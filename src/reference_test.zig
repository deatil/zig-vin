const std = @import("std");
const testing = std.testing;
const conform = @import("conform.zig");

const golden_json = @embedFile("testdata/golden.json");

const min_cases = 351;

fn parseGolden(gpa: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, golden_json, .{});
}

test "replay: every recorded case matches the reference's output byte for byte" {
    const gpa = testing.allocator;
    var parsed = try parseGolden(gpa);
    defer parsed.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const cases = parsed.value.object.get("cases").?.array.items;
    var failures: usize = 0;
    for (cases) |entry| {
        const c = try conform.caseFromJson(arena.allocator(), entry);
        conform.expectMatch(gpa, c, conform.refFromJson(entry), "replay") catch {
            failures += 1;
        };
    }
    if (failures != 0) {
        std.debug.print("\nreplay: {d} of {d} cases failed\n", .{ failures, cases.len });
        return error.ReferenceMismatch;
    }
}

test "replay: the transcript still covers the whole corpus" {
    const gpa = testing.allocator;
    var parsed = try parseGolden(gpa);
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;

    if (cases.len < min_cases) {
        std.debug.print(
            "\nthe transcript holds {d} cases, down from {d} — coverage shrank\n",
            .{ cases.len, min_cases },
        );
        return error.CoverageShrank;
    }

    // Names are the key the transcript is read back by, and a duplicate would
    // silently halve what one of them asserts.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for (cases) |c| {
        const gop = try seen.getOrPut(gpa, c.object.get("name").?.string);
        try testing.expect(!gop.found_existing);
    }
}

test "replay: every recorded case carries the inputs it was rendered from" {
    const gpa = testing.allocator;
    var parsed = try parseGolden(gpa);
    defer parsed.deinit();

    var with_loader: usize = 0;
    var expecting_error: usize = 0;
    var autoescaped: usize = 0;
    for (parsed.value.object.get("cases").?.array.items) |c| {
        inline for (.{ "name", "template", "context", "templates", "status" }) |k| {
            if (c.object.get(k) == null) {
                std.debug.print("\ntranscript entry is missing '{s}'\n", .{k});
                return error.MissingInput;
            }
        }
        inline for (.{ "autoescape", "strict", "trim_blocks", "lstrip_blocks", "keep_trailing_newline", "expect_error" }) |k| {
            _ = c.object.get(k).?.bool;
        }
        if (c.object.get("templates").?.object.count() != 0) with_loader += 1;
        if (c.object.get("expect_error").?.bool) expecting_error += 1;
        if (c.object.get("autoescape").?.bool) autoescaped += 1;
    }

    try testing.expect(with_loader >= 50);
    try testing.expect(expecting_error >= 30);
    try testing.expect(autoescaped >= 35);

    // `expect_error` must describe the transcript, not merely sit in it: every
    // case the corpus marks has to be one the reference actually refused.
    var refused: usize = 0;
    for (parsed.value.object.get("cases").?.array.items) |c| {
        if (std.mem.eql(u8, c.object.get("status").?.string, "error")) {
            try testing.expect(c.object.get("expect_error").?.bool);
            refused += 1;
        }
    }
    try testing.expectEqual(expecting_error, refused);
}


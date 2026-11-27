const std = @import("std");
const Writer = std.Io.Writer;

pub const Diagnostic = struct {
    filename: []const u8 = "",
    /// 1-based line in the template source; 0 when unknown.
    line: usize = 0,
    buf: [512]u8 = undefined,
    len: usize = 0,
    /// if stop is true, the set wiil return
    stop: bool = false,

    pub fn withFilename(self: *Diagnostic, filename: []const u8) void {
        self.filename = filename;
    }

    pub fn with(self: *Diagnostic, line: usize, comptime fmt: []const u8, args: anytype) void {
        self.line = line;
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            break :blk self.buf[0..self.buf.len];
        };
        self.len = s.len;
    }

    pub fn setFilename(self: *Diagnostic, filename: []const u8) void {
        if (self.stop) return;
        self.filename = filename;
    }

    pub fn set(self: *Diagnostic, line: usize, comptime fmt: []const u8, args: anytype) void {
        if (self.stop) return;

        self.line = line;
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            break :blk self.buf[0..self.buf.len];
        };
        self.len = s.len;
        self.stop = true;
    }

    pub fn message(self: *const Diagnostic) []const u8 {
        const len: usize = if (self.len < 512) self.len else 511;
        return self.buf[0..len];
    }

    pub fn format(self: *const Diagnostic, writer: *Writer) Writer.Error!void {
        if (self.filename.len > 0) {
            try writer.print("line {d}: in template '{s}': {s}", .{ self.line, self.filename, self.message() });
        }

        try writer.print("line {d}: {s}", .{ self.line, self.message() });
    }
};

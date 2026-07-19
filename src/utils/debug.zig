//! Debugging utilities for zregex
//!
//! This module provides debugging helpers including hex dumps,
//! bytecode dumping, pretty printing, and conditional logging.

const std = @import("std");
const config = @import("../core/config.zig");

/// Print a hex dump of a byte buffer
pub fn hexDump(writer: anytype, data: []const u8, offset: usize) !void {
    const bytes_per_line = 16;
    var i: usize = 0;

    while (i < data.len) {
        // Print offset
        try writer.print("{x:08}: ", .{offset + i});

        // Print hex bytes
        var j: usize = 0;
        while (j < bytes_per_line) : (j += 1) {
            if (i + j < data.len) {
                try writer.print("{x:02} ", .{data[i + j]});
            } else {
                try writer.writeAll("   ");
            }

            // Extra space in the middle
            if (j == 7) try writer.writeByte(' ');
        }

        try writer.writeAll(" |");

        // Print ASCII representation
        j = 0;
        while (j < bytes_per_line and i + j < data.len) : (j += 1) {
            const c = data[i + j];
            if (std.ascii.isPrint(c)) {
                try writer.writeByte(c);
            } else {
                try writer.writeByte('.');
            }
        }

        try writer.writeAll("|\n");
        i += bytes_per_line;
    }
}

/// Print a compact hex dump (single line)
pub fn hexDumpCompact(writer: anytype, data: []const u8) !void {
    for (data, 0..) |byte, i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.print("{x:02}", .{byte});
    }
}

/// Conditional debug print (only in debug builds)
pub fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (config.enable_execution_trace) {
        std.debug.print(fmt, args);
    }
}

/// Assert with custom message
pub fn assertMsg(condition: bool, comptime msg: []const u8) void {
    if (!condition) {
        if (config.panic_on_internal_error) {
            @panic(msg);
        } else {
            std.debug.print("Assertion failed: {s}\n", .{msg});
        }
    }
}

/// Print a divider line
pub fn printDivider(writer: anytype, length: usize) !void {
    for (0..length) |_| {
        try writer.writeByte('-');
    }
    try writer.writeByte('\n');
}

/// Print a section header
pub fn printSection(writer: anytype, title: []const u8) !void {
    try printDivider(writer, 60);
    try writer.print("  {s}\n", .{title});
    try printDivider(writer, 60);
}

/// Format bytes as human-readable size
pub fn formatSize(bytes: usize) []const u8 {
    if (bytes < 1024) {
        return std.fmt.comptimePrint("{} B", .{bytes});
    } else if (bytes < 1024 * 1024) {
        return std.fmt.comptimePrint("{d:.2} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    } else if (bytes < 1024 * 1024 * 1024) {
        return std.fmt.comptimePrint("{d:.2} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    } else {
        return std.fmt.comptimePrint("{d:.2} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)});
    }
}

/// Print a simple progress bar
pub fn printProgress(writer: anytype, current: usize, total: usize, width: usize) !void {
    if (total == 0) return;

    const percent = (@as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(total))) * 100.0;
    const filled = (@as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(total))) * @as(f64, @floatFromInt(width));
    const filled_int = @as(usize, @intFromFloat(filled));

    try writer.writeByte('[');

    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled_int) {
            try writer.writeByte('=');
        } else if (i == filled_int) {
            try writer.writeByte('>');
        } else {
            try writer.writeByte(' ');
        }
    }

    try writer.print("] {d:.1}% ({}/{})\n", .{ percent, current, total });
}

/// Placeholder for bytecode dumping (will be implemented in Phase 2)
pub fn dumpBytecode(writer: anytype, bytecode: []const u8) !void {
    try writer.writeAll("Bytecode dump:\n");
    try hexDump(writer, bytecode, 0);
}

/// Print a tree-like structure
pub const TreePrinter = struct {
    writer: *std.Io.Writer,
    indent_level: usize,
    use_unicode: bool,

    const Self = @This();

    pub fn init(writer: *std.Io.Writer, use_unicode: bool) Self {
        return .{
            .writer = writer,
            .indent_level = 0,
            .use_unicode = use_unicode,
        };
    }

    pub fn indent(self: *Self) !void {
        for (0..self.indent_level) |_| {
            if (self.use_unicode) {
                try self.writer.writeAll("│   ");
            } else {
                try self.writer.writeAll("|   ");
            }
        }
    }

    pub fn node(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.indent();
        if (self.use_unicode) {
            try self.writer.writeAll("├── ");
        } else {
            try self.writer.writeAll("+-- ");
        }
        try self.writer.print(fmt, args);
        try self.writer.writeByte('\n');
    }

    pub fn lastNode(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.indent();
        if (self.use_unicode) {
            try self.writer.writeAll("└── ");
        } else {
            try self.writer.writeAll("`-- ");
        }
        try self.writer.print(fmt, args);
        try self.writer.writeByte('\n');
    }

    pub fn push(self: *Self) void {
        self.indent_level += 1;
    }

    pub fn pop(self: *Self) void {
        if (self.indent_level > 0) {
            self.indent_level -= 1;
        }
    }
};

/// Memory arena for temporary debug strings
pub const DebugArena = struct {
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(parent_allocator: std.mem.Allocator) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn reset(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "hexDump: basic output" {
    const data = "Hello, World!\x00\x01\x02";
    const allocator = std.testing.allocator;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try hexDump(&aw.writer, data, 0);

    const output = aw.written();

    // Should contain hex offset
    try std.testing.expect(std.mem.indexOf(u8, output, "00000000:") != null);

    // Should contain hex bytes
    try std.testing.expect(std.mem.indexOf(u8, output, "48") != null); // 'H'

    // Should contain ASCII representation
    try std.testing.expect(std.mem.indexOf(u8, output, "|Hello") != null);
}

test "hexDumpCompact: single line" {
    const data = "\x01\x02\x03\x04";
    const allocator = std.testing.allocator;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try hexDumpCompact(&aw.writer, data);

    const output = aw.written();
    try std.testing.expectEqualStrings("01 02 03 04", output);
}

test "printDivider" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try printDivider(&aw.writer, 10);

    try std.testing.expectEqualStrings("----------\n", aw.written());
}

test "printSection" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try printSection(&aw.writer, "Test Section");

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "Test Section") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "---") != null);
}

test "printProgress" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try printProgress(&aw.writer, 50, 100, 20);

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "50.0%") != null);
}

test "TreePrinter: basic usage" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var printer = TreePrinter.init(&aw.writer, false);

    try printer.node("Root", .{});
    printer.push();
    try printer.node("Child 1", .{});
    try printer.lastNode("Child 2", .{});
    printer.pop();

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "+-- Root") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Child 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Child 2") != null);
}

test "TreePrinter: unicode" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var printer = TreePrinter.init(&aw.writer, true);

    try printer.node("Root", .{});
    printer.push();
    try printer.lastNode("Child", .{});
    printer.pop();

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "├── Root") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "└── Child") != null);
}

test "TreePrinter: nested levels" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var printer = TreePrinter.init(&aw.writer, false);

    try printer.node("Level 1", .{});
    printer.push();
    try printer.node("Level 2", .{});
    printer.push();
    try printer.lastNode("Level 3", .{});
    printer.pop();
    printer.pop();

    const output = aw.written();
    try std.testing.expect(output.len > 0);
}

test "DebugArena: basic usage" {
    var arena = DebugArena.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // Allocate some strings
    const str1 = try allocator.dupe(u8, "test1");
    const str2 = try allocator.dupe(u8, "test2");

    try std.testing.expectEqualStrings("test1", str1);
    try std.testing.expectEqualStrings("test2", str2);

    // Reset doesn't free, just resets the arena
    arena.reset();

    // Can allocate again
    const str3 = try allocator.dupe(u8, "test3");
    try std.testing.expectEqualStrings("test3", str3);
}

test "debugPrint: compiles" {
    // This test just ensures debugPrint compiles
    debugPrint("Test message: {}\n", .{42});
}

test "assertMsg: compiles" {
    // This test just ensures assertMsg compiles
    assertMsg(true, "This should not panic");
}

test "dumpBytecode: placeholder" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const bytecode = "\x01\x02\x03\x04";
    try dumpBytecode(&aw.writer, bytecode);

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "Bytecode dump") != null);
}

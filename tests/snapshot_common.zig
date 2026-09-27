//! Shared by the bytecode snapshot test (tests/bytecode_snapshot.zig) and its
//! updater (tests/snapshot_update.zig): how a snapshot line is read and how a
//! pattern's outcome is computed. See tests/snapshots/bytecode.txt's header.

const std = @import("std");
const zregex = @import("zregex");

pub const Line = struct {
    outcome: []const u8,
    flags: []const u8,
    pattern_hex: []const u8,
    /// Everything after the pattern hex (the informational JSON column).
    rest: []const u8,
};

/// A data line of the snapshot, or null for a comment or blank line.
pub fn parseLine(line: []const u8) ?Line {
    if (line.len == 0 or line[0] == '#') return null;
    var it = std.mem.splitScalar(u8, line, '\t');
    const recorded = it.next() orelse return null;
    const flags = it.next() orelse return null;
    const pattern_hex = it.next() orelse return null;
    return .{ .outcome = recorded, .flags = flags, .pattern_hex = pattern_hex, .rest = it.rest() };
}

pub fn options(flags: []const u8) zregex.CompileOptions {
    const has = struct {
        fn f(s: []const u8, c: u8) bool {
            return std.mem.indexOfScalar(u8, s, c) != null;
        }
    }.f;
    return .{
        .case_insensitive = has(flags, 'i'),
        .multiline = has(flags, 'm'),
        .dot_all = has(flags, 's'),
        .unicode = has(flags, 'u'),
        .v = has(flags, 'v'),
    };
}

/// Wyhash of the whole program: the bytecode, then each CharSet in table
/// order (its range count, then its ranges).
pub fn hashProgram(compiled: zregex.CompileResult) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(compiled.bytecode);
    for (compiled.charsets) |cs| {
        h.update(std.mem.asBytes(&@as(u64, cs.ranges.len)));
        h.update(std.mem.sliceAsBytes(cs.ranges));
    }
    return h.final();
}

/// The outcome column for `pattern` under `flags`: the program hash as 16
/// hex digits, or `error:<Name>`. Written into `buf`.
pub fn outcome(allocator: std.mem.Allocator, flags: []const u8, pattern: []const u8, buf: []u8) ![]const u8 {
    const compiled = zregex.compile(allocator, pattern, options(flags)) catch |err| {
        if (err == error.OutOfMemory) return err;
        return std.fmt.bufPrint(buf, "error:{s}", .{@errorName(err)});
    };
    defer compiled.deinit();
    return std.fmt.bufPrint(buf, "{x:0>16}", .{hashProgram(compiled)});
}

/// The disassembly and CharSet table of `pattern`, for a failure report.
pub fn dump(allocator: std.mem.Allocator, flags: []const u8, pattern: []const u8, w: *std.Io.Writer) !void {
    const compiled = zregex.compile(allocator, pattern, options(flags)) catch |err| {
        try w.print("  compile error: {s}\n", .{@errorName(err)});
        return;
    };
    defer compiled.deinit();
    try zregex.disassemble(compiled.bytecode, w);
    for (compiled.charsets, 0..) |cs, i| {
        try w.print("  charset {d}: {d} ranges", .{ i, cs.ranges.len });
        for (cs.ranges[0..@min(cs.ranges.len, 8)]) |r| try w.print(" {X}-{X}", .{ r.lo, r.hi });
        if (cs.ranges.len > 8) try w.writeAll(" ...");
        try w.writeAll("\n");
    }
}

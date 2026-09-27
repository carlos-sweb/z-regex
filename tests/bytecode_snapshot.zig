//! Bytecode snapshot check (docs/REGEX_TIERS_PLAN.md, F2c): every pattern of
//! tests/snapshots/bytecode.txt must still compile to the same program
//! (bytecode and CharSet table), or fail with the same error. On a
//! difference the test prints the pattern and its new program; the policy
//! for updating the file is in its header.

const std = @import("std");
const common = @import("snapshot_common.zig");

const snapshot = @embedFile("snapshots/bytecode.txt");

test "bytecode snapshot: every corpus pattern compiles to the recorded program" {
    const allocator = std.testing.allocator;
    var checked: usize = 0;
    var mismatches: usize = 0;
    var pattern_buf: [4096]u8 = undefined;
    var out_buf: [128]u8 = undefined;
    var report: std.Io.Writer.Allocating = .init(allocator);
    defer report.deinit();

    var lines = std.mem.splitScalar(u8, snapshot, '\n');
    while (lines.next()) |raw| {
        const line = common.parseLine(raw) orelse continue;
        const pattern = try std.fmt.hexToBytes(&pattern_buf, line.pattern_hex);
        const got = try common.outcome(allocator, line.flags, pattern, &out_buf);
        checked += 1;
        if (std.mem.eql(u8, got, line.outcome)) continue;
        mismatches += 1;
        if (mismatches > 10) continue;
        const w = &report.writer;
        try w.print("\n/{s}/{s}: recorded {s}, now {s}\n", .{ line.rest, line.flags, line.outcome, got });
        try common.dump(allocator, line.flags, pattern, w);
    }

    try std.testing.expect(checked > 0);
    if (mismatches > 0) {
        std.debug.print("{s}\nbytecode snapshot: {d} of {d} patterns differ (first 10 above). " ++
            "See the policy in tests/snapshots/bytecode.txt; `zig build update-bytecode-snapshot` rewrites it.\n", .{ report.written(), mismatches, checked });
        return error.SnapshotMismatch;
    }
}

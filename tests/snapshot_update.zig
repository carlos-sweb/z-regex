//! `zig build update-bytecode-snapshot`: recompute the outcome column of
//! tests/snapshots/bytecode.txt (see its header) for the current compiler.

const std = @import("std");
const common = @import("snapshot_common.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingSnapshotPath;

    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 << 20));
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    var pattern_buf: [4096]u8 = undefined;
    var out_buf: [128]u8 = undefined;
    var changed: usize = 0;
    var total: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        if (lines.peek() == null and raw.len == 0) break; // trailing newline
        const line = common.parseLine(raw) orelse {
            try w.print("{s}\n", .{raw});
            continue;
        };
        const pattern = try std.fmt.hexToBytes(&pattern_buf, line.pattern_hex);
        const got = try common.outcome(gpa, line.flags, pattern, &out_buf);
        total += 1;
        if (!std.mem.eql(u8, got, line.outcome)) changed += 1;
        try w.print("{s}\t{s}\t{s}\t{s}\n", .{ got, line.flags, line.pattern_hex, line.rest });
    }

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = out.written() });
    var msg: [128]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&msg, "bytecode snapshot: {d} of {d} outcomes changed\n", .{ changed, total }));
}

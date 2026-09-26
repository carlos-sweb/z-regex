//! Parser fuzzing, corpus part (docs/REGEX_TIERS_PLAN.md, F0d): runs on
//! every `zig build test`. What each pattern goes through, and what the
//! matcher doesn't cover yet, is in tests/fuzz_common.zig. The 20,000-pattern
//! stress is a separate step: `zig build test-fuzz-stress`
//! (tests/fuzz_stress.zig).
//!
//! `std.testing.fuzz`: outside fuzz mode it runs only the corpus (the
//! *patterns* of tests/test262_data.zig), fed as raw bytes; with
//! `zig build test --fuzz` the fuzzer generates patterns through `Smith`
//! (doesn't build on Zig 0.16.0, see §8.2 of the plan).

const std = @import("std");
const data = @import("test262_data.zig");
const common = @import("fuzz_common.zig");

const corpus = blk: {
    var patterns: [data.cases.len][]const u8 = undefined;
    for (data.cases, 0..) |c, i| patterns[i] = c.pattern;
    const final = patterns;
    break :blk final;
};

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    // Outside fuzz mode `in` holds a raw corpus entry; in fuzz mode the
    // fuzzer drives `Smith`.
    const pattern: []const u8 = if (smith.in) |in| in else buf[0..smith.slice(&buf)];
    try common.checkPattern(std.testing.allocator, pattern);
}

test "fuzz: parser never crashes or leaks (corpus: test262 sample patterns)" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &corpus });
}

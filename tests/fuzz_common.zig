//! Shared by the parser fuzzers (docs/REGEX_TIERS_PLAN.md, F0d): the corpus
//! test in tests/fuzz_parser.zig (`zig build test`) and the deterministic
//! stress in tests/fuzz_stress.zig (`zig build test-fuzz-stress`).
//!
//! `checkPattern` runs a pattern through `analyze` and `compile` (with no
//! flags, `u`, and `v`) and, when it compiles, a few `find` calls on short
//! subjects. A crash is a safety panic; a leak is caught by
//! `std.testing.allocator`. Both fail the test.
//!
//! Coverage: the parser and `analyze` see every pattern. The matcher does
//! not: patterns in the expert tier (T2: backreferences, lookarounds), or
//! that `analyze` can't classify, are compiled but **not executed**, because
//! the recursive matcher overflows the native stack on chains like
//! `()\1{1000}` (D15; found by this fuzzer, reproduced as a skipped test in
//! tests/regression_tests.zig). F6a replaces that matcher with an explicit
//! heap stack; when F6a closes, remove this exclusion.

const std = @import("std");
const zregex = @import("zregex");

pub const Mode = enum { none, u, v };

// Short subjects keep a pathological pattern's worst case (the step limit
// per start position) small.
pub const subjects = [_][]const u8{ "", "a", "ab1_ \xC3\xA9", "aaaaab" };

/// Pattern×mode pairs that compiled, by what happened to them next.
pub const Stats = struct {
    executed: usize = 0,
    skipped_expert: usize = 0,
    skipped_unclassifiable: usize = 0,
};
pub var stats: Stats = .{};

/// Execute only patterns classified below the expert tier. Unclassifiable
/// ones (a parse error, or a known deviation such as D10) are compiled but
/// not run: `analyze` stops at the deviation, so its feature set may miss a
/// backreference (the fuzzer's `\2{9007199254740991}` did exactly that).
fn executable(a: zregex.analysis.Analysis) bool {
    const t = a.min_tier orelse return false;
    return t != .expert;
}

pub fn checkPattern(gpa: std.mem.Allocator, pattern: []const u8) !void {
    for ([_]Mode{ .none, .u, .v }) |mode| {
        const flags: zregex.analysis.Flags = switch (mode) {
            .none => .{},
            .u => .{ .u = true },
            .v => .{ .v = true },
        };
        const analysis = try zregex.analyze(gpa, pattern, flags);
        const execute = executable(analysis);

        const options: zregex.CompileOptions = switch (mode) {
            .none => .{},
            .u => .{ .unicode = true },
            .v => .{ .v = true },
        };
        if (zregex.Regex.compileWithOptions(gpa, pattern, options)) |re| {
            defer re.deinit();
            if (!execute) {
                if (analysis.min_tier == null) {
                    stats.skipped_unclassifiable += 1;
                } else {
                    stats.skipped_expert += 1;
                }
                continue;
            }
            stats.executed += 1;
            for (subjects) |subject| {
                if (re.find(subject)) |m| {
                    if (m) |match| match.deinit();
                } else |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {}, // resource limits are a defined outcome
                }
            }
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {}, // any defined compile error is fine
        }
    }
}

//! Runs the extracted test262 cases (see test262_data.zig) against zregexp
//! and reports a pass rate. See docs/ECMASCRIPT_COMPATIBILITY_PLAN.md Phase 6.
//!
//! Important semantic note: JS's `.test()`/`.exec()` are UNANCHORED substring
//! searches, unlike zregexp's `test_()` (which requires a full-string match).
//! So test262 "test" cases are checked via `find() != null`, not `test_()`.

const std = @import("std");
const regex = @import("zregexp");
const data = @import("test262_data.zig");

fn optionsFromFlags(flags: []const u8) regex.CompileOptions {
    var opts = regex.CompileOptions{};
    for (flags) |c| {
        switch (c) {
            'i' => opts.case_insensitive = true,
            'm' => opts.multiline = true,
            's' => opts.dot_all = true,
            'y' => opts.sticky = true,
            else => {}, // 'g': no-op for a single find/test call
        }
    }
    return opts;
}

const Outcome = enum { pass, fail, compile_error };

fn runCase(allocator: std.mem.Allocator, c: data.Case) Outcome {
    var re = regex.Regex.compileWithOptions(allocator, c.pattern, optionsFromFlags(c.flags)) catch {
        return .compile_error;
    };
    defer re.deinit();

    switch (c.kind) {
        .test_ => {
            const m = re.find(c.input) catch return .fail;
            defer if (m) |mm| mm.deinit();
            return if ((m != null) == c.expected_bool) .pass else .fail;
        },
        .exec_null => {
            const m = re.find(c.input) catch return .fail;
            defer if (m) |mm| mm.deinit();
            return if (m == null) .pass else .fail;
        },
        .exec_array => {
            const m = re.find(c.input) catch return .fail;
            if (m == null) return .fail;
            defer m.?.deinit();

            if (c.expected_captures.len == 0) return .fail;
            const full = c.expected_captures[0] orelse return .fail;
            if (!std.mem.eql(u8, m.?.group(c.input), full)) return .fail;

            for (c.expected_captures[1..], 1..) |expected, i| {
                const actual = m.?.getCapture(i, c.input);
                if (expected == null) {
                    if (actual != null) return .fail;
                } else {
                    if (actual == null or !std.mem.eql(u8, actual.?, expected.?)) return .fail;
                }
            }
            return .pass;
        },
    }
}

test "test262 conformance sample" {
    const allocator = std.testing.allocator;

    var pass: usize = 0;
    var fail: usize = 0;
    var compile_errors: usize = 0;

    for (data.cases) |c| {
        switch (runCase(allocator, c)) {
            .pass => pass += 1,
            .fail => {
                fail += 1;
                std.debug.print("[test262 FAIL] {s}: /{s}/{s} vs \"{s}\"\n", .{ c.file, c.pattern, c.flags, c.input });
            },
            .compile_error => {
                compile_errors += 1;
                std.debug.print("[test262 COMPILE-ERROR] {s}: /{s}/{s}\n", .{ c.file, c.pattern, c.flags });
            },
        }
    }

    const total = data.cases.len;
    std.debug.print(
        "\ntest262 conformance sample: {}/{} passed ({d:.1}%), {} failed, {} compile errors\n",
        .{ pass, total, @as(f64, @floatFromInt(pass)) * 100.0 / @as(f64, @floatFromInt(total)), fail, compile_errors },
    );
}

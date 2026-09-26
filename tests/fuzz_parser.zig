//! Parser fuzzing (docs/REGEX_TIERS_PLAN.md, F0d): arbitrary patterns must
//! never crash or leak. Every pattern goes through `compile` (with no flags,
//! `u`, and `v`), a few `find` calls on short subjects when it compiles, and
//! `analyze`. A crash is a Debug safety panic; a leak is caught by
//! `std.testing.allocator`. Both fail the test.
//!
//! Patterns that `analyze` puts in the expert tier (backreferences,
//! lookarounds), or can't classify, are compiled and analyzed but **not executed**: the
//! recursive matcher overflows the native stack on chains like `()\1{1000}`
//! (D14; found by this fuzzer, reproduced as a skipped test in
//! tests/regression_tests.zig). F6a replaces that matcher with an explicit
//! heap stack; when F6a closes, remove this exclusion.
//!
//! Two entry points:
//! - `std.testing.fuzz`: outside fuzz mode it runs only the corpus (the
//!   *patterns* of tests/test262_data.zig), fed as raw bytes; with
//!   `zig build test --fuzz` the fuzzer generates patterns through `Smith`.
//! - a deterministic stress test: 20,000 patterns built from a fixed seed
//!   and a regex-syntax-biased token alphabet, run on every `zig build test`.

const std = @import("std");
const zregex = @import("zregex");
const data = @import("test262_data.zig");

const Mode = enum { none, u, v };

// Short subjects keep a pathological pattern's worst case (the step limit
// per start position) small.
const subjects = [_][]const u8{ "", "a", "ab1_ \xC3\xA9", "aaaaab" };

/// Patterns compiled but not executed because they reach the expert tier.
var skipped_execution: usize = 0;

/// Execute only patterns classified below the expert tier. Unclassifiable
/// ones (a parse error, or a known deviation such as D10) are compiled but
/// not run: `analyze` stops at the deviation, so its feature set may miss a
/// backreference (the fuzzer's `\2{9007199254740991}` did exactly that).
fn executable(a: zregex.analysis.Analysis) bool {
    const t = a.min_tier orelse return false;
    return t != .expert;
}

fn checkPattern(gpa: std.mem.Allocator, pattern: []const u8) !void {
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
            if (!execute) skipped_execution += 1;
            if (execute) for (subjects) |subject| {
                if (re.find(subject)) |m| {
                    if (m) |match| match.deinit();
                } else |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {}, // resource limits are a defined outcome
                }
            };
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {}, // any defined compile error is fine
        }
    }
}

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
    try checkPattern(std.testing.allocator, pattern);
}

test "fuzz: parser never crashes or leaks (corpus: test262 sample patterns)" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &corpus });
}

const tokens = [_][]const u8{
    // atoms
    "a",          "b",     "\\d",  "\\w",          "\\s",    "\\D",    ".",       "[a-z]", "[^a]",               "[]",
    "[^]",        "\\1",   "\\2",  "\\10",         "\\k<n>", "\\p{L}", "\\P{Lu}", "\\p{",  "\\u{1F600}",         "\\u{",
    "\xC3\xA9",   "\\x41", "\\x4", "\\u0041",      "\\u00",  "\\cA",   "\\c",     "\\0",   "\\q{ab}",            "\\",
    "\\b",        "\\B",   "\xFF", "\xED\xB0\x80",
    // groups and assertions
    "(",      ")",      "(?:",     "(?=",   "(?!",                "(?<=",
    "(?<!",       "(?<n>", "(?<n", "(?",
    // quantifiers
              "*",      "+",      "?",       "*?",    "+?",                 "??",
    "*+",         "{",     "}",    "{2}",          "{1,3}",  "{,3}",   "{3,1}",   "{2,}?", "{9007199254740991}",
    // alternation, anchors, class syntax
    "|",
    "^",          "$",     "[",    "]",            "-",      "--",     "&&",      ",",     "[a-",                "[\\d-z]",
    "[[a]--[b]]",
};

test "fuzz: deterministic stress over 20,000 syntax-biased patterns" {
    var prng = std.Random.DefaultPrng.init(0xF0D_F022);
    const rand = prng.random();
    var buf: [512]u8 = undefined;
    for (0..20_000) |_| {
        var len: usize = 0;
        const n = 1 + rand.uintLessThan(usize, 16);
        for (0..n) |_| {
            const tok = tokens[rand.uintLessThan(usize, tokens.len)];
            if (len + tok.len > buf.len) break;
            @memcpy(buf[len..][0..tok.len], tok);
            len += tok.len;
        }
        checkPattern(std.testing.allocator, buf[0..len]) catch |err| {
            std.debug.print("fuzz stress failed on pattern: {s}\n", .{buf[0..len]});
            return err;
        };
    }
}

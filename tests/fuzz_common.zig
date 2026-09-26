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
const dual = @import("dual_encoding.zig");

pub const Mode = enum { none, u, v };

// Short subjects keep a pathological pattern's worst case (the step limit
// per start position) small. Since F3c they include astral characters and
// lone surrogates, and every executed pattern is also run on each
// subject's UTF-16 form (it must find the same match).
pub const subjects = [_][]const u8{ "", "a", "ab1_ \xC3\xA9", "aaaaab", "\u{1F600}x\u{1F600}", "a\xED\xA0\x80b\xED\xB0\x80", "\u{1D306}\u{2028}_" };

/// Pattern×mode pairs that compiled, by what happened to them next.
pub const Stats = struct {
    executed: usize = 0,
    skipped_expert: usize = 0,
    skipped_unclassifiable: usize = 0,
};
pub var stats: Stats = .{};

/// Execute only patterns classified below the expert tier. Unclassifiable
/// ones (a parse error, or a known deviation such as D10) are compiled but
/// not run: a known deviation has no tier (its feature set is complete since
/// F2d, but the semantics it would run under deviates until F5).
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
        const analyzed_syntax_error = if (analysis.unclassifiable) |u| u == .parse_error else false;
        if (zregex.Regex.compileWithOptions(gpa, pattern, options)) |re| {
            defer re.deinit();
            // F1 gate: analyze and compile agree on what is a SyntaxError.
            if (analyzed_syntax_error) return reportDisagreement(pattern, mode, "analyze: parse error, compile: ok");
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
                try sameInBoth(gpa, re, subject, pattern, mode);
            }
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                // Any defined compile error is fine, but a parse error must be
                // one for analyze too (codegen-only errors, e.g.
                // PatternTooLarge, are not parse errors).
                if (isParseError(err) and !analyzed_syntax_error) return reportDisagreement(pattern, mode, "compile: parse error, analyze: classified");
            },
        }
    }
}

/// F3c: a search from 0 on the subject and on its UTF-16 form give the
/// same outcome (the same slots once mapped, or the same error).
fn sameInBoth(gpa: std.mem.Allocator, re: zregex.Regex, subject: []const u8, pattern: []const u8, mode: Mode) !void {
    // Raw bytes of an ill-formed pattern (BYTE) only exist in WTF-8.
    if (!dual.wellFormed(subject) or !dual.wellFormed(pattern)) return;
    var err_w: ?anyerror = null;
    var err_u: ?anyerror = null;
    const w = dual.execWtf8(gpa, re, subject, 0) catch |e| blk: {
        err_w = e;
        break :blk null;
    };
    defer if (w) |f| f.deinit(gpa);
    const u = dual.execUtf16(gpa, re, subject, 0) catch |e| blk: {
        err_u = e;
        break :blk null;
    };
    defer if (u) |f| f.deinit(gpa);
    for ([_]?anyerror{ err_w, err_u }) |e| {
        if (e) |x| if (x == error.OutOfMemory) return error.OutOfMemory;
    }
    const same_err = if (err_w) |x| (if (err_u) |y| x == y else false) else err_u == null;
    const same = same_err and (w == null) == (u == null) and
        (w == null or std.mem.eql(?usize, w.?.slots, u.?.slots));
    if (!same) {
        std.debug.print("\n/{s}/ ({s}) on {x}: WTF-8 and UTF-16 differ\n", .{ pattern, @tagName(mode), subject });
        return error.EncodingsDisagree;
    }
}

fn isParseError(err: anyerror) bool {
    inline for (@typeInfo(zregex.ParseError).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return true;
    }
    return false;
}

fn reportDisagreement(pattern: []const u8, mode: Mode, what: []const u8) error{AnalyzeCompileDisagree} {
    std.debug.print("\n/{s}/ ({s}): {s}\n", .{ pattern, @tagName(mode), what });
    return error.AnalyzeCompileDisagree;
}

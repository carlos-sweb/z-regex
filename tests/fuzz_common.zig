//! Shared by the parser fuzzers (docs/REGEX_TIERS_PLAN.md, F0d): the corpus
//! test in tests/fuzz_parser.zig (`zig build test`) and the deterministic
//! stress in tests/fuzz_stress.zig (`zig build test-fuzz-stress`).
//!
//! `checkPattern` runs a pattern through `analyze` and `compile` (with no
//! flags, `u`, and `v`) and, when it compiles, a few `find` calls on short
//! subjects. A crash is a safety panic; a leak is caught by
//! `std.testing.allocator`. Both fail the test.
//!
//! Since F4a, a pattern the dispatcher routes to T0's VM is also run on
//! the backtracker (`force_tier = .expert`), and the two executors must
//! give the same `[start, end]` at every index of every subject, sticky
//! and not, in WTF-8 and UTF-16 (`compareEngines`).
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
    /// Executed patterns that ran on T0's VM, compared with the backtracker.
    engines_compared: usize = 0,
    /// Pattern×mode pairs that also went through the path audit (sampled).
    audited: usize = 0,
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
            const audit = sampled(pattern);
            if (audit) try checkRouting(gpa, re, pattern, options, analysis, mode);
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
                if (audit) try findMatchesExecAt(gpa, re, subject, pattern) else if (re.find(subject)) |m| {
                    if (m) |match| match.deinit();
                } else |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {}, // resource limits are a defined outcome
                }
                try sameInBoth(gpa, re, subject, pattern, mode);
            }
            if (re.t0 != null) try compareEngines(gpa, re, pattern, options, audit);
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

/// The F4a(4) path-audit checks (`checkRouting`, `findMatchesExecAt`) run
/// on one pattern in ten, picked by a hash of the pattern: on every pattern
/// they doubled the stress in Debug (70.6 -> 140.5 s), over the 50% limit.
fn sampled(pattern: []const u8) bool {
    return std.hash.Wyhash.hash(0xF4A4, pattern) % 10 == 0;
}

/// F4a audit: the dispatcher routes to T0's VM exactly the patterns
/// `analyze()` puts in T0 and `tier0.check` accepts, and `force_tier`
/// agrees with that routing.
fn checkRouting(gpa: std.mem.Allocator, re: zregex.Regex, pattern: []const u8, options: zregex.CompileOptions, analysis: zregex.analysis.Analysis, mode: Mode) !void {
    stats.audited += 1;
    const eligible = blk: {
        if (analysis.min_tier != .regular) break :blk false;
        const fe = try zregex.lower.Frontend.init(gpa, pattern, .{ .unicode = options.unicode, .v = options.v }, .{});
        defer fe.deinit();
        break :blk zregex.tier0.check(fe.root) == null;
    };
    if (eligible != (re.t0 != null)) return reportDisagreement(pattern, mode, "analyze()+tier0.check and the dispatcher route differently");
    var o = options;
    o.force_tier = .regular;
    if (zregex.Regex.compileWithOptions(gpa, pattern, o)) |forced| {
        defer forced.deinit();
        if (re.t0 == null or forced.t0 == null) return reportDisagreement(pattern, mode, "force_tier .regular compiled a pattern the dispatcher keeps off the VM");
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        error.TierUnavailable => if (re.t0 != null) return reportDisagreement(pattern, mode, "force_tier .regular refused a pattern the dispatcher routes to the VM"),
        else => return err,
    }
    o.force_tier = .expert;
    const bt = try zregex.Regex.compileWithOptions(gpa, pattern, o);
    defer bt.deinit();
    if (bt.t0 != null) return reportDisagreement(pattern, mode, "force_tier .expert left a T0 program");
}

/// F4a audit: the facade's `find` is `execAt` from 0 (WTF-8, the regex's
/// own sticky), including its errors.
fn findMatchesExecAt(gpa: std.mem.Allocator, re: zregex.Regex, subject: []const u8, pattern: []const u8) !void {
    const found = re.find(subject);
    defer if (found) |m| (if (m) |match| match.deinit()) else |_| {};
    var scratch = zregex.Scratch.init(gpa);
    defer scratch.deinit();
    const slots = try gpa.alloc(?usize, re.slotCount());
    defer gpa.free(slots);
    var out: zregex.MatchSlots = .{ .slots = slots };
    const exec = re.execAt(.{ .wtf8 = subject }, 0, &scratch, &out, .{});
    const same = if (found) |m| (if (exec) |e| (if (m) |match| e and slots[0].? == match.start and slots[1].? == match.end else !e) else |_| false) else |ferr| (if (exec) |_| false else |eerr| ferr == eerr);
    if (found) |_| {} else |err| if (err == error.OutOfMemory) return err;
    if (!same) {
        std.debug.print("\n/{s}/ on {x}: find and execAt differ\n", .{ pattern, subject });
        return error.FindExecAtDisagree;
    }
}

/// F4a: T0's VM (`re`) and the backtracker give the same result.
fn compareEngines(gpa: std.mem.Allocator, re: zregex.Regex, pattern: []const u8, options: zregex.CompileOptions, audit: bool) !void {
    stats.engines_compared += 1;
    var o = options;
    o.force_tier = .expert;
    var bt = try zregex.Regex.compileWithOptions(gpa, pattern, o);
    defer bt.deinit();
    var vm = re;
    var scratch = zregex.Scratch.init(gpa);
    defer scratch.deinit();
    for (subjects) |s8| {
        if (audit) try findMatchesExecAt(gpa, bt, s8, pattern);
        const s16 = try zregex.subject.utf16FromWtf8(gpa, s8);
        defer gpa.free(s16);
        for ([_]zregex.Subject{ .{ .wtf8 = s8 }, .{ .utf16 = s16 } }) |subj| {
            for ([_]bool{ false, true }) |sticky| {
                vm.sticky = sticky;
                bt.sticky = sticky;
                for (0..subj.len() + 1) |i| {
                    var b1: [2]?usize = undefined;
                    var b2: [2]?usize = undefined;
                    var o1: zregex.MatchSlots = .{ .slots = &b1 };
                    var o2: zregex.MatchSlots = .{ .slots = &b2 };
                    const expected = bt.execAt(subj, i, &scratch, &o2, .{}) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        // The backtracker's limits; the VM has none.
                        error.StepLimitExceeded, error.RecursionLimitExceeded => continue,
                        error.InvalidIndex => {
                            try std.testing.expectError(error.InvalidIndex, vm.execAt(subj, i, &scratch, &o1, .{}));
                            continue;
                        },
                        else => return err,
                    };
                    const got = try vm.execAt(subj, i, &scratch, &o1, .{});
                    if (got != expected or (got and (b1[0] != b2[0] or b1[1] != b2[1]))) {
                        std.debug.print("\n/{s}/ on {x} ({s}) at {d}, sticky {}: the VM and the backtracker differ\n", .{ pattern, s8, @tagName(subj), i, sticky });
                        return error.EnginesDisagree;
                    }
                }
            }
        }
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

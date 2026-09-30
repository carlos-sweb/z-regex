//! E1 P2: an oracle for lookbehind without V8 (docs/plans/E1.md). Run:
//! `zig build lbdiff`.
//!
//! `(?<=B)` holds at `pos` if and only if there is a character boundary
//! `k <= pos` such that `^(?:B)$` matches the slice `subject[k..pos]`;
//! `(?<!B)` is its negation. Both sides run on zregex: the lookbehind as
//! compiled (B′ today, full F6b later) and the body forward on the slices.
//! It is exact only where cutting the subject at `k` and `pos` can't change
//! what the body sees, so the domain is bodies without anchors, word
//! boundaries, backreferences or lookarounds (`zregex.internal.analyze`); captures
//! are allowed and not compared. Bodies: a fixed-seed generator, the
//! lookbehind bodies of test262, and the patterns of tests/corpus/iter_v8.tsv,
//! each under every flag set below. Exits 1 on any discrepancy.

const std = @import("std");
const zregex = @import("zregex");
const analysis = zregex.internal.analysis;
const Mode = zregex.internal.subject.Mode;

const Flag = struct { text: []const u8, i: bool = false, s: bool = false, u: bool = false, v: bool = false };
const flag_sets = [_]Flag{
    .{ .text = "" },
    .{ .text = "i", .i = true },
    .{ .text = "s", .s = true },
    .{ .text = "u", .u = true },
    .{ .text = "iu", .i = true, .u = true },
    .{ .text = "v", .v = true },
    .{ .text = "iv", .i = true, .v = true },
};

/// Why a (body, flags) pair is out of the comparison, in the order a pair is
/// counted: the first reason that applies.
const Out = enum { invalid, anchor, word_boundary, backreference, lookahead, lookbehind, b_prime, compared };
const Source = enum { generated, test262, iter_v8 };

const generated_count = 2000;
const seed = 0xE1;

/// The bodies of the lookbehinds in test262's built-ins/RegExp/lookBehind/*.js and
/// named-groups/lookbehind.js (82 unique; extracted once with regexpp).
const test262_bodies = [_][]const u8{
    "(..|...|....)",
    "(xx|...|....)",
    "(xx|...)",
    "(xx|xxx)",
    "\\1(\\w)",
    "\\1([abx])",
    "\\1(\\w+)",
    "(\\w+)\\1",
    "(\\1\\1)",
    "\\1\\2\\1",
    "(\\1)",
    "(.)",
    "\\1\\1\\1",
    "(^|[ab])",
    "(c)",
    "(\\w{2})",
    "(\\w(\\w))",
    "(\\w){3}",
    "(bc)|(cd)",
    "([ab]{1,2})\\D|(abc)",
    "([ab]+)",
    "b|c",
    "[b-e]",
    "([abc]+)",
    "(b+)",
    "(b\\d+)",
    "((?:b\\d{2})+)",
    "$abc",
    "foo",
    "fo+",
    "fo*",
    "a(.\\2)b(\\1)",
    "a(\\2)b(..\\1)",
    "(?:\\1b)(aa)",
    "(?:\\1|b)(aa)",
    "abc",
    "a.c",
    "a\\wc",
    "a[a-z]",
    "a[a-z]{2}",
    "a[a-z][a-z]",
    "a{1}b{1}",
    "a{1}[a-z]{2}",
    "ab(?=c)\\wd",
    "a(?=([^a]{2})d)\\w{3}",
    "a(?=([bc]{2}(?<!a{2}))d)\\w{3}",
    "a{2}",
    "^f[oa]+(?=o)",
    "a(?=([bc]{2}(?<!a*))d)\\w{3}",
    "a*",
    "a",
    "\\woo",
    ".oo",
    "a{1}",
    "\\1",
    "^[^a-c]{3}",
    "^o+",
    "^o*",
    "^abc",
    "^[a-c]{3}",
    "^",
    "$",
    "^fo+",
    "^fo*",
    "^\\1o+",
    "^\\w+",
    "^(\\w+)",
    "[a|b|c]*",
    "\\w*",
    "\\b",
    "\\B",
    "c(?<=\\w)",
    "\\w",
    "(?<a>\\w){3}",
    "(?<a>\\w){4}",
    "(?<a>\\w)+",
    "(?<a>\\w){6}",
    "\\w{3}",
    "(?<a>\\d){3}",
    "(?<a>\\D){3}",
    "\\D{3}",
    "(?<fst>.)|(?<snd>.)",
};

const subjects_utf8 = [_][]const u8{ "", "a", "ab", "ba", "aab", "abab", "bb a", "\u{e9}", "a\u{e9}b", "\u{1F600}", "a\u{1F600}b", "12a", "_x9", "a\nb", "AbA" };
/// UTF-16 only: lone surrogate halves.
const subjects_units = [_][]const u16{ &.{ 0xD83D, 'a' }, &.{ 'a', 0xDE00 }, &.{ 0xDE00, 0xD83D } };

const Counts = struct {
    pairs: [3][@typeInfo(Out).@"enum".fields.len]u64 = .{.{0} ** @typeInfo(Out).@"enum".fields.len} ** 3,
    runs: u64 = 0,
    step_limit: u64 = 0,
    /// How often the oracle said the lookbehind holds / doesn't.
    oracle_true: u64 = 0,
    oracle_false: u64 = 0,
    discrepancies: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    var counts: Counts = .{};
    var scratch = zregex.Scratch.init(gpa);
    defer scratch.deinit();

    // Generated bodies.
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    for (0..generated_count) |_| {
        body.clearRetainingCapacity();
        try genAlt(gpa, rnd, &body, 0);
        try checkBody(gpa, &scratch, body.items, .generated, &counts, w);
    }
    for (test262_bodies) |b| try checkBody(gpa, &scratch, b, .test262, &counts, w);

    // tests/corpus/iter_v8.tsv: the pattern is the first column.
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, "tests/corpus/iter_v8.tsv", gpa, .limited(16 << 20));
    defer gpa.free(data);
    var iter_bodies: u64 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const pattern = line[0 .. std.mem.indexOfScalar(u8, line, '\t') orelse line.len];
        iter_bodies += 1;
        try checkBody(gpa, &scratch, pattern, .iter_v8, &counts, w);
    }

    try w.print("lbdiff: bodies generated {d} (seed 0x{x}), test262 {d}, iter_v8.tsv {d}; flag sets {d} (", .{ generated_count, seed, test262_bodies.len, iter_bodies, flag_sets.len });
    for (flag_sets, 0..) |f, i| try w.print("{s}{s}", .{ if (i > 0) " " else "", if (f.text.len == 0) "\"\"" else f.text });
    try w.print("); counts are (body, flags) pairs\n", .{});
    try w.print("| Source | pairs | invalid | anchor | word_boundary | backreference | lookahead | lookbehind | B' (variable length or captures) | compared |\n|---|---|---|---|---|---|---|---|---|---|\n", .{});
    var total = [_]u64{0} ** @typeInfo(Out).@"enum".fields.len;
    for (counts.pairs, 0..) |row, s| {
        var sum: u64 = 0;
        for (row, 0..) |n, i| {
            sum += n;
            total[i] += n;
        }
        try w.print("| {s} | {d}", .{ @tagName(@as(Source, @enumFromInt(s))), sum });
        for (row) |n| try w.print(" | {d}", .{n});
        try w.print(" |\n", .{});
    }
    var sum: u64 = 0;
    for (total) |n| sum += n;
    try w.print("| total | {d}", .{sum});
    for (total) |n| try w.print(" | {d}", .{n});
    try w.print(" |\nruns {d} (each: (?<=B) and (?<!B) at one position of one subject in one encoding); oracle true {d}, false {d}; step limit {d}; DISCREPANCIES {d}\n", .{ counts.runs, counts.oracle_true, counts.oracle_false, counts.step_limit, counts.discrepancies });
    try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
    if (counts.discrepancies > 0) std.process.exit(1);
}

fn genAtom(gpa: std.mem.Allocator, rnd: std.Random, b: *std.ArrayListUnmanaged(u8), depth: u32) std.mem.Allocator.Error!void {
    const atoms = [_][]const u8{ "a", "b", ".", "\\d", "\\w", "[ab]", "[^a]", "\u{e9}", "\u{1F600}", "ab", "ba", "a\u{e9}" };
    const r = rnd.uintLessThan(u32, 10);
    if (depth < 2 and r == 0) {
        try b.appendSlice(gpa, "(?:");
        try genAlt(gpa, rnd, b, depth + 1);
        try b.append(gpa, ')');
    } else if (depth < 2 and r == 1) {
        try b.append(gpa, '(');
        try genAlt(gpa, rnd, b, depth + 1);
        try b.append(gpa, ')');
    } else try b.appendSlice(gpa, atoms[rnd.uintLessThan(usize, atoms.len)]);
    const quants = [_][]const u8{ "", "", "", "", "*", "+", "?", "{1,2}", "{0,3}", "{2}", "*?", "+?", "??" };
    try b.appendSlice(gpa, quants[rnd.uintLessThan(usize, quants.len)]);
}

fn genAlt(gpa: std.mem.Allocator, rnd: std.Random, b: *std.ArrayListUnmanaged(u8), depth: u32) std.mem.Allocator.Error!void {
    const branches = 1 + @as(u32, if (rnd.uintLessThan(u32, 3) == 0) rnd.uintLessThan(u32, 2) + 1 else 0);
    for (0..branches) |i| {
        if (i > 0) try b.append(gpa, '|');
        const terms = 1 + rnd.uintLessThan(u32, 3);
        for (0..terms) |_| try genAtom(gpa, rnd, b, depth);
    }
}

fn checkBody(gpa: std.mem.Allocator, scratch: *zregex.Scratch, body: []const u8, source: Source, counts: *Counts, w: *std.Io.Writer) !void {
    for (flag_sets) |f| {
        const out = try classify(gpa, scratch, body, f, counts, w);
        counts.pairs[@intFromEnum(source)][@intFromEnum(out)] += 1;
    }
}

fn options(f: Flag, sticky: bool) zregex.CompileOptions {
    return .{ .case_insensitive = f.i, .dot_all = f.s, .unicode = f.u, .v = f.v, .sticky = sticky };
}

fn classify(gpa: std.mem.Allocator, scratch: *zregex.Scratch, body: []const u8, f: Flag, counts: *Counts, w: *std.Io.Writer) !Out {
    const flags: analysis.Flags = .{ .i = f.i, .s = f.s, .u = f.u, .v = f.v };
    const a = try zregex.internal.analyze(gpa, body, flags);
    inline for (.{ .{ Out.anchor, analysis.Feature.anchor }, .{ Out.word_boundary, analysis.Feature.word_boundary }, .{ Out.backreference, analysis.Feature.backreference }, .{ Out.lookahead, analysis.Feature.lookahead }, .{ Out.lookbehind, analysis.Feature.lookbehind } }) |pair| {
        if (a.features.contains(pair[1])) return pair[0];
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.print(gpa, "^(?:{s})$", .{body});
    var whole = zregex.Regex.compileWithOptions(gpa, buf.items, options(f, false)) catch return .invalid;
    defer whole.deinit();
    buf.clearRetainingCapacity();
    try buf.print(gpa, "(?<={s})", .{body});
    var pos_re = zregex.Regex.compileWithOptions(gpa, buf.items, options(f, true)) catch |err| return if (err == error.UnsupportedFeature) .b_prime else .invalid;
    defer pos_re.deinit();
    buf.clearRetainingCapacity();
    try buf.print(gpa, "(?<!{s})", .{body});
    var neg_re = zregex.Regex.compileWithOptions(gpa, buf.items, options(f, true)) catch |err| return if (err == error.UnsupportedFeature) .b_prime else .invalid;
    defer neg_re.deinit();

    const mode: Mode = if (f.u or f.v) .code_point else .code_unit;
    for (subjects_utf8) |s| {
        const s16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, s);
        defer gpa.free(s16);
        try compareOn(gpa, scratch, &whole, &pos_re, &neg_re, .{ .utf16 = s16 }, mode, body, f, counts, w);
        // WTF-8 only in code-point mode: without `u`/`v` a code-unit boundary
        // can fall on a 4-byte sequence's `b+2`, where no slice can start.
        if (mode == .code_point) try compareOn(gpa, scratch, &whole, &pos_re, &neg_re, .{ .wtf8 = s }, mode, body, f, counts, w);
    }
    for (subjects_units) |s| try compareOn(gpa, scratch, &whole, &pos_re, &neg_re, .{ .utf16 = s }, mode, body, f, counts, w);
    return .compared;
}

fn slice(s: zregex.Subject, from: usize, to: usize) zregex.Subject {
    return switch (s) {
        .utf16 => |u| .{ .utf16 = u[from..to] },
        .wtf8 => |b| .{ .wtf8 = b[from..to] },
    };
}

/// Whether `re` (sticky) matches at `index`; null when it hits the step limit.
fn matchesAt(gpa: std.mem.Allocator, scratch: *zregex.Scratch, re: *const zregex.Regex, s: zregex.Subject, index: usize) !?bool {
    const slots = try gpa.alloc(?usize, re.slotCount());
    defer gpa.free(slots);
    var out: zregex.MatchSlots = .{ .slots = slots };
    return re.execAt(s, index, scratch, &out, .{}) catch |err| switch (err) {
        error.StepLimitExceeded => null,
        else => |e| e,
    };
}

fn compareOn(gpa: std.mem.Allocator, scratch: *zregex.Scratch, whole: *const zregex.Regex, pos_re: *const zregex.Regex, neg_re: *const zregex.Regex, s: zregex.Subject, mode: Mode, body: []const u8, f: Flag, counts: *Counts, w: *std.Io.Writer) !void {
    // The character boundaries of `s` in the pattern's mode.
    var bounds: std.ArrayListUnmanaged(usize) = .empty;
    defer bounds.deinit(gpa);
    var p: usize = 0;
    while (true) {
        try bounds.append(gpa, p);
        if (p >= s.len()) break;
        p = s.advanceIndex(mode, p);
    }
    for (bounds.items, 0..) |pos, bi| {
        counts.runs += 1;
        const lb = try matchesAt(gpa, scratch, pos_re, s, pos) orelse {
            counts.step_limit += 1;
            continue;
        };
        const nlb = try matchesAt(gpa, scratch, neg_re, s, pos) orelse {
            counts.step_limit += 1;
            continue;
        };
        var oracle = false;
        var limited = false;
        for (bounds.items[0 .. bi + 1]) |k| {
            const m = try matchesAt(gpa, scratch, whole, slice(s, k, pos), 0) orelse {
                limited = true;
                break;
            };
            if (m) {
                oracle = true;
                break;
            }
        }
        if (limited) {
            counts.step_limit += 1;
            continue;
        }
        if (oracle) counts.oracle_true += 1 else counts.oracle_false += 1;
        if (lb != oracle or nlb == oracle) {
            counts.discrepancies += 1;
            if (counts.discrepancies <= 5) try w.print("DISCREPANCY body /{s}/{s} {s} pos {d}: (?<=B) {} (?<!B) {} oracle {}\n", .{ body, f.text, @tagName(s), pos, lb, nlb, oracle });
        }
    }
}

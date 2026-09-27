//! F0c (docs/REGEX_TIERS_PLAN.md §5.6): the tier histogram of a regex
//! corpus built by scripts/f0c/extract.mjs. Run: `zig build f0c -- FILE.tsv`.
//!
//! Each row is a regex with its flags, its occurrences and the number of
//! packages (or files) it appears in. The histogram is given three ways:
//! per unique regex, weighted by occurrences, and weighted by packages
//! (occurrences are dominated by generated code that repeats one regex
//! hundreds of times in one package). Invalid flags and patterns `analyze()`
//! can't classify are their own rows. Also: how many regexes change tier
//! with UNROLL_BUDGET at 500 and 5000 instead of 1000.

const std = @import("std");
const zregex = @import("zregex");
const analysis = zregex.analysis;

const Class = enum { regular, unicode, expert, unclassifiable, invalid_flags };

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingCorpusPath;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(256 << 20));
    defer gpa.free(data);

    var unique = [_]u64{0} ** 5;
    var by_occ = [_]u64{0} ** 5;
    var by_pkg = [_]u64{0} ** 5;
    var moved = [_]u64{ 0, 0 }; // tier differs with budget 500 / 5000
    var reasons = [_]u64{0} ** @typeInfo(analysis.Feature).@"enum".fields.len; // features at the top tier, T1/T2 patterns
    // T1 only because of `i` over non-ASCII content, while the pattern text is
    // ASCII without \u, \x80-\xff or \p: the content came from a class
    // like \s, \S, \W or [^...] (members up to U+10FFFF).
    var i_via_classes = [_]u64{ 0, 0, 0 }; // unique, occurrences, packages
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const flags_text = cols.next().?;
        const hex = cols.next().?;
        const occ = try std.fmt.parseInt(u64, cols.next().?, 10);
        const pkgs = try std.fmt.parseInt(u64, cols.next().?, 10);
        try buf.resize(gpa, hex.len / 2);
        const pattern = try std.fmt.hexToBytes(buf.items, hex);
        const class: Class = blk: {
            const flags = analysis.Flags.parse(flags_text) catch break :blk .invalid_flags;
            const a = try zregex.analyze(gpa, pattern, flags);
            const tier = a.min_tier orelse break :blk .unclassifiable;
            if (tier != .regular) {
                var it = a.reasons().iterator();
                while (it.next()) |f| reasons[@intFromEnum(f)] += 1;
                const r = a.reasons();
                if (tier == .unicode and r.count() == 1 and r.contains(.ignore_case_unicode) and asciiText(pattern)) {
                    i_via_classes[0] += 1;
                    i_via_classes[1] += occ;
                    i_via_classes[2] += pkgs;
                }
            }
            for ([_]u64{ 500, 5000 }, 0..) |budget, k| {
                const b = try analysis.analyzeWithBudget(gpa, pattern, flags, budget);
                if (b.min_tier != a.min_tier) moved[k] += 1;
            }
            break :blk switch (tier) {
                .regular => .regular,
                .unicode => .unicode,
                .expert => .expert,
            };
        };
        const i = @intFromEnum(class);
        unique[i] += 1;
        by_occ[i] += occ;
        by_pkg[i] += pkgs;
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.print("| Class | Unique | % | By occurrences | % | By packages | % |\n|---|---|---|---|---|---|---|\n", .{});
    const tu = sum(&unique);
    const to = sum(&by_occ);
    const tp = sum(&by_pkg);
    for (std.enums.values(Class), 0..) |c, i| {
        try w.print("| {s} | {d} | {d:.1} | {d} | {d:.1} | {d} | {d:.1} |\n", .{ @tagName(c), unique[i], pct(unique[i], tu), by_occ[i], pct(by_occ[i], to), by_pkg[i], pct(by_pkg[i], tp) });
    }
    // The 70/20/10 split is over the classified regexes (T0 + T1 + T2).
    const cu = unique[0] + unique[1] + unique[2];
    const co = by_occ[0] + by_occ[1] + by_occ[2];
    const cp = by_pkg[0] + by_pkg[1] + by_pkg[2];
    try w.print("\nOver classified regexes, T0/T1/T2: unique {d:.1}/{d:.1}/{d:.1}; by occurrences {d:.1}/{d:.1}/{d:.1}; by packages {d:.1}/{d:.1}/{d:.1}\n", .{
        pct(unique[0], cu), pct(unique[1], cu), pct(unique[2], cu),
        pct(by_occ[0], co), pct(by_occ[1], co), pct(by_occ[2], co),
        pct(by_pkg[0], cp), pct(by_pkg[1], cp), pct(by_pkg[2], cp),
    });
    try w.print("UNROLL_BUDGET sensitivity (unique regexes whose tier changes): 500 -> {d}, 5000 -> {d}\n", .{ moved[0], moved[1] });
    try w.print("T1 only by `i` over class content, ASCII pattern text: unique {d}, occurrences {d}, packages {d}\n", .{ i_via_classes[0], i_via_classes[1], i_via_classes[2] });
    try w.print("\nFeatures behind T1/T2 (unique regexes):\n", .{});
    for (reasons, 0..) |n, i| if (n > 0) try w.print("  {s}: {d}\n", .{ @tagName(@as(analysis.Feature, @enumFromInt(i))), n });
    try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
}

fn asciiText(p: []const u8) bool {
    for (p, 0..) |c, i| {
        if (c >= 0x80) return false;
        if (c == '\\' and i + 1 < p.len and (p[i + 1] == 'u' or p[i + 1] == 'p' or p[i + 1] == 'P')) return false;
        if (c == '\\' and i + 2 < p.len and p[i + 1] == 'x' and p[i + 2] >= '8') return false;
    }
    return true;
}

fn sum(xs: []const u64) u64 {
    var t: u64 = 0;
    for (xs) |x| t += x;
    return t;
}

fn pct(n: u64, total: u64) f64 {
    return if (total == 0) 0 else 100.0 * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(total));
}

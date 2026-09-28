//! Case-insensitive matching data: ECMA-262's Canonicalize as equivalence
//! classes (F5b), and the simple (1-to-1) case mapping.
//!
//! **Canonicalize (F5b).** Two characters match under `i` when they
//! canonicalize to the same value, so each non-trivial class of equal
//! values is what a character matches. There are two rules:
//! - `unicode` (`u`/`v`): CaseFolding.txt's simple folding (C + S);
//! - `legacy` (no `u`): the full `toUppercase` when it is one code unit and
//!   doesn't take a code point >= 128 below 128, over the BMP.
//! The classes are generated (`FOLD_U_*`, `FOLD_LEGACY_*` in `tables.zig`);
//! both were checked against V8 on every code point (F5b's pre-check).
//!
//! **Simple case mapping (pre-F5b).**
//! "Simple" here means the Unicode Character Database's Simple_Uppercase/
//! Simple_Lowercase_Mapping fields (one codepoint maps to exactly one other
//! codepoint) -- not full case folding (`CaseFolding.txt`), which also
//! handles multi-codepoint expansions like German `ß` -> `ss`. JS regex
//! case-insensitive matching itself only does simple, per-codepoint folding
//! (a regex `/ß/i` does not match `"ss"` in JS either), so this is the
//! spec-correct primitive for that purpose.

const std = @import("std");
const tables = @import("tables.zig");

/// Which Canonicalize: with `u`/`v` (`unicode`) or without (`legacy`).
pub const FoldMode = enum { unicode, legacy };

const Tables = struct {
    cps: []const u32,
    class: []const u16,
    members: []const u32,
    start: []const u16,
    canon: []const u32,
};

fn tablesFor(mode: FoldMode) Tables {
    return switch (mode) {
        .unicode => .{ .cps = tables.FOLD_U_CPS, .class = tables.FOLD_U_CLASS, .members = tables.FOLD_U_MEMBERS, .start = tables.FOLD_U_START, .canon = tables.FOLD_U_CANON },
        .legacy => .{ .cps = tables.FOLD_LEGACY_CPS, .class = tables.FOLD_LEGACY_CLASS, .members = tables.FOLD_LEGACY_MEMBERS, .start = tables.FOLD_LEGACY_START, .canon = tables.FOLD_LEGACY_CANON },
    };
}

/// The index of the first entry of the sorted `cps` that is >= `cp`.
fn lowerBound(cps: []const u32, cp: u32) usize {
    var lo: usize = 0;
    var hi: usize = cps.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cps[mid] < cp) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The class index of `cp`, or null if it only matches itself.
fn classIndex(t: Tables, cp: u32) ?u16 {
    const i = lowerBound(t.cps, cp);
    if (i == t.cps.len or t.cps[i] != cp) return null;
    return t.class[i];
}

fn members(t: Tables, k: u16) []const u32 {
    return t.members[t.start[k]..t.start[k + 1]];
}

/// ECMA-262's Canonicalize(ch) under `i`, as a class representative: two
/// characters match iff their values are equal. `cp` itself when it only
/// matches itself.
pub fn canonicalize(cp: u32, mode: FoldMode) u32 {
    const t = tablesFor(mode);
    const k = classIndex(t, cp) orelse return cp;
    return t.canon[k];
}

/// Every character `cp` matches under `i` (itself included), sorted; null
/// when it only matches itself.
pub fn class(cp: u32, mode: FoldMode) ?[]const u32 {
    const t = tablesFor(mode);
    const k = classIndex(t, cp) orelse return null;
    return members(t, k);
}

/// The code points folding adds to the union of `ranges` (sorted, inclusive
/// [lo, hi] pairs): the members, outside the ranges, of every class that
/// has one inside. Appended to `out` in no particular order. The cost is in
/// the foldable code points inside the ranges (a binary search per range),
/// not in their size.
pub fn closureExtra(ranges: []const [2]u32, mode: FoldMode, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u32)) std.mem.Allocator.Error!void {
    const t = tablesFor(mode);
    for (ranges) |r| {
        var i = lowerBound(t.cps, r[0]);
        while (i < t.cps.len and t.cps[i] <= r[1]) : (i += 1) {
            for (members(t, t.class[i])) |m| {
                if (!inRanges(ranges, m)) try out.append(gpa, m);
            }
        }
    }
}

/// The foldable code points inside `ranges` whose class leaves the ranges,
/// appended to `out`. For the closure of a set through its complement:
/// closure(S) = S + leavingMembers(complement(S)).
pub fn leavingMembers(ranges: []const [2]u32, mode: FoldMode, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u32)) std.mem.Allocator.Error!void {
    const t = tablesFor(mode);
    for (ranges) |r| {
        var i = lowerBound(t.cps, r[0]);
        while (i < t.cps.len and t.cps[i] <= r[1]) : (i += 1) {
            for (members(t, t.class[i])) |m| {
                if (!inRanges(ranges, m)) {
                    try out.append(gpa, t.cps[i]);
                    break;
                }
            }
        }
    }
}

/// How many foldable code points `ranges` hold (the work `closureExtra`
/// and `leavingMembers` do over them).
pub fn foldableCount(ranges: []const [2]u32, mode: FoldMode) usize {
    const t = tablesFor(mode);
    var n: usize = 0;
    for (ranges) |r| n += lowerBound(t.cps, r[1] +| 1) - lowerBound(t.cps, r[0]);
    return n;
}

/// How many foldable code points there are in all.
pub fn foldableTotal(mode: FoldMode) usize {
    return tablesFor(mode).cps.len;
}

fn inRanges(ranges: []const [2]u32, cp: u32) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

fn lookup(table: []const tables.CaseMapping, cp: u32) ?u32 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = table[mid];
        if (cp < entry.from) {
            hi = mid;
        } else if (cp > entry.from) {
            lo = mid + 1;
        } else {
            return entry.to;
        }
    }
    return null;
}

/// The codepoint's simple uppercase mapping, or `null` if it has none
/// (including if it's already uppercase, or has no case at all).
pub fn toUpper(cp: u32) ?u32 {
    return lookup(tables.LOWER_TO_UPPER, cp);
}

/// The codepoint's simple lowercase mapping, or `null` if it has none.
pub fn toLower(cp: u32) ?u32 {
    return lookup(tables.UPPER_TO_LOWER, cp);
}

test "casefold: ASCII" {
    try std.testing.expectEqual(@as(?u32, 'a'), toLower('A'));
    try std.testing.expectEqual(@as(?u32, 'A'), toUpper('a'));
    try std.testing.expect(toLower('5') == null);
}

test "casefold: non-ASCII" {
    // é (U+00E9) / É (U+00C9)
    try std.testing.expectEqual(@as(?u32, 0xE9), toLower(0xC9));
    try std.testing.expectEqual(@as(?u32, 0xC9), toUpper(0xE9));
    // Greek alpha: Α (U+0391) / α (U+03B1)
    try std.testing.expectEqual(@as(?u32, 0x3B1), toLower(0x391));
    try std.testing.expectEqual(@as(?u32, 0x391), toUpper(0x3B1));
}

fn expectClass(cp: u32, mode: FoldMode, want: []const u32) !void {
    if (want.len == 0) {
        try std.testing.expect(class(cp, mode) == null);
        try std.testing.expectEqual(cp, canonicalize(cp, mode));
        return;
    }
    try std.testing.expectEqualSlices(u32, want, class(cp, mode).?);
    for (want) |m| try std.testing.expectEqual(canonicalize(cp, mode), canonicalize(m, mode));
}

// V8's answers (F5b's pre-check: `/x/i` and `/x/iu` over every code point).
test "casefold: unicode (u) classes of the edge cases" {
    try expectClass('k', .unicode, &.{ 'K', 'k', 0x212A });
    try expectClass(0x212A, .unicode, &.{ 'K', 'k', 0x212A });
    try expectClass('s', .unicode, &.{ 'S', 's', 0x17F });
    try expectClass(0xDF, .unicode, &.{ 0xDF, 0x1E9E });
    try expectClass(0x3C3, .unicode, &.{ 0x3A3, 0x3C2, 0x3C3 });
    try expectClass(0x3B8, .unicode, &.{ 0x398, 0x3B8, 0x3D1, 0x3F4 });
    try expectClass(0x3B9, .unicode, &.{ 0x345, 0x399, 0x3B9, 0x1FBE });
    try expectClass(0x390, .unicode, &.{ 0x390, 0x1FD3 });
    try expectClass(0x1F80, .unicode, &.{ 0x1F80, 0x1F88 });
    try expectClass(0xFB05, .unicode, &.{ 0xFB05, 0xFB06 });
    try expectClass(0x10400, .unicode, &.{ 0x10400, 0x10428 });
    // Full and Turkic mappings aren't simple folding: no class.
    try expectClass(0xFB00, .unicode, &.{});
    try expectClass(0xFB01, .unicode, &.{});
    try expectClass(0x130, .unicode, &.{});
    try expectClass(0x131, .unicode, &.{});
}

test "casefold: legacy (no u) classes of the edge cases" {
    try expectClass('k', .legacy, &.{ 'K', 'k' });
    try expectClass(0x212A, .legacy, &.{});
    try expectClass('s', .legacy, &.{ 'S', 's' });
    try expectClass(0x17F, .legacy, &.{});
    try expectClass(0xDF, .legacy, &.{});
    try expectClass(0x1E9E, .legacy, &.{});
    try expectClass(0x3C3, .legacy, &.{ 0x3A3, 0x3C2, 0x3C3 });
    try expectClass(0x3B8, .legacy, &.{ 0x398, 0x3B8, 0x3D1 });
    try expectClass(0x390, .legacy, &.{});
    try expectClass(0x1F80, .legacy, &.{});
    try expectClass(0xE9, .legacy, &.{ 0xC9, 0xE9 });
    // Astral code points are two code units without `u`: no class.
    try expectClass(0x10400, .legacy, &.{});
}

test "casefold: every class is consistent" {
    for ([_]FoldMode{ .unicode, .legacy }) |mode| {
        const t = tablesFor(mode);
        for (t.cps, t.class, 0..) |cp, k, i| {
            if (i > 0) try std.testing.expect(t.cps[i - 1] < cp);
            const ms = members(t, k);
            try std.testing.expect(ms.len >= 2);
            try std.testing.expect(std.mem.indexOfScalar(u32, ms, cp) != null);
            try std.testing.expect(std.mem.indexOfScalar(u32, ms, t.canon[k]) != null);
            if (mode == .legacy) try std.testing.expect(cp <= 0xFFFF);
        }
    }
}

test "casefold: closureExtra" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(gpa);
    // [À-Ö]: its lowercase partners, à-ö, and with `u` the Angstrom sign
    // (U+212B, in Å's class; V8 agrees).
    try closureExtra(&.{.{ 0xC0, 0xD6 }}, .unicode, gpa, &out);
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    try std.testing.expectEqual(@as(usize, 24), out.items.len);
    try std.testing.expectEqual(@as(u32, 0xE0), out.items[0]);
    try std.testing.expectEqual(@as(u32, 0xF6), out.items[22]);
    try std.testing.expectEqual(@as(u32, 0x212B), out.items[23]);
    out.clearRetainingCapacity();
    try closureExtra(&.{.{ 0xC0, 0xD6 }}, .legacy, gpa, &out);
    try std.testing.expectEqual(@as(usize, 23), out.items.len);
    // [a-z] under `u` adds A-Z, ſ and the Kelvin sign; without `u`, A-Z only.
    out.clearRetainingCapacity();
    try closureExtra(&.{.{ 'a', 'z' }}, .unicode, gpa, &out);
    try std.testing.expectEqual(@as(usize, 28), out.items.len);
    try std.testing.expect(std.mem.indexOfScalar(u32, out.items, 0x212A) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, out.items, 0x17F) != null);
    out.clearRetainingCapacity();
    try closureExtra(&.{.{ 'a', 'z' }}, .legacy, gpa, &out);
    try std.testing.expectEqual(@as(usize, 26), out.items.len);
    // A closed set adds nothing.
    out.clearRetainingCapacity();
    try closureExtra(&.{ .{ 'A', 'Z' }, .{ 'a', 'z' }, .{ 0x17F, 0x17F }, .{ 0x212A, 0x212A } }, .unicode, gpa, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

//! CharSet: a set of Unicode code points as sorted, merged ranges
//! (docs/REGEX_TIERS_PLAN.md, F2b).
//!
//! A character class compiles to one CharSet, held in
//! `CompileResult.charsets` and referenced from the bytecode by index
//! (`CHAR_SET idx:u32`). Every class member -- literal, range, shorthand,
//! `\p{...}` property table, a `v`-mode set operation -- is materialized at
//! compile time with the algebra below, so the matcher only ever does one
//! `contains` per class.
//!
//! Invariant of every CharSet this module builds: ranges sorted by `lo`,
//! each `lo <= hi <= MAX_CODEPOINT`, and no two ranges overlapping or
//! adjacent (`next.lo > prev.hi + 1`). `eql` and `contains` rely on it.
//!
//! Part of `ir/`, the module F2e shares across Tiers: it must not import
//! `unicode/` (T0 can't depend on the Unicode tables).
//!
//! Strings (`\q{...}`, properties of strings) come with the HIR in F2c.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Largest Unicode code point; `complement` is taken over [0, MAX_CODEPOINT].
pub const MAX_CODEPOINT: u32 = 0x10FFFF;

/// Inclusive code point range. `extern` so a table with the same layout
/// (`unicode/tables.zig`'s `CodepointRange`) can be viewed as ranges without
/// copying (`CharSet.borrowed`).
pub const Range = extern struct {
    lo: u32,
    hi: u32,
};

pub const CharSet = struct {
    /// Owned by the allocator the set was built with (see `deinit`).
    ranges: []const Range,

    const Self = @This();

    pub fn deinit(self: Self, allocator: Allocator) void {
        allocator.free(self.ranges);
    }

    /// Build a set from ranges in any order, possibly overlapping or
    /// adjacent. `ranges` is not modified; each `hi` is clamped to
    /// MAX_CODEPOINT and a range with `lo > hi` is dropped.
    pub fn fromRanges(allocator: Allocator, ranges: []const Range) Allocator.Error!Self {
        const buf = try allocator.alloc(Range, ranges.len);
        errdefer allocator.free(buf);
        var n: usize = 0;
        for (ranges) |r| {
            const hi = @min(r.hi, MAX_CODEPOINT);
            if (r.lo > hi) continue;
            buf[n] = .{ .lo = r.lo, .hi = hi };
            n += 1;
        }
        // Input that already keeps the invariant (e.g. a Unicode property
        // table) needs no sort.
        if (!isNormalized(buf[0..n])) n = normalize(buf[0..n]);
        return .{ .ranges = try shrink(allocator, buf, n) };
    }

    /// A set over `ranges` without copying them, for static tables that
    /// already keep the invariant (checked in safe builds). The result owns
    /// nothing: never `deinit` it (an arena-owned HIR never does).
    pub fn borrowed(ranges: []const Range) Self {
        std.debug.assert(isNormalized(ranges));
        return .{ .ranges = ranges };
    }

    /// A copy of `self` owned by `allocator`.
    pub fn clone(self: Self, allocator: Allocator) Allocator.Error!Self {
        return .{ .ranges = try allocator.dupe(Range, self.ranges) };
    }

    /// Whether `cp` is in the set (binary search).
    pub fn contains(self: Self, cp: u32) bool {
        var lo: usize = 0;
        var hi: usize = self.ranges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = self.ranges[mid];
            if (cp < r.lo) {
                hi = mid;
            } else if (cp > r.hi) {
                lo = mid + 1;
            } else {
                return true;
            }
        }
        return false;
    }

    pub fn isEmpty(self: Self) bool {
        return self.ranges.len == 0;
    }

    /// Same code points. Exact, because both sides keep the invariant.
    pub fn eql(a: Self, b: Self) bool {
        if (a.ranges.len != b.ranges.len) return false;
        for (a.ranges, b.ranges) |x, y| {
            if (x.lo != y.lo or x.hi != y.hi) return false;
        }
        return true;
    }

    /// Bytes the set takes as a range table (8 per range), counted against
    /// the program size cap by the code generator.
    pub fn byteSize(self: Self) usize {
        return self.ranges.len * @sizeOf(Range);
    }

    /// a ∪ b
    pub fn unionWith(a: Self, b: Self, allocator: Allocator) Allocator.Error!Self {
        const buf = try allocator.alloc(Range, a.ranges.len + b.ranges.len);
        errdefer allocator.free(buf);
        // Merge the two sorted lists, then coalesce in one pass.
        var i: usize = 0;
        var j: usize = 0;
        var n: usize = 0;
        while (i < a.ranges.len or j < b.ranges.len) {
            const take_a = j == b.ranges.len or (i < a.ranges.len and a.ranges[i].lo <= b.ranges[j].lo);
            const r = if (take_a) a.ranges[i] else b.ranges[j];
            if (take_a) i += 1 else j += 1;
            n = appendCoalescing(buf, n, r);
        }
        return .{ .ranges = try shrink(allocator, buf, n) };
    }

    /// a ∩ b
    pub fn intersect(a: Self, b: Self, allocator: Allocator) Allocator.Error!Self {
        // Each output range ends where an input range ends, so there are at
        // most len(a) + len(b) of them.
        const buf = try allocator.alloc(Range, a.ranges.len + b.ranges.len);
        errdefer allocator.free(buf);
        var i: usize = 0;
        var j: usize = 0;
        var n: usize = 0;
        while (i < a.ranges.len and j < b.ranges.len) {
            const x = a.ranges[i];
            const y = b.ranges[j];
            const lo = @max(x.lo, y.lo);
            const hi = @min(x.hi, y.hi);
            if (lo <= hi) {
                buf[n] = .{ .lo = lo, .hi = hi };
                n += 1;
            }
            if (x.hi < y.hi) i += 1 else j += 1;
        }
        return .{ .ranges = try shrink(allocator, buf, n) };
    }

    /// [0, MAX_CODEPOINT] \ self
    pub fn complement(self: Self, allocator: Allocator) Allocator.Error!Self {
        const buf = try allocator.alloc(Range, self.ranges.len + 1);
        errdefer allocator.free(buf);
        var n: usize = 0;
        var next: u32 = 0; // first code point not yet covered
        var covered_to_end = false;
        for (self.ranges) |r| {
            if (r.lo > next) {
                buf[n] = .{ .lo = next, .hi = r.lo - 1 };
                n += 1;
            }
            if (r.hi == MAX_CODEPOINT) {
                covered_to_end = true;
                break;
            }
            next = r.hi + 1;
        }
        if (!covered_to_end) {
            buf[n] = .{ .lo = next, .hi = MAX_CODEPOINT };
            n += 1;
        }
        return .{ .ranges = try shrink(allocator, buf, n) };
    }

    /// a \ b
    pub fn difference(a: Self, b: Self, allocator: Allocator) Allocator.Error!Self {
        const not_b = try b.complement(allocator);
        defer not_b.deinit(allocator);
        return a.intersect(not_b, allocator);
    }
};

/// Whether `ranges` already keeps the CharSet invariant: sorted, and no
/// two ranges overlapping or adjacent.
pub fn isNormalized(ranges: []const Range) bool {
    for (ranges, 0..) |r, i| {
        if (r.lo > r.hi) return false;
        if (i > 0 and r.lo <= ranges[i - 1].hi +| 1) return false;
    }
    return true;
}

/// Sort `ranges` by `lo` and coalesce overlapping or adjacent ones in place;
/// returns the new length.
pub fn normalize(ranges: []Range) usize {
    if (ranges.len == 0) return 0;
    std.mem.sort(Range, ranges, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            return a.lo < b.lo;
        }
    }.lessThan);
    var n: usize = 0;
    for (ranges) |r| n = appendCoalescing(ranges, n, r);
    return n;
}

/// Append `r` (whose `lo` is >= every `lo` already in `buf[0..n]`) to
/// `buf[0..n]`, extending the last range instead when they overlap or touch.
fn appendCoalescing(buf: []Range, n: usize, r: Range) usize {
    if (n > 0 and r.lo <= buf[n - 1].hi +| 1) {
        buf[n - 1].hi = @max(buf[n - 1].hi, r.hi);
        return n;
    }
    buf[n] = r;
    return n + 1;
}

/// Return `buf[0..n]` as an exactly-sized allocation, freeing `buf`.
fn shrink(allocator: Allocator, buf: []Range, n: usize) Allocator.Error![]const Range {
    if (n == buf.len) return buf;
    const out = try allocator.dupe(Range, buf[0..n]);
    allocator.free(buf);
    return out;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn set(ranges: []const Range) !CharSet {
    return CharSet.fromRanges(testing.allocator, ranges);
}

fn expectRanges(s: CharSet, expected: []const Range) !void {
    try testing.expectEqualSlices(Range, expected, s.ranges);
}

test "CharSet: fromRanges sorts, merges overlapping and adjacent, clamps" {
    const s = try set(&.{ .{ .lo = 10, .hi = 20 }, .{ .lo = 0, .hi = 3 }, .{ .lo = 21, .hi = 25 }, .{ .lo = 4, .hi = 4 }, .{ .lo = 15, .hi = 18 }, .{ .lo = 30, .hi = 40 } });
    defer s.deinit(testing.allocator);
    try expectRanges(s, &.{ .{ .lo = 0, .hi = 4 }, .{ .lo = 10, .hi = 25 }, .{ .lo = 30, .hi = 40 } });

    const c = try set(&.{ .{ .lo = 0x10FFF0, .hi = 0xFFFFFFFF }, .{ .lo = 9, .hi = 5 } });
    defer c.deinit(testing.allocator);
    try expectRanges(c, &.{.{ .lo = 0x10FFF0, .hi = MAX_CODEPOINT }});

    const e = try set(&.{});
    defer e.deinit(testing.allocator);
    try testing.expect(e.isEmpty());
}

test "CharSet: contains at range edges" {
    const s = try set(&.{ .{ .lo = 0, .hi = 0 }, .{ .lo = 'a', .hi = 'z' }, .{ .lo = MAX_CODEPOINT, .hi = MAX_CODEPOINT } });
    defer s.deinit(testing.allocator);
    try testing.expect(s.contains(0));
    try testing.expect(!s.contains(1));
    try testing.expect(!s.contains('a' - 1));
    try testing.expect(s.contains('a'));
    try testing.expect(s.contains('z'));
    try testing.expect(!s.contains('z' + 1));
    try testing.expect(!s.contains(MAX_CODEPOINT - 1));
    try testing.expect(s.contains(MAX_CODEPOINT));
}

test "CharSet: complement of empty, full and edge-touching sets" {
    const a = testing.allocator;
    const empty = try set(&.{});
    defer empty.deinit(a);
    const full = try empty.complement(a);
    defer full.deinit(a);
    try expectRanges(full, &.{.{ .lo = 0, .hi = MAX_CODEPOINT }});
    const back = try full.complement(a);
    defer back.deinit(a);
    try testing.expect(back.isEmpty());

    const edges = try set(&.{ .{ .lo = 0, .hi = 5 }, .{ .lo = 100, .hi = MAX_CODEPOINT } });
    defer edges.deinit(a);
    const inner = try edges.complement(a);
    defer inner.deinit(a);
    try expectRanges(inner, &.{.{ .lo = 6, .hi = 99 }});

    const mid = try set(&.{.{ .lo = 10, .hi = 20 }});
    defer mid.deinit(a);
    const outer = try mid.complement(a);
    defer outer.deinit(a);
    try expectRanges(outer, &.{ .{ .lo = 0, .hi = 9 }, .{ .lo = 21, .hi = MAX_CODEPOINT } });
}

test "CharSet: union, intersect, difference on hand-picked sets" {
    const a = testing.allocator;
    const x = try set(&.{ .{ .lo = 0, .hi = 10 }, .{ .lo = 20, .hi = 30 } });
    defer x.deinit(a);
    const y = try set(&.{ .{ .lo = 5, .hi = 19 }, .{ .lo = 31, .hi = 31 }, .{ .lo = 40, .hi = 50 } });
    defer y.deinit(a);

    const u = try x.unionWith(y, a);
    defer u.deinit(a);
    try expectRanges(u, &.{ .{ .lo = 0, .hi = 31 }, .{ .lo = 40, .hi = 50 } });

    const i = try x.intersect(y, a);
    defer i.deinit(a);
    try expectRanges(i, &.{.{ .lo = 5, .hi = 10 }});

    const d = try x.difference(y, a);
    defer d.deinit(a);
    try expectRanges(d, &.{ .{ .lo = 0, .hi = 4 }, .{ .lo = 20, .hi = 30 } });

    try testing.expect(!x.eql(y));
    const x2 = try x.clone(a);
    defer x2.deinit(a);
    try testing.expect(x.eql(x2));
}

/// Bitmap reference model on a small universe [0, U).
const U = 96;
const Bits = std.StaticBitSet(U);

fn randomSet(rng: std.Random, ranges: *[8]Range) []Range {
    const count = rng.uintLessThan(usize, 7);
    for (ranges[0..count]) |*r| {
        const lo = rng.uintLessThan(u32, U);
        r.* = .{ .lo = lo, .hi = @min(U - 1, lo + rng.uintLessThan(u32, 12)) };
    }
    return ranges[0..count];
}

fn toBits(ranges: []const Range) Bits {
    var b = Bits.initEmpty();
    for (ranges) |r| {
        var c = r.lo;
        while (c <= r.hi) : (c += 1) b.set(c);
    }
    return b;
}

fn expectMatchesModel(s: CharSet, model: Bits) !void {
    // Invariant: sorted, no overlap or adjacency.
    for (s.ranges, 0..) |r, k| {
        try testing.expect(r.lo <= r.hi);
        if (k > 0) try testing.expect(r.lo > s.ranges[k - 1].hi + 1);
    }
    for (0..U) |c| try testing.expectEqual(model.isSet(c), s.contains(@intCast(c)));
}

test "CharSet: algebra agrees with a bitmap model (random sets)" {
    const a = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xf2b);
    const rng = prng.random();
    var bx: [8]Range = undefined;
    var by: [8]Range = undefined;
    for (0..2000) |_| {
        const rx = randomSet(rng, &bx);
        const ry = randomSet(rng, &by);
        const mx = toBits(rx);
        const my = toBits(ry);
        const x = try set(rx);
        defer x.deinit(a);
        const y = try set(ry);
        defer y.deinit(a);
        try expectMatchesModel(x, mx);

        const u = try x.unionWith(y, a);
        defer u.deinit(a);
        try expectMatchesModel(u, mx.unionWith(my));

        const i = try x.intersect(y, a);
        defer i.deinit(a);
        try expectMatchesModel(i, mx.intersectWith(my));

        const d = try x.difference(y, a);
        defer d.deinit(a);
        try expectMatchesModel(d, mx.differenceWith(my));

        // The complement runs to MAX_CODEPOINT: check the small universe,
        // then that everything above it is in.
        const c = try x.complement(a);
        defer c.deinit(a);
        for (0..U) |cp| try testing.expectEqual(!mx.isSet(cp), c.contains(@intCast(cp)));
        try testing.expect(c.contains(U));
        try testing.expect(c.contains(MAX_CODEPOINT));
        const cc = try c.complement(a);
        defer cc.deinit(a);
        try testing.expect(cc.eql(x));

        try testing.expectEqual(mx.eql(my), x.eql(y));
    }
}

test "CharSet: algebra on the full code point range (sampled)" {
    const a = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x10ffff);
    const rng = prng.random();
    for (0..200) |_| {
        var rx: [16]Range = undefined;
        var ry: [16]Range = undefined;
        for (&rx) |*r| {
            const lo = rng.uintAtMost(u32, MAX_CODEPOINT);
            r.* = .{ .lo = lo, .hi = @min(MAX_CODEPOINT, lo + rng.uintLessThan(u32, 0x2000)) };
        }
        for (&ry) |*r| {
            const lo = rng.uintAtMost(u32, MAX_CODEPOINT);
            r.* = .{ .lo = lo, .hi = @min(MAX_CODEPOINT, lo + rng.uintLessThan(u32, 0x2000)) };
        }
        const x = try set(&rx);
        defer x.deinit(a);
        const y = try set(&ry);
        defer y.deinit(a);
        const u = try x.unionWith(y, a);
        defer u.deinit(a);
        const i = try x.intersect(y, a);
        defer i.deinit(a);
        const d = try x.difference(y, a);
        defer d.deinit(a);
        const c = try x.complement(a);
        defer c.deinit(a);
        // Sample points: every range edge ±1, plus random ones.
        var points: [16 * 2 * 4 * 3 + 64]u32 = undefined;
        var n: usize = 0;
        for ([_][]const Range{ &rx, &ry }) |rs| for (rs) |r| for ([_]u32{ r.lo, r.hi }) |e| {
            points[n] = e;
            points[n + 1] = e -| 1;
            points[n + 2] = @min(MAX_CODEPOINT, e + 1);
            n += 3;
        };
        for (0..64) |_| {
            points[n] = rng.uintAtMost(u32, MAX_CODEPOINT);
            n += 1;
        }
        for (points[0..n]) |p| {
            const inx = x.contains(p);
            const iny = y.contains(p);
            try testing.expectEqual(inx or iny, u.contains(p));
            try testing.expectEqual(inx and iny, i.contains(p));
            try testing.expectEqual(inx and !iny, d.contains(p));
            try testing.expectEqual(!inx, c.contains(p));
        }
    }
}

test "CharSet: allocation failures leak nothing" {
    const x = try set(&.{ .{ .lo = 0, .hi = 10 }, .{ .lo = 20, .hi = 30 } });
    defer x.deinit(testing.allocator);
    const y = try set(&.{.{ .lo = 5, .hi = 25 }});
    defer y.deinit(testing.allocator);
    const Ops = struct {
        fn run(allocator: Allocator, p: CharSet, q: CharSet) !void {
            const d = try p.difference(q, allocator);
            defer d.deinit(allocator);
            const u = try p.unionWith(q, allocator);
            defer u.deinit(allocator);
            const f = try CharSet.fromRanges(allocator, &.{ .{ .lo = 3, .hi = 1 }, .{ .lo = 1, .hi = 2 }, .{ .lo = 2, .hi = 9 } });
            defer f.deinit(allocator);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ops.run, .{ x, y });
}

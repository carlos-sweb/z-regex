//! Case-folding closure of a CharSet (F5b): under `i`, a set matches every
//! character that canonicalizes like one of its members, so it is widened to
//! the union of its members' classes (`unicode.casefold`). Built at
//! compile time; the executors match the widened set as it is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const charset_mod = @import("ir").charset;
const CharSet = charset_mod.CharSet;
const Range = charset_mod.Range;
const unicode = @import("unicode");
const casefold = unicode.casefold;
const properties = unicode.properties;

pub const FoldMode = casefold.FoldMode;

fn pairs(ranges: []const Range) []const [2]u32 {
    comptime std.debug.assert(@sizeOf(Range) == @sizeOf([2]u32));
    return @ptrCast(ranges);
}

/// `set` plus the code points in `extra`, as one set owned by `arena`.
fn withPoints(arena: Allocator, set: CharSet, extra: []const u32) Allocator.Error!CharSet {
    if (extra.len == 0) return set;
    const all = try arena.alloc(Range, set.ranges.len + extra.len);
    @memcpy(all[0..set.ranges.len], set.ranges);
    for (extra, all[set.ranges.len..]) |cp, *r| r.* = .{ .lo = cp, .hi = cp };
    return CharSet.fromRanges(arena, all);
}

/// Which side the closure walks: the set's foldable code points, or its
/// complement's (fewer for a set like `\W`, which holds almost all of them).
pub const Side = enum { auto, set, complement };

/// The closure of `set` under `mode`: every code point whose class meets it.
/// The work is in the foldable code points of the smaller side (at most
/// half of them, ~1,500 with `u`), not in the set's size.
pub fn foldSet(arena: Allocator, set: CharSet, mode: FoldMode) Allocator.Error!CharSet {
    return foldSetSide(arena, set, mode, .auto);
}

pub fn foldSetSide(arena: Allocator, set: CharSet, mode: FoldMode, side: Side) Allocator.Error!CharSet {
    var extra: std.ArrayListUnmanaged(u32) = .empty;
    const inside = casefold.foldableCount(pairs(set.ranges), mode);
    const walk_set = switch (side) {
        .auto => inside * 2 <= casefold.foldableTotal(mode),
        .set => true,
        .complement => false,
    };
    if (walk_set) {
        try casefold.closureExtra(pairs(set.ranges), mode, arena, &extra);
    } else {
        // closure(S) = S + the code points of its complement whose class
        // leaves the complement (reaches S).
        const comp = try set.complement(arena);
        try casefold.leavingMembers(pairs(comp.ranges), mode, arena, &extra);
    }
    return withPoints(arena, set, extra.items);
}

/// The `u` closure of a property table (`\p{...}`), or of its complement
/// (`\P{...}`), from the generated delta: no walk over the property.
pub fn foldProperty(arena: Allocator, table: CharSet, delta: []const properties.CodepointRange, negated: bool) Allocator.Error!CharSet {
    const d: []const Range = @ptrCast(delta);
    if (!negated) return table.unionWith(CharSet.borrowed(d), arena);
    // closure(complement(P)) = complement(P) + the members inside P of the
    // classes that cross P's edge: the classes of the delta's code points.
    var extra: std.ArrayListUnmanaged(u32) = .empty;
    for (d) |r| {
        var cp = r.lo;
        while (cp <= r.hi) : (cp += 1) {
            for (casefold.class(cp, .unicode).?) |m| {
                if (table.contains(m)) try extra.append(arena, m);
            }
        }
    }
    return withPoints(arena, try table.complement(arena), extra.items);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// The closure by brute force: every class of `mode`, whole, if it meets the set.
fn bruteClosure(arena: Allocator, set: CharSet, mode: FoldMode) !CharSet {
    const tables = unicode.tables;
    const cps = if (mode == .unicode) tables.FOLD_U_CPS else tables.FOLD_LEGACY_CPS;
    var extra: std.ArrayListUnmanaged(u32) = .empty;
    for (cps) |cp| {
        if (set.contains(cp)) continue;
        for (casefold.class(cp, mode).?) |m| {
            if (set.contains(m)) {
                try extra.append(arena, cp);
                break;
            }
        }
    }
    return withPoints(arena, set, extra.items);
}

fn setOf(arena: Allocator, ranges: []const Range) !CharSet {
    return CharSet.fromRanges(arena, ranges);
}

test "fold: foldSet agrees with the brute-force closure, both sides, both modes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][]const Range{
        &.{.{ .lo = 0xC0, .hi = 0xD6 }},
        &.{.{ .lo = 'a', .hi = 'z' }},
        &.{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } },
        &.{.{ .lo = 0x3C3, .hi = 0x3C3 }},
        &.{.{ .lo = 0x1E9E, .hi = 0x1E9E }},
        &.{.{ .lo = 0, .hi = 0x10FFFF }},
        &.{},
        &.{ .{ .lo = 0x100, .hi = 0x24F }, .{ .lo = 0x10400, .hi = 0x1040F } },
    };
    var prng = std.Random.DefaultPrng.init(0xF5B);
    const rand = prng.random();
    var random_sets: [40][4]Range = undefined;
    for (&random_sets) |*rs| for (rs) |*r| {
        const lo = rand.intRangeAtMost(u32, 0, 0x2200);
        r.* = .{ .lo = lo, .hi = lo + rand.intRangeAtMost(u32, 0, 300) };
    };
    for ([_]FoldMode{ .unicode, .legacy }) |mode| {
        for (cases) |c| try checkAll(arena, try setOf(arena, c), mode);
        for (&random_sets) |*rs| try checkAll(arena, try setOf(arena, rs), mode);
    }
}

fn checkAll(arena: Allocator, set: CharSet, mode: FoldMode) !void {
    const want = try bruteClosure(arena, set, mode);
    for ([_]Side{ .auto, .set, .complement }) |side| {
        const got = try foldSetSide(arena, set, mode, side);
        try testing.expect(got.eql(want));
    }
}

test "fold: the edge cases (V8's answers)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const k = try foldSet(arena, try setOf(arena, &.{.{ .lo = 'k', .hi = 'k' }}), .unicode);
    try testing.expect(k.contains('K') and k.contains(0x212A));
    const k_legacy = try foldSet(arena, try setOf(arena, &.{.{ .lo = 'k', .hi = 'k' }}), .legacy);
    try testing.expect(k_legacy.contains('K') and !k_legacy.contains(0x212A));
    const a_o = try foldSet(arena, try setOf(arena, &.{.{ .lo = 0xC0, .hi = 0xD6 }}), .legacy);
    try testing.expect(a_o.contains(0xE0) and a_o.contains(0xF6) and !a_o.contains(0xF7));
    const ss = try foldSet(arena, try setOf(arena, &.{.{ .lo = 0xDF, .hi = 0xDF }}), .unicode);
    try testing.expect(ss.contains(0x1E9E) and !ss.contains('s'));
    const ss_legacy = try foldSet(arena, try setOf(arena, &.{.{ .lo = 0xDF, .hi = 0xDF }}), .legacy);
    try testing.expect(!ss_legacy.contains(0x1E9E));
    const fi = try foldSet(arena, try setOf(arena, &.{.{ .lo = 0xFB01, .hi = 0xFB01 }}), .unicode);
    try testing.expectEqual(@as(usize, 1), fi.ranges.len);
}

test "fold: foldProperty is the closure of the property and of its complement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]properties.UnicodeProperty{ .L, .Lu, .Ll, .ASCII, .Nd, .Cased, .Changes_When_Casefolded, .Any }) |p| {
        const table = CharSet.borrowed(@ptrCast(properties.propertyRanges(p)));
        const delta = properties.propertyFoldDelta(p);
        try testing.expect((try foldProperty(arena, table, delta, false)).eql(try bruteClosure(arena, table, .unicode)));
        try testing.expect((try foldProperty(arena, table, delta, true)).eql(try bruteClosure(arena, try table.complement(arena), .unicode)));
    }
    // \p{Lu} under iu matches `a` (V8), \P{Lu} matches `A`.
    const lu = CharSet.borrowed(@ptrCast(properties.propertyRanges(.Lu)));
    try testing.expect((try foldProperty(arena, lu, properties.propertyFoldDelta(.Lu), false)).contains('a'));
    try testing.expect((try foldProperty(arena, lu, properties.propertyFoldDelta(.Lu), true)).contains('A'));
}

test "fold: word_fold is the u closure of the ASCII word characters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const word = try setOf(arena, &.{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } });
    const closed = try foldSet(arena, word, .unicode);
    const extra = try closed.difference(word, arena);
    var n: usize = 0;
    for (extra.ranges) |r| {
        var cp = r.lo;
        while (cp <= r.hi) : (cp += 1) {
            try testing.expect(@import("ir").word.isWordChar(cp, true));
            n += 1;
        }
    }
    try testing.expectEqual(@import("ir").word.extra_count, n);
    // Without `u` the closure adds nothing.
    try testing.expect((try foldSet(arena, word, .legacy)).eql(word));
}

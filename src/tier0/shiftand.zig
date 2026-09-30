//! T0's Shift-And fast path (docs/plans/T0-CB.md, C): a pattern whose
//! program is a straight line of ASCII `char`/`set` instructions is found
//! with one `u64` of state, a bit per position, and no VM.
//!
//! **Predicate** (on the compiled `Program`, so `i`, scopes, `x{n}` and
//! classes are already lowered): `[char | set | save | clear]* match`, no
//! `split`, `jmp`, `assert` or `fail`; every `char` below 0x80 and every
//! `set` non-empty with only ASCII members; 1 to 64 positions. Code-unit
//! mode only, like every prefilter (`pikevm.exec`'s `use_pf`).
//!
//! **Leftmost-first.** With one path and no loop, every match is `m` units
//! long; among matches of one length the earliest start is the earliest
//! end, and the VM's leftmost-first is the earliest start. So the first
//! time bit `m-1` is set, at the end `e`, the match is `[e-m, e]`.
//!
//! **Positions.** A unit at or above 0x80 (a WTF-8 byte of a non-ASCII
//! character, an ill-formed byte, a UTF-16 unit) has an empty mask: no
//! match covers one, so every match starts and ends at a position.
//!
//! With groups, this gives the bounds and `execCaptures` runs the tagged VM
//! on the span only (F4b). Like the other fast paths, it never touches
//! `VmScratch`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Program = @import("program.zig").Program;

pub const max_positions = 64;

pub const ShiftAnd = struct {
    /// `masks[u]`, for each ASCII unit: bit k set when position k accepts
    /// it. 128 entries (1 KiB); a unit from 0x80 up accepts nowhere.
    masks: []const u64,
    /// The pattern's length in units, 1..64.
    m: u32,

    pub fn deinit(self: ShiftAnd, gpa: Allocator) void {
        gpa.free(self.masks);
    }

    inline fn mask(self: *const ShiftAnd, u: u32) u64 {
        return if (u < 0x80) self.masks[u] else 0;
    }

    /// The first match at `index` or after (only at `index` when sticky).
    pub fn find(self: *const ShiftAnd, comptime Unit: type, input: []const Unit, index: usize, sticky: bool) ?[2]usize {
        const m = self.m;
        if (sticky) {
            if (input.len - index < m) return null;
            for (input[index..][0..m], 0..) |u, k| {
                if ((self.mask(u) >> @intCast(k)) & 1 == 0) return null;
            }
            return .{ index, index + m };
        }
        const last = @as(u64, 1) << @intCast(m - 1);
        var d: u64 = 0;
        for (input[index..], index..) |u, i| {
            d = ((d << 1) | 1) & self.mask(u);
            if (d & last != 0) return .{ i + 1 - m, i + 1 };
        }
        return null;
    }
};

/// The Shift-And table for `prog`, or null when the predicate fails.
pub fn of(gpa: Allocator, prog: *const Program) Allocator.Error!?ShiftAnd {
    const insts = prog.insts;
    if (insts.len < 2 or insts[insts.len - 1] != .match) return null;
    const body = insts[0 .. insts.len - 1];
    var m: u32 = 0;
    for (body) |inst| switch (inst) {
        .char => |c| {
            if (c >= 0x80) return null;
            m += 1;
        },
        .set => |i| {
            const ranges = prog.sets[i].set.ranges;
            if (ranges.len == 0 or ranges[ranges.len - 1].hi >= 0x80) return null;
            m += 1;
        },
        .save, .clear => {},
        .split, .jmp, .assert, .fail, .match => return null,
    };
    if (m == 0 or m > max_positions) return null;
    const masks = try gpa.alloc(u64, 0x80);
    @memset(masks, 0);
    var k: u6 = 0;
    for (body) |inst| {
        const bit = @as(u64, 1) << k;
        switch (inst) {
            .char => |c| masks[c] |= bit,
            .set => |i| for (prog.sets[i].set.ranges) |r| {
                for (masks[r.lo .. r.hi + 1]) |*x| x.* |= bit;
            },
            else => continue,
        }
        k +%= 1;
    }
    return .{ .masks = masks, .m = m };
}

const testing = std.testing;
const ir = @import("ir");
const hir = ir.hir;
const CharSet = ir.charset.CharSet;
const compile = @import("compile.zig").compile;
const compileWith = @import("compile.zig").compileWith;

fn lit(comptime s: []const u8) hir.Node {
    const units = comptime blk: {
        var u: [s.len]hir.LitUnit = undefined;
        for (s, 0..) |c, i| u[i] = .{ .value = c };
        const out = u;
        break :blk out;
    };
    return .{ .literal = .{ .units = &units } };
}

fn setNode(set: CharSet) hir.Node {
    return .{ .char_set = .{ .set = set, .inverted = false, .encoding_hint = .set } };
}

/// `of` over `root`'s program (compiled without prefilters, and tagged, so
/// `save`/`clear` show up when there are groups).
fn ofRoot(root: *const hir.Node) !?ShiftAnd {
    const p = try compileWith(testing.allocator, root, .{ .prefilters = false, .tagged = true });
    defer p.deinit(testing.allocator);
    return of(testing.allocator, &p);
}

const digit: CharSet = .{ .ranges = &.{.{ .lo = '0', .hi = '9' }} };

test "predicate: straight ASCII lines, groups allowed" {
    const d = setNode(digit);
    const dash = lit("-");
    const seq: hir.Node = .{ .seq = &.{ &d, &d, &d, &dash, &d } };
    const sa = (try ofRoot(&seq)).?;
    defer sa.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 5), sa.m);
    // A group adds save/clear, not positions.
    const g: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &seq } };
    const sg = (try ofRoot(&g)).?;
    defer sg.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 5), sg.m);
    // One position.
    const one = (try ofRoot(&d)).?;
    defer one.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), one.m);
}

test "predicate: rejects loops, alternation, asserts, non-ASCII, empty, > 64" {
    const a = lit("a");
    const b = lit("b");
    const plus: hir.Node = .{ .repeat = .{ .min = 1, .max = null, .policy = .greedy, .syntax_form = .plus, .body = &a } };
    try testing.expectEqual(null, try ofRoot(&plus));
    const alt: hir.Node = .{ .alt = &.{ &a, &b } };
    try testing.expectEqual(null, try ofRoot(&alt));
    const wb: hir.Node = .{ .assert = .word_boundary };
    const bounded: hir.Node = .{ .seq = &.{ &wb, &a } };
    try testing.expectEqual(null, try ofRoot(&bounded));
    const e9: hir.Node = .{ .literal = .{ .units = &.{.{ .value = 0xE9 }} } };
    try testing.expectEqual(null, try ofRoot(&e9));
    const wide = setNode(.{ .ranges = &.{.{ .lo = 'a', .hi = 0x100 }} });
    try testing.expectEqual(null, try ofRoot(&wide));
    const empty: hir.Node = .{ .seq = &.{} };
    try testing.expectEqual(null, try ofRoot(&empty));
    const n64 = lit("a" ** 64);
    const s64 = (try ofRoot(&n64)).?;
    s64.deinit(testing.allocator);
    const n65 = lit("a" ** 65);
    try testing.expectEqual(null, try ofRoot(&n65));
}

test "table: a bit per position, per member" {
    const d = setNode(digit);
    const x = lit("x");
    const seq: hir.Node = .{ .seq = &.{ &x, &d, &x } };
    const sa = (try ofRoot(&seq)).?;
    defer sa.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0b101), sa.masks['x']);
    try testing.expectEqual(@as(u64, 0b010), sa.masks['0']);
    try testing.expectEqual(@as(u64, 0b010), sa.masks['9']);
    try testing.expectEqual(@as(u64, 0), sa.masks['a']);
    try testing.expectEqual(@as(usize, 0x80), sa.masks.len);
}

test "find: ASCII, overlapping starts, sticky, both encodings" {
    const d = setNode(digit);
    const dash = lit("-");
    const seq: hir.Node = .{ .seq = &.{ &d, &d, &dash, &d } };
    const sa = (try ofRoot(&seq)).?;
    defer sa.deinit(testing.allocator);
    // `23-4`: the start at 1 (`12` then `3`, not `-`) fails, 2 matches.
    try testing.expectEqual(@as(?[2]usize, .{ 2, 6 }), sa.find(u8, "x123-45", 0, false));
    try testing.expectEqual(@as(?[2]usize, .{ 2, 6 }), sa.find(u8, "x123-45", 2, false));
    try testing.expectEqual(@as(?[2]usize, null), sa.find(u8, "x123-45", 3, false));
    try testing.expectEqual(@as(?[2]usize, null), sa.find(u8, "12-", 0, false));
    // Sticky: only at the index.
    try testing.expectEqual(@as(?[2]usize, null), sa.find(u8, "x12-3", 0, true));
    try testing.expectEqual(@as(?[2]usize, .{ 1, 5 }), sa.find(u8, "x12-3", 1, true));
    try testing.expectEqual(@as(?[2]usize, null), sa.find(u8, "x12-", 1, true));
    const s16 = [_]u16{ 'a', '1', '2', '-', '3' };
    try testing.expectEqual(@as(?[2]usize, .{ 1, 5 }), sa.find(u16, &s16, 0, false));
}

test "find: non-ASCII units break a match and never start one" {
    const x = lit("ab");
    const sa = (try ofRoot(&x)).?;
    defer sa.deinit(testing.allocator);
    // WTF-8 `é` is 0xC3 0xA9: masks 0, the search goes on after it.
    try testing.expectEqual(@as(?[2]usize, .{ 3, 5 }), sa.find(u8, "a\xC3\xA9ab", 0, false));
    try testing.expectEqual(@as(?[2]usize, null), sa.find(u8, "a\xC3\xA9b", 0, false));
    // A UTF-16 unit whose low byte is 'a' is not 'a'.
    const s16 = [_]u16{ 0x0161, 'b', 'a', 'b' };
    try testing.expectEqual(@as(?[2]usize, .{ 2, 4 }), sa.find(u16, &s16, 0, false));
    // A unit above 0x80 in the pattern's own position: no match.
    const s16b = [_]u16{ 'a', 0x0162 };
    try testing.expectEqual(@as(?[2]usize, null), sa.find(u16, &s16b, 0, false));
}

test "find: the VM's result on every index (differential)" {
    const pikevm = @import("pikevm.zig");
    const d = setNode(digit);
    const dash = lit("-");
    const seq: hir.Node = .{ .seq = &.{ &d, &d, &d, &dash, &d, &d } };
    const vm_prog = try compileWith(testing.allocator, &seq, .{ .prefilters = false });
    defer vm_prog.deinit(testing.allocator);
    const sa = (try of(testing.allocator, &vm_prog)).?;
    defer sa.deinit(testing.allocator);
    var scratch = pikevm.VmScratch.init(testing.allocator);
    defer scratch.deinit();
    const input = "12-34 555-1234 5555-123-45é12-99-111-22";
    for (0..input.len + 1) |i| {
        var slots: [2]?usize = undefined;
        const vm = pikevm.exec(&vm_prog, u8, input, .code_unit, i, false, &scratch, &slots) catch |err| {
            try testing.expectEqual(error.InvalidIndex, err);
            continue;
        };
        const want: ?[2]usize = if (vm) .{ slots[0].?, slots[1].? } else null;
        try testing.expectEqual(want, sa.find(u8, input, i, false));
    }
}

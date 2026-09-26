//! T0's program (docs/REGEX_TIERS_PLAN.md, F4a): a Thompson NFA built from
//! the HIR (`compile.zig`) and run by the Pike VM. It never reuses the
//! backtracker's bytecode, and of a CharSet node it reads only `set`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const CharSet = @import("ir").charset.CharSet;
const Prefilter = @import("prefilter.zig").Prefilter;

pub const Assert = enum {
    /// `^` without `m`: position 0.
    text_start,
    /// `$` without `m`: the end of the subject.
    text_end,
    /// `^` with `m`: position 0 or right after a LineTerminator.
    line_start,
    /// `$` with `m`: the end or right before a LineTerminator.
    line_end,
    /// `\b` (ASCII word characters, as in ECMA-262 without `u`+`i`).
    word_boundary,
    not_word_boundary,
};

pub const Inst = union(enum) {
    /// One character whose decoded value is exactly this.
    char: u32,
    /// One character in `Program.sets[i]`.
    set: u32,
    /// Continue at `x` and at `y`, `x` first in priority.
    split: struct { x: u32, y: u32 },
    jmp: u32,
    assert: Assert,
    match,
};

/// A CharSet the program owns, with a bitmap of its ASCII members so the
/// common case is one lookup (the monomorphic ASCII path, F3b).
pub const Set = struct {
    set: CharSet,
    ascii: [2]u64,

    pub fn init(gpa: Allocator, set: CharSet) Allocator.Error!Set {
        var ascii: [2]u64 = .{ 0, 0 };
        for (0..128) |c| {
            if (set.contains(@intCast(c))) ascii[c / 64] |= @as(u64, 1) << @intCast(c % 64);
        }
        return .{ .set = try set.clone(gpa), .ascii = ascii };
    }

    pub inline fn contains(self: *const Set, c: u32) bool {
        if (c < 128) return self.ascii[c / 64] & (@as(u64, 1) << @intCast(c % 64)) != 0;
        return self.set.contains(c);
    }
};

pub const Program = struct {
    insts: []const Inst,
    sets: []const Set,
    /// Fast paths and the start-position skip (`prefilter.zig`); empty when
    /// compiled without them.
    prefilter: Prefilter = .{},

    pub fn deinit(self: Program, gpa: Allocator) void {
        self.prefilter.deinit(gpa);
        for (self.sets) |s| s.set.deinit(gpa);
        gpa.free(self.sets);
        gpa.free(self.insts);
    }

    /// A readable listing, for tests.
    pub fn dump(self: Program, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.insts, 0..) |inst, pc| {
            try w.print("{d:>3}: ", .{pc});
            switch (inst) {
                .char => |c| if (c >= 0x20 and c < 0x7F) try w.print("char '{c}'\n", .{@as(u8, @intCast(c))}) else try w.print("char U+{X:0>4}\n", .{c}),
                .set => |i| {
                    try w.print("set {d}:", .{i});
                    const ranges = self.sets[i].set.ranges;
                    for (ranges[0..@min(ranges.len, 4)]) |r| try w.print(" {X}-{X}", .{ r.lo, r.hi });
                    if (ranges.len > 4) try w.writeAll(" ...");
                    try w.writeAll("\n");
                },
                .split => |sp| try w.print("split {d}, {d}\n", .{ sp.x, sp.y }),
                .jmp => |t| try w.print("jmp {d}\n", .{t}),
                .assert => |a| try w.print("assert {s}\n", .{@tagName(a)}),
                .match => try w.writeAll("match\n"),
            }
        }
    }
};

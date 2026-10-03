//! T0's program (docs/REGEX_TIERS_PLAN.md, F4a): a Thompson NFA built from
//! the HIR (`compile.zig`) and run by the Pike VM. It never reuses the
//! backtracker's bytecode, and of a CharSet node it reads only `set`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const CharSet = @import("ir").charset.CharSet;
const Prefilter = @import("prefilter.zig").Prefilter;
const DfaSkip = @import("prefilter.zig").DfaSkip;
const Dfa = @import("dfa.zig").Dfa;

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
    /// Record the position in capture slot `n` (F4b). The VM without
    /// captures passes over it.
    save: u32,
    /// Set capture slots `lo..hi` (exclusive) to "no match": the groups of
    /// a repeat's body, at the start of each iteration (F4b; RepeatMatcher
    /// step 4). The VM without captures passes over it.
    clear: struct { lo: u32, hi: u32 },
    /// A dead end: the end of an iteration that consumed nothing, where
    /// ECMA-262 rejects it (F4b, `compile.zig`'s phase-0 copies).
    fail,
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
        var bits = std.bit_set.IntegerBitSet(128).initEmpty();
        for (set.ranges) |r| {
            if (r.lo >= 128) break;
            bits.setRangeValue(.{ .start = r.lo, .end = @as(usize, @min(r.hi, 127)) + 1 }, true);
        }
        const ascii: [2]u64 = .{ @truncate(bits.mask), @truncate(bits.mask >> 64) };
        return .{ .set = try set.clone(gpa), .ascii = ascii };
    }

    pub inline fn contains(self: *const Set, c: u32) bool {
        if (c < 128) return self.ascii[c / 64] & (@as(u64, 1) << @intCast(c % 64)) != 0;
        return self.set.contains(c);
    }
};

/// The epsilon closure of one pc: `Program.follow[start..][0..len]`, the
/// `char`, `set` and `match` pcs it reaches, in priority order. `dynamic`
/// when it passes through an `assert` (its result depends on the
/// position), or when the table's size cap was reached.
pub const Closure = struct {
    start: u32,
    len: u32,

    pub const dynamic: Closure = .{ .start = 0, .len = std.math.maxInt(u32) };

    pub fn isDynamic(self: Closure) bool {
        return self.len == std.math.maxInt(u32);
    }
};

pub const Program = struct {
    insts: []const Inst,
    sets: []const Set,
    /// One per pc (the VM's `addThread`); empty for a program built by hand.
    closures: []const Closure = &.{},
    /// Capture slots: 2 per group, group 0 (the match) included. Programs
    /// compiled without captures have just group 0.
    nslots: u32 = 2,
    /// The most undo frames one closure of the tagged VM can hold: 1 per
    /// `save`, `hi - lo` per `clear` (each pc is visited once per closure).
    /// Set by `compile`; a program built by hand with `save`/`clear` and
    /// run on the tagged VM must set it too.
    max_undo: u32 = 0,
    /// The pattern's `i` (its root scope): with `u`/`v` (the VM's
    /// code-point mode), `\b`/`\B` count the extended WordCharacters
    /// (`ir.word`, F5b).
    word_ci: bool = false,
    follow: []const u32 = &.{},
    /// Fast paths and the start-position skip (`prefilter.zig`); empty when
    /// compiled without them.
    prefilter: Prefilter = .{},
    /// The DFA (`dfa.zig`, T0-A phase 1): built with the prefilters for a
    /// program without asserts whose route isn't a fast path, within the
    /// cap; null otherwise (the VM runs).
    dfa: ?*const Dfa = null,
    /// The skip the DFA uses in its start state (`prefilter.dfaSkip`).
    dfa_skip: DfaSkip = .none,

    pub fn deinit(self: Program, gpa: Allocator) void {
        if (self.dfa) |d| d.deinit(gpa);
        self.prefilter.deinit(gpa);
        gpa.free(self.closures);
        gpa.free(self.follow);
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
                .save => |n| try w.print("save {d}\n", .{n}),
                .clear => |c| try w.print("clear {d}..{d}\n", .{ c.lo, c.hi }),
                .fail => try w.writeAll("fail\n"),
            }
        }
    }
};

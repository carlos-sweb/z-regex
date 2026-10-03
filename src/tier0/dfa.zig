//! T0's DFA (docs/plans/T0-A.md, T0-A-precheck.md; A phase 1): a program
//! without asserts, compiled into a forward DFA that finds the end of the
//! leftmost-first match and a reverse DFA that finds its start. Built at
//! compile time into the `Program` (immutable, shared like the rest of
//! it), within a cap; above the cap the program runs on the Pike VM.
//!
//! **The alphabet.** Characters (the values `decodeAt` gives, code-unit
//! mode) fall into equivalence classes: the cuts of every `char` and `set`
//! range split the code space into intervals, and intervals with the same
//! membership in every `char`/`set` share a class. An ill-formed WTF-8
//! byte (`Decoded.invalid`) matches no `char` but a `set` by its value, as
//! on the VM, so it has its own family of classes. At run time a unit
//! below 0x80 takes its class from a 128-entry table; the rest go through
//! a binary search over the cuts.
//!
//! **The forward DFA is the VM with its threads merged into states.** A
//! state is the VM's thread list at a position before its closure: the
//! target pcs in priority order, whether a match has been recorded, and
//! whether pc 0 is still seeded (not when sticky). Its closure is the
//! pcs' `follow` lists in order, deduplicated as `addThread` does, then
//! pc 0's while seeding and no match. If `match` is in it, a match ends at
//! the state's position and the lower-priority pcs after it are dropped.
//! Stepping a class keeps the pcs that accept it, their `pc + 1` the next
//! targets. A state with no targets, when nothing more can be seeded, is
//! dead. Without asserts the closure doesn't depend on the next character,
//! so "a match ends here" is a property of the state. So it's the same
//! search as the VM's, and gives the same end: the last match recorded
//! before the dead state or the end of the input.
//!
//! **The reverse DFA finds the start.** From the end `e`, leftwards, a
//! state is the set of consuming pcs from which the text up to `e` leads
//! to `match`; a match can start at `t` when that set meets pc 0's
//! closure. The start is the leftmost such `t` not below `index`: `[s0, e]`
//! is a match (the leftmost-first one), and no match starts before `s0`,
//! so no `t < s0` qualifies either.
//!
//! **Tight tables.** State ids are premultiplied by the row width, and the
//! special states come first: forward, the dead state, the match states,
//! then the unanchored start; reverse, the dead state and the states a
//! match can start in. One compare per unit tells a special state apart.
//!
//! **Assertions (A phase 2).** `^`, `$`, `\b` and `\B` look at the
//! characters on both sides of a position. A program with any gets `Ctx`
//! tables instead: the state also holds the context of the character on
//! one side (the text's edge, a line terminator, a word character or
//! another), and a closure is resolved one character later, when the other
//! side is known. So "a match ends here" (forward) and "a match can start
//! here" (reverse) mark transitions, not states; forward has a column for
//! the end of the input, reverse four for the context at `index`. The
//! closure is `addClosure`'s walk with the asserts evaluated as `Vm.holds`
//! does, from the two contexts.
//!
//! **Code points (A phase 3).** A `u`/`v` program gets its DFA in
//! code-point mode (`Dfa.mode`): the same tables over the values
//! `decodeAt(.code_point)` gives, where a valid surrogate pair is one astral
//! value and a lone surrogate its own. Below 0x80 a unit is a whole
//! character in both modes, so the ASCII table doesn't change; only the
//! slow path decodes in the DFA's mode. With `i` too, `\b` takes the
//! extended word characters (`word.extra`), as `Vm.isWordBoundary` does.
//! `\p{…}` gives thousands of cuts, so a class's membership in each set is
//! a sweep over its sorted ranges, not a search per cut.

const std = @import("std");
const Allocator = std.mem.Allocator;
const subject_mod = @import("subject");
const Subject = subject_mod.Subject;
const Decoded = subject_mod.Decoded;
const Mode = subject_mod.Mode;
const Program = @import("program.zig").Program;
const word = @import("ir").word;

/// The cap (docs/plans/T0-A-precheck.md §2): forward and reverse states
/// together, and table cells (states × classes). Above it: no DFA.
pub const max_states = 1024;
pub const max_cells = 32768;

pub const Dfa = struct {
    /// Interval starts (`cuts[0]` is 0); interval k is `[cuts[k], cuts[k+1])`.
    cuts: []const u32,
    /// The class of interval k, for a well-formed and an ill-formed value.
    valid: []const u32,
    bad: []const u32,
    ascii: [128]u32,
    nclass: u32,
    /// The mode the alphabet decodes in (`u`/`v`: code points, A phase 3).
    mode: Mode = .code_unit,
    /// Forward: `ft[st + class]`, ids premultiplied by `nclass`.
    ft: []const u32,
    /// Forward starts: unanchored, sticky.
    fstart: [2]u32,
    /// Ids up to here are special: 0 dead, then match states (up to
    /// `fmatch_max`), then the unanchored start (when it isn't a match
    /// state).
    fmatch_max: u32,
    fspecial_max: u32,
    /// Reverse: `rt[st + class]`; 0 dead, then the states a match can start
    /// in (up to `rok_max`).
    rt: []const u32,
    rstart: u32,
    rok_max: u32,
    /// Forward and reverse states (for tests and diagnostics).
    fstates: u32,
    rstates: u32,
    /// The tables of a program with assertions (then the ones above, but
    /// the alphabet, are empty).
    ctx: ?Ctx = null,

    pub fn deinit(self: *const Dfa, gpa: Allocator) void {
        if (self.ctx) |c| c.deinit(gpa);
        gpa.free(self.cuts);
        gpa.free(self.valid);
        gpa.free(self.bad);
        gpa.free(self.ft);
        gpa.free(self.rt);
        gpa.destroy(self);
    }

    pub inline fn classOf(self: *const Dfa, d: Decoded) u32 {
        if (!d.invalid and d.value < 128) return self.ascii[d.value];
        return self.classOfSlow(d.value, d.invalid);
    }

    fn classOfSlow(self: *const Dfa, v: u32, invalid: bool) u32 {
        var lo: usize = 0;
        var hi: usize = self.cuts.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.cuts[mid] <= v) lo = mid else hi = mid;
        }
        return if (invalid) self.bad[lo] else self.valid[lo];
    }

    /// The leftmost-first match at `index` or after (only at `index` when
    /// sticky), in code-unit mode. `skipper` is `{}` or a value with
    /// `next(Unit, input, pos) ?usize`: the next position a match can start
    /// at, used while in the unanchored start state (nothing alive, no
    /// match), as the VM uses it.
    pub fn find(self: *const Dfa, comptime Unit: type, input: []const Unit, index: usize, sticky: bool, skipper: anytype) ?[2]usize {
        if (self.ctx) |*c| return c.find(self, Unit, input, index, sticky, skipper);
        const end = self.forward(Unit, input, index, sticky, skipper) orelse return null;
        if (sticky) return .{ index, end };
        return .{ self.backward(Unit, input, index, end), end };
    }

    fn subjectOf(comptime Unit: type, input: []const Unit) Subject {
        return if (Unit == u8) .{ .wtf8 = input } else .{ .utf16 = input };
    }

    /// `decodeBefore(mode, pos)` for the reverse DFAs, the character
    /// ending at `pos > 0` whose last unit is not ASCII. In WTF-8 the
    /// well-formed 2- and 3-byte sequences (and 4-byte ones in code-point
    /// mode) are read in place: `decodeBefore` tries `midOf` and a full
    /// `seqAt` per length, the reverse DFA's cost on non-ASCII text. A
    /// `b+2` position is never one of these (its `pos - 2` starts a 4-byte
    /// sequence), and every other byte goes the general way.
    inline fn decodeBack(mode: Mode, comptime Unit: type, input: []const Unit, pos: usize) Decoded {
        if (Unit == u8) {
            const c1 = input[pos - 1];
            if (c1 & 0xC0 == 0x80 and pos >= 2) {
                const b2 = input[pos - 2];
                if (b2 >= 0xC2 and b2 <= 0xDF)
                    return .{ .value = (@as(u32, b2 & 0x1F) << 6) | (c1 & 0x3F), .pos = pos - 2 };
                if (b2 & 0xC0 == 0x80 and pos >= 3) {
                    const b3 = input[pos - 3];
                    if (b3 >= 0xE0 and b3 <= 0xEF and (b3 != 0xE0 or b2 >= 0xA0))
                        return .{ .value = (@as(u32, b3 & 0x0F) << 12) | (@as(u32, b2 & 0x3F) << 6) | (c1 & 0x3F), .pos = pos - 3 };
                    if (mode == .code_point and b3 & 0xC0 == 0x80 and pos >= 4) {
                        const b4 = input[pos - 4];
                        if (b4 >= 0xF0 and b4 <= 0xF4 and (b4 != 0xF0 or b3 >= 0x90) and (b4 != 0xF4 or b3 <= 0x8F))
                            return .{ .value = (@as(u32, b4 & 0x07) << 18) | (@as(u32, b3 & 0x3F) << 12) | (@as(u32, b2 & 0x3F) << 6) | (c1 & 0x3F), .pos = pos - 4 };
                    }
                }
            }
        }
        return subjectOf(Unit, input).decodeBefore(mode, pos).?;
    }

    fn forward(self: *const Dfa, comptime Unit: type, input: []const Unit, index: usize, sticky: bool, skipper: anytype) ?usize {
        const skips = @TypeOf(skipper) != void;
        var sk = skipper;
        const ft = self.ft;
        var st = self.fstart[@intFromBool(sticky)];
        var pos = index;
        var end: ?usize = null;
        while (true) {
            if (st <= self.fspecial_max) {
                if (st == 0) break;
                if (st <= self.fmatch_max) {
                    end = pos;
                } else if (skips) {
                    // The unanchored start: nothing alive, no match.
                    pos = sk.next(Unit, input, pos) orelse break;
                }
            }
            if (pos >= input.len) break;
            const u = input[pos];
            if (u < 0x80) {
                st = ft[st + self.ascii[u]];
                pos += 1;
            } else {
                const d = subjectOf(Unit, input).decodeAt(self.mode, pos).?;
                st = ft[st + self.classOf(d)];
                pos = d.pos;
            }
        }
        return end;
    }

    fn backward(self: *const Dfa, comptime Unit: type, input: []const Unit, index: usize, e: usize) usize {
        const rt = self.rt;
        var st = self.rstart;
        var s: usize = e;
        var found = st <= self.rok_max;
        var pos = e;
        while (pos > index) {
            const u = input[pos - 1];
            if (u < 0x80) {
                st = rt[st + self.ascii[u]];
                pos -= 1;
            } else {
                var d = decodeBack(self.mode, Unit, input, pos);
                if (d.pos < index) {
                    // A character straddling `index`: from `index`, forward
                    // decoding saw only its part at `index`.
                    const f = subjectOf(Unit, input).decodeAt(self.mode, index).?;
                    d = .{ .value = f.value, .pos = index, .invalid = f.invalid };
                }
                st = rt[st + self.classOf(d)];
                pos = d.pos;
            }
            if (st <= self.rok_max) {
                if (st == 0) break;
                s = pos;
                found = true;
            }
        }
        std.debug.assert(found);
        return s;
    }
};

/// Whether `prog` can have a DFA: every closure precomputed (no asserts),
/// or asserts (the `Ctx` tables walk the closures themselves). A closure
/// left dynamic by the size cap of `follow` alone gets none.
pub fn eligible(prog: *const Program) bool {
    if (hasAsserts(prog)) return true;
    if (prog.closures.len != prog.insts.len) return false;
    for (prog.closures) |cl| if (cl.isDynamic()) return false;
    return true;
}

fn hasAsserts(prog: *const Program) bool {
    for (prog.insts) |inst| if (inst == .assert) return true;
    return false;
}

fn followOf(prog: *const Program, pc: usize) []const u32 {
    const cl = prog.closures[pc];
    return prog.follow[cl.start..][0..cl.len];
}

/// The DFA of `prog` (which must be `eligible`), or null above the cap.
pub fn build(gpa: Allocator, prog: *const Program, mode: Mode) Allocator.Error!?*const Dfa {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const n = prog.insts.len;

    // --- The alphabet: consuming pcs, cuts, one signature per class.
    const cons_index = try a.alloc(u32, n);
    var ncons: u32 = 0;
    var cut_list: std.ArrayListUnmanaged(u32) = .empty;
    try cut_list.append(a, 0);
    for (prog.insts, 0..) |inst, pc| switch (inst) {
        .char => |c| {
            cons_index[pc] = ncons;
            ncons += 1;
            try cut_list.appendSlice(a, &.{ c, c + 1 });
        },
        .set => |i| {
            cons_index[pc] = ncons;
            ncons += 1;
            for (prog.sets[i].set.ranges) |r| try cut_list.appendSlice(a, &.{ r.lo, r.hi + 1 });
        },
        else => {},
    };
    const asserts = hasAsserts(prog);
    // With asserts, the word characters and line terminators are cut out
    // too: the context of a class must be one.
    if (asserts) try cut_list.appendSlice(a, &.{ '0', '9' + 1, 'A', 'Z' + 1, '_', '_' + 1, 'a', 'z' + 1, '\n', '\n' + 1, '\r', '\r' + 1, 0x2028, 0x202A });
    // `u`/`v` + `i`: `\b` takes the extended word characters (`Vm.isWordBoundary`).
    const extended = prog.word_ci and mode == .code_point;
    if (asserts and extended) for (word.extra) |c| try cut_list.appendSlice(a, &.{ c, c + 1 });
    std.mem.sort(u32, cut_list.items, {}, std.sort.asc(u32));
    var cuts: std.ArrayListUnmanaged(u32) = .empty;
    for (cut_list.items) |c| {
        if (c > 0x10FFFF) continue;
        if (cuts.items.len != 0 and cuts.items[cuts.items.len - 1] == c) continue;
        try cuts.append(a, c);
    }
    // sigs[class * ncons + k]: whether consuming pc number k accepts it.
    var sigs: std.ArrayListUnmanaged(u8) = .empty;
    var sig_ids: std.StringHashMapUnmanaged(u32) = .empty;
    const valid = try a.alloc(u32, cuts.items.len);
    const bad = try a.alloc(u32, cuts.items.len);
    // With asserts the signature ends with the class's context, so a class
    // never mixes contexts.
    const sig_full = try a.alloc(u8, ncons + 1);
    const sig = if (asserts) sig_full else sig_full[0..ncons];
    // The cuts ascend, so each set's membership is a sweep over its sorted
    // ranges (`ranges[at[k]]` the first not below the cut), not a search
    // per cut: `\p{…}` under `u`/`v` gives thousands of cuts.
    const cons_pc = try a.alloc(u32, ncons);
    for (prog.insts, 0..) |inst, pc| if (inst == .char or inst == .set) {
        cons_pc[cons_index[pc]] = @intCast(pc);
    };
    const at = try a.alloc(usize, ncons);
    @memset(at, 0);
    for (cuts.items, 0..) |v, k| {
        var has_char = false;
        for (cons_pc, 0..) |pc, ci| switch (prog.insts[pc]) {
            .char => |c| {
                sig[ci] = @intFromBool(c == v);
                has_char = has_char or c == v;
            },
            .set => |i| {
                const ranges = prog.sets[i].set.ranges;
                while (at[ci] < ranges.len and ranges[at[ci]].hi < v) at[ci] += 1;
                sig[ci] = @intFromBool(at[ci] < ranges.len and ranges[at[ci]].lo <= v);
            },
            else => unreachable,
        };
        if (asserts) sig[ncons] = contextOf(v, extended);
        // Ill-formed, the same signature without the `char`s (a `set`
        // takes the byte by its value): the same class unless a `char`
        // accepts the interval.
        for ([_]bool{ false, true }) |is_bad| {
            if (is_bad) {
                if (!has_char) {
                    bad[k] = valid[k];
                    break;
                }
                for (cons_pc, 0..) |pc, ci| if (prog.insts[pc] == .char) {
                    sig[ci] = 0;
                };
            }
            const g = try sig_ids.getOrPut(a, sig);
            if (!g.found_existing) {
                g.key_ptr.* = try a.dupe(u8, sig);
                g.value_ptr.* = @intCast(sig_ids.count() - 1);
                try sigs.appendSlice(a, sig[0..ncons]);
            }
            (if (is_bad) bad else valid)[k] = g.value_ptr.*;
        }
    }
    const nclass: u32 = sig_ids.count();
    if (asserts) {
        // The context of each class, from a value of it (a class never
        // mixes contexts: the cuts and the signature above).
        const cat = try a.alloc(u8, nclass);
        for (cuts.items, 0..) |v, k| {
            cat[valid[k]] = contextOf(v, extended);
            cat[bad[k]] = contextOf(v, extended);
        }
        return buildCtx(gpa, a, prog, mode, cuts.items, valid, bad, nclass, sigs.items, cons_index, ncons, cat);
    }

    // --- The forward DFA over the classes.
    const Keys = struct {
        map: std.StringHashMapUnmanaged(u32) = .empty,
        list: std.ArrayListUnmanaged([]const u32) = .empty,

        fn intern(self: *@This(), al: Allocator, key: []const u32) Allocator.Error!u32 {
            if (self.map.get(std.mem.sliceAsBytes(key))) |id| return id;
            const k = try al.dupe(u32, key);
            const id: u32 = @intCast(self.list.items.len);
            try self.map.put(al, std.mem.sliceAsBytes(k), id);
            try self.list.append(al, k);
            return id;
        }
    };
    const matched_bit: u32 = 1;
    const seed_bit: u32 = 2;
    var fkeys: Keys = .{};
    try fkeys.list.append(a, &.{}); // 0: dead
    const fs_unanch = try fkeys.intern(a, &.{seed_bit});
    const fs_sticky = try fkeys.intern(a, &.{ 0, 0 });
    var ftrans: std.ArrayListUnmanaged(u32) = .empty;
    var fmatch: std.ArrayListUnmanaged(bool) = .empty;
    try fmatch.append(a, false);
    const seen = try a.alloc(u32, n);
    @memset(seen, 0);
    var gen: u32 = 0;
    var list: std.ArrayListUnmanaged(u32) = .empty;
    var next: std.ArrayListUnmanaged(u32) = .empty;
    var si: usize = 1;
    while (si < fkeys.list.items.len) : (si += 1) {
        if (fkeys.list.items.len - 1 > max_states or (fkeys.list.items.len - 1) * nclass > max_cells) return null;
        const key = fkeys.list.items[si];
        const matched = key[0] & matched_bit != 0;
        const seed = key[0] & seed_bit != 0;
        // The closure, as `addThread`: targets in order, then pc 0 while
        // seeding; deduplicated for the whole position.
        gen += 1;
        list.clearRetainingCapacity();
        var is_match = false;
        const sources: [2][]const u32 = .{ key[1..], if (seed and !matched) &.{0} else &.{} };
        outer: for (sources) |src| for (src) |t| for (followOf(prog, t)) |pc| {
            if (seen[pc] == gen) continue;
            seen[pc] = gen;
            if (prog.insts[pc] == .match) {
                is_match = true;
                break :outer;
            }
            try list.append(a, pc);
        };
        try fmatch.append(a, is_match);
        const m2: u32 = if (matched or is_match) matched_bit else 0;
        for (0..nclass) |c| {
            next.clearRetainingCapacity();
            try next.append(a, m2 | (key[0] & seed_bit));
            const row = sigs.items[c * ncons ..][0..ncons];
            for (list.items) |pc| if (row[cons_index[pc]] != 0) try next.append(a, @intCast(pc + 1));
            const dead = next.items.len == 1 and (m2 != 0 or !seed);
            try ftrans.append(a, if (dead) 0 else try fkeys.intern(a, next.items));
        }
    }
    const fn_states: u32 = @intCast(fkeys.list.items.len);

    // --- The reverse DFA: sets of consuming pcs (plus `match` at the end).
    var rkeys: Keys = .{};
    try rkeys.list.append(a, &.{});
    var ends: std.ArrayListUnmanaged(u32) = .empty;
    for (prog.insts, 0..) |inst, pc| if (inst == .match) try ends.append(a, @intCast(pc));
    const rs = try rkeys.intern(a, ends.items);
    const in_set = try a.alloc(bool, n);
    @memset(in_set, false);
    var rtrans: std.ArrayListUnmanaged(u32) = .empty;
    var rok: std.ArrayListUnmanaged(bool) = .empty;
    try rok.append(a, false);
    const c0 = followOf(prog, 0);
    si = 1;
    while (si < rkeys.list.items.len) : (si += 1) {
        const total = fn_states - 1 + rkeys.list.items.len - 1;
        if (total > max_states or total * nclass > max_cells) return null;
        const t = rkeys.list.items[si];
        for (t) |pc| in_set[pc] = true;
        var ok = false;
        for (c0) |pc| ok = ok or in_set[pc];
        try rok.append(a, ok);
        for (0..nclass) |c| {
            next.clearRetainingCapacity();
            const row = sigs.items[c * ncons ..][0..ncons];
            for (prog.insts, 0..) |inst, pc| {
                if (inst != .char and inst != .set) continue;
                if (row[cons_index[pc]] == 0) continue;
                for (followOf(prog, pc + 1)) |q| if (in_set[q]) {
                    try next.append(a, @intCast(pc));
                    break;
                };
            }
            try rtrans.append(a, if (next.items.len == 0) 0 else try rkeys.intern(a, next.items));
        }
        for (t) |pc| in_set[pc] = false;
    }
    const rn_states: u32 = @intCast(rkeys.list.items.len);

    // --- Tight tables: renumber (specials first), premultiply.
    const d = try gpa.create(Dfa);
    errdefer gpa.destroy(d);
    const out_cuts = try gpa.dupe(u32, cuts.items);
    errdefer gpa.free(out_cuts);
    const out_valid = try gpa.dupe(u32, valid);
    errdefer gpa.free(out_valid);
    const out_bad = try gpa.dupe(u32, bad);
    errdefer gpa.free(out_bad);
    const ft = try gpa.alloc(u32, fn_states * nclass);
    errdefer gpa.free(ft);
    const rt = try gpa.alloc(u32, rn_states * nclass);
    errdefer gpa.free(rt);

    const forder = try a.alloc(u32, fn_states);
    const fnew = try a.alloc(u32, fn_states);
    var k: u32 = 0;
    forder[0] = 0;
    k = 1;
    for (1..fn_states) |id| if (fmatch.items[id]) {
        forder[k] = @intCast(id);
        k += 1;
    };
    const fmatch_count = k - 1;
    if (!fmatch.items[fs_unanch]) {
        forder[k] = fs_unanch;
        k += 1;
    }
    const fspecial_count = k - 1;
    for (1..fn_states) |id| if (!fmatch.items[id] and id != fs_unanch) {
        forder[k] = @intCast(id);
        k += 1;
    };
    for (forder, 0..) |old, nw| fnew[old] = @intCast(nw);
    @memset(ft[0..nclass], 0);
    for (forder[1..], 1..) |old, nw| for (0..nclass) |c| {
        ft[nw * nclass + c] = fnew[ftrans.items[(old - 1) * nclass + c]] * nclass;
    };

    const rorder = try a.alloc(u32, rn_states);
    const rnew = try a.alloc(u32, rn_states);
    rorder[0] = 0;
    k = 1;
    for (1..rn_states) |id| if (rok.items[id]) {
        rorder[k] = @intCast(id);
        k += 1;
    };
    const rok_count = k - 1;
    for (1..rn_states) |id| if (!rok.items[id]) {
        rorder[k] = @intCast(id);
        k += 1;
    };
    for (rorder, 0..) |old, nw| rnew[old] = @intCast(nw);
    @memset(rt[0..nclass], 0);
    for (rorder[1..], 1..) |old, nw| for (0..nclass) |c| {
        rt[nw * nclass + c] = rnew[rtrans.items[(old - 1) * nclass + c]] * nclass;
    };

    d.* = .{
        .cuts = out_cuts,
        .valid = out_valid,
        .bad = out_bad,
        .ascii = undefined,
        .mode = mode,
        .nclass = nclass,
        .ft = ft,
        .fstart = .{ fnew[fs_unanch] * nclass, fnew[fs_sticky] * nclass },
        .fmatch_max = fmatch_count * nclass,
        .fspecial_max = fspecial_count * nclass,
        .rt = rt,
        .rstart = rnew[rs] * nclass,
        .rok_max = rok_count * nclass,
        .fstates = fn_states - 1,
        .rstates = rn_states - 1,
    };
    for (0..128) |v| d.ascii[v] = d.classOfSlow(@intCast(v), false);
    return d;
}

// ------------------------------------------------------------ assertions

/// The context of one side of a position: the text's edge (nothing there),
/// a line terminator, a word character (code-unit mode: ASCII only), or
/// another character.
const edge: u8 = 0;
const line: u8 = 1;
const wordc: u8 = 2;
const other: u8 = 3;

fn contextOf(v: u32, extended: bool) u8 {
    if (v == '\n' or v == '\r' or v == 0x2028 or v == 0x2029) return line;
    if (word.isWordChar(v, extended)) return wordc;
    return other;
}

/// `Vm.holds`, from the contexts on the left and on the right.
fn holds(a: anytype, left: u8, right: u8) bool {
    return switch (a) {
        .text_start => left == edge,
        .text_end => right == edge,
        .line_start => left == edge or left == line,
        .line_end => right == edge or right == line,
        .word_boundary => (left == wordc) != (right == wordc),
        .not_word_boundary => (left == wordc) == (right == wordc),
    };
}

const emit: u32 = 1 << 31;

pub const Ctx = struct {
    /// The context of each class.
    cat: []const u8,
    /// Forward: `ft[st + class]` (column `nclass`: the end of the input) is
    /// the next state, `| emit` when a match ends at this position. Ids
    /// premultiplied by `nclass + 1`; 0 dead, 1 to 4 the unanchored starts
    /// (the specials, for the skip).
    ft: []const u32,
    fcol: u32,
    /// `[sticky][context on the left of index]`.
    fstart: [2][4]u32,
    fspecial_max: u32,
    /// Reverse: `rt[st + class]` (columns `nclass + k`: the context `k` on
    /// the left of `index`) is the next state, `| emit` when a match can
    /// start at this position. Ids premultiplied by `nclass + 4`; 0 dead.
    rt: []const u32,
    rcol: u32,
    /// By the context on the right of the match's end.
    rstart: [4]u32,

    fn deinit(self: Ctx, gpa: Allocator) void {
        gpa.free(self.cat);
        gpa.free(self.ft);
        gpa.free(self.rt);
    }

    fn contextBefore(self: *const Ctx, d: *const Dfa, comptime Unit: type, input: []const Unit, i: usize) u8 {
        if (i == 0) return edge;
        const u = input[i - 1];
        if (u < 0x80) return self.cat[d.ascii[u]];
        return self.cat[d.classOf(Dfa.subjectOf(Unit, input).decodeBefore(d.mode, i).?)];
    }

    fn contextAt(self: *const Ctx, d: *const Dfa, comptime Unit: type, input: []const Unit, i: usize) u8 {
        if (i >= input.len) return edge;
        const u = input[i];
        if (u < 0x80) return self.cat[d.ascii[u]];
        return self.cat[d.classOf(Dfa.subjectOf(Unit, input).decodeAt(d.mode, i).?)];
    }

    fn find(self: *const Ctx, d: *const Dfa, comptime Unit: type, input: []const Unit, index: usize, sticky: bool, skipper: anytype) ?[2]usize {
        const end = self.forward(d, Unit, input, index, sticky, skipper) orelse return null;
        if (sticky) return .{ index, end };
        return .{ self.backward(d, Unit, input, index, end), end };
    }

    fn forward(self: *const Ctx, d: *const Dfa, comptime Unit: type, input: []const Unit, index: usize, sticky: bool, skipper: anytype) ?usize {
        const skips = @TypeOf(skipper) != void;
        var sk = skipper;
        const ft = self.ft;
        var st = self.fstart[@intFromBool(sticky)][self.contextBefore(d, Unit, input, index)];
        var pos = index;
        var end: ?usize = null;
        while (true) {
            if (skips and st <= self.fspecial_max) {
                // An unanchored start: nothing alive, no match.
                const to = sk.next(Unit, input, pos) orelse break;
                if (to != pos) {
                    pos = to;
                    st = self.fstart[0][self.contextBefore(d, Unit, input, pos)];
                }
            }
            if (pos >= input.len) {
                if (ft[st + d.nclass] & emit != 0) end = pos;
                break;
            }
            const u = input[pos];
            var e: u32 = undefined;
            var to: usize = undefined;
            if (u < 0x80) {
                e = ft[st + d.ascii[u]];
                to = pos + 1;
            } else {
                const x = Dfa.subjectOf(Unit, input).decodeAt(d.mode, pos).?;
                e = ft[st + d.classOf(x)];
                to = x.pos;
            }
            // The mark is for this position, before the character.
            if (e & emit != 0) end = pos;
            st = e & ~emit;
            if (st == 0) break;
            pos = to;
        }
        return end;
    }

    fn backward(self: *const Ctx, d: *const Dfa, comptime Unit: type, input: []const Unit, index: usize, e: usize) usize {
        const rt = self.rt;
        var st = self.rstart[self.contextAt(d, Unit, input, e)];
        var s: ?usize = null;
        var pos = e;
        while (pos > index) {
            const u = input[pos - 1];
            var t: u32 = undefined;
            var to: usize = undefined;
            if (u < 0x80) {
                t = rt[st + d.ascii[u]];
                to = pos - 1;
            } else {
                var x = Dfa.decodeBack(d.mode, Unit, input, pos);
                if (x.pos < index) {
                    const f = Dfa.subjectOf(Unit, input).decodeAt(d.mode, index).?;
                    x = .{ .value = f.value, .pos = index, .invalid = f.invalid };
                }
                t = rt[st + d.classOf(x)];
                to = x.pos;
            }
            if (t & emit != 0) s = pos;
            st = t & ~emit;
            pos = to;
            if (st == 0) break;
        }
        if (st != 0 and pos == index) {
            if (rt[st + d.nclass + self.contextBefore(d, Unit, input, index)] & emit != 0) s = index;
        }
        return s.?;
    }
};

/// `addClosure`'s walk from `pc0` with the asserts evaluated from `left`
/// and `right`: appends the `char`, `set` and `match` pcs in priority order
/// to `out`, skipping (and marking) those already `seen[pc] == gen`.
const Walker = struct {
    a: Allocator,
    prog: *const Program,
    seen: []u32,
    gen: u32 = 0,
    stack: std.ArrayListUnmanaged(u32) = .empty,

    fn walk(self: *Walker, out: *std.ArrayListUnmanaged(u32), pc0: u32, left: u8, right: u8) Allocator.Error!void {
        self.stack.clearRetainingCapacity();
        try self.stack.append(self.a, pc0);
        while (self.stack.pop()) |start| {
            var pc = start;
            while (self.seen[pc] != self.gen) {
                self.seen[pc] = self.gen;
                switch (self.prog.insts[pc]) {
                    .jmp => |t| pc = t,
                    .split => |sp| {
                        try self.stack.append(self.a, sp.y);
                        pc = sp.x;
                    },
                    .assert => |as| {
                        if (!holds(as, left, right)) break;
                        pc += 1;
                    },
                    .save, .clear => pc += 1,
                    .char, .set, .match => {
                        try out.append(self.a, pc);
                        break;
                    },
                    .fail => break,
                }
            }
        }
    }
};

fn buildCtx(
    gpa: Allocator,
    a: Allocator,
    prog: *const Program,
    mode: Mode,
    cuts: []const u32,
    valid: []const u32,
    bad: []const u32,
    nclass: u32,
    sigs: []const u8,
    cons_index: []const u32,
    ncons: u32,
    cat: []const u8,
) Allocator.Error!?*const Dfa {
    const n = prog.insts.len;
    const fcol = nclass + 1;
    const rcol = nclass + 4;
    const Keys = struct {
        map: std.StringHashMapUnmanaged(u32) = .empty,
        list: std.ArrayListUnmanaged([]const u32) = .empty,

        fn intern(self: *@This(), al: Allocator, key: []const u32) Allocator.Error!u32 {
            if (self.map.get(std.mem.sliceAsBytes(key))) |id| return id;
            const k = try al.dupe(u32, key);
            const id: u32 = @intCast(self.list.items.len);
            try self.map.put(al, std.mem.sliceAsBytes(k), id);
            try self.list.append(al, k);
            return id;
        }
    };
    const seen = try a.alloc(u32, n);
    @memset(seen, 0);
    var w: Walker = .{ .a = a, .prog = prog, .seen = seen };
    var next: std.ArrayListUnmanaged(u32) = .empty;

    // --- Forward. Key: [matched | seed << 1 | left << 2, targets...].
    var fkeys: Keys = .{};
    try fkeys.list.append(a, &.{});
    var fstart_old: [2][4]u32 = undefined;
    for (0..4) |cx| fstart_old[0][cx] = try fkeys.intern(a, &.{2 | @as(u32, @intCast(cx)) << 2});
    for (0..4) |cx| fstart_old[1][cx] = try fkeys.intern(a, &.{ @as(u32, @intCast(cx)) << 2, 0 });
    var ftrans: std.ArrayListUnmanaged(u32) = .empty;
    // The closure of a state depends only on the right context, not on the
    // class: walked once per (state, context), then filtered per class.
    var lists: [4]std.ArrayListUnmanaged(u32) = @splat(.empty);
    var si: usize = 1;
    while (si < fkeys.list.items.len) : (si += 1) {
        if (fkeys.list.items.len - 1 > max_states or (fkeys.list.items.len - 1) * fcol > max_cells) return null;
        const key = fkeys.list.items[si];
        const matched = key[0] & 1 != 0;
        const seed = key[0] & 2 != 0;
        const left: u8 = @intCast(key[0] >> 2);
        var walked: [4]bool = @splat(false);
        for (0..fcol) |c| {
            const right: u8 = if (c == nclass) edge else cat[c];
            const list = &lists[right];
            if (!walked[right]) {
                walked[right] = true;
                w.gen += 1;
                list.clearRetainingCapacity();
                for (key[1..]) |t| try w.walk(list, t, left, right);
                if (seed and !matched) try w.walk(list, 0, left, right);
            }
            next.clearRetainingCapacity();
            try next.append(a, 0);
            var is_match = false;
            for (list.items) |pc| {
                if (prog.insts[pc] == .match) {
                    is_match = true;
                    break;
                }
                if (c != nclass and sigs[c * ncons + cons_index[pc]] != 0) try next.append(a, @intCast(pc + 1));
            }
            const m2 = matched or is_match;
            var nx: u32 = 0;
            if (c != nclass and !(next.items.len == 1 and (m2 or !seed))) {
                next.items[0] = @as(u32, @intFromBool(m2)) | (@as(u32, @intFromBool(seed)) << 1) | (@as(u32, cat[c]) << 2);
                nx = try fkeys.intern(a, next.items);
            }
            try ftrans.append(a, nx | (if (is_match) emit else 0));
        }
    }
    const fn_states: u32 = @intCast(fkeys.list.items.len);

    // --- Reverse. Key: [right, pcs...]: the consuming pcs (or `match`) from
    // which the text up to the end leads to `match`, sorted.
    // Closures of `pc + 1` for each (left, right), computed on demand.
    const memo = try a.alloc(?[]const u32, n * 16);
    @memset(memo, null);
    const Closure = struct {
        fn of(wk: *Walker, mm: []?[]const u32, pc: u32, left: u8, right: u8) Allocator.Error![]const u32 {
            const slot = &mm[@as(usize, pc) * 16 + @as(usize, left) * 4 + right];
            if (slot.*) |got| return got;
            var out: std.ArrayListUnmanaged(u32) = .empty;
            wk.gen += 1;
            try wk.walk(&out, pc, left, right);
            slot.* = out.items;
            return out.items;
        }
    };
    const in_set = try a.alloc(bool, n);
    @memset(in_set, false);
    var rkeys: Keys = .{};
    try rkeys.list.append(a, &.{});
    var ends: std.ArrayListUnmanaged(u32) = .empty;
    try ends.append(a, 0);
    for (prog.insts, 0..) |inst, pc| if (inst == .match) try ends.append(a, @intCast(pc));
    var rstart_old: [4]u32 = undefined;
    for (0..4) |rc| {
        ends.items[0] = @intCast(rc);
        rstart_old[rc] = try rkeys.intern(a, ends.items);
    }
    var rtrans: std.ArrayListUnmanaged(u32) = .empty;
    // Which consuming pcs lead into the state depends only on the left
    // context, not on the class: found once per (state, context), then
    // filtered per class.
    var cands: [4]std.ArrayListUnmanaged(u32) = @splat(.empty);
    // `wanted[left * ncons + i]`: some class in the context `left` accepts
    // the consuming pc `i` (only those closures are walked).
    const wanted = try a.alloc(bool, 4 * ncons);
    @memset(wanted, false);
    for (0..nclass) |c| for (0..ncons) |i| {
        if (sigs[c * ncons + i] != 0) wanted[@as(usize, cat[c]) * ncons + i] = true;
    };
    si = 1;
    while (si < rkeys.list.items.len) : (si += 1) {
        const total = fn_states - 1 + rkeys.list.items.len - 1;
        if (total > max_states or (fn_states - 1) * fcol + (rkeys.list.items.len - 1) * rcol > max_cells) return null;
        const key = rkeys.list.items[si];
        const right: u8 = @intCast(key[0]);
        for (key[1..]) |pc| in_set[pc] = true;
        var starts: [4]?bool = @splat(null);
        var found: [4]bool = @splat(false);
        for (0..rcol) |c| {
            const boundary = c >= nclass;
            const left: u8 = if (boundary) @intCast(c - nclass) else cat[c];
            if (starts[left] == null) {
                starts[left] = false;
                for (try Closure.of(&w, memo, 0, left, right)) |pc| if (in_set[pc]) {
                    starts[left] = true;
                    break;
                };
            }
            var nx: u32 = 0;
            if (!boundary) {
                const cand = &cands[left];
                if (!found[left]) {
                    found[left] = true;
                    cand.clearRetainingCapacity();
                    for (prog.insts, 0..) |inst, pc| {
                        if (inst != .char and inst != .set) continue;
                        if (!wanted[@as(usize, left) * ncons + cons_index[pc]]) continue;
                        for (try Closure.of(&w, memo, @intCast(pc + 1), left, right)) |q| if (in_set[q]) {
                            try cand.append(a, @intCast(pc));
                            break;
                        };
                    }
                }
                next.clearRetainingCapacity();
                try next.append(a, cat[c]);
                for (cand.items) |pc| {
                    if (sigs[c * ncons + cons_index[pc]] != 0) try next.append(a, pc);
                }
                if (next.items.len > 1) nx = try rkeys.intern(a, next.items);
            }
            try rtrans.append(a, nx | (if (starts[left].?) emit else 0));
        }
        for (key[1..]) |pc| in_set[pc] = false;
    }
    const rn_states: u32 = @intCast(rkeys.list.items.len);

    // --- Tables: forward specials (the unanchored starts) first.
    const d = try gpa.create(Dfa);
    errdefer gpa.destroy(d);
    const out_cuts = try gpa.dupe(u32, cuts);
    errdefer gpa.free(out_cuts);
    const out_valid = try gpa.dupe(u32, valid);
    errdefer gpa.free(out_valid);
    const out_bad = try gpa.dupe(u32, bad);
    errdefer gpa.free(out_bad);
    const out_cat = try gpa.dupe(u8, cat);
    errdefer gpa.free(out_cat);
    const ft = try gpa.alloc(u32, fn_states * fcol);
    errdefer gpa.free(ft);
    const rt = try gpa.alloc(u32, rn_states * rcol);
    errdefer gpa.free(rt);

    // The four unanchored starts were interned first: ids 1 to 4 already.
    @memset(ft[0..fcol], 0);
    for (1..fn_states) |id| for (0..fcol) |c| {
        const t = ftrans.items[(id - 1) * fcol + c];
        ft[id * fcol + c] = (t & ~emit) * fcol | (t & emit);
    };
    @memset(rt[0..rcol], 0);
    for (1..rn_states) |id| for (0..rcol) |c| {
        const t = rtrans.items[(id - 1) * rcol + c];
        rt[id * rcol + c] = (t & ~emit) * rcol | (t & emit);
    };
    var fstart: [2][4]u32 = undefined;
    for (0..2) |sk| for (0..4) |cx| {
        fstart[sk][cx] = fstart_old[sk][cx] * fcol;
    };
    var rstart: [4]u32 = undefined;
    for (0..4) |rc| rstart[rc] = rstart_old[rc] * rcol;
    d.* = .{
        .cuts = out_cuts,
        .valid = out_valid,
        .bad = out_bad,
        .ascii = undefined,
        .mode = mode,
        .nclass = nclass,
        .ft = &.{},
        .fstart = .{ 0, 0 },
        .fmatch_max = 0,
        .fspecial_max = 0,
        .rt = &.{},
        .rstart = 0,
        .rok_max = 0,
        .fstates = fn_states - 1,
        .rstates = rn_states - 1,
        .ctx = .{
            .cat = out_cat,
            .ft = ft,
            .fcol = fcol,
            .fstart = fstart,
            .fspecial_max = 4 * fcol,
            .rt = rt,
            .rcol = rcol,
            .rstart = rstart,
        },
    };
    for (0..128) |v| d.ascii[v] = d.classOfSlow(@intCast(v), false);
    return d;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const ir = @import("ir");
const hir = ir.hir;
const CharSet = ir.charset.CharSet;
const compile_mod = @import("compile.zig");
const pikevm = @import("pikevm.zig");

fn lit(comptime s: []const u8) hir.Node {
    const units = comptime blk: {
        var u: [s.len]hir.LitUnit = undefined;
        for (s, 0..) |c, i| u[i] = .{ .value = c };
        const out = u;
        break :blk out;
    };
    return .{ .literal = .{ .units = &units } };
}

fn setNode(ranges: []const ir.charset.Range) hir.Node {
    return .{ .char_set = .{ .set = .{ .ranges = ranges }, .inverted = false, .encoding_hint = .set } };
}

fn rep(body: *const hir.Node, min: u32, max: ?u32) hir.Node {
    return .{ .repeat = .{ .min = min, .max = max, .policy = .greedy, .syntax_form = .counted, .body = body } };
}

/// The program of `root` without prefilters (so no DFA of its own) and
/// its DFA built here.
const Built = struct {
    prog: Program,
    dfa: ?*const Dfa,

    fn init(root: *const hir.Node) !Built {
        const p = try compile_mod.compileWith(testing.allocator, root, .{ .prefilters = false });
        errdefer p.deinit(testing.allocator);
        return .{ .prog = p, .dfa = if (eligible(&p)) try build(testing.allocator, &p, .code_unit) else null };
    }

    fn deinit(self: Built) void {
        if (self.dfa) |d| d.deinit(testing.allocator);
        self.prog.deinit(testing.allocator);
    }
};

const email_user = [_]ir.charset.Range{ .{ .lo = '+', .hi = '+' }, .{ .lo = '-', .hi = '.' }, .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };
const email_host = [_]ir.charset.Range{ .{ .lo = '-', .hi = '-' }, .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };
const email_tld = [_]ir.charset.Range{ .{ .lo = '.', .hi = '.' }, .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };

/// Every index and both stickinesses of `input` (WTF-8, and UTF-16 when it
/// is ASCII) against the VM of the same program.
fn expectSameAsVm(b: *const Built, input: []const u8) !void {
    const d = b.dfa.?;
    var scratch: pikevm.VmScratch = .init(testing.allocator);
    defer scratch.deinit();
    var ascii = true;
    for (input) |c| ascii = ascii and c < 0x80;
    var buf16: [256]u16 = undefined;
    for (input, 0..) |c, i| buf16[i] = c;
    const input16 = buf16[0..input.len];
    for (0..input.len + 1) |i| for ([_]bool{ false, true }) |sticky| {
        var slots: [2]?usize = undefined;
        const vm = pikevm.exec(&b.prog, u8, input, .code_unit, i, sticky, &scratch, &slots) catch |err| {
            try testing.expectEqual(error.InvalidIndex, err);
            continue;
        };
        const want: ?[2]usize = if (vm) .{ slots[0].?, slots[1].? } else null;
        try testing.expectEqual(want, d.find(u8, input, i, sticky, {}));
        if (!ascii) continue;
        const vm16 = try pikevm.exec(&b.prog, u16, input16, .code_unit, i, sticky, &scratch, &slots);
        const want16: ?[2]usize = if (vm16) .{ slots[0].?, slots[1].? } else null;
        try testing.expectEqual(want16, d.find(u16, input16, i, sticky, {}));
    };
}

test "classes: cuts, the ASCII table, ill-formed bytes" {
    const x = lit("x");
    const digit = setNode(&.{.{ .lo = '0', .hi = '9' }});
    const e9 = setNode(&.{.{ .lo = 0xE9, .hi = 0xE9 }});
    const seq: hir.Node = .{ .seq = &.{ &x, &digit, &e9 } };
    const b = try Built.init(&seq);
    defer b.deinit();
    const d = b.dfa.?;
    // x, the digits, U+00E9, everything else: four classes.
    try testing.expectEqual(@as(u32, 4), d.nclass);
    try testing.expect(d.ascii['0'] == d.ascii['9'] and d.ascii['0'] != d.ascii['x'] and d.ascii['a'] == d.ascii['-']);
    try testing.expectEqual(d.classOf(.{ .value = 0xE9, .pos = 0 }), d.classOf(.{ .value = 0xE9, .pos = 0, .invalid = true }));
    try testing.expect(d.classOf(.{ .value = 0xE9, .pos = 0 }) != d.ascii['a']);
    // The ill-formed family: a `char` never matches an invalid value.
    try testing.expect(d.classOf(.{ .value = 'x', .pos = 0, .invalid = true }) != d.ascii['x']);
}

test "states of the bench's e-mail pattern, and a match" {
    const u = setNode(&email_user);
    const h = setNode(&email_host);
    const t = setNode(&email_tld);
    const up = rep(&u, 1, null);
    const hp = rep(&h, 1, null);
    const tp = rep(&t, 1, null);
    const at = lit("@");
    const dot = lit(".");
    const email: hir.Node = .{ .seq = &.{ &up, &at, &hp, &dot, &tp } };
    const b = try Built.init(&email);
    defer b.deinit();
    const d = b.dfa.?;
    // As measured in the precheck's prototype (both anchorings).
    try testing.expectEqual(@as(u32, 14), d.fstates);
    try testing.expectEqual(@as(u32, 7), d.rstates);
    try testing.expectEqual(@as(?[2]usize, .{ 5, 17 }), d.find(u8, "mail joe@site.com and", 0, false, {}));
    try expectSameAsVm(&b, "mail joe@site.com and ann.b+c@x-y.org. @@@ a@ @b a@b @b.c x@@y.z");
    try expectSameAsVm(&b, "é@a.b caf\xC3\xA9 x@y.z \xC3\xA9x@y.z \xE9@\xFFa.b");
}

test "empty matches, laziness, alternation priority, sticky" {
    const a = lit("a");
    const b_ = lit("b");
    const star = rep(&a, 0, null);
    const lazy: hir.Node = .{ .repeat = .{ .min = 1, .max = null, .policy = .lazy, .syntax_form = .plus, .body = &a } };
    const ab = lit("ab");
    const alt: hir.Node = .{ .alt = &.{ &a, &ab } };
    const alt_b: hir.Node = .{ .seq = &.{ &alt, &b_ } };
    for ([_]*const hir.Node{ &star, &lazy, &alt, &alt_b }) |root| {
        const built = try Built.init(root);
        defer built.deinit();
        try expectSameAsVm(&built, "baaab abb aab b");
        try expectSameAsVm(&built, "");
    }
}

test "groups: the bounds of a tagged program" {
    const digit = setNode(&.{.{ .lo = '0', .hi = '9' }});
    const three = rep(&digit, 3, 3);
    const g1: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &three } };
    const dash = lit("-");
    const plus = rep(&digit, 1, null);
    const seq: hir.Node = .{ .seq = &.{ &g1, &dash, &plus } };
    const p = try compile_mod.compileWith(testing.allocator, &seq, .{ .prefilters = false, .tagged = true });
    defer p.deinit(testing.allocator);
    const d = (try build(testing.allocator, &p, .code_unit)).?;
    defer d.deinit(testing.allocator);
    const built: Built = .{ .prog = p, .dfa = d };
    try expectSameAsVm(&built, "12-3 555-1234 55-5 666-7-");
}

test "the cap: a program above it gets no DFA" {
    // `(a|b)*a(a|b){11}`: the forward DFA needs 2^12 states.
    const a = lit("a");
    const b_ = lit("b");
    const ab: hir.Node = .{ .alt = &.{ &a, &b_ } };
    const star = rep(&ab, 0, null);
    const tail = rep(&ab, 11, 11);
    const seq: hir.Node = .{ .seq = &.{ &star, &a, &tail } };
    const built = try Built.init(&seq);
    defer built.deinit();
    try testing.expectEqual(@as(?*const Dfa, null), built.dfa);
    // A shorter tail fits.
    const tail3 = rep(&ab, 3, 3);
    const small: hir.Node = .{ .seq = &.{ &star, &a, &tail3 } };
    const ok = try Built.init(&small);
    defer ok.deinit();
    try testing.expect(ok.dfa != null);
    try expectSameAsVm(&ok, "abababbbaaabab babba");
}

test "eligible: asserts too (A phase 2)" {
    const wb: hir.Node = .{ .assert = .word_boundary };
    const a = lit("a");
    const seq: hir.Node = .{ .seq = &.{ &wb, &a } };
    const p = try compile_mod.compileWith(testing.allocator, &seq, .{ .prefilters = false });
    defer p.deinit(testing.allocator);
    try testing.expect(eligible(&p));
}

fn scopeOf(flags: hir.Flags, body: *const hir.Node) hir.Node {
    return .{ .modifier_scope = .{ .flags = flags, .body = body } };
}

test "asserts: ^ and $, with and without m, against the VM" {
    const caret: hir.Node = .{ .assert = .caret };
    const dollar: hir.Node = .{ .assert = .dollar };
    const abc = lit("abc");
    const a = lit("a");
    const b_ = lit("b");
    const lower = setNode(&.{.{ .lo = 'a', .hi = 'z' }});
    const wrd = rep(&lower, 1, null);
    const caret_abc: hir.Node = .{ .seq = &.{ &caret, &abc } };
    const abc_dollar: hir.Node = .{ .seq = &.{ &abc, &dollar } };
    const caret_a: hir.Node = .{ .seq = &.{ &caret, &a } };
    const b_dollar: hir.Node = .{ .seq = &.{ &b_, &dollar } };
    const either: hir.Node = .{ .alt = &.{ &caret_a, &b_dollar } };
    const whole: hir.Node = .{ .seq = &.{ &caret, &wrd, &dollar } };
    const empty_line: hir.Node = .{ .seq = &.{ &caret, &dollar } };
    const mid: hir.Node = .{ .seq = &.{ &a, &dollar, &b_ } };
    const texts = [_][]const u8{
        "abc\nabc\r\nxabc abc",
        "a\nb\na b\n\nab",
        "abc\xE2\x80\xA8abc\xE2\x80\xA9b",
        "",
        "\n\n",
    };
    for ([_]*const hir.Node{ &caret_abc, &abc_dollar, &either, &whole, &empty_line, &mid }) |root| {
        for ([_]bool{ false, true }) |multiline| {
            const scoped = scopeOf(.{ .multiline = multiline }, root);
            const built = try Built.init(&scoped);
            defer built.deinit();
            try testing.expect(built.dfa.?.ctx != null);
            for (texts) |t| try expectSameAsVm(&built, t);
        }
    }
}

test "asserts: \\b and \\B, next to non-ASCII and ill-formed bytes, against the VM" {
    const wb: hir.Node = .{ .assert = .word_boundary };
    const nwb: hir.Node = .{ .assert = .not_word_boundary };
    const foo = lit("foo");
    const o = lit("o");
    const a = lit("a");
    const lower = setNode(&.{.{ .lo = 'a', .hi = 'z' }});
    const wrd = rep(&lower, 1, null);
    const wfoo: hir.Node = .{ .seq = &.{ &wb, &foo, &wb } };
    const nwo: hir.Node = .{ .seq = &.{ &nwb, &o, &nwb } };
    const a_wb: hir.Node = .{ .seq = &.{ &a, &wb } };
    const wword: hir.Node = .{ .seq = &.{ &wb, &wrd, &wb } };
    const only_wb: hir.Node = .{ .seq = &.{&wb} };
    const star = rep(&lower, 0, null);
    const wstar: hir.Node = .{ .seq = &.{ &wb, &star } };
    const texts = [_][]const u8{
        "foo foofoo _foo foo_ (foo) foo",
        "zoo ooo o oo a ab ba a_",
        "caf\xC3\xA9foo foo\xC3\xA9 \xE9foo foo\xFF",
        "",
        " ",
    };
    for ([_]*const hir.Node{ &wfoo, &nwo, &a_wb, &wword, &only_wb, &wstar }) |root| {
        const built = try Built.init(root);
        defer built.deinit();
        try testing.expect(built.dfa.?.ctx != null);
        for (texts) |t| try expectSameAsVm(&built, t);
    }
}

test "asserts: groups, anchored programs through exec, the cap, and allocation failure" {
    const wb: hir.Node = .{ .assert = .word_boundary };
    const digit = setNode(&.{.{ .lo = '0', .hi = '9' }});
    const three = rep(&digit, 3, 3);
    const g1: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &three } };
    const dash = lit("-");
    const plus = rep(&digit, 1, null);
    const seq: hir.Node = .{ .seq = &.{ &wb, &g1, &dash, &plus, &wb } };
    const p = try compile_mod.compileWith(testing.allocator, &seq, .{ .prefilters = false, .tagged = true });
    defer p.deinit(testing.allocator);
    const d = (try build(testing.allocator, &p, .code_unit)).?;
    defer d.deinit(testing.allocator);
    const built: Built = .{ .prog = p, .dfa = d };
    try expectSameAsVm(&built, "12-3 555-1234 x555-1234 55-5 666-7-");
    // An anchored program through `exec` (its own DFA, with prefilters):
    // the forward DFA at index 0 only.
    const caret: hir.Node = .{ .assert = .caret };
    const anchored: hir.Node = .{ .seq = &.{ &caret, &three, &dash } };
    const ap = try compile_mod.compile(testing.allocator, &anchored);
    defer ap.deinit(testing.allocator);
    try testing.expect(ap.dfa != null and ap.prefilter.anchored);
    var scratch: pikevm.VmScratch = .init(testing.allocator);
    defer scratch.deinit();
    var slots: [2]?usize = undefined;
    try testing.expect(try pikevm.exec(&ap, u8, "555-1234", .code_unit, 0, false, &scratch, &slots));
    try testing.expectEqual(@as(?usize, 4), slots[1]);
    try testing.expect(!try pikevm.exec(&ap, u8, "x555-1234", .code_unit, 0, false, &scratch, &slots));
    try testing.expect(!try pikevm.exec(&ap, u8, "555-1234", .code_unit, 1, false, &scratch, &slots));
    // The cap applies with asserts too.
    const a = lit("a");
    const b_ = lit("b");
    const ab: hir.Node = .{ .alt = &.{ &a, &b_ } };
    const star = rep(&ab, 0, null);
    const tail = rep(&ab, 11, 11);
    const big: hir.Node = .{ .seq = &.{ &star, &a, &tail, &wb } };
    const over = try Built.init(&big);
    defer over.deinit();
    try testing.expectEqual(@as(?*const Dfa, null), over.dfa);
    // No leak on allocation failure.
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(gpa: Allocator, prog: *const Program) !void {
            const dd = (try build(gpa, prog, .code_unit)).?;
            dd.deinit(gpa);
        }
    }.f, .{&p});
}

test "build doesn't leak on allocation failure" {
    const u = setNode(&email_user);
    const up = rep(&u, 1, null);
    const at = lit("@");
    const seq: hir.Node = .{ .seq = &.{ &up, &at, &up } };
    const p = try compile_mod.compileWith(testing.allocator, &seq, .{ .prefilters = false });
    defer p.deinit(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(gpa: Allocator, prog: *const Program) !void {
            const d = (try build(gpa, prog, .code_unit)).?;
            d.deinit(gpa);
        }
    }.f, .{&p});
}

// ---------------------------------------------------- code points (phase 3)

/// The program of `root` in code-point mode (`u`/`v`) twice: with its DFA,
/// and without (the VM alone).
const BuiltCp = struct {
    dfa: Program,
    vm: Program,

    fn init(root: *const hir.Node) !BuiltCp {
        const d = try compile_mod.compileWith(testing.allocator, root, .{ .code_point = true });
        errdefer d.deinit(testing.allocator);
        const v = try compile_mod.compileWith(testing.allocator, root, .{ .code_point = true, .dfa = false });
        return .{ .dfa = d, .vm = v };
    }

    fn deinit(self: BuiltCp) void {
        self.dfa.deinit(testing.allocator);
        self.vm.deinit(testing.allocator);
    }
};

/// Every index (positions or not, as `tier0.exec` gets them) and both
/// stickinesses of `input`, through `exec` in code-point mode: the DFA
/// against the VM.
fn expectCpSame(b: *const BuiltCp, comptime Unit: type, input: []const Unit) !void {
    const d = b.dfa.dfa.?;
    try testing.expectEqual(Mode.code_point, d.mode);
    try testing.expectEqual(DfaSkipNone, b.dfa.dfa_skip);
    var scratch: pikevm.VmScratch = .init(testing.allocator);
    defer scratch.deinit();
    for (0..input.len + 1) |i| for ([_]bool{ false, true }) |sticky| {
        var s1: [2]?usize = undefined;
        var s2: [2]?usize = undefined;
        const got = pikevm.exec(&b.dfa, Unit, input, .code_point, i, sticky, &scratch, &s1);
        const want = pikevm.exec(&b.vm, Unit, input, .code_point, i, sticky, &scratch, &s2);
        if (want) |w| {
            try testing.expectEqual(w, try got);
            if (w) try testing.expectEqual(s2, s1);
        } else |err| try testing.expectError(err, got);
    };
}

const DfaSkipNone = @import("prefilter.zig").DfaSkip.none;

/// A literal of code points (`lit` takes bytes).
fn litCp(comptime cps: []const u32) hir.Node {
    const units = comptime blk: {
        var u: [cps.len]hir.LitUnit = undefined;
        for (cps, 0..) |c, i| u[i] = .{ .value = c };
        const out = u;
        break :blk out;
    };
    return .{ .literal = .{ .units = &units } };
}

/// `text` in WTF-8 and UTF-16, then the extra WTF-8 bytes and UTF-16 units.
fn expectCpSameAll(b: *const BuiltCp, comptime text: []const u8, extra8: []const u8, extra16: []const u16) !void {
    var buf8: [512]u8 = undefined;
    @memcpy(buf8[0..text.len], text);
    @memcpy(buf8[text.len..][0..extra8.len], extra8);
    try expectCpSame(b, u8, buf8[0 .. text.len + extra8.len]);
    const t16 = std.unicode.utf8ToUtf16LeStringLiteral(text);
    var buf16: [512]u16 = undefined;
    @memcpy(buf16[0..t16.len], t16);
    @memcpy(buf16[t16.len..][0..extra16.len], extra16);
    try expectCpSame(b, u16, buf16[0 .. t16.len + extra16.len]);
}

/// Lone surrogates (lead, trail, the two encoded apart), ill-formed bytes
/// (a lone continuation, truncated sequences, 0xFF) and an astral char.
const wtf8_odd = "a\xED\xA0\x80b\xED\xB0\x80c\xED\xA0\x80\xED\xB0\x80d\x80e\xC3f\xE2\x82g\xFF\xF0\x9F\x98\x80h";
/// A lone lead and trail, a reversed pair, a pair, a lead at the end.
const utf16_odd = [_]u16{ 'a', 0xD800, 'b', 0xDC00, 'c', 0xDC00, 0xD800, 'd', 0xD83D, 0xDE00, 0xD800 };

test "code points: astral literals, non-ASCII and astral classes, dot" {
    const grin = litCp(&.{0x1F600});
    const grin_x = litCp(&.{ 0x1F600, 'x' });
    const grins = rep(&grin_x, 1, null);
    // Many ranges, BMP and astral (a `\p{…}` in small): the sweep.
    const letters = setNode(&.{ .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0xC0, .hi = 0xD6 }, .{ .lo = 0xD8, .hi = 0xF6 }, .{ .lo = 0x391, .hi = 0x3A9 }, .{ .lo = 0x3B1, .hi = 0x3C9 }, .{ .lo = 0x10400, .hi = 0x1044F }, .{ .lo = 0x1F600, .hi = 0x1F602 } });
    const word_run = rep(&letters, 1, null);
    const surr = setNode(&.{.{ .lo = 0xD800, .hi = 0xDFFF }});
    const surr_run = rep(&surr, 1, null);
    const dot = setNode(&.{ .{ .lo = 0, .hi = 9 }, .{ .lo = 11, .hi = 12 }, .{ .lo = 14, .hi = 0x2027 }, .{ .lo = 0x202A, .hi = 0x10FFFF } });
    const dot_all = setNode(&.{.{ .lo = 0, .hi = 0x10FFFF }});
    const dots = rep(&dot, 1, null);
    const dot_alls = rep(&dot_all, 2, 2);
    const latin1 = setNode(&.{.{ .lo = 0x80, .hi = 0xFF }});
    const text = "x\u{1F600}x\u{1F600}xy caf\u{E9} \u{391}\u{3B1}\u{10400}! \u{1F601}\u{1F603}\n\u{2028}z\u{E9}";
    for ([_]*const hir.Node{ &grin, &grins, &word_run, &surr_run, &dots, &dot_alls, &latin1 }) |root| {
        const built = try BuiltCp.init(root);
        defer built.deinit();
        try expectCpSameAll(&built, text, wtf8_odd, &utf16_odd);
    }
}

test "code points: \\b with the extended word characters, ^ and $ with LS/PS" {
    const wb: hir.Node = .{ .assert = .word_boundary };
    const nwb: hir.Node = .{ .assert = .not_word_boundary };
    const k = lit("k");
    const any = setNode(&.{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0x17F, .hi = 0x17F }, .{ .lo = 0x212A, .hi = 0x212A }, .{ .lo = 0xE9, .hi = 0xE9 } });
    const run = rep(&any, 1, null);
    const wk: hir.Node = .{ .seq = &.{ &wb, &k, &wb } };
    const wrun: hir.Node = .{ .seq = &.{ &wb, &run, &wb } };
    const nk: hir.Node = .{ .seq = &.{ &nwb, &k } };
    const caret: hir.Node = .{ .assert = .caret };
    const dollar: hir.Node = .{ .assert = .dollar };
    const whole: hir.Node = .{ .seq = &.{ &caret, &run, &dollar } };
    const empty_line: hir.Node = .{ .seq = &.{ &caret, &dollar } };
    const text = "k \u{17F}k \u{212A}k k\u{17F} ok caf\u{E9}k\n\u{2028}ab\u{2029}\r\n\u{17F}\u{2028}\u{2028}";
    for ([_]*const hir.Node{ &wk, &wrun, &nk, &whole, &empty_line }) |root| {
        for ([_]bool{ false, true }) |ci| for ([_]bool{ false, true }) |multiline| {
            const scoped = scopeOf(.{ .ignore_case = ci, .multiline = multiline }, root);
            const built = try BuiltCp.init(&scoped);
            defer built.deinit();
            try testing.expect(built.dfa.dfa.?.ctx != null);
            try expectCpSameAll(&built, text, wtf8_odd, &utf16_odd);
        };
    }
}

test "code points: groups, empty matches, an index inside a pair" {
    const letters = setNode(&.{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0x1F600, .hi = 0x1F64F } });
    const run = rep(&letters, 1, null);
    const g1: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &run } };
    const sp = lit(" ");
    const grouped: hir.Node = .{ .seq = &.{ &g1, &sp } };
    const star = rep(&letters, 0, null);
    const empty: hir.Node = .{ .seq = &.{} };
    // An index between the halves (UTF-16) or at `b+2` (WTF-8): `exec`
    // takes it as is, the DFA must decode as the VM does.
    const text = "ab\u{1F600}\u{1F601} c\u{1F602} \u{1F600}";
    for ([_]*const hir.Node{ &grouped, &star, &empty }) |root| {
        const tagged = root == &grouped;
        const d = try compile_mod.compileWith(testing.allocator, root, .{ .code_point = true, .tagged = tagged });
        errdefer d.deinit(testing.allocator);
        const v = try compile_mod.compileWith(testing.allocator, root, .{ .code_point = true, .dfa = false, .tagged = tagged });
        const built: BuiltCp = .{ .dfa = d, .vm = v };
        defer built.deinit();
        try expectCpSameAll(&built, text, wtf8_odd, &utf16_odd);
    }
}

test "code points: the cap, and allocation failure" {
    const a = litCp(&.{0x1F600});
    const b_ = lit("b");
    const ab: hir.Node = .{ .alt = &.{ &a, &b_ } };
    const star = rep(&ab, 0, null);
    const tail = rep(&ab, 11, 11);
    const big: hir.Node = .{ .seq = &.{ &star, &a, &tail } };
    const over = try compile_mod.compileWith(testing.allocator, &big, .{ .code_point = true });
    defer over.deinit(testing.allocator);
    try testing.expect(eligible(&over));
    try testing.expectEqual(@as(?*const Dfa, null), over.dfa);
    const wb: hir.Node = .{ .assert = .word_boundary };
    const letters = setNode(&.{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0x17F, .hi = 0x17F }, .{ .lo = 0x10400, .hi = 0x1044F } });
    const run = rep(&letters, 1, null);
    const seq: hir.Node = .{ .seq = &.{ &wb, &run, &wb } };
    const scoped = scopeOf(.{ .ignore_case = true }, &seq);
    for ([_]*const hir.Node{ &run, &scoped }) |root| {
        const p = try compile_mod.compileWith(testing.allocator, root, .{ .code_point = true, .dfa = false });
        defer p.deinit(testing.allocator);
        try testing.checkAllAllocationFailures(testing.allocator, struct {
            fn f(gpa: Allocator, prog: *const Program) !void {
                const d = (try build(gpa, prog, .code_point)).?;
                d.deinit(gpa);
            }
        }.f, .{&p});
    }
}

test "decodeBack: decodeBefore at every position of odd WTF-8" {
    const text = "a\xC3\xA9\xCE\xB1\xE2\x82\xAC\xED\x9F\xBF\xED\xA0\x80\xED\xB0\x80\xEF\xBF\xBF\xF0\x9F\x98\x80" ++
        "\xF4\x8F\xBF\xBF\xF4\x90\x80\x80\xE0\x80\x80\xE0\xA0\x80\xC0\x80\xC1\xBF\xF0\x80\x80\x80\xF5\x80\x80\x80" ++
        "\x80\xBF\xC3\xE2\x82\xF0\x9F\x98\xFFz\xED\xA0\x80\xED\xB0\x80\xF0\x9F\x98\x80\x80";
    const subj: Subject = .{ .wtf8 = text };
    for ([_]Mode{ .code_unit, .code_point }) |mode| {
        for (1..text.len + 1) |pos| {
            if (!subj.isPosition(pos) or text[pos - 1] < 0x80) continue;
            try testing.expectEqual(subj.decodeBefore(mode, pos).?, Dfa.decodeBack(mode, u8, text, pos));
        }
    }
}

//! T0's Pike VM (docs/REGEX_TIERS_PLAN.md, F4a): runs a `Program` in
//! O(input × program) with the match ECMA-262's backtracking finds
//! (leftmost-first), without captures.
//!
//! **Priority.** Each thread list is ordered by priority: the order the
//! epsilon closure inserts threads, depth first with a `split`'s `x` before
//! its `y`. A pc already in the list is not inserted again; the thread that
//! got there first has the higher priority and the same future. When a
//! thread reaches `match`, its `(start, end)` is recorded and every thread
//! **after** it in the list (lower priority) is dropped; the threads
//! **before** it (higher priority) have already stepped into the next list
//! and go on. No new thread is seeded once there is a match. If one of the
//! surviving threads reaches `match` later, it replaces the recorded match:
//! what decides is the priority the matching thread had, not whether it was
//! first in its list.
//!
//! **Search.** At each start position a new thread is seeded after the
//! threads carried from earlier positions (lower priority: an earlier start
//! wins, as leftmost requires), while there is no match. The result is the
//! backtracker's at the first start position that matches, like its
//! position-by-position search, advancing with `advanceIndex(mode)`.
//!
//! Each thread carries only its start position: T0 in F4a has no capture
//! groups (F4b).

const std = @import("std");
const Allocator = std.mem.Allocator;
const subject_mod = @import("subject");
const Subject = subject_mod.Subject;
const Mode = subject_mod.Mode;
const Decoded = subject_mod.Decoded;
const Budget = @import("utils").budget.Budget;
const program = @import("program.zig");
const Program = program.Program;
const prefilter = @import("prefilter.zig");

pub const ExecError = Allocator.Error || error{ InvalidIndex, SlotsTooSmall };

pub const ExistsError = Allocator.Error || error{ InvalidIndex, Unsupported, StepLimitExceeded };

/// `execCaptures`: `TwoPassMismatch` is D5's contract broken (the tagged
/// pass didn't end where the first one did), a VM bug.
pub const CaptureError = ExecError || error{TwoPassMismatch};

/// An unset capture slot in the tagged VM's rows.
const none = std.math.maxInt(usize);

/// The tagged closure's work stack (F4b D1): a pc still to explore, or a
/// slot to put back when the walk returns past the `save`/`clear` that
/// changed it.
const Frame = union(enum) {
    explore: u32,
    restore: struct { slot: u32, old: usize },
};

/// A thread list: pcs in insertion (= priority) order, with each thread's
/// start position, and a generation stamp per pc for membership (one load
/// and compare; clearing the list is bumping the generation). Every pc the
/// dynamic closure passes through is inserted (so it is visited once per
/// position); only `char`, `set` and `match` do anything when the list
/// steps.
const List = struct {
    dense: []u32 = &.{},
    starts: []usize = &.{},
    stamp: []u32 = &.{},
    /// The tagged VM's capture slots: a row of `nslots` per pc, written
    /// for the pcs that step or match (`char`, `set`, `match`).
    rows: []usize = &.{},
    gen: u32 = 1,
    len: u32 = 0,

    inline fn contains(self: *const List, pc: u32) bool {
        return self.stamp[pc] == self.gen;
    }

    inline fn insert(self: *List, pc: u32, start: usize) void {
        self.stamp[pc] = self.gen;
        self.dense[self.len] = pc;
        self.starts[self.len] = start;
        self.len += 1;
    }

    /// Insertion for the tagged VM, whose threads carry their start in
    /// their row (slot 0).
    inline fn mark(self: *List, pc: u32) void {
        self.stamp[pc] = self.gen;
        self.dense[self.len] = pc;
        self.len += 1;
    }

    inline fn clear(self: *List) void {
        self.len = 0;
        self.gen +%= 1;
        if (self.gen == 0) {
            // Wrapped: no stale stamp may equal the new generation.
            @memset(self.stamp, 0);
            self.gen = 1;
        }
    }
};

/// The VM's buffers, sized to the largest program run with it. Once warm
/// (grown to a program's size), `exec` allocates nothing.
pub const VmScratch = struct {
    gpa: Allocator,
    lists: [2]List = .{ .{}, .{} },
    /// The closure's pending `split` branches (at most one per `split`).
    stack: []u32 = &.{},
    capacity: usize = 0,
    /// The tagged VM's (`ensureTagged`): the closure's current slots and
    /// the recorded match's, `nslots` each, and the undo stack.
    curr: []usize = &.{},
    frames: []Frame = &.{},
    row_cells: usize = 0,

    pub fn init(gpa: Allocator) VmScratch {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *VmScratch) void {
        self.free();
        self.* = undefined;
    }

    fn free(self: *VmScratch) void {
        for (&self.lists) |*l| {
            self.gpa.free(l.dense);
            self.gpa.free(l.starts);
            self.gpa.free(l.stamp);
            self.gpa.free(l.rows);
        }
        self.gpa.free(self.stack);
        self.gpa.free(self.curr);
        self.gpa.free(self.frames);
    }

    /// Grows the buffers to `n` pcs (all or nothing).
    fn ensure(self: *VmScratch, n: usize) Allocator.Error!void {
        if (n <= self.capacity) return;
        var fresh: [2]List = undefined;
        var done: usize = 0;
        errdefer for (fresh[0..done]) |l| {
            self.gpa.free(l.dense);
            self.gpa.free(l.starts);
            self.gpa.free(l.stamp);
        };
        for (&fresh) |*l| {
            const dense = try self.gpa.alloc(u32, n);
            errdefer self.gpa.free(dense);
            const starts = try self.gpa.alloc(usize, n);
            errdefer self.gpa.free(starts);
            const stamp = try self.gpa.alloc(u32, n);
            @memset(stamp, 0);
            l.* = .{ .dense = dense, .starts = starts, .stamp = stamp };
            done += 1;
        }
        const stack = try self.gpa.alloc(u32, n);
        for (&self.lists) |*l| {
            self.gpa.free(l.dense);
            self.gpa.free(l.starts);
            self.gpa.free(l.stamp);
        }
        self.gpa.free(self.stack);
        for (&self.lists, fresh) |*l, f| {
            l.dense = f.dense;
            l.starts = f.starts;
            l.stamp = f.stamp;
            l.gen = 1;
            l.len = 0;
        }
        self.stack = stack;
        self.capacity = n;
    }

    /// Grows the tagged VM's buffers too: rows of `nslots` for `n` pcs,
    /// and `frames` undo frames. Each buffer grows on its own, all or
    /// nothing.
    fn ensureTagged(self: *VmScratch, n: usize, nslots: usize, frames: usize) Allocator.Error!void {
        try self.ensure(n);
        const cells = n * nslots;
        if (cells > self.row_cells) {
            const r0 = try self.gpa.alloc(usize, cells);
            errdefer self.gpa.free(r0);
            const r1 = try self.gpa.alloc(usize, cells);
            self.gpa.free(self.lists[0].rows);
            self.gpa.free(self.lists[1].rows);
            self.lists[0].rows = r0;
            self.lists[1].rows = r1;
            self.row_cells = cells;
        }
        if (2 * nslots > self.curr.len) {
            const curr = try self.gpa.alloc(usize, 2 * nslots);
            self.gpa.free(self.curr);
            self.curr = curr;
        }
        if (frames > self.frames.len) {
            const f = try self.gpa.alloc(Frame, frames);
            self.gpa.free(self.frames);
            self.frames = f;
        }
    }
};

/// Search `input` from `index` (only at `index` when `sticky`) for the
/// leftmost-first match of `prog`, into `slots[0..2]`. The contract of the
/// backtracker's `Matcher.exec`: an index past the end is no match, one
/// inside a character is `error.InvalidIndex`.
pub fn exec(prog: *const Program, comptime Unit: type, input: []const Unit, mode: Mode, index: usize, sticky: bool, scratch: *VmScratch, slots: []?usize) ExecError!bool {
    if (slots.len < 2) return error.SlotsTooSmall;
    if (index > input.len) return false;
    const vm: Vm(Unit) = .{ .prog = prog, .input = input, .mode = mode };
    if (!vm.subject().isPosition(index)) return error.InvalidIndex;
    const pf = &prog.prefilter;
    // The prefilters hold in code-unit mode only (all of T0 in F4a).
    const use_pf = mode == .code_unit;
    // `^` without `m` leads every path: only position 0 can match.
    const anchored = use_pf and pf.anchored;
    if (anchored and index > 0) return false;
    // The fast paths never touch `scratch` (prefilter.zig's invariant).
    const found = if (use_pf) switch (pf.kind) {
        .literal => |l| literalSearch(Unit, input, if (Unit == u8) l.utf8 else l.utf16, index, sticky),
        .class_run => |*c| classRun(Unit, input, c, index, sticky),
        .first, .none => null,
    } else null;
    const result = found orelse blk: {
        if (use_pf and (pf.kind == .literal or pf.kind == .class_run)) break :blk null;
        try scratch.ensure(prog.insts.len);
        break :blk vm.search(index, sticky or anchored, if (use_pf and pf.kind == .first) &pf.kind.first else null, scratch);
    };
    const m = result orelse return false;
    slots[0] = m[0];
    slots[1] = m[1];
    return true;
}

/// The tagged VM (F4b D1, D2): the leftmost-first match of `prog` with its
/// capture slots, into `slots[0..prog.nslots]` (null: the group didn't
/// take part). The same search, priority and cut as `exec`, without
/// prefilters. With `stop = e` it ends after the position `e` (D5's
/// second pass, which knows where the match ends).
pub fn execTagged(prog: *const Program, comptime Unit: type, input: []const Unit, mode: Mode, index: usize, sticky: bool, stop: ?usize, scratch: *VmScratch, slots: []?usize) ExecError!bool {
    if (slots.len < prog.nslots) return error.SlotsTooSmall;
    if (index > input.len) return false;
    const vm: Vm(Unit) = .{ .prog = prog, .input = input, .mode = mode };
    if (!vm.subject().isPosition(index)) return error.InvalidIndex;
    try scratch.ensureTagged(prog.insts.len, prog.nslots, prog.insts.len + prog.max_undo + 1);
    const found = vm.searchTagged(index, sticky, stop, scratch) orelse return false;
    for (slots[0..prog.nslots], found) |*o, v| o.* = if (v == none) null else v;
    return true;
}

/// D5's two passes: `exec` (prefilters, no captures) finds `[s, e]`; when
/// the program has groups, `execTagged` runs anchored at `s` and stops at
/// `e`. A second pass that doesn't end at `e` is `error.TwoPassMismatch`.
pub fn execCaptures(prog: *const Program, comptime Unit: type, input: []const Unit, mode: Mode, index: usize, sticky: bool, scratch: *VmScratch, slots: []?usize) CaptureError!bool {
    if (slots.len < prog.nslots) return error.SlotsTooSmall;
    if (!try exec(prog, Unit, input, mode, index, sticky, scratch, slots[0..2])) return false;
    if (prog.nslots == 2) return true;
    const s = slots[0].?;
    const e = slots[1].?;
    if (!try execTagged(prog, Unit, input, mode, s, true, e, scratch, slots)) return error.TwoPassMismatch;
    if (slots[0] != s or slots[1] != e) return error.TwoPassMismatch;
    return true;
}

/// The literal fast path: the first occurrence at `index` or after (only
/// at `index` when sticky).
fn literalSearch(comptime Unit: type, input: []const Unit, needle: []const Unit, index: usize, sticky: bool) ?[2]usize {
    if (sticky) {
        if (!std.mem.startsWith(Unit, input[index..], needle)) return null;
        return .{ index, index + needle.len };
    }
    const at = std.mem.indexOfPos(Unit, input, index, needle) orelse return null;
    return .{ at, at + needle.len };
}

/// The class-run fast path: `C+` from the first member at `index` or after
/// (only at `index` when sticky), `C*` at `index` itself, then the longest
/// run.
fn classRun(comptime Unit: type, input: []const Unit, c: *const prefilter.ClassRun, index: usize, sticky: bool) ?[2]usize {
    var start = index;
    if (c.min == 1) {
        if (sticky) {
            if (start >= input.len or !c.has(input[start])) return null;
        } else {
            while (start < input.len and !c.has(input[start])) start += 1;
            if (start == input.len) return null;
        }
    }
    var end = start;
    while (end < input.len and c.has(input[end])) end += 1;
    return .{ start, end };
}

pub const Direction = enum { forward, backward };

/// Whether some match of `prog` starts at `pos` (ends there, backward):
/// any match, not the leftmost-first one, so it stops at the first
/// `match` a thread reaches. For T2's delegation of lookaround bodies
/// (F6a). Every thread step draws one step from `budget`. `.backward`
/// needs the reversed program of F6b and is `error.Unsupported` until then.
pub fn existsAnchoredMatch(prog: *const Program, subj: Subject, mode: Mode, pos: usize, dir: Direction, scratch: *VmScratch, budget: *Budget) ExistsError!bool {
    if (dir == .backward) return error.Unsupported;
    if (pos > subj.len()) return false;
    if (!subj.isPosition(pos)) return error.InvalidIndex;
    try scratch.ensure(prog.insts.len);
    return switch (subj) {
        .wtf8 => |s| (Vm(u8){ .prog = prog, .input = s, .mode = mode }).exists(pos, scratch, budget),
        .utf16 => |s| (Vm(u16){ .prog = prog, .input = s, .mode = mode }).exists(pos, scratch, budget),
    };
}

fn Vm(comptime Unit: type) type {
    comptime std.debug.assert(Unit == u8 or Unit == u16);
    return struct {
        prog: *const Program,
        input: []const Unit,
        mode: Mode,

        const Self = @This();

        fn subject(self: Self) Subject {
            return if (Unit == u8) .{ .wtf8 = self.input } else .{ .utf16 = self.input };
        }

        /// Whether `u` is a whole character by itself: ASCII, and in UTF-16
        /// any unit that isn't a surrogate (the backtracker's inline path).
        inline fn isSingle(u: Unit) bool {
            return if (Unit == u8) u < 0x80 else (u < 0xD800 or u > 0xDFFF);
        }

        inline fn decodeAt(self: Self, pos: usize) ?Decoded {
            if (pos < self.input.len and isSingle(self.input[pos])) return .{ .value = self.input[pos], .pos = pos + 1 };
            return self.subject().decodeAt(self.mode, pos);
        }

        inline fn decodeBefore(self: Self, pos: usize) ?Decoded {
            if (pos > 0 and pos <= self.input.len and isSingle(self.input[pos - 1])) return .{ .value = self.input[pos - 1], .pos = pos - 1 };
            return self.subject().decodeBefore(self.mode, pos);
        }

        fn search(self: Self, index: usize, sticky: bool, first: ?*const prefilter.First, scratch: *VmScratch) ?[2]usize {
            var clist = &scratch.lists[0];
            var nlist = &scratch.lists[1];
            clist.clear();
            var found: ?[2]usize = null;
            var pos = index;
            while (true) {
                // Nothing alive and no match yet: skip to the next position
                // a match can start at (`First`: it always is a position).
                if (first != null and found == null and clist.len == 0 and !sticky) {
                    pos = skip(self.input, first.?, pos) orelse break;
                }
                if (found == null and (!sticky or pos == index)) self.addThread(clist, scratch.stack, 0, pos, pos);
                if (clist.len == 0 and (found != null or sticky)) break;
                const d = self.decodeAt(pos);
                nlist.clear();
                if (clist.len != 0) {
                    const next = if (d) |c| c.pos else pos;
                    for (clist.dense[0..clist.len], clist.starts[0..clist.len]) |pc, start| {
                        switch (self.prog.insts[pc]) {
                            .char => |c| if (d) |x| {
                                if (!x.invalid and x.value == c) self.addThread(nlist, scratch.stack, pc + 1, start, next);
                            },
                            .set => |i| if (d) |x| {
                                if (self.prog.sets[i].contains(x.value)) self.addThread(nlist, scratch.stack, pc + 1, start, next);
                            },
                            .match => {
                                found = .{ start, pos };
                                break;
                            },
                            .split, .jmp, .assert, .save, .clear, .fail => {},
                        }
                    }
                }
                const c = d orelse break;
                pos = c.pos;
                std.mem.swap(*List, &clist, &nlist);
            }
            return found;
        }

        /// `search` with capture slots: each thread's are its row in the
        /// list (slot 0 its start). Returns the recorded match's slots
        /// (`none` for unset), in `scratch.curr`'s second half.
        fn searchTagged(self: Self, index: usize, sticky: bool, stop: ?usize, scratch: *VmScratch) ?[]const usize {
            const ns = self.prog.nslots;
            const curr = scratch.curr[0..ns];
            const best = scratch.curr[ns..][0..ns];
            var clist = &scratch.lists[0];
            var nlist = &scratch.lists[1];
            clist.clear();
            var found = false;
            var pos = index;
            while (true) {
                if (!found and (!sticky or pos == index)) {
                    @memset(curr, none);
                    curr[0] = pos;
                    self.closeTagged(clist, scratch.frames, 0, pos, curr);
                }
                if (clist.len == 0 and (found or sticky)) break;
                const d = self.decodeAt(pos);
                nlist.clear();
                if (clist.len != 0) {
                    const next = if (d) |c| c.pos else pos;
                    for (clist.dense[0..clist.len]) |pc| {
                        const row = clist.rows[pc * ns ..][0..ns];
                        switch (self.prog.insts[pc]) {
                            .char => |c| if (d) |x| {
                                if (!x.invalid and x.value == c) {
                                    @memcpy(curr, row);
                                    self.closeTagged(nlist, scratch.frames, pc + 1, next, curr);
                                }
                            },
                            .set => |i| if (d) |x| {
                                if (self.prog.sets[i].contains(x.value)) {
                                    @memcpy(curr, row);
                                    self.closeTagged(nlist, scratch.frames, pc + 1, next, curr);
                                }
                            },
                            .match => {
                                @memcpy(best, row);
                                best[1] = pos;
                                found = true;
                                break;
                            },
                            .split, .jmp, .assert, .save, .clear, .fail => {},
                        }
                    }
                }
                if (stop) |e| if (pos == e) break;
                const c = d orelse break;
                pos = c.pos;
                std.mem.swap(*List, &clist, &nlist);
            }
            return if (found) best else null;
        }

        /// The epsilon closure of `pc0` at `pos` with the slots in `curr`,
        /// appended to `list` in priority order (depth first, a split's
        /// `x` before its `y`), copying `curr` into the row of each pc
        /// that steps or matches. `save` and `clear` change `curr` and push
        /// the old values; they are put back when the walk pops them, so
        /// the `y` of an earlier split sees `curr` as it was at the split,
        /// and `curr` comes back unchanged. A pc already in the list is not
        /// walked again: its first thread has the higher priority and the
        /// same future (D2).
        fn closeTagged(self: Self, list: *List, frames: []Frame, pc0: u32, pos: usize, curr: []usize) void {
            const ns = self.prog.nslots;
            var sp: usize = 1;
            frames[0] = .{ .explore = pc0 };
            while (sp != 0) {
                sp -= 1;
                var pc = switch (frames[sp]) {
                    .restore => |r| {
                        curr[r.slot] = r.old;
                        continue;
                    },
                    .explore => |pc| pc,
                };
                while (!list.contains(pc)) {
                    list.mark(pc);
                    switch (self.prog.insts[pc]) {
                        .jmp => |t| pc = t,
                        .split => |s| {
                            frames[sp] = .{ .explore = s.y };
                            sp += 1;
                            pc = s.x;
                        },
                        .save => |slot| {
                            frames[sp] = .{ .restore = .{ .slot = slot, .old = curr[slot] } };
                            sp += 1;
                            curr[slot] = pos;
                            pc += 1;
                        },
                        .clear => |c| {
                            for (c.lo..c.hi) |k| {
                                frames[sp] = .{ .restore = .{ .slot = @intCast(k), .old = curr[k] } };
                                sp += 1;
                                curr[k] = none;
                            }
                            pc += 1;
                        },
                        .assert => |a| {
                            if (!self.holds(a, pos)) break;
                            pc += 1;
                        },
                        .char, .set, .match => {
                            @memcpy(list.rows[pc * ns ..][0..ns], curr);
                            break;
                        },
                        .fail => break,
                    }
                }
            }
        }

        /// The first index at `pos` or after whose unit can start a match.
        fn skip(input: []const Unit, f: *const prefilter.First, pos: usize) ?usize {
            if (Unit == u8) {
                if (f.single8) |b| return std.mem.indexOfScalarPos(u8, input, pos, b);
                var i = pos;
                while (i < input.len) : (i += 1) if (f.utf8[input[i]]) return i;
                return null;
            } else {
                if (f.single16) |u| return std.mem.indexOfScalarPos(u16, input, pos, u);
                var i = pos;
                while (i < input.len) : (i += 1) {
                    const u = input[i];
                    if (if (u < 256) f.utf16[u] else f.high) return i;
                }
                return null;
            }
        }

        fn exists(self: Self, pos0: usize, scratch: *VmScratch, budget: *Budget) error{StepLimitExceeded}!bool {
            var clist = &scratch.lists[0];
            var nlist = &scratch.lists[1];
            clist.clear();
            self.addThread(clist, scratch.stack, 0, pos0, pos0);
            var pos = pos0;
            while (clist.len != 0) {
                try budget.charge(clist.len);
                const d = self.decodeAt(pos);
                const next = if (d) |c| c.pos else pos;
                nlist.clear();
                for (clist.dense[0..clist.len]) |pc| {
                    switch (self.prog.insts[pc]) {
                        .char => |c| if (d) |x| {
                            if (!x.invalid and x.value == c) self.addThread(nlist, scratch.stack, pc + 1, pos0, next);
                        },
                        .set => |i| if (d) |x| {
                            if (self.prog.sets[i].contains(x.value)) self.addThread(nlist, scratch.stack, pc + 1, pos0, next);
                        },
                        .match => return true,
                        .split, .jmp, .assert, .save, .clear, .fail => {},
                    }
                }
                if (d == null) break;
                pos = next;
                std.mem.swap(*List, &clist, &nlist);
            }
            return false;
        }

        /// The epsilon closure of `pc0` at `pos`, appended to `list` in
        /// priority order (depth first, a split's `x` before its `y`).
        inline fn addThread(self: Self, list: *List, stack: []u32, pc0: u32, start: usize, pos: usize) void {
            // The precomputed closure when it has no assert: the same pcs
            // in the same order as the walk below (a subtree the walk would
            // skip as visited only holds pcs already in the list).
            if (pc0 < self.prog.closures.len) {
                const cl = self.prog.closures[pc0];
                if (!cl.isDynamic()) {
                    for (self.prog.follow[cl.start..][0..cl.len]) |pc| {
                        if (!list.contains(pc)) list.insert(pc, start);
                    }
                    return;
                }
            }
            self.addClosure(list, stack, pc0, start, pos);
        }

        fn addClosure(self: Self, list: *List, stack: []u32, pc0: u32, start: usize, pos: usize) void {
            var sp: usize = 1;
            stack[0] = pc0;
            while (sp != 0) {
                sp -= 1;
                var pc = stack[sp];
                while (!list.contains(pc)) {
                    list.insert(pc, start);
                    switch (self.prog.insts[pc]) {
                        .jmp => |t| pc = t,
                        .split => |s| {
                            stack[sp] = s.y;
                            sp += 1;
                            pc = s.x;
                        },
                        .assert => |a| {
                            if (!self.holds(a, pos)) break;
                            pc += 1;
                        },
                        // Captures don't change what matches: this VM (the
                        // first pass, F4b D5) passes over them.
                        .save, .clear => pc += 1,
                        .char, .set, .match, .fail => break,
                    }
                }
            }
        }

        fn holds(self: Self, a: program.Assert, pos: usize) bool {
            return switch (a) {
                .text_start => pos == 0,
                .text_end => pos == self.input.len,
                .line_start => pos == 0 or (if (self.decodeBefore(pos)) |d| isLineTerminator(d.value) else false),
                .line_end => pos == self.input.len or (if (self.decodeAt(pos)) |d| isLineTerminator(d.value) else false),
                .word_boundary => self.isWordBoundary(pos),
                .not_word_boundary => !self.isWordBoundary(pos),
            };
        }

        fn isWordBoundary(self: Self, pos: usize) bool {
            const before = if (self.decodeBefore(pos)) |d| isWordChar(d.value) else false;
            const after = if (self.decodeAt(pos)) |d| isWordChar(d.value) else false;
            return before != after;
        }
    };
}

/// ECMA-262 LineTerminator: LF, CR, LS and PS (what `^`/`$` look for under `m`).
fn isLineTerminator(c: u32) bool {
    return c == '\n' or c == '\r' or c == 0x2028 or c == 0x2029;
}

/// `\w` without `u`+`i`: ASCII letters, digits and `_`.
fn isWordChar(c: u32) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const ir = @import("ir");
const hir = ir.hir;
const CharSet = ir.charset.CharSet;
const compile = @import("compile.zig").compile;

fn lit(comptime s: []const u8) hir.Node {
    const units = comptime blk: {
        var u: [s.len]hir.LitUnit = undefined;
        for (s, 0..) |c, i| u[i] = .{ .value = c };
        const out = u;
        break :blk out;
    };
    return .{ .literal = .{ .units = &units } };
}

fn rep(body: *const hir.Node, min: u32, max: ?u32, lazy: bool) hir.Node {
    return .{ .repeat = .{ .min = min, .max = max, .policy = if (lazy) .lazy else .greedy, .syntax_form = .counted, .body = body } };
}

fn setNode(set: CharSet) hir.Node {
    return .{ .char_set = .{ .set = set, .inverted = false, .encoding_hint = .set } };
}

const digit = [_]ir.charset.Range{.{ .lo = '0', .hi = '9' }};
const lower = [_]ir.charset.Range{.{ .lo = 'a', .hi = 'z' }};

/// `exec` over `input` (WTF-8), as `[start, end]` or null.
fn run(root: *const hir.Node, input: []const u8, index: usize, sticky: bool) !?[2]usize {
    const p = try compile(testing.allocator, root);
    defer p.deinit(testing.allocator);
    var scratch: VmScratch = .init(testing.allocator);
    defer scratch.deinit();
    var slots: [2]?usize = undefined;
    if (!try exec(&p, u8, input, .code_unit, index, sticky, &scratch, &slots)) return null;
    return .{ slots[0].?, slots[1].? };
}

fn expectMatch(expected: ?[2]usize, got: ?[2]usize) !void {
    try testing.expectEqual(expected, got);
}

test "leftmost-first: alternation order, not the longest" {
    const a = lit("a");
    const ab = lit("ab");
    const alt1: hir.Node = .{ .alt = &.{ &a, &ab } };
    const alt2: hir.Node = .{ .alt = &.{ &ab, &a } };
    try expectMatch(.{ 0, 1 }, try run(&alt1, "ab", 0, false));
    try expectMatch(.{ 0, 2 }, try run(&alt2, "ab", 0, false));
    try expectMatch(.{ 2, 3 }, try run(&alt1, "xxab", 1, false));
}

test "greedy and lazy repeats" {
    const a = lit("a");
    const star = rep(&a, 0, null, false);
    const lazy_plus = rep(&a, 1, null, true);
    const opt = rep(&a, 0, 3, false);
    const lazy_opt = rep(&a, 1, 3, true);
    try expectMatch(.{ 0, 0 }, try run(&star, "baa", 0, false));
    try expectMatch(.{ 0, 3 }, try run(&star, "aaab", 0, false));
    try expectMatch(.{ 1, 2 }, try run(&lazy_plus, "baa", 0, false));
    try expectMatch(.{ 0, 3 }, try run(&opt, "aaaa", 0, false));
    try expectMatch(.{ 0, 1 }, try run(&lazy_opt, "aaaa", 0, false));
    // A lazy prefix that has to grow: /a+?b/ on "aaab".
    const b = lit("b");
    const seq: hir.Node = .{ .seq = &.{ &lazy_plus, &b } };
    try expectMatch(.{ 0, 4 }, try run(&seq, "aaab", 0, false));
    try expectMatch(null, try run(&seq, "aaa", 0, false));
}

test "a higher-priority thread that matches later replaces the match" {
    // /(?:a|ab)(?:c|bcd)/ on "abcd": "a" then "bcd" (the first alternative
    // wins, and its thread matches after "ab"+"c" would have).
    const a = lit("a");
    const ab = lit("ab");
    const c = lit("c");
    const bcd = lit("bcd");
    const alt1: hir.Node = .{ .alt = &.{ &a, &ab } };
    const alt2: hir.Node = .{ .alt = &.{ &c, &bcd } };
    const seq: hir.Node = .{ .seq = &.{ &alt1, &alt2 } };
    try expectMatch(.{ 0, 4 }, try run(&seq, "abcd", 0, false));
    // And a lower-priority thread that would match later is cut: /a*?|b/.
    const b = lit("b");
    const lazy_star = rep(&a, 0, null, true);
    const alt3: hir.Node = .{ .alt = &.{ &lazy_star, &b } };
    try expectMatch(.{ 0, 0 }, try run(&alt3, "b", 0, false));
}

test "sticky, index, and the exec contract" {
    const a = lit("a");
    try expectMatch(null, try run(&a, "ba", 0, true));
    try expectMatch(.{ 1, 2 }, try run(&a, "ba", 1, true));
    try expectMatch(null, try run(&a, "ba", 3, false));
    try expectMatch(null, try run(&a, "", 0, false));
    const p = try compile(testing.allocator, &a);
    defer p.deinit(testing.allocator);
    var scratch: VmScratch = .init(testing.allocator);
    defer scratch.deinit();
    var slots: [2]?usize = undefined;
    try testing.expectError(error.InvalidIndex, exec(&p, u8, "\u{E9}a", .code_unit, 1, false, &scratch, &slots));
    try testing.expectError(error.SlotsTooSmall, exec(&p, u8, "a", .code_unit, 0, false, &scratch, slots[0..1]));
}

test "anchors and word boundaries" {
    const caret: hir.Node = .{ .assert = .caret };
    const dollar: hir.Node = .{ .assert = .dollar };
    const wb: hir.Node = .{ .assert = .word_boundary };
    const nwb: hir.Node = .{ .assert = .not_word_boundary };
    const a = lit("a");
    const caret_a: hir.Node = .{ .seq = &.{ &caret, &a } };
    const a_dollar: hir.Node = .{ .seq = &.{ &a, &dollar } };
    const m_caret_a: hir.Node = .{ .modifier_scope = .{ .flags = .{ .multiline = true }, .body = &caret_a } };
    const m_a_dollar: hir.Node = .{ .modifier_scope = .{ .flags = .{ .multiline = true }, .body = &a_dollar } };
    try expectMatch(null, try run(&caret_a, "b\na", 0, false));
    try expectMatch(.{ 2, 3 }, try run(&m_caret_a, "b\na", 0, false));
    try expectMatch(.{ 4, 5 }, try run(&m_caret_a, "b\u{2028}a", 0, false));
    try expectMatch(.{ 2, 3 }, try run(&m_caret_a, "b\ra", 0, false));
    try expectMatch(null, try run(&a_dollar, "a\nb", 0, false));
    try expectMatch(.{ 0, 1 }, try run(&m_a_dollar, "a\nb", 0, false));
    const wb_a: hir.Node = .{ .seq = &.{ &wb, &a } };
    const nwb_a: hir.Node = .{ .seq = &.{ &nwb, &a } };
    try expectMatch(.{ 3, 4 }, try run(&wb_a, "ba a", 0, false));
    try expectMatch(.{ 1, 2 }, try run(&nwb_a, "ba a", 0, false));
}

test "sets, ignore case, and code units in WTF-8" {
    const d = try CharSet.fromRanges(testing.allocator, &digit);
    defer d.deinit(testing.allocator);
    const dn = setNode(d);
    const three = rep(&dn, 3, 3, false);
    try expectMatch(.{ 1, 4 }, try run(&three, "a12345", 0, false));
    const ab = lit("aB");
    const i_ab: hir.Node = .{ .modifier_scope = .{ .flags = .{ .ignore_case = true }, .body = &ab } };
    try expectMatch(.{ 1, 3 }, try run(&i_ab, "xAb", 0, false));
    // Without `u` an astral character is two code units: `.`-like set of
    // everything, twice, spans one 4-byte sequence through its `b+2`.
    const all_ranges = [_]ir.charset.Range{.{ .lo = 0, .hi = 0x10FFFF }};
    const all = try CharSet.fromRanges(testing.allocator, &all_ranges);
    defer all.deinit(testing.allocator);
    const any = setNode(all);
    const one: hir.Node = any;
    try expectMatch(.{ 0, 2 }, try run(&one, "\u{1F600}", 0, false));
    try expectMatch(.{ 2, 4 }, try run(&one, "\u{1F600}", 2, false));
    const two = rep(&any, 2, 2, false);
    try expectMatch(.{ 0, 4 }, try run(&two, "\u{1F600}", 0, false));
    // A literal never matches an ill-formed byte of the same value.
    const e9: hir.Node = .{ .literal = .{ .units = &.{.{ .value = 0xE9 }} } };
    try expectMatch(null, try run(&e9, "\xE9", 0, false));
    try expectMatch(.{ 0, 2 }, try run(&e9, "\u{E9}", 0, false));
}

test "UTF-16 subjects" {
    const a = lit("a");
    const star = rep(&a, 1, null, false);
    const p = try compile(testing.allocator, &star);
    defer p.deinit(testing.allocator);
    var scratch: VmScratch = .init(testing.allocator);
    defer scratch.deinit();
    var slots: [2]?usize = undefined;
    const s = [_]u16{ 'b', 0xD83D, 0xDE00, 'a', 'a' };
    try testing.expect(try exec(&p, u16, &s, .code_unit, 0, false, &scratch, &slots));
    try testing.expectEqual(@as(?usize, 3), slots[0]);
    try testing.expectEqual(@as(?usize, 5), slots[1]);
}

test "a warm scratch allocates nothing" {
    const a = lit("ab");
    const star = rep(&a, 0, null, false);
    const p = try compile(testing.allocator, &star);
    defer p.deinit(testing.allocator);
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var scratch: VmScratch = .init(failing.allocator());
    defer scratch.deinit();
    var slots: [2]?usize = undefined;
    _ = try exec(&p, u8, "xabab", .code_unit, 0, false, &scratch, &slots);
    const warm = failing.allocations;
    try testing.expect(warm > 0);
    for (0..5) |i| _ = try exec(&p, u8, "xababab", .code_unit, i, false, &scratch, &slots);
    try testing.expectEqual(warm, failing.allocations);
}

test "VmScratch.ensure doesn't leak on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(gpa: Allocator) !void {
            var scratch: VmScratch = .init(gpa);
            defer scratch.deinit();
            try scratch.ensure(4);
            try scratch.ensure(40);
        }
    }.f, .{});
}

test "existsAnchoredMatch: forward bodies of lookarounds" {
    const d = try CharSet.fromRanges(testing.allocator, &digit);
    defer d.deinit(testing.allocator);
    const l = try CharSet.fromRanges(testing.allocator, &lower);
    defer l.deinit(testing.allocator);
    const dn = setNode(d);
    const ln = setNode(l);
    const d3 = rep(&dn, 3, 3, false);
    const foo = lit("foo");
    const lplus = rep(&ln, 1, null, false);
    const dollar: hir.Node = .{ .assert = .dollar };
    const l_end: hir.Node = .{ .seq = &.{ &lplus, &dollar } };
    const cases = .{
        .{ &d3, "a1234", 1, true },
        .{ &d3, "a12x4", 1, false },
        .{ &d3, "a1234", 0, false },
        .{ &foo, "xfoo", 1, true },
        .{ &foo, "xfo", 1, false },
        .{ &l_end, "12abc", 2, true },
        .{ &l_end, "12abc!", 2, false },
        .{ &l_end, "12abc", 5, false },
    };
    var scratch: VmScratch = .init(testing.allocator);
    defer scratch.deinit();
    inline for (cases) |c| {
        const p = try compile(testing.allocator, c[0]);
        defer p.deinit(testing.allocator);
        var budget: Budget = .unlimited;
        try testing.expectEqual(c[3], try existsAnchoredMatch(&p, .{ .wtf8 = c[1] }, .code_unit, c[2], .forward, &scratch, &budget));
        const s16 = try subject_mod.utf16FromWtf8(testing.allocator, c[1]);
        defer testing.allocator.free(s16);
        try testing.expectEqual(c[3], try existsAnchoredMatch(&p, .{ .utf16 = s16 }, .code_unit, c[2], .forward, &scratch, &budget));
    }
    const p = try compile(testing.allocator, &l_end);
    defer p.deinit(testing.allocator);
    var budget: Budget = .unlimited;
    try testing.expectError(error.Unsupported, existsAnchoredMatch(&p, .{ .wtf8 = "abc" }, .code_unit, 3, .backward, &scratch, &budget));
    try testing.expectError(error.InvalidIndex, existsAnchoredMatch(&p, .{ .wtf8 = "\u{E9}" }, .code_unit, 1, .forward, &scratch, &budget));
    var small: Budget = .init(3);
    try testing.expectError(error.StepLimitExceeded, existsAnchoredMatch(&p, .{ .wtf8 = "abcdefgh" }, .code_unit, 0, .forward, &scratch, &small));
}

// Tagged VM (F4b(2)). Expected slots are V8's (checked with Node when
// written); where the backtracker differs, it says so.

const compileWith = @import("compile.zig").compileWith;

fn group(index: u16, body: *const hir.Node) hir.Node {
    return .{ .capture = .{ .index = index, .name = null, .body = body } };
}

/// Runs `root` tagged from 0 three ways (the two passes in WTF-8 and in
/// UTF-16, and one tagged pass without `stop`), checks they agree, and
/// compares with `expected` (null: no match).
fn expectCaptures(root: *const hir.Node, input: []const u8, expected: ?[]const ?usize) !void {
    const p = try compileWith(testing.allocator, root, .{ .tagged = true });
    defer p.deinit(testing.allocator);
    var scratch: VmScratch = .init(testing.allocator);
    defer scratch.deinit();
    var two: [8]?usize = undefined;
    var one: [8]?usize = undefined;
    var wide: [8]?usize = undefined;
    const ns = p.nslots;
    const got = try execCaptures(&p, u8, input, .code_unit, 0, false, &scratch, &two);
    try testing.expectEqual(got, try execTagged(&p, u8, input, .code_unit, 0, false, null, &scratch, &one));
    const s16 = try subject_mod.utf16FromWtf8(testing.allocator, input);
    defer testing.allocator.free(s16);
    try testing.expectEqual(got, try execCaptures(&p, u16, s16, .code_unit, 0, false, &scratch, &wide));
    const want = expected orelse return testing.expect(!got);
    try testing.expect(got);
    try testing.expectEqual(want.len, ns);
    try testing.expectEqualSlices(?usize, want, two[0..ns]);
    try testing.expectEqualSlices(?usize, want, one[0..ns]);
    // All-ASCII inputs here: UTF-16 indices are the same.
    try testing.expectEqualSlices(?usize, want, wide[0..ns]);
}

test "tagged: D3 worked example 1, (a*)* on \"\" rejects the empty iteration" {
    const a = lit("a");
    const star_a = rep(&a, 0, null, false);
    const g1 = group(1, &star_a);
    const outer = rep(&g1, 0, null, false);
    // V8: ["", undefined]; the backtracker: ["", ""].
    try expectCaptures(&outer, "", &.{ 0, 0, null, null });
    try expectCaptures(&outer, "aa", &.{ 0, 2, 0, 2 });
}

test "tagged: D3 worked example 2, (a*)+ keeps the mandatory iteration" {
    const a = lit("a");
    const star_a = rep(&a, 0, null, false);
    const g1 = group(1, &star_a);
    const plus = rep(&g1, 1, null, false);
    // V8: ["aa", "aa"]; the backtracker: ["aa", ""].
    try expectCaptures(&plus, "aa", &.{ 0, 2, 0, 2 });
    try expectCaptures(&plus, "", &.{ 0, 0, 0, 0 });
}

test "tagged: D3 worked example 3, ((a*)*)* nested three deep" {
    const a = lit("a");
    const star_a = rep(&a, 0, null, false);
    const g2 = group(2, &star_a);
    const mid = rep(&g2, 0, null, false);
    const g1 = group(1, &mid);
    const outer = rep(&g1, 0, null, false);
    try expectCaptures(&outer, "a", &.{ 0, 1, 0, 1, 0, 1 });
    // V8: ["", undefined, undefined]; the backtracker: ["", "", ""].
    try expectCaptures(&outer, "", &.{ 0, 0, null, null, null, null });
}

test "tagged: each iteration resets the body's groups (clear)" {
    // /(?:(a)|b)+/ on "ab": the second iteration takes `b`, g1 is unset.
    const a = lit("a");
    const b = lit("b");
    const g1 = group(1, &a);
    const alt: hir.Node = .{ .alt = &.{ &g1, &b } };
    const plus = rep(&alt, 1, null, false);
    try expectCaptures(&plus, "ab", &.{ 0, 2, null, null });
    try expectCaptures(&plus, "ba", &.{ 0, 2, 1, 2 });
}

test "tagged: the empty iteration of ? is rejected too (F4a's correction)" {
    // /(?:[^a]?(b?)?)/ on "\nab": [0, 1] with g1 unset in V8; the
    // backtracker gives g1 = [1, 1].
    const not_a = [_]ir.charset.Range{ .{ .lo = 0, .hi = 'a' - 1 }, .{ .lo = 'a' + 1, .hi = 0x10FFFF } };
    const na = try CharSet.fromRanges(testing.allocator, &not_a);
    defer na.deinit(testing.allocator);
    const na_node = setNode(na);
    const na_opt = rep(&na_node, 0, 1, false);
    const b = lit("b");
    const b_opt = rep(&b, 0, 1, false);
    const g1 = group(1, &b_opt);
    const g1_opt = rep(&g1, 0, 1, false);
    const seq: hir.Node = .{ .seq = &.{ &na_opt, &g1_opt } };
    try expectCaptures(&seq, "\nab", &.{ 0, 1, null, null });
}

test "tagged: priority decides the groups, not the length" {
    // /(a|ab)(c|bcd)(d*)/ on "abcd": "a", "bcd", "".
    const a = lit("a");
    const ab = lit("ab");
    const c = lit("c");
    const bcd = lit("bcd");
    const d = lit("d");
    const alt1: hir.Node = .{ .alt = &.{ &a, &ab } };
    const alt2: hir.Node = .{ .alt = &.{ &c, &bcd } };
    const d_star = rep(&d, 0, null, false);
    const g1 = group(1, &alt1);
    const g2 = group(2, &alt2);
    const g3 = group(3, &d_star);
    const seq: hir.Node = .{ .seq = &.{ &g1, &g2, &g3 } };
    try expectCaptures(&seq, "abcd", &.{ 0, 4, 0, 1, 1, 4, 4, 4 });
    // Lazy: /(a+?)(a*)/ on "aaa": "a", "aa".
    const lazy = rep(&a, 1, null, true);
    const greedy = rep(&a, 0, null, false);
    const l1 = group(1, &lazy);
    const l2 = group(2, &greedy);
    const seq2: hir.Node = .{ .seq = &.{ &l1, &l2 } };
    try expectCaptures(&seq2, "xaaa", &.{ 1, 4, 1, 2, 2, 4 });
    try expectCaptures(&seq2, "xyz", null);
}

test "tagged: stop at the first pass's end (D5), and UTF-16 indices" {
    const ab = lit("ab");
    const g1 = group(1, &ab);
    const p = try compileWith(testing.allocator, &g1, .{ .tagged = true });
    defer p.deinit(testing.allocator);
    var scratch: VmScratch = .init(testing.allocator);
    defer scratch.deinit();
    var slots: [4]?usize = undefined;
    // A wrong end before any match: the second pass finds nothing.
    try testing.expect(!try execTagged(&p, u8, "ab", .code_unit, 0, true, 1, &scratch, &slots));
    try testing.expect(try execTagged(&p, u8, "ab", .code_unit, 0, true, 2, &scratch, &slots));
    try testing.expectEqualSlices(?usize, &.{ 0, 2, 0, 2 }, &slots);
    try testing.expectError(error.SlotsTooSmall, execCaptures(&p, u8, "ab", .code_unit, 0, false, &scratch, slots[0..2]));
    // UTF-16: an astral character is two units before the group.
    const s = [_]u16{ 0xD83D, 0xDE00, 'a', 'b' };
    try testing.expect(try execCaptures(&p, u16, &s, .code_unit, 0, false, &scratch, &slots));
    try testing.expectEqualSlices(?usize, &.{ 2, 4, 2, 4 }, &slots);
    // WTF-8: four bytes.
    try testing.expect(try execCaptures(&p, u8, "\u{1F600}ab", .code_unit, 0, false, &scratch, &slots));
    try testing.expectEqualSlices(?usize, &.{ 4, 6, 4, 6 }, &slots);
}

test "tagged: a warm scratch allocates nothing" {
    const a = lit("a");
    const b = lit("b");
    const g1 = group(1, &a);
    const alt: hir.Node = .{ .alt = &.{ &g1, &b } };
    const plus = rep(&alt, 1, null, false);
    const p = try compileWith(testing.allocator, &plus, .{ .tagged = true });
    defer p.deinit(testing.allocator);
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var scratch: VmScratch = .init(failing.allocator());
    defer scratch.deinit();
    var slots: [4]?usize = undefined;
    _ = try execCaptures(&p, u8, "xabab", .code_unit, 0, false, &scratch, &slots);
    const warm = failing.allocations;
    try testing.expect(warm > 0);
    for (0..5) |i| _ = try execCaptures(&p, u8, "xababba", .code_unit, i, false, &scratch, &slots);
    try testing.expectEqual(warm, failing.allocations);
}

test "VmScratch.ensureTagged doesn't leak on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(gpa: Allocator) !void {
            var scratch: VmScratch = .init(gpa);
            defer scratch.deinit();
            try scratch.ensureTagged(4, 4, 8);
            try scratch.ensure(40);
            try scratch.ensureTagged(40, 6, 80);
        }
    }.f, .{});
}

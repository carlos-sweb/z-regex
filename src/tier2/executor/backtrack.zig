//! The explicit-stack backtracker (F6a, docs/REGEX_TIERS_PLAN.md §4.4).
//!
//! It runs the same bytecode as `recursive_matcher.zig`, in the same order,
//! but keeps every pending alternative on a heap stack of choicepoints
//! instead of the native call stack. The recursive matcher spends a stack
//! frame per instruction on the path (it's continuation-passing), so how
//! far a match can go depended on the caller's stack (D14) and its depth
//! limit was never calibrated against bytes (D15). Here the only stack is
//! `Scratch.choices` (plus the loop guards, star positions and lookahead
//! snapshots it already kept on the heap), bounded in bytes by
//! `ExecLimits.max_backtrack_stack_bytes`.
//!
//! Exploration order, step counting and capture semantics are the
//! recursive matcher's, instruction for instruction:
//! - a SPLIT pushes its second branch and continues with the first;
//! - SAVE_START/SAVE_END/CLEAR_CAPTURE push a `restore` of the slot's
//!   previous value, undone when backtracking past it (the recursive
//!   matcher's per-frame rollback);
//! - a backward jump goes through the zero-progress loop guard (`guards`,
//!   a stack whose height every choicepoint records: an entry lives until
//!   backtracking pops a choicepoint older than it, which is exactly how
//!   long it lived on the recursive chain);
//! - a simple `*` keeps its positions on `positions` and one choicepoint
//!   for all of them;
//! - a lookahead copies the slots to `snapshots` and pushes a barrier; a
//!   positive one that succeeds drops everything above the barrier (it's
//!   atomic) and keeps its captures, as the recursive matcher does.
//! Lookbehind isn't here: patterns with one stay on the recursive matcher
//! until F6b.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("../bytecode/format.zig");
const recursive = @import("recursive_matcher.zig");

const CaptureGroup = recursive.CaptureGroup;
const LoopState = recursive.LoopState;
const Scratch = recursive.Scratch;

/// Default `ExecLimits.max_backtrack_stack_bytes`: far above what the step
/// budget lets a match push (one choicepoint per step at most), so by
/// default the step limit answers first.
pub const DEFAULT_MAX_BACKTRACK_STACK_BYTES: usize = 64 << 20;

/// Execution limits (D11): the backtracker's step budget, per start
/// position, and the bytes its stacks may take. 0 means unlimited.
/// T0's VM is linear and ignores both.
pub const ExecLimits = struct {
    max_steps: usize = recursive.DEFAULT_MAX_STEPS,
    max_backtrack_stack_bytes: usize = DEFAULT_MAX_BACKTRACK_STACK_BYTES,
};

/// A pending alternative. `guard_h`, `pos_h` and `look_top` are the heights
/// of the loop guards, the star positions and the innermost lookahead
/// barrier when it was pushed; resuming it brings them back.
pub const Choice = struct {
    kind: Kind,
    /// `alt`: the resumed branch jumps backward (through the loop guard).
    back: bool = false,
    /// `alt`: the branch to resume. `star_greedy`/`star_lazy`: the pattern
    /// after the star. `look`: the pc after LOOKAHEAD_END. `restore`: the
    /// capture slot.
    pc: u32,
    guard_h: u32,
    pos_h: u32,
    look_top: u32,
    /// `alt`: where to resume. `star_greedy`: the index in `positions` to
    /// try next. `star_lazy`: the position reached so far. `look`: where
    /// the lookahead started.
    pos: usize,
    /// `star_greedy`: the star's first index in `positions`. `star_lazy`:
    /// the pc of the starred atom. `look`: 1 for a negative lookahead.
    /// `restore`: the slot's previous start (`none` for null).
    a: usize = 0,
    /// `look`: the barrier's first index in `snapshots`. `restore`: the
    /// slot's previous end (`none` for null).
    b: usize = 0,

    pub const Kind = enum(u8) { alt, star_greedy, star_lazy, look, restore };
};

const none = std.math.maxInt(usize);

fn pack(v: ?usize) usize {
    return v orelse none;
}

fn unpack(v: usize) ?usize {
    return if (v == none) null else v;
}

/// The explicit-stack backtracker over a subject of `Unit`s (`u8` WTF-8,
/// `u16` UTF-16). `core` is the recursive matcher's state and atom checks
/// (captures, subject, CharSets, decoding), reused as they are; only its
/// control flow (`matchFrom`) isn't used.
pub fn BacktrackerFor(comptime Unit: type) type {
    return struct {
        core: Core,
        stack: std.ArrayListUnmanaged(Choice),
        limits: ExecLimits,
        steps: usize = 0,
        /// Index + 1 of the innermost lookahead barrier in `stack` (0: none).
        look_top: u32 = 0,

        const Core = recursive.RecursiveMatcherFor(Unit);
        const Self = @This();

        pub const MatchError = Core.MatchError || error{BacktrackStackExhausted};

        /// A backtracker on `scratch`'s buffers; hand them back with
        /// `releaseScratch`.
        pub fn initScratch(bytecode: []const u8, input: []const Unit, limits: ExecLimits, capture_slots: usize, scratch: *Scratch) Allocator.Error!Self {
            // The core's own limits stay off: it never runs `matchFrom`.
            const core = try Core.initScratch(bytecode, input, .unlimited(), capture_slots, scratch);
            var stack = scratch.choices;
            scratch.choices = .empty;
            stack.clearRetainingCapacity();
            return .{ .core = core, .stack = stack, .limits = limits };
        }

        pub fn releaseScratch(self: *Self, scratch: *Scratch) void {
            scratch.choices = self.stack;
            self.stack = .empty;
            self.core.releaseScratch(scratch);
        }

        /// Ready for another start position: captures unset, steps at zero.
        pub fn reset(self: *Self) void {
            self.clearStacks();
            self.core.reset();
            self.steps = 0;
        }

        /// The captures of the last successful `run`.
        pub fn captureSlice(self: *Self) []const CaptureGroup {
            return self.core.captureSlice();
        }

        fn clearStacks(self: *Self) void {
            self.stack.clearRetainingCapacity();
            self.core.loop_guard.clearRetainingCapacity();
            self.core.positions.clearRetainingCapacity();
            self.core.snapshots.clearRetainingCapacity();
            self.look_top = 0;
        }

        fn gpa(self: *const Self) Allocator {
            return self.core.allocator;
        }

        /// Fails once the stacks together pass `max_backtrack_stack_bytes`.
        fn checkBytes(self: *const Self) error{BacktrackStackExhausted}!void {
            const limit = self.limits.max_backtrack_stack_bytes;
            if (limit == 0) return;
            const bytes = self.stack.items.len * @sizeOf(Choice) +
                self.core.loop_guard.items.len * @sizeOf(LoopState) +
                self.core.positions.items.len * @sizeOf(usize) +
                self.core.snapshots.items.len * @sizeOf(CaptureGroup);
            if (bytes > limit) return error.BacktrackStackExhausted;
        }

        fn push(self: *Self, c: Choice) MatchError!void {
            try self.stack.append(self.gpa(), c);
            try self.checkBytes();
        }

        /// A choicepoint of `kind` recording the current heights.
        fn choice(self: *const Self, kind: Choice.Kind, pc: usize, pos: usize) Choice {
            return .{
                .kind = kind,
                .pc = @intCast(pc),
                .guard_h = @intCast(self.core.loop_guard.items.len),
                .pos_h = @intCast(self.core.positions.items.len),
                .look_top = self.look_top,
                .pos = pos,
            };
        }

        /// Enter a loop head through a backward edge, refusing an iteration
        /// that made no progress (the recursive matcher's `matchBackEdge`).
        /// False: refused.
        fn enterBackEdge(self: *Self, target_pc: usize, pos: usize) MatchError!bool {
            for (self.core.loop_guard.items) |g| {
                if (g.pc == target_pc and g.pos == pos) return false;
            }
            try self.core.loop_guard.append(self.gpa(), .{ .pc = target_pc, .pos = pos });
            try self.checkBytes();
            return true;
        }

        /// Record `slot`'s value for backtracking, then set it.
        fn setCapture(self: *Self, slot: usize, value: CaptureGroup) MatchError!void {
            const caps = self.core.caps();
            const prev = caps[slot];
            var r = self.choice(.restore, slot, 0);
            r.a = pack(prev.start);
            r.b = pack(prev.end);
            try self.push(r);
            caps[slot] = value;
        }

        fn restoreSnapshot(self: *Self, mark: usize) void {
            @memcpy(self.core.caps(), self.core.snapshots.items[mark..][0..self.core.capture_slots]);
        }

        /// Drop everything above the lookahead barrier at `idx` (the barrier
        /// too), bringing the heights back to its own.
        fn cutTo(self: *Self, idx: usize) void {
            const b = self.stack.items[idx];
            self.core.snapshots.shrinkRetainingCapacity(b.b);
            self.core.loop_guard.shrinkRetainingCapacity(b.guard_h);
            self.core.positions.shrinkRetainingCapacity(b.pos_h);
            self.look_top = b.look_top;
            self.stack.shrinkRetainingCapacity(idx);
        }

        /// Backtrack: resume the newest pending alternative, setting `pc`
        /// and `pos`. False when there's none left (no match here).
        fn backtrack(self: *Self, pc: *usize, pos: *usize) MatchError!bool {
            while (self.stack.items.len > 0) {
                const top = &self.stack.items[self.stack.items.len - 1];
                self.core.loop_guard.shrinkRetainingCapacity(top.guard_h);
                self.look_top = top.look_top;
                switch (top.kind) {
                    .restore => {
                        self.core.caps()[top.pc] = .{ .start = unpack(top.a), .end = unpack(top.b) };
                        self.stack.items.len -= 1;
                    },
                    .alt => {
                        const c = top.*;
                        self.stack.items.len -= 1;
                        self.core.positions.shrinkRetainingCapacity(c.pos_h);
                        if (c.back and !try self.enterBackEdge(c.pc, c.pos)) continue;
                        pc.* = c.pc;
                        pos.* = c.pos;
                        return true;
                    },
                    .star_greedy => {
                        // The next shorter repetition count, down to the
                        // star's first position (zero repetitions).
                        const idx = top.pos;
                        self.core.positions.shrinkRetainingCapacity(idx + 1);
                        pc.* = top.pc;
                        pos.* = self.core.positions.items[idx];
                        if (idx > top.a) top.pos = idx - 1 else self.stack.items.len -= 1;
                        return true;
                    },
                    .star_lazy => {
                        // One more repetition, if the atom matches and moves.
                        self.core.positions.shrinkRetainingCapacity(top.pos_h);
                        const at = top.pos;
                        if (at < self.core.input.len) {
                            const inst = try format.decodeInstruction(self.core.bytecode, top.a);
                            const r = try self.core.matchSingleInstruction(inst, top.a, at);
                            if (r.matched and r.end_pos != at) {
                                top.pos = r.end_pos;
                                pc.* = top.pc;
                                pos.* = r.end_pos;
                                return true;
                            }
                        }
                        self.stack.items.len -= 1;
                    },
                    .look => {
                        // The lookahead's body failed.
                        const c = top.*;
                        self.restoreSnapshot(c.b);
                        self.cutTo(self.stack.items.len - 1);
                        if (c.a == 1) {
                            // Negative: the assertion holds.
                            pc.* = c.pc;
                            pos.* = c.pos;
                            return true;
                        }
                    },
                }
            }
            return false;
        }

        /// Run from `start_pc` at `start_pos`: the end of the first match
        /// in the recursive matcher's order, or null. The captures are in
        /// `captureSlice` after a match.
        pub fn run(self: *Self, start_pc: usize, start_pos: usize) MatchError!?usize {
            defer self.clearStacks();
            const bytecode = self.core.bytecode;
            var pc = start_pc;
            var pos = start_pos;
            while (true) {
                // One step per instruction dispatched: the recursive
                // matcher's one step per `matchFrom`.
                if (self.limits.max_steps > 0) {
                    self.steps += 1;
                    if (self.steps >= self.limits.max_steps) return error.StepLimitExceeded;
                }
                const ok = try self.exec1(bytecode, &pc, &pos) orelse return pos;
                if (!ok and !try self.backtrack(&pc, &pos)) return null;
            }
        }

        /// Execute the instruction at `pc`. True: `pc`/`pos` moved on (or a
        /// branch was taken). False: it failed, backtrack. Null: MATCH.
        fn exec1(self: *Self, bytecode: []const u8, pc_ptr: *usize, pos_ptr: *usize) MatchError!?bool {
            const pc = pc_ptr.*;
            const pos = pos_ptr.*;
            if (pc >= bytecode.len) return false;
            const inst = try format.decodeInstruction(bytecode, pc);
            const next = pc + inst.size;
            switch (inst.opcode) {
                .MATCH => return null,

                .CHAR32 => {
                    const d = self.core.decodeAt(pos) orelse return false;
                    if (d.invalid or d.value != inst.operands[0]) return false;
                    pos_ptr.* = d.pos;
                },

                .CHAR_RANGE, .CHAR_RANGE_INV, .CHAR_CLASS, .CHAR_CLASS_INV, .CHAR, .CHAR_ANY => {
                    const d = self.core.decodeAt(pos) orelse return false;
                    if (!try self.core.charMatches(inst, pc, d)) return false;
                    pos_ptr.* = d.pos;
                },

                .BYTE, .CHAR_SET, .CHAR_SET_INV, .UNICODE_PROPERTY, .UNICODE_PROPERTY_INV, .UNICODE_SCRIPT, .UNICODE_SCRIPT_INV, .UNICODE_SCRIPT_EXTENSIONS, .UNICODE_SCRIPT_EXTENSIONS_INV => {
                    const r = try self.core.matchSingleInstruction(inst, pc, pos);
                    if (!r.matched) return false;
                    pos_ptr.* = r.end_pos;
                },

                .BACK_REF, .BACK_REF_I => {
                    const r = self.core.checkBackRef(pos, inst.operands[0], inst.opcode == .BACK_REF_I);
                    if (!r.matched) return false;
                    pos_ptr.* = r.end_pos;
                },

                .GOTO => {
                    // A backward jump closes a `*`/`{n,}` loop: through the
                    // zero-progress guard.
                    const target = jump(pc, inst.operands[0]);
                    if (target < pc and !try self.enterBackEdge(target, pos)) return false;
                    pc_ptr.* = target;
                    return true;
                },

                .SPLIT, .SPLIT_GREEDY, .SPLIT_LAZY, .SPLIT_POSSESSIVE => {
                    const pc1 = if (inst.operands[0] == 0) next else jump(pc, inst.operands[0]);
                    const pc2 = if (inst.operands[1] == 0) next else jump(pc, inst.operands[1]);
                    if (try self.core.isStarQuantifier(pc, pc1, pc2)) {
                        const pc1_consumes = try self.core.isStarConsumePath(pc, pc1);
                        const pc_atom = if (pc1_consumes) pc1 else pc2;
                        const pc_rest = if (pc1_consumes) pc2 else pc1;
                        if (inst.opcode == .SPLIT_POSSESSIVE) {
                            pos_ptr.* = try self.consumeAll(pc_atom, pos, null);
                        } else if (inst.opcode == .SPLIT_LAZY) {
                            var c = self.choice(.star_lazy, pc_rest, pos);
                            c.a = pc_atom;
                            try self.push(c);
                        } else {
                            // Greedy: every repetition count's end on
                            // `positions`, longest tried first.
                            const mark = self.core.positions.items.len;
                            try self.core.positions.append(self.gpa(), pos);
                            pos_ptr.* = try self.consumeAll(pc_atom, pos, mark);
                            const last = self.core.positions.items.len - 1;
                            if (last > mark) {
                                var c = self.choice(.star_greedy, pc_rest, last - 1);
                                c.a = mark;
                                try self.push(c);
                            }
                        }
                        pc_ptr.* = pc_rest;
                        return true;
                    }
                    // Alternation or `?`: the first branch, the second on
                    // backtracking. A backward branch closes a `+`/`{n,}`
                    // loop the star path didn't recognize: through the guard.
                    var c = self.choice(.alt, pc2, pos);
                    c.back = pc2 < pc;
                    try self.push(c);
                    if (pc1 < pc and !try self.enterBackEdge(pc1, pos)) return false;
                    pc_ptr.* = pc1;
                    return true;
                },

                .SAVE_START, .SAVE_END => {
                    const group: usize = inst.operands[0];
                    if (group < self.core.capture_slots) {
                        var v = self.core.caps()[group];
                        if (inst.opcode == .SAVE_START) v.start = pos else v.end = pos;
                        try self.setCapture(group, v);
                    }
                },

                .CLEAR_CAPTURE => {
                    const group: usize = inst.operands[0];
                    if (group < self.core.capture_slots) try self.setCapture(group, .{});
                },

                .LOOKAHEAD, .NEGATIVE_LOOKAHEAD => {
                    const end_pc = try self.core.findLookaheadEnd(next);
                    const mark = self.core.snapshots.items.len;
                    try self.core.snapshots.appendSlice(self.gpa(), self.core.caps());
                    var c = self.choice(.look, end_pc + 1, pos);
                    c.a = @intFromBool(inst.opcode == .NEGATIVE_LOOKAHEAD);
                    c.b = mark;
                    try self.push(c);
                    self.look_top = @intCast(self.stack.items.len);
                },

                .LOOKAHEAD_END => {
                    // Outside a lookahead (malformed bytecode) it matches, as
                    // the recursive matcher's does.
                    if (self.look_top == 0) return null;
                    const idx = self.look_top - 1;
                    const b = self.stack.items[idx];
                    if (b.a == 1) {
                        // Negative: its body matched, so the assertion
                        // fails, and none of the body's captures stay.
                        self.restoreSnapshot(b.b);
                        self.cutTo(idx);
                        return false;
                    }
                    // Positive: atomic. Its alternatives go, its captures
                    // stay; continue after it where it started.
                    self.cutTo(idx);
                    pc_ptr.* = b.pc;
                    pos_ptr.* = b.pos;
                    return true;
                },

                .STRING_START => if (pos != 0) return false,
                .STRING_END => if (pos != self.core.input.len) return false,
                .LINE_START => if (!(pos == 0 or self.core.lineTerminatorEndsAt(pos))) return false,
                .LINE_END => if (!(pos == self.core.input.len or self.core.isLineTerminatorAt(pos))) return false,
                .WORD_BOUNDARY => if (!self.core.isWordBoundary(pos)) return false,
                .NOT_WORD_BOUNDARY => if (self.core.isWordBoundary(pos)) return false,

                // Lookbehind runs on the recursive matcher (see the module
                // doc); anything else the recursive matcher doesn't run
                // either.
                else => return false,
            }
            pc_ptr.* = next;
            return true;
        }

        /// Repeat the starred atom at `pc_atom` from `pos` while it matches
        /// and moves; with `mark`, record every end on `positions`. The
        /// last end.
        fn consumeAll(self: *Self, pc_atom: usize, pos: usize, mark: ?usize) MatchError!usize {
            const inst = try format.decodeInstruction(self.core.bytecode, pc_atom);
            var at = pos;
            while (at < self.core.input.len) {
                const r = try self.core.matchSingleInstruction(inst, pc_atom, at);
                if (!r.matched or r.end_pos == at) break;
                at = r.end_pos;
                if (mark != null) try self.core.positions.append(self.gpa(), at);
            }
            if (mark != null) try self.checkBytes();
            return at;
        }

        fn jump(pc: usize, operand: u32) usize {
            const offset: i32 = @bitCast(operand);
            return @intCast(@as(i64, @intCast(pc)) + offset);
        }
    };
}

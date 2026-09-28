//! The explicit-stack backtracker (F6a, docs/REGEX_TIERS_PLAN.md §4.4).
//!
//! It runs the same bytecode as `recursive_matcher.zig`, in the same order,
//! but keeps every pending alternative on a heap stack of choicepoints
//! instead of the native call stack. The recursive matcher spends a stack
//! frame per instruction on the path (it's continuation-passing), so how
//! far a match can go depended on the caller's stack (D14) and its depth
//! limit was never calibrated against bytes (D15). Here the only stack is
//! `Scratch.choices`, with the capture trail and the loop guards and star
//! positions the recursive matcher already kept on the heap, all bounded
//! together by `ExecLimits.max_backtrack_stack_bytes`.
//!
//! Exploration order and step counting are the recursive matcher's,
//! instruction for instruction:
//! - a SPLIT pushes its second branch and continues with the first;
//! - SAVE_START/SAVE_END/CLEAR_CAPTURE write the slot's previous value to
//!   the trail (docs/REGEX_TIERS_PLAN.md §4.4 D-D); every choicepoint
//!   records the trail's height, and resuming it undoes the trail down to
//!   there;
//! - a backward jump goes through the zero-progress loop guard (`guards`,
//!   a stack whose height every choicepoint records: an entry lives until
//!   backtracking pops a choicepoint older than it, which is exactly how
//!   long it lived on the recursive chain);
//! - a simple `*` keeps its positions on `positions` and one choicepoint
//!   for all of them;
//! - a lookahead pushes a barrier. A positive one that succeeds drops the
//!   choicepoints above it (it's atomic) but keeps the trail, so its
//!   captures stay and a later backtrack past it still undoes them (the
//!   recursive matcher kept them: bug F, F6A_PRECHECK.md). A negative one
//!   always undoes the trail to its barrier.
//! Lookbehind isn't here: patterns with one stay on the recursive matcher
//! until F6b.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("../bytecode/format.zig");
const recursive = @import("recursive_matcher.zig");
const tier0 = @import("tier0");
const Budget = @import("utils").budget.Budget;
const LinearSite = @import("../program.zig").LinearSite;

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
    /// The most a LookLinear memo table may take, per delegated lookahead
    /// (2 bits per position of the subject). Not an error when a table
    /// doesn't fit: that lookahead runs without memo. 0 turns the memo off.
    max_memo_bytes: usize = DEFAULT_MAX_MEMO_BYTES,
};

/// Default `ExecLimits.max_memo_bytes`: memo for subjects up to 4 Mi units.
pub const DEFAULT_MAX_MEMO_BYTES: usize = 1 << 20;

/// LookLinear's memo for one delegated program (§4.4): 2 bits per position,
/// `00` not evaluated, `01` no anchored match there, `10` one. Valid for
/// one execution (`gen`); a new one clears only the range the last one
/// touched, so an execution never pays for more of it than it used.
pub const LookMemo = struct {
    bits: std.ArrayListUnmanaged(u8) = .empty,
    lo: usize = std.math.maxInt(usize),
    hi: usize = 0,
    gen: u32 = 0,

    fn begin(self: *LookMemo, gen: u32) void {
        if (self.lo <= self.hi) @memset(self.bits.items[self.lo / 4 .. self.hi / 4 + 1], 0);
        self.lo = std.math.maxInt(usize);
        self.hi = 0;
        self.gen = gen;
    }

    fn get(self: *const LookMemo, pos: usize) ?bool {
        const v = (self.bits.items[pos / 4] >> @intCast(pos % 4 * 2)) & 3;
        std.debug.assert(v != 3);
        return if (v == 0) null else v == 2;
    }

    fn put(self: *LookMemo, pos: usize, found: bool) void {
        self.bits.items[pos / 4] |= @as(u8, if (found) 2 else 1) << @intCast(pos % 4 * 2);
        self.lo = @min(self.lo, pos);
        self.hi = @max(self.hi, pos);
    }
};

/// A capture slot's value before a write: undone on backtracking.
pub const TrailEntry = struct { slot: u32, prev: CaptureGroup };

/// A pending alternative. `trail_h`, `guard_h`, `pos_h` and `look_top` are
/// the heights of the trail, the loop guards, the star positions and the
/// innermost lookahead barrier when it was pushed; resuming it brings them
/// back.
pub const Choice = struct {
    kind: Kind,
    /// `alt`: the resumed branch jumps backward (through the loop guard).
    back: bool = false,
    /// `alt`: the branch to resume. `star_greedy`/`star_lazy`: the pattern
    /// after the star. `look`: the pc after LOOKAHEAD_END.
    pc: u32,
    trail_h: u32,
    guard_h: u32,
    pos_h: u32,
    look_top: u32,
    /// `alt`: where to resume. `star_greedy`: the index in `positions` to
    /// try next. `star_lazy`: the position reached so far. `look`: where
    /// the lookahead started.
    pos: usize,
    /// `star_greedy`: the star's first index in `positions`. `star_lazy`:
    /// the pc of the starred atom. `look`: 1 for a negative lookahead.
    a: usize = 0,

    pub const Kind = enum(u8) { alt, star_greedy, star_lazy, look };
};

/// The explicit-stack backtracker over a subject of `Unit`s (`u8` WTF-8,
/// `u16` UTF-16). `core` is the recursive matcher's state and atom checks
/// (captures, subject, CharSets, decoding), reused as they are; only its
/// control flow (`matchFrom`) isn't used.
/// Loop guards past this many are mirrored in a hash set (F7a(3)): the
/// zero-progress check of a long loop was a scan of every active guard,
/// quadratic in the iterations (5,000 of `(?:ab)*` took ~13 ms). Below it
/// the scan is cheaper than hashing.
const guard_set_min = 64;

pub fn BacktrackerFor(comptime Unit: type) type {
    return struct {
        core: Core,
        stack: std.ArrayListUnmanaged(Choice),
        trail: std.ArrayListUnmanaged(TrailEntry),
        limits: ExecLimits,
        steps: usize = 0,
        /// Index + 1 of the innermost lookahead barrier in `stack` (0: none).
        look_top: u32 = 0,
        scratch: *Scratch,
        /// LookLinear's sites and programs (`CompileResult.linear`).
        linear: []const LinearSite = &.{},
        programs: []const tier0.Program = &.{},

        const Core = recursive.RecursiveMatcherFor(Unit);
        const Self = @This();

        pub const MatchError = Core.MatchError || error{BacktrackStackExhausted};

        /// A backtracker on `scratch`'s buffers, built in place (the core
        /// is a few hundred bytes, and this runs per execution); hand them
        /// back with `releaseScratch`.
        pub fn initScratchInto(self: *Self, bytecode: []const u8, input: []const Unit, limits: ExecLimits, capture_slots: usize, scratch: *Scratch) Allocator.Error!void {
            // The core's own limits stay off: it never runs `matchFrom`.
            try self.core.initScratchInto(bytecode, input, .unlimited(), capture_slots, scratch);
            self.stack = scratch.choices;
            self.trail = scratch.trail;
            scratch.choices = .empty;
            scratch.trail = .empty;
            self.stack.clearRetainingCapacity();
            self.trail.clearRetainingCapacity();
            scratch.guard_set.clearRetainingCapacity();
            self.limits = limits;
            self.steps = 0;
            self.look_top = 0;
            self.scratch = scratch;
            self.linear = &.{};
            self.programs = &.{};
            // A new execution: the memo tables from the last one are stale.
            scratch.look_gen +%= 1;
            if (scratch.look_gen == 0) {
                for (scratch.look_memo.items) |*m| m.begin(0);
                scratch.look_gen = 1;
            }
        }

        pub fn releaseScratch(self: *Self, scratch: *Scratch) void {
            scratch.choices = self.stack;
            scratch.trail = self.trail;
            self.stack = .empty;
            self.trail = .empty;
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
            self.trail.clearRetainingCapacity();
            self.core.loop_guard.clearRetainingCapacity();
            self.scratch.guard_set.clearRetainingCapacity();
            self.core.positions.clearRetainingCapacity();
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
                self.trail.items.len * @sizeOf(TrailEntry) +
                self.core.loop_guard.items.len * @sizeOf(LoopState) +
                self.scratch.guard_set.count() * @sizeOf(LoopState) +
                self.core.positions.items.len * @sizeOf(usize);
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
                .trail_h = @intCast(self.trail.items.len),
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
            const entry: LoopState = .{ .pc = target_pc, .pos = pos };
            if (self.guarded(entry)) return false;
            try self.core.loop_guard.append(self.gpa(), entry);
            const guards = self.core.loop_guard.items;
            if (guards.len == guard_set_min + 1) {
                // Just past the threshold: the mirror starts with them all.
                for (guards) |g| try self.scratch.guard_set.put(self.gpa(), g, {});
            } else if (guards.len > guard_set_min + 1) {
                try self.scratch.guard_set.put(self.gpa(), entry, {});
            }
            try self.checkBytes();
            return true;
        }

        /// Whether `entry` is an active loop guard. The guards are unique
        /// (`enterBackEdge` refuses a second one), so past `guard_set_min`
        /// the set mirroring them answers; below it a scan is cheaper.
        fn guarded(self: *const Self, entry: LoopState) bool {
            const guards = self.core.loop_guard.items;
            if (guards.len > guard_set_min) return self.scratch.guard_set.contains(entry);
            for (guards) |g| {
                if (g.pc == entry.pc and g.pos == entry.pos) return true;
            }
            return false;
        }

        /// Drop the loop guards above height `h` (a choicepoint's), keeping
        /// the set in step: empty at or below `guard_set_min`, the same
        /// entries as the stack above it.
        fn truncateGuards(self: *Self, h: usize) void {
            const guards = self.core.loop_guard.items;
            if (h >= guards.len) return;
            if (guards.len > guard_set_min) {
                if (h <= guard_set_min) {
                    self.scratch.guard_set.clearRetainingCapacity();
                } else for (guards[h..]) |g| {
                    _ = self.scratch.guard_set.remove(g);
                }
            }
            self.core.loop_guard.shrinkRetainingCapacity(h);
        }

        /// Record `slot`'s value on the trail, then set it.
        fn setCapture(self: *Self, slot: usize, value: CaptureGroup) MatchError!void {
            const caps = self.core.caps();
            try self.trail.append(self.gpa(), .{ .slot = @intCast(slot), .prev = caps[slot] });
            try self.checkBytes();
            caps[slot] = value;
        }

        /// Undo the capture writes above trail height `h`, newest first.
        fn undoTo(self: *Self, h: usize) void {
            const caps = self.core.caps();
            while (self.trail.items.len > h) {
                const e = self.trail.pop().?;
                caps[e.slot] = e.prev;
            }
        }

        /// Drop the choicepoints from the lookahead barrier at `idx` up (the
        /// barrier too), bringing the heights back to its own. The trail
        /// stays: undoing it is the caller's choice.
        fn cutTo(self: *Self, idx: usize) void {
            const b = self.stack.items[idx];
            self.truncateGuards(b.guard_h);
            self.core.positions.shrinkRetainingCapacity(b.pos_h);
            self.look_top = b.look_top;
            self.stack.shrinkRetainingCapacity(idx);
        }

        /// Backtrack: resume the newest pending alternative, setting `pc`
        /// and `pos`. False when there's none left (no match here).
        fn backtrack(self: *Self, pc: *usize, pos: *usize) MatchError!bool {
            while (self.stack.items.len > 0) {
                const top = &self.stack.items[self.stack.items.len - 1];
                self.undoTo(top.trail_h);
                self.truncateGuards(top.guard_h);
                self.look_top = top.look_top;
                switch (top.kind) {
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
                        // The lookahead's body failed (its captures are
                        // already undone, above).
                        const c = top.*;
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
                    // LookLinear: T0's VM (or the memo) says whether the
                    // body matches here; it has no captures, so nothing
                    // goes on the trail and no barrier is needed.
                    if (self.linearSite(pc)) |site| {
                        if (try self.lookLinear(site, pos)) |found| {
                            if (found == (inst.opcode == .NEGATIVE_LOOKAHEAD)) return false;
                            pc_ptr.* = site.end + 1;
                            return true;
                        }
                    }
                    const end_pc = try self.core.findLookaheadEnd(next);
                    var c = self.choice(.look, end_pc + 1, pos);
                    c.a = @intFromBool(inst.opcode == .NEGATIVE_LOOKAHEAD);
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
                        self.undoTo(b.trail_h);
                        self.cutTo(idx);
                        return false;
                    }
                    // Positive: atomic. Its alternatives go; its captures
                    // stay, on the trail, so backtracking past the
                    // lookahead later undoes them. Continue after it,
                    // where it started.
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

        /// The LookLinear site of the lookahead at `pc`, if any.
        fn linearSite(self: *const Self, pc: usize) ?LinearSite {
            if (self.linear.len == 0) return null;
            const i = std.sort.binarySearch(LinearSite, self.linear, pc, struct {
                fn order(key: usize, site: LinearSite) std.math.Order {
                    return std.math.order(key, site.pc);
                }
            }.order) orelse return null;
            return self.linear[i];
        }

        /// Whether the delegated body of `site` matches anchored at `pos`:
        /// the memo, or T0's VM on the same step budget. Null if the VM
        /// can't answer (never expected: `pos` is always a position), and
        /// the backtracker evaluates the body itself.
        fn lookLinear(self: *Self, site: LinearSite, pos: usize) MatchError!?bool {
            const s = self.scratch;
            const memo = try self.memoFor(site.program);
            if (memo) |m| if (m.get(pos)) |found| {
                s.look_memo_hits += 1;
                return found;
            };
            var budget: Budget = if (self.limits.max_steps > 0) .init(self.limits.max_steps - self.steps) else .unlimited;
            const before = budget.remaining;
            const found = tier0.existsAnchoredMatch(&self.programs[site.program], self.core.subject(), self.core.mode, pos, .forward, &s.look_vm, &budget) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.StepLimitExceeded => return error.StepLimitExceeded,
                error.InvalidIndex, error.Unsupported => return null,
            };
            if (self.limits.max_steps > 0) self.steps += @intCast(before - budget.remaining);
            s.look_evals += 1;
            if (memo) |m| m.put(pos, found);
            return found;
        }

        /// The memo of program `index` for this execution, or null when its
        /// table wouldn't fit in `max_memo_bytes`.
        fn memoFor(self: *Self, index: usize) MatchError!?*LookMemo {
            const bytes = self.core.input.len / 4 + 1;
            if (bytes > self.limits.max_memo_bytes) return null;
            const s = self.scratch;
            if (s.look_memo.items.len < self.programs.len) try s.look_memo.appendNTimes(s.gpa, .{}, self.programs.len - s.look_memo.items.len);
            const m = &s.look_memo.items[index];
            if (m.gen != s.look_gen) m.begin(s.look_gen);
            if (m.bits.items.len < bytes) try m.bits.appendNTimes(s.gpa, 0, bytes - m.bits.items.len);
            return m;
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

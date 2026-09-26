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
        }
        self.gpa.free(self.stack);
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
        self.free();
        self.lists = fresh;
        self.stack = stack;
        self.capacity = n;
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
                            .split, .jmp, .assert => {},
                        }
                    }
                }
                const c = d orelse break;
                pos = c.pos;
                std.mem.swap(*List, &clist, &nlist);
            }
            return found;
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
                        .split, .jmp, .assert => {},
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
                        .char, .set, .match => break,
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

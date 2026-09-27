//! T0's tagged Pike VM (docs/REGEX_TIERS_PLAN.md §6.5, F4b): the VM of
//! `pikevm.zig` with capture slots, and D5's two passes. It runs the same
//! programs, with the same search, priority and cut; each thread carries a
//! row of slots, and the epsilon closure undoes `save`/`clear` on the way
//! back (D1). Dedup by pc as in F4a (D2).
//!
//! Its own file (F4b(4)): kept apart from F4a's VM so adding it doesn't
//! reorder that VM's code in the binary (the capture-less path lost 7-14%
//! when both lived in one file, a code-layout effect). The buffers are in
//! `pikevm.VmScratch`, shared by both.

const std = @import("std");
const subject_mod = @import("subject");
const Mode = subject_mod.Mode;
const program = @import("program.zig");
const Program = program.Program;
const pikevm = @import("pikevm.zig");
const VmScratch = pikevm.VmScratch;
const List = pikevm.List;
const ExecError = pikevm.ExecError;

/// `execCaptures`: `TwoPassMismatch` is D5's contract broken (the tagged
/// pass didn't end where the first one did), a VM bug.
pub const CaptureError = ExecError || error{TwoPassMismatch};

/// An unset capture slot in the tagged VM's rows.
pub const none = std.math.maxInt(usize);

/// The tagged closure's work stack (F4b D1): a pc still to explore, or a
/// slot to put back when the walk returns past the `save`/`clear` that
/// changed it.
pub const Frame = union(enum) {
    explore: u32,
    restore: struct { slot: u32, old: usize },
};

/// The tagged VM (F4b D1, D2): the leftmost-first match of `prog` with its
/// capture slots, into `slots[0..prog.nslots]` (null: the group didn't
/// take part). The same search, priority and cut as `exec`, without
/// prefilters. With `stop = e` it ends after the position `e` (D5's
/// second pass, which knows where the match ends).
pub fn execTagged(prog: *const Program, comptime Unit: type, input: []const Unit, mode: Mode, index: usize, sticky: bool, stop: ?usize, scratch: *VmScratch, slots: []?usize) ExecError!bool {
    if (slots.len < prog.nslots) return error.SlotsTooSmall;
    if (index > input.len) return false;
    const vm: pikevm.Vm(Unit) = .{ .prog = prog, .input = input, .mode = mode };
    if (!vm.subject().isPosition(index)) return error.InvalidIndex;
    try scratch.ensureTagged(prog.insts.len, prog.nslots, prog.insts.len + prog.max_undo + 1);
    const found = searchTagged(Unit, vm, index, sticky, stop, scratch) orelse return false;
    for (slots[0..prog.nslots], found) |*o, v| o.* = if (v == none) null else v;
    return true;
}

/// D5's two passes: `exec` (prefilters, no captures) finds `[s, e]`; when
/// the program has groups, `execTagged` runs anchored at `s` and stops at
/// `e`. A second pass that doesn't end at `e` is `error.TwoPassMismatch`.
pub fn execCaptures(prog: *const Program, comptime Unit: type, input: []const Unit, mode: Mode, index: usize, sticky: bool, scratch: *VmScratch, slots: []?usize) CaptureError!bool {
    if (slots.len < prog.nslots) return error.SlotsTooSmall;
    if (!try pikevm.exec(prog, Unit, input, mode, index, sticky, scratch, slots[0..2])) return false;
    if (prog.nslots == 2) return true;
    const s = slots[0].?;
    const e = slots[1].?;
    if (!try execTagged(prog, Unit, input, mode, s, true, e, scratch, slots)) return error.TwoPassMismatch;
    if (slots[0] != s or slots[1] != e) return error.TwoPassMismatch;
    return true;
}

/// `search` with capture slots: each thread's are its row in the
/// list (slot 0 its start). Returns the recorded match's slots
/// (`none` for unset), in `scratch.curr`'s second half.
fn searchTagged(comptime Unit: type, self: pikevm.Vm(Unit), index: usize, sticky: bool, stop: ?usize, scratch: *VmScratch) ?[]const usize {
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
            closeTagged(Unit, self, clist, scratch.frames, 0, pos, curr);
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
                            closeTagged(Unit, self, nlist, scratch.frames, pc + 1, next, curr);
                        }
                    },
                    .set => |i| if (d) |x| {
                        if (self.prog.sets[i].contains(x.value)) {
                            @memcpy(curr, row);
                            closeTagged(Unit, self, nlist, scratch.frames, pc + 1, next, curr);
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
fn closeTagged(comptime Unit: type, self: pikevm.Vm(Unit), list: *List, frames: []Frame, pc0: u32, pos: usize, curr: []usize) void {
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

// ------------------------------------------------------------------ tests

const testing = std.testing;
const Allocator = std.mem.Allocator;
const ir = @import("ir");
const hir = ir.hir;
const CharSet = ir.charset.CharSet;

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

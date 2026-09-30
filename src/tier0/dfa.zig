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

const std = @import("std");
const Allocator = std.mem.Allocator;
const subject_mod = @import("subject");
const Subject = subject_mod.Subject;
const Decoded = subject_mod.Decoded;
const Program = @import("program.zig").Program;

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

    pub fn deinit(self: *const Dfa, gpa: Allocator) void {
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
        const end = self.forward(Unit, input, index, sticky, skipper) orelse return null;
        if (sticky) return .{ index, end };
        return .{ self.backward(Unit, input, index, end), end };
    }

    fn subjectOf(comptime Unit: type, input: []const Unit) Subject {
        return if (Unit == u8) .{ .wtf8 = input } else .{ .utf16 = input };
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
                const d = subjectOf(Unit, input).decodeAt(.code_unit, pos).?;
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
                const subj = subjectOf(Unit, input);
                var d = subj.decodeBefore(.code_unit, pos).?;
                if (d.pos < index) {
                    // A character straddling `index`: from `index`, forward
                    // decoding saw only its part at `index`.
                    const f = subj.decodeAt(.code_unit, index).?;
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

/// Whether `prog` can have a DFA: no asserts (every closure precomputed).
pub fn eligible(prog: *const Program) bool {
    if (prog.closures.len != prog.insts.len) return false;
    for (prog.closures) |cl| if (cl.isDynamic()) return false;
    return true;
}

fn followOf(prog: *const Program, pc: usize) []const u32 {
    const cl = prog.closures[pc];
    return prog.follow[cl.start..][0..cl.len];
}

/// The DFA of `prog` (which must be `eligible`), or null above the cap.
pub fn build(gpa: Allocator, prog: *const Program) Allocator.Error!?*const Dfa {
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
    const sig = try a.alloc(u8, ncons);
    for (cuts.items, 0..) |v, k| {
        for ([_]bool{ false, true }) |is_bad| {
            for (prog.insts, 0..) |inst, pc| switch (inst) {
                .char => |c| sig[cons_index[pc]] = @intFromBool(!is_bad and c == v),
                .set => |i| sig[cons_index[pc]] = @intFromBool(prog.sets[i].contains(v)),
                else => {},
            };
            const g = try sig_ids.getOrPut(a, sig);
            if (!g.found_existing) {
                g.key_ptr.* = try a.dupe(u8, sig);
                g.value_ptr.* = @intCast(sig_ids.count() - 1);
                try sigs.appendSlice(a, sig);
            }
            (if (is_bad) bad else valid)[k] = g.value_ptr.*;
        }
    }
    const nclass: u32 = sig_ids.count();

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
        return .{ .prog = p, .dfa = if (eligible(&p)) try build(testing.allocator, &p) else null };
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
    const d = (try build(testing.allocator, &p)).?;
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

test "eligible: no asserts" {
    const wb: hir.Node = .{ .assert = .word_boundary };
    const a = lit("a");
    const seq: hir.Node = .{ .seq = &.{ &wb, &a } };
    const p = try compile_mod.compileWith(testing.allocator, &seq, .{ .prefilters = false });
    defer p.deinit(testing.allocator);
    try testing.expect(!eligible(&p));
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
            const d = (try build(gpa, prog)).?;
            d.deinit(gpa);
        }
    }.f, .{&p});
}

//! HIR -> T0 `Program` (docs/REGEX_TIERS_PLAN.md, F4a), and which patterns
//! T0 takes in F4a.
//!
//! A Thompson construction whose `split` order is the priority of ECMA-262's
//! backtracking: an alternative before the next, a greedy iteration before
//! leaving, a lazy exit before iterating. The pattern's flags come from its
//! `modifier_scope` nodes (only the root one today).
//!
//! **What F4a takes** (`check`), on top of the dispatcher's own condition
//! (`analyze()` says T0, so no `u`/`v`, no `i` on non-ASCII content, no
//! `\p`): no capture group (F4b), no backreference or lookaround (T2), no raw
//! pattern byte (a WTF-8-only notion), and no quantifier that can iterate
//! over a body that matches empty. ECMA-262 rejects such an iteration
//! (RepeatMatcher's empty check) and the VM doesn't model that rule before
//! F4b. `{0,1}` and `{1,1}` are allowed with a nullable body: they don't
//! iterate, so there is no "next, empty iteration" to reject; `{1,1}` is the
//! body once and `{0,1}` the body or nothing, in the priority order of its
//! branches.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir");
const hir = ir.hir;
const CharSet = ir.charset.CharSet;
const program = @import("program.zig");
const Program = program.Program;
const Inst = program.Inst;
const Set = program.Set;
const prefilter = @import("prefilter.zig");

/// Why a pattern stays on the backtracker in F4a.
pub const Ineligible = enum {
    capture,
    backref,
    lookaround,
    raw_byte,
    nullable_repeat,
    /// `i` on a non-ASCII literal (T1's Canonicalize, F5).
    non_ascii_fold,
    /// The unrolled program would exceed `max_insts`.
    too_large,
    /// A possessive quantifier (D8's opt-in): the dispatcher never gets
    /// here with one (it is a known deviation), and the VM has no atomic
    /// repeat.
    possessive,
};

/// Upper bound on a T0 program's instructions (the unrolled repeats).
pub const max_insts: usize = 1 << 20;

/// Upper bound on a tagged program's capture slots times instructions: the
/// tagged VM keeps a row of slots per instruction per thread list (F4b D1).
pub const max_slot_cells: usize = 1 << 20;

/// Why `root` can't run on F4a's T0 (no captures), or null if it can.
pub fn check(root: *const hir.Node) ?Ineligible {
    if (checkNode(root, .{}, false)) |why| return why;
    if (size(root, false) > max_insts) return .too_large;
    return null;
}

/// Why `root` can't run on F4b's tagged T0 (captures, and repeats over
/// nullable bodies through the phase product), or null if it can.
pub fn checkTagged(root: *const hir.Node) ?Ineligible {
    if (checkNode(root, .{}, true)) |why| return why;
    const insts = size(root, true);
    if (insts > max_insts) return .too_large;
    if (insts *| slotCount(root) > max_slot_cells) return .too_large;
    return null;
}

/// Capture slots of `root`: 2 per group, group 0 included.
pub fn slotCount(root: *const hir.Node) u32 {
    const r = hir.captureRange(root) orelse return 2;
    return 2 * (@as(u32, r.hi) + 1);
}

fn checkNode(node: *const hir.Node, flags: hir.Flags, tagged: bool) ?Ineligible {
    switch (node.*) {
        .empty, .char_set, .assert => return null,
        .literal => |l| for (l.units) |u| {
            if (u.raw_byte) return .raw_byte;
            if (flags.ignore_case and u.value >= 0x80) return .non_ascii_fold;
        },
        .seq, .alt => |items| for (items) |item| {
            if (checkNode(item, flags, tagged)) |why| return why;
        },
        .repeat => |r| {
            if (r.policy == .possessive) return .possessive;
            const iterates = r.max == null or r.max.? > 1;
            if (!tagged and iterates and hir.nullable(r.body)) return .nullable_repeat;
            return checkNode(r.body, flags, tagged);
        },
        .capture => |c| return if (tagged) checkNode(c.body, flags, tagged) else .capture,
        .backref => return .backref,
        .look => return .lookaround,
        .modifier_scope => |m| return checkNode(m.body, m.flags, tagged),
    }
    return null;
}

/// Instructions `node` compiles to, saturating (no match instruction). A
/// bound for tagged programs: a phase product (an optional iteration of a
/// nullable body) is two copies, one `jmp` per consuming instruction, the
/// `clear` and the `fail`, counted as 3 x body + 2.
fn size(node: *const hir.Node, tagged: bool) usize {
    return switch (node.*) {
        .empty => 0,
        .literal => |l| l.units.len,
        .char_set, .assert => 1,
        .seq => |items| blk: {
            var n: usize = 0;
            for (items) |item| n +|= size(item, tagged);
            break :blk n;
        },
        .alt => |items| blk: {
            var n: usize = 0;
            for (items) |item| n +|= size(item, tagged) +| 2;
            break :blk n;
        },
        .repeat => |r| blk: {
            const body = size(r.body, tagged);
            const clear: usize = @intFromBool(tagged);
            const fixed = (body +| clear) *| r.min;
            const optional = if (tagged and hir.nullable(r.body)) body *| 3 +| 2 else body +| clear;
            break :blk if (r.max) |max| fixed +| (optional +| 1) *| (max - r.min) else fixed +| optional +| 2;
        },
        .capture => |c| size(c.body, tagged) +| @as(usize, if (tagged) 2 else 0),
        .modifier_scope => |m| size(m.body, tagged),
        .backref, .look => 1,
    };
}

pub const Error = Allocator.Error || error{Ineligible};

pub const Options = struct {
    /// The prefilters and fast paths (`prefilter.zig`). Off only for tests
    /// and the bench, to measure and compare the plain VM.
    prefilters: bool = true,
    /// F4b's program (docs/REGEX_TIERS_PLAN.md §6.5): capture groups
    /// (`save`), their reset at each iteration (`clear`), and optional
    /// iterations of nullable bodies through the phase product (D3), with
    /// `checkTagged`'s eligibility. The VM without captures runs it too,
    /// passing over `save`/`clear` (D5's first pass).
    tagged: bool = false,
};

/// The T0 program for `root`, which `check` must have accepted.
pub fn compile(gpa: Allocator, root: *const hir.Node) Error!Program {
    return compileWith(gpa, root, .{});
}

pub fn compileWith(gpa: Allocator, root: *const hir.Node, options: Options) Error!Program {
    const why = if (options.tagged) checkTagged(root) else check(root);
    if (why != null) return error.Ineligible;
    return compileAccepted(gpa, root, options);
}

/// `compileWith` for a `root` the caller has already passed through
/// `check` (the dispatcher does, to decide the route): the check isn't run
/// twice.
pub fn compileAccepted(gpa: Allocator, root: *const hir.Node, options: Options) Allocator.Error!Program {
    std.debug.assert((if (options.tagged) checkTagged(root) else check(root)) == null);
    var sets: std.ArrayListUnmanaged(Set) = .empty;
    errdefer {
        for (sets.items) |s| s.set.deinit(gpa);
        sets.deinit(gpa);
    }
    var b: Builder = .{ .gpa = gpa, .sets = &sets, .tagged = options.tagged };
    errdefer b.insts.deinit(gpa);
    try b.insts.ensureTotalCapacity(gpa, size(root, options.tagged) + 1);
    try b.emit(root, .{});
    try b.insts.append(gpa, .match);
    const insts = try b.insts.toOwnedSlice(gpa);
    const owned_sets = sets.toOwnedSlice(gpa) catch |err| {
        gpa.free(insts);
        return err;
    };
    var undo: u32 = 0;
    for (insts) |inst| switch (inst) {
        .save => undo += 1,
        .clear => |c| undo += c.hi - c.lo,
        else => {},
    };
    var prog: Program = .{ .insts = insts, .sets = owned_sets, .nslots = if (options.tagged) slotCount(root) else 2, .max_undo = undo };
    // Flags live in `modifier_scope` nodes, only the root one today.
    if (root.* == .modifier_scope) prog.word_ci = root.modifier_scope.flags.ignore_case;
    errdefer prog.deinit(gpa);
    try buildClosures(gpa, &prog);
    if (options.prefilters) prog.prefilter = try prefilter.analyze(gpa, root, &prog);
    return prog;
}

/// Total entries of `Program.follow` before the remaining pcs get dynamic
/// closures (a long alternation's closures can overlap: quadratic).
const max_follow: usize = 1 << 16;

/// Precomputes each pc's epsilon closure (`program.Closure`), so the VM's
/// `addThread` copies a list instead of walking splits and jumps. A pc
/// whose closure reaches an `assert` stays dynamic: the assert's outcome
/// depends on the position.
fn buildClosures(gpa: Allocator, prog: *Program) Allocator.Error!void {
    const n = prog.insts.len;
    const closures = try gpa.alloc(program.Closure, n);
    errdefer gpa.free(closures);
    var follow: std.ArrayListUnmanaged(u32) = .empty;
    errdefer follow.deinit(gpa);
    // Visited stamps (the pc being closed + 1) and the DFS stack (at most
    // two entries per visited pc), in one allocation.
    const work = try gpa.alloc(u32, 3 * n + 1);
    defer gpa.free(work);
    const stamp = work[0..n];
    @memset(stamp, 0);
    const stack = work[n..];
    for (closures, 0..) |*cl, pc0| {
        const mark: u32 = @intCast(pc0 + 1);
        const start = follow.items.len;
        var sp: usize = 1;
        stack[0] = @intCast(pc0);
        var dynamic = false;
        while (sp != 0 and !dynamic) {
            sp -= 1;
            const pc = stack[sp];
            if (stamp[pc] == mark) continue;
            stamp[pc] = mark;
            switch (prog.insts[pc]) {
                .jmp => |t| {
                    stack[sp] = t;
                    sp += 1;
                },
                // `y` first on the stack, so `x` is closed first.
                .split => |s| {
                    stack[sp] = s.y;
                    stack[sp + 1] = s.x;
                    sp += 2;
                },
                .assert => dynamic = true,
                // Epsilon for the VM without captures; the tagged VM (F4b)
                // walks its closures itself.
                .save, .clear => {
                    stack[sp] = pc + 1;
                    sp += 1;
                },
                .fail => {},
                .char, .set, .match => try follow.append(gpa, @intCast(pc)),
            }
        }
        if (dynamic or follow.items.len > max_follow) {
            follow.shrinkRetainingCapacity(start);
            cl.* = .dynamic;
        } else {
            cl.* = .{ .start = @intCast(start), .len = @intCast(follow.items.len - start) };
        }
    }
    prog.follow = try follow.toOwnedSlice(gpa);
    prog.closures = closures;
}

const Builder = struct {
    gpa: Allocator,
    insts: std.ArrayListUnmanaged(Inst) = .empty,
    /// Shared with the sub-builders of the phase product, so set indices
    /// stay valid when their instructions are copied into this one.
    sets: *std.ArrayListUnmanaged(Set),
    tagged: bool,
    /// The HIR ranges of the last `char_set` node's set, and its index: the
    /// same node emitted again (`x+` is `x` then `x*`) is found without
    /// comparing its ranges (F7b(6): `\p{L}+` spent a third of its
    /// compile there). Only for HIR sets: their ranges stay put for the
    /// whole compile, where `emitUnit`'s are freed at once and the next
    /// letter's can get the same address.
    last: struct { src: [*]const ir.charset.Range = undefined, len: usize = std.math.maxInt(usize), idx: u32 = 0 } = .{},

    fn pc(self: *const Builder) u32 {
        return @intCast(self.insts.items.len);
    }

    fn add(self: *Builder, inst: Inst) Allocator.Error!u32 {
        const at = self.pc();
        try self.insts.append(self.gpa, inst);
        return at;
    }

    /// Adds a set the program owns (a copy of `set`), or reuses an equal
    /// one (an unrolled `\d{3}` is one set, not three).
    fn addSet(self: *Builder, set: CharSet) Allocator.Error!u32 {
        for (self.sets.items, 0..) |s, i| if (s.set.eql(set)) return @intCast(i);
        try self.sets.ensureUnusedCapacity(self.gpa, 1);
        const s = try Set.init(self.gpa, set);
        self.sets.appendAssumeCapacity(s);
        return @intCast(self.sets.items.len - 1);
    }

    /// `addSet` for a `char_set` node's set (see `last`).
    fn addHirSet(self: *Builder, set: CharSet) Allocator.Error!u32 {
        if (self.last.len == set.ranges.len and self.last.src == set.ranges.ptr) return self.last.idx;
        const idx = try self.addSet(set);
        self.last = .{ .src = set.ranges.ptr, .len = set.ranges.len, .idx = idx };
        return idx;
    }

    fn emit(self: *Builder, node: *const hir.Node, flags: hir.Flags) Allocator.Error!void {
        switch (node.*) {
            .empty => {},
            .literal => |l| for (l.units) |u| try self.emitUnit(u.value, flags),
            .char_set => |cs| _ = try self.add(.{ .set = try self.addHirSet(cs.set) }),
            .seq => |items| for (items) |item| try self.emit(item, flags),
            .alt => |items| try self.emitAlt(items, flags),
            .repeat => |r| try self.emitRepeat(r, flags),
            .assert => |a| _ = try self.add(.{ .assert = switch (a) {
                .caret => if (flags.multiline) .line_start else .text_start,
                .dollar => if (flags.multiline) .line_end else .text_end,
                .word_boundary => .word_boundary,
                .not_word_boundary => .not_word_boundary,
            } }),
            .modifier_scope => |m| try self.emit(m.body, m.flags),
            // `checkTagged` lets captures in only for tagged programs.
            .capture => |c| {
                std.debug.assert(self.tagged);
                _ = try self.add(.{ .save = 2 * @as(u32, c.index) });
                try self.emit(c.body, flags);
                _ = try self.add(.{ .save = 2 * @as(u32, c.index) + 1 });
            },
            // `check` keeps these out.
            .backref, .look => unreachable,
        }
    }

    /// One literal character; under `i` an ASCII letter is both of its cases
    /// (T0's Canonicalize: `check` keeps non-ASCII `i` literals out).
    fn emitUnit(self: *Builder, c: u32, flags: hir.Flags) Allocator.Error!void {
        const lower = c | 0x20;
        if (flags.ignore_case and lower >= 'a' and lower <= 'z') {
            const upper = lower - 0x20;
            var ranges = [_]ir.charset.Range{ .{ .lo = upper, .hi = upper }, .{ .lo = lower, .hi = lower } };
            const set = try CharSet.fromRanges(self.gpa, &ranges);
            defer set.deinit(self.gpa);
            _ = try self.add(.{ .set = try self.addSet(set) });
            return;
        }
        _ = try self.add(.{ .char = c });
    }

    /// `a|b|c`: each alternative before the next.
    fn emitAlt(self: *Builder, items: []const *const hir.Node, flags: hir.Flags) Allocator.Error!void {
        var jumps: std.ArrayListUnmanaged(u32) = .empty;
        defer jumps.deinit(self.gpa);
        for (items, 0..) |item, i| {
            if (i + 1 == items.len) {
                try self.emit(item, flags);
                break;
            }
            const split = try self.add(.{ .split = .{ .x = 0, .y = 0 } });
            self.insts.items[split].split.x = self.pc();
            try self.emit(item, flags);
            try jumps.append(self.gpa, try self.add(.{ .jmp = 0 }));
            self.insts.items[split].split.y = self.pc();
        }
        const end = self.pc();
        for (jumps.items) |j| self.insts.items[j].jmp = end;
    }

    /// `min` copies, then either `max - min` optional copies or a loop.
    /// Tagged: each iteration starts with `clear` of the body's groups (D4),
    /// and an optional iteration of a nullable body is a phase product (D3).
    fn emitRepeat(self: *Builder, r: hir.Repeat, flags: hir.Flags) Allocator.Error!void {
        const iter: Iteration = .{
            .body = r.body,
            .flags = flags,
            .clear = if (!self.tagged) null else if (hir.captureRange(r.body)) |g| .{ .lo = 2 * @as(u32, g.lo), .hi = 2 * @as(u32, g.hi) + 2 } else null,
            .product = self.tagged and hir.nullable(r.body),
        };
        for (0..r.min) |_| try self.emitIteration(iter, false);
        const greedy = r.policy != .lazy;
        if (r.max) |max| {
            // x{n,m}: each optional copy may be skipped to the end.
            var exits: std.ArrayListUnmanaged(u32) = .empty;
            defer exits.deinit(self.gpa);
            for (r.min..max) |_| {
                const split = try self.add(.{ .split = .{ .x = 0, .y = 0 } });
                try exits.append(self.gpa, split);
                const body = self.pc();
                try self.emitIteration(iter, true);
                self.insts.items[split].split = if (greedy) .{ .x = body, .y = 0 } else .{ .x = 0, .y = body };
            }
            const end = self.pc();
            for (exits.items) |s| {
                const sp = &self.insts.items[s].split;
                if (greedy) sp.y = end else sp.x = end;
            }
        } else {
            // x*: L: split(body, out); body; jmp L.
            const loop = try self.add(.{ .split = .{ .x = 0, .y = 0 } });
            const body = self.pc();
            try self.emitIteration(iter, true);
            _ = try self.add(.{ .jmp = loop });
            const out = self.pc();
            self.insts.items[loop].split = if (greedy) .{ .x = body, .y = out } else .{ .x = out, .y = body };
        }
    }

    const Iteration = struct {
        body: *const hir.Node,
        flags: hir.Flags,
        clear: ?@FieldType(Inst, "clear"),
        product: bool,
    };

    /// One iteration of a repeat. `optional`: past `min`, where ECMA-262
    /// rejects an iteration that consumes nothing.
    fn emitIteration(self: *Builder, it: Iteration, optional: bool) Allocator.Error!void {
        if (it.clear) |c| _ = try self.add(.{ .clear = c });
        if (optional and it.product) return self.emitProduct(it.body, it.flags);
        try self.emit(it.body, it.flags);
    }

    /// The phase product of an optional iteration of a nullable body (D3):
    /// B0, a copy of the body in which nothing has been consumed yet, whose
    /// consuming instructions continue in B1 and whose end is `fail`; then
    /// B1, the body itself, whose end completes the iteration. The body is
    /// emitted once, into a sub-builder (targets relative to 0, its end is
    /// its length), and copied twice with its targets relocated.
    fn emitProduct(self: *Builder, body: *const hir.Node, flags: hir.Flags) Allocator.Error!void {
        var sub: Builder = .{ .gpa = self.gpa, .sets = self.sets, .tagged = self.tagged };
        defer sub.insts.deinit(self.gpa);
        try sub.emit(body, flags);
        const rel = sub.insts.items;
        const n = rel.len;
        // Where each body instruction lands in B0: one more slot after each
        // consuming one, for its jump into B1.
        const map0 = try self.gpa.alloc(u32, n + 1);
        defer self.gpa.free(map0);
        var at = self.pc();
        for (rel, 0..) |inst, i| {
            map0[i] = at;
            at += 1 + @as(u32, @intFromBool(consumes(inst)));
        }
        const fail_pc = at;
        map0[n] = fail_pc; // the end of B0: an iteration that consumed nothing
        const base1 = fail_pc + 1;
        try self.insts.ensureUnusedCapacity(self.gpa, (fail_pc - self.pc()) + 1 + n);
        for (rel, 0..) |inst, i| {
            self.insts.appendAssumeCapacity(relocate(inst, map0, 0));
            if (consumes(inst)) self.insts.appendAssumeCapacity(.{ .jmp = base1 + @as(u32, @intCast(i)) + 1 });
        }
        self.insts.appendAssumeCapacity(.fail);
        for (rel) |inst| self.insts.appendAssumeCapacity(relocate(inst, null, base1));
    }

    fn consumes(inst: Inst) bool {
        return inst == .char or inst == .set;
    }

    /// `inst` with its targets mapped through `map` (B0) or shifted by
    /// `base` (B1).
    fn relocate(inst: Inst, map: ?[]const u32, base: u32) Inst {
        const to = struct {
            fn f(t: u32, m: ?[]const u32, b: u32) u32 {
                return if (m) |mm| mm[t] else b + t;
            }
        }.f;
        return switch (inst) {
            .jmp => |t| .{ .jmp = to(t, map, base) },
            .split => |sp| .{ .split = .{ .x = to(sp.x, map, base), .y = to(sp.y, map, base) } },
            else => inst,
        };
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn lit(comptime s: []const u8) hir.Node {
    const units = comptime blk: {
        var u: [s.len]hir.LitUnit = undefined;
        for (s, 0..) |c, i| u[i] = .{ .value = c };
        const out = u;
        break :blk out;
    };
    return .{ .literal = .{ .units = &units } };
}

fn expectProgram(root: *const hir.Node, expected: []const u8) !void {
    const p = try compile(testing.allocator, root);
    defer p.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try p.dump(&out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "alternation and repeats compile in priority order" {
    const a = lit("a");
    const b = lit("b");
    const alt: hir.Node = .{ .alt = &.{ &a, &b } };
    try expectProgram(&alt,
        \\  0: split 1, 3
        \\  1: char 'a'
        \\  2: jmp 4
        \\  3: char 'b'
        \\  4: match
        \\
    );
    const star: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &a } };
    try expectProgram(&star,
        \\  0: split 1, 3
        \\  1: char 'a'
        \\  2: jmp 0
        \\  3: match
        \\
    );
    const lazy: hir.Node = .{ .repeat = .{ .min = 1, .max = 3, .policy = .lazy, .syntax_form = .counted, .body = &a } };
    try expectProgram(&lazy,
        \\  0: char 'a'
        \\  1: split 5, 2
        \\  2: char 'a'
        \\  3: split 5, 4
        \\  4: char 'a'
        \\  5: match
        \\
    );
}

test "flags: i on ASCII letters, m on anchors" {
    const ab = lit("a1");
    const caret: hir.Node = .{ .assert = .caret };
    const seq: hir.Node = .{ .seq = &.{ &caret, &ab } };
    const scope: hir.Node = .{ .modifier_scope = .{ .flags = .{ .ignore_case = true, .multiline = true }, .body = &seq } };
    try expectProgram(&scope,
        \\  0: assert line_start
        \\  1: set 0: 41-41 61-61
        \\  2: char '1'
        \\  3: match
        \\
    );
}

test "check: what stays on the backtracker in F4a" {
    const a = lit("a");
    const e: hir.Node = .empty;
    const opt_e: hir.Node = .{ .repeat = .{ .min = 0, .max = 1, .policy = .greedy, .syntax_form = .question, .body = &e } };
    const star_e: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &opt_e } };
    const two_e: hir.Node = .{ .repeat = .{ .min = 2, .max = 2, .policy = .greedy, .syntax_form = .counted, .body = &e } };
    const cap: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &a } };
    const look: hir.Node = .{ .look = .{ .behind = false, .negated = false, .body = &a } };
    const raw: hir.Node = .{ .literal = .{ .units = &.{.{ .value = 0xE9, .raw_byte = true }} } };
    const e9: hir.Node = .{ .literal = .{ .units = &.{.{ .value = 0xE9 }} } };
    const fold: hir.Node = .{ .modifier_scope = .{ .flags = .{ .ignore_case = true }, .body = &e9 } };
    const big: hir.Node = .{ .repeat = .{ .min = 2_000_000, .max = 2_000_000, .policy = .greedy, .syntax_form = .counted, .body = &a } };
    try testing.expectEqual(@as(?Ineligible, null), check(&a));
    try testing.expectEqual(@as(?Ineligible, null), check(&opt_e)); // {0,1} over empty: allowed
    try testing.expectEqual(@as(?Ineligible, .nullable_repeat), check(&star_e));
    try testing.expectEqual(@as(?Ineligible, .nullable_repeat), check(&two_e));
    try testing.expectEqual(@as(?Ineligible, .capture), check(&cap));
    try testing.expectEqual(@as(?Ineligible, .lookaround), check(&look));
    try testing.expectEqual(@as(?Ineligible, .raw_byte), check(&raw));
    try testing.expectEqual(@as(?Ineligible, .non_ascii_fold), check(&fold));
    try testing.expectEqual(@as(?Ineligible, .too_large), check(&big));
    const poss: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .possessive, .syntax_form = .star, .body = &a } };
    try testing.expectEqual(@as(?Ineligible, .possessive), check(&poss));
    try testing.expectError(error.Ineligible, compile(testing.allocator, &cap));
}

test "compile doesn't leak on allocation failure" {
    const a = lit("aB");
    const b = lit("c");
    const alt: hir.Node = .{ .alt = &.{ &a, &b } };
    const rep: hir.Node = .{ .repeat = .{ .min = 1, .max = 4, .policy = .greedy, .syntax_form = .counted, .body = &alt } };
    const scope: hir.Node = .{ .modifier_scope = .{ .flags = .{ .ignore_case = true }, .body = &rep } };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(gpa: Allocator, root: *const hir.Node) !void {
            const p = compile(gpa, root) catch |err| switch (err) {
                error.Ineligible => unreachable,
                else => |e| return e,
            };
            p.deinit(gpa);
        }
    }.f, .{&scope});
}

fn expectTagged(root: *const hir.Node, expected: []const u8) !void {
    const p = try compileWith(testing.allocator, root, .{ .tagged = true, .prefilters = false });
    defer p.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try p.dump(&out.writer);
    try testing.expectEqualStrings(expected, out.written());
    // `size` bounds what is emitted.
    try testing.expect(p.insts.len <= size(root, true) + 1);
}

test "tagged: a group saves its start and end" {
    const ab = lit("ab");
    const g1: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &ab } };
    try expectTagged(&g1,
        \\  0: save 2
        \\  1: char 'a'
        \\  2: char 'b'
        \\  3: save 3
        \\  4: match
        \\
    );
}

test "tagged: (a*)* is a phase product (D3, worked example 1)" {
    const a = lit("a");
    const star_a: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &a } };
    const g1: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &star_a } };
    const outer: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &g1 } };
    // 1: the iteration's reset; 2-8: B0, whose `a` continues in B1 (5) and
    // whose end is `fail` (8); 9-14: B1, whose end loops back (14).
    try expectTagged(&outer,
        \\  0: split 1, 15
        \\  1: clear 2..4
        \\  2: save 2
        \\  3: split 4, 7
        \\  4: char 'a'
        \\  5: jmp 12
        \\  6: jmp 3
        \\  7: save 3
        \\  8: fail
        \\  9: save 2
        \\ 10: split 11, 13
        \\ 11: char 'a'
        \\ 12: jmp 10
        \\ 13: save 3
        \\ 14: jmp 0
        \\ 15: match
        \\
    );
}

test "tagged: (a*)+ keeps the mandatory iteration plain (D3, worked example 2)" {
    const a = lit("a");
    const star_a: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &a } };
    const g1: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &star_a } };
    const plus: hir.Node = .{ .repeat = .{ .min = 1, .max = null, .policy = .greedy, .syntax_form = .plus, .body = &g1 } };
    try expectTagged(&plus,
        \\  0: clear 2..4
        \\  1: save 2
        \\  2: split 3, 5
        \\  3: char 'a'
        \\  4: jmp 2
        \\  5: save 3
        \\  6: split 7, 21
        \\  7: clear 2..4
        \\  8: save 2
        \\  9: split 10, 13
        \\ 10: char 'a'
        \\ 11: jmp 18
        \\ 12: jmp 9
        \\ 13: save 3
        \\ 14: fail
        \\ 15: save 2
        \\ 16: split 17, 19
        \\ 17: char 'a'
        \\ 18: jmp 16
        \\ 19: save 3
        \\ 20: jmp 6
        \\ 21: match
        \\
    );
}

test "tagged: (b?)? rejects the empty iteration of ?, a non-iterating optional" {
    const b = lit("b");
    const opt_b: hir.Node = .{ .repeat = .{ .min = 0, .max = 1, .policy = .greedy, .syntax_form = .question, .body = &b } };
    const g1: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &opt_b } };
    const opt: hir.Node = .{ .repeat = .{ .min = 0, .max = 1, .policy = .greedy, .syntax_form = .question, .body = &g1 } };
    try expectTagged(&opt,
        \\  0: split 1, 12
        \\  1: clear 2..4
        \\  2: save 2
        \\  3: split 4, 6
        \\  4: char 'b'
        \\  5: jmp 11
        \\  6: save 3
        \\  7: fail
        \\  8: save 2
        \\  9: split 10, 11
        \\ 10: char 'b'
        \\ 11: save 3
        \\ 12: match
        \\
    );
}

test "tagged: nested nullable loops, ((a*)*)*: four copies of the inner a* (D3, worked example 3)" {
    const a = lit("a");
    const star_a: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &a } };
    const g2: hir.Node = .{ .capture = .{ .index = 2, .name = null, .body = &star_a } };
    const mid: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &g2 } };
    const g1: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &mid } };
    const outer: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &g1 } };
    const p = try compileWith(testing.allocator, &outer, .{ .tagged = true, .prefilters = false });
    defer p.deinit(testing.allocator);
    var chars: usize = 0;
    var fails: usize = 0;
    for (p.insts) |inst| switch (inst) {
        .char => chars += 1,
        .fail => fails += 1,
        else => {},
    };
    // The outer body twice (B0, B1), each with the middle loop's two
    // copies: four `a`; a `fail` per phase-0 copy: the outer one, and the
    // middle one in each outer copy.
    try testing.expectEqual(@as(usize, 4), chars);
    try testing.expectEqual(@as(usize, 3), fails);
    try testing.expectEqual(@as(u32, 6), p.nslots);
    try testing.expect(p.insts.len <= size(&outer, true) + 1);
}

test "checkTagged: captures and nullable loops are in, the rest as before" {
    const a = lit("a");
    const e: hir.Node = .empty;
    const g1: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &a } };
    const star_e: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &e } };
    const look: hir.Node = .{ .look = .{ .behind = false, .negated = false, .body = &a } };
    const raw: hir.Node = .{ .literal = .{ .units = &.{.{ .value = 0xE9, .raw_byte = true }} } };
    try testing.expectEqual(@as(?Ineligible, null), checkTagged(&g1));
    try testing.expectEqual(@as(?Ineligible, null), checkTagged(&star_e));
    try testing.expectEqual(@as(?Ineligible, .capture), check(&g1));
    try testing.expectEqual(@as(?Ineligible, .nullable_repeat), check(&star_e));
    try testing.expectEqual(@as(?Ineligible, .lookaround), checkTagged(&look));
    try testing.expectEqual(@as(?Ineligible, .raw_byte), checkTagged(&raw));
    // The slot table's bound: a group numbered 60,000 over a long program.
    const many: hir.Node = .{ .repeat = .{ .min = 100, .max = 100, .policy = .greedy, .syntax_form = .counted, .body = &a } };
    const seq: hir.Node = .{ .seq = &.{&many} };
    const big: hir.Node = .{ .capture = .{ .index = 60000, .name = null, .body = &seq } };
    try testing.expectEqual(@as(?Ineligible, .too_large), checkTagged(&big));
    try testing.expectError(error.Ineligible, compileWith(testing.allocator, &big, .{ .tagged = true }));
}

test "tagged compile doesn't leak on allocation failure" {
    const a = lit("aB");
    const star_a: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &a } };
    const g1: hir.Node = .{ .capture = .{ .index = 1, .name = null, .body = &star_a } };
    const outer: hir.Node = .{ .repeat = .{ .min = 1, .max = 3, .policy = .lazy, .syntax_form = .counted, .body = &g1 } };
    const scope: hir.Node = .{ .modifier_scope = .{ .flags = .{ .ignore_case = true }, .body = &outer } };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(gpa: Allocator, root: *const hir.Node) !void {
            const p = compileWith(gpa, root, .{ .tagged = true }) catch |err| switch (err) {
                error.Ineligible => unreachable,
                else => |e| return e,
            };
            p.deinit(gpa);
        }
    }.f, .{&scope});
}

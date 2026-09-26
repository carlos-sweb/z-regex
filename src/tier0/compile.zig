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
};

/// Upper bound on a T0 program's instructions (the unrolled repeats).
pub const max_insts: usize = 1 << 20;

/// Why `root` can't run on T0 in F4a, or null if it can.
pub fn check(root: *const hir.Node) ?Ineligible {
    if (checkNode(root, .{})) |why| return why;
    if (size(root) > max_insts) return .too_large;
    return null;
}

fn checkNode(node: *const hir.Node, flags: hir.Flags) ?Ineligible {
    switch (node.*) {
        .empty, .char_set, .assert => return null,
        .literal => |l| for (l.units) |u| {
            if (u.raw_byte) return .raw_byte;
            if (flags.ignore_case and u.value >= 0x80) return .non_ascii_fold;
        },
        .seq, .alt => |items| for (items) |item| {
            if (checkNode(item, flags)) |why| return why;
        },
        .repeat => |r| {
            const iterates = r.max == null or r.max.? > 1;
            if (iterates and hir.nullable(r.body)) return .nullable_repeat;
            return checkNode(r.body, flags);
        },
        .capture => return .capture,
        .backref => return .backref,
        .look => return .lookaround,
        .modifier_scope => |m| return checkNode(m.body, m.flags),
    }
    return null;
}

/// Instructions `node` compiles to, saturating (no match instruction).
fn size(node: *const hir.Node) usize {
    return switch (node.*) {
        .empty => 0,
        .literal => |l| l.units.len,
        .char_set, .assert => 1,
        .seq => |items| blk: {
            var n: usize = 0;
            for (items) |item| n +|= size(item);
            break :blk n;
        },
        .alt => |items| blk: {
            var n: usize = 0;
            for (items) |item| n +|= size(item) +| 2;
            break :blk n;
        },
        .repeat => |r| blk: {
            const body = size(r.body);
            const fixed = body *| r.min;
            break :blk if (r.max) |max| fixed +| (body +| 1) *| (max - r.min) else fixed +| body +| 2;
        },
        .capture => |c| size(c.body),
        .modifier_scope => |m| size(m.body),
        .backref, .look => 1,
    };
}

pub const Error = Allocator.Error || error{Ineligible};

/// The T0 program for `root`, which `check` must have accepted.
pub fn compile(gpa: Allocator, root: *const hir.Node) Error!Program {
    if (check(root) != null) return error.Ineligible;
    var b: Builder = .{ .gpa = gpa };
    errdefer b.deinit();
    try b.emit(root, .{});
    try b.insts.append(gpa, .match);
    const insts = try b.insts.toOwnedSlice(gpa);
    errdefer gpa.free(insts);
    return .{ .insts = insts, .sets = try b.sets.toOwnedSlice(gpa) };
}

const Builder = struct {
    gpa: Allocator,
    insts: std.ArrayListUnmanaged(Inst) = .empty,
    sets: std.ArrayListUnmanaged(Set) = .empty,

    fn deinit(self: *Builder) void {
        for (self.sets.items) |s| s.set.deinit(self.gpa);
        self.sets.deinit(self.gpa);
        self.insts.deinit(self.gpa);
    }

    fn pc(self: *const Builder) u32 {
        return @intCast(self.insts.items.len);
    }

    fn add(self: *Builder, inst: Inst) Allocator.Error!u32 {
        const at = self.pc();
        try self.insts.append(self.gpa, inst);
        return at;
    }

    /// Adds a set the program owns (a copy of `set`).
    fn addSet(self: *Builder, set: CharSet) Allocator.Error!u32 {
        try self.sets.ensureUnusedCapacity(self.gpa, 1);
        const s = try Set.init(self.gpa, set);
        self.sets.appendAssumeCapacity(s);
        return @intCast(self.sets.items.len - 1);
    }

    fn emit(self: *Builder, node: *const hir.Node, flags: hir.Flags) Allocator.Error!void {
        switch (node.*) {
            .empty => {},
            .literal => |l| for (l.units) |u| try self.emitUnit(u.value, flags),
            .char_set => |cs| _ = try self.add(.{ .set = try self.addSet(cs.set) }),
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
            // `check` keeps these out.
            .capture, .backref, .look => unreachable,
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
    fn emitRepeat(self: *Builder, r: hir.Repeat, flags: hir.Flags) Allocator.Error!void {
        for (0..r.min) |_| try self.emit(r.body, flags);
        const greedy = r.policy != .lazy;
        if (r.max) |max| {
            // x{n,m}: each optional copy may be skipped to the end.
            var exits: std.ArrayListUnmanaged(u32) = .empty;
            defer exits.deinit(self.gpa);
            for (r.min..max) |_| {
                const split = try self.add(.{ .split = .{ .x = 0, .y = 0 } });
                try exits.append(self.gpa, split);
                const body = self.pc();
                try self.emit(r.body, flags);
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
            try self.emit(r.body, flags);
            _ = try self.add(.{ .jmp = loop });
            const out = self.pc();
            self.insts.items[loop].split = if (greedy) .{ .x = body, .y = out } else .{ .x = out, .y = body };
        }
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

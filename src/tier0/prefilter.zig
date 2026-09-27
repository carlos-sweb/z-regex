//! T0's prefilters and fast paths (docs/REGEX_TIERS_PLAN.md, F4a D7),
//! computed once at compile time and stored in `Program.prefilter`.
//!
//! Each one is exact: it gives the result the VM gives without it (the
//! corpus differential compares the two). They apply only in code-unit mode
//! (without `u`/`v`, which is all of T0 in F4a); in code-point mode the
//! search runs the plain VM.
//!
//! **Invariant: the fast paths (`literal`, `class_run`) and the `first`
//! skip never touch `VmScratch`.** A pattern served by a fast path never
//! grows the VM's buffers, so a host that only runs such patterns pays for
//! no thread lists (`exec` sizes the scratch only on the VM path).
//!
//! - `anchored`: every path starts with `^` (no `m`). A search from an
//!   index above 0 has no match, and from 0 only a match at 0 counts.
//! - `literal`: the pattern is one literal (no `i` on a letter, no
//!   surrogate, no raw byte, nothing astral): `std.mem.indexOfPos` over the
//!   subject's units. In WTF-8 the literal's first byte is ASCII or a lead
//!   byte and UTF-8 synchronizes itself, so a match always starts at a
//!   position and covers whole characters; a literal never equals an
//!   ill-formed byte, and without surrogates it never starts at `b+2`.
//! - `class_run`: the pattern is `C+` or `C*` (greedy) over an ASCII-only
//!   class: the first member, then the longest run. A non-ASCII character
//!   or an ill-formed byte is never a member, and a run stops right after
//!   an ASCII unit, so every boundary is a position.
//! - `first`: the units a match can start with, to skip positions where
//!   none can (only while no thread is alive). See `First`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir");
const hir = ir.hir;
const program = @import("program.zig");
const Program = program.Program;
const Inst = program.Inst;

pub const Prefilter = struct {
    /// Every match starts at text position 0.
    anchored: bool = false,
    kind: Kind = .none,

    pub const Kind = union(enum) {
        none,
        literal: Literal,
        class_run: ClassRun,
        first: First,
    };

    pub fn deinit(self: Prefilter, gpa: Allocator) void {
        switch (self.kind) {
            .literal => |l| {
                gpa.free(l.utf8);
                gpa.free(l.utf16);
            },
            else => {},
        }
    }
};

/// The whole pattern as the subject's units.
pub const Literal = struct { utf8: []const u8, utf16: []const u16 };

/// `C+` (`min` 1) or `C*` (`min` 0) over an ASCII class, greedy.
pub const ClassRun = struct {
    /// Membership of each unit below 256 (only ASCII members are set).
    table: [256]bool,
    min: u1,

    pub inline fn has(self: *const ClassRun, c: u32) bool {
        return c < 256 and self.table[c];
    }
};

/// The code units a match can start with.
///
/// `utf8[b]`: a match can start at a byte `b` of a WTF-8 subject. ASCII
/// members are marked one by one; any member at or above U+0080 marks every
/// byte from 0x80 up (conservative: it covers lead bytes, ill-formed bytes
/// and the `b+2` position, whose byte is a continuation byte). So a scan
/// only stops at positions: a stop on a continuation byte `b+1`/`b+3`
/// would need the lead byte before it, also >= 0x80 and so marked, to have
/// been passed over, and a scan that starts at `b+2` stops there at once.
///
/// `utf16[u]` for units below 256, and `high` for every unit from 256 up
/// (every UTF-16 index is a position).
pub const First = struct {
    utf8: [256]bool,
    utf16: [256]bool,
    high: bool,
    /// The only possible WTF-8 byte, when there is one (memchr).
    single8: ?u8,
    /// The only possible UTF-16 unit, when there is one and it is below 256.
    single16: ?u8,
};

/// The prefilter for `prog`, compiled from `root`.
pub fn analyze(gpa: Allocator, root: *const hir.Node, prog: *const Program) Allocator.Error!Prefilter {
    var pf: Prefilter = .{ .anchored = prog.insts.len > 0 and prog.insts[0] == .assert and prog.insts[0].assert == .text_start };
    if (try literalOf(gpa, root)) |l| {
        pf.kind = .{ .literal = l };
    } else if (classRunOf(root)) |c| {
        pf.kind = .{ .class_run = c };
    } else if (firstOf(prog)) |f| {
        pf.kind = .{ .first = f };
    }
    return pf;
}

/// The root scope's body and flags.
fn body(root: *const hir.Node) struct { *const hir.Node, hir.Flags } {
    return switch (root.*) {
        .modifier_scope => |m| .{ m.body, m.flags },
        else => .{ root, .{} },
    };
}

fn literalOf(gpa: Allocator, root: *const hir.Node) Allocator.Error!?Literal {
    const node, const flags = body(root);
    if (node.* != .literal) return null;
    const units = node.literal.units;
    if (units.len == 0) return null;
    for (units) |u| {
        if (u.raw_byte or u.value > 0xFFFF or (u.value >= 0xD800 and u.value <= 0xDFFF)) return null;
        const lower = u.value | 0x20;
        if (flags.ignore_case and lower >= 'a' and lower <= 'z') return null;
    }
    var utf8: std.ArrayListUnmanaged(u8) = .empty;
    errdefer utf8.deinit(gpa);
    const utf16 = try gpa.alloc(u16, units.len);
    errdefer gpa.free(utf16);
    for (units, utf16) |u, *w| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(u.value), &buf) catch unreachable; // no surrogates
        try utf8.appendSlice(gpa, buf[0..n]);
        w.* = @intCast(u.value);
    }
    return .{ .utf8 = try utf8.toOwnedSlice(gpa), .utf16 = utf16 };
}

fn classRunOf(root: *const hir.Node) ?ClassRun {
    const node, _ = body(root);
    if (node.* != .repeat) return null;
    const r = node.repeat;
    if (r.max != null or r.min > 1 or r.policy != .greedy or r.body.* != .char_set) return null;
    const ranges = r.body.char_set.set.ranges;
    if (ranges.len == 0 or ranges[ranges.len - 1].hi >= 0x80) return null;
    var run: ClassRun = .{ .table = @splat(false), .min = @intCast(r.min) };
    for (ranges) |range| @memset(run.table[range.lo .. range.hi + 1], true);
    return run;
}

/// The units a match can start with, or null when a match can be empty
/// (the closure from pc 0 reaches `match`) or can start anywhere.
fn firstOf(prog: *const Program) ?First {
    return firstOfWith(prog, max_scan);
}

/// `firstOf` with the scan's bound as a parameter (tests use a small one).
fn firstOfWith(prog: *const Program, comptime scan: usize) ?First {
    // Built as bit sets (whole ranges per word, popcount to count), turned
    // into the lookup tables at the end.
    var utf8 = Bits.initEmpty();
    var utf16 = Bits.initEmpty();
    var high = false;
    // Depth-first over the epsilon closure of pc 0, asserts passed over.
    var seen = std.StaticBitSet(scan).initEmpty();
    // Each visited pc pops one entry and pushes at most two: the depth
    // stays within n + 1 (it was `scan`, one short at n = scan; F4b(1)).
    var stack: [2 * scan + 1]u32 = undefined;
    var sp: usize = 0;
    if (prog.insts.len > scan) return null;
    stack[0] = 0;
    sp = 1;
    while (sp != 0) {
        sp -= 1;
        const pc = stack[sp];
        if (seen.isSet(pc)) continue;
        seen.set(pc);
        switch (prog.insts[pc]) {
            .match => return null,
            .jmp => |t| {
                stack[sp] = t;
                sp += 1;
            },
            .split => |s| {
                stack[sp] = s.x;
                stack[sp + 1] = s.y;
                sp += 2;
            },
            .assert, .save, .clear => {
                stack[sp] = pc + 1;
                sp += 1;
            },
            .fail => {},
            .char => |c| mark(&utf8, &utf16, &high, c, c),
            .set => |i| for (prog.sets[i].set.ranges) |r| mark(&utf8, &utf16, &high, r.lo, r.hi),
        }
        // Every byte possible: nothing to skip, whatever else follows.
        if (utf8.count() == 256) return null;
    }
    var f: First = .{ .utf8 = undefined, .utf16 = undefined, .high = high, .single8 = null, .single16 = null };
    for (&f.utf8, &f.utf16, 0..) |*a, *b, i| {
        a.* = utf8.isSet(i);
        b.* = utf16.isSet(i);
    }
    if (utf8.count() == 1) f.single8 = @intCast(utf8.findFirstSet().?);
    if (utf16.count() == 1 and !high) f.single16 = @intCast(utf16.findFirstSet().?);
    return f;
}

const Bits = std.StaticBitSet(256);

/// Programs above this size get no `first` table (the scan's stack and
/// visited set are fixed-size); they still run, on the plain VM.
const max_scan = 4096;

/// Marks the units a character in `lo..hi` can start with: ASCII members
/// one by one; any member from U+0080 up, every byte from 0x80 up (see
/// `First`); in UTF-16, the units below 256 and `high` for the rest.
fn mark(utf8: *Bits, utf16: *Bits, high: *bool, lo: u32, hi: u32) void {
    // (`@min` with a constant narrows the type: widen before adding.)
    if (lo <= 0x7F) utf8.setRangeValue(.{ .start = lo, .end = @as(usize, @min(hi, 0x7F)) + 1 }, true);
    if (hi >= 0x80) utf8.setRangeValue(.{ .start = 0x80, .end = 256 }, true);
    if (lo <= 0xFF) utf16.setRangeValue(.{ .start = lo, .end = @as(usize, @min(hi, 0xFF)) + 1 }, true);
    if (hi >= 0x100) high.* = true;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
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

fn scope(flags: hir.Flags, b: *const hir.Node) hir.Node {
    return .{ .modifier_scope = .{ .flags = flags, .body = b } };
}

fn kindOf(root: *const hir.Node) !std.meta.Tag(Prefilter.Kind) {
    const p = try compile(testing.allocator, root);
    defer p.deinit(testing.allocator);
    return std.meta.activeTag(p.prefilter.kind);
}

fn setNode(set: CharSet) hir.Node {
    return .{ .char_set = .{ .set = set, .inverted = false, .encoding_hint = .set } };
}

test "literal: when it applies and when it doesn't" {
    const abc = lit("abc");
    try testing.expectEqual(.literal, try kindOf(&scope(.{}, &abc)));
    // `i` on a letter: not a byte search (but the VM still skips).
    try testing.expectEqual(.first, try kindOf(&scope(.{ .ignore_case = true }, &abc)));
    // `i` without letters is still a literal.
    const digits = lit("12-");
    try testing.expectEqual(.literal, try kindOf(&scope(.{ .ignore_case = true }, &digits)));
    // A surrogate (an astral character without `u`) or a raw byte: no.
    const sur: hir.Node = .{ .literal = .{ .units = &.{ .{ .value = 0xD83D }, .{ .value = 0xDE00 } } } };
    try testing.expect(try kindOf(&scope(.{}, &sur)) != .literal);
    const raw: hir.Node = .{ .literal = .{ .units = &.{.{ .value = 0xE9, .raw_byte = true }} } };
    try testing.expectError(error.Ineligible, compile(testing.allocator, &scope(.{}, &raw)));
    // Non-ASCII is fine: é€ as UTF-8 and UTF-16.
    const e: hir.Node = .{ .literal = .{ .units = &.{ .{ .value = 0xE9 }, .{ .value = 0x20AC } } } };
    const p = try compile(testing.allocator, &scope(.{}, &e));
    defer p.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "\u{E9}\u{20AC}", p.prefilter.kind.literal.utf8);
    try testing.expectEqualSlices(u16, &.{ 0xE9, 0x20AC }, p.prefilter.kind.literal.utf16);
}

test "class_run: C+ and C* over an ASCII class, greedy, nothing else" {
    const az = [_]ir.charset.Range{.{ .lo = 'a', .hi = 'z' }};
    const s = try CharSet.fromRanges(testing.allocator, &az);
    defer s.deinit(testing.allocator);
    const c = setNode(s);
    const plus: hir.Node = .{ .repeat = .{ .min = 1, .max = null, .policy = .greedy, .syntax_form = .plus, .body = &c } };
    const star: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &c } };
    const lazy: hir.Node = .{ .repeat = .{ .min = 1, .max = null, .policy = .lazy, .syntax_form = .plus, .body = &c } };
    const two: hir.Node = .{ .repeat = .{ .min = 2, .max = null, .policy = .greedy, .syntax_form = .counted, .body = &c } };
    try testing.expectEqual(.class_run, try kindOf(&scope(.{}, &plus)));
    try testing.expectEqual(.class_run, try kindOf(&scope(.{}, &star)));
    try testing.expectEqual(.first, try kindOf(&scope(.{}, &lazy)));
    try testing.expectEqual(.first, try kindOf(&scope(.{}, &two)));
    // A non-ASCII member: the VM.
    const wide = [_]ir.charset.Range{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0xE9, .hi = 0xE9 } };
    const w = try CharSet.fromRanges(testing.allocator, &wide);
    defer w.deinit(testing.allocator);
    const wn = setNode(w);
    const wplus: hir.Node = .{ .repeat = .{ .min = 1, .max = null, .policy = .greedy, .syntax_form = .plus, .body = &wn } };
    try testing.expectEqual(.first, try kindOf(&scope(.{}, &wplus)));
}

test "first: nullable patterns and non-ASCII members" {
    const a = lit("a");
    const b = lit("b");
    const alt: hir.Node = .{ .alt = &.{ &a, &b } };
    const p = try compile(testing.allocator, &scope(.{}, &alt));
    defer p.deinit(testing.allocator);
    const f = p.prefilter.kind.first;
    try testing.expect(f.utf8['a'] and f.utf8['b'] and !f.utf8['c'] and !f.utf8[0xC3]);
    try testing.expectEqual(@as(?u8, null), f.single8);
    // A nullable pattern can match anywhere: no table.
    const opt: hir.Node = .{ .repeat = .{ .min = 0, .max = 1, .policy = .greedy, .syntax_form = .question, .body = &a } };
    try testing.expectEqual(.none, try kindOf(&scope(.{}, &opt)));
    // `\bé`: asserts pass through; é marks every byte >= 0x80, and 0xE9
    // for UTF-16.
    const wb: hir.Node = .{ .assert = .word_boundary };
    const e: hir.Node = .{ .literal = .{ .units = &.{ .{ .value = 0xE9 }, .{ .value = 'x' } } } };
    const seq: hir.Node = .{ .seq = &.{ &wb, &e } };
    const q = try compile(testing.allocator, &scope(.{}, &seq));
    defer q.deinit(testing.allocator);
    const g = q.prefilter.kind.first;
    try testing.expect(g.utf8[0x80] and g.utf8[0xFF] and !g.utf8['x']);
    try testing.expectEqual(@as(?u8, 0xE9), g.single16);
}

test "anchored: ^ without m, not with m or in one alternative" {
    const caret: hir.Node = .{ .assert = .caret };
    const a = lit("ab");
    const seq: hir.Node = .{ .seq = &.{ &caret, &a } };
    const p = try compile(testing.allocator, &scope(.{}, &seq));
    defer p.deinit(testing.allocator);
    try testing.expect(p.prefilter.anchored);
    const m = try compile(testing.allocator, &scope(.{ .multiline = true }, &seq));
    defer m.deinit(testing.allocator);
    try testing.expect(!m.prefilter.anchored);
    const alt: hir.Node = .{ .alt = &.{ &seq, &a } };
    const x = try compile(testing.allocator, &scope(.{}, &alt));
    defer x.deinit(testing.allocator);
    try testing.expect(!x.prefilter.anchored);
}

test "firstOf: the DFS stack holds a closure n + 1 deep (regression, F4b(1))" {
    // n splits, each `x` and `y` the next one, the last one pointing back
    // to pc 0: visiting pc k pops one entry and pushes two, so the last
    // split (k = n - 1) writes entries n - 1 and n: n + 1 entries. With the
    // stack sized `scan` this indexed past its end at n = scan (a safety
    // panic). Nothing consumes, so the table comes out empty. Every
    // instruction must be a split, hence the last one points back (pc 0,
    // already seen) to stay in bounds: ending the chain in a `char` leaves
    // n - 1 splits, a peak of n entries, and doesn't reproduce the bug.
    const scan = 64;
    var insts: [scan]program.Inst = undefined;
    for (&insts, 0..) |*inst, k| {
        const next: u32 = if (k + 1 < scan) @intCast(k + 1) else 0;
        inst.* = .{ .split = .{ .x = next, .y = next } };
    }
    const p: Program = .{ .insts = &insts, .sets = &.{} };
    const f = firstOfWith(&p, scan).?;
    try testing.expectEqual(@as(?u8, null), f.single8);
    for (f.utf8) |on| try testing.expect(!on);
}

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
    ascii: [2]u64,
    min: u1,

    pub inline fn has(self: ClassRun, c: u32) bool {
        return c < 128 and self.ascii[c / 64] & (@as(u64, 1) << @intCast(c % 64)) != 0;
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
    var run: ClassRun = .{ .ascii = .{ 0, 0 }, .min = @intCast(r.min) };
    for (ranges) |range| {
        var c = range.lo;
        while (c <= range.hi) : (c += 1) run.ascii[c / 64] |= @as(u64, 1) << @intCast(c % 64);
    }
    return run;
}

/// The units a match can start with, or null when a match can be empty
/// (the closure from pc 0 reaches `match`) or can start anywhere.
fn firstOf(prog: *const Program) ?First {
    var f: First = .{ .utf8 = @splat(false), .utf16 = @splat(false), .high = false, .single8 = null, .single16 = null };
    // Depth-first over the epsilon closure of pc 0, asserts passed over.
    var seen = std.StaticBitSet(max_scan).initEmpty();
    var stack: [max_scan]u32 = undefined;
    var sp: usize = 0;
    if (prog.insts.len > max_scan) return null;
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
            .assert => {
                stack[sp] = pc + 1;
                sp += 1;
            },
            .char => |c| mark(&f, c, c),
            .set => |i| for (prog.sets[i].set.ranges) |r| mark(&f, r.lo, r.hi),
        }
    }
    var n8: usize = 0;
    for (f.utf8, 0..) |on, b| if (on) {
        n8 += 1;
        f.single8 = @intCast(b);
    };
    if (n8 != 1) f.single8 = null;
    var n16: usize = 0;
    for (f.utf16, 0..) |on, u| if (on) {
        n16 += 1;
        f.single16 = @intCast(u);
    };
    if (n16 != 1 or f.high) f.single16 = null;
    // Everything possible: nothing to skip.
    if (n8 == 256) return null;
    return f;
}

/// Programs above this size get no `first` table (the scan's stack and
/// visited set are fixed-size); they still run, on the plain VM.
const max_scan = 4096;

fn mark(f: *First, lo: u32, hi: u32) void {
    var c = lo;
    while (c <= @min(hi, 0x7F)) : (c += 1) f.utf8[c] = true;
    if (hi >= 0x80) @memset(f.utf8[0x80..], true);
    c = lo;
    while (c <= @min(hi, 0xFF)) : (c += 1) f.utf16[c] = true;
    if (hi >= 0x100) f.high = true;
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

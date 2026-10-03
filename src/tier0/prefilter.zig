//! T0's prefilters and fast paths (docs/REGEX_TIERS_PLAN.md, F4a D7),
//! computed once at compile time and stored in `Program.prefilter`.
//!
//! Each one is exact: it gives the result the VM gives without it (the
//! corpus differential compares the two). They apply only in code-unit mode
//! (without `u`/`v`, which is all of T0 in F4a); in code-point mode the
//! search runs the plain VM.
//!
//! **Invariant: the fast paths (`literal`, `class_run`, `shift_and`) and the `first`
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
//! - `shift_and`: the program is a straight line of 1 to 64 ASCII
//!   chars/sets (groups allowed): Shift-And, one `u64` of state
//!   (`shiftand.zig`, docs/plans/T0-CB.md C).
//! - `first`: the units a match can start with, to skip positions where
//!   none can (only while no thread is alive). See `First`.
//! - `inner`: a required ASCII character that nothing before it in a match
//!   can be: find it, back up over the run before it, and run the VM from
//!   there (only while no thread is alive). See `Inner` (docs/plans/T0-CB.md
//!   B).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir");
const hir = ir.hir;
const program = @import("program.zig");
const Program = program.Program;
const Inst = program.Inst;
const shiftand = @import("shiftand.zig");

pub const Prefilter = struct {
    /// Every match starts at text position 0.
    anchored: bool = false,
    kind: Kind = .none,

    pub const Kind = union(enum) {
        none,
        literal: Literal,
        class_run: ClassRun,
        shift_and: shiftand.ShiftAnd,
        first: First,
        inner: Inner,
    };

    pub fn deinit(self: Prefilter, gpa: Allocator) void {
        switch (self.kind) {
            .literal => |l| {
                gpa.free(l.utf8);
                gpa.free(l.utf16);
            },
            .shift_and => |sa| sa.deinit(gpa),
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
    } else if (try shiftand.of(gpa, prog)) |sa| {
        pf.kind = .{ .shift_and = sa };
    } else {
        const first = firstOf(prog);
        // A single first byte is already a memchr at every start; B would
        // search for a more common byte (`(Mr|Mrs|Miss)\.? ([A-Z]...` would
        // take the space: 4x slower in the precheck).
        const single = if (first) |f| f.single8 != null else false;
        if (!pf.anchored and !single) {
            if (try innerOf(gpa, prog)) |n| {
                pf.kind = .{ .inner = n };
                return pf;
            }
        }
        if (first) |f| pf.kind = .{ .first = f };
    }
    return pf;
}

/// Whether a program with this prefilter gets a DFA (T0-A): not when a
/// fast path serves it whole (`literal`, `class_run`, `shift_and` run
/// before the DFA). An anchored one does (A phase 2): its search is the
/// forward DFA at index 0. Code-unit mode only: a `u`/`v` program has no
/// prefilters and gets a DFA when eligible (A phase 3).
pub fn wantsDfa(pf: *const Prefilter) bool {
    return switch (pf.kind) {
        .literal, .class_run, .shift_and => false,
        .first, .inner, .none => true,
    };
}

/// The skip the DFA uses in its unanchored start state: `inner` always;
/// `first` only when it admits few units (at most `selective_first` bytes
/// of 256 in WTF-8, no unit from 256 up in UTF-16), since on a text where
/// most units can start a match it only adds a test per position.
pub const DfaSkip = enum { none, first, inner };

pub const selective_first = 32;

pub fn dfaSkip(pf: *const Prefilter) DfaSkip {
    return switch (pf.kind) {
        .inner => .inner,
        .first => |*f| blk: {
            var n: usize = 0;
            for (f.utf8) |b| n += @intFromBool(b);
            break :blk if (n <= selective_first and !f.high) .first else .none;
        },
        else => .none,
    };
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
    expand(utf8, &f.utf8);
    expand(utf16, &f.utf16);
    if (utf8.count() == 1) f.single8 = @intCast(utf8.findFirstSet().?);
    if (utf16.count() == 1 and !high) f.single16 = @intCast(utf16.findFirstSet().?);
    return f;
}

const Bits = std.StaticBitSet(256);

/// A required inner character (B): `unit`, ASCII, is on every path from pc
/// 0 to `match`, and no `char`/`set` reachable from pc 0 without passing it
/// accepts `unit`. So in any match, the units before its first `unit` are
/// all members of the prefix class `back`, and `unit` is not one.
///
/// **The skip** (`pikevm`, while no thread is alive): the first `unit` at
/// `p >= pos`, then back over `back` members down to `s >= pos`. No match
/// starts in `[pos, s)`: a match from `t` in there would have its first
/// `unit` at `p' >= p`; `p' > p` puts `p` (not in `back`) inside its prefix,
/// and `p' = p` puts `t` in the run, so `t >= s`. The VM then runs from `s`
/// as always, so it finds the leftmost-first match from `pos`.
///
/// **Minimum prefix.** Every match consumes at least `min_prefix` units
/// before its first `unit`: a run `[s, p)` shorter than that has no match
/// through `p`, and the skip goes on to the next `unit`.
///
/// **Linear.** Each back-up stops at the `unit` before (not in `back`), so
/// the back-ups are disjoint; the found `p` and `s` are kept while `p >= pos`.
///
/// `back` is conservative like `First`: in WTF-8 a member from U+0080 up
/// marks every byte from 0x80 up, so the back-up stops right after an ASCII
/// byte or at `pos`, both positions.
pub const Inner = struct {
    unit: u8,
    min_prefix: u32,
    back8: [256]bool,
    back16: [256]bool,
    high: bool,

    pub inline fn inBack(self: *const Inner, comptime Unit: type, u: Unit) bool {
        return if (Unit == u8) self.back8[u] else if (u < 256) self.back16[u] else self.high;
    }
};

/// Candidates tried (in pc order) before giving up: each costs a walk of the
/// program.
const max_inner_candidates = 32;

/// A coarse guess at how common a byte is in text, lower is rarer: control
/// characters, then uncommon punctuation, then digits, capitals and common
/// punctuation, then lower-case letters, then the space. Not measured on a
/// corpus: it only has to put `@`, `#` or `=` before `e` or ` `.
fn commonness(c: u8) u8 {
    return switch (c) {
        ' ' => 4,
        'a'...'z' => 3,
        '0'...'9', 'A'...'Z', '\t', '\n', '\r', '.', ',', '-', '\'', '"', '/', ':', '(', ')', '_' => 2,
        '!', '#'...'&', '*', '+', ';'...'@', '['...'^', '`', '{'...'~' => 1,
        else => 0,
    };
}

/// The rarest required inner character of `prog` (earliest pc on ties).
fn innerOf(gpa: Allocator, prog: *const Program) Allocator.Error!?Inner {
    if (prog.insts.len > max_scan) return null;
    var best: ?Inner = null;
    var best_pc: u32 = 0;
    var tried: usize = 0;
    for (prog.insts, 0..) |inst, pc| {
        if (inst != .char or inst.char >= 0x80) continue;
        if (best) |b| if (commonness(@intCast(inst.char)) >= commonness(b.unit)) continue;
        if (tried == max_inner_candidates) break;
        tried += 1;
        if (innerAt(prog, @intCast(pc))) |n| {
            best = n;
            best_pc = @intCast(pc);
        }
    }
    var n = best orelse return null;
    n.min_prefix = try minPrefix(gpa, prog, best_pc);
    return n;
}

/// `Inner` for the `char` at `l`, or null when `l` isn't required, a unit
/// before it can be its character, or nothing is consumed before it.
/// `min_prefix` is left 0 (`minPrefix` fills it).
fn innerAt(prog: *const Program, l: u32) ?Inner {
    const c = prog.insts[l].char;
    var utf8 = Bits.initEmpty();
    var utf16 = Bits.initEmpty();
    var high = false;
    var consumes = false;
    var seen = std.StaticBitSet(max_scan).initEmpty();
    var stack: [2 * max_scan + 1]u32 = undefined;
    stack[0] = 0;
    var sp: usize = 1;
    while (sp != 0) {
        sp -= 1;
        const pc = stack[sp];
        if (pc == l or seen.isSet(pc)) continue;
        seen.set(pc);
        switch (prog.insts[pc]) {
            // A path to `match` that avoids `l`: not required.
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
            .char => |x| {
                if (x == c) return null;
                mark(&utf8, &utf16, &high, x, x);
                consumes = true;
                stack[sp] = pc + 1;
                sp += 1;
            },
            .set => |i| {
                if (prog.sets[i].contains(c)) return null;
                for (prog.sets[i].set.ranges) |r| mark(&utf8, &utf16, &high, r.lo, r.hi);
                consumes = true;
                stack[sp] = pc + 1;
                sp += 1;
            },
        }
    }
    if (!consumes) return null;
    var n: Inner = .{ .unit = @intCast(c), .min_prefix = 0, .back8 = undefined, .back16 = undefined, .high = high };
    expand(utf8, &n.back8);
    expand(utf16, &n.back16);
    return n;
}

/// The fewest units any path from pc 0 consumes before reaching `l`: a 0-1
/// breadth-first search (a `char`/`set` edge costs 1, the rest 0).
fn minPrefix(gpa: Allocator, prog: *const Program, l: u32) Allocator.Error!u32 {
    const n = prog.insts.len;
    const none = std.math.maxInt(u32);
    const dist = try gpa.alloc(u32, n);
    defer gpa.free(dist);
    @memset(dist, none);
    const done = try gpa.alloc(bool, n);
    defer gpa.free(done);
    @memset(done, false);
    // A deque: 0-cost edges push at the front, 1-cost at the back. A pc's
    // first pop is final and only then are its (at most two) edges relaxed,
    // so there are at most 2n + 1 pushes: 2n + 1 slots on each side.
    const dq = try gpa.alloc(u32, 4 * n + 2);
    defer gpa.free(dq);
    var head: usize = 2 * n + 1;
    var tail: usize = head;
    dist[0] = 0;
    dq[tail] = 0;
    tail += 1;
    while (head != tail) {
        const pc = dq[head];
        head += 1;
        if (done[pc]) continue;
        done[pc] = true;
        if (pc == l) return dist[pc];
        const d = dist[pc];
        var to: [2]u32 = undefined;
        var k: usize = 0;
        var w: u32 = 0;
        switch (prog.insts[pc]) {
            .jmp => |t| {
                to[0] = t;
                k = 1;
            },
            .split => |s| {
                to = .{ s.x, s.y };
                k = 2;
            },
            .assert, .save, .clear => {
                to[0] = pc + 1;
                k = 1;
            },
            .char, .set => {
                to[0] = pc + 1;
                k = 1;
                w = 1;
            },
            .fail, .match => {},
        }
        for (to[0..k]) |t| if (d + w < dist[t]) {
            dist[t] = d + w;
            if (w == 0) {
                head -= 1;
                dq[head] = t;
            } else {
                dq[tail] = t;
                tail += 1;
            }
        };
    }
    return dist[l];
}

/// `bits` as a lookup table, eight entries at a time (a bit per `isSet`
/// was most of the prefilter's compile cost; F7b(6)). Each byte of the
/// masks is spread to eight 0/1 bytes: replicate it, keep bit i in byte
/// i, then carry any set bit into bit 7 and shift it down to bit 0.
fn expand(bits: Bits, out: *[256]bool) void {
    comptime std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
    const bytes = std.mem.asBytes(out);
    for (std.mem.asBytes(&bits.masks), 0..) |b, k| {
        const kept = (@as(u64, b) *% 0x0101010101010101) & 0x8040201008040201;
        const one = ((kept +% 0x7F7F7F7F7F7F7F7F) >> 7) & 0x0101010101010101;
        std.mem.writeInt(u64, bytes[8 * k ..][0..8], one, .little);
    }
}

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

/// The literal fast path's search: the first occurrence of `needle` in
/// `haystack` at `start` or after, with `std.mem.indexOfPos`'s contract.
/// A needle of 2+ units runs a SIMD pairwise search (memchr::memmem's
/// scheme, with the needle's first and last units as the pair): W units at
/// a time are compared with both, the masks are ANDed and each candidate is
/// verified. W is the target's suggested vector length, chosen at compile
/// time; a target without one keeps `std.mem.indexOfPos` (scalar
/// Boyer-Moore-Horspool, which it replaces: ~0.9 GB/s against ~15-20 GB/s
/// on AVX2 for "hello" and "Darcy").
pub fn findLiteral(comptime Unit: type, haystack: []const Unit, start: usize, needle: []const Unit) ?usize {
    const w: ?usize = comptime if (std.simd.suggestVectorLength(Unit)) |v| v else null;
    return findLiteralWith(Unit, w, haystack, start, needle);
}

/// `findLiteral` with the vector length given: null is the scalar path
/// (`std.mem.indexOfPos`), for targets without SIMD and for its test.
pub fn findLiteralWith(comptime Unit: type, comptime W: ?usize, haystack: []const Unit, start: usize, needle: []const Unit) ?usize {
    const n = needle.len;
    if (n == 0) return start; // as std.mem.indexOfPos, even past the end
    if (n == 1) return std.mem.indexOfScalarPos(Unit, haystack, start, needle[0]);
    const w = W orelse return std.mem.indexOfPos(Unit, haystack, start, needle);
    const len = haystack.len;
    if (start > len or n > len - start) return null;
    const V = @Vector(w, Unit);
    const Mask = std.meta.Int(.unsigned, w);
    const first: V = @splat(needle[0]);
    const last: V = @splat(needle[n - 1]);
    var i = start;
    // Candidates i..i+w-1: their first units at i.., their last at i+n-1..;
    // both loads fit while i + (w + n - 2) < len.
    while (i + (w + n - 2) < len) : (i += w) {
        const a: V = haystack[i..][0..w].*;
        const b: V = haystack[i + n - 1 ..][0..w].*;
        var m: Mask = @bitCast((a == first) & (b == last));
        while (m != 0) {
            const at = i + @ctz(m);
            if (std.mem.eql(Unit, haystack[at + 1 ..][0 .. n - 2], needle[1 .. n - 1])) return at;
            m &= m - 1;
        }
    }
    // The tail, fewer than w candidates: scalar.
    while (i + n <= len) : (i += 1) {
        if (haystack[i] == needle[0] and haystack[i + n - 1] == needle[n - 1] and
            std.mem.eql(Unit, haystack[i + 1 ..][0 .. n - 2], needle[1 .. n - 1])) return i;
    }
    return null;
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
    // `i` on a letter: not a byte search; a straight line of ASCII sets,
    // so Shift-And (C).
    try testing.expectEqual(.shift_and, try kindOf(&scope(.{ .ignore_case = true }, &abc)));
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
    // `\bé[xy]`: asserts pass through; é marks every byte >= 0x80, and
    // 0xE9 for UTF-16. (`\béx` would take B, on the `x`.)
    const wb: hir.Node = .{ .assert = .word_boundary };
    const e: hir.Node = .{ .literal = .{ .units = &.{.{ .value = 0xE9 }} } };
    const xy = setNode(.{ .ranges = &.{.{ .lo = 'x', .hi = 'y' }} });
    const seq: hir.Node = .{ .seq = &.{ &wb, &e, &xy } };
    const q = try compile(testing.allocator, &scope(.{}, &seq));
    defer q.deinit(testing.allocator);
    const g = q.prefilter.kind.first;
    try testing.expect(g.utf8[0x80] and g.utf8[0xFF] and !g.utf8['x']);
    try testing.expectEqual(@as(?u8, 0xE9), g.single16);
}

fn innerOfRoot(root: *const hir.Node) !?Inner {
    const p = try compile(testing.allocator, root);
    defer p.deinit(testing.allocator);
    return if (p.prefilter.kind == .inner) p.prefilter.kind.inner else null;
}

const lower_set: CharSet = .{ .ranges = &.{.{ .lo = 'a', .hi = 'z' }} };

fn plusOf(b: *const hir.Node) hir.Node {
    return .{ .repeat = .{ .min = 1, .max = null, .policy = .greedy, .syntax_form = .plus, .body = b } };
}

test "inner: a required character nothing before it can be" {
    const l = setNode(lower_set);
    const word = plusOf(&l);
    const at = lit("@");
    const seq: hir.Node = .{ .seq = &.{ &word, &at, &word } };
    const n = (try innerOfRoot(&scope(.{}, &seq))).?;
    try testing.expectEqual(@as(u8, '@'), n.unit);
    try testing.expectEqual(@as(u32, 1), n.min_prefix);
    try testing.expect(n.back8['a'] and n.back8['z'] and !n.back8['@'] and !n.back8[0x80]);
    try testing.expect(n.back16['q'] and !n.back16['@'] and !n.high);
    // `\béx`: the `x`, after a prefix of é (every byte from 0x80 up).
    const wb: hir.Node = .{ .assert = .word_boundary };
    const ex: hir.Node = .{ .literal = .{ .units = &.{ .{ .value = 0xE9 }, .{ .value = 'x' } } } };
    const bex: hir.Node = .{ .seq = &.{ &wb, &ex } };
    const m = (try innerOfRoot(&scope(.{}, &bex))).?;
    try testing.expectEqual(@as(u8, 'x'), m.unit);
    try testing.expect(m.back8[0xC3] and m.back8[0xFF] and !m.back8['x'] and m.back16[0xE9]);
}

test "inner: not when avoidable, in the prefix, anchored, or after a single first byte" {
    const l = setNode(lower_set);
    const word = plusOf(&l);
    const at = lit("@");
    const hash = lit("#");
    // `[a-z]+(?:@|#)`: neither is on every path.
    const either: hir.Node = .{ .alt = &.{ &at, &hash } };
    const avoid: hir.Node = .{ .seq = &.{ &word, &either } };
    try testing.expectEqual(.first, try kindOf(&scope(.{}, &avoid)));
    // `[a-z@]+@`: the prefix can be `@`; the `x` of `[a-z@]+@x` too.
    const la = setNode(.{ .ranges = &.{ .{ .lo = '@', .hi = '@' }, .{ .lo = 'a', .hi = 'z' } } });
    const word_at = plusOf(&la);
    const x = lit("x");
    const in_prefix: hir.Node = .{ .seq = &.{ &word_at, &at, &x } };
    try testing.expectEqual(.first, try kindOf(&scope(.{}, &in_prefix)));
    // `^[a-z]+@`: anchored, only position 0 is tried anyway.
    const caret: hir.Node = .{ .assert = .caret };
    const anchored: hir.Node = .{ .seq = &.{ &caret, &word, &at } };
    try testing.expectEqual(.first, try kindOf(&scope(.{}, &anchored)));
    // `a[a-z]*@`: `first` is the single byte `a`, a memchr already.
    const a = lit("a");
    const star: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &l } };
    const single: hir.Node = .{ .seq = &.{ &a, &star, &at } };
    try testing.expectEqual(.first, try kindOf(&scope(.{}, &single)));
    // `@[a-z]+`: nothing before it, so `first` (the single byte `@`).
    const lead: hir.Node = .{ .seq = &.{ &at, &word } };
    try testing.expectEqual(.first, try kindOf(&scope(.{}, &lead)));
}

test "inner: the rarest candidate, and the minimum prefix" {
    const l = setNode(lower_set);
    const word = plusOf(&l);
    // `[a-z]+ =[a-z]`: both ` ` and `=` qualify; `=` is rarer.
    const sp_eq = lit(" =");
    const seq: hir.Node = .{ .seq = &.{ &word, &sp_eq, &l } };
    const n = (try innerOfRoot(&scope(.{}, &seq))).?;
    try testing.expectEqual(@as(u8, '='), n.unit);
    try testing.expectEqual(@as(u32, 2), n.min_prefix);
    try testing.expect(n.back8[' '] and n.back8['k']);
    // `[a-z]{3}\d*@`: three units at least; `\d*` adds none.
    const three: hir.Node = .{ .repeat = .{ .min = 3, .max = 3, .policy = .greedy, .syntax_form = .counted, .body = &l } };
    const d = setNode(.{ .ranges = &.{.{ .lo = '0', .hi = '9' }} });
    const ds: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &d } };
    const at = lit("@");
    const min3: hir.Node = .{ .seq = &.{ &three, &ds, &at, &l } };
    try testing.expectEqual(@as(u32, 3), (try innerOfRoot(&scope(.{}, &min3))).?.min_prefix);
    // `(?:ab|c)@`: the shorter branch decides.
    const ab = lit("ab");
    const c = lit("c");
    const alt: hir.Node = .{ .alt = &.{ &ab, &c } };
    const alt_at: hir.Node = .{ .seq = &.{ &alt, &at, &l } };
    try testing.expectEqual(@as(u32, 1), (try innerOfRoot(&scope(.{}, &alt_at))).?.min_prefix);
    // `[a-z]*@`: a nullable prefix, 0.
    const star: hir.Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &l } };
    const nul: hir.Node = .{ .seq = &.{ &star, &at, &l } };
    try testing.expectEqual(@as(u32, 0), (try innerOfRoot(&scope(.{}, &nul))).?.min_prefix);
}

test "inner: compile doesn't leak on allocation failure" {
    const l = setNode(lower_set);
    const word = plusOf(&l);
    const at = lit("@");
    const seq: hir.Node = .{ .seq = &.{ &word, &at, &word } };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(gpa: Allocator, root: *const hir.Node) !void {
            const p = compile(gpa, root) catch |err| switch (err) {
                error.Ineligible => unreachable,
                else => |e| return e,
            };
            try testing.expect(p.prefilter.kind == .inner);
            p.deinit(gpa);
        }
    }.f, .{&seq});
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

// findLiteral: every result checked against std.mem.indexOfPos, for the
// vector lengths of the targets (8-64 units) and the scalar path (null).

const widths = [_]?usize{ null, 8, 16, 32, 64 };

fn expectSame(comptime Unit: type, h: []const Unit, start: usize, n: []const Unit) !void {
    const want = std.mem.indexOfPos(Unit, h, start, n);
    inline for (widths) |w| {
        const got = findLiteralWith(Unit, w, h, start, n);
        testing.expectEqual(want, got) catch |err| {
            std.debug.print("W={any} len={d} start={d} needle.len={d}\n", .{ w, h.len, start, n.len });
            return err;
        };
    }
    try testing.expectEqual(want, findLiteral(Unit, h, start, n));
}

test "findLiteral: fixed edge cases, against std.mem.indexOfPos" {
    // Empty needle: `start`, even past the end (std's contract).
    try expectSame(u8, "abc", 0, "");
    try expectSame(u8, "abc", 3, "");
    try expectSame(u8, "abc", 5, "");
    try testing.expectEqual(@as(?usize, 5), findLiteral(u8, "abc", 5, ""));
    // One unit: std's SIMD scalar search.
    try expectSame(u8, "abcabc", 1, "a");
    try expectSame(u8, "abc", 4, "a");
    // Overlapping repeats: the first occurrence.
    try expectSame(u8, "aaaa", 0, "aa");
    try expectSame(u8, "aaaa", 1, "aa");
    try expectSame(u8, "aaaa", 3, "aa");
    // Needle equal to, and longer than, the haystack; start at and past the end.
    try expectSame(u8, "hello", 0, "hello");
    try expectSame(u8, "hell", 0, "hello");
    try expectSame(u8, "hello", 5, "lo");
    try expectSame(u8, "hello", 6, "lo");
    // Multibyte literals in WTF-8, and the same text in UTF-16.
    const text = "x\u{E9}\u{20AC}y\u{E9}\u{20AC}" ** 20;
    try expectSame(u8, text, 0, "\u{E9}\u{20AC}");
    try expectSame(u8, text, 4, "\u{E9}\u{20AC}");
    const t16 = std.unicode.utf8ToUtf16LeStringLiteral(text);
    const n16 = std.unicode.utf8ToUtf16LeStringLiteral("\u{E9}\u{20AC}");
    for (0..t16.len + 1) |start| try expectSame(u16, t16, start, n16);
}

test "findLiteral: a needle as long as the vector or longer" {
    // n >= W: both loads (at i and i + n - 1) still fit while the haystack
    // is long enough; the rest is the scalar tail.
    var h: [100]u8 = undefined;
    for (&h, 0..) |*c, k| c.* = "abcdefgh"[k % 8];
    const needle = h[40..72]; // 32 units
    for (0..h.len + 1) |start| try expectSame(u8, &h, start, needle);
    try expectSame(u8, &h, 0, h[0..70]);
    try expectSame(u8, &h, 0, h[30..100]);
}

test "findLiteral: random, small alphabet, across vector boundaries" {
    var prng = std.Random.DefaultPrng.init(0xF1AD);
    const r = prng.random();
    var buf8: [300]u8 = undefined;
    var buf16: [300]u16 = undefined;
    // Haystack lengths around multiples of 8, 16, 32 and 64, and others.
    const lens = [_]usize{ 0, 1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 47, 63, 64, 65, 95, 127, 128, 129, 191, 255, 256, 257, 300 };
    var checks: usize = 0;
    for (lens) |len| {
        for (0..12) |_| {
            // {a, b}: many false candidates (both pair units often match).
            for (buf8[0..len], buf16[0..len]) |*c8, *c16| {
                c8.* = if (r.boolean()) 'a' else 'b';
                c16.* = c8.*;
            }
            const n = 2 + r.uintLessThan(usize, 69); // 2..70
            if (n > len) continue;
            // The needle: a slice of the haystack (so it occurs), sometimes
            // with its last unit changed (so it may not).
            const from = r.uintLessThan(usize, len - n + 1);
            var needle8: [70]u8 = undefined;
            var needle16: [70]u16 = undefined;
            @memcpy(needle8[0..n], buf8[from..][0..n]);
            if (r.uintLessThan(u8, 4) == 0) needle8[n - 1] = 'c';
            for (needle8[0..n], needle16[0..n]) |c8, *c16| c16.* = c8;
            // Every start: the beginning, mid-vector, the end, past it.
            var start: usize = 0;
            while (start <= len + 1) : (start += 1 + r.uintLessThan(usize, 5)) {
                try expectSame(u8, buf8[0..len], start, needle8[0..n]);
                try expectSame(u16, buf16[0..len], start, needle16[0..n]);
                checks += 2;
            }
        }
    }
    try testing.expect(checks > 2000);
}

test "findLiteral: the needle planted at the start, the end, and across a vector edge" {
    var h: [200]u8 = undefined;
    @memset(&h, 'x');
    const needle = "Darcy";
    for ([_]usize{ 0, 1, 14, 15, 16, 28, 29, 30, 31, 32, 60, 61, 62, 63, 64, 195 }) |at| {
        @memset(&h, 'x');
        @memcpy(h[at..][0..needle.len], needle);
        try expectSame(u8, &h, 0, needle);
        try expectSame(u8, &h, at, needle);
        if (at > 0) try expectSame(u8, &h, at - 1, needle);
        try expectSame(u8, &h, at + 1, needle);
        try testing.expectEqual(@as(?usize, at), findLiteral(u8, &h, 0, needle));
    }
}

test "expand gives the table isSet gives (F7b(6))" {
    var prng = std.Random.DefaultPrng.init(0x7b6);
    const rnd = prng.random();
    for (0..64) |_| {
        var bits = Bits.initEmpty();
        for (0..rnd.uintLessThan(usize, 256)) |_| bits.set(rnd.int(u8));
        var table: [256]bool = undefined;
        expand(bits, &table);
        for (table, 0..) |t, i| try std.testing.expectEqual(bits.isSet(i), t);
    }
}

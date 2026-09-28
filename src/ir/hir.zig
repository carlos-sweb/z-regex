//! HIR: the high-level intermediate representation (docs/REGEX_TIERS_PLAN.md,
//! F2c). The parser's AST is lowered into it (`src/frontend/lower/lower.zig`) and the
//! code generator reads only the HIR.
//!
//! The tree lives in one arena per compilation and holds no pointer into the
//! AST: every node is plain data (scalars, slices it owns, CharSets), so the
//! AST, the HIR and the parser can all be freed when `compile()` returns.
//!
//! Faithful, not canonical. Until the backtracker is replaced (F6a) its
//! bytecode, and in two places its semantics, depend on how a construct was
//! written, not only on what it means. Two fields carry that, and they are
//! different in kind:
//! - `CharSet.encoding_hint` is COSMETIC: it only picks the bytecode
//!   encoding. What a CharSet matches is always `set`.
//! - `Repeat.syntax_form` is SEMANTIC: `a?` clears inner captures when it
//!   skips, `a{0,1}` doesn't. Dropping it changes behavior.
//! T0/T1 (F4a on) generate their own programs from the HIR and read neither;
//! both die with the current backtracker's code generator in F6a.
//!
//! Flags are lexical (option (b) of the F2 plan): `i`/`m`/`s` live only in
//! `ModifierScope` nodes and every node takes those of its nearest enclosing
//! scope. F2c only produces the root scope (from `CompileOptions`). Where each
//! flag is consumed:
//! - `i`: by the lowering for classes (a CharSet's `set` is already folded)
//!   and by the code generator for `Literal` and `Backref`;
//! - `m`: by the code generator, for `^`/`$`;
//! - `s`: by the lowering, for `.` (its `set`; `encoding_hint.dot` records it).
//!
//! Part of `ir/`, shared across Tiers from F2e: no `unicode/` import.

const std = @import("std");
const charset_mod = @import("charset.zig");

pub const CharSet = charset_mod.CharSet;

pub const Flags = struct {
    /// `i`: case-insensitive.
    ignore_case: bool = false,
    /// `m`: `^`/`$` also match at line boundaries.
    multiline: bool = false,
    /// `s`: `.` also matches line terminators.
    dot_all: bool = false,
};

/// One unit of a `Literal`.
pub const LitUnit = struct {
    /// A code point, or a byte when `raw_byte`.
    value: u32,
    /// SEMANTIC. A lone byte 0x80-0xFF from the pattern (invalid UTF-8, or
    /// the lead byte of `\` + a non-ASCII character), matched as that single
    /// byte rather than as the code point U+0080-U+00FF. Pre-existing lexer
    /// behavior, kept as is (F3's Subject work revisits it).
    raw_byte: bool = false,
};

/// A run of literal characters. The code generator emits one CHAR32 per
/// byte-level unit, exactly as before F2c: a code point <= 0x7F (or a raw
/// byte) as one CHAR32 (a SPLIT of both ASCII cases under `i`), a code point
/// above 0x7F as its WTF-8 bytes (a SPLIT with its simple case-fold pair under
/// `i`). Do NOT merge the units into a literal-string instruction: that would
/// change the bytecode and break the snapshot (tests/snapshots/bytecode.txt);
/// a literal opcode is F4a's, for T0's own program.
pub const Literal = struct {
    units: []const LitUnit,
};

/// How the current backtracker's bytecode encodes a CharSet. COSMETIC: it
/// changes bytes, never what matches -- that is always `CharSetNode.set`.
pub const EncodingHint = union(enum) {
    /// CHAR_SET(_INV) over the program's CharSet table.
    set,
    /// CHAR_CLASS(_INV): a 256-bit table of the (ASCII) members.
    bitmap,
    /// CHAR_RANGE(_INV) over a byte range (`\d`, `\D`, a lone `[a-z]`); a
    /// bitmap instead under `i`, as before F2c.
    byte_range: struct { lo: u8, hi: u8 },
    /// UNICODE_PROPERTY/_SCRIPT/_SCRIPT_EXTENSIONS(_INV) for a standalone
    /// `\p{...}`: `kind` 0/1/2 as in those opcodes' families, `value` the
    /// property ordinal or script index.
    property: struct { kind: PropertyKind, value: u8 },
    /// CHAR (`.`) or CHAR_ANY (`.` under `s`).
    dot: struct { dot_all: bool },
};

pub const PropertyKind = enum(u8) { general_category = 0, script = 1, script_extensions = 2 };

pub const CharSetNode = struct {
    /// What this node matches (one code point, decoded as the matcher does):
    /// members, then the fold `i` implies on this node's path, then negation.
    /// The only field T0/T1 read. Arena-owned, or a view of a static
    /// Unicode table (`CharSet.borrowed`): never freed on its own.
    set: CharSet,
    /// The opcode's `_INV` form, for the bytecode encoding: the code
    /// generator encodes `complement(set)` then (the double complement is
    /// exact, so the table entry is the same as before F2c). COSMETIC.
    inverted: bool,
    encoding_hint: EncodingHint,
    /// For `analyze()` only (F2d); neither matching nor the bytecode
    /// encoding reads it.
    analysis_origin: AnalysisOrigin = .{},
};

/// Where a CharSet came from, as far as the Tier classifier needs and the
/// set can't show: a `\p`/`\P` (standalone or a class member) always needs
/// the Unicode tables, even when its set is ASCII (`[\p{ASCII}]`); a `v` set
/// operation is its own feature. Scalars only, no pointer into the AST.
pub const AnalysisOrigin = packed struct {
    property: bool = false,
    set_operation: bool = false,
};

pub const Policy = enum { greedy, lazy, possessive };

/// Which quantifier syntax produced a Repeat: the backtracker's code
/// generator keeps each form's shape (`plus` and `counted` `{1,}` differ).
/// It was SEMANTIC until F7a(4): only `question` cleared the captures inside
/// its body (on skip), `counted` didn't. Since then every iteration clears
/// them at its start (RepeatMatcher step 4), so `?` and `{0,1}` match alike.
pub const SyntaxForm = enum { star, plus, question, counted };

pub const Repeat = struct {
    min: u32,
    /// null = unbounded.
    max: ?u32,
    policy: Policy,
    syntax_form: SyntaxForm,
    body: *const Node,
};

pub const Capture = struct {
    index: u16,
    /// Borrowed from the parser; valid only during `compile()`.
    name: ?[]const u8,
    body: *const Node,
};

pub const Backref = struct {
    /// One group today; a list so duplicate named groups can resolve to
    /// several later.
    indices: []const u16,
};

pub const AssertKind = enum {
    /// `^`: string start, or line start under `m`.
    caret,
    /// `$`: string end, or line end under `m`.
    dollar,
    word_boundary,
    not_word_boundary,
};

pub const Look = struct {
    behind: bool,
    negated: bool,
    body: *const Node,
};

pub const ModifierScope = struct {
    flags: Flags,
    body: *const Node,
};

pub const Node = union(enum) {
    empty,
    literal: Literal,
    char_set: CharSetNode,
    seq: []const *const Node,
    /// n-ary; the code generator emits it nested to the left, `((a|b)|c)`,
    /// as the parser's binary alternation always was.
    alt: []const *const Node,
    repeat: Repeat,
    capture: Capture,
    backref: Backref,
    assert: AssertKind,
    look: Look,
    modifier_scope: ModifierScope,
};

/// Whether `node` can match the empty string (F4a). A pure function of the
/// tree: the HIR stores no per-node attributes. Assertions, lookarounds and
/// backreferences consume nothing, so they count as nullable.
pub fn nullable(node: *const Node) bool {
    return switch (node.*) {
        .empty, .assert, .look, .backref => true,
        .literal => |l| l.units.len == 0,
        .char_set => false,
        .seq => |items| for (items) |item| {
            if (!nullable(item)) break false;
        } else true,
        .alt => |items| for (items) |item| {
            if (nullable(item)) break true;
        } else false,
        .repeat => |r| r.min == 0 or nullable(r.body),
        .capture => |c| nullable(c.body),
        .modifier_scope => |m| nullable(m.body),
    };
}

/// The number of characters every match of `node` consumes, or null when
/// it can vary (F6b step 1, B′). A character is what `char_set` and a
/// `LitUnit` consume in the pattern's mode: a code unit without `u`/`v`,
/// a code point with them (an astral literal without `u` is already two
/// units). Assertions and lookarounds consume nothing; a `repeat` is fixed
/// when `min == max`; an alternation when all its branches agree. A
/// backreference, a raw byte (one byte of WTF-8, not a character) and a
/// length past `u32` are not fixed. Captures don't change the length:
/// whether a lookbehind may hold one is `lookbehindsFixed`'s business.
pub fn fixedLength(node: *const Node) ?u32 {
    return switch (node.*) {
        .empty, .assert, .look => 0,
        .literal => |l| for (l.units) |u| {
            if (u.raw_byte) break null;
        } else std.math.cast(u32, l.units.len),
        .char_set => 1,
        .backref => null,
        .seq => |items| blk: {
            var sum: u32 = 0;
            for (items) |item| sum = std.math.add(u32, sum, fixedLength(item) orelse break :blk null) catch break :blk null;
            break :blk sum;
        },
        .alt => |items| blk: {
            var len: ?u32 = null;
            for (items) |item| {
                const l = fixedLength(item) orelse break :blk null;
                if (len != null and len.? != l) break :blk null;
                len = l;
            }
            break :blk len orelse 0;
        },
        .repeat => |r| if (r.max != null and r.max.? == r.min)
            std.math.mul(u32, r.min, fixedLength(r.body) orelse return null) catch null
        else
            null,
        .capture => |c| fixedLength(c.body),
        .modifier_scope => |m| fixedLength(m.body),
    };
}

/// Whether every lookbehind in `node`'s subtree is one the explicit-stack
/// backtracker runs (B′): a body of fixed length (`fixedLength`) with no
/// capture group inside. Such a body matched forward from `L` characters
/// back ends exactly where the lookbehind stands, and without captures the
/// direction can't show. Anything else is `error.UnsupportedFeature` until
/// F6b matches backward.
pub fn lookbehindsFixed(node: *const Node) bool {
    return switch (node.*) {
        .empty, .literal, .char_set, .backref, .assert => true,
        .seq, .alt => |items| for (items) |item| {
            if (!lookbehindsFixed(item)) break false;
        } else true,
        .repeat => |r| lookbehindsFixed(r.body),
        .capture => |c| lookbehindsFixed(c.body),
        .look => |l| (!l.behind or (fixedLength(l.body) != null and captureRange(l.body) == null)) and lookbehindsFixed(l.body),
        .modifier_scope => |m| lookbehindsFixed(m.body),
    };
}

/// The lowest and highest capture index in `node`'s subtree (the node
/// included), or null if it has none. Indices are given in order of the
/// opening parenthesis, so a subtree's groups are exactly `lo..hi` (F4b's
/// `clear`).
pub fn captureRange(node: *const Node) ?struct { lo: u16, hi: u16 } {
    var lo: u16 = std.math.maxInt(u16);
    var hi: u16 = 0;
    rangeOf(node, &lo, &hi);
    return if (lo > hi) null else .{ .lo = lo, .hi = hi };
}

fn rangeOf(node: *const Node, lo: *u16, hi: *u16) void {
    switch (node.*) {
        .empty, .literal, .char_set, .backref, .assert => {},
        .seq, .alt => |items| for (items) |item| rangeOf(item, lo, hi),
        .repeat => |r| rangeOf(r.body, lo, hi),
        .capture => |c| {
            lo.* = @min(lo.*, c.index);
            hi.* = @max(hi.*, c.index);
            rangeOf(c.body, lo, hi);
        },
        .look => |l| rangeOf(l.body, lo, hi),
        .modifier_scope => |m| rangeOf(m.body, lo, hi),
    }
}

/// Append the capture indices in `node`'s subtree (the node included), in
/// pre-order: the groups a skipped optional atom must clear.
pub fn collectCaptures(node: *const Node, list: *std.ArrayListUnmanaged(u16), allocator: std.mem.Allocator) !void {
    switch (node.*) {
        .empty, .literal, .char_set, .backref, .assert => {},
        .seq, .alt => |items| for (items) |item| try collectCaptures(item, list, allocator),
        .repeat => |r| try collectCaptures(r.body, list, allocator),
        .capture => |c| {
            try list.append(allocator, c.index);
            try collectCaptures(c.body, list, allocator);
        },
        .look => |l| try collectCaptures(l.body, list, allocator),
        .modifier_scope => |m| try collectCaptures(m.body, list, allocator),
    }
}

/// A one-line-per-node text dump, for tests and debugging.
pub fn dump(node: *const Node, w: *std.Io.Writer, indent: usize) std.Io.Writer.Error!void {
    try w.splatByteAll(' ', indent * 2);
    switch (node.*) {
        .empty => try w.writeAll("empty\n"),
        .literal => |l| {
            try w.writeAll("literal");
            for (l.units) |u| {
                if (u.raw_byte) {
                    try w.print(" byte:{X:0>2}", .{u.value});
                } else if (u.value >= 0x20 and u.value < 0x7F) {
                    try w.print(" '{c}'", .{@as(u8, @intCast(u.value))});
                } else {
                    try w.print(" U+{X:0>4}", .{u.value});
                }
            }
            try w.writeAll("\n");
        },
        .char_set => |c| {
            try w.print("char_set {s}{s}{s}{s} ranges={d}", .{ @tagName(c.encoding_hint), if (c.inverted) " inv" else "", if (c.analysis_origin.property) " +property" else "", if (c.analysis_origin.set_operation) " +set_op" else "", c.set.ranges.len });
            for (c.set.ranges[0..@min(c.set.ranges.len, 4)]) |r| try w.print(" {X}-{X}", .{ r.lo, r.hi });
            if (c.set.ranges.len > 4) try w.writeAll(" ...");
            try w.writeAll("\n");
        },
        .seq => |items| {
            try w.writeAll("seq\n");
            for (items) |item| try dump(item, w, indent + 1);
        },
        .alt => |items| {
            try w.writeAll("alt\n");
            for (items) |item| try dump(item, w, indent + 1);
        },
        .repeat => |r| {
            if (r.max) |max| {
                try w.print("repeat {s} {s} {d},{d}\n", .{ @tagName(r.syntax_form), @tagName(r.policy), r.min, max });
            } else {
                try w.print("repeat {s} {s} {d},inf\n", .{ @tagName(r.syntax_form), @tagName(r.policy), r.min });
            }
            try dump(r.body, w, indent + 1);
        },
        .capture => |c| {
            try w.print("capture {d}{s}{s}\n", .{ c.index, if (c.name != null) " " else "", c.name orelse "" });
            try dump(c.body, w, indent + 1);
        },
        .backref => |b| {
            try w.writeAll("backref");
            for (b.indices) |i| try w.print(" {d}", .{i});
            try w.writeAll("\n");
        },
        .assert => |a| try w.print("assert {s}\n", .{@tagName(a)}),
        .look => |l| {
            try w.print("look {s}{s}\n", .{ if (l.behind) "behind" else "ahead", if (l.negated) " negated" else "" });
            try dump(l.body, w, indent + 1);
        },
        .modifier_scope => |m| {
            try w.print("scope{s}{s}{s}\n", .{ if (m.flags.ignore_case) " i" else "", if (m.flags.multiline) " m" else "", if (m.flags.dot_all) " s" else "" });
            try dump(m.body, w, indent + 1);
        },
    }
}

// =============================================================================
// Tests
// =============================================================================

test "hir: collectCaptures is pre-order over the whole subtree" {
    const a = std.testing.allocator;
    const empty: Node = .empty;
    const c3: Node = .{ .capture = .{ .index = 3, .name = null, .body = &empty } };
    const look: Node = .{ .look = .{ .behind = false, .negated = false, .body = &c3 } };
    const c2: Node = .{ .capture = .{ .index = 2, .name = "x", .body = &look } };
    const rep: Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &c2 } };
    const c1: Node = .{ .capture = .{ .index = 1, .name = null, .body = &empty } };
    const items = [_]*const Node{ &c1, &rep };
    const root: Node = .{ .seq = &items };
    var list: std.ArrayListUnmanaged(u16) = .empty;
    defer list.deinit(a);
    try collectCaptures(&root, &list, a);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, list.items);
}

test "hir: fixedLength and lookbehindsFixed (B′)" {
    const a = std.testing.allocator;
    const t = std.testing;
    const ab_units = [_]LitUnit{ .{ .value = 'a' }, .{ .value = 'b' } };
    const ab: Node = .{ .literal = .{ .units = &ab_units } };
    // An astral literal: one unit with `u`, two (its surrogates) without.
    const smile_cp_units = [_]LitUnit{.{ .value = 0x1F600 }};
    const smile_cp: Node = .{ .literal = .{ .units = &smile_cp_units } };
    const smile_cu_units = [_]LitUnit{ .{ .value = 0xD83D }, .{ .value = 0xDE00 } };
    const smile_cu: Node = .{ .literal = .{ .units = &smile_cu_units } };
    const raw_units = [_]LitUnit{.{ .value = 0xC3, .raw_byte = true }};
    const raw: Node = .{ .literal = .{ .units = &raw_units } };
    const set = try CharSet.fromRanges(a, &.{.{ .lo = '0', .hi = '9' }});
    defer set.deinit(a);
    const digit: Node = .{ .char_set = .{ .set = set, .inverted = false, .encoding_hint = .set } };
    const empty: Node = .empty;
    const caret: Node = .{ .assert = .caret };
    const wb: Node = .{ .assert = .word_boundary };
    const br: Node = .{ .backref = .{ .indices = &.{1} } };

    // Fixed forms.
    try t.expectEqual(@as(?u32, 2), fixedLength(&ab));
    try t.expectEqual(@as(?u32, 1), fixedLength(&digit));
    try t.expectEqual(@as(?u32, 0), fixedLength(&empty));
    try t.expectEqual(@as(?u32, 0), fixedLength(&caret));
    try t.expectEqual(@as(?u32, 0), fixedLength(&wb));
    const seq_items = [_]*const Node{ &caret, &ab, &wb, &digit };
    const seq: Node = .{ .seq = &seq_items };
    try t.expectEqual(@as(?u32, 3), fixedLength(&seq));
    const exact: Node = .{ .repeat = .{ .min = 3, .max = 3, .policy = .lazy, .syntax_form = .counted, .body = &ab } };
    try t.expectEqual(@as(?u32, 6), fixedLength(&exact));
    const zero: Node = .{ .repeat = .{ .min = 0, .max = 0, .policy = .greedy, .syntax_form = .counted, .body = &ab } };
    try t.expectEqual(@as(?u32, 0), fixedLength(&zero));
    const alt_same_items = [_]*const Node{ &ab, &seq };
    const alt_same: Node = .{ .alt = &alt_same_items };
    try t.expectEqual(@as(?u32, null), fixedLength(&alt_same)); // 2 vs 3
    const two_digits_items = [_]*const Node{ &digit, &digit };
    const two_digits: Node = .{ .seq = &two_digits_items };
    const alt_eq_items = [_]*const Node{ &ab, &two_digits };
    const alt_eq: Node = .{ .alt = &alt_eq_items };
    try t.expectEqual(@as(?u32, 2), fixedLength(&alt_eq));
    const ahead_var: Node = .{ .repeat = .{ .min = 1, .max = null, .policy = .greedy, .syntax_form = .plus, .body = &digit } };
    const look_ahead: Node = .{ .look = .{ .behind = false, .negated = false, .body = &ahead_var } };
    try t.expectEqual(@as(?u32, 0), fixedLength(&look_ahead));
    const cap: Node = .{ .capture = .{ .index = 1, .name = null, .body = &ab } };
    try t.expectEqual(@as(?u32, 2), fixedLength(&cap));
    // `(?<=😀|ab)`: fixed without `u` (2 and 2 units), not with it (1 and 2).
    const alt_cu_items = [_]*const Node{ &smile_cu, &ab };
    const alt_cu: Node = .{ .alt = &alt_cu_items };
    try t.expectEqual(@as(?u32, 2), fixedLength(&alt_cu));
    const alt_cp_items = [_]*const Node{ &smile_cp, &ab };
    const alt_cp: Node = .{ .alt = &alt_cp_items };
    try t.expectEqual(@as(?u32, null), fixedLength(&alt_cp));

    // Forms that look fixed but aren't.
    try t.expectEqual(@as(?u32, null), fixedLength(&ahead_var));
    const opt: Node = .{ .repeat = .{ .min = 0, .max = 1, .policy = .greedy, .syntax_form = .question, .body = &ab } };
    try t.expectEqual(@as(?u32, null), fixedLength(&opt));
    const alt_empty_items = [_]*const Node{ &ab, &empty };
    const alt_empty: Node = .{ .alt = &alt_empty_items };
    try t.expectEqual(@as(?u32, null), fixedLength(&alt_empty));
    try t.expectEqual(@as(?u32, null), fixedLength(&br));
    try t.expectEqual(@as(?u32, null), fixedLength(&raw));
    const huge: Node = .{ .repeat = .{ .min = std.math.maxInt(u32), .max = std.math.maxInt(u32), .policy = .greedy, .syntax_form = .counted, .body = &ab } };
    try t.expectEqual(@as(?u32, null), fixedLength(&huge));

    // lookbehindsFixed: every lookbehind fixed and capture-free, nested too.
    const lb_ok: Node = .{ .look = .{ .behind = true, .negated = true, .body = &seq } };
    try t.expect(lookbehindsFixed(&lb_ok));
    const lb_var: Node = .{ .look = .{ .behind = true, .negated = false, .body = &ahead_var } };
    try t.expect(!lookbehindsFixed(&lb_var));
    const lb_cap: Node = .{ .look = .{ .behind = true, .negated = false, .body = &cap } };
    try t.expect(!lookbehindsFixed(&lb_cap));
    const la_cap: Node = .{ .look = .{ .behind = false, .negated = false, .body = &cap } };
    try t.expect(lookbehindsFixed(&la_cap)); // a lookahead may capture
    const inner_items = [_]*const Node{ &ab, &lb_var };
    const inner: Node = .{ .seq = &inner_items };
    const lb_nested: Node = .{ .look = .{ .behind = true, .negated = false, .body = &inner } };
    try t.expectEqual(@as(?u32, 2), fixedLength(&inner)); // the nested lookbehind is zero-width…
    try t.expect(!lookbehindsFixed(&lb_nested)); // …but not fixed itself
    const in_ahead: Node = .{ .look = .{ .behind = false, .negated = false, .body = &lb_var } };
    const deep: Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &in_ahead } };
    try t.expect(!lookbehindsFixed(&deep));
    try t.expect(lookbehindsFixed(&seq));
}

test "hir: dump" {
    const a = std.testing.allocator;
    const units = [_]LitUnit{ .{ .value = 'a' }, .{ .value = 0xE9 }, .{ .value = 0xC3, .raw_byte = true } };
    const lit: Node = .{ .literal = .{ .units = &units } };
    const set = try CharSet.fromRanges(a, &.{.{ .lo = '0', .hi = '9' }});
    defer set.deinit(a);
    const cs: Node = .{ .char_set = .{ .set = set, .inverted = false, .encoding_hint = .{ .byte_range = .{ .lo = '0', .hi = '9' } } } };
    const rep: Node = .{ .repeat = .{ .min = 2, .max = 3, .policy = .lazy, .syntax_form = .counted, .body = &cs } };
    const items = [_]*const Node{ &lit, &rep };
    const seq: Node = .{ .seq = &items };
    const root: Node = .{ .modifier_scope = .{ .flags = .{ .ignore_case = true }, .body = &seq } };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try dump(&root, &out.writer, 0);
    try std.testing.expectEqualStrings(
        \\scope i
        \\  seq
        \\    literal 'a' U+00E9 byte:C3
        \\    repeat counted lazy 2,3
        \\      char_set byte_range ranges=1 30-39
        \\
    , out.written());
}

test "nullable" {
    const a: Node = .{ .literal = .{ .units = &.{.{ .value = 'a' }} } };
    const e: Node = .empty;
    const star: Node = .{ .repeat = .{ .min = 0, .max = null, .policy = .greedy, .syntax_form = .star, .body = &a } };
    const plus: Node = .{ .repeat = .{ .min = 1, .max = null, .policy = .greedy, .syntax_form = .plus, .body = &a } };
    const plus_of_star: Node = .{ .repeat = .{ .min = 1, .max = null, .policy = .greedy, .syntax_form = .plus, .body = &star } };
    const seq: Node = .{ .seq = &.{ &a, &star } };
    const alt: Node = .{ .alt = &.{ &a, &e } };
    const caret: Node = .{ .assert = .caret };
    try std.testing.expect(!nullable(&a));
    try std.testing.expect(nullable(&e));
    try std.testing.expect(nullable(&star));
    try std.testing.expect(!nullable(&plus));
    try std.testing.expect(nullable(&plus_of_star));
    try std.testing.expect(!nullable(&seq));
    try std.testing.expect(nullable(&alt));
    try std.testing.expect(nullable(&caret));
}

test "captureRange: a subtree's groups, contiguous" {
    const a: Node = .{ .literal = .{ .units = &.{.{ .value = 'a' }} } };
    const g2: Node = .{ .capture = .{ .index = 2, .name = null, .body = &a } };
    const g3: Node = .{ .capture = .{ .index = 3, .name = null, .body = &a } };
    const seq: Node = .{ .seq = &.{ &g2, &g3 } };
    const g1: Node = .{ .capture = .{ .index = 1, .name = null, .body = &seq } };
    try std.testing.expectEqual(@as(u16, 1), captureRange(&g1).?.lo);
    try std.testing.expectEqual(@as(u16, 3), captureRange(&g1).?.hi);
    try std.testing.expectEqual(@as(u16, 2), captureRange(&seq).?.lo);
    try std.testing.expect(captureRange(&a) == null);
}

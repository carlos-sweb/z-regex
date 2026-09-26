//! HIR: the high-level intermediate representation (docs/REGEX_TIERS_PLAN.md,
//! F2c). The parser's AST is lowered into it (`src/lower/lower.zig`) and the
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
    /// The only field T0/T1 read.
    set: CharSet,
    /// The opcode's `_INV` form, for the bytecode encoding: the code
    /// generator encodes `complement(set)` then (the double complement is
    /// exact, so the table entry is the same as before F2c). COSMETIC.
    inverted: bool,
    encoding_hint: EncodingHint,
};

pub const Policy = enum { greedy, lazy, possessive };

/// SEMANTIC (see the file comment): which quantifier syntax produced a
/// Repeat. `question` clears the captures inside its body when it skips;
/// `counted` (`{n,m}`) doesn't; `plus` and `counted` `{1,}` also differ in
/// shape. Dies in F6a with the backtracker's code generator (earlier if F4b
/// aligns the backtracker with the spec's RepeatMatcher).
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
            try w.print("char_set {s}{s} ranges={d}", .{ @tagName(c.encoding_hint), if (c.inverted) " inv" else "", c.set.ranges.len });
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

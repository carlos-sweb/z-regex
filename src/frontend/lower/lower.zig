//! Lowering: parser AST -> HIR (docs/REGEX_TIERS_PLAN.md, F2c).
//!
//! Faithful to what the code generator did from the AST before F2c, so the
//! bytecode is unchanged (tests/snapshots/bytecode.txt). In particular a
//! class's CharSet is built with the case-folding rule of the path the class
//! took before, which is not the spec's (F3 fixes folding):
//! - a class that fits the ASCII bitmap folds the ASCII letters of its
//!   literals AND ranges (`[a-z]` under `i` matches `A`);
//! - any other class folds only its literals, with the simple case mapping
//!   (`[a-zé]` under `i` matches `É` but not `A`); property members and the
//!   operands of a `v` set operation don't fold.
//!
//! Needs the Unicode tables (property ranges, case mapping), so it lives
//! outside `ir/`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../parser/ast.zig");
const hir = @import("../../ir/hir.zig");
const charset_mod = @import("../../ir/charset.zig");
const properties = @import("../../unicode/properties.zig");
const casefold = @import("../../unicode/casefold.zig");
const Lexer = @import("../parser/lexer.zig").Lexer;
const Parser = @import("../parser/parser.zig").Parser;

const AstNode = ast.Node;
const Node = hir.Node;
const CharSet = charset_mod.CharSet;
const Range = charset_mod.Range;
const MAX_CODEPOINT = charset_mod.MAX_CODEPOINT;

pub const LowerError = error{ OutOfMemory, InvalidPattern };

pub const GroupName = struct { name: []const u8, index: u16 };

/// Lexer modes: what the pattern's grammar is (`CompileOptions.unicode`,
/// `.v`, `.possessive`; the flags that change only matching are
/// `hir.Flags`).
pub const LexOptions = struct {
    unicode: bool = false,
    v: bool = false,
    possessive: bool = false,
};

/// The shared front end of `compile()` and `analyze()` (F2d): lex, parse
/// and lower one pattern, so both see exactly the same HIR. Heap-allocated
/// because the parser keeps a pointer to the lexer. The AST, the parser's
/// group names and the HIR arena all live until `deinit`.
pub const Frontend = struct {
    gpa: Allocator,
    lexer: Lexer,
    parser: Parser,
    ast: *AstNode,
    arena: std.heap.ArenaAllocator,
    /// The HIR: a root ModifierScope carrying the flags.
    root: *const Node,

    /// Parse errors (and the lowering's own) are returned as is; the lexer's
    /// record of a known deviation (D10) is in `lexer.deviation`.
    pub fn init(gpa: Allocator, pattern: []const u8, lex: LexOptions, flags: hir.Flags) !*Frontend {
        const self = try gpa.create(Frontend);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.lexer = Lexer.init(pattern);
        self.lexer.unicode_mode = lex.unicode;
        self.lexer.v_mode = lex.v;
        self.lexer.possessive = lex.possessive;

        self.parser = try Parser.init(gpa, &self.lexer);
        errdefer self.parser.deinit();
        self.ast = try self.parser.parse();
        errdefer self.ast.deinit();

        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        const names = try arena.alloc(GroupName, self.parser.group_names.items.len);
        for (self.parser.group_names.items, names) |entry, *n| n.* = .{ .name = entry.name, .index = entry.index };
        self.root = try lower(arena, self.ast, flags, names);
        return self;
    }

    pub fn deinit(self: *Frontend) void {
        self.arena.deinit();
        self.ast.deinit();
        self.parser.deinit();
        self.gpa.destroy(self);
    }
};

/// Lower `root` into a HIR tree allocated in `arena` (free the arena to free
/// the tree). The result is the root `ModifierScope`, carrying `flags`.
/// `names` (index -> name of each named group) is borrowed.
pub fn lower(arena: Allocator, root: *const AstNode, flags: hir.Flags, names: []const GroupName) LowerError!*const Node {
    var l: Lowerer = .{ .arena = arena, .flags = flags, .names = names };
    const body = try l.lowerNode(root);
    return l.make(.{ .modifier_scope = .{ .flags = flags, .body = body } });
}

const Lowerer = struct {
    arena: Allocator,
    /// The flags of the scope being lowered (only the root scope in F2c).
    flags: hir.Flags,
    names: []const GroupName,

    fn make(self: *Lowerer, node: Node) LowerError!*const Node {
        const p = try self.arena.create(Node);
        p.* = node;
        return p;
    }

    fn only(n: *const AstNode) LowerError!*const AstNode {
        if (n.children.items.len != 1) return error.InvalidPattern;
        return n.children.items[0];
    }

    /// Only dispatches (F2a's rule for recursive descent): the kinds that
    /// nest go to small helpers on the recursive path, every leaf to the
    /// `noinline` `lowerLeaf`, so a nesting level's frame stays small.
    fn lowerNode(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        return switch (n.type) {
            .sequence => self.lowerSequence(n),
            .alternation => self.lowerAlternation(n),
            .group => self.lowerGroup(n),
            .non_capturing_group => self.lowerNode(try only(n)),
            .star, .plus, .question, .repeat, .lazy_star, .lazy_plus, .lazy_question, .lazy_repeat, .possessive_star, .possessive_plus, .possessive_question => self.repeat(n),
            .lookahead, .negative_lookahead, .lookbehind, .negative_lookbehind => self.look(n),
            else => self.lowerLeaf(n),
        };
    }

    noinline fn lowerLeaf(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        return switch (n.type) {
            .char => self.literalUnit(.{ .value = n.char_value, .raw_byte = n.char_value > 0x7F }),
            .back_ref => blk: {
                const indices = try self.arena.alloc(u16, 1);
                indices[0] = n.group_index;
                break :blk self.make(.{ .backref = .{ .indices = indices } });
            },
            .anchor_start => self.make(.{ .assert = .caret }),
            .anchor_end => self.make(.{ .assert = .dollar }),
            .word_boundary => self.make(.{ .assert = .word_boundary }),
            .not_word_boundary => self.make(.{ .assert = .not_word_boundary }),
            .dot => self.lowerDot(),
            .char_range => self.lowerByteRange(n),
            .unicode_property, .unicode_script, .unicode_script_extensions => self.lowerProperty(n),
            .char_class => self.lowerClass(n),
            .class_set_op => self.lowerClassSetOp(n),
            else => error.InvalidPattern,
        };
    }

    fn lowerGroup(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        const body = try self.lowerNode(try only(n));
        return self.make(.{ .capture = .{ .index = n.group_index, .name = self.nameOf(n.group_index), .body = body } });
    }

    fn maxOf(n: *const AstNode) ?u32 {
        return if (n.repeat_max == std.math.maxInt(u32)) null else n.repeat_max;
    }

    /// `names` is in source order, which is increasing index order (the
    /// parser registers a name when it assigns the group's index).
    fn nameOf(self: *Lowerer, index: u16) ?[]const u8 {
        var lo: usize = 0;
        var hi: usize = self.names.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const g = self.names[mid];
            if (g.index == index) return g.name;
            if (g.index < index) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    noinline fn literalUnit(self: *Lowerer, unit: hir.LitUnit) LowerError!*const Node {
        const units = try self.arena.alloc(hir.LitUnit, 1);
        units[0] = unit;
        return self.make(.{ .literal = .{ .units = units } });
    }

    /// Every quantifier, keeping the syntax that produced it
    /// (`hir.SyntaxForm`, semantic) and its policy.
    fn repeat(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        const body = try self.lowerNode(try only(n));
        const shape: struct { min: u32, max: ?u32, policy: hir.Policy, form: hir.SyntaxForm } = switch (n.type) {
            .star => .{ .min = 0, .max = null, .policy = .greedy, .form = .star },
            .plus => .{ .min = 1, .max = null, .policy = .greedy, .form = .plus },
            .question => .{ .min = 0, .max = 1, .policy = .greedy, .form = .question },
            .repeat => .{ .min = n.repeat_min, .max = maxOf(n), .policy = .greedy, .form = .counted },
            .lazy_star => .{ .min = 0, .max = null, .policy = .lazy, .form = .star },
            .lazy_plus => .{ .min = 1, .max = null, .policy = .lazy, .form = .plus },
            .lazy_question => .{ .min = 0, .max = 1, .policy = .lazy, .form = .question },
            .lazy_repeat => .{ .min = n.repeat_min, .max = maxOf(n), .policy = .lazy, .form = .counted },
            .possessive_star => .{ .min = 0, .max = null, .policy = .possessive, .form = .star },
            .possessive_plus => .{ .min = 1, .max = null, .policy = .possessive, .form = .plus },
            .possessive_question => .{ .min = 0, .max = 1, .policy = .possessive, .form = .question },
            else => unreachable,
        };
        return self.make(.{ .repeat = .{ .min = shape.min, .max = shape.max, .policy = shape.policy, .syntax_form = shape.form, .body = body } });
    }

    fn look(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        const body = try self.lowerNode(try only(n));
        const behind = n.type == .lookbehind or n.type == .negative_lookbehind;
        const negated = n.type == .negative_lookahead or n.type == .negative_lookbehind;
        return self.make(.{ .look = .{ .behind = behind, .negated = negated, .body = body } });
    }

    /// A parser `.sequence` is either one multi-byte literal character (its
    /// `char_value` set to the code point, its children the bytes) or an
    /// ordinary concatenation. Adjacent literals merge; empty items (an
    /// empty `(?:)`) generate nothing, so they are dropped.
    noinline fn lowerSequence(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        if (n.char_value != 0) return self.literalUnit(.{ .value = n.char_value });

        var items: std.ArrayListUnmanaged(*const Node) = .empty;
        var pending: std.ArrayListUnmanaged(hir.LitUnit) = .empty;
        for (n.children.items) |child| {
            const lowered = try self.lowerNode(child);
            switch (lowered.*) {
                .empty => {},
                .literal => |lit| try pending.appendSlice(self.arena, lit.units),
                .seq => |inner| {
                    try self.flushLiteral(&items, &pending);
                    try items.appendSlice(self.arena, inner);
                },
                else => {
                    try self.flushLiteral(&items, &pending);
                    try items.append(self.arena, lowered);
                },
            }
        }
        try self.flushLiteral(&items, &pending);
        return switch (items.items.len) {
            0 => self.make(.empty),
            1 => items.items[0],
            else => self.make(.{ .seq = items.items }),
        };
    }

    fn flushLiteral(self: *Lowerer, items: *std.ArrayListUnmanaged(*const Node), pending: *std.ArrayListUnmanaged(hir.LitUnit)) LowerError!void {
        if (pending.items.len == 0) return;
        const units = try pending.toOwnedSlice(self.arena);
        try items.append(self.arena, try self.make(.{ .literal = .{ .units = units } }));
    }

    /// The parser's alternation is binary and nested to the left
    /// (`a|b|c` = `((a|b)|c)`); flatten that chain into one n-ary Alt, which
    /// the code generator emits nested to the left again.
    noinline fn lowerAlternation(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        var branches: std.ArrayListUnmanaged(*const AstNode) = .empty;
        var cur = n;
        while (true) {
            if (cur.children.items.len != 2) return error.InvalidPattern;
            try branches.append(self.arena, cur.children.items[1]);
            const left = cur.children.items[0];
            if (left.type != .alternation) {
                try branches.append(self.arena, left);
                break;
            }
            cur = left;
        }
        std.mem.reverse(*const AstNode, branches.items);
        const items = try self.arena.alloc(*const Node, branches.items.len);
        for (branches.items, items) |b, *out| out.* = try self.lowerNode(b);
        return self.make(.{ .alt = items });
    }

    // -------------------------------------------------------------------------
    // Character sets
    // -------------------------------------------------------------------------

    /// `members` is the set before the node's own negation; `set` (what
    /// matches) is its complement when `inverted`.
    fn charSetNode(self: *Lowerer, members: CharSet, inverted: bool, hint: hir.EncodingHint) LowerError!*const Node {
        return self.charSetNodeFrom(members, inverted, hint, .{});
    }

    fn charSetNodeFrom(self: *Lowerer, members: CharSet, inverted: bool, hint: hir.EncodingHint, origin: hir.AnalysisOrigin) LowerError!*const Node {
        const set = if (inverted) try members.complement(self.arena) else members;
        return self.make(.{ .char_set = .{ .set = set, .inverted = inverted, .encoding_hint = hint, .analysis_origin = origin } });
    }

    /// Whether a class or a set-operation operand has a `\p`/`\P` member.
    fn hasProperty(n: *const AstNode) bool {
        return switch (n.type) {
            .unicode_property, .unicode_script, .unicode_script_extensions => true,
            .char_class, .class_set_op => for (n.children.items) |child| {
                if (hasProperty(child)) break true;
            } else false,
            else => false,
        };
    }

    noinline fn lowerDot(self: *Lowerer) LowerError!*const Node {
        const dot_all = self.flags.dot_all;
        // `.` without `s` excludes the LineTerminators \n, \r, U+2028, U+2029.
        const set = if (dot_all)
            try CharSet.fromRanges(self.arena, &.{.{ .lo = 0, .hi = MAX_CODEPOINT }})
        else
            try CharSet.fromRanges(self.arena, &.{ .{ .lo = 0, .hi = '\n' - 1 }, .{ .lo = '\n' + 1, .hi = '\r' - 1 }, .{ .lo = '\r' + 1, .hi = 0x2027 }, .{ .lo = 0x202A, .hi = MAX_CODEPOINT } });
        return self.make(.{ .char_set = .{ .set = set, .inverted = false, .encoding_hint = .{ .dot = .{ .dot_all = dot_all } } } });
    }

    /// A standalone range: `\d`/`\D`, or a class whose only member is an
    /// ASCII range (`[a-z]`). CHAR_RANGE(_INV) over bytes, or under `i` a
    /// bitmap with both cases of its ASCII letters.
    noinline fn lowerByteRange(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        if (n.range_start > 0xFF or n.range_end > 0xFF) return error.InvalidPattern;
        var ranges = [_]Range{.{ .lo = n.range_start, .hi = n.range_end }};
        const fold = self.flags.ignore_case and n.range_end <= 0x7F;
        const members = if (fold) try self.asciiFolded(&ranges) else try CharSet.fromRanges(self.arena, &ranges);
        return self.charSetNode(members, n.inverted, .{ .byte_range = .{ .lo = @intCast(n.range_start), .hi = @intCast(n.range_end) } });
    }

    noinline fn lowerProperty(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        // The property's own code points; a standalone `\P{...}` is the
        // node's `inverted`, applied once by `charSetNode` (the opcode's
        // `_INV` form), not by `propertyMembers`.
        const members = try self.propertyTable(n);
        const kind: hir.PropertyKind = switch (n.type) {
            .unicode_property => .general_category,
            .unicode_script => .script,
            .unicode_script_extensions => .script_extensions,
            else => unreachable,
        };
        if (n.char_value > 0xFF) return error.InvalidPattern;
        return self.charSetNodeFrom(members, n.inverted, .{ .property = .{ .kind = kind, .value = @intCast(n.char_value) } }, .{ .property = true });
    }

    noinline fn lowerClassSetOp(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        return self.charSetNodeFrom(try self.classSetOpMembers(n), n.inverted, .set, .{ .property = hasProperty(n), .set_operation = true });
    }

    /// A `[...]` class, routed exactly as the code generator did before F2c.
    noinline fn lowerClass(self: *Lowerer, n: *const AstNode) LowerError!*const Node {
        const children = n.children.items;
        // `[]` (D3): an empty table, never matches.
        if (children.len == 0 and !n.inverted) return self.charSetNode(try CharSet.fromRanges(self.arena, &.{}), false, .set);

        for (children) |child| switch (child.type) {
            .unicode_property, .unicode_script, .unicode_script_extensions => return self.charSetNodeFrom(try self.classMembers(n, self.flags.ignore_case), n.inverted, .set, .{ .property = true }),
            else => {},
        };
        var needs_set = false;
        for (children) |child| switch (child.type) {
            .char => needs_set = needs_set or child.char_value > 0x7F,
            .char_range => needs_set = needs_set or child.range_start > 0x7F or child.range_end > 0x7F,
            else => return error.InvalidPattern,
        };
        if (needs_set) return self.charSetNode(try self.classMembers(n, self.flags.ignore_case), n.inverted, .set);

        // A lone member is generated as itself: `[a]` is the literal `a`,
        // `[a-z]` a byte range.
        if (children.len == 1 and !n.inverted) return self.lowerNode(children[0]);

        // The ASCII bitmap: under `i`, both cases of every ASCII letter of
        // its literals and ranges.
        var ranges: std.ArrayListUnmanaged(Range) = .empty;
        for (children) |child| switch (child.type) {
            .char => try ranges.append(self.arena, .{ .lo = child.char_value, .hi = child.char_value }),
            .char_range => try ranges.append(self.arena, .{ .lo = child.range_start, .hi = child.range_end }),
            else => unreachable,
        };
        const members = if (self.flags.ignore_case) try self.asciiFolded(ranges.items) else try CharSet.fromRanges(self.arena, ranges.items);
        return self.charSetNode(members, n.inverted, .bitmap);
    }

    /// `ranges` plus the other case of every ASCII letter in them.
    fn asciiFolded(self: *Lowerer, ranges: []const Range) LowerError!CharSet {
        var all: std.ArrayListUnmanaged(Range) = .empty;
        try all.appendSlice(self.arena, ranges);
        for (ranges) |r| {
            if (intersect(r, 'a', 'z')) |x| try all.append(self.arena, .{ .lo = x.lo - 32, .hi = x.hi - 32 });
            if (intersect(r, 'A', 'Z')) |x| try all.append(self.arena, .{ .lo = x.lo + 32, .hi = x.hi + 32 });
        }
        return CharSet.fromRanges(self.arena, all.items);
    }

    fn intersect(r: Range, lo: u32, hi: u32) ?Range {
        const a = @max(r.lo, lo);
        const b = @min(r.hi, hi);
        return if (a <= b) .{ .lo = a, .hi = b } else null;
    }

    /// The union of a class's members, without its own `[^...]`. With
    /// `fold`, a literal also adds its simple case-fold pair; ranges and
    /// properties don't fold (see the file comment).
    fn classMembers(self: *Lowerer, n: *const AstNode, fold: bool) LowerError!CharSet {
        var literal: std.ArrayListUnmanaged(Range) = .empty;
        var props: std.ArrayListUnmanaged(*const AstNode) = .empty;
        for (n.children.items) |child| switch (child.type) {
            .char => {
                try literal.append(self.arena, .{ .lo = child.char_value, .hi = child.char_value });
                if (fold) {
                    if (casefold.toUpper(child.char_value) orelse casefold.toLower(child.char_value)) |opposite| {
                        try literal.append(self.arena, .{ .lo = opposite, .hi = opposite });
                    }
                }
            },
            .char_range => try literal.append(self.arena, .{ .lo = child.range_start, .hi = child.range_end }),
            .unicode_property, .unicode_script, .unicode_script_extensions => try props.append(self.arena, child),
            else => return error.InvalidPattern,
        };
        var acc = try CharSet.fromRanges(self.arena, literal.items);
        for (props.items) |p| acc = try acc.unionWith(try self.propertyMembers(p), self.arena);
        return acc;
    }

    /// A `\p{...}` node's code points; `\P{...}` (its `inverted`) is the
    /// complement.
    fn propertyMembers(self: *Lowerer, n: *const AstNode) LowerError!CharSet {
        const set = try self.propertyTable(n);
        return if (n.inverted) set.complement(self.arena) else set;
    }

    /// A `\p{...}`/`\P{...}` node's property table as a CharSet, ignoring
    /// its negation.
    fn propertyTable(self: *Lowerer, n: *const AstNode) LowerError!CharSet {
        const table = switch (n.type) {
            .unicode_property => properties.propertyRanges(@enumFromInt(n.char_value)),
            .unicode_script => properties.scriptRanges(@intCast(n.char_value)),
            .unicode_script_extensions => properties.scriptExtensionsRanges(@intCast(n.char_value)),
            else => return error.InvalidPattern,
        };
        // The generated tables are sorted and merged, and share `Range`'s
        // layout: view them in place instead of copying (a copy of `\p{L}` is
        // ~5.5 KiB per compile).
        comptime {
            const T = std.meta.Child(@TypeOf(table));
            std.debug.assert(@sizeOf(T) == @sizeOf(Range) and @offsetOf(T, "start") == @offsetOf(Range, "lo") and @offsetOf(T, "end") == @offsetOf(Range, "hi"));
        }
        _ = self;
        return CharSet.borrowed(@ptrCast(table));
    }

    /// One operand of a `v` set operation: a class (its members, then its
    /// own `[^...]` as a complement) or a bare `\p{...}`. No folding.
    fn classSetOperand(self: *Lowerer, n: *const AstNode) LowerError!CharSet {
        return switch (n.type) {
            .char_class => blk: {
                const members = try self.classMembers(n, false);
                break :blk if (n.inverted) members.complement(self.arena) else members;
            },
            .unicode_property, .unicode_script, .unicode_script_extensions => self.propertyMembers(n),
            else => error.InvalidPattern,
        };
    }

    /// `[A--B]` / `[A&&B]` without the outermost `[^...]` (the node's
    /// `inverted`, applied by `charSetNode`).
    fn classSetOpMembers(self: *Lowerer, n: *const AstNode) LowerError!CharSet {
        if (n.children.items.len != 2) return error.InvalidPattern;
        const left = try self.classSetOperand(n.children.items[0]);
        const right = try self.classSetOperand(n.children.items[1]);
        const op: ast.ClassSetOp = @enumFromInt(n.char_value);
        return switch (op) {
            .intersection => left.intersect(right, self.arena),
            .difference => left.difference(right, self.arena),
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const TestOptions = struct { flags: hir.Flags = .{}, unicode: bool = false, v: bool = false, possessive: bool = false };

fn expectLowered(pattern: []const u8, options: TestOptions, expected: []const u8) !void {
    const a = std.testing.allocator;
    var lexer = Lexer.init(pattern);
    lexer.unicode_mode = options.unicode or options.v;
    lexer.v_mode = options.v;
    lexer.possessive = options.possessive;
    var parser = try Parser.init(a, &lexer);
    defer parser.deinit();
    const root = try parser.parse();
    defer root.deinit();
    var names: std.ArrayListUnmanaged(GroupName) = .empty;
    defer names.deinit(a);
    for (parser.group_names.items) |g| try names.append(a, .{ .name = g.name, .index = g.index });

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const h = try lower(arena_state.allocator(), root, options.flags, names.items);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try hir.dump(h, &out.writer, 0);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "lower: literals merge across sequences and non-capturing groups" {
    try expectLowered("a(?:bc)d", .{},
        \\scope
        \\  literal 'a' 'b' 'c' 'd'
        \\
    );
    try expectLowered("\u{E9}\\u{1F600}x", .{ .unicode = true },
        \\scope
        \\  literal U+00E9 U+1F600 'x'
        \\
    );
    // A lone invalid UTF-8 byte stays a raw byte.
    try expectLowered("a\xFFb", .{},
        \\scope
        \\  literal 'a' byte:FF 'b'
        \\
    );
    try expectLowered("(?:)", .{},
        \\scope
        \\  empty
        \\
    );
}

test "lower: every quantifier keeps its syntax form" {
    try expectLowered("a*b+?c?d{2,3}e{2,}?f{0,1}", .{},
        \\scope
        \\  seq
        \\    repeat star greedy 0,inf
        \\      literal 'a'
        \\    repeat plus lazy 1,inf
        \\      literal 'b'
        \\    repeat question greedy 0,1
        \\      literal 'c'
        \\    repeat counted greedy 2,3
        \\      literal 'd'
        \\    repeat counted lazy 2,inf
        \\      literal 'e'
        \\    repeat counted greedy 0,1
        \\      literal 'f'
        \\
    );
    try expectLowered("a*+b++c?+", .{ .possessive = true },
        \\scope
        \\  seq
        \\    repeat star possessive 0,inf
        \\      literal 'a'
        \\    repeat plus possessive 1,inf
        \\      literal 'b'
        \\    repeat question possessive 0,1
        \\      literal 'c'
        \\
    );
}

test "lower: alternation is n-ary, groups, backrefs, asserts, lookarounds" {
    try expectLowered("^a|b|(?<n>c)\\1$", .{},
        \\scope
        \\  alt
        \\    seq
        \\      assert caret
        \\      literal 'a'
        \\    literal 'b'
        \\    seq
        \\      capture 1 n
        \\        literal 'c'
        \\      backref 1
        \\      assert dollar
        \\
    );
    try expectLowered("(?=a)(?!b)(?<=c)(?<!d)\\b\\B", .{},
        \\scope
        \\  seq
        \\    look ahead
        \\      literal 'a'
        \\    look ahead negated
        \\      literal 'b'
        \\    look behind
        \\      literal 'c'
        \\    look behind negated
        \\      literal 'd'
        \\    assert word_boundary
        \\    assert not_word_boundary
        \\
    );
}

test "lower: classes keep their pre-F2c encoding and folding path" {
    // A lone member is itself.
    try expectLowered("[a]", .{},
        \\scope
        \\  literal 'a'
        \\
    );
    try expectLowered("[a-c]\\d\\D", .{},
        \\scope
        \\  seq
        \\    char_set byte_range ranges=1 61-63
        \\    char_set byte_range ranges=1 30-39
        \\    char_set byte_range inv ranges=2 0-2F 3A-10FFFF
        \\
    );
    // ASCII bitmap: under `i`, literals and ranges fold.
    try expectLowered("[ab-c]", .{ .flags = .{ .ignore_case = true } },
        \\scope i
        \\  char_set bitmap ranges=2 41-43 61-63
        \\
    );
    // CHAR_SET path: only literals fold (a-z doesn't gain A-Z).
    try expectLowered("[a-z\u{E9}]", .{ .flags = .{ .ignore_case = true } },
        \\scope i
        \\  char_set set ranges=3 61-7A C9-C9 E9-E9
        \\
    );
    try expectLowered("[]", .{},
        \\scope
        \\  char_set set ranges=0
        \\
    );
    try expectLowered("[^]", .{},
        \\scope
        \\  char_set bitmap inv ranges=1 0-10FFFF
        \\
    );
    try expectLowered("\\p{Lu}", .{ .unicode = true },
        \\scope
        \\  char_set property +property ranges=655 41-5A C0-D6 D8-DE 100-100 ...
        \\
    );
    // A standalone \P: its set is the complement (applied once).
    try expectLowered("\\P{ASCII}", .{ .unicode = true },
        \\scope
        \\  char_set property inv +property ranges=1 80-10FFFF
        \\
    );
    // A \P member inside a class, under the class's own [^...].
    try expectLowered("[^\\P{ASCII}]", .{ .unicode = true },
        \\scope
        \\  char_set set inv +property ranges=1 0-7F
        \\
    );
    try expectLowered("[\\p{L}--[a-z]]", .{ .v = true },
        \\scope
        \\  char_set set +property +set_op ranges=683 41-5A AA-AA B5-B5 BA-BA ...
        \\
    );
}

test "lower: analysis_origin records property members and set operations" {
    // Its set is ASCII-only, but a property still needs the Unicode tables.
    try expectLowered("[\\p{ASCII}]", .{ .unicode = true },
        \\scope
        \\  char_set set +property ranges=1 0-7F
        \\
    );
    try expectLowered("[[a-c]--[b]]", .{ .v = true },
        \\scope
        \\  char_set set +set_op ranges=2 61-61 63-63
        \\
    );
    try expectLowered("[a\u{E9}]", .{ .unicode = true },
        \\scope
        \\  char_set set ranges=2 61-61 E9-E9
        \\
    );
}

test "lower: the dot's set follows `s`" {
    try expectLowered(".", .{},
        \\scope
        \\  char_set dot ranges=4 0-9 B-C E-2027 202A-10FFFF
        \\
    );
    try expectLowered(".", .{ .flags = .{ .dot_all = true } },
        \\scope s
        \\  char_set dot ranges=1 0-10FFFF
        \\
    );
}

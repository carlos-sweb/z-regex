//! Tier classifier -- F0a prototype (docs/REGEX_TIERS_PLAN.md §5.2, §6.3).
//!
//! `analyze` lowers a pattern to the HIR through the same front end as
//! `compile` (`lower.Frontend`, since F2d) and reports which RegExp features
//! the HIR uses and the minimum execution tier they require:
//!
//!   * `regular` (T0): regular language, no Unicode data needed.
//!   * `unicode` (T1): still regular, but needs Unicode tables/folding or
//!     large counted repetition.
//!   * `expert`  (T2): backreferences and lookaround (backtracking).
//!
//! The tier is a pure function of pattern + flags, never of the input. No
//! backend consumes it yet: this module only classifies. It never changes
//! what `compile` produces.
//!
//! Patterns whose current compile semantics is *known* to deviate from
//! ECMA-262 are reported as unclassifiable instead of being classified on
//! top of a wrong meaning (plan §6.3, "decisión de F0a"): D10 (recorded by
//! the lexer) and anything the current parser rejects. Since F2d a known
//! deviation still reports the pattern's complete feature set (only
//! `min_tier` is withheld); a parse error has none, since there is no HIR. D1 and D8 left this
//! list in F1b: the lexer reads `{,5}` per ECMA-262, and possessive
//! quantifiers are an opt-in of `compile` only, so `analyze` (which follows
//! the spec) sees `a*+` as a SyntaxError. A deliberate change of the F0a
//! contract (plan §5.2).

const std = @import("std");
const Allocator = std.mem.Allocator;

const lower_mod = @import("../frontend/lower/lower.zig");
const hir = @import("../ir/hir.zig");
const Node = hir.Node;

pub const Tier = enum(u2) {
    regular = 0,
    unicode = 1,
    expert = 2,

    fn max(a: Tier, b: Tier) Tier {
        return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
    }
};

pub const Feature = enum {
    // T0
    literal,
    dot,
    char_class,
    anchor,
    word_boundary,
    alternation,
    capturing_group,
    named_group,
    greedy_quantifier,
    lazy_quantifier,
    counted_repeat,
    flag_global,
    flag_has_indices,
    flag_multiline,
    flag_dot_all,
    flag_sticky,
    ignore_case_ascii,
    // T1
    unicode_mode,
    unicode_sets_mode,
    property_escape,
    class_set_operation,
    ignore_case_unicode,
    large_counted_repeat,
    // T2
    backreference,
    lookahead,
    lookbehind,

    /// The feature -> tier table (plan §3). Kept as one exhaustive switch
    /// so adding a feature without deciding its tier doesn't compile.
    pub fn tier(self: Feature) Tier {
        return switch (self) {
            .literal,
            .dot,
            .char_class,
            .anchor,
            .word_boundary,
            .alternation,
            .capturing_group,
            .named_group,
            .greedy_quantifier,
            .lazy_quantifier,
            .counted_repeat,
            .flag_global,
            .flag_has_indices,
            .flag_multiline,
            .flag_dot_all,
            .flag_sticky,
            .ignore_case_ascii,
            => .regular,

            .unicode_mode,
            .unicode_sets_mode,
            .property_escape,
            .class_set_operation,
            .ignore_case_unicode,
            .large_counted_repeat,
            => .unicode,

            .backreference,
            .lookahead,
            .lookbehind,
            => .expert,
        };
    }
};

pub const FeatureSet = std.EnumSet(Feature);

/// Known ECMA-262 deviations of the current parser that make a pattern
/// unclassifiable in F0a (numbering from plan §2.3).
pub const Deviation = enum {
    /// `{n}` with n > 65536 silently clamped.
    d10_quantifier_min_clamped,
};

pub const Unclassifiable = union(enum) {
    known_deviation: Deviation,
    /// The current parser rejected the pattern: either a real SyntaxError or
    /// an Annex B form it doesn't support yet (D2 `a{`, D3 `[]`).
    parse_error: anyerror,
};

/// ECMA-262 RegExp flags.
pub const Flags = struct {
    d: bool = false,
    g: bool = false,
    i: bool = false,
    m: bool = false,
    s: bool = false,
    u: bool = false,
    v: bool = false,
    y: bool = false,

    pub const ParseError = error{ InvalidFlag, DuplicateFlag, IncompatibleFlags };

    /// Parse a flags string such as `"giu"` with the same rules as the
    /// RegExp constructor: only `dgimsuvy`, no repeats, not both `u` and `v`.
    pub fn parse(text: []const u8) ParseError!Flags {
        var flags: Flags = .{};
        for (text) |c| {
            const slot: *bool = switch (c) {
                'd' => &flags.d,
                'g' => &flags.g,
                'i' => &flags.i,
                'm' => &flags.m,
                's' => &flags.s,
                'u' => &flags.u,
                'v' => &flags.v,
                'y' => &flags.y,
                else => return error.InvalidFlag,
            };
            if (slot.*) return error.DuplicateFlag;
            slot.* = true;
        }
        if (flags.u and flags.v) return error.IncompatibleFlags;
        return flags;
    }
};

/// Result of `analyze`. Owns no memory.
pub const Analysis = struct {
    /// Every feature the pattern uses. Also filled for a known deviation
    /// (since F2d); empty for a parse error.
    features: FeatureSet,
    /// Null exactly when `unclassifiable` is set.
    min_tier: ?Tier,
    unclassifiable: ?Unclassifiable = null,

    /// The features responsible for `min_tier` (the ones at that tier).
    /// Empty when the pattern is unclassifiable.
    pub fn reasons(self: Analysis) FeatureSet {
        var out = FeatureSet.initEmpty();
        const t = self.min_tier orelse return out;
        var it = self.features.iterator();
        while (it.next()) |f| {
            if (f.tier() == t) out.insert(f);
        }
        return out;
    }
};

/// Provisional unroll budget: a counted repetition whose total unrolled
/// copies (counts multiplied through nesting) exceed this needs T1's
/// counted-loop support instead of T0's plain unrolling. To be replaced by
/// `CompileLimits` in F2 and calibrated against F0c/F0d data.
pub const UNROLL_BUDGET: u64 = 1000;

/// Classify `pattern` under `flags`. Only allocation failure is an error;
/// parse failures and known deviations are reported in the result.
pub fn analyze(gpa: Allocator, pattern: []const u8, flags: Flags) Allocator.Error!Analysis {
    // The same front end and lexer modes `src/compile.zig::compile`
    // uses, so this classifies exactly the HIR compile generates from.
    const fe = lower_mod.Frontend.init(gpa, pattern, .{ .unicode = flags.u, .v = flags.v }, .{
        .ignore_case = flags.i,
        .multiline = flags.m,
        .dot_all = flags.s,
    }) catch |err| return parseFailure(err);
    defer fe.deinit();

    var walker: Walker = .{ .flags = flags };
    walker.visit(fe.root, 1);

    var features = walker.features;
    if (flags.d) features.insert(.flag_has_indices);
    if (flags.g) features.insert(.flag_global);
    if (flags.m) features.insert(.flag_multiline);
    if (flags.s) features.insert(.flag_dot_all);
    if (flags.y) features.insert(.flag_sticky);
    if (flags.u) features.insert(.unicode_mode);
    if (flags.v) features.insert(.unicode_sets_mode);
    if (flags.i) {
        // With `u`/`v`, even ASCII content folds through Unicode tables
        // (U+212A KELVIN SIGN matches `k`). Without them, ASCII content can
        // never match a non-ASCII input char (a char >= 128 never
        // canonicalizes below 128), so no tables are needed.
        const needs_tables = flags.u or flags.v or walker.non_ascii;
        features.insert(if (needs_tables) .ignore_case_unicode else .ignore_case_ascii);
    }

    // A known deviation keeps the whole feature set (plan §8.2, fixed in
    // F2d: the walk no longer stops there) but no tier: the semantics it
    // would be classified on is wrong until F5.
    if (fe.lexer.deviation) |d| {
        return .{ .features = features, .min_tier = null, .unclassifiable = .{ .known_deviation = switch (d) {
            .min_clamped => .d10_quantifier_min_clamped,
        } } };
    }

    var tier: Tier = .regular;
    var it = features.iterator();
    while (it.next()) |f| tier = Tier.max(tier, f.tier());
    return .{ .features = features, .min_tier = tier };
}

fn parseFailure(err: anyerror) Allocator.Error!Analysis {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return unclassifiable(.{ .parse_error = err });
}

fn unclassifiable(reason: Unclassifiable) Analysis {
    return .{ .features = FeatureSet.initEmpty(), .min_tier = null, .unclassifiable = reason };
}

const Walker = struct {
    flags: Flags,
    features: FeatureSet = FeatureSet.initEmpty(),
    /// Any literal or class member >= U+0080, or any `\p`/`\P`. A class is
    /// judged by its members before its own `[^...]` (`[^a]` is ASCII
    /// content); a negated shorthand spliced into a class (`[\W]`) has members
    /// up to U+10FFFF, so it counts. Over-promoting only costs speed, never
    /// semantics.
    non_ascii: bool = false,

    /// `copies`: how many times this node gets unrolled by enclosing
    /// counted repeats (saturating).
    fn visit(self: *Walker, node: *const Node, copies: u64) void {
        switch (node.*) {
            .empty => {},
            .literal => |lit| {
                self.features.insert(.literal);
                for (lit.units) |u| {
                    if (u.raw_byte or u.value >= 0x80) self.non_ascii = true;
                }
            },
            .char_set => |cs| self.visitCharSet(cs),
            .seq => |items| for (items) |item| self.visit(item, copies),
            .alt => |items| {
                self.features.insert(.alternation);
                for (items) |item| self.visit(item, copies);
            },
            .repeat => |r| {
                var child_copies = copies;
                switch (r.syntax_form) {
                    .star, .plus, .question => switch (r.policy) {
                        .greedy => self.features.insert(.greedy_quantifier),
                        .lazy => self.features.insert(.lazy_quantifier),
                        // Never built here: `analyze` doesn't turn on the
                        // possessive opt-in (D8), so `a*+` fails to parse.
                        .possessive => {},
                    },
                    .counted => {
                        self.features.insert(.counted_repeat);
                        if (r.policy == .lazy) self.features.insert(.lazy_quantifier);
                        // An open-ended `{n,}` unrolls `n` copies plus one loop body.
                        const count: u64 = if (r.max) |max| max else @as(u64, r.min) + 1;
                        child_copies = std.math.mul(u64, copies, @max(count, 1)) catch std.math.maxInt(u64);
                        if (child_copies > UNROLL_BUDGET) self.features.insert(.large_counted_repeat);
                    },
                }
                self.visit(r.body, child_copies);
            },
            .capture => |c| {
                self.features.insert(.capturing_group);
                if (c.name != null) self.features.insert(.named_group);
                self.visit(c.body, copies);
            },
            .backref => self.features.insert(.backreference),
            .assert => |a| self.features.insert(switch (a) {
                .caret, .dollar => .anchor,
                .word_boundary, .not_word_boundary => .word_boundary,
            }),
            .look => |l| {
                self.features.insert(if (l.behind) .lookbehind else .lookahead);
                self.visit(l.body, copies);
            },
            .modifier_scope => |m| self.visit(m.body, copies),
        }
    }

    fn visitCharSet(self: *Walker, cs: hir.CharSetNode) void {
        switch (cs.encoding_hint) {
            .dot => self.features.insert(.dot),
            .property => {},
            .set, .bitmap, .byte_range => {
                self.features.insert(.char_class);
                if (membersHaveNonAscii(cs)) self.non_ascii = true;
            },
        }
        if (cs.analysis_origin.property) {
            self.features.insert(.property_escape);
            self.non_ascii = true;
        }
        if (cs.analysis_origin.set_operation) self.features.insert(.class_set_operation);
    }

    /// Whether the class's members (its set, or the complement for `_INV`)
    /// include a code point >= U+0080, without building the complement.
    fn membersHaveNonAscii(cs: hir.CharSetNode) bool {
        const ranges = cs.set.ranges;
        if (!cs.inverted) return ranges.len > 0 and ranges[ranges.len - 1].hi >= 0x80;
        // The members miss something >= U+0080 unless the set covers all of
        // [U+0080, U+10FFFF], which, the ranges being merged, is one range.
        if (ranges.len == 0) return true;
        const last = ranges[ranges.len - 1];
        return !(last.lo <= 0x80 and last.hi == 0x10FFFF);
    }
};

// =============================================================================
// Tests -- the classification table of docs/REGEX_TIERS_PLAN.md §5.2 plus
// edge cases. This table is the F0a contract: changing an expected tier
// must be a deliberate, reviewed change.
// =============================================================================

const testing = std.testing;

fn classify(pattern: []const u8, flags: []const u8) !Analysis {
    return analyze(testing.allocator, pattern, try Flags.parse(flags));
}

fn expectTier(pattern: []const u8, flags: []const u8, expected: Tier) !void {
    const a = try classify(pattern, flags);
    if (a.unclassifiable) |u| {
        std.debug.print("\n/{s}/{s}: expected {s}, got unclassifiable {any}\n", .{ pattern, flags, @tagName(expected), u });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(expected, a.min_tier.?);
}

fn expectDeviation(pattern: []const u8, flags: []const u8, expected: Deviation) !void {
    const a = try classify(pattern, flags);
    try testing.expectEqual(@as(?Tier, null), a.min_tier);
    try testing.expectEqual(expected, a.unclassifiable.?.known_deviation);
}

fn expectParseError(pattern: []const u8, flags: []const u8) !void {
    const a = try classify(pattern, flags);
    try testing.expectEqual(@as(?Tier, null), a.min_tier);
    try testing.expect(a.unclassifiable.? == .parse_error);
}

test "§5.2 after F1: [0-9]{,5} is T0 (Annex B literal) and a SyntaxError with u" {
    // F0a reported it as unclassifiable (D1); F1b's lexer reads `{,5}` per
    // ECMA-262: a digit class followed by the literal text `{,5}`.
    try expectTier("[0-9]{,5}", "", .regular);
    try expectParseError("[0-9]{,5}", "u");
}

test "§5.2: T0 patterns" {
    try expectTier("\\d{3}-\\d{4}", "", .regular);
    try expectTier("^[\\w.+-]+@[\\w-]+\\.[\\w.]+$", "", .regular);
    try expectTier("(?<year>\\d{4})-(?<month>\\d{2})", "g", .regular);
    try expectTier("\\bfoo\\b", "i", .regular);
}

test "§5.2: T1 patterns" {
    try expectTier("caf\xc3\xa9", "i", .unicode); // café
    try expectTier("k", "iu", .unicode);
    try expectTier("\\p{L}+", "u", .unicode);
    try expectTier("[\\p{L}--[a-z]]", "v", .unicode);
}

test "§5.2: T2 patterns" {
    try expectTier("<(\\w+)>.*?<\\/\\1>", "", .expert);
    try expectTier("(?<=\\$)\\d+(?:\\.\\d{2})?", "", .expert);
    try expectTier("^(?=.*[a-z])(?=.*[A-Z])(?=.*\\d).{8,}$", "", .expert);
}

test "reasons are the features at the minimum tier" {
    const a = try classify("(a)\\1(?=b)[c-d]", "g");
    try testing.expectEqual(Tier.expert, a.min_tier.?);
    const r = a.reasons();
    try testing.expect(r.contains(.backreference));
    try testing.expect(r.contains(.lookahead));
    try testing.expect(!r.contains(.capturing_group));
    try testing.expect(a.features.contains(.capturing_group));
    try testing.expect(a.features.contains(.flag_global));
}

test "named groups and named backreferences" {
    // named_group comes from the HIR's captures (since F2d).
    const a = try classify("(?<x>a)\\k<x>", "");
    try testing.expect(a.features.contains(.named_group));
    try testing.expect(a.features.contains(.backreference));
    try testing.expectEqual(Tier.expert, a.min_tier.?);
}

test "non-ASCII content is T0 without i, T1 with i" {
    try expectTier("caf\xc3\xa9", "", .regular);
    try expectTier("[\xc3\xa0-\xc3\xb6]", "", .regular);
    try expectTier("[\xc3\xa0-\xc3\xb6]", "i", .unicode);
    try expectTier("[a-z]", "i", .regular);
}

test "flags u and v alone promote to T1" {
    try expectTier("abc", "u", .unicode);
    try expectTier("abc", "v", .unicode);
    try expectTier("abc", "dgmsy", .regular);
}

test "counted repetition: unroll budget multiplies through nesting" {
    try expectTier("a{1000}", "", .regular);
    try expectTier("a{1001}", "", .unicode);
    try expectTier("(?:a{40}){30}", "", .unicode);
    try expectTier("(?:a{10}){10}", "", .regular);
    try expectTier("a{5,}", "", .regular);
}

test "every empty-minimum brace form is literal text without u and a SyntaxError with u (D1, F1b)" {
    for ([_][]const u8{ "a{}", "a{,}", "x(?:a{,2})" }) |p| {
        try expectTier(p, "", .regular);
        try expectParseError(p, "u");
    }
    // Well-formed quantifiers are not D1.
    try expectTier("a{2}", "", .regular);
    try expectTier("a{2,}", "", .regular);
    try expectTier("a{2,5}", "", .regular);
}

test "braces that are class content or escaped are plain T0" {
    // The parser speculatively lexes the token after `[` in normal mode and
    // then rewinds; that discarded token must not change the result.
    try expectTier("[{,5}]", "", .regular);
    try expectTier("\\{,5}", "", .regular);
}

test "D10: clamped minimum is unclassifiable" {
    try expectDeviation("a{70000}", "", .d10_quantifier_min_clamped);
    try expectDeviation("a{70000,}", "", .d10_quantifier_min_clamped);
}

test "§8.2 (F2d): a known deviation still reports its complete feature set" {
    // Before F2d the walk stopped at D10 and returned no features, so the
    // backreference below went unrecorded.
    const a = try classify("(a)\\1{70000}", "");
    try testing.expectEqual(@as(?Tier, null), a.min_tier);
    try testing.expectEqual(Deviation.d10_quantifier_min_clamped, a.unclassifiable.?.known_deviation);
    try testing.expect(a.features.contains(.backreference));
    try testing.expect(a.features.contains(.capturing_group));
    try testing.expect(a.features.contains(.counted_repeat));
    try testing.expect(a.features.contains(.large_counted_repeat));
    try testing.expectEqual(@as(usize, 0), a.reasons().count());

    const n = try classify("(?<x>a)\\k<x>{70000,}(?=b)", "i");
    try testing.expect(n.unclassifiable.? == .known_deviation);
    try testing.expect(n.features.contains(.named_group));
    try testing.expect(n.features.contains(.lookahead));
    try testing.expect(n.features.contains(.ignore_case_ascii));
    // A parse error still has no HIR, so no features.
    const e = try classify("(", "");
    try testing.expectEqual(@as(usize, 0), e.features.count());
}

test "a property keeps its Tier and feature even when its set is ASCII (F2d)" {
    // The HIR's set for [\p{ASCII}] is ASCII-only; its analysis_origin keeps
    // it a property, which needs the Unicode tables under i.
    try expectTier("[\\p{ASCII}]", "i", .unicode);
    const a = try classify("[\\p{ASCII}]", "i");
    try testing.expect(a.features.contains(.property_escape));
    try testing.expect(a.features.contains(.ignore_case_unicode));
    const v = try classify("[[a]--[b]]", "iv");
    try testing.expect(v.features.contains(.class_set_operation));
    try testing.expectEqual(Tier.unicode, v.min_tier.?);
    // A class's own [^...] doesn't make ASCII members non-ASCII.
    try expectTier("[^a]", "i", .regular);
    try expectTier("\\D\\W", "i", .regular);
    try expectTier("[\\W]", "i", .unicode);
}

test "feature changes documented in F2d (the HIR's view, no Tier changes)" {
    // (?:...) is gone after lowering: there is no non_capturing_group
    // feature any more.
    const g = try classify("(?:ab)+", "");
    try testing.expect(g.features.contains(.literal));
    try testing.expect(g.features.contains(.greedy_quantifier));
    try testing.expectEqual(Tier.regular, g.min_tier.?);
    // A one-member class lowers to its member: [a] is a literal.
    const one = try classify("[a]", "");
    try testing.expect(one.features.contains(.literal));
    try testing.expect(!one.features.contains(.char_class));
    // Class members don't count as literals.
    const two = try classify("[ab]", "");
    try testing.expect(two.features.contains(.char_class));
    try testing.expect(!two.features.contains(.literal));
}

test "D8: possessive syntax is a SyntaxError for analyze (compile's opt-in only, F1b)" {
    try expectParseError("a++", "");
    try expectParseError("(?:ab)*+c", "");
    try expectParseError("a?+", "u");
}

test "parser rejections are reported, not raised" {
    try expectTier("a{", "", .regular); // Annex B literal since F1b (D2)
    try expectParseError("a{", "u");
    try expectTier("[]", "", .regular); // valid, never matches (D3, F1b)
    try expectParseError("(", "");
    try expectParseError("\\q", "u");
}

test "Flags.parse follows the RegExp constructor rules" {
    const f = try Flags.parse("gimsuy");
    try testing.expect(f.g and f.i and f.m and f.s and f.u and f.y and !f.v and !f.d);
    try testing.expectError(error.InvalidFlag, Flags.parse("x"));
    try testing.expectError(error.DuplicateFlag, Flags.parse("gg"));
    try testing.expectError(error.IncompatibleFlags, Flags.parse("uv"));
}

test "analyze reports allocation failure instead of classifying" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, analyze(failing.allocator(), "(a)b", .{}));
}

test "analyze does not leak on any allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            _ = try analyze(gpa, "(?<y>\\d{4})-(a|b)*\\1(?=c)", .{ .g = true });
        }
    }.run, .{});
}

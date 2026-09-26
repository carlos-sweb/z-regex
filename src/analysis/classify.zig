//! Tier classifier -- F0a prototype (docs/REGEX_TIERS_PLAN.md §5.2, §6.3).
//!
//! `analyze` parses a pattern with the *current* parser and reports which
//! RegExp features it uses and the minimum execution tier they require:
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
//! the lexer), D8 (possessive quantifiers), and anything the current parser
//! rejects. D1 left this list in F1b, when the lexer started reading `{,5}`
//! per ECMA-262 (a deliberate change of the F0a contract, plan §5.2).

const std = @import("std");
const Allocator = std.mem.Allocator;

const lexer_mod = @import("../parser/lexer.zig");
const parser_mod = @import("../parser/parser.zig");
const ast = @import("../parser/ast.zig");
const Node = ast.Node;

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
    non_capturing_group,
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
            .non_capturing_group,
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
    /// Possessive quantifiers (`*+`, `++`, `?+`) enabled by default.
    d8_possessive_quantifier,
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
    var lexer = lexer_mod.Lexer.init(pattern);
    // Same lexer modes `codegen/compiler.zig::compile` uses, so this
    // classifies exactly what compile would build.
    lexer.unicode_mode = flags.u;
    lexer.v_mode = flags.v;

    var parser = parser_mod.Parser.init(gpa, &lexer) catch |err| return parseFailure(err);
    defer parser.deinit();
    const root = parser.parse() catch |err| return parseFailure(err);
    defer root.deinit();

    if (lexer.deviation) |d| {
        return unclassifiable(.{ .known_deviation = switch (d) {
            .min_clamped => .d10_quantifier_min_clamped,
        } });
    }

    var walker: Walker = .{ .flags = flags };
    walker.visit(root, 1);
    if (walker.possessive) return unclassifiable(.{ .known_deviation = .d8_possessive_quantifier });

    var features = walker.features;
    if (parser.group_names.items.len > 0) features.insert(.named_group);
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
    /// Any literal/class content >= U+0080. Conservative: a negated
    /// shorthand spliced into a class (`[\W]`) is stored by the parser as a
    /// byte range up to 0xFF, indistinguishable from a real non-ASCII range,
    /// so it also counts. Over-promoting only costs speed, never semantics.
    non_ascii: bool = false,
    possessive: bool = false,

    /// `copies`: how many times this node gets unrolled by enclosing
    /// counted repeats (saturating).
    fn visit(self: *Walker, node: *const Node, copies: u64) void {
        var child_copies = copies;
        switch (node.type) {
            .char => {
                self.features.insert(.literal);
                if (node.char_value >= 0x80) self.non_ascii = true;
            },
            .char_range => {
                self.features.insert(.char_class);
                if (node.range_end >= 0x80) self.non_ascii = true;
            },
            .char_class => self.features.insert(.char_class),
            .dot => self.features.insert(.dot),
            .unicode_property, .unicode_script, .unicode_script_extensions => {
                self.features.insert(.property_escape);
                self.non_ascii = true;
            },
            .class_set_op => self.features.insert(.class_set_operation),
            .star, .plus, .question => self.features.insert(.greedy_quantifier),
            .lazy_star, .lazy_plus, .lazy_question => self.features.insert(.lazy_quantifier),
            .repeat, .lazy_repeat => {
                self.features.insert(.counted_repeat);
                if (node.type == .lazy_repeat) self.features.insert(.lazy_quantifier);
                const unbounded = node.repeat_max == std.math.maxInt(u32);
                // An open-ended `{n,}` unrolls `n` copies plus one loop body.
                const count: u64 = if (unbounded) @as(u64, node.repeat_min) + 1 else node.repeat_max;
                child_copies = std.math.mul(u64, copies, @max(count, 1)) catch std.math.maxInt(u64);
                if (child_copies > UNROLL_BUDGET) self.features.insert(.large_counted_repeat);
            },
            .possessive_star, .possessive_plus, .possessive_question => self.possessive = true,
            .group => self.features.insert(.capturing_group),
            .non_capturing_group => self.features.insert(.non_capturing_group),
            .alternation => self.features.insert(.alternation),
            .back_ref => self.features.insert(.backreference),
            .sequence => {},
            .anchor_start, .anchor_end => self.features.insert(.anchor),
            .word_boundary, .not_word_boundary => self.features.insert(.word_boundary),
            .lookahead, .negative_lookahead => self.features.insert(.lookahead),
            .lookbehind, .negative_lookbehind => self.features.insert(.lookbehind),
        }
        for (node.children.items) |child| self.visit(child, child_copies);
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

test "D8: possessive quantifiers are unclassifiable" {
    try expectDeviation("a++", "", .d8_possessive_quantifier);
    try expectDeviation("(?:ab)*+c", "", .d8_possessive_quantifier);
}

test "parser rejections are reported, not raised" {
    try expectTier("a{", "", .regular); // Annex B literal since F1b (D2)
    try expectParseError("a{", "u");
    try expectParseError("[]", ""); // D3 today
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

//! Main compiler API
//!
//! This module provides the high-level compiler interface,
//! orchestrating the lexer, parser, code generator, and optimizer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const generator_mod = @import("tier2").generator;
const optimizer_mod = @import("tier2").optimizer;
const bytecode_writer = @import("tier2").writer;
const format_mod = @import("tier2").format;
const charset_mod = @import("ir").charset;
const lower_mod = @import("frontend").lower;
const program_mod = @import("tier2").program;
const tier0 = @import("tier0");
const classify = @import("analysis/classify.zig");
const Tier = classify.Tier;

const CodeGenerator = generator_mod.CodeGenerator;
const Optimizer = optimizer_mod.Optimizer;
const OptLevel = optimizer_mod.OptLevel;
const BytecodeWriter = bytecode_writer.BytecodeWriter;
pub const NamedGroup = format_mod.NamedGroup;
pub const CharSet = charset_mod.CharSet;

/// Compilation result: the backtracker's program (`tier2/program.zig`).
pub const CompileResult = program_mod.CompileResult;
const freeCharSets = program_mod.freeCharSets;

/// Compiler options
pub const CompileOptions = struct {
    /// Optimization level
    opt_level: OptLevel = .basic,

    /// Case insensitive matching
    case_insensitive: bool = false,

    /// Multiline mode (^ and $ match line boundaries)
    multiline: bool = false,

    /// Dot matches newline
    dot_all: bool = false,

    /// Sticky mode (JS `y` flag): `find`/`findAll` only match starting
    /// exactly at the current position, never scanning ahead. Doesn't
    /// affect bytecode generation — read by `Regex.find`/`findAll`.
    sticky: bool = false,

    /// Unicode mode (JS `u` flag): this engine is already unconditionally
    /// code-point-aware (see Phase 1 in the compatibility plan) and already
    /// supports `\p{...}`/`\P{...}` unconditionally, so this flag's only
    /// current effect is stricter escape-sequence syntax validation, read by
    /// the lexer (`Lexer.unicode_mode`, set from this field by `lower.Frontend`):
    /// a backslash followed by a character that isn't a recognized escape or
    /// syntax character (e.g. `\q`) is `error.InvalidEscape` instead of
    /// falling back to a literal character (Annex-B-style leniency, this
    /// engine's default everywhere else). See `docs/KNOWN_LIMITATIONS.md`
    /// for what real `u`-mode strictness this does *not* yet cover (e.g.
    /// malformed `\x`/`\u`/`\c`/`\k`/`\p` still fall back leniently even
    /// under this flag).
    unicode: bool = false,

    /// Unicode Sets mode (JS `v` flag), partial: inside a character class,
    /// enables exactly one (non-chained, e.g. `A--B`, not `A--B--C`;
    /// non-nested beyond one bracket level) class-set operation, `--`
    /// (difference: matches `A` but not `B`) or `&&` (intersection: matches
    /// both), where each operand is either an ordinary class body
    /// (`\p{L}`, `a-z\d`, ...) or a nested `[...]` class (which may itself
    /// be `[^...]`-negated). Read by the lexer (`Lexer.v_mode`, set by `lower.Frontend` from
    /// this field) to recognize `--`/`&&`/`[` as their own
    /// tokens inside a class instead of literal characters -- outside a
    /// class, or with this flag off, they're unaffected. Does **not**
    /// (yet) turn on full `u`-mode strictness the way real `v` implies, nor
    /// `\q{...}` multi-string literals or operator chaining/deep nesting --
    /// see `docs/KNOWN_LIMITATIONS.md` for the authoritative list of what
    /// this flag does and doesn't cover.
    v: bool = false,

    /// Opt-in extension, not ECMA-262 (D8, F1b): read `*+`, `++` and `?+` as
    /// possessive quantifiers (match greedily, never give back). Off by
    /// default, where `a*+` is a SyntaxError as in JS. Before F1b this was
    /// always on.
    possessive: bool = false,

    /// Tests and diagnostics only (plan §4.2): which executor runs the
    /// pattern. Null: the dispatcher decides (T0's VM when the pattern is
    /// eligible, the backtracker otherwise). `.regular`: T0's VM, or
    /// `error.TierUnavailable` when the pattern can't run on it. `.expert`:
    /// the backtracker. `.unicode`: `error.TierUnavailable` until F5.
    force_tier: ?Tier = null,

    /// Where `compile` writes why it failed with `error.TierUnavailable`.
    tier_diagnostic: ?*TierUnavailable = null,
};

/// Why `force_tier` can't be honored.
pub const TierUnavailable = union(enum) {
    /// `analyze()` gives the pattern no tier (a known deviation; also a
    /// parse error, which fails compilation before this).
    not_classifiable: classify.Unclassifiable,
    /// The pattern needs this tier (T1 or T2), above T0.
    tier_too_high: Tier,
    /// T0, but not what the VM takes in F4a (captures, iterated nullable
    /// bodies, raw pattern bytes).
    not_eligible: tier0.Ineligible,
    /// No executor for this tier exists yet (T1, F5).
    not_built: Tier,
};

/// Both programs of a pattern (F4a): the backtracker's, always, and T0's
/// when the dispatcher routes the pattern to the VM.
pub const Compiled = struct {
    bt: CompileResult,
    t0: ?tier0.Program,
};

/// Compile a regex pattern to bytecode
pub fn compile(allocator: Allocator, pattern: []const u8, options: CompileOptions) !CompileResult {
    // Phases 1-3: lex, parse and lower to the HIR (F2c), through the front
    // end `analyze()` shares (F2d). The HIR holds no pointer into the AST;
    // both, and the parser, die when this function returns.
    const fe = try frontend(allocator, pattern, options);
    defer fe.deinit();
    return generate(allocator, fe, options);
}

/// Both programs, from one front end (F4a): the dispatcher classifies the
/// HIR with `analyzeFrontend` (the same answer `analyze()` gives) and,
/// when the pattern is T0 and the VM takes it (`tier0.check`), compiles
/// T0's `Program` too. `force_tier` overrides the choice (see there).
pub fn compileTiers(allocator: Allocator, pattern: []const u8, options: CompileOptions) !Compiled {
    const fe = try frontend(allocator, pattern, options);
    defer fe.deinit();
    const use_vm = try route(fe, options);
    const bt = try generate(allocator, fe, options);
    errdefer bt.deinit();
    const t0: ?tier0.Program = if (use_vm) tier0.compile(allocator, fe.root) catch |err| switch (err) {
        error.Ineligible => unreachable, // `route` checked
        else => |e| return e,
    } else null;
    return .{ .bt = bt, .t0 = t0 };
}

fn frontend(allocator: Allocator, pattern: []const u8, options: CompileOptions) !*lower_mod.Frontend {
    return lower_mod.Frontend.init(allocator, pattern, .{
        .unicode = options.unicode,
        .v = options.v,
        .possessive = options.possessive,
    }, .{
        .ignore_case = options.case_insensitive,
        .multiline = options.multiline,
        .dot_all = options.dot_all,
    });
}

/// Whether the pattern runs on T0's VM, or `error.TierUnavailable` when
/// `force_tier` asks for what it can't have.
fn route(fe: *const lower_mod.Frontend, options: CompileOptions) error{TierUnavailable}!bool {
    const force = options.force_tier;
    if (force == .expert) return false;
    if (force == .unicode) return unavailable(options, .{ .not_built = .unicode });
    const analysis = classify.analyzeFrontend(fe, .{
        .i = options.case_insensitive,
        .m = options.multiline,
        .s = options.dot_all,
        .u = options.unicode,
        .v = options.v,
        .y = options.sticky,
    });
    const why: ?TierUnavailable = if (analysis.min_tier) |tier|
        (if (tier != .regular) .{ .tier_too_high = tier } else if (tier0.check(fe.root)) |r| .{ .not_eligible = r } else null)
    else
        .{ .not_classifiable = analysis.unclassifiable.? };
    const reason = why orelse return true;
    if (force == .regular) return unavailable(options, reason);
    return false;
}

fn unavailable(options: CompileOptions, reason: TierUnavailable) error{TierUnavailable} {
    if (options.tier_diagnostic) |d| d.* = reason;
    return error.TierUnavailable;
}

/// Phases 4-5 over the HIR: the backtracker's bytecode.
fn generate(allocator: Allocator, fe: *const lower_mod.Frontend, options: CompileOptions) !CompileResult {
    const parser = &fe.parser;

    // Phase 4: Code generation, from the HIR only
    var writer = BytecodeWriter.init(allocator);
    defer writer.deinit();

    var generator = CodeGenerator.init(allocator, &writer);
    defer generator.deinit();
    try generator.generate(fe.root);

    const unoptimized = try writer.finalize();
    // Note: unoptimized is owned by writer, will be freed by writer.deinit()

    // Phase 5: Optimization
    var optimizer = Optimizer.init(allocator, options.opt_level);
    const optimized = try optimizer.optimize(unoptimized);
    errdefer allocator.free(optimized);

    // Copy named-group names out of the parser's pattern-borrowed slices so
    // they outlive this function (the pattern itself may not outlive the
    // returned CompileResult).
    var named_groups: std.ArrayListUnmanaged(NamedGroup) = .empty;
    errdefer {
        for (named_groups.items) |ng| allocator.free(ng.name);
        named_groups.deinit(allocator);
    }
    for (parser.group_names.items) |entry| {
        const name_copy = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name_copy);
        try named_groups.append(allocator, .{ .name = name_copy, .index = entry.index });
    }

    const charsets = try generator.takeCharSets();
    errdefer freeCharSets(allocator, charsets);

    return CompileResult{
        .bytecode = optimized,
        .named_groups = try named_groups.toOwnedSlice(allocator),
        .group_count = parser.group_counter,
        .charsets = charsets,
        .mode = if (options.unicode or options.v) .code_point else .code_unit,
        .allocator = allocator,
    };
}

/// Compile with default options
pub fn compileSimple(allocator: Allocator, pattern: []const u8) !CompileResult {
    return compile(allocator, pattern, .{});
}

// =============================================================================
// Tests
// =============================================================================

test "compile: simple character" {
    const result = try compileSimple(std.testing.allocator, "a");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: sequence" {
    const result = try compileSimple(std.testing.allocator, "abc");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: alternation" {
    const result = try compileSimple(std.testing.allocator, "a|b");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: quantifiers" {
    {
        const result = try compileSimple(std.testing.allocator, "a*");
        defer result.deinit();
        try std.testing.expect(result.bytecode.len > 0);
    }

    {
        const result = try compileSimple(std.testing.allocator, "a+");
        defer result.deinit();
        try std.testing.expect(result.bytecode.len > 0);
    }

    {
        const result = try compileSimple(std.testing.allocator, "a?");
        defer result.deinit();
        try std.testing.expect(result.bytecode.len > 0);
    }

    {
        const result = try compileSimple(std.testing.allocator, "a{2,5}");
        defer result.deinit();
        try std.testing.expect(result.bytecode.len > 0);
    }
}

test "compile: groups" {
    const result = try compileSimple(std.testing.allocator, "(abc)");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: character classes" {
    const result = try compileSimple(std.testing.allocator, "[abc]");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: anchors" {
    const result = try compileSimple(std.testing.allocator, "^hello$");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: complex pattern" {
    const result = try compileSimple(std.testing.allocator, "(a|b)+c*");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: with options" {
    const options = CompileOptions{
        .opt_level = .aggressive,
        .case_insensitive = true,
        .multiline = true,
    };

    const result = try compile(std.testing.allocator, "test", options);
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: empty pattern" {
    const result = try compileSimple(std.testing.allocator, "");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: dot" {
    const result = try compileSimple(std.testing.allocator, ".");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: escaped characters" {
    const result = try compileSimple(std.testing.allocator, "\\n\\t");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

test "compile: word boundaries" {
    const result = try compileSimple(std.testing.allocator, "\\bword\\b");
    defer result.deinit();

    try std.testing.expect(result.bytecode.len > 0);
}

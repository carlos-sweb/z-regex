//! Main compiler API
//!
//! This module provides the high-level compiler interface,
//! orchestrating the lexer, parser, code generator, and optimizer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const lexer_mod = @import("../parser/lexer.zig");
const parser_mod = @import("../parser/parser.zig");
const ast_mod = @import("../parser/ast.zig");
const generator_mod = @import("generator.zig");
const optimizer_mod = @import("optimizer.zig");
const bytecode_writer = @import("../bytecode/writer.zig");
const format_mod = @import("../bytecode/format.zig");

const Lexer = lexer_mod.Lexer;
const Parser = parser_mod.Parser;
const CodeGenerator = generator_mod.CodeGenerator;
const Optimizer = optimizer_mod.Optimizer;
const OptLevel = optimizer_mod.OptLevel;
const BytecodeWriter = bytecode_writer.BytecodeWriter;
pub const NamedGroup = format_mod.NamedGroup;

/// Compilation result
pub const CompileResult = struct {
    bytecode: []const u8,
    /// Owned copies of named-group name strings (see `NamedGroup`); empty for
    /// patterns with no named capture groups.
    named_groups: []const NamedGroup,
    /// Total number of capturing groups in the pattern (0 if none). Used to
    /// distinguish "group N doesn't exist in this pattern" from "group N
    /// exists but didn't participate in this match" -- e.g. for `$N`
    /// substitution in `Regex.replace`/`replaceAll`.
    group_count: u8,
    allocator: Allocator,

    /// Free the compilation result
    pub fn deinit(self: CompileResult) void {
        for (self.named_groups) |ng| self.allocator.free(ng.name);
        self.allocator.free(self.named_groups);
        self.allocator.free(self.bytecode);
    }
};

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
    /// the lexer (`Lexer.unicode_mode`, set from this field in `compile()`):
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
    /// be `[^...]`-negated). Read by the lexer (`Lexer.v_mode`, set from
    /// this field in `compile()`) to recognize `--`/`&&`/`[` as their own
    /// tokens inside a class instead of literal characters -- outside a
    /// class, or with this flag off, they're unaffected. Does **not**
    /// (yet) turn on full `u`-mode strictness the way real `v` implies, nor
    /// `\q{...}` multi-string literals or operator chaining/deep nesting --
    /// see `docs/KNOWN_LIMITATIONS.md` for the authoritative list of what
    /// this flag does and doesn't cover.
    v: bool = false,
};

/// Compile a regex pattern to bytecode
pub fn compile(allocator: Allocator, pattern: []const u8, options: CompileOptions) !CompileResult {
    // Phase 1: Lexing
    var lexer = Lexer.init(pattern);
    lexer.unicode_mode = options.unicode;
    lexer.v_mode = options.v;

    // Phase 2: Parsing
    var parser = try Parser.init(allocator, &lexer);
    defer parser.deinit();
    const ast = try parser.parse();
    defer ast.deinit();

    // Phase 3: Code generation
    var writer = BytecodeWriter.init(allocator);
    defer writer.deinit();

    var generator = CodeGenerator.init(allocator, &writer, options);
    try generator.generate(ast);

    const unoptimized = try writer.finalize();
    // Note: unoptimized is owned by writer, will be freed by writer.deinit()

    // Phase 4: Optimization
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

    return CompileResult{
        .bytecode = optimized,
        .named_groups = try named_groups.toOwnedSlice(allocator),
        .group_count = parser.group_counter,
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

//! High-level Regex API
//!
//! This module provides a simple, user-friendly API for working with regular expressions.
//! It combines compilation and matching into convenient methods.
//!
//! ## Quick Start
//!
//! ```zig
//! const regex = @import("regex.zig");
//!
//! // Test if a pattern matches
//! const matches = try regex.test("hello", "hello world");
//!
//! // Find first match
//! const result = try regex.find(allocator, "wo..", "hello world");
//! defer if (result) |r| r.deinit();
//!
//! // Compile once, use many times
//! var re = try regex.Regex.compile(allocator, "a+");
//! defer re.deinit();
//!
//! const match1 = try re.test_("aaa");
//! const match2 = try re.test_("bbb");
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import compiler and executor modules
const compiler = @import("codegen/compiler.zig");
const matcher_mod = @import("executor/matcher.zig");
const parser_mod = @import("parser/parser.zig");
const generator_mod = @import("codegen/generator.zig");
const format_mod = @import("bytecode/format.zig");

const CompileResult = compiler.CompileResult;
const CompileOptions = compiler.CompileOptions;
const Matcher = matcher_mod.Matcher;
pub const MatchResult = matcher_mod.MatchResult;

/// Error set for regex operations (includes all possible compilation and execution errors)
pub const RegexError = parser_mod.ParseError || generator_mod.CodegenError || Allocator.Error || error{
    UnexpectedEndOfBytecode,
    UnknownOpcode,
    UnresolvedLabels,
    BufferTooSmall,
    RecursionLimitExceeded,
    StepLimitExceeded,
};

/// Main Regex type - represents a compiled regular expression
pub const Regex = struct {
    allocator: Allocator,
    compiled: CompileResult,
    pattern: []const u8,
    /// JS `y` flag: `find`/`findAll` only match starting exactly at the
    /// current position, never scanning ahead to find a match further in.
    sticky: bool = false,

    const Self = @This();

    /// Compile a regex pattern
    pub fn compile(allocator: Allocator, pattern: []const u8) RegexError!Self {
        const compiled = try compiler.compileSimple(allocator, pattern);
        return .{
            .allocator = allocator,
            .compiled = compiled,
            .pattern = pattern,
        };
    }

    /// Compile with custom options
    pub fn compileWithOptions(allocator: Allocator, pattern: []const u8, options: CompileOptions) RegexError!Self {
        const compiled = try compiler.compile(allocator, pattern, options);
        return .{
            .allocator = allocator,
            .compiled = compiled,
            .pattern = pattern,
            .sticky = options.sticky,
        };
    }

    /// Free resources
    pub fn deinit(self: Self) void {
        self.compiled.deinit();
    }

    /// Test if pattern matches entire input
    pub fn matchFull(self: Self, input: []const u8) RegexError!bool {
        const m = Matcher.init(self.allocator, self.compiled.bytecode);
        return try m.matchFull(input);
    }

    /// Alias for matchFull (common in other regex libraries)
    pub fn test_(self: Self, input: []const u8) RegexError!bool {
        return self.matchFull(input);
    }

    /// Find first match in input. If `sticky`, only matches at position 0
    /// (no scanning ahead) — use `findAt` directly to check a later position.
    pub fn find(self: Self, input: []const u8) RegexError!?MatchResult {
        const m = Matcher.initWithNamedGroups(self.allocator, self.compiled.bytecode, self.compiled.named_groups);
        if (self.sticky) return try m.findAt(input, 0);
        return try m.find(input);
    }

    /// Try to match starting at exactly `start_pos`, with no scanning ahead
    /// (regardless of the `sticky` option). Useful for manually resuming
    /// iteration from a caller-tracked position, similar to how JS code
    /// tracks `lastIndex` when using a sticky regex.
    pub fn findAt(self: Self, input: []const u8, start_pos: usize) RegexError!?MatchResult {
        const m = Matcher.initWithNamedGroups(self.allocator, self.compiled.bytecode, self.compiled.named_groups);
        return try m.findAt(input, start_pos);
    }

    /// Find all matches in input. If `sticky`, stops at the first position
    /// that doesn't match instead of scanning ahead for the next one.
    pub fn findAll(self: Self, input: []const u8) RegexError!std.ArrayListUnmanaged(MatchResult) {
        const m = Matcher.initWithNamedGroups(self.allocator, self.compiled.bytecode, self.compiled.named_groups);
        return try m.findAll(input, self.sticky);
    }

    /// Get the original pattern string
    pub fn getPattern(self: Self) []const u8 {
        return self.pattern;
    }

    /// Replace the first match with `replacement` (JS `String.prototype.replace`
    /// with a non-global regex). `replacement` may use JS's substitution syntax
    /// (`$$`, `$&`, `` $` ``, `$'`, `$1`-`$99`, `$<name>` -- see
    /// `expandReplacement`). Returns a newly allocated string (owned by the
    /// caller) even when there's no match, in which case it's just a copy of
    /// `input`.
    pub fn replace(self: Self, allocator: Allocator, input: []const u8, replacement: []const u8) RegexError![]u8 {
        const m = try self.find(input);
        defer if (m) |match| match.deinit();

        const match = m orelse return allocator.dupe(u8, input);

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.appendSlice(allocator, input[0..match.start]);
        try expandReplacement(allocator, &result, replacement, match, input, self.compiled.named_groups, self.compiled.group_count);
        try result.appendSlice(allocator, input[match.end..]);
        return result.toOwnedSlice(allocator);
    }

    /// Replace every match with `replacement` (JS `String.prototype.replaceAll`,
    /// or `.replace` with a `/g` regex). Same substitution syntax as `replace`.
    /// Returns a newly allocated string (owned by the caller).
    pub fn replaceAll(self: Self, allocator: Allocator, input: []const u8, replacement: []const u8) RegexError![]u8 {
        var matches = try self.findAll(input);
        defer {
            for (matches.items) |m| m.deinit();
            matches.deinit(allocator);
        }

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        var last_end: usize = 0;
        for (matches.items) |match| {
            try result.appendSlice(allocator, input[last_end..match.start]);
            try expandReplacement(allocator, &result, replacement, match, input, self.compiled.named_groups, self.compiled.group_count);
            last_end = match.end;
        }
        try result.appendSlice(allocator, input[last_end..]);
        return result.toOwnedSlice(allocator);
    }
};

/// Expand a JS-style replacement pattern against `match`, appending the
/// result to `out`. Recognizes:
///   `$$`      - literal `$`
///   `$&`      - the matched substring
///   `` $` ``  - the input before the match
///   `$'`      - the input after the match
///   `$1`-`$99`- capture group by number (two digits tried first, per spec;
///               empty string if the group exists but didn't participate)
///   `$<name>` - capture group by name
/// Anything else starting with `$` (including `$N` where N doesn't
/// correspond to any group in this pattern, or `$<unknownName>`) is copied
/// through literally, matching JS's `String.prototype.replace` semantics for
/// a string (non-function) replacement argument.
fn expandReplacement(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    replacement: []const u8,
    match: MatchResult,
    input: []const u8,
    named_groups: []const format_mod.NamedGroup,
    group_count: u8,
) !void {
    var i: usize = 0;
    while (i < replacement.len) {
        if (replacement[i] != '$' or i + 1 >= replacement.len) {
            try out.append(allocator, replacement[i]);
            i += 1;
            continue;
        }

        switch (replacement[i + 1]) {
            '$' => {
                try out.append(allocator, '$');
                i += 2;
            },
            '&' => {
                try out.appendSlice(allocator, match.group(input));
                i += 2;
            },
            '`' => {
                try out.appendSlice(allocator, input[0..match.start]);
                i += 2;
            },
            '\'' => {
                try out.appendSlice(allocator, input[match.end..]);
                i += 2;
            },
            '<' => {
                if (std.mem.indexOfScalarPos(u8, replacement, i + 2, '>')) |end| {
                    const name = replacement[i + 2 .. end];
                    var resolved = false;
                    // A name can belong to more than one group (duplicate
                    // names across mutually exclusive alternation branches,
                    // e.g. `(?<x>a)|(?<x>b)`) -- at most one such group can
                    // ever actually participate, so check all of them and
                    // use whichever did, same as `MatchResult.getNamedCapture`.
                    for (named_groups) |ng| {
                        if (std.mem.eql(u8, ng.name, name)) {
                            resolved = true;
                            if (match.getCapture(ng.index, input)) |cap| {
                                try out.appendSlice(allocator, cap);
                                break;
                            }
                        }
                    }
                    if (resolved) {
                        i = end + 1;
                    } else {
                        try out.append(allocator, '$');
                        i += 1;
                    }
                } else {
                    try out.append(allocator, '$');
                    i += 1;
                }
            },
            '0'...'9' => {
                var num: u8 = 0;
                var consumed: usize = 0;

                if (i + 2 < replacement.len and std.ascii.isDigit(replacement[i + 2])) {
                    const two = std.fmt.parseInt(u8, replacement[i + 1 .. i + 3], 10) catch 0;
                    if (two >= 1 and two <= group_count) {
                        num = two;
                        consumed = 2;
                    }
                }
                if (consumed == 0) {
                    const one = replacement[i + 1] - '0';
                    if (one >= 1 and one <= group_count) {
                        num = one;
                        consumed = 1;
                    }
                }

                if (consumed == 0) {
                    try out.append(allocator, '$');
                    i += 1;
                    continue;
                }
                if (match.getCapture(num, input)) |cap| {
                    try out.appendSlice(allocator, cap);
                }
                i += 1 + consumed;
            },
            else => {
                try out.append(allocator, '$');
                i += 1;
            },
        }
    }
}

// =============================================================================
// Convenience Functions (one-shot operations)
// =============================================================================

/// Quick test: compile pattern and check if it matches input
pub fn test_(allocator: Allocator, pattern: []const u8, input: []const u8) RegexError!bool {
    const re = try Regex.compile(allocator, pattern);
    defer re.deinit();
    return try re.matchFull(input);
}

/// Quick match: compile pattern and return first match
pub fn find(allocator: Allocator, pattern: []const u8, input: []const u8) RegexError!?MatchResult {
    const re = try Regex.compile(allocator, pattern);
    defer re.deinit();
    return try re.find(input);
}

/// Quick findAll: compile pattern and return all matches
pub fn findAll(allocator: Allocator, pattern: []const u8, input: []const u8) RegexError!std.ArrayListUnmanaged(MatchResult) {
    const re = try Regex.compile(allocator, pattern);
    defer re.deinit();
    return try re.findAll(input);
}

/// Quick replace: compile pattern and replace the first match
pub fn replace(allocator: Allocator, pattern: []const u8, input: []const u8, replacement: []const u8) RegexError![]u8 {
    const re = try Regex.compile(allocator, pattern);
    defer re.deinit();
    return try re.replace(allocator, input, replacement);
}

/// Quick replaceAll: compile pattern and replace every match
pub fn replaceAll(allocator: Allocator, pattern: []const u8, input: []const u8, replacement: []const u8) RegexError![]u8 {
    const re = try Regex.compile(allocator, pattern);
    defer re.deinit();
    return try re.replaceAll(allocator, input, replacement);
}

// =============================================================================
// Tests
// =============================================================================

test "Regex: compile and test" {
    var re = try Regex.compile(std.testing.allocator, "hello");
    defer re.deinit();

    try std.testing.expect(try re.test_("hello"));
    try std.testing.expect(!try re.test_("world"));
}

test "Regex: compile with options" {
    const options = CompileOptions{
        .opt_level = .basic,
    };

    var re = try Regex.compileWithOptions(std.testing.allocator, "test", options);
    defer re.deinit();

    try std.testing.expect(try re.matchFull("test"));
}

test "Regex: find" {
    var re = try Regex.compile(std.testing.allocator, "world");
    defer re.deinit();

    const result = try re.find("hello world");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "Regex: find with capture" {
    // Note: \d+ would be [0-9]+ but character classes not fully implemented yet
    // Using simple pattern for now
    var re = try Regex.compile(std.testing.allocator, "(wo..)");
    defer re.deinit();

    const result = try re.find("hello world");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    const captured = result.?.getCapture(1, "hello world");
    try std.testing.expect(captured != null);
    try std.testing.expectEqualStrings("worl", captured.?);
}

test "Regex: findAll" {
    var re = try Regex.compile(std.testing.allocator, "a");
    defer re.deinit();

    var matches = try re.findAll("banana");
    defer {
        for (matches.items) |match| {
            match.deinit();
        }
        matches.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 3), matches.items.len);
}

test "Regex: getPattern" {
    var re = try Regex.compile(std.testing.allocator, "test.*");
    defer re.deinit();

    try std.testing.expectEqualStrings("test.*", re.getPattern());
}

test "convenience: test_" {
    try std.testing.expect(try test_(std.testing.allocator, "abc", "abc"));
    try std.testing.expect(!try test_(std.testing.allocator, "abc", "xyz"));
}

test "convenience: find" {
    const result = try find(std.testing.allocator, "wo..", "hello world");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.?.start);
}

test "convenience: findAll" {
    var matches = try findAll(std.testing.allocator, "o", "foo");
    defer {
        for (matches.items) |match| {
            match.deinit();
        }
        matches.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
}

test "Regex: alternation" {
    var re = try Regex.compile(std.testing.allocator, "cat|dog");
    defer re.deinit();

    try std.testing.expect(try re.test_("cat"));
    try std.testing.expect(try re.test_("dog"));
    try std.testing.expect(!try re.test_("bird"));
}

test "Regex: quantifiers" {
    var re_star = try Regex.compile(std.testing.allocator, "a*");
    defer re_star.deinit();
    try std.testing.expect(try re_star.test_(""));
    try std.testing.expect(try re_star.test_("aaa"));

    var re_plus = try Regex.compile(std.testing.allocator, "a+");
    defer re_plus.deinit();
    try std.testing.expect(!try re_plus.test_(""));
    try std.testing.expect(try re_plus.test_("aaa"));

    var re_question = try Regex.compile(std.testing.allocator, "a?");
    defer re_question.deinit();
    try std.testing.expect(try re_question.test_(""));
    try std.testing.expect(try re_question.test_("a"));
}

test "Regex: lazy quantifiers" {
    // Lazy star: matches as few as possible
    {
        var re = try Regex.compile(std.testing.allocator, "a*?");
        defer re.deinit();
        // test_() checks if pattern matches ENTIRE input
        try std.testing.expect(try re.test_("")); // Empty matches empty
        // For lazy star with non-empty input, use find() instead
        const match = try re.find("aaa");
        defer if (match) |m| m.deinit();
        try std.testing.expect(match != null);
        try std.testing.expectEqual(@as(usize, 0), match.?.start);
        try std.testing.expectEqual(@as(usize, 0), match.?.end); // Lazy matches empty
    }

    // Lazy plus: matches one or more, but as few as possible
    {
        var re = try Regex.compile(std.testing.allocator, "a+?");
        defer re.deinit();
        try std.testing.expect(!try re.test_("")); // Must match at least one
        try std.testing.expect(try re.test_("a")); // Matches exactly 1
        // With longer input, lazy matches minimum (1 char)
        const match = try re.find("aaa");
        defer if (match) |m| m.deinit();
        try std.testing.expect(match != null);
        try std.testing.expectEqual(@as(usize, 0), match.?.start);
        try std.testing.expectEqual(@as(usize, 1), match.?.end); // Lazy matches 1
    }

    // Lazy question: 0 or 1, preferring 0
    {
        var re = try Regex.compile(std.testing.allocator, "a??");
        defer re.deinit();
        try std.testing.expect(try re.test_("")); // Empty matches empty
        // For lazy question with non-empty input, use find()
        const match = try re.find("a");
        defer if (match) |m| m.deinit();
        try std.testing.expect(match != null);
        try std.testing.expectEqual(@as(usize, 0), match.?.start);
        try std.testing.expectEqual(@as(usize, 0), match.?.end); // Lazy matches empty
    }
}

test "Regex: greedy vs lazy comparison" {
    // Greedy star matches maximum
    {
        var re = try Regex.compile(std.testing.allocator, "a*");
        defer re.deinit();
        const match = try re.find("aaabbb");
        defer if (match) |m| m.deinit();
        try std.testing.expect(match != null);
        try std.testing.expectEqual(@as(usize, 0), match.?.start);
        try std.testing.expectEqual(@as(usize, 3), match.?.end); // Greedy: all 'a's
    }

    // Lazy star matches minimum
    {
        var re = try Regex.compile(std.testing.allocator, "a*?");
        defer re.deinit();
        const match = try re.find("aaabbb");
        defer if (match) |m| m.deinit();
        try std.testing.expect(match != null);
        try std.testing.expectEqual(@as(usize, 0), match.?.start);
        try std.testing.expectEqual(@as(usize, 0), match.?.end); // Lazy: empty
    }
}

test "Regex: possessive quantifiers" {
    // Possessive star: consumes all without backtracking
    {
        var re = try Regex.compile(std.testing.allocator, "a*+");
        defer re.deinit();
        try std.testing.expect(try re.test_(""));
        try std.testing.expect(try re.test_("aaa"));

        const match = try re.find("aaabbb");
        defer if (match) |m| m.deinit();
        try std.testing.expect(match != null);
        try std.testing.expectEqual(@as(usize, 0), match.?.start);
        try std.testing.expectEqual(@as(usize, 3), match.?.end); // Possessive: all 'a's
    }

    // Possessive plus: at least one, then all without backtracking
    {
        var re = try Regex.compile(std.testing.allocator, "a++");
        defer re.deinit();
        try std.testing.expect(!try re.test_(""));
        try std.testing.expect(try re.test_("aaa"));

        const match = try re.find("aaa");
        defer if (match) |m| m.deinit();
        try std.testing.expect(match != null);
        try std.testing.expectEqual(@as(usize, 0), match.?.start);
        try std.testing.expectEqual(@as(usize, 3), match.?.end); // All
    }

    // Possessive question: 0 or 1 without backtracking
    {
        var re = try Regex.compile(std.testing.allocator, "a?+");
        defer re.deinit();
        try std.testing.expect(try re.test_(""));
        try std.testing.expect(try re.test_("a"));
    }
}

test "Regex: greedy vs lazy vs possessive comparison" {
    // All three should match "aaa" when used alone
    {
        var greedy = try Regex.compile(std.testing.allocator, "a*");
        defer greedy.deinit();
        const match1 = try greedy.find("aaa");
        defer if (match1) |m| m.deinit();
        try std.testing.expectEqual(@as(usize, 3), match1.?.end);
    }

    {
        var lazy = try Regex.compile(std.testing.allocator, "a*?");
        defer lazy.deinit();
        const match2 = try lazy.find("aaa");
        defer if (match2) |m| m.deinit();
        try std.testing.expectEqual(@as(usize, 0), match2.?.end); // Lazy: minimum
    }

    {
        var possessive = try Regex.compile(std.testing.allocator, "a*+");
        defer possessive.deinit();
        const match3 = try possessive.find("aaa");
        defer if (match3) |m| m.deinit();
        try std.testing.expectEqual(@as(usize, 3), match3.?.end); // Possessive: all
    }
}

test "Regex: anchors" {
    var re = try Regex.compile(std.testing.allocator, "^hello$");
    defer re.deinit();

    try std.testing.expect(try re.test_("hello"));
    try std.testing.expect(!try re.test_("hello world"));
    try std.testing.expect(!try re.test_("say hello"));
}

test "Regex: dot metacharacter" {
    var re = try Regex.compile(std.testing.allocator, "h.llo");
    defer re.deinit();

    try std.testing.expect(try re.test_("hello"));
    try std.testing.expect(try re.test_("hallo"));
    try std.testing.expect(try re.test_("hxllo"));
}

test "Regex: complex pattern" {
    var re = try Regex.compile(std.testing.allocator, "^[a-z]+@[a-z]+\\.[a-z]+$");
    defer re.deinit();

    // These should work when character classes are fully implemented
    // For now, just test that compilation succeeds
    _ = try re.test_("user@example.com");
}

test "Regex: character classes" {
    // Test \d (digit)
    {
        var re = try Regex.compile(std.testing.allocator, "\\d");
        defer re.deinit();
        try std.testing.expect(try re.test_("5"));
        try std.testing.expect(!try re.test_("a"));
    }

    // Test \D (not digit)
    {
        var re = try Regex.compile(std.testing.allocator, "\\D");
        defer re.deinit();
        try std.testing.expect(try re.test_("a"));
        try std.testing.expect(!try re.test_("5"));
    }

    // Test [0-9] range
    {
        var re = try Regex.compile(std.testing.allocator, "[0-9]");
        defer re.deinit();
        try std.testing.expect(try re.test_("5"));
        try std.testing.expect(!try re.test_("a"));
    }

    // Test [^0-9] negated range
    {
        var re = try Regex.compile(std.testing.allocator, "[^0-9]");
        defer re.deinit();
        try std.testing.expect(try re.test_("a"));
        try std.testing.expect(!try re.test_("5"));
    }

    // Test [a-z] range
    {
        var re = try Regex.compile(std.testing.allocator, "[a-z]");
        defer re.deinit();
        try std.testing.expect(try re.test_("a"));
        try std.testing.expect(try re.test_("z"));
        try std.testing.expect(!try re.test_("A"));
        try std.testing.expect(!try re.test_("5"));
    }

    // Test [^a-z] negated range
    {
        var re = try Regex.compile(std.testing.allocator, "[^a-z]");
        defer re.deinit();
        try std.testing.expect(try re.test_("A"));
        try std.testing.expect(try re.test_("5"));
        try std.testing.expect(!try re.test_("a"));
    }
}

test "Regex: case-insensitive matching" {
    const options = CompileOptions{
        .case_insensitive = true,
    };

    // Test single character
    {
        var re = try Regex.compileWithOptions(std.testing.allocator, "a", options);
        defer re.deinit();
        try std.testing.expect(try re.test_("a"));
        try std.testing.expect(try re.test_("A"));
    }

    // Test word
    {
        var re = try Regex.compileWithOptions(std.testing.allocator, "hello", options);
        defer re.deinit();
        try std.testing.expect(try re.test_("hello"));
        try std.testing.expect(try re.test_("HELLO"));
        try std.testing.expect(try re.test_("Hello"));
        try std.testing.expect(try re.test_("HeLLo"));
        try std.testing.expect(!try re.test_("world"));
    }

    // Test with numbers (should not be affected)
    {
        var re = try Regex.compileWithOptions(std.testing.allocator, "test123", options);
        defer re.deinit();
        try std.testing.expect(try re.test_("test123"));
        try std.testing.expect(try re.test_("TEST123"));
        try std.testing.expect(try re.test_("Test123"));
        try std.testing.expect(!try re.test_("test124"));
    }

    // Test with anchors
    {
        var re = try Regex.compileWithOptions(std.testing.allocator, "^abc$", options);
        defer re.deinit();
        try std.testing.expect(try re.test_("abc"));
        try std.testing.expect(try re.test_("ABC"));
        try std.testing.expect(try re.test_("AbC"));
        try std.testing.expect(!try re.test_("abcd"));
    }
}

test "Regex: counted quantifiers {n,m}" {
    // Test exact count {3}
    {
        var re = try Regex.compile(std.testing.allocator, "a{3}");
        defer re.deinit();

        try std.testing.expect(!try re.test_("a"));
        try std.testing.expect(!try re.test_("aa"));
        try std.testing.expect(try re.test_("aaa"));
        try std.testing.expect(!try re.test_("aaaa")); // Full match requires exactly 3

        // Test find() for partial matches
        const r1 = try re.find("aaaa");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 0), r1.?.start);
        try std.testing.expectEqual(@as(usize, 3), r1.?.end);
    }

    // Test range {2,4}
    {
        var re = try Regex.compile(std.testing.allocator, "a{2,4}");
        defer re.deinit();

        try std.testing.expect(!try re.test_("a"));
        try std.testing.expect(try re.test_("aa"));
        try std.testing.expect(try re.test_("aaa"));
        try std.testing.expect(try re.test_("aaaa"));
        try std.testing.expect(!try re.test_("aaaaa")); // Full match needs 2-4

        // Test greedy matching
        const r1 = try re.find("aaaaa");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 0), r1.?.start);
        try std.testing.expectEqual(@as(usize, 4), r1.?.end); // Greedy: matches 4, not 2 or 3
    }

    // Test unbounded {2,}
    {
        var re = try Regex.compile(std.testing.allocator, "a{2,}");
        defer re.deinit();

        try std.testing.expect(!try re.test_("a"));
        try std.testing.expect(try re.test_("aa"));
        try std.testing.expect(try re.test_("aaa"));
        try std.testing.expect(try re.test_("aaaa"));
        try std.testing.expect(try re.test_("aaaaaaaa"));
        try std.testing.expect(!try re.test_("baaaa")); // Must start with a's for full match
    }

    // Test with patterns
    {
        var re = try Regex.compile(std.testing.allocator, "x{2}y");
        defer re.deinit();

        try std.testing.expect(!try re.test_("xy"));
        try std.testing.expect(try re.test_("xxy"));
        try std.testing.expect(!try re.test_("xxxy"));
        try std.testing.expect(!try re.test_("xxxyy"));
    }

    // Test {0,n}
    {
        var re = try Regex.compile(std.testing.allocator, "a{0,2}b");
        defer re.deinit();

        try std.testing.expect(try re.test_("b"));
        try std.testing.expect(try re.test_("ab"));
        try std.testing.expect(try re.test_("aab"));
        try std.testing.expect(!try re.test_("aaab"));
    }

    // Test {1} - exactly 1
    {
        var re = try Regex.compile(std.testing.allocator, "a{1}");
        defer re.deinit();

        try std.testing.expect(!try re.test_(""));
        try std.testing.expect(try re.test_("a"));
        try std.testing.expect(!try re.test_("aa"));
    }
}

test "Regex: backreferences \\1-\\9" {
    // Test simple backreference
    {
        var re = try Regex.compile(std.testing.allocator, "(.)\\1");
        defer re.deinit();

        try std.testing.expect(try re.test_("aa"));
        try std.testing.expect(try re.test_("bb"));
        try std.testing.expect(try re.test_("00"));
        try std.testing.expect(!try re.test_("ab"));
        try std.testing.expect(!try re.test_("a"));
    }

    // Test word repetition
    {
        var re = try Regex.compile(std.testing.allocator, "(.+) \\1");
        defer re.deinit();

        try std.testing.expect(try re.test_("hello hello"));
        try std.testing.expect(try re.test_("test test"));
        try std.testing.expect(!try re.test_("hello world"));
        try std.testing.expect(!try re.test_("hello"));
    }

    // Test quoted strings (matching quotes)
    {
        var re = try Regex.compile(std.testing.allocator, "(['\"]).*\\1");
        defer re.deinit();

        const r1 = try re.find("'hello'");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqualStrings("'hello'", r1.?.group("'hello'"));

        const r2 = try re.find("\"world\"");
        try std.testing.expect(r2 != null);
        defer r2.?.deinit();
        try std.testing.expectEqualStrings("\"world\"", r2.?.group("\"world\""));

        // Mismatched quotes should not match
        try std.testing.expect(null == try re.find("'hello\""));
        try std.testing.expect(null == try re.find("\"world'"));
    }

    // Test multiple backreferences
    {
        var re = try Regex.compile(std.testing.allocator, "(.)(.)(.)\\3\\2\\1");
        defer re.deinit();

        try std.testing.expect(try re.test_("abccba"));
        try std.testing.expect(try re.test_("123321"));
        try std.testing.expect(!try re.test_("abcabc"));
        try std.testing.expect(!try re.test_("abcdef"));
    }

    // Test backreference with quantifier
    {
        var re = try Regex.compile(std.testing.allocator, "(a+)\\1");
        defer re.deinit();

        try std.testing.expect(try re.test_("aa"));
        try std.testing.expect(try re.test_("aaaa"));
        try std.testing.expect(try re.test_("aaaaaa"));
        try std.testing.expect(!try re.test_("aaa")); // "aa" + "a" doesn't match
        try std.testing.expect(!try re.test_("ab"));
    }

    // Test empty capture
    {
        var re = try Regex.compile(std.testing.allocator, "(a?)\\1");
        defer re.deinit();

        try std.testing.expect(try re.test_("")); // empty + empty
        try std.testing.expect(try re.test_("aa")); // "a" + "a"
        try std.testing.expect(!try re.test_("a")); // "a" + empty doesn't work for full match
    }

    // Test case-sensitive backreference
    {
        var re = try Regex.compile(std.testing.allocator, "(.)\\1");
        defer re.deinit();

        try std.testing.expect(try re.test_("aa"));
        try std.testing.expect(try re.test_("AA"));
        try std.testing.expect(!try re.test_("aA")); // Case-sensitive
        try std.testing.expect(!try re.test_("Aa"));
    }

    // Test case-insensitive backreference
    {
        const options = CompileOptions{
            .case_insensitive = true,
        };
        var re = try Regex.compileWithOptions(std.testing.allocator, "(.)\\1", options);
        defer re.deinit();

        try std.testing.expect(try re.test_("aa"));
        try std.testing.expect(try re.test_("AA"));
        try std.testing.expect(try re.test_("aA")); // Case-insensitive!
        try std.testing.expect(try re.test_("Aa")); // Case-insensitive!
    }
}

test "Regex: lookahead assertions (?=...) and (?!...)" {
    // Test positive lookahead - basic
    {
        var re = try Regex.compile(std.testing.allocator, "foo(?=bar)");
        defer re.deinit();

        // "foobar" matches: "foo" is followed by "bar"
        const r1 = try re.find("foobar");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 0), r1.?.start);
        try std.testing.expectEqual(@as(usize, 3), r1.?.end); // Only matches "foo", not "bar"

        // "foobaz" doesn't match: "foo" is NOT followed by "bar"
        try std.testing.expect(null == try re.find("foobaz"));

        // "foo" alone doesn't match: nothing follows
        try std.testing.expect(null == try re.find("foo"));
    }

    // Test negative lookahead - basic
    {
        var re = try Regex.compile(std.testing.allocator, "foo(?!bar)");
        defer re.deinit();

        // "foobaz" matches: "foo" is NOT followed by "bar"
        const r1 = try re.find("foobaz");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 0), r1.?.start);
        try std.testing.expectEqual(@as(usize, 3), r1.?.end);

        // "foobar" doesn't match: "foo" IS followed by "bar"
        try std.testing.expect(null == try re.find("foobar"));

        // "foo" at end matches: nothing follows (not "bar")
        const r2 = try re.find("foo");
        try std.testing.expect(r2 != null);
        defer r2.?.deinit();
    }

    // Test lookahead doesn't consume input
    {
        var re = try Regex.compile(std.testing.allocator, "foo(?=bar)bar");
        defer re.deinit();

        // Should match "foobar": lookahead checks for "bar" but doesn't consume it
        try std.testing.expect(try re.test_("foobar"));

        // Should NOT match "foobaz"
        try std.testing.expect(!try re.test_("foobaz"));
    }

    // Test password validation: at least one digit
    {
        var re = try Regex.compile(std.testing.allocator, "(?=.*[0-9]).+");
        defer re.deinit();

        try std.testing.expect(try re.test_("pass123"));
        try std.testing.expect(try re.test_("1password"));
        try std.testing.expect(try re.test_("p4ssw0rd"));
        try std.testing.expect(!try re.test_("password"));
    }

    // Test multiple lookaheads
    {
        // Must contain digit AND letter
        var re = try Regex.compile(std.testing.allocator, "(?=.*[0-9])(?=.*[a-z]).+");
        defer re.deinit();

        try std.testing.expect(try re.test_("pass123"));
        try std.testing.expect(!try re.test_("123456")); // No letter
        try std.testing.expect(!try re.test_("password")); // No digit
    }

    // Test word boundaries with lookahead
    {
        // Match "test" only if NOT followed by "ing"
        var re = try Regex.compile(std.testing.allocator, "test(?!ing)");
        defer re.deinit();

        const r1 = try re.find("test");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();

        const r2 = try re.find("tester");
        try std.testing.expect(r2 != null);
        defer r2.?.deinit();

        try std.testing.expect(null == try re.find("testing"));
    }

    // Test lookahead with alternation
    {
        // Match "foo" followed by either "bar" or "baz"
        var re = try Regex.compile(std.testing.allocator, "foo(?=bar|baz)");
        defer re.deinit();

        const r1 = try re.find("foobar");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();

        const r2 = try re.find("foobaz");
        try std.testing.expect(r2 != null);
        defer r2.?.deinit();

        try std.testing.expect(null == try re.find("fooqux"));
    }

    // Test negative lookahead with simple pattern
    {
        // Match "foo" not followed by "x"
        var re = try Regex.compile(std.testing.allocator, "foo(?!x)");
        defer re.deinit();

        const r1 = try re.find("foobar");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 0), r1.?.start);
        try std.testing.expectEqual(@as(usize, 3), r1.?.end);

        const r2 = try re.find("foo");
        try std.testing.expect(r2 != null);
        defer r2.?.deinit();

        // "foox" should not match
        try std.testing.expect(null == try re.find("foox"));
    }
}

test "Regex: non-capturing groups (?:...)" {
    // Test 1: Basic non-capturing group doesn't create capture
    {
        var re = try Regex.compile(std.testing.allocator, "(?:hello) world");
        defer re.deinit();

        const r = try re.find("hello world");
        try std.testing.expect(r != null);
        defer r.?.deinit();

        // Should match the entire pattern
        try std.testing.expectEqual(@as(usize, 0), r.?.start);
        try std.testing.expectEqual(@as(usize, 11), r.?.end);

        // Should have no captures (only group 0 - the whole match)
        try std.testing.expect(r.?.getCapture(1, "hello world") == null);
    }

    // Test 2: Non-capturing group with quantifier
    {
        var re = try Regex.compile(std.testing.allocator, "(?:ab)+");
        defer re.deinit();

        // "ababab" should match
        try std.testing.expect(try re.test_("ababab"));

        const r1 = try re.find("ababab");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 0), r1.?.start);
        try std.testing.expectEqual(@as(usize, 6), r1.?.end);

        // "ab" should match
        try std.testing.expect(try re.test_("ab"));

        // "a" should not match
        try std.testing.expect(!try re.test_("a"));

        // "abc" should match "ab" part
        const r2 = try re.find("abc");
        try std.testing.expect(r2 != null);
        defer r2.?.deinit();
        try std.testing.expectEqual(@as(usize, 0), r2.?.start);
        try std.testing.expectEqual(@as(usize, 2), r2.?.end);
    }

    // Test 3: Non-capturing group with alternation
    {
        var re = try Regex.compile(std.testing.allocator, "(?:cat|dog)s");
        defer re.deinit();

        try std.testing.expect(try re.test_("cats"));
        try std.testing.expect(try re.test_("dogs"));
        try std.testing.expect(!try re.test_("cat"));
        try std.testing.expect(!try re.test_("dog"));
        try std.testing.expect(!try re.test_("birds"));
    }

    // Test 4: Mixed capturing and non-capturing groups
    {
        // Pattern: (?:https?:)//(\\w+)
        // Only the domain should be captured, not the protocol
        var re = try Regex.compile(std.testing.allocator, "(?:https?)://(\\w+)");
        defer re.deinit();

        const r1 = try re.find("http://example");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();

        // Group 0: Full match
        try std.testing.expectEqual(@as(usize, 0), r1.?.start);
        try std.testing.expectEqual(@as(usize, 14), r1.?.end);

        // Group 1: Should capture "example" (the \\w+)
        const capture1 = r1.?.getCapture(1, "http://example");
        try std.testing.expect(capture1 != null);
        try std.testing.expectEqualStrings("example", capture1.?);

        // The https? part is non-capturing, so group numbering starts at 1 for \\w+
        const r2 = try re.find("https://google");
        try std.testing.expect(r2 != null);
        defer r2.?.deinit();

        const capture2 = r2.?.getCapture(1, "https://google");
        try std.testing.expect(capture2 != null);
        try std.testing.expectEqualStrings("google", capture2.?);
    }

    // Test 5: Nested groups (capturing inside non-capturing)
    {
        var re = try Regex.compile(std.testing.allocator, "(?:(\\w+)@(\\w+))");
        defer re.deinit();

        const r = try re.find("user@example");
        try std.testing.expect(r != null);
        defer r.?.deinit();

        // Should capture both parts
        const c1 = r.?.getCapture(1, "user@example");
        try std.testing.expect(c1 != null);
        try std.testing.expectEqualStrings("user", c1.?);

        const c2 = r.?.getCapture(2, "user@example");
        try std.testing.expect(c2 != null);
        try std.testing.expectEqualStrings("example", c2.?);
    }

    // Test 6: Non-capturing group preserves group numbering
    {
        // Pattern: (a)(?:b)(c)
        // Group 1: a
        // Group 2: c  (not b, because (?:b) is non-capturing)
        var re = try Regex.compile(std.testing.allocator, "(a)(?:b)(c)");
        defer re.deinit();

        const r = try re.find("abc");
        try std.testing.expect(r != null);
        defer r.?.deinit();

        // Full match
        try std.testing.expectEqual(@as(usize, 0), r.?.start);
        try std.testing.expectEqual(@as(usize, 3), r.?.end);

        // Group 1: "a"
        const c1 = r.?.getCapture(1, "abc");
        try std.testing.expect(c1 != null);
        try std.testing.expectEqualStrings("a", c1.?);

        // Group 2: "c" (b is in non-capturing group)
        const c2 = r.?.getCapture(2, "abc");
        try std.testing.expect(c2 != null);
        try std.testing.expectEqualStrings("c", c2.?);

        // Group 3: Should not exist
        try std.testing.expect(r.?.getCapture(3, "abc") == null);
    }

    // Test 7: Multiple non-capturing groups
    {
        var re = try Regex.compile(std.testing.allocator, "(?:foo)(?:bar)(baz)");
        defer re.deinit();

        const r = try re.find("foobarbaz");
        try std.testing.expect(r != null);
        defer r.?.deinit();

        // Should only capture "baz"
        const c1 = r.?.getCapture(1, "foobarbaz");
        try std.testing.expect(c1 != null);
        try std.testing.expectEqualStrings("baz", c1.?);

        // No other captures
        try std.testing.expect(r.?.getCapture(2, "foobarbaz") == null);
    }

    // Test 8: Non-capturing group with backreference to capturing group
    {
        // Pattern: (a)(?:b)\\1
        // Group 1: a
        // (?:b) is non-capturing
        // \\1 refers to group 1 (a)
        var re = try Regex.compile(std.testing.allocator, "(a)(?:b)\\1");
        defer re.deinit();

        try std.testing.expect(try re.test_("aba"));
        try std.testing.expect(!try re.test_("abb"));
        try std.testing.expect(!try re.test_("abc"));
    }
}

test "Regex: lookbehind assertions (?<=...) and (?<!...)" {
    // Test 1: Basic positive lookbehind
    {
        // Match digits preceded by $
        var re = try Regex.compile(std.testing.allocator, "(?<=\\$)\\d+");
        defer re.deinit();

        // "Price: $100" should match "100"
        const r1 = try re.find("Price: $100");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 8), r1.?.start); // Position after $
        try std.testing.expectEqual(@as(usize, 11), r1.?.end);

        // "100" without $ should not match
        try std.testing.expect(null == try re.find("Price: 100"));

        // "$50" should match
        const r2 = try re.find("$50");
        try std.testing.expect(r2 != null);
        defer r2.?.deinit();
        try std.testing.expectEqual(@as(usize, 1), r2.?.start);
        try std.testing.expectEqual(@as(usize, 3), r2.?.end);
    }

    // Test 2: Basic negative lookbehind
    {
        // Match digits NOT preceded by $
        var re = try Regex.compile(std.testing.allocator, "(?<!\\$)\\d+");
        defer re.deinit();

        // "Price: 100" should match
        const r1 = try re.find("Price: 100");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();

        // "$100" - the '1' IS preceded by $, so it won't match
        // But '0' at position 2 is NOT preceded by $ (preceded by '1')
        // So the pattern will match "00"
        const r2 = try re.find("$100");
        try std.testing.expect(r2 != null);
        defer r2.?.deinit();
        try std.testing.expectEqual(@as(usize, 2), r2.?.start); // Starts at second '0'
        try std.testing.expectEqual(@as(usize, 4), r2.?.end); // Matches "00"

        // "Cost: 50 items" should match "50"
        const r3 = try re.find("Cost: 50 items");
        try std.testing.expect(r3 != null);
        defer r3.?.deinit();
    }

    // Test 3: Lookbehind with literal text
    {
        // Match "world" preceded by "hello "
        var re = try Regex.compile(std.testing.allocator, "(?<=hello )\\w+");
        defer re.deinit();

        // "hello world" should match "world"
        const r1 = try re.find("hello world");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 6), r1.?.start);
        try std.testing.expectEqual(@as(usize, 11), r1.?.end);

        // "hi world" should not match
        try std.testing.expect(null == try re.find("hi world"));

        // "world" alone should not match
        try std.testing.expect(null == try re.find("world"));
    }

    // Test 4: Lookbehind is zero-width (doesn't consume)
    {
        // Pattern includes lookbehind and the character it checks for
        var re = try Regex.compile(std.testing.allocator, "(?<=@)\\w+");
        defer re.deinit();

        // "user@example" should match "example"
        const r1 = try re.find("user@example");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 5), r1.?.start); // After @
        try std.testing.expectEqual(@as(usize, 12), r1.?.end);
    }

    // Test 5: Negative lookbehind with specific character
    {
        // Match word NOT preceded by @
        var re = try Regex.compile(std.testing.allocator, "(?<!@)\\w+");
        defer re.deinit();

        // "hello" should match (not preceded by @)
        const r1 = try re.find("hello");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();

        // "user@example" - "user" should match, "example" should not
        const r2 = try re.find("user@example");
        try std.testing.expect(r2 != null);
        defer r2.?.deinit();
        // Should match "user" (starts at 0)
        try std.testing.expectEqual(@as(usize, 0), r2.?.start);
    }

    // Test 6: Lookbehind with character class
    {
        // Match digits preceded by any letter
        var re = try Regex.compile(std.testing.allocator, "(?<=[a-z])\\d+");
        defer re.deinit();

        // "abc123" should match "123"
        const r1 = try re.find("abc123");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 3), r1.?.start);
        try std.testing.expectEqual(@as(usize, 6), r1.?.end);

        // "123" alone should not match
        try std.testing.expect(null == try re.find("123"));

        // "ABC123" (uppercase) should not match
        try std.testing.expect(null == try re.find("ABC123"));
    }

    // Test 7: Multiple matches with lookbehind
    {
        // Match word boundaries with lookbehind
        var re = try Regex.compile(std.testing.allocator, "(?<=,)\\w+");
        defer re.deinit();

        // "a,b,c" should match "b" and "c"
        const r1 = try re.find("a,b,c");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 2), r1.?.start); // First match is "b"
        try std.testing.expectEqual(@as(usize, 3), r1.?.end);

        // "abc" (no commas) should not match
        try std.testing.expect(null == try re.find("abc"));
    }

    // Test 8: Combining lookahead and lookbehind
    {
        // Match digit preceded by $ and followed by space
        var re = try Regex.compile(std.testing.allocator, "(?<=\\$)\\d+(?= )");
        defer re.deinit();

        // "$100 total" should match "100"
        const r1 = try re.find("$100 total");
        try std.testing.expect(r1 != null);
        defer r1.?.deinit();
        try std.testing.expectEqual(@as(usize, 1), r1.?.start);
        try std.testing.expectEqual(@as(usize, 4), r1.?.end);

        // "$100" (no space after) should not match
        try std.testing.expect(null == try re.find("$100"));

        // "100 " (no $ before) should not match
        try std.testing.expect(null == try re.find("100 "));
    }
}

test "Regex: lazy counted quantifiers {n,m}?" {
    const allocator = std.testing.allocator;

    // Test 1: a{2,4}? should match minimum (2) vs greedy a{2,4} matches maximum (4)
    {
        // Lazy version - should match exactly 2 'a's
        var re_lazy = try Regex.compile(allocator, "a{2,4}?");
        defer re_lazy.deinit();

        const result = try re_lazy.find("aaaa");
        try std.testing.expect(result != null);
        defer if (result) |r| r.deinit();

        if (result) |r| {
            try std.testing.expectEqual(@as(usize, 0), r.start);
            try std.testing.expectEqual(@as(usize, 2), r.end); // Matches "aa" (minimum)
        }

        // Greedy version - should match all 4 'a's
        var re_greedy = try Regex.compile(allocator, "a{2,4}");
        defer re_greedy.deinit();

        const result2 = try re_greedy.find("aaaa");
        try std.testing.expect(result2 != null);
        defer if (result2) |r| r.deinit();

        if (result2) |r| {
            try std.testing.expectEqual(@as(usize, 0), r.start);
            try std.testing.expectEqual(@as(usize, 4), r.end); // Matches "aaaa" (maximum)
        }
    }

    // Test 2: a{2,}? should match minimum (2) in unbounded case
    {
        var re = try Regex.compile(allocator, "a{2,}?");
        defer re.deinit();

        const result = try re.find("aaaaaa");
        try std.testing.expect(result != null);
        defer if (result) |r| r.deinit();

        if (result) |r| {
            try std.testing.expectEqual(@as(usize, 0), r.start);
            try std.testing.expectEqual(@as(usize, 2), r.end); // Matches "aa" (minimum)
        }
    }

    // Test 3: Lazy repeat in context - match as little as possible
    {
        // Pattern: .{1,10}? should match minimally before 'x'
        var re = try Regex.compile(allocator, ".{1,10}?x");
        defer re.deinit();

        const result = try re.find("abcdefx");
        try std.testing.expect(result != null);
        defer if (result) |r| r.deinit();

        if (result) |r| {
            try std.testing.expectEqual(@as(usize, 0), r.start);
            try std.testing.expectEqual(@as(usize, 7), r.end); // Matches "abcdefx" (all chars needed to reach 'x')
        }
    }

    // Test 4: Lazy repeat with exact count a{3}? (should be same as a{3})
    {
        var re = try Regex.compile(allocator, "a{3}?");
        defer re.deinit();

        const result = try re.find("aaaaa");
        try std.testing.expect(result != null);
        defer if (result) |r| r.deinit();

        if (result) |r| {
            try std.testing.expectEqual(@as(usize, 0), r.start);
            try std.testing.expectEqual(@as(usize, 3), r.end); // Must match exactly 3
        }
    }

    // Test 5: Lazy quantifier with character class
    {
        var re = try Regex.compile(allocator, "[a-z]{2,5}?");
        defer re.deinit();

        const result = try re.find("abcdef");
        try std.testing.expect(result != null);
        defer if (result) |r| r.deinit();

        if (result) |r| {
            try std.testing.expectEqual(@as(usize, 0), r.start);
            try std.testing.expectEqual(@as(usize, 2), r.end); // Matches "ab" (minimum)
        }
    }

    // Test 6: Multiple lazy quantifiers in sequence
    {
        // With input "abbb", lazy quantifiers should match "ab" (1 'a' + 1 'b')
        var re = try Regex.compile(allocator, "a{1,3}?b{1,3}?");
        defer re.deinit();

        const result = try re.find("abbb");
        try std.testing.expect(result != null);
        defer if (result) |r| r.deinit();

        if (result) |r| {
            try std.testing.expectEqual(@as(usize, 0), r.start);
            try std.testing.expectEqual(@as(usize, 2), r.end); // Matches "ab" (both minimal)
        }
    }

    // Test 7: Lazy quantifier with digits
    {
        var re = try Regex.compile(allocator, "\\d{2,4}?");
        defer re.deinit();

        const result = try re.find("12345");
        try std.testing.expect(result != null);
        defer if (result) |r| r.deinit();

        if (result) |r| {
            try std.testing.expectEqual(@as(usize, 0), r.start);
            try std.testing.expectEqual(@as(usize, 2), r.end); // Matches "12" (minimum)
        }
    }

    // Test 8: Lazy unbounded with following pattern
    {
        // With "aab", lazy should match minimum 2 'a's + 'b'
        var re = try Regex.compile(allocator, "a{2,}?b");
        defer re.deinit();

        const result = try re.find("aab");
        try std.testing.expect(result != null);
        defer if (result) |r| r.deinit();

        if (result) |r| {
            try std.testing.expectEqual(@as(usize, 0), r.start);
            try std.testing.expectEqual(@as(usize, 3), r.end); // Matches "aab" (2 'a's + 'b')
        }
    }
}

test "Regex: multiline flag makes ^ and $ match line boundaries" {
    const allocator = std.testing.allocator;

    {
        var re = try Regex.compileWithOptions(allocator, "^b", .{ .multiline = true });
        defer re.deinit();
        const result = try re.find("a\nb");
        defer if (result) |r| r.deinit();
        try std.testing.expect(result != null);
    }
    {
        // Without multiline, ^ only matches the absolute start of the string
        var re = try Regex.compileWithOptions(allocator, "^b", .{ .multiline = false });
        defer re.deinit();
        const result = try re.find("a\nb");
        defer if (result) |r| r.deinit();
        try std.testing.expect(result == null);
    }
    {
        var re = try Regex.compileWithOptions(allocator, "a$", .{ .multiline = true });
        defer re.deinit();
        const result = try re.find("a\nb");
        defer if (result) |r| r.deinit();
        try std.testing.expect(result != null);
    }
    {
        // Basic (non-multiline) anchors must still behave as before
        var re = try Regex.compile(allocator, "^hello$");
        defer re.deinit();
        try std.testing.expect(try re.test_("hello"));
        try std.testing.expect(!try re.test_("hello world"));
    }
}

test "Regex: dot excludes newline unless dot_all is set" {
    const allocator = std.testing.allocator;

    {
        var re = try Regex.compile(allocator, "a.b");
        defer re.deinit();
        try std.testing.expect(!try re.test_("a\nb"));
        try std.testing.expect(try re.test_("axb"));
    }
    {
        var re = try Regex.compileWithOptions(allocator, "a.b", .{ .dot_all = true });
        defer re.deinit();
        try std.testing.expect(try re.test_("a\nb"));
    }
}

test "Regex: \\xHH, \\uHHHH, \\u{...}, \\0 and \\cX escapes" {
    const allocator = std.testing.allocator;

    {
        var re = try Regex.compile(allocator, "\\x41");
        defer re.deinit();
        try std.testing.expect(try re.test_("A"));
        try std.testing.expect(!try re.test_("x41"));
    }
    {
        var re = try Regex.compile(allocator, "\\u0041");
        defer re.deinit();
        try std.testing.expect(try re.test_("A"));
    }
    {
        // \u{E9} is 'é', 2 UTF-8 bytes -- must match as a single atomic unit
        var re = try Regex.compile(allocator, "\\u{E9}");
        defer re.deinit();
        try std.testing.expect(try re.test_("\u{E9}"));
    }
    {
        // \u{1F600} is an emoji, 4 UTF-8 bytes
        var re = try Regex.compile(allocator, "\\u{1F600}");
        defer re.deinit();
        try std.testing.expect(try re.test_("\u{1F600}"));
    }
    {
        var re = try Regex.compile(allocator, "\\cA");
        defer re.deinit();
        try std.testing.expect(try re.test_("\x01"));
    }
    {
        var re = try Regex.compile(allocator, "\\0");
        defer re.deinit();
        try std.testing.expect(try re.test_("\x00"));
        try std.testing.expect(!try re.test_("0"));
    }
}

test "Regex: invalid quantifier range {n,m} with n > m is rejected" {
    try std.testing.expectError(
        error.InvalidQuantifier,
        Regex.compile(std.testing.allocator, "a{2,1}"),
    );
}

test "Regex: literal multi-byte UTF-8 character quantifies as one atomic unit" {
    const allocator = std.testing.allocator;

    // 'é' is 2 UTF-8 bytes (0xC3 0xA9). '+' must repeat the whole character,
    // not just its last byte.
    {
        var re = try Regex.compile(allocator, "\u{E9}+");
        defer re.deinit();
        try std.testing.expect(try re.test_("\u{E9}\u{E9}\u{E9}"));
    }
    {
        // Must not match a stray continuation byte as if it were another 'é'.
        var re = try Regex.compile(allocator, "^\u{E9}+$");
        defer re.deinit();
        try std.testing.expect(!try re.test_("\u{E9}\xa9\xa9"));
    }
}

test "Regex: dot consumes one Unicode scalar value, not one byte" {
    const allocator = std.testing.allocator;

    {
        var re = try Regex.compile(allocator, "^.$");
        defer re.deinit();
        try std.testing.expect(try re.test_("\u{E9}")); // 'é', 2 bytes: one dot, one match
    }
    {
        var re = try Regex.compile(allocator, "^..$");
        defer re.deinit();
        try std.testing.expect(!try re.test_("\u{E9}")); // one character, not two
    }
    {
        var re = try Regex.compile(allocator, "^.$");
        defer re.deinit();
        try std.testing.expect(try re.test_("\u{1F600}")); // emoji, 4 bytes
    }
}

test "Regex: negated character classes consume one Unicode scalar value" {
    const allocator = std.testing.allocator;

    {
        var re = try Regex.compile(allocator, "^\\W$");
        defer re.deinit();
        try std.testing.expect(try re.test_("\u{E9}"));
    }
    {
        var re = try Regex.compile(allocator, "^\\W\\W$");
        defer re.deinit();
        try std.testing.expect(!try re.test_("\u{E9}"));
    }
    {
        var re = try Regex.compile(allocator, "^[^a-z]$");
        defer re.deinit();
        try std.testing.expect(try re.test_("\u{E9}"));
    }
}

test "Regex: multi-byte character inside a character class (Phase 3)" {
    // [é] needed Unicode-aware character class ranges (added in Phase 3);
    // it now matches the whole 2-byte character as a single class member,
    // rather than being rejected or silently split into raw bytes.
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[\u{E9}]");
    defer re.deinit();
    try std.testing.expect(try re.test_("\u{E9}"));
    try std.testing.expect(!try re.test_("a"));
}

test "Regex: literal '-' outside a character class" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "555-1234");
    defer re.deinit();
    try std.testing.expect(try re.test_("555-1234"));

    // Character class ranges must still work (regression check)
    var re2 = try Regex.compile(allocator, "^[a-z]+$");
    defer re2.deinit();
    try std.testing.expect(try re2.test_("hello"));
}

test "Regex: named capture groups" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(?<year>\\d+)-(?<month>\\d+)");
    defer re.deinit();

    const input = "2026-07";
    const m = (try re.find(input)).?;
    defer m.deinit();

    try std.testing.expectEqualStrings("2026", m.getNamedCapture("year", input).?);
    try std.testing.expectEqualStrings("07", m.getNamedCapture("month", input).?);
    // Named groups are still numbered like ordinary groups
    try std.testing.expectEqualStrings("2026", m.getCapture(1, input).?);
    try std.testing.expect(m.getNamedCapture("nonexistent", input) == null);
}

test "Regex: named groups mixed with unnamed groups keep correct indices" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(a)(?<b>b)(c)");
    defer re.deinit();

    const input = "abc";
    const m = (try re.find(input)).?;
    defer m.deinit();

    try std.testing.expectEqualStrings("a", m.getCapture(1, input).?);
    try std.testing.expectEqualStrings("b", m.getNamedCapture("b", input).?);
    try std.testing.expectEqualStrings("c", m.getCapture(3, input).?);
}

test "Regex: getNamedCapture on a pattern with no named groups returns null" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(a)(b)");
    defer re.deinit();

    const input = "ab";
    const m = (try re.find(input)).?;
    defer m.deinit();

    try std.testing.expect(m.getNamedCapture("x", input) == null);
}

test "Regex: named backreference \\k<name>" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(?<word>\\w+) \\k<word>");
    defer re.deinit();

    try std.testing.expect(try re.test_("hello hello"));
    try std.testing.expect(!try re.test_("hello world"));
}

test "Regex: bare \\k without <name> falls back to a literal 'k'" {
    var re = try Regex.compile(std.testing.allocator, "\\k");
    defer re.deinit();
    try std.testing.expect(try re.test_("k"));
}

test "Regex: duplicate named groups are rejected" {
    try std.testing.expectError(
        error.DuplicateGroupName,
        Regex.compile(std.testing.allocator, "(?<x>a)(?<x>b)"),
    );
}

test "Regex: duplicate named groups in mutually exclusive alternation branches are allowed" {
    const allocator = std.testing.allocator;

    // JS's exception to "duplicate group names are a SyntaxError": allowed
    // when every occurrence is in a different, mutually exclusive branch of
    // the same alternation (at most one can ever actually capture).
    var re = try Regex.compile(allocator, "(?<x>a)|(?<x>b)");
    defer re.deinit();

    const m1 = (try re.find("a")).?;
    defer m1.deinit();
    try std.testing.expectEqualStrings("a", m1.getNamedCapture("x", "a").?);

    const m2 = (try re.find("b")).?;
    defer m2.deinit();
    try std.testing.expectEqualStrings("b", m2.getNamedCapture("x", "b").?);
}

test "Regex: duplicate named groups allowed across a flat 3-way alternation" {
    const allocator = std.testing.allocator;

    // a|b|c is one flat disjunction in JS terms (all three branches
    // pairwise mutually exclusive), even though it's represented as nested
    // binary alternation nodes internally.
    var re = try Regex.compile(allocator, "(?<x>a)|(?<x>b)|(?<x>c)");
    defer re.deinit();

    try std.testing.expect(try re.test_("a"));
    try std.testing.expect(try re.test_("b"));
    try std.testing.expect(try re.test_("c"));
}

test "Regex: duplicate named groups in nested groups under exclusive branches are allowed" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "((?<x>a)c)|((?<x>b)d)");
    defer re.deinit();

    const m = (try re.find("bd")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("b", m.getNamedCapture("x", "bd").?);
}

test "Regex: duplicate named groups nested inside groups (not alternated) are still rejected" {
    const allocator = std.testing.allocator;

    // Two named groups reachable together (no alternation separates them),
    // just each wrapped in its own extra non-capturing structure -- must
    // still conflict, same as the flat sequential case.
    try std.testing.expectError(
        error.DuplicateGroupName,
        Regex.compile(allocator, "((?<x>a))((?<x>b))"),
    );
}

test "Regex: duplicate named groups in the same alternation branch are still rejected" {
    const allocator = std.testing.allocator;

    // Both occurrences of x are inside the *same* left branch of the top-level
    // `|` -- the presence of a `|` somewhere in the pattern isn't enough on
    // its own; the two groups specifically need to be in different branches
    // of a *shared* alternation ancestor.
    try std.testing.expectError(
        error.DuplicateGroupName,
        Regex.compile(allocator, "((?<x>a)(?<x>b))|c"),
    );
}

test "Regex: getNamedCapture finds whichever duplicate-named group actually participated" {
    const allocator = std.testing.allocator;

    // Regression test for a real bug this feature exposed: getNamedCapture
    // used to return as soon as it found the *first* named_groups entry
    // with a matching name, regardless of whether that specific group
    // participated in this match -- when x's *second* declaration (branch
    // b) is the one that actually captured, looking up "x" needs to find
    // it, not stop at x's first (branch a) declaration and see "didn't
    // participate" there.
    var re = try Regex.compile(allocator, "(?<x>a)|(?<x>b)");
    defer re.deinit();

    const m = (try re.find("b")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("b", m.getNamedCapture("x", "b").?);
}

test "Regex: $<name> replacement finds whichever duplicate-named group actually participated" {
    const allocator = std.testing.allocator;

    // Same bug, different call site: Regex.replace's $<name> substitution
    // had the identical "stop at the first same-named entry" mistake.
    var re = try Regex.compile(allocator, "(?<x>a)|(?<x>b)");
    defer re.deinit();

    const result = try re.replace(allocator, "b", "[$<x>]");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[b]", result);
}

test "Regex: unknown named backreference is rejected" {
    try std.testing.expectError(
        error.UnknownGroupName,
        Regex.compile(std.testing.allocator, "\\k<nope>"),
    );
}

test "Regex: character class range with multi-byte endpoints" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[\u{1F600}-\u{1F64F}]");
    defer re.deinit();
    try std.testing.expect(try re.test_("\u{1F600}")); // range start
    try std.testing.expect(try re.test_("\u{1F64F}")); // range end
    try std.testing.expect(!try re.test_("\u{1F650}")); // just past the end
    try std.testing.expect(!try re.test_("a"));
}

test "Regex: character class mixing ASCII and multi-byte members" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[a\u{E9}]");
    defer re.deinit();
    try std.testing.expect(try re.test_("a"));
    try std.testing.expect(try re.test_("\u{E9}"));
    try std.testing.expect(!try re.test_("b"));
}

test "Regex: negated character class with multi-byte range" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "^[^\u{1F600}-\u{1F64F}]$");
    defer re.deinit();
    try std.testing.expect(try re.test_("a"));
    try std.testing.expect(!try re.test_("\u{1F600}"));
}

test "Regex: quantifiers on a multi-byte character class" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "^[\u{E9}\u{E8}]+$");
    defer re.deinit();
    try std.testing.expect(try re.test_("\u{E9}\u{E8}\u{E9}"));
    try std.testing.expect(!try re.test_("\u{E9}a"));
}

test "Regex: character class with more than MAX_CLASS_RANGES multi-byte members is rejected" {
    // 9 distinct multi-byte single-char members; MAX_CLASS_RANGES is 8.
    try std.testing.expectError(
        error.TooManyRanges,
        Regex.compile(std.testing.allocator, "[\u{1F600}\u{1F601}\u{1F602}\u{1F603}\u{1F604}\u{1F605}\u{1F606}\u{1F607}\u{1F608}]"),
    );
}

test "Regex: sticky flag only matches at the current position" {
    const allocator = std.testing.allocator;

    // Non-sticky: scans forward and finds the match anywhere.
    {
        var re = try Regex.compile(allocator, "world");
        defer re.deinit();
        const m = try re.find("hello world");
        defer if (m) |mm| mm.deinit();
        try std.testing.expect(m != null);
    }
    // Sticky: fails because the match isn't at position 0.
    {
        var re = try Regex.compileWithOptions(allocator, "world", .{ .sticky = true });
        defer re.deinit();
        const m = try re.find("hello world");
        try std.testing.expect(m == null);
    }
    // Sticky: succeeds when the match is exactly at position 0.
    {
        var re = try Regex.compileWithOptions(allocator, "hello", .{ .sticky = true });
        defer re.deinit();
        const m = try re.find("hello world");
        defer if (m) |mm| mm.deinit();
        try std.testing.expect(m != null);
    }
}

test "Regex: findAt matches at an exact position with no scanning" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\d+");
    defer re.deinit();
    const input = "12 34";

    const m1 = try re.findAt(input, 0);
    defer if (m1) |mm| mm.deinit();
    try std.testing.expectEqualStrings("12", m1.?.group(input));

    // No digit at position 2 (a space) -- findAt must not scan ahead to "34"
    const m2 = try re.findAt(input, 2);
    try std.testing.expect(m2 == null);

    const m3 = try re.findAt(input, 3);
    defer if (m3) |mm| mm.deinit();
    try std.testing.expectEqualStrings("34", m3.?.group(input));
}

test "Regex: sticky findAll stops at the first gap instead of scanning ahead" {
    const allocator = std.testing.allocator;

    var sticky_re = try Regex.compileWithOptions(allocator, "\\d", .{ .sticky = true });
    defer sticky_re.deinit();
    var sticky_matches = try sticky_re.findAll("123ab456");
    defer {
        for (sticky_matches.items) |m| m.deinit();
        sticky_matches.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 3), sticky_matches.items.len);

    var re = try Regex.compile(allocator, "\\d");
    defer re.deinit();
    var matches = try re.findAll("123ab456");
    defer {
        for (matches.items) |m| m.deinit();
        matches.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 6), matches.items.len);
}

test "Regex: getCaptureIndices and getNamedCaptureIndices" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(?<year>\\d+)-(\\d+)");
    defer re.deinit();
    const input = "2026-07";
    const m = (try re.find(input)).?;
    defer m.deinit();

    const idx1 = m.getCaptureIndices(1).?;
    try std.testing.expectEqual(@as(usize, 0), idx1.start);
    try std.testing.expectEqual(@as(usize, 4), idx1.end);

    const idx_year = m.getNamedCaptureIndices("year").?;
    try std.testing.expectEqual(idx1.start, idx_year.start);
    try std.testing.expectEqual(idx1.end, idx_year.end);

    try std.testing.expect(m.getCaptureIndices(99) == null);
    try std.testing.expect(m.getNamedCaptureIndices("nonexistent") == null);
}

test "Regex: regex metacharacters are literal inside a character class" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[*&$.^+?(){}|]");
    defer re.deinit();
    for ("*&$.^+?(){}|") |c| {
        try std.testing.expect(try re.test_(&[_]u8{c}));
    }
    try std.testing.expect(!try re.test_("a"));

    // '.' inside a class must stay a literal dot, not "any character".
    var dot_re = try Regex.compile(allocator, "[.]");
    defer dot_re.deinit();
    try std.testing.expect(try dot_re.test_("."));
    try std.testing.expect(!try dot_re.test_("x"));
}

test "Regex: shorthand classes as character class members" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[a-c\\d]");
    defer re.deinit();
    try std.testing.expect(try re.test_("a"));
    try std.testing.expect(try re.test_("c"));
    try std.testing.expect(try re.test_("5"));
    try std.testing.expect(!try re.test_("z"));

    // A negated shorthand as a class member contributes its own complement,
    // not a flip of the whole enclosing class.
    var neg_re = try Regex.compile(allocator, "[\\D]");
    defer neg_re.deinit();
    try std.testing.expect(try neg_re.test_("x"));
    try std.testing.expect(!try neg_re.test_("5"));
}

test "Regex: [^] (negated empty class) matches any character" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[^]");
    defer re.deinit();
    try std.testing.expect(try re.test_("x"));
    try std.testing.expect(try re.test_("\n"));
    try std.testing.expect(try re.test_("\x00"));

    // Non-inverted empty class remains a compile error.
    try std.testing.expectError(error.EmptyCharClass, Regex.compile(allocator, "[]"));
}

test "Regex: \\s and \\S include form feed and vertical tab" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\s");
    defer re.deinit();
    try std.testing.expect(try re.test_("\x0c")); // \f
    try std.testing.expect(try re.test_("\x0b")); // \v

    var not_re = try Regex.compile(allocator, "\\S");
    defer not_re.deinit();
    try std.testing.expect(!try not_re.test_("\x0c"));
    try std.testing.expect(!try not_re.test_("\x0b"));
}

test "Regex: replace() replaces only the first match" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\d+");
    defer re.deinit();

    const result = try re.replace(allocator, "a1 b22 c333", "X");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("aX b22 c333", result);
}

test "Regex: replace() with no match returns a copy of the input" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\d+");
    defer re.deinit();

    const result = try re.replace(allocator, "no digits here", "X");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("no digits here", result);
}

test "Regex: replaceAll() replaces every match" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\d+");
    defer re.deinit();

    const result = try re.replaceAll(allocator, "a1 b22 c333", "X");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("aX bX cX", result);
}

test "Regex: replaceAll() with no matches returns a copy of the input" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\d+");
    defer re.deinit();

    const result = try re.replaceAll(allocator, "no digits here", "X");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("no digits here", result);
}

test "Regex: free-function replace and replaceAll convenience wrappers" {
    const allocator = std.testing.allocator;

    const r1 = try replace(allocator, "\\d+", "a1 b22", "X");
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("aX b22", r1);

    const r2 = try replaceAll(allocator, "\\d+", "a1 b22", "X");
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("aX bX", r2);
}

test "Regex: case_insensitive character ranges match both cases (test262 S15.10.2.8_A5_T1)" {
    const allocator = std.testing.allocator;

    var re = try Regex.compileWithOptions(allocator, "[a-z]+", .{ .case_insensitive = true });
    defer re.deinit();

    const m = (try re.find("ABC def ghi")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("ABC", m.group("ABC def ghi"));
}

test "Regex: case_insensitive negated character class matches both cases (test262 S15.10.2.6_A3_T7)" {
    const allocator = std.testing.allocator;

    var re = try Regex.compileWithOptions(allocator, "[^o]t\\b", .{ .case_insensitive = true });
    defer re.deinit();

    const input = "pilOt\nsoviet robot\topenoffice";
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("et", m.group(input));
}

test "Regex: \\b inside a character class means backspace, not word boundary (test262 S15.10.2.13_A3_T1)" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, ".[\\b].");
    defer re.deinit();

    const input = "abc\x08def";
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("c\x08d", m.group(input));
}

test "Regex: [^\\b] excludes only backspace, matches everything else (test262 S15.10.2.13_A2_T4)" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[^\\b]+");
    defer re.deinit();

    const input = "easy\x08to\x08ride";
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("easy", m.group(input));
}

test "Regex: a quantified capturing group retains its last iteration's capture (test262 S15.10.2.7_A6_T4)" {
    const allocator = std.testing.allocator;

    // Before the SAVE_START/SAVE_END rollback fix, the loop's final
    // (failed) attempt at a 3rd repetition mutated captures[1] and never
    // rolled the mutation back, leaving the capture empty instead of "123".
    var re = try Regex.compile(allocator, "(123){1,}");
    defer re.deinit();

    const m = (try re.find("123123")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("123123", m.group("123123"));
    try std.testing.expectEqualStrings("123", m.getCapture(1, "123123").?);
}

test "Regex: backreference to a group repeated via {1,} sees the last iteration's capture (test262 S15.10.2.7_A6_T5)" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(123){1,}x\\1");
    defer re.deinit();

    const m = (try re.find("123123x123")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("123123x123", m.group("123123x123"));
}

test "Regex: `*` on a capturing group is greedy (test262-style, was matching zero reps)" {
    const allocator = std.testing.allocator;

    // Before the generateStar branch-order fix, `(a)*` compiled to
    // literally non-greedy bytecode ("try zero reps first"); since zero
    // reps always trivially succeeds for `*`, an unanchored search never
    // even tried consuming, matching an empty string at position 0.
    var re = try Regex.compile(allocator, "(a)*");
    defer re.deinit();

    const m = (try re.find("aa")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("aa", m.group("aa"));
    try std.testing.expectEqualStrings("a", m.getCapture(1, "aa").?);
}

test "Regex: `?` on a capturing group prefers to consume when it can (test262 S15.10.2.7_A5_T1)" {
    const allocator = std.testing.allocator;

    // Before the generateQuestion branch-order fix, `(script)?` always
    // preferred to skip whenever skipping alone already produced *some*
    // successful overall match, even though consuming would too (and JS's
    // greedy `?` always prefers to consume in that case).
    var re = try Regex.compile(allocator, "java(script)?");
    defer re.deinit();

    const input = "state: javascript is extension of ecma script";
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("javascript", m.group(input));
    try std.testing.expectEqualStrings("script", m.getCapture(1, input).?);
}

test "Regex: `(A)?(A.*)` prefers consuming the optional group (test262 S15.10.2.8_A3_T21)" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "^(A)?(A.*)$");
    defer re.deinit();

    const m = (try re.find("AA")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("AA", m.group("AA"));
    try std.testing.expectEqualStrings("A", m.getCapture(1, "AA").?);
    try std.testing.expectEqualStrings("A", m.getCapture(2, "AA").?);
}

test "Regex: lazy star `.*?` can expand across multiple iterations (was stuck after one)" {
    const allocator = std.testing.allocator;

    // Before the matchStarLazy fix, the zero-width-progress guard compared
    // `matched.end_pos` against `current_pos` *after* current_pos was
    // already overwritten, making the check trivially always true and
    // capping the loop at exactly one iteration.
    var re = try Regex.compile(allocator, "^.*?$");
    defer re.deinit();

    const m = (try re.find("Hello World")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("Hello World", m.group("Hello World"));
}

test "Regex: an optional group nested in a repeated group doesn't leak a stale capture across iterations (test262 S15.10.2.5_A1_T4)" {
    const allocator = std.testing.allocator;

    // On the 3rd iteration of the outer `*`, `(b+)?` correctly declines to
    // match (no 'b's left) -- its capture must read back as null for this
    // overall match, not the "bbb" a *previous* iteration captured.
    var re = try Regex.compile(allocator, "(z)((a+)?(b+)?(c))*");
    defer re.deinit();

    const input = "zaacbbbcac";
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings(input, m.group(input));
    try std.testing.expectEqualStrings("z", m.getCapture(1, input).?);
    try std.testing.expectEqualStrings("ac", m.getCapture(2, input).?);
    try std.testing.expectEqualStrings("a", m.getCapture(3, input).?);
    try std.testing.expect(m.getCapture(4, input) == null);
    try std.testing.expectEqualStrings("c", m.getCapture(5, input).?);
}

test "Regex: a backreference to a group that never participated matches empty (spec, not a failure)" {
    const allocator = std.testing.allocator;

    // Per ECMAScript, \1 referencing a group that didn't participate in
    // the match (here, the `(a)?` branch was never taken) always succeeds
    // as an empty-string match -- it must not fail the whole pattern.
    var re = try Regex.compile(allocator, "(a)?\\1b");
    defer re.deinit();

    const m = (try re.find("b")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("b", m.group("b"));
    try std.testing.expect(m.getCapture(1, "b") == null);
}

test "Regex: a negative lookahead's own captures don't leak out, whether it succeeds or fails (test262 S15.10.2.8_A2_T1)" {
    const allocator = std.testing.allocator;

    // `(a+)` inside the negative lookahead genuinely succeeds as a raw
    // sub-match in an earlier, abandoned attempt (making that attempt's
    // assertion fail); per spec, none of that should be observable once
    // the outer `(.*?)` backtracks to a position where the assertion
    // actually holds -- capture 2 must read back null, not the leaked
    // value from the earlier failed attempt.
    var re = try Regex.compile(allocator, "(.*?)a(?!(a+)b\\2c)\\2(.*)");
    defer re.deinit();

    const input = "baaabaac";
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings(input, m.group(input));
    try std.testing.expectEqualStrings("ba", m.getCapture(1, input).?);
    try std.testing.expect(m.getCapture(2, input) == null);
    try std.testing.expectEqualStrings("abaac", m.getCapture(3, input).?);
}

test "Regex: a positive lookahead's captures leak out on success (spec'd behavior)" {
    const allocator = std.testing.allocator;

    // Unlike negative lookahead, a *positive* lookahead that succeeds is
    // spec'd to leave its captures observable afterward.
    var re = try Regex.compile(allocator, "(?=(a))");
    defer re.deinit();

    const m = (try re.find("a")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("a", m.getCapture(1, "a").?);
}

test "Regex: \\p{L}+ matches Unicode letters, including non-ASCII, and stops at non-letters" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{L}+");
    defer re.deinit();

    const m = (try re.find("h\u{E9}llo123")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("h\u{E9}llo", m.group("h\u{E9}llo123"));
}

test "Regex: \\p{N}+ matches Unicode digits" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{N}+");
    defer re.deinit();

    const m = (try re.find("abc4567def")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("4567", m.group("abc4567def"));
}

test "Regex: \\P{L} (negated Unicode property) matches non-letters" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\P{L}+");
    defer re.deinit();

    const m = (try re.find("abc!!!def")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("!!!", m.group("abc!!!def"));
}

test "Regex: \\p{Lu} matches only uppercase letters" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{Lu}");
    defer re.deinit();

    const m = (try re.find("aB")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("B", m.group("aB"));
}

test "Regex: \\p{Letter} accepts the long-form General_Category alias and matches CJK ideographs" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{Letter}+");
    defer re.deinit();

    const input = "\u{65E5}\u{672C}\u{8A9E}123"; // "日本語123"
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("\u{65E5}\u{672C}\u{8A9E}", m.group(input));
}

test "Regex: \\p{gc=Lu} and \\p{General_Category=Lu} prefix forms both work" {
    const allocator = std.testing.allocator;

    var re1 = try Regex.compile(allocator, "\\p{gc=Lu}");
    defer re1.deinit();
    try std.testing.expect(try re1.test_("B"));
    try std.testing.expect(!try re1.test_("b"));

    var re2 = try Regex.compile(allocator, "\\p{General_Category=Lu}");
    defer re2.deinit();
    try std.testing.expect(try re2.test_("B"));
}

test "Regex: unknown \\p{...} property name is a compile error, not silently ignored" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownUnicodeProperty, Regex.compile(allocator, "\\p{Bogus}"));
}

test "Regex: \\p{...} alone inside a character class matches the same as standalone" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[\\p{L}]+");
    defer re.deinit();

    const input = "123abc456";
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("abc", m.group(input));
}

test "Regex: \\p{...} mixed with ordinary members in a class is a union (e.g. [\\p{L}\\d])" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[\\p{L}\\d]+");
    defer re.deinit();

    const input = "!!!abc123\u{3B1}\u{3B2}###"; // letters, digits, Greek alpha/beta
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("abc123\u{3B1}\u{3B2}", m.group(input));
}

test "Regex: \\P{...} as a class member contributes its own complement to the union, not a whole-class negation" {
    const allocator = std.testing.allocator;

    // [\P{L}\d] means "not-a-letter, OR a digit" -- since digits aren't
    // letters anyway this reduces to "not a letter", but it must NOT behave
    // like [^\p{L}\d] (which would additionally reject digits too).
    var re = try Regex.compile(allocator, "[\\P{L}\\d]+");
    defer re.deinit();

    const input = "abc123!!!xyz";
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("123!!!", m.group(input));
}

test "Regex: [^\\p{L}\\d] (whole-class negation) rejects both letters and digits" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[^\\p{L}\\d]+");
    defer re.deinit();

    const input = "abc123!!!xyz789";
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("!!!", m.group(input));
}

test "Regex: \\p{Script=...} and \\p{Script_Extensions=...} work as class members too" {
    const allocator = std.testing.allocator;

    var sc = try Regex.compile(allocator, "[\\p{Script=Greek}\\d]+");
    defer sc.deinit();
    const input1 = "abc\u{3B1}\u{3B2}123xyz";
    const m1 = (try sc.find(input1)).?;
    defer m1.deinit();
    try std.testing.expectEqualStrings("\u{3B1}\u{3B2}123", m1.group(input1));

    var scx = try Regex.compile(allocator, "[\\p{Script_Extensions=Latin}]+");
    defer scx.deinit();
    // U+0301 is in Latin's Script_Extensions (see the earlier
    // Script_Extensions tests) even though its own Script is Inherited.
    try std.testing.expect(try scx.test_("a\u{301}"));
}

test "Regex: a class with more than MAX_CLASS_PROPERTIES \\p{...} members is a compile error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.TooManyClassProperties,
        Regex.compile(allocator, "[\\p{L}\\p{N}\\p{P}\\p{S}\\p{Z}]"),
    );
}

test "Regex: malformed \\p (no braces) falls back to a literal 'p'" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p");
    defer re.deinit();
    try std.testing.expect(try re.test_("p"));
    try std.testing.expect(!try re.test_("q"));
}

test "Regex: replace() supports $N numbered capture substitution" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(\\w+) (\\w+)");
    defer re.deinit();

    const r = try re.replace(allocator, "hello world", "$2 $1");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("world hello", r);
}

test "Regex: replace() supports $& (whole match), $` (before), $' (after)" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\d+");
    defer re.deinit();

    const r1 = try re.replace(allocator, "abc123def", "[$&]");
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("abc[123]def", r1);

    const r2 = try re.replace(allocator, "abc123def", "[$`|$']");
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("abc[abc|def]def", r2);
}

test "Regex: replace() supports $$ as a literal dollar sign" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "100%");
    defer re.deinit();

    const r = try re.replace(allocator, "100%", "$$");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("$", r);
}

test "Regex: replace() supports $<name> named-group substitution" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(?<year>\\d+)-(?<month>\\d+)");
    defer re.deinit();

    const r = try re.replace(allocator, "2026-07", "$<month>/$<year>");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("07/2026", r);
}

test "Regex: replace() substitutes empty string for a group that exists but didn't participate" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(a)?b");
    defer re.deinit();

    const r = try re.replace(allocator, "b", "[$1]");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("[]", r);
}

test "Regex: replace() leaves $N literal when group N doesn't exist in the pattern" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(a)b");
    defer re.deinit();

    const r = try re.replace(allocator, "ab", "[$5]");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("[$5]", r);
}

test "Regex: replace() leaves $<unknownName> literal when the name doesn't exist" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(?<x>a)b");
    defer re.deinit();

    const r = try re.replace(allocator, "ab", "[$<bogus>]");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("[$<bogus>]", r);
}

test "Regex: replaceAll() substitutes $& per match" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\d");
    defer re.deinit();

    const r = try re.replaceAll(allocator, "a1b2c3", "<$&>");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("a<1>b<2>c<3>", r);
}

test "Regex: replace() prefers the two-digit group number when it exists ($10 vs $1 + '0')" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)");
    defer re.deinit();

    const r = try re.replace(allocator, "abcdefghij", "$10-$1");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("j-a", r);
}

test "Regex: \\p{White_Space} matches Unicode whitespace, including non-ASCII" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{White_Space}+");
    defer re.deinit();

    const m = (try re.find("abc   def")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("   ", m.group("abc   def"));

    // U+3000 IDEOGRAPHIC SPACE
    try std.testing.expect(try re.test_("\u{3000}"));
}

test "Regex: \\p{Alphabetic} matches letters (broader than General_Category L in principle, ASCII-equal in practice)" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{Alphabetic}+");
    defer re.deinit();

    const m = (try re.find("abc123")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("abc", m.group("abc123"));
}

test "Regex: \\p{Uppercase} and \\p{Lowercase} match case-specific letters" {
    const allocator = std.testing.allocator;

    var upper_re = try Regex.compile(allocator, "\\p{Uppercase}+");
    defer upper_re.deinit();
    const m1 = (try upper_re.find("abcDEFghi")).?;
    defer m1.deinit();
    try std.testing.expectEqualStrings("DEF", m1.group("abcDEFghi"));

    var lower_re = try Regex.compile(allocator, "\\p{Lowercase}+");
    defer lower_re.deinit();
    const m2 = (try lower_re.find("ABCdefGHI")).?;
    defer m2.deinit();
    try std.testing.expectEqualStrings("def", m2.group("ABCdefGHI"));
}

test "Regex: \\p{ASCII} and \\p{Any} trivial properties" {
    const allocator = std.testing.allocator;

    var ascii_re = try Regex.compile(allocator, "\\p{ASCII}+");
    defer ascii_re.deinit();
    const m1 = (try ascii_re.find("abc\u{E9}def")).?;
    defer m1.deinit();
    try std.testing.expectEqualStrings("abc", m1.group("abc\u{E9}def"));

    var any_re = try Regex.compile(allocator, "\\p{Any}+");
    defer any_re.deinit();
    const input = "abc\u{E9}def";
    const m2 = (try any_re.find(input)).?;
    defer m2.deinit();
    try std.testing.expectEqualStrings(input, m2.group(input));
}

test "Regex: \\P{Alphabetic} (negated binary property) matches non-letters" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\P{Alphabetic}+");
    defer re.deinit();

    const m = (try re.find("abc   def")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("   ", m.group("abc   def"));
}

test "Regex: expanded Unicode binary properties (Hex_Digit, Dash, Math, Quotation_Mark)" {
    const allocator = std.testing.allocator;

    var hex_re = try Regex.compile(allocator, "\\p{Hex_Digit}+");
    defer hex_re.deinit();
    const m1 = (try hex_re.find("xyzABCdef123ghi")).?;
    defer m1.deinit();
    try std.testing.expectEqualStrings("ABCdef123", m1.group("xyzABCdef123ghi"));

    var dash_re = try Regex.compile(allocator, "\\p{Dash}+");
    defer dash_re.deinit();
    const m2 = (try dash_re.find("a--b")).?;
    defer m2.deinit();
    try std.testing.expectEqualStrings("--", m2.group("a--b"));

    var math_re = try Regex.compile(allocator, "\\p{Math}+");
    defer math_re.deinit();
    try std.testing.expect(try math_re.test_("+"));
    try std.testing.expect(!try math_re.test_("a"));

    var quote_re = try Regex.compile(allocator, "\\p{Quotation_Mark}");
    defer quote_re.deinit();
    try std.testing.expect(try quote_re.test_("\""));
}

test "Regex: \\p{Emoji} matches a real emoji codepoint, not ASCII text" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{Emoji}");
    defer re.deinit();

    const input = "a\u{1F600}b"; // a + GRINNING FACE + b
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("\u{1F600}", m.group(input));

    try std.testing.expect(!try re.test_("a"));
}

test "Regex: \\p{Extended_Pictographic} matches U+00A9 (line with no space before '#' in emoji-data.txt)" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{Extended_Pictographic}");
    defer re.deinit();

    try std.testing.expect(try re.test_("\u{A9}")); // COPYRIGHT SIGN
}

test "Regex: \\p{Script=Greek} matches Greek letters, not Latin ones" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{Script=Greek}+");
    defer re.deinit();

    const input = "abc\u{3B1}\u{3B2}\u{3B3}def"; // abc + alpha,beta,gamma + def
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("\u{3B1}\u{3B2}\u{3B3}", m.group(input));
}

test "Regex: \\p{sc=Latin} (short prefix form) matches Latin letters" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{sc=Latin}+");
    defer re.deinit();

    const input = "\u{3B1}abcXYZ\u{3B2}"; // alpha + abcXYZ + beta
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("abcXYZ", m.group(input));
}

test "Regex: \\P{Script=Latin} (negated script) matches non-Latin codepoints" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\P{Script=Latin}");
    defer re.deinit();

    try std.testing.expect(try re.test_("\u{3B1}")); // Greek alpha
    try std.testing.expect(!try re.test_("a"));
}

test "Regex: \\p{Script=Han} matches CJK ideographs" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{Script=Han}+");
    defer re.deinit();

    const input = "abc\u{4E2D}\u{6587}xyz"; // abc + 中文 + xyz
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("\u{4E2D}\u{6587}", m.group(input));
}

test "Regex: unknown \\p{Script=...} value is a compile error, not silently ignored" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownUnicodeProperty, Regex.compile(allocator, "\\p{Script=Bogus}"));
}

test "Regex: a bare script name without Script=/sc= prefix is rejected (not valid JS syntax)" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownUnicodeProperty, Regex.compile(allocator, "\\p{Greek}"));
}

test "Regex: \\p{Script=Grek} (short script alias) matches the same as \\p{Script=Greek}" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{Script=Grek}+");
    defer re.deinit();

    const input = "abc\u{3B1}\u{3B2}\u{3B3}def"; // abc + alpha,beta,gamma + def
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("\u{3B1}\u{3B2}\u{3B3}", m.group(input));
}

test "Regex: \\p{sc=Hani} (short alias with sc= prefix) matches CJK ideographs" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{sc=Hani}+");
    defer re.deinit();

    const input = "abc\u{4E2D}\u{6587}xyz"; // abc + 中文 + xyz
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("\u{4E2D}\u{6587}", m.group(input));
}

test "Regex: \\P{Script=Latn} (negated short alias) matches non-Latin codepoints" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\P{Script=Latn}");
    defer re.deinit();

    try std.testing.expect(try re.test_("\u{3B1}")); // Greek alpha
    try std.testing.expect(!try re.test_("a"));
}

test "Regex: \\p{Script_Extensions=Latin} matches a combining accent that \\p{Script=Latin} rejects" {
    const allocator = std.testing.allocator;

    // U+0301 COMBINING ACUTE ACCENT: Script is Inherited, but
    // Script_Extensions includes Latin (it's used to write e.g. "e" + accent
    // in several Latin-script orthographies) -- the whole reason
    // Script_Extensions exists as a separate, broader property.
    var scx = try Regex.compile(allocator, "\\p{Script_Extensions=Latin}");
    defer scx.deinit();
    try std.testing.expect(try scx.test_("\u{301}"));

    var sc = try Regex.compile(allocator, "\\p{Script=Latin}");
    defer sc.deinit();
    try std.testing.expect(!try sc.test_("\u{301}"));
}

test "Regex: \\p{scx=Grek} (short prefix + short alias) matches Greek letters" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{scx=Grek}+");
    defer re.deinit();

    const input = "abc\u{3B1}\u{3B2}\u{3B3}def"; // abc + alpha,beta,gamma + def
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("\u{3B1}\u{3B2}\u{3B3}", m.group(input));
}

test "Regex: \\P{Script_Extensions=Latin} (negated) rejects a Latin-extension combining accent" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\P{Script_Extensions=Latin}");
    defer re.deinit();

    try std.testing.expect(!try re.test_("\u{301}")); // in Latin's Script_Extensions
    try std.testing.expect(!try re.test_("a")); // Latin itself
    try std.testing.expect(try re.test_("\u{3B1}")); // Greek alpha: not in Latin's scx
}

test "Regex: \\p{Script_Extensions=...} still matches ordinary single-script codepoints like \\p{Script=...}" {
    const allocator = std.testing.allocator;

    // For the overwhelming majority of codepoints (anything
    // ScriptExtensions.txt doesn't explicitly list), Script_Extensions is
    // identical to Script.
    var re = try Regex.compile(allocator, "\\p{Script_Extensions=Han}+");
    defer re.deinit();

    const input = "abc\u{4E2D}\u{6587}xyz"; // abc + 中文 + xyz
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("\u{4E2D}\u{6587}", m.group(input));
}

test "Regex: unknown \\p{Script_Extensions=...} value is a compile error, not silently ignored" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownUnicodeProperty, Regex.compile(allocator, "\\p{Script_Extensions=Bogus}"));
}

test "Regex: \\p{Bidi_Mirrored} matches mirrored punctuation like parens and braces" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\p{Bidi_Mirrored}+");
    defer re.deinit();

    const input = "abc(){}def";
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("(){}", m.group(input));

    try std.testing.expect(!try re.test_("a"));
}

test "Regex: \\p{Assigned} / \\P{Assigned} distinguish assigned codepoints from noncharacters" {
    const allocator = std.testing.allocator;

    var assigned_re = try Regex.compile(allocator, "\\p{Assigned}+");
    defer assigned_re.deinit();
    try std.testing.expect(try assigned_re.test_("a"));
    try std.testing.expect(try assigned_re.test_("\u{1F600}"));

    var unassigned_re = try Regex.compile(allocator, "\\P{Assigned}");
    defer unassigned_re.deinit();
    try std.testing.expect(try unassigned_re.test_("\u{FFFF}")); // noncharacter
    try std.testing.expect(!try unassigned_re.test_("a"));
}

test "Regex: case_insensitive matches a literal non-ASCII character's simple case-fold pair" {
    const allocator = std.testing.allocator;

    var re = try Regex.compileWithOptions(allocator, "caf\u{E9}", .{ .case_insensitive = true }); // "café"
    defer re.deinit();

    try std.testing.expect(try re.test_("caf\u{E9}")); // same case
    try std.testing.expect(try re.test_("CAF\u{C9}")); // "CAFÉ": É is U+00C9
    try std.testing.expect(!try re.test_("cafe")); // no accent: different codepoint, not a case pair
}

test "Regex: case_insensitive is off by default for non-ASCII literals" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "caf\u{E9}"); // "café", no options
    defer re.deinit();

    try std.testing.expect(!try re.test_("CAF\u{C9}"));
}

test "Regex: case_insensitive + quantifier over a non-ASCII literal matches mixed-case runs" {
    const allocator = std.testing.allocator;

    // Greek alpha (U+03B1) / capital alpha (U+0391)
    var re = try Regex.compileWithOptions(allocator, "\u{3B1}+", .{ .case_insensitive = true });
    defer re.deinit();

    const input = "xx\u{391}\u{391}\u{3B1}yy"; // xxΑΑαyy
    const m = (try re.find(input)).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("\u{391}\u{391}\u{3B1}", m.group(input));
}

test "Regex: case_insensitive matches a non-ASCII codepoint with no case pair unchanged" {
    const allocator = std.testing.allocator;

    // CJK ideographs have no case distinction; case_insensitive must not
    // break matching them (casefold.toUpper/toLower both return null).
    var re = try Regex.compileWithOptions(allocator, "\u{4E2D}", .{ .case_insensitive = true });
    defer re.deinit();
    try std.testing.expect(try re.test_("\u{4E2D}"));
}

test "Regex: case_insensitive character class matches a non-ASCII member's case-fold pair" {
    const allocator = std.testing.allocator;

    var re = try Regex.compileWithOptions(allocator, "[\u{E9}]", .{ .case_insensitive = true }); // [é]
    defer re.deinit();

    try std.testing.expect(try re.test_("\u{E9}")); // é
    try std.testing.expect(try re.test_("\u{C9}")); // É
    try std.testing.expect(!try re.test_("e")); // no accent
}

test "Regex: case_insensitive character class mixing ASCII and non-ASCII members folds both" {
    const allocator = std.testing.allocator;

    // 'a' forces this class into ranges mode alongside 'é' (>U+007F); both
    // members must still be case-folded, not just the non-ASCII one.
    var re = try Regex.compileWithOptions(allocator, "[a\u{E9}]+", .{ .case_insensitive = true });
    defer re.deinit();

    const m = (try re.find("xxA\u{C9}yy")).?; // xxAÉyy
    defer m.deinit();
    try std.testing.expectEqualStrings("A\u{C9}", m.group("xxA\u{C9}yy"));
}

test "Regex: \\v and \\f are recognized as vertical tab / form feed, not literal 'v'/'f'" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\v\\f");
    defer re.deinit();

    try std.testing.expect(try re.test_("\x0B\x0C"));
    try std.testing.expect(!try re.test_("vf"));
}

test "Regex: unicode flag off (default) keeps Annex-B leniency for unrecognized escapes" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\q");
    defer re.deinit();
    try std.testing.expect(try re.test_("q"));
}

test "Regex: unicode flag rejects an unrecognized escape as a compile error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidEscape,
        Regex.compileWithOptions(allocator, "\\q", .{ .unicode = true }),
    );
}

test "Regex: unicode flag still accepts SyntaxCharacter identity escapes" {
    const allocator = std.testing.allocator;

    var re = try Regex.compileWithOptions(allocator, "\\/\\.\\*", .{ .unicode = true });
    defer re.deinit();
    try std.testing.expect(try re.test_("/.*"));
}

test "Regex: unicode flag accepts \\- as the first character-class member (lookahead-mode fix)" {
    const allocator = std.testing.allocator;

    // Regression test for a real bug this feature exposed: parseCharClass
    // speculatively tokenizes the character right after `[` in normal
    // (non-class) mode first, purely to check for `^`, and rewinds to
    // re-tokenize in class mode if it isn't -- `-` is a valid class-mode
    // identity escape but not a valid normal-mode one, so that speculative
    // fetch must not itself trip the strict check (see parser.zig).
    var re = try Regex.compileWithOptions(allocator, "[\\-a]", .{ .unicode = true });
    defer re.deinit();
    try std.testing.expect(try re.test_("-"));
    try std.testing.expect(try re.test_("a"));
}

test "Regex: unicode flag rejects \\- outside a character class" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidEscape,
        Regex.compileWithOptions(allocator, "\\-", .{ .unicode = true }),
    );
}

test "Regex: unicode flag rejects an unrecognized escape inside a character class" {
    const allocator = std.testing.allocator;
    // \B has no meaning inside a class (unlike \b, backspace); Annex-B
    // leniency treats it as a literal 'B' there, but it's a SyntaxError
    // under the unicode flag, same as any other unrecognized escape.
    try std.testing.expectError(
        error.InvalidEscape,
        Regex.compileWithOptions(allocator, "[\\B]", .{ .unicode = true }),
    );
}

test "Regex: unicode flag rejects legacy octal escapes (\\0 followed by a digit)" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidEscape,
        Regex.compileWithOptions(allocator, "\\01", .{ .unicode = true }),
    );
}

test "Regex: unicode flag off (default) keeps legacy octal Annex-B leniency" {
    const allocator = std.testing.allocator;

    // \01 falls back to a literal '0' (matching prior behavior) when the
    // unicode flag isn't set.
    var re = try Regex.compile(allocator, "\\01");
    defer re.deinit();
    try std.testing.expect(try re.test_("01"));
}

test "Regex: v flag class set difference [A--B]" {
    const allocator = std.testing.allocator;

    // Letters except vowels.
    var re = try Regex.compileWithOptions(allocator, "[\\p{L}--[aeiou]]+", .{ .v = true });
    defer re.deinit();

    try std.testing.expect(try re.test_("b"));
    try std.testing.expect(!try re.test_("e"));
    try std.testing.expect(!try re.test_("5"));

    const m = (try re.find("hello world")).?;
    defer m.deinit();
    try std.testing.expectEqualStrings("h", m.group("hello world"));
}

test "Regex: v flag class set intersection [A&&B], both operands nested and negated" {
    const allocator = std.testing.allocator;

    // Lowercase letters that aren't 'x'.
    var re = try Regex.compileWithOptions(allocator, "[[a-z]&&[^x]]", .{ .v = true });
    defer re.deinit();

    try std.testing.expect(try re.test_("a"));
    try std.testing.expect(!try re.test_("x"));
    try std.testing.expect(!try re.test_("A"));
}

test "Regex: v flag class set operation with a bare \\p{...} operand on both sides" {
    const allocator = std.testing.allocator;

    // Letters that aren't uppercase.
    var re = try Regex.compileWithOptions(allocator, "[\\p{L}--\\p{Lu}]+", .{ .v = true });
    defer re.deinit();

    try std.testing.expect(try re.test_("a"));
    try std.testing.expect(!try re.test_("A"));
}

test "Regex: v flag class set operation's own [^...] negation is independent of each operand's" {
    const allocator = std.testing.allocator;

    // Regression test for a real bug: a flat (non-nested) operand1's own
    // `char_class` node was reusing the *outer* class's `[^...]` flag as if
    // it were operand1's own negation, double-counting it (once via the
    // operand's own negation, once via the set-op's outer negation) instead
    // of the outer `^` belonging solely to the whole operation's result.
    var re = try Regex.compileWithOptions(allocator, "[^\\p{L}--[aeiou]]", .{ .v = true });
    defer re.deinit();

    // \p{L}--[aeiou] matches consonants; negated, it matches vowels,
    // digits, and everything else that ISN'T a consonant.
    try std.testing.expect(!try re.test_("b")); // consonant: excluded
    try std.testing.expect(try re.test_("e")); // vowel: included
    try std.testing.expect(try re.test_("5")); // digit: included
}

test "Regex: v flag class set operation with a negated nested operand (regression: mode-timing bug)" {
    const allocator = std.testing.allocator;

    // Regression test for a real bug: recursing into parseCharClass for a
    // nested operand while still lexing in class mode broke that nested
    // call's own `^`-negation lookahead (which assumes it starts from
    // normal mode), silently losing `[^x]`'s negation.
    var re = try Regex.compileWithOptions(allocator, "[[a-z]--[^x]]", .{ .v = true });
    defer re.deinit();

    // a-z minus (not-x) = a-z intersect x = just 'x'.
    try std.testing.expect(try re.test_("x"));
    try std.testing.expect(!try re.test_("a"));
}

test "Regex: v flag rejects chained class set operators" {
    const allocator = std.testing.allocator;

    // This feature's scope is exactly one operation per class; chaining
    // (`[A--B--C]`) is deliberately not supported -- see
    // docs/KNOWN_LIMITATIONS.md.
    try std.testing.expectError(
        error.ChainedClassSetOperatorNotSupported,
        Regex.compileWithOptions(allocator, "[\\p{L}--[a]--[b]]", .{ .v = true }),
    );
}

test "Regex: v flag off (default) keeps -- and && as ordinary literal characters" {
    const allocator = std.testing.allocator;

    // Backward compatibility: without the v flag, `-` and `&` have no
    // special class-set meaning, even doubled up.
    var re = try Regex.compile(allocator, "[a-c-]");
    defer re.deinit();
    try std.testing.expect(try re.test_("-"));
}

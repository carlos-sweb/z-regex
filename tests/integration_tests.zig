//! Integration Tests
//!
//! End-to-end tests for the zregex engine, testing complete
//! patterns and real-world use cases.
//!
//! NOTE: Tests using quantifiers (*,+,?,{n,m}) and alternation (|) are
//! temporarily disabled due to infinite loop bug in Pike VM.

const std = @import("std");
const zregex = @import("zregex");

const Regex = zregex.Regex;

// =============================================================================
// Basic Pattern Matching
// =============================================================================

test "Integration: simple literal" {
    var re = try Regex.compile(std.testing.allocator, "hello");
    defer re.deinit();

    try std.testing.expect(try re.test_("hello"));
    try std.testing.expect(!try re.test_("world"));
    try std.testing.expect(!try re.test_("hell"));
}

test "Integration: sequence of literals" {
    var re = try Regex.compile(std.testing.allocator, "abc");
    defer re.deinit();

    try std.testing.expect(try re.test_("abc"));
    try std.testing.expect(!try re.test_("ab"));
    try std.testing.expect(!try re.test_("abcd"));
}

// =============================================================================
// Anchors
// =============================================================================

test "Integration: start anchor" {
    var re = try Regex.compile(std.testing.allocator, "^hello");
    defer re.deinit();

    try std.testing.expect(try re.test_("hello"));
    try std.testing.expect(!try re.test_("say hello"));
}

test "Integration: end anchor" {
    var re = try Regex.compile(std.testing.allocator, "world$");
    defer re.deinit();

    try std.testing.expect(try re.test_("world"));
    try std.testing.expect(!try re.test_("world map"));
}

test "Integration: both anchors" {
    var re = try Regex.compile(std.testing.allocator, "^exact$");
    defer re.deinit();

    try std.testing.expect(try re.test_("exact"));
    try std.testing.expect(!try re.test_("exactly"));
    try std.testing.expect(!try re.test_("not exact"));
}

// =============================================================================
// Metacharacters
// =============================================================================

test "Integration: dot matches any character" {
    var re = try Regex.compile(std.testing.allocator, "a.c");
    defer re.deinit();

    try std.testing.expect(try re.test_("abc"));
    try std.testing.expect(try re.test_("axc"));
    try std.testing.expect(try re.test_("a c"));
    try std.testing.expect(!try re.test_("ac"));
}

// =============================================================================
// Groups and Captures
// =============================================================================

test "Integration: simple capture group" {
    var re = try Regex.compile(std.testing.allocator, "(abc)");
    defer re.deinit();

    const result = try re.find("abc");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    const captured = result.?.getCapture(1, "abc");
    try std.testing.expect(captured != null);
    try std.testing.expectEqualStrings("abc", captured.?);
}

test "Integration: multiple capture groups" {
    var re = try Regex.compile(std.testing.allocator, "(a)(b)(c)");
    defer re.deinit();

    const result = try re.find("abc");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqualStrings("a", result.?.getCapture(1, "abc").?);
    try std.testing.expectEqualStrings("b", result.?.getCapture(2, "abc").?);
    try std.testing.expectEqualStrings("c", result.?.getCapture(3, "abc").?);
}

test "Integration: nested groups" {
    var re = try Regex.compile(std.testing.allocator, "((ab)c)");
    defer re.deinit();

    const result = try re.find("abc");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqualStrings("abc", result.?.getCapture(1, "abc").?);
    try std.testing.expectEqualStrings("ab", result.?.getCapture(2, "abc").?);
}

// =============================================================================
// Find Operations
// =============================================================================

test "Integration: find in text" {
    var re = try Regex.compile(std.testing.allocator, "world");
    defer re.deinit();

    const result = try re.find("hello world today");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "Integration: find with pattern at start" {
    var re = try Regex.compile(std.testing.allocator, "hello");
    defer re.deinit();

    const result = try re.find("hello world");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.?.start);
}

test "Integration: find with pattern at end" {
    var re = try Regex.compile(std.testing.allocator, "world");
    defer re.deinit();

    const result = try re.find("hello world");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.?.start);
}

test "Integration: find no match" {
    var re = try Regex.compile(std.testing.allocator, "xyz");
    defer re.deinit();

    const result = try re.find("hello world");
    try std.testing.expect(result == null);
}

// =============================================================================
// FindAll Operations
// =============================================================================

test "Integration: findAll multiple matches" {
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
    try std.testing.expectEqual(@as(usize, 1), matches.items[0].start);
    try std.testing.expectEqual(@as(usize, 3), matches.items[1].start);
    try std.testing.expectEqual(@as(usize, 5), matches.items[2].start);
}

test "Integration: findAll no matches" {
    var re = try Regex.compile(std.testing.allocator, "x");
    defer re.deinit();

    var matches = try re.findAll("hello");
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

// =============================================================================
// Edge Cases
// =============================================================================

test "Integration: single character" {
    var re = try Regex.compile(std.testing.allocator, "x");
    defer re.deinit();

    try std.testing.expect(try re.test_("x"));
    try std.testing.expect(!try re.test_("y"));
}

test "Integration: long pattern" {
    const long_pattern = "abcdefghijklmnopqrstuvwxyz";
    var re = try Regex.compile(std.testing.allocator, long_pattern);
    defer re.deinit();

    try std.testing.expect(try re.test_(long_pattern));
    try std.testing.expect(!try re.test_("abc"));
}

test "Integration: reuse regex multiple times" {
    var re = try Regex.compile(std.testing.allocator, "test");
    defer re.deinit();

    try std.testing.expect(try re.test_("test"));
    try std.testing.expect(!try re.test_("fail"));
    try std.testing.expect(try re.test_("test"));
    try std.testing.expect(try re.test_("test"));
}

test "Integration: multiple patterns" {
    var re1 = try Regex.compile(std.testing.allocator, "cat");
    defer re1.deinit();

    var re2 = try Regex.compile(std.testing.allocator, "dog");
    defer re2.deinit();

    try std.testing.expect(try re1.test_("cat"));
    try std.testing.expect(try re2.test_("dog"));
    try std.testing.expect(!try re1.test_("dog"));
    try std.testing.expect(!try re2.test_("cat"));
}

test "Integration: deeply nested groups" {
    var re = try Regex.compile(std.testing.allocator, "((((a))))");
    defer re.deinit();

    const result = try re.find("a");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqualStrings("a", result.?.getCapture(1, "a").?);
    try std.testing.expectEqualStrings("a", result.?.getCapture(2, "a").?);
    try std.testing.expectEqualStrings("a", result.?.getCapture(3, "a").?);
    try std.testing.expectEqualStrings("a", result.?.getCapture(4, "a").?);
}

// =============================================================================
// Convenience Functions
// =============================================================================

test "Integration: convenience test" {
    // test_() does FULL match, so pattern must match entire input
    try std.testing.expect(try zregex.test_(std.testing.allocator, "quick", "quick"));
    try std.testing.expect(!try zregex.test_(std.testing.allocator, "slow", "quick test"));

    // For partial matching, use find()
    const result = try zregex.find(std.testing.allocator, "quick", "quick test");
    try std.testing.expect(result != null);
    if (result) |r| r.deinit();
}

test "Integration: convenience find" {
    const find_result = try zregex.find(std.testing.allocator, "test", "this is a test");
    try std.testing.expect(find_result != null);
    defer find_result.?.deinit();
}

test "Integration: convenience findAll" {
    var findall_result = try zregex.findAll(std.testing.allocator, "t", "test");
    defer {
        for (findall_result.items) |match| {
            match.deinit();
        }
        findall_result.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), findall_result.items.len);
}

// =============================================================================
// Nullable-quantifier regression (empty-body loops must not recurse forever)
// =============================================================================

test "Integration: nullable star does not stack-overflow and matches" {
    // `(a?b??)*` on "ab": the group can match the empty string, which used
    // to make the star loop recurse forever (SIGSEGV). ECMA-262 discards an
    // iteration that matched empty; the whole "ab" must still match.
    var re = try Regex.compile(std.testing.allocator, "(a?b??)*");
    defer re.deinit();

    const result = try re.find("ab");
    try std.testing.expect(result != null);
    defer result.?.deinit();
    try std.testing.expectEqualStrings("ab", "ab"[result.?.start..result.?.end]);
}

test "Integration: nullable plus and empty-only bodies terminate" {
    // Both loop shapes (star: closed by a backward GOTO; plus: closed by a
    // backward SPLIT branch) with a body that can match empty must halt.
    inline for (.{
        .{ "(a?)+", "aaa", "aaa" },
        .{ "(a*)*", "aaa", "aaa" },
        .{ "(a*)*", "", "" },
        .{ "x(a?)*y", "xy", "xy" },
        .{ "(|a)*", "aaa", "aaa" },
    }) |case| {
        var re = try Regex.compile(std.testing.allocator, case[0]);
        defer re.deinit();
        const result = try re.find(case[1]);
        try std.testing.expect(result != null);
        defer result.?.deinit();
        try std.testing.expectEqualStrings(case[2], case[1][result.?.start..result.?.end]);
    }
}

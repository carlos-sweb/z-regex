//! Basic Usage Example
//!
//! This example demonstrates the fundamental usage of zregex:
//! - Compiling a regex pattern
//! - Testing if a pattern matches
//! - Finding matches in text
//!
//! Build and run:
//!   zig build-exe basic_usage.zig --dep zregex --mod zregex:../src/main.zig
//!   ./basic_usage

const std = @import("std");
const zregex = @import("zregex");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== zregex Basic Usage Example ===\n\n", .{});

    // Example 1: Simple pattern matching
    {
        std.debug.print("Example 1: Simple Pattern Matching\n", .{});
        std.debug.print("-----------------------------------\n", .{});

        var re = try zregex.Regex.compile(allocator, "hello");
        defer re.deinit();

        const text1 = "hello world";
        const text2 = "goodbye world";

        const match1 = try re.find(text1);
        defer if (match1) |m| m.deinit();
        const match2 = try re.find(text2);
        defer if (match2) |m| m.deinit();

        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text 1: '{f}' -> Match: {}\n", .{
            std.zig.fmtString(text1),
            match1 != null,
        });
        std.debug.print("Text 2: '{f}' -> Match: {}\n\n", .{
            std.zig.fmtString(text2),
            match2 != null,
        });
    }

    // Example 2: Finding matches in text
    {
        std.debug.print("Example 2: Finding Matches\n", .{});
        std.debug.print("--------------------------\n", .{});

        var re = try zregex.Regex.compile(allocator, "world");
        defer re.deinit();

        const text = "hello world, beautiful world";
        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        if (try re.find(text)) |match| {
            defer match.deinit();
            std.debug.print("First match found at position {}-{}\n", .{ match.start, match.end });
            std.debug.print("Matched text: '{f}'\n\n", .{std.zig.fmtString(match.group(text))});
        }
    }

    // Example 3: One-shot matching (convenience functions)
    {
        std.debug.print("Example 3: One-Shot Matching\n", .{});
        std.debug.print("-----------------------------\n", .{});

        const pattern = "quick";
        const text = "the quick brown fox";

        if (try zregex.test_(allocator, pattern, text)) {
            std.debug.print("Pattern '{f}' matches in '{f}'\n\n", .{
                std.zig.fmtString(pattern),
                std.zig.fmtString(text),
            });
        }
    }

    // Example 4: Using metacharacters
    {
        std.debug.print("Example 4: Metacharacters\n", .{});
        std.debug.print("-------------------------\n", .{});

        var re = try zregex.Regex.compile(allocator, "h.llo");
        defer re.deinit();

        const tests = [_][]const u8{ "hello", "hallo", "hxllo", "hllo" };

        std.debug.print("Pattern: '{f}' (dot matches any character)\n", .{std.zig.fmtString(re.getPattern())});
        for (tests) |test_text| {
            const matches = try re.test_(test_text);
            std.debug.print("  '{f}' -> {}\n", .{ std.zig.fmtString(test_text), matches });
        }
        std.debug.print("\n", .{});
    }

    // Example 5: Quantifiers
    {
        std.debug.print("Example 5: Quantifiers\n", .{});
        std.debug.print("----------------------\n", .{});

        const patterns = [_][]const u8{ "a*", "a+", "a?" };
        const tests = [_][]const u8{ "", "a", "aa", "aaa" };

        for (patterns) |pattern| {
            var re = try zregex.Regex.compile(allocator, pattern);
            defer re.deinit();

            std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(pattern)});
            for (tests) |test_text| {
                const matches = try re.test_(test_text);
                std.debug.print("  '{f}' -> {}\n", .{ std.zig.fmtString(test_text), matches });
            }
            std.debug.print("\n", .{});
        }
    }

    // Example 6: Anchors
    {
        std.debug.print("Example 6: Anchors\n", .{});
        std.debug.print("------------------\n", .{});

        var re = try zregex.Regex.compile(allocator, "^hello$");
        defer re.deinit();

        const tests = [_][]const u8{ "hello", "hello world", "say hello", "hello there" };

        std.debug.print("Pattern: '{f}' (must match entire string)\n", .{std.zig.fmtString(re.getPattern())});
        for (tests) |test_text| {
            const matches = try re.test_(test_text);
            std.debug.print("  '{f}' -> {}\n", .{ std.zig.fmtString(test_text), matches });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("=== Example Complete ===\n", .{});
}

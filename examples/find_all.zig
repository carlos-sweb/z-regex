//! Find All Matches Example
//!
//! This example demonstrates how to find all occurrences of a pattern
//! in text, not just the first match.
//!
//! Build and run:
//!   zig build-exe find_all.zig --dep zregexp --mod zregexp:../src/main.zig
//!   ./find_all

const std = @import("std");
const zregexp = @import("zregexp");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Find All Matches Example ===\n\n", .{});

    // Example 1: Find all occurrences of a letter
    {
        std.debug.print("Example 1: Find All Letters\n", .{});
        std.debug.print("---------------------------\n", .{});

        var re = try zregexp.Regex.compile(allocator, "a");
        defer re.deinit();

        const text = "banana";
        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        var matches = try re.findAll(text);
        defer {
            for (matches.items) |match| {
                match.deinit();
            }
            matches.deinit(allocator);
        }

        std.debug.print("Found {} matches:\n", .{matches.items.len});
        for (matches.items, 0..) |match, i| {
            std.debug.print("  Match {}: position {}-{}, text: '{f}'\n", .{
                i + 1,
                match.start,
                match.end,
                std.zig.fmtString(match.group(text)),
            });
        }
        std.debug.print("\n", .{});
    }

    // Example 2: Find all words (simplified)
    {
        std.debug.print("Example 2: Find All Words\n", .{});
        std.debug.print("-------------------------\n", .{});

        var re = try zregexp.Regex.compile(allocator, "o+");
        defer re.deinit();

        const text = "foooobar boo zoo";
        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        var matches = try re.findAll(text);
        defer {
            for (matches.items) |match| {
                match.deinit();
            }
            matches.deinit(allocator);
        }

        std.debug.print("Found {} matches:\n", .{matches.items.len});
        for (matches.items, 0..) |match, i| {
            std.debug.print("  Match {}: '{f}' at position {}-{}\n", .{
                i + 1,
                std.zig.fmtString(match.group(text)),
                match.start,
                match.end,
            });
        }
        std.debug.print("\n", .{});
    }

    // Example 3: Count occurrences
    {
        std.debug.print("Example 3: Count Occurrences\n", .{});
        std.debug.print("----------------------------\n", .{});

        var re = try zregexp.Regex.compile(allocator, "the");
        defer re.deinit();

        const text = "the quick brown fox jumps over the lazy dog near the river";
        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        var matches = try re.findAll(text);
        defer {
            for (matches.items) |match| {
                match.deinit();
            }
            matches.deinit(allocator);
        }

        std.debug.print("The word 'the' appears {} times\n\n", .{matches.items.len});
    }

    // Example 4: Find with alternation
    {
        std.debug.print("Example 4: Find Multiple Patterns\n", .{});
        std.debug.print("---------------------------------\n", .{});

        var re = try zregexp.Regex.compile(allocator, "cat|dog|bird");
        defer re.deinit();

        const text = "I have a cat and a dog, but no bird";
        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        var matches = try re.findAll(text);
        defer {
            for (matches.items) |match| {
                match.deinit();
            }
            matches.deinit(allocator);
        }

        std.debug.print("Found {} animals:\n", .{matches.items.len});
        for (matches.items, 0..) |match, i| {
            std.debug.print("  Animal {}: '{f}'\n", .{
                i + 1,
                std.zig.fmtString(match.group(text)),
            });
        }
        std.debug.print("\n", .{});
    }

    // Example 5: Using convenience function
    {
        std.debug.print("Example 5: Convenience Function\n", .{});
        std.debug.print("--------------------------------\n", .{});

        const pattern = "e";
        const text = "hello everyone";

        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(pattern)});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        var matches = try zregexp.findAll(allocator, pattern, text);
        defer {
            for (matches.items) |match| {
                match.deinit();
            }
            matches.deinit(allocator);
        }

        std.debug.print("Letter 'e' appears {} times\n", .{matches.items.len});

        // Show positions
        for (matches.items, 0..) |match, i| {
            std.debug.print("  Occurrence {}: position {}\n", .{ i + 1, match.start });
        }
        std.debug.print("\n", .{});
    }

    // Example 6: No matches
    {
        std.debug.print("Example 6: No Matches Case\n", .{});
        std.debug.print("---------------------------\n", .{});

        var re = try zregexp.Regex.compile(allocator, "xyz");
        defer re.deinit();

        const text = "hello world";
        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        var matches = try re.findAll(text);
        defer matches.deinit(allocator);

        if (matches.items.len == 0) {
            std.debug.print("No matches found\n", .{});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("=== Example Complete ===\n", .{});
}

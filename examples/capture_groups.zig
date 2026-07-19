//! Capture Groups Example
//!
//! This example demonstrates how to use capture groups to extract
//! parts of matched text.
//!
//! Build and run:
//!   zig build-exe capture_groups.zig --dep zregex --mod zregex:../src/main.zig
//!   ./capture_groups

const std = @import("std");
const zregex = @import("zregex");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Capture Groups Example ===\n\n", .{});

    // Example 1: Simple capture group
    {
        std.debug.print("Example 1: Simple Capture\n", .{});
        std.debug.print("--------------------------\n", .{});

        var re = try zregex.Regex.compile(allocator, "hello (world|there)");
        defer re.deinit();

        const text = "hello world";
        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        if (try re.find(text)) |match| {
            defer match.deinit();

            std.debug.print("Full match: '{f}'\n", .{std.zig.fmtString(match.group(text))});

            if (match.getCapture(1, text)) |captured| {
                std.debug.print("Capture group 1: '{f}'\n", .{std.zig.fmtString(captured)});
            }
        }
        std.debug.print("\n", .{});
    }

    // Example 2: Multiple capture groups
    {
        std.debug.print("Example 2: Multiple Captures\n", .{});
        std.debug.print("----------------------------\n", .{});

        var re = try zregex.Regex.compile(allocator, "(a)(b)(c)");
        defer re.deinit();

        const text = "abc";
        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        if (try re.find(text)) |match| {
            defer match.deinit();

            std.debug.print("Full match: '{f}'\n", .{std.zig.fmtString(match.group(text))});

            var i: usize = 1;
            while (i <= 3) : (i += 1) {
                if (match.getCapture(i, text)) |captured| {
                    std.debug.print("Capture group {}: '{f}'\n", .{ i, std.zig.fmtString(captured) });
                }
            }
        }
        std.debug.print("\n", .{});
    }

    // Example 3: Nested capture groups
    {
        std.debug.print("Example 3: Nested Captures\n", .{});
        std.debug.print("--------------------------\n", .{});

        var re = try zregex.Regex.compile(allocator, "((ab)c)");
        defer re.deinit();

        const text = "abc";
        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        if (try re.find(text)) |match| {
            defer match.deinit();

            std.debug.print("Full match: '{f}'\n", .{std.zig.fmtString(match.group(text))});
            std.debug.print("Capture group 1 (outer): '{f}'\n", .{std.zig.fmtString(match.getCapture(1, text).?)});
            std.debug.print("Capture group 2 (inner): '{f}'\n", .{std.zig.fmtString(match.getCapture(2, text).?)});
        }
        std.debug.print("\n", .{});
    }

    // Example 4: Extracting data from structured text
    {
        std.debug.print("Example 4: Extracting Structured Data\n", .{});
        std.debug.print("--------------------------------------\n", .{});

        // Note: Character classes like [0-9] are not fully implemented yet
        // Using simple patterns for demonstration
        var re = try zregex.Regex.compile(allocator, "User: (.*), Age: (.*)");
        defer re.deinit();

        const text = "User: Alice, Age: 30";
        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});
        std.debug.print("Text: '{f}'\n", .{std.zig.fmtString(text)});

        if (try re.find(text)) |match| {
            defer match.deinit();

            if (match.getCapture(1, text)) |name| {
                std.debug.print("Name: '{f}'\n", .{std.zig.fmtString(name)});
            }
            if (match.getCapture(2, text)) |age| {
                std.debug.print("Age: '{f}'\n", .{std.zig.fmtString(age)});
            }
        }
        std.debug.print("\n", .{});
    }

    // Example 5: Optional captures
    {
        std.debug.print("Example 5: Optional Captures\n", .{});
        std.debug.print("----------------------------\n", .{});

        var re = try zregex.Regex.compile(allocator, "a(bc)?d");
        defer re.deinit();

        const texts = [_][]const u8{ "ad", "abcd" };

        std.debug.print("Pattern: '{f}'\n", .{std.zig.fmtString(re.getPattern())});

        for (texts) |text| {
            std.debug.print("\nText: '{f}'\n", .{std.zig.fmtString(text)});

            if (try re.find(text)) |match| {
                defer match.deinit();

                std.debug.print("Full match: '{f}'\n", .{std.zig.fmtString(match.group(text))});

                if (match.getCapture(1, text)) |captured| {
                    std.debug.print("Capture group 1: '{f}'\n", .{std.zig.fmtString(captured)});
                } else {
                    std.debug.print("Capture group 1: (not captured)\n", .{});
                }
            }
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("=== Example Complete ===\n", .{});
}

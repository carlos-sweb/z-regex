//! Validation Example
//!
//! This example demonstrates using regex for input validation,
//! a common real-world use case.
//!
//! Build and run:
//!   zig build-exe validation.zig --dep zregexp --mod zregexp:../src/main.zig
//!   ./validation

const std = @import("std");
const zregexp = @import("zregexp");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Input Validation Example ===\n\n", .{});

    // Example 1: Validate exact match
    {
        std.debug.print("Example 1: Validate Exact Format\n", .{});
        std.debug.print("---------------------------------\n", .{});

        var re = try zregexp.Regex.compile(allocator, "^yes$");
        defer re.deinit();

        const inputs = [_][]const u8{ "yes", "no", "Yes", "yes ", " yes" };

        std.debug.print("Pattern: '{f}' (must be exactly 'yes')\n", .{std.zig.fmtString(re.getPattern())});

        for (inputs) |input| {
            const valid = try re.test_(input);
            std.debug.print("  '{f}' -> {s}\n", .{
                std.zig.fmtString(input),
                if (valid) "VALID" else "INVALID",
            });
        }
        std.debug.print("\n", .{});
    }

    // Example 2: Validate length with quantifiers
    {
        std.debug.print("Example 2: Validate Length\n", .{});
        std.debug.print("--------------------------\n", .{});

        var re = try zregexp.Regex.compile(allocator, "^a{3,5}$");
        defer re.deinit();

        const inputs = [_][]const u8{ "a", "aa", "aaa", "aaaa", "aaaaa", "aaaaaa" };

        std.debug.print("Pattern: '{f}' (3 to 5 'a's)\n", .{std.zig.fmtString(re.getPattern())});

        for (inputs) |input| {
            const valid = try re.test_(input);
            std.debug.print("  '{f}' ({} chars) -> {s}\n", .{
                std.zig.fmtString(input),
                input.len,
                if (valid) "VALID" else "INVALID",
            });
        }
        std.debug.print("\n", .{});
    }

    // Example 3: Validate with alternation
    {
        std.debug.print("Example 3: Validate Multiple Options\n", .{});
        std.debug.print("-------------------------------------\n", .{});

        var re = try zregexp.Regex.compile(allocator, "^(red|green|blue)$");
        defer re.deinit();

        const inputs = [_][]const u8{ "red", "green", "blue", "yellow", "Red" };

        std.debug.print("Pattern: '{f}' (valid colors)\n", .{std.zig.fmtString(re.getPattern())});

        for (inputs) |input| {
            const valid = try re.test_(input);
            std.debug.print("  '{f}' -> {s}\n", .{
                std.zig.fmtString(input),
                if (valid) "VALID" else "INVALID",
            });
        }
        std.debug.print("\n", .{});
    }

    // Example 4: Validate optional parts
    {
        std.debug.print("Example 4: Validate Optional Parts\n", .{});
        std.debug.print("-----------------------------------\n", .{});

        var re = try zregexp.Regex.compile(allocator, "^hello( world)?$");
        defer re.deinit();

        const inputs = [_][]const u8{ "hello", "hello world", "hello there", "hello  world" };

        std.debug.print("Pattern: '{f}' (optional ' world')\n", .{std.zig.fmtString(re.getPattern())});

        for (inputs) |input| {
            const valid = try re.test_(input);
            std.debug.print("  '{f}' -> {s}\n", .{
                std.zig.fmtString(input),
                if (valid) "VALID" else "INVALID",
            });
        }
        std.debug.print("\n", .{});
    }

    // Example 5: Validate prefix/suffix
    {
        std.debug.print("Example 5: Validate Prefix and Suffix\n", .{});
        std.debug.print("--------------------------------------\n", .{});

        // Must start with "cmd_" and end with ".txt"
        var re = try zregexp.Regex.compile(allocator, "^cmd_.*\\.txt$");
        defer re.deinit();

        const inputs = [_][]const u8{
            "cmd_test.txt",
            "cmd_file.txt",
            "test.txt",
            "cmd_file.md",
            "cmd_.txt",
        };

        std.debug.print("Pattern: '{f}' (must start with 'cmd_' and end with '.txt')\n", .{std.zig.fmtString(re.getPattern())});

        for (inputs) |input| {
            const valid = try re.test_(input);
            std.debug.print("  '{f}' -> {s}\n", .{
                std.zig.fmtString(input),
                if (valid) "VALID" else "INVALID",
            });
        }
        std.debug.print("\n", .{});
    }

    // Example 6: Custom validator function
    {
        std.debug.print("Example 6: Custom Validator Function\n", .{});
        std.debug.print("-------------------------------------\n", .{});

        const Validator = struct {
            fn validateCommand(alloc: std.mem.Allocator, cmd: []const u8) !bool {
                // Command must be 3-10 lowercase letters
                var re = try zregexp.Regex.compile(alloc, "^[a-z]{3,10}$");
                defer re.deinit();
                return try re.test_(cmd);
            }
        };

        const commands = [_][]const u8{ "help", "ls", "mkdir", "verylongcommand", "ABC" };

        std.debug.print("Validator: Commands must be 3-10 lowercase letters\n", .{});

        for (commands) |cmd| {
            const valid = try Validator.validateCommand(allocator, cmd);
            std.debug.print("  Command '{f}' -> {s}\n", .{
                std.zig.fmtString(cmd),
                if (valid) "VALID" else "INVALID",
            });
        }
        std.debug.print("\n", .{});
    }

    // Example 7: Batch validation
    {
        std.debug.print("Example 7: Batch Validation\n", .{});
        std.debug.print("---------------------------\n", .{});

        var re = try zregexp.Regex.compile(allocator, "^test.*");
        defer re.deinit();

        const files = [_][]const u8{
            "test_main.zig",
            "test_utils.zig",
            "main.zig",
            "test_parser.zig",
            "utils.zig",
        };

        std.debug.print("Pattern: '{f}' (find test files)\n", .{std.zig.fmtString(re.getPattern())});

        var valid_count: usize = 0;
        for (files) |file| {
            const valid = try re.test_(file);
            if (valid) {
                valid_count += 1;
                std.debug.print("  ✓ {f}\n", .{std.zig.fmtString(file)});
            } else {
                std.debug.print("  ✗ {f}\n", .{std.zig.fmtString(file)});
            }
        }

        std.debug.print("\nFound {} test files out of {} total\n\n", .{ valid_count, files.len });
    }

    std.debug.print("=== Example Complete ===\n", .{});
}

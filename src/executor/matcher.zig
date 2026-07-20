//! High-level matching API
//!
//! This module provides the main matching interface for compiled regex patterns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const recursive_mod = @import("recursive_matcher.zig");
const thread_mod = @import("thread.zig");
const format_mod = @import("../bytecode/format.zig");

const RecursiveMatcher = recursive_mod.RecursiveMatcher;
const Capture = thread_mod.Capture;
pub const NamedGroup = format_mod.NamedGroup;

/// A capture's [start, end) byte offsets into the matched input (the JS `d`
/// / `hasIndices` flag equivalent — see `MatchResult.getCaptureIndices`).
pub const CaptureIndices = struct { start: usize, end: usize };

/// Match result
pub const MatchResult = struct {
    matched: bool,
    start: usize,
    end: usize,
    captures: []Capture,
    allocator: Allocator,
    /// Borrowed from the `Regex`/`CompileResult` that produced this match;
    /// empty for patterns with no named capture groups.
    named_groups: []const NamedGroup = &.{},

    /// Free match result
    pub fn deinit(self: MatchResult) void {
        self.allocator.free(self.captures);
    }

    /// Get full matched string
    pub fn group(self: MatchResult, input: []const u8) []const u8 {
        if (!self.matched) return "";
        return input[self.start..self.end];
    }

    /// Get capture group by index
    pub fn getCapture(self: MatchResult, index: usize, input: []const u8) ?[]const u8 {
        if (!self.matched or index >= self.captures.len) return null;
        const cap = self.captures[index];
        if (!cap.isValid()) return null;
        return input[cap.start.?..cap.end.?];
    }

    /// Get capture group by name (from a named group `(?<name>...)`). A name
    /// can belong to more than one group when duplicate names are used
    /// across mutually exclusive alternation branches (`(?<x>a)|(?<x>b)`) --
    /// at most one such group can ever actually participate in a given
    /// match, so this checks every group with this name and returns
    /// whichever one did (matching JS's `match.groups.x` semantics), not
    /// just the first one declared.
    pub fn getNamedCapture(self: MatchResult, name: []const u8, input: []const u8) ?[]const u8 {
        for (self.named_groups) |ng| {
            if (std.mem.eql(u8, ng.name, name)) {
                if (self.getCapture(ng.index, input)) |value| return value;
            }
        }
        return null;
    }

    /// Get a capture group's [start, end) byte offsets by index, equivalent
    /// to JS's `match.indices[index]` under the `d` flag. There's no
    /// `has_indices`/`d` compile option here — captures always track their
    /// positions internally, so there's nothing to gate; just call this
    /// whenever indices are needed.
    pub fn getCaptureIndices(self: MatchResult, index: usize) ?CaptureIndices {
        if (!self.matched or index >= self.captures.len) return null;
        const cap = self.captures[index];
        if (!cap.isValid()) return null;
        return .{ .start = cap.start.?, .end = cap.end.? };
    }

    /// Get a named capture group's [start, end) byte offsets, equivalent to
    /// JS's `match.indices.groups[name]` under the `d` flag. Same
    /// duplicate-name handling as `getNamedCapture` -- see its doc comment.
    pub fn getNamedCaptureIndices(self: MatchResult, name: []const u8) ?CaptureIndices {
        for (self.named_groups) |ng| {
            if (std.mem.eql(u8, ng.name, name)) {
                if (self.getCaptureIndices(ng.index)) |value| return value;
            }
        }
        return null;
    }
};

/// Main matcher interface
pub const Matcher = struct {
    allocator: Allocator,
    bytecode: []const u8,
    named_groups: []const NamedGroup = &.{},

    const Self = @This();

    /// Initialize matcher with compiled bytecode
    pub fn init(allocator: Allocator, bytecode: []const u8) Self {
        return .{
            .allocator = allocator,
            .bytecode = bytecode,
        };
    }

    /// Initialize matcher with compiled bytecode and its named-group table,
    /// so `find`/`findAll` results support `MatchResult.getNamedCapture`.
    pub fn initWithNamedGroups(allocator: Allocator, bytecode: []const u8, named_groups: []const NamedGroup) Self {
        return .{
            .allocator = allocator,
            .bytecode = bytecode,
            .named_groups = named_groups,
        };
    }

    /// Check if pattern matches entire input
    pub fn matchFull(self: Self, input: []const u8) !bool {
        var matcher = RecursiveMatcher.init(self.allocator, self.bytecode, input);
        defer matcher.deinit();

        const result = try matcher.matchFrom(0, 0);

        // For full match, verify that the entire input was consumed
        return result.matched and result.end_pos == input.len;
    }

    /// Try to match starting at exactly `start_pos` (no scanning forward).
    /// This is the primitive `find`/`findAll` build on, and is also the
    /// building block for `y` (sticky) semantics at the `Regex` level: a
    /// sticky match must occur exactly at a given position or not at all.
    pub fn findAt(self: Self, input: []const u8, start_pos: usize) !?MatchResult {
        if (start_pos > input.len) return null;

        // Pass the FULL input to matcher (not a slice)
        // This allows lookbehind to see content before start_pos
        var matcher = RecursiveMatcher.init(self.allocator, self.bytecode, input);
        defer matcher.deinit();

        const result = try matcher.matchFrom(0, start_pos);
        if (!result.matched) return null;

        // Copy captures (positions are already relative to original input)
        const captures = try self.allocator.alloc(Capture, 16);
        for (0..16) |i| {
            captures[i] = Capture{
                .start = result.captures[i].start,
                .end = result.captures[i].end,
            };
        }

        return MatchResult{
            .matched = true,
            .start = start_pos,
            .end = result.end_pos,
            .captures = captures,
            .allocator = self.allocator,
            .named_groups = self.named_groups,
        };
    }

    /// Find first match in input
    pub fn find(self: Self, input: []const u8) !?MatchResult {
        var start_pos: usize = 0;
        while (start_pos <= input.len) : (start_pos += 1) {
            if (try self.findAt(input, start_pos)) |m| return m;
        }
        return null;
    }

    /// Find all matches in input. When `sticky` is true, stops at the first
    /// position that doesn't match instead of scanning ahead for the next
    /// one (matching JS's `y` flag semantics).
    pub fn findAll(self: Self, input: []const u8, sticky: bool) !std.ArrayListUnmanaged(MatchResult) {
        var matches: std.ArrayListUnmanaged(MatchResult) = .empty;
        errdefer {
            for (matches.items) |match| {
                match.deinit();
            }
            matches.deinit(self.allocator);
        }

        var pos: usize = 0;
        while (pos < input.len) {
            if (try self.findAt(input, pos)) |match_result| {
                try matches.append(self.allocator, match_result);

                // Advance past this match
                const match_len = match_result.end - pos;
                pos = pos + match_len;
                if (match_len == 0) {
                    // Empty match, advance by 1 to avoid infinite loop
                    pos += 1;
                }
            } else if (sticky) {
                // Sticky: a gap here means stop entirely, don't scan ahead
                break;
            } else {
                // No match at this position, try next
                pos += 1;
            }
        }

        return matches;
    }

    /// Test if pattern matches at start of input
    pub fn test_(self: Self, input: []const u8) !bool {
        return self.matchFull(input);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Matcher: matchFull success" {
    const compiler = @import("../codegen/compiler.zig");

    const compiled = try compiler.compileSimple(std.testing.allocator, "hello");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.matchFull("hello");

    try std.testing.expect(result);
}

test "Matcher: matchFull failure" {
    const compiler = @import("../codegen/compiler.zig");

    const compiled = try compiler.compileSimple(std.testing.allocator, "hello");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.matchFull("world");

    try std.testing.expect(!result);
}

test "Matcher: find match" {
    const compiler = @import("../codegen/compiler.zig");

    const compiled = try compiler.compileSimple(std.testing.allocator, "world");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.find("hello world");

    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "Matcher: find no match" {
    const compiler = @import("../codegen/compiler.zig");

    const compiled = try compiler.compileSimple(std.testing.allocator, "xyz");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.find("hello world");

    try std.testing.expect(result == null);
}

test "Matcher: find with capture" {
    const compiler = @import("../codegen/compiler.zig");

    const compiled = try compiler.compileSimple(std.testing.allocator, "(wo..)");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.find("hello world");

    try std.testing.expect(result != null);
    defer result.?.deinit();

    const captured = result.?.getCapture(1, "hello world");
    try std.testing.expect(captured != null);
    try std.testing.expectEqualStrings("worl", captured.?);
}

test "Matcher: findAll multiple matches" {
    const compiler = @import("../codegen/compiler.zig");

    const compiled = try compiler.compileSimple(std.testing.allocator, "a");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    var matches = try matcher.findAll("banana", false);
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

test "Matcher: findAll no matches" {
    const compiler = @import("../codegen/compiler.zig");

    const compiled = try compiler.compileSimple(std.testing.allocator, "x");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    var matches = try matcher.findAll("hello", false);
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "Matcher: test_ function" {
    const compiler = @import("../codegen/compiler.zig");

    const compiled = try compiler.compileSimple(std.testing.allocator, "test");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);

    try std.testing.expect(try matcher.test_("test"));
    try std.testing.expect(!try matcher.test_("fail"));
}

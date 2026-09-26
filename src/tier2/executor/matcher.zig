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
const nextSearchStart = RecursiveMatcher.nextSearchStart;
pub const NamedGroup = format_mod.NamedGroup;
const CompileResult = @import("../program.zig").CompileResult;
const CharSet = @import("../../ir/charset.zig").CharSet;

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
    /// Capture slots per match: the pattern's group count + 1 (D9).
    capture_slots: usize = 1,
    /// The program's CharSet table (`CompileResult.charsets`, F2b).
    charsets: []const CharSet = &.{},

    const Self = @This();

    /// Initialize matcher with compiled bytecode (the group count is read
    /// from the bytecode).
    pub fn init(allocator: Allocator, bytecode: []const u8) Self {
        return .{
            .allocator = allocator,
            .bytecode = bytecode,
            .capture_slots = RecursiveMatcher.captureSlotsIn(bytecode),
        };
    }

    /// Initialize matcher with compiled bytecode and its named-group table,
    /// so `find`/`findAll` results support `MatchResult.getNamedCapture`.
    pub fn initWithNamedGroups(allocator: Allocator, bytecode: []const u8, named_groups: []const NamedGroup) Self {
        var m = Self.init(allocator, bytecode);
        m.named_groups = named_groups;
        return m;
    }

    /// Like `initWithNamedGroups`, with the group count the compiler already
    /// knows (`CompileResult.group_count`), so nothing is scanned.
    pub fn initWithGroups(allocator: Allocator, bytecode: []const u8, named_groups: []const NamedGroup, group_count: u16) Self {
        return .{
            .allocator = allocator,
            .bytecode = bytecode,
            .named_groups = named_groups,
            .capture_slots = @as(usize, group_count) + 1,
        };
    }

    /// Everything a `CompileResult` carries: bytecode, named groups, group
    /// count and the CharSet table.
    pub fn initCompiled(allocator: Allocator, compiled: CompileResult) Self {
        var m = Self.initWithGroups(allocator, compiled.bytecode, compiled.named_groups, compiled.group_count);
        m.charsets = compiled.charsets;
        return m;
    }

    /// Check if pattern matches entire input
    pub fn matchFull(self: Self, input: []const u8) !bool {
        var matcher = RecursiveMatcher.initWithSlots(self.allocator, self.bytecode, input, .{}, self.capture_slots);
        matcher.charsets = self.charsets;
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
        var matcher = RecursiveMatcher.initWithSlots(self.allocator, self.bytecode, input, .{}, self.capture_slots);
        matcher.charsets = self.charsets;
        defer matcher.deinit();

        const result = try matcher.matchFrom(0, start_pos);
        if (!result.matched) return null;

        // Copy captures (positions are already relative to original input),
        // one slot per group of the pattern (D9: no fixed cap).
        const found = matcher.captureSlice();
        const captures = try self.allocator.alloc(Capture, found.len);
        for (found, captures) |c, *out| {
            out.* = Capture{ .start = c.start, .end = c.end };
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
        while (start_pos <= input.len) : (start_pos = nextSearchStart(input, start_pos)) {
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
                    // Empty match: step over one character to avoid an
                    // infinite loop (a whole UTF-8 sequence, not a byte).
                    pos = nextSearchStart(input, pos);
                }
            } else if (sticky) {
                // Sticky: a gap here means stop entirely, don't scan ahead
                break;
            } else {
                // No match at this position, try the next character
                pos = nextSearchStart(input, pos);
            }
        }

        return matches;
    }

    /// Test if pattern matches at start of input
    pub fn test_(self: Self, input: []const u8) !bool {
        return self.matchFull(input);
    }
};

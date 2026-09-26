//! High-level matching API
//!
//! This module provides the main matching interface for compiled regex patterns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const recursive_mod = @import("recursive_matcher.zig");
const thread_mod = @import("thread.zig");
const format_mod = @import("../bytecode/format.zig");

const RecursiveMatcher = recursive_mod.RecursiveMatcher;
const RecursiveMatcherFor = recursive_mod.RecursiveMatcherFor;
const Capture = thread_mod.Capture;
const nextSearchStart = RecursiveMatcher.nextSearchStart;
pub const Scratch = recursive_mod.Scratch;
pub const ExecOptions = recursive_mod.ExecOptions;
const Subject = @import("subject").Subject;

/// What `Matcher.exec` can fail with: the matcher's errors, an `index`
/// that isn't a position of the subject (F3a: inside a character), and
/// `slots` shorter than two per group plus two for the match.
pub const ExecError = MatchError || error{ InvalidIndex, SlotsTooSmall };
/// What the byte-offset facade (`find`, `findAt`, ...) can fail with.
pub const MatchError = RecursiveMatcher.MatchError;
pub const NamedGroup = format_mod.NamedGroup;
const CompileResult = @import("../program.zig").CompileResult;
const CharSet = @import("ir").charset.CharSet;

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

    /// Slots `exec` fills: start and end of the match, then of each group.
    pub fn slotCount(self: Self) usize {
        return 2 * self.capture_slots;
    }

    fn subjectOf(comptime Unit: type, input: []const Unit) Subject {
        return if (Unit == u8) .{ .wtf8 = input } else .{ .utf16 = input };
    }

    /// The execution primitive (F3c): a match starting exactly at `index`
    /// when `sticky`, or the first one at `index` or after (advancing one
    /// character at a time). On a match, fills `slots` (start and end of
    /// the match, then of each group, null for a group that didn't take
    /// part) and returns true. An `index` past the end is no match; one
    /// inside a character is `error.InvalidIndex`. Allocates only when a
    /// buffer of `scratch` has to grow.
    pub fn exec(self: Self, comptime Unit: type, input: []const Unit, index: usize, sticky: bool, scratch: *Scratch, slots: []?usize, limits: ExecOptions) ExecError!bool {
        if (slots.len < self.slotCount()) return error.SlotsTooSmall;
        if (index > input.len) return false;
        const subject = subjectOf(Unit, input);
        if (!subject.isPosition(index)) return error.InvalidIndex;
        scratch.acquire();
        defer scratch.release();

        var m = try RecursiveMatcherFor(Unit).initScratch(self.bytecode, input, limits, self.capture_slots, scratch);
        m.charsets = self.charsets;
        defer m.releaseScratch(scratch);
        var pos = index;
        while (pos <= input.len) : (pos = subject.advanceIndex(.code_point, pos)) {
            if (pos != index) m.reset();
            const r = try m.matchFrom(0, pos);
            if (r.matched) {
                slots[0] = pos;
                slots[1] = r.end_pos;
                for (m.captureSlice()[1..], 1..) |c, g| {
                    slots[2 * g] = c.start;
                    slots[2 * g + 1] = c.end;
                }
                return true;
            }
            if (sticky) break;
        }
        return false;
    }

    /// `exec` into a new `MatchResult` (byte offsets). An index inside a
    /// character is no match.
    fn execResult(self: Self, input: []const u8, index: usize, sticky: bool, scratch: *Scratch) MatchError!?MatchResult {
        // Slots on the stack when they fit (most patterns), so a facade
        // call allocates only its result.
        var stack_slots: [64]?usize = undefined;
        const heap = self.slotCount() > stack_slots.len;
        const slots = if (heap) try self.allocator.alloc(?usize, self.slotCount()) else stack_slots[0..self.slotCount()];
        defer if (heap) self.allocator.free(slots);
        const found = self.exec(u8, input, index, sticky, scratch, slots, .{}) catch |err| switch (err) {
            error.InvalidIndex => return null,
            error.SlotsTooSmall => unreachable,
            else => |e| return e,
        };
        if (!found) return null;
        const captures = try self.allocator.alloc(Capture, self.capture_slots);
        // Slot 0 of `captures` is never a group (group 0 is the match).
        captures[0] = .{};
        for (captures[1..], 1..) |*c, g| c.* = .{ .start = slots[2 * g], .end = slots[2 * g + 1] };
        return MatchResult{
            .matched = true,
            .start = slots[0].?,
            .end = slots[1].?,
            .captures = captures,
            .allocator = self.allocator,
            .named_groups = self.named_groups,
        };
    }

    /// Check if pattern matches entire input
    pub fn matchFull(self: Self, input: []const u8) MatchError!bool {
        var scratch = Scratch.init(self.allocator);
        defer scratch.deinit();
        const m = (try self.execResult(input, 0, true, &scratch)) orelse return false;
        defer m.deinit();
        // For full match, verify that the entire input was consumed
        return m.end == input.len;
    }

    /// Try to match starting at exactly `start_pos` (no scanning forward).
    /// This is the primitive `find`/`findAll` build on, and is also the
    /// building block for `y` (sticky) semantics at the `Regex` level: a
    /// sticky match must occur exactly at a given position or not at all.
    /// A `start_pos` inside a character (not a position of the subject,
    /// F3c) is no match.
    pub fn findAt(self: Self, input: []const u8, start_pos: usize) MatchError!?MatchResult {
        var scratch = Scratch.init(self.allocator);
        defer scratch.deinit();
        return self.execResult(input, start_pos, true, &scratch);
    }

    /// Find first match in input
    pub fn find(self: Self, input: []const u8) MatchError!?MatchResult {
        return self.findFrom(input, 0);
    }

    /// The first match starting at `start_pos` or after.
    pub fn findFrom(self: Self, input: []const u8, start_pos: usize) MatchError!?MatchResult {
        var scratch = Scratch.init(self.allocator);
        defer scratch.deinit();
        return self.execResult(input, start_pos, false, &scratch);
    }

    /// Find all matches in input. When `sticky` is true, stops at the first
    /// position that doesn't match instead of scanning ahead for the next
    /// one (matching JS's `y` flag semantics). Never reports a match that
    /// starts at the end of the input.
    pub fn findAll(self: Self, input: []const u8, sticky: bool) MatchError!std.ArrayListUnmanaged(MatchResult) {
        var matches: std.ArrayListUnmanaged(MatchResult) = .empty;
        errdefer {
            for (matches.items) |match| {
                match.deinit();
            }
            matches.deinit(self.allocator);
        }
        var scratch = Scratch.init(self.allocator);
        defer scratch.deinit();

        var pos: usize = 0;
        while (pos < input.len) {
            const match_result = (try self.execResult(input, pos, sticky, &scratch)) orelse break;
            if (match_result.start >= input.len) {
                match_result.deinit();
                break;
            }
            try matches.append(self.allocator, match_result);

            // Advance past this match; after an empty match, step over one
            // character to avoid an infinite loop.
            pos = match_result.end;
            if (match_result.end == match_result.start) pos = nextSearchStart(input, pos);
        }

        return matches;
    }

    /// Test if pattern matches at start of input
    pub fn test_(self: Self, input: []const u8) !bool {
        return self.matchFull(input);
    }
};

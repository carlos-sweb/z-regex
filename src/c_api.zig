//! C Foreign Function Interface (FFI) for zregex
//!
//! This module implements the C API defined in zregex.h by wrapping the Zig regex module.
//! It handles memory management, error handling, and type conversions between C and Zig.

const std = @import("std");
const regex = @import("zregex");
const Regex = regex.Regex;
const MatchResult = regex.MatchResult;
const Allocator = std.mem.Allocator;

// =============================================================================
// Global State
// =============================================================================

/// Global allocator for FFI operations
var gpa: std.heap.DebugAllocator(.{}) = .init;
/// In test builds it goes through `test_alloc`, which can be told to fail
/// (to exercise the out-of-memory paths); elsewhere it's `gpa` itself.
const allocator: Allocator = if (@import("builtin").is_test) test_alloc.allocator() else gpa.allocator();

/// Test builds only: `gpa`, failing every allocation while `fail` is set.
const test_alloc = struct {
    threadlocal var fail: bool = false;

    fn allocator() Allocator {
        return .{ .ptr = undefined, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        if (fail) return null;
        return gpa.allocator().rawAlloc(len, alignment, ret);
    }
    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        if (fail and new_len > memory.len) return false;
        return gpa.allocator().rawResize(memory, alignment, new_len, ret);
    }
    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        if (fail and new_len > memory.len) return null;
        return gpa.allocator().rawRemap(memory, alignment, new_len, ret);
    }
    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        gpa.allocator().rawFree(memory, alignment, ret);
    }
};

/// Thread-local error state
threadlocal var last_error: ZRegexError = .ZREGEXP_OK;

/// `@errorName` of the Zig error behind `last_error` ("" when none). The
/// coarse `ZRegexError` codes lump most syntax errors into UNKNOWN; this
/// keeps the precise reason for callers that need it (the test262
/// harness tells a zregex SyntaxError apart from a resource limit).
threadlocal var last_error_name: [*:0]const u8 = "";

// =============================================================================
// Opaque Type Definitions
// =============================================================================

/// Opaque handle to a compiled regular expression (maps to regex.Regex)
pub const ZRegex = Regex;

/// Opaque handle to a match result (maps to MatchResultWrapper)
pub const ZMatch = struct {
    result: MatchResult,
    input: []const u8, // Need to keep input for getCapture
    // Note: No caching - strings are created on demand and must be freed by caller
};

/// Opaque handle to a list of match results
pub const ZMatchList = struct {
    matches: std.ArrayList(ZMatch),
};

// =============================================================================
// Error Codes (must match zregex.h)
// =============================================================================

pub const ZRegexError = enum(c_int) {
    ZREGEXP_OK = 0,
    ZREGEXP_ERROR_SYNTAX = 1,
    ZREGEXP_ERROR_OUT_OF_MEMORY = 2,
    ZREGEXP_ERROR_RECURSION_LIMIT = 3,
    ZREGEXP_ERROR_STEP_LIMIT = 4,
    ZREGEXP_ERROR_INVALID_GROUP = 5,
    ZREGEXP_ERROR_UNMATCHED_PAREN = 6,
    ZREGEXP_ERROR_INVALID_RANGE = 7,
    ZREGEXP_ERROR_UNKNOWN = 8,
    /// A valid pattern this engine can't run yet: a lookbehind of variable
    /// length or with a capture group inside (F6b step 1, B′). A new value
    /// at the end: no symbol or struct changes.
    ZREGEXP_ERROR_UNSUPPORTED = 9,
};

// =============================================================================
// Compilation Options (must match zregex.h)
// =============================================================================

pub const ZRegexOptions = extern struct {
    case_insensitive: bool,
    multiline: bool,
    dot_all: bool,
    sticky: bool,
    unicode: bool,
    v: bool,
    /// Reserved: no effect since F6a (the backtracker keeps its stack on
    /// the heap, bounded by `ExecLimits.max_backtrack_stack_bytes`).
    max_recursion_depth: u32,
    /// The backtracker's step budget per start position
    /// (`ExecLimits.max_steps`); 0 keeps the default.
    max_steps: u64,
    reserved: [4]u32,
};

// =============================================================================
// Helper Functions
// =============================================================================

/// A failure with no Zig error behind it (an argument out of range): the
/// code, and its name from `codeName`.
fn setError(err: ZRegexError) void {
    last_error = err;
    last_error_name = codeName(err);
}

/// The name `zregex_last_error_name` reports for a failure known only by
/// its code: one entry per `ZRegexError`.
fn codeName(err: ZRegexError) [*:0]const u8 {
    return switch (err) {
        .ZREGEXP_OK => "",
        .ZREGEXP_ERROR_SYNTAX => "SyntaxError",
        .ZREGEXP_ERROR_OUT_OF_MEMORY => "OutOfMemory",
        .ZREGEXP_ERROR_RECURSION_LIMIT => "BacktrackStackExhausted",
        .ZREGEXP_ERROR_STEP_LIMIT => "StepLimitExceeded",
        .ZREGEXP_ERROR_INVALID_GROUP => "InvalidGroup",
        .ZREGEXP_ERROR_UNMATCHED_PAREN => "UnmatchedParen",
        .ZREGEXP_ERROR_INVALID_RANGE => "InvalidCharRange",
        .ZREGEXP_ERROR_UNKNOWN => "Unknown",
        .ZREGEXP_ERROR_UNSUPPORTED => "UnsupportedFeature",
    };
}

fn setZigError(err: anyerror) void {
    last_error = zigErrorToC(err);
    last_error_name = @errorName(err);
}

fn clearError() void {
    last_error = .ZREGEXP_OK;
    last_error_name = "";
}

/// The C code of a Zig error: the table of docs/API.md, section 3. What is
/// left in UNKNOWN is an implementation limit, an engine invariant or an
/// error nothing produces, not a SyntaxError of the pattern.
fn zigErrorToC(err: anytype) ZRegexError {
    return switch (err) {
        error.OutOfMemory => .ZREGEXP_ERROR_OUT_OF_MEMORY,
        error.RecursionLimitExceeded, error.BacktrackStackExhausted => .ZREGEXP_ERROR_RECURSION_LIMIT,
        error.StepLimitExceeded => .ZREGEXP_ERROR_STEP_LIMIT,
        error.UnmatchedParen => .ZREGEXP_ERROR_UNMATCHED_PAREN,
        error.InvalidEscape, error.InvalidQuantifier, error.IncompatibleFlags => .ZREGEXP_ERROR_SYNTAX,
        // F7c-4: UNKNOWN until 0.6.0.
        error.UnexpectedToken,
        error.UnexpectedEOF,
        error.UnmatchedBracket,
        error.DuplicateGroupName,
        error.UnknownGroupName,
        error.InvalidGroupName,
        error.InvalidRepeat,
        error.UnterminatedRepeat,
        error.UnknownUnicodeProperty,
        error.InvalidClassSetOperand,
        error.MixedClassSetOperators,
        => .ZREGEXP_ERROR_SYNTAX,
        error.InvalidCharRange => .ZREGEXP_ERROR_INVALID_RANGE,
        error.UnsupportedFeature => .ZREGEXP_ERROR_UNSUPPORTED,
        else => .ZREGEXP_ERROR_UNKNOWN,
    };
}

fn cStringToSlice(str: [*:0]const u8) []const u8 {
    return std.mem.span(str);
}

fn sliceToCString(slice: []const u8) ![]u8 {
    // Allocate len+1 bytes as a regular slice
    const buf = try allocator.alloc(u8, slice.len + 1);
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    // Return the full buffer - this will be freed with its full length
    return buf;
}

// =============================================================================
// Version Information
// =============================================================================

export fn zregex_version() [*:0]const u8 {
    return regex.version;
}

// =============================================================================
// Options
// =============================================================================

export fn zregex_default_options() ZRegexOptions {
    return .{
        .case_insensitive = false,
        .multiline = false,
        .dot_all = false,
        .sticky = false,
        .unicode = false,
        .v = false,
        .max_recursion_depth = 1000,
        .max_steps = 1000000,
        .reserved = [_]u32{0} ** 4,
    };
}

// =============================================================================
// Compilation and Destruction
// =============================================================================

export fn zregex_compile(pattern: [*:0]const u8, options: ?*const ZRegexOptions) ?*ZRegex {
    clearError();

    const pattern_slice = cStringToSlice(pattern);

    // `max_steps` becomes the regex's own limit (`applyLimits`), used by
    // every execution through this API.
    var re = if (options) |opts| blk: {
        const compile_opts = regex.CompileOptions{
            .case_insensitive = opts.case_insensitive,
            .multiline = opts.multiline,
            .dot_all = opts.dot_all,
            .sticky = opts.sticky,
            .unicode = opts.unicode,
            .v = opts.v,
        };
        break :blk Regex.compileWithOptions(allocator, pattern_slice, compile_opts) catch |err| {
            setZigError(err);
            return null;
        };
    } else blk: {
        break :blk Regex.compile(allocator, pattern_slice) catch |err| {
            setZigError(err);
            return null;
        };
    };

    if (options) |opts| applyLimits(&re, opts);

    // Allocate on heap
    const heap_re = allocator.create(Regex) catch {
        re.deinit();
        setZigError(error.OutOfMemory);
        return null;
    };
    heap_re.* = re;

    return heap_re;
}

/// The execution limits of `ZRegexOptions` on the compiled regex: `max_steps`
/// (0 keeps the default); `max_recursion_depth` is reserved.
fn applyLimits(re: *Regex, opts: *const ZRegexOptions) void {
    if (opts.max_steps > 0) re.limits.max_steps = std.math.cast(usize, opts.max_steps) orelse std.math.maxInt(usize);
}

export fn zregex_free(re: ?*ZRegex) void {
    if (re) |r| {
        r.deinit();
        allocator.destroy(r);
    }
}

// =============================================================================
// Named Groups
// =============================================================================

export fn zregex_named_group_count(re: *ZRegex) usize {
    return re.compiled.named_groups.len;
}

export fn zregex_named_group_name(re: *ZRegex, index: usize) ?[*:0]u8 {
    clearError();

    if (index >= re.compiled.named_groups.len) {
        setError(.ZREGEXP_ERROR_INVALID_GROUP);
        return null;
    }

    const buf = sliceToCString(re.compiled.named_groups[index].name) catch {
        setZigError(error.OutOfMemory);
        return null;
    };

    // Caller must free with zregex_string_free()
    return @ptrCast(@constCast(buf.ptr));
}

/// The group number of named group `index`, or 0 (never a named group's)
/// with ZREGEXP_ERROR_INVALID_GROUP when `index` is out of range.
export fn zregex_named_group_index(re: *ZRegex, index: usize) usize {
    clearError();
    if (index >= re.compiled.named_groups.len) {
        setError(.ZREGEXP_ERROR_INVALID_GROUP);
        return 0;
    }
    return re.compiled.named_groups[index].index;
}

// =============================================================================
// Matching Functions
// =============================================================================

/// Wrap a matched `MatchResult` (and a duplicate of the input it matched
/// against) in a heap-allocated `ZMatch`, or clean up and report an error.
/// Shared by `zregex_find` and `zregex_find_at`.
fn wrapMatch(input_slice: []const u8, match: MatchResult) ?*ZMatch {
    const input_dup = allocator.dupe(u8, input_slice) catch {
        match.deinit();
        setZigError(error.OutOfMemory);
        return null;
    };

    const heap_match = allocator.create(ZMatch) catch {
        allocator.free(input_dup);
        match.deinit();
        setZigError(error.OutOfMemory);
        return null;
    };

    heap_match.* = .{
        .result = match,
        .input = input_dup,
    };

    return heap_match;
}

export fn zregex_find(re: *ZRegex, input: [*:0]const u8) ?*ZMatch {
    clearError();

    const input_slice = cStringToSlice(input);

    const result = re.find(input_slice) catch |err| {
        setZigError(err);
        return null;
    };

    if (result) |match| return wrapMatch(input_slice, match);
    return null;
}

export fn zregex_find_at(re: *ZRegex, input: [*:0]const u8, start_byte_offset: usize) ?*ZMatch {
    clearError();

    const input_slice = cStringToSlice(input);

    const result = re.findAt(input_slice, start_byte_offset) catch |err| {
        setZigError(err);
        return null;
    };

    if (result) |match| return wrapMatch(input_slice, match);
    return null;
}

export fn zregex_find_all(re: *ZRegex, input: [*:0]const u8) ?*ZMatchList {
    clearError();

    const input_slice = cStringToSlice(input);

    var matches_unmanaged = re.findAll(input_slice) catch |err| {
        setZigError(err);
        return null;
    };

    // Convert to managed ArrayList
    var match_list: std.ArrayList(ZMatch) = .empty;

    // Duplicate input once for all matches
    const input_dup = allocator.dupe(u8, input_slice) catch {
        for (matches_unmanaged.items) |m| m.deinit();
        matches_unmanaged.deinit(allocator);
        setZigError(error.OutOfMemory);
        return null;
    };

    for (matches_unmanaged.items) |match| {
        match_list.append(allocator, .{
            .result = match,
            .input = input_dup,
        }) catch {
            allocator.free(input_dup);
            for (matches_unmanaged.items) |m| m.deinit();
            matches_unmanaged.deinit(allocator);
            match_list.deinit(allocator);
            setZigError(error.OutOfMemory);
            return null;
        };
    }

    matches_unmanaged.deinit(allocator);

    const heap_list = allocator.create(ZMatchList) catch {
        allocator.free(input_dup);
        match_list.deinit(allocator);
        setZigError(error.OutOfMemory);
        return null;
    };

    heap_list.* = .{ .matches = match_list };
    return heap_list;
}

export fn zregex_is_match(re: *ZRegex, input: [*:0]const u8) bool {
    clearError();

    const input_slice = cStringToSlice(input);

    const match = re.find(input_slice) catch |err| {
        setZigError(err);
        return false;
    };

    if (match) |m| {
        m.deinit();
        return true;
    }

    return false;
}

// =============================================================================
// Match Result Functions
// =============================================================================

export fn zregex_match_slice(match: *ZMatch) [*:0]u8 {
    clearError();
    const slice = match.result.group(match.input);
    const buf = sliceToCString(slice) catch {
        setZigError(error.OutOfMemory);
        return @constCast("");
    };
    // Caller must free with zregex_string_free()
    return @ptrCast(@constCast(buf.ptr));
}

export fn zregex_match_start(match: *ZMatch) usize {
    return match.result.start;
}

export fn zregex_match_end(match: *ZMatch) usize {
    return match.result.end;
}

export fn zregex_match_group(match: *ZMatch, group_index: usize) ?[*:0]u8 {
    clearError();
    // Group 0 is the full match; it isn't stored in the internal captures
    // array (which is 1-indexed by capture group number), so it needs its
    // own path rather than going through `MatchResult.getCapture`.
    if (group_index == 0) {
        const buf = sliceToCString(match.result.group(match.input)) catch {
            setZigError(error.OutOfMemory);
            return null;
        };
        return @ptrCast(@constCast(buf.ptr));
    }

    // Any group the pattern has (D9: no fixed cap); past the last one it's
    // an invalid group, not merely an unmatched one.
    if (group_index >= match.result.captures.len) {
        setError(.ZREGEXP_ERROR_INVALID_GROUP);
        return null;
    }

    const capture = match.result.getCapture(group_index, match.input) orelse return null;

    const buf = sliceToCString(capture) catch {
        setZigError(error.OutOfMemory);
        return null;
    };

    // Caller must free with zregex_string_free()
    return @ptrCast(@constCast(buf.ptr));
}

/// Sentinel for "group doesn't exist or didn't participate" -- matches
/// `ZREGEXP_NO_CAPTURE` in zregex.h.
const NO_CAPTURE: usize = std.math.maxInt(usize);

export fn zregex_match_capture_start(match: *ZMatch, group_index: usize) usize {
    // See the comment in zregex_match_group: group 0 (the full match)
    // isn't in the internal captures array and needs its own path.
    if (group_index == 0) return match.result.start;
    const idx = match.result.getCaptureIndices(group_index) orelse return NO_CAPTURE;
    return idx.start;
}

export fn zregex_match_capture_end(match: *ZMatch, group_index: usize) usize {
    if (group_index == 0) return match.result.end;
    const idx = match.result.getCaptureIndices(group_index) orelse return NO_CAPTURE;
    return idx.end;
}

export fn zregex_match_named_capture_start(match: *ZMatch, name: [*:0]const u8) usize {
    const idx = match.result.getNamedCaptureIndices(cStringToSlice(name)) orelse return NO_CAPTURE;
    return idx.start;
}

export fn zregex_match_named_capture_end(match: *ZMatch, name: [*:0]const u8) usize {
    const idx = match.result.getNamedCaptureIndices(cStringToSlice(name)) orelse return NO_CAPTURE;
    return idx.end;
}

export fn zregex_match_free(match: ?*ZMatch) void {
    if (match) |m| {
        m.result.deinit();
        allocator.free(m.input);
        allocator.destroy(m);
    }
}

// =============================================================================
// Match List Functions
// =============================================================================

export fn zregex_match_list_count(list: *ZMatchList) usize {
    return list.matches.items.len;
}

export fn zregex_match_list_get(list: *ZMatchList, index: usize) ?*ZMatch {
    if (index >= list.matches.items.len) {
        return null;
    }
    return &list.matches.items[index];
}

export fn zregex_match_list_free(list: ?*ZMatchList) void {
    if (list) |l| {
        // Free input (shared by all matches in list)
        if (l.matches.items.len > 0) {
            allocator.free(l.matches.items[0].input);
        }

        // Free all match results
        for (l.matches.items) |*m| {
            m.result.deinit();
        }

        l.matches.deinit(allocator);
        allocator.destroy(l);
    }
}

// =============================================================================
// String Replacement
// =============================================================================

export fn zregex_replace(re: *ZRegex, input: [*:0]const u8, replacement: [*:0]const u8) ?[*:0]u8 {
    clearError();

    const input_slice = cStringToSlice(input);
    const replacement_slice = cStringToSlice(replacement);

    const result = re.replace(allocator, input_slice, replacement_slice) catch |err| {
        setZigError(err);
        return null;
    };
    defer allocator.free(result);

    const buf = sliceToCString(result) catch {
        setZigError(error.OutOfMemory);
        return null;
    };

    return @ptrCast(@constCast(buf.ptr));
}

export fn zregex_replace_all(re: *ZRegex, input: [*:0]const u8, replacement: [*:0]const u8) ?[*:0]u8 {
    clearError();

    const input_slice = cStringToSlice(input);
    const replacement_slice = cStringToSlice(replacement);

    const result = re.replaceAll(allocator, input_slice, replacement_slice) catch |err| {
        setZigError(err);
        return null;
    };
    defer allocator.free(result);

    const buf = sliceToCString(result) catch {
        setZigError(error.OutOfMemory);
        return null;
    };

    return @ptrCast(@constCast(buf.ptr));
}

export fn zregex_string_free(str: ?[*:0]u8) void {
    if (str) |s| {
        // Reconstruct the full buffer (len + 1 for null)
        const len = std.mem.len(s);
        const buf: []u8 = @constCast(@as([*]u8, @ptrCast(s))[0 .. len + 1]);
        allocator.free(buf);
    }
}

// =============================================================================
// Error Handling
// =============================================================================

export fn zregex_last_error() ZRegexError {
    return last_error;
}

export fn zregex_error_message(err: ZRegexError) [*:0]const u8 {
    return switch (err) {
        .ZREGEXP_OK => "No error",
        .ZREGEXP_ERROR_SYNTAX => "Syntax error in pattern",
        .ZREGEXP_ERROR_OUT_OF_MEMORY => "Out of memory",
        .ZREGEXP_ERROR_RECURSION_LIMIT => "Recursion depth limit exceeded",
        .ZREGEXP_ERROR_STEP_LIMIT => "Execution step limit exceeded",
        .ZREGEXP_ERROR_INVALID_GROUP => "Invalid capture group number",
        .ZREGEXP_ERROR_UNMATCHED_PAREN => "Unmatched parenthesis",
        .ZREGEXP_ERROR_INVALID_RANGE => "Invalid character range",
        .ZREGEXP_ERROR_UNKNOWN => "Unknown error",
        .ZREGEXP_ERROR_UNSUPPORTED => "Pattern uses a feature not supported yet (lookbehind of variable length or with captures)",
    };
}

export fn zregex_clear_error() void {
    clearError();
}

// =============================================================================
// Length-taking entry points
// =============================================================================
//
// The NUL-terminated functions above can't represent a pattern or subject
// that contains U+0000, which test262 exercises. These take an explicit
// byte length and otherwise behave like their NUL-terminated counterparts;
// they add no engine behavior. Offsets are byte offsets into the subject.

/// Like `zregex_compile`, for a pattern of `len` bytes that may contain NUL.
export fn zregex_compile_n(pattern: [*]const u8, len: usize, options: ?*const ZRegexOptions) ?*ZRegex {
    clearError();
    const pattern_slice = pattern[0..len];
    const compile_opts: regex.CompileOptions = if (options) |opts| .{
        .case_insensitive = opts.case_insensitive,
        .multiline = opts.multiline,
        .dot_all = opts.dot_all,
        .sticky = opts.sticky,
        .unicode = opts.unicode,
        .v = opts.v,
    } else .{};
    var re = Regex.compileWithOptions(allocator, pattern_slice, compile_opts) catch |err| {
        setZigError(err);
        return null;
    };
    if (options) |opts| applyLimits(&re, opts);
    const heap_re = allocator.create(Regex) catch {
        re.deinit();
        setZigError(error.OutOfMemory);
        return null;
    };
    heap_re.* = re;
    return heap_re;
}

/// Match anchored exactly at `start` (no scanning ahead), like
/// `zregex_find_at`, for a subject of `len` bytes that may contain NUL.
/// Returns null on no match; check `zregex_last_error` to tell a failure
/// (e.g. a step limit) from a plain non-match.
export fn zregex_match_at_n(re: *ZRegex, input: [*]const u8, len: usize, start: usize) ?*ZMatch {
    clearError();
    const input_slice = input[0..len];
    const result = re.findAt(input_slice, start) catch |err| {
        setZigError(err);
        return null;
    };
    if (result) |match| return wrapMatch(input_slice, match);
    return null;
}

/// First match starting at or after byte `start`, advancing one character
/// at a time exactly like `Regex.find` does from 0. Returns null on no match; see
/// `zregex_match_at_n` for telling failures apart.
export fn zregex_search_n(re: *ZRegex, input: [*]const u8, len: usize, start: usize) ?*ZMatch {
    clearError();
    const input_slice = input[0..len];
    // A search never starts in the middle of a character (F3c): from a
    // `start` inside one, it starts at the next position.
    var pos = start;
    const subject: regex.Subject = .{ .wtf8 = input_slice };
    while (pos <= len and !subject.isPosition(pos)) pos += 1;
    const result = re.findFrom(input_slice, pos) catch |err| {
        setZigError(err);
        return null;
    };
    if (result) |match| return wrapMatch(input_slice, match);
    return null;
}

// =============================================================================
// Execution over WTF-8 or UTF-16 (F3c)
// =============================================================================

/// One `Scratch` per thread for the exec functions below (they never run
/// a match from inside another). Its buffers live until the thread ends.
threadlocal var tls_scratch: ?regex.Scratch = null;

fn threadScratch() *regex.Scratch {
    if (tls_scratch == null) tls_scratch = regex.Scratch.init(allocator);
    return &tls_scratch.?;
}

/// `Regex.execAt` with the stickiness chosen per call: fills `slots` (`nslots`
/// entries, at least 2 * (zregex_group_count + 1)) with the start and end of
/// the match and of each group, `ZREGEXP_NO_CAPTURE` for a group that didn't
/// take part. Returns 1 on a match, 0 on none, -1 on an error (see
/// `zregex_last_error_name`: e.g. "InvalidIndex" for an index inside a
/// character, "SlotsTooSmall").
fn execC(re: *ZRegex, subject: regex.Subject, index: usize, sticky: bool, slots: [*]usize, nslots: usize) c_int {
    clearError();
    var r = re.*;
    r.sticky = sticky;
    var stack_slots: [64]?usize = undefined;
    const n = @min(nslots, r.slotCount());
    const buf: []?usize = if (n <= stack_slots.len) stack_slots[0..n] else allocator.alloc(?usize, n) catch {
        setZigError(error.OutOfMemory);
        return -1;
    };
    defer if (n > stack_slots.len) allocator.free(buf);
    var out: regex.MatchSlots = .{ .slots = buf };
    const found = r.execAt(subject, index, threadScratch(), &out, r.limits) catch |err| {
        setZigError(err);
        return -1;
    };
    if (!found) return 0;
    for (buf, 0..) |v, i| slots[i] = v orelse NO_CAPTURE;
    return 1;
}

/// `execC` over `len` bytes of WTF-8; indices are byte offsets (with `b+2`
/// between the halves of a 4-byte character, see the `subject` module).
export fn zregex_exec_wtf8(re: *ZRegex, input: [*]const u8, len: usize, index: usize, sticky: bool, slots: [*]usize, nslots: usize) c_int {
    return execC(re, .{ .wtf8 = input[0..len] }, index, sticky, slots, nslots);
}

/// `execC` over `len` UTF-16 code units; indices are code-unit offsets.
export fn zregex_exec_utf16(re: *ZRegex, input: [*]const u16, len: usize, index: usize, sticky: bool, slots: [*]usize, nslots: usize) c_int {
    return execC(re, .{ .utf16 = input[0..len] }, index, sticky, slots, nslots);
}

/// `Regex.advanceIndex` over WTF-8 bytes.
export fn zregex_advance_index_wtf8(re: *ZRegex, input: [*]const u8, len: usize, index: usize) usize {
    return re.advanceIndex(.{ .wtf8 = input[0..len] }, index);
}

/// `Regex.advanceIndex` over UTF-16 code units.
export fn zregex_advance_index_utf16(re: *ZRegex, input: [*]const u16, len: usize, index: usize) usize {
    return re.advanceIndex(.{ .utf16 = input[0..len] }, index);
}

/// Number of capturing groups in the pattern (not counting group 0).
export fn zregex_group_count(re: *ZRegex) usize {
    return re.compiled.group_count;
}

/// `@errorName` of the last failure on this thread, or "" if none. The
/// string is static; don't free it. Every function of the C API that can
/// fail records it with `zregex_last_error`: the Zig error's own name when
/// there is one (`UnexpectedToken`, `StepLimitExceeded`, `OutOfMemory`,
/// ...), else the code's (`InvalidGroup` for an index out of range).
export fn zregex_last_error_name() [*:0]const u8 {
    return last_error_name;
}

// =============================================================================
// Utility Functions
// =============================================================================

export fn zregex_escape(input: [*:0]const u8) ?[*:0]u8 {
    clearError();

    const input_slice = cStringToSlice(input);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    // Characters that need escaping in regex
    const special_chars = "\\^$.|?*+()[]{}";

    for (input_slice) |c| {
        if (std.mem.indexOfScalar(u8, special_chars, c) != null) {
            result.append(allocator, '\\') catch {
                setZigError(error.OutOfMemory);
                return null;
            };
        }
        result.append(allocator, c) catch {
            setZigError(error.OutOfMemory);
            return null;
        };
    }

    const buf = sliceToCString(result.items) catch {
        setZigError(error.OutOfMemory);
        return null;
    };

    return @ptrCast(@constCast(buf.ptr));
}

export fn zregex_is_valid_pattern(pattern: [*:0]const u8) bool {
    clearError();

    const pattern_slice = cStringToSlice(pattern);

    var re = Regex.compile(allocator, pattern_slice) catch {
        return false;
    };
    defer re.deinit();

    return true;
}

// =============================================================================
// Tests
// =============================================================================

// F7c-4: the C codes of docs/API.md, section 3, for every RegexError and
// ExecError: any change fails here until the table changes with it.
test "the error codes of the API contract (docs/API.md)" {
    const Code = ZRegexError;
    const Expected = struct { names: []const []const u8, code: Code };
    const table = [_]Expected{
        .{ .names = &.{
            "InvalidEscape",          "InvalidQuantifier",      "IncompatibleFlags",
            "UnexpectedToken",        "UnexpectedEOF",          "UnmatchedBracket",
            "DuplicateGroupName",     "UnknownGroupName",       "InvalidGroupName",
            "InvalidRepeat",          "UnterminatedRepeat",     "UnknownUnicodeProperty",
            "InvalidClassSetOperand", "MixedClassSetOperators",
        }, .code = .ZREGEXP_ERROR_SYNTAX },
        .{ .names = &.{"OutOfMemory"}, .code = .ZREGEXP_ERROR_OUT_OF_MEMORY },
        .{ .names = &.{ "RecursionLimitExceeded", "BacktrackStackExhausted" }, .code = .ZREGEXP_ERROR_RECURSION_LIMIT },
        .{ .names = &.{"StepLimitExceeded"}, .code = .ZREGEXP_ERROR_STEP_LIMIT },
        .{ .names = &.{"UnmatchedParen"}, .code = .ZREGEXP_ERROR_UNMATCHED_PAREN },
        .{ .names = &.{"InvalidCharRange"}, .code = .ZREGEXP_ERROR_INVALID_RANGE },
        .{ .names = &.{"UnsupportedFeature"}, .code = .ZREGEXP_ERROR_UNSUPPORTED },
    };
    inline for (.{ regex.RegexError, regex.ExecError }) |E| {
        inline for (@typeInfo(E).error_set.?) |e| {
            const want: Code = comptime blk: {
                @setEvalBranchQuota(100_000);
                for (table) |row| for (row.names) |n| {
                    if (std.mem.eql(u8, n, e.name)) break :blk row.code;
                };
                break :blk .ZREGEXP_ERROR_UNKNOWN;
            };
            try std.testing.expectEqual(want, zigErrorToC(@as(anyerror, @field(anyerror, e.name))));
        }
    }
}

test "a SyntaxError of the pattern is ZREGEXP_ERROR_SYNTAX, a limit stays UNKNOWN (F7c-4)" {
    const Case = struct { pattern: [:0]const u8, name: []const u8, u: bool = false, v: bool = false };
    // One pattern per error of the frontend that maps to SYNTAX (each one
    // checked against the error the engine gives; UnexpectedEOF has no
    // producer).
    const syntax = [_]Case{
        .{ .pattern = "a{2,1}", .name = "InvalidQuantifier" },
        .{ .pattern = "a)", .name = "UnexpectedToken" },
        .{ .pattern = "a]", .name = "UnmatchedBracket", .u = true },
        .{ .pattern = "(?<n>a)(?<n>b)", .name = "DuplicateGroupName" },
        .{ .pattern = "\\k<x>(?<n>a)", .name = "UnknownGroupName" },
        .{ .pattern = "(?<1>a)", .name = "InvalidGroupName" },
        .{ .pattern = "a{,5}", .name = "InvalidRepeat", .u = true },
        .{ .pattern = "a{2,3", .name = "UnterminatedRepeat", .u = true },
        .{ .pattern = "\\p{Foo}", .name = "UnknownUnicodeProperty", .u = true },
        .{ .pattern = "[a&&]", .name = "InvalidClassSetOperand", .v = true },
        // F7c-4b: a list or a range as an operand.
        .{ .pattern = "[ab&&[c]]", .name = "InvalidClassSetOperand", .v = true },
        .{ .pattern = "[a-z--\\p{Lu}]", .name = "InvalidClassSetOperand", .v = true },
        .{ .pattern = "[[a]&&[b]--[c]]", .name = "MixedClassSetOperators", .v = true },
        // F7c-4b: with flat operands too.
        .{ .pattern = "[a--b&&c]", .name = "MixedClassSetOperators", .v = true },
        .{ .pattern = "[a&&b--c]", .name = "MixedClassSetOperators", .v = true },
        .{ .pattern = "[\\w&&\\d--x]", .name = "MixedClassSetOperators", .v = true },
    };
    for (syntax) |c| {
        var opts = zregex_default_options();
        opts.unicode = c.u;
        opts.v = c.v;
        try std.testing.expectEqual(@as(?*ZRegex, null), zregex_compile(c.pattern, &opts));
        try std.testing.expectEqualStrings(c.name, std.mem.span(zregex_last_error_name()));
        try std.testing.expectEqual(ZRegexError.ZREGEXP_ERROR_SYNTAX, zregex_last_error());
    }

    // An implementation limit on valid syntax stays UNKNOWN.
    var deep: [2 * 257 + 1]u8 = undefined;
    @memset(deep[0..257], '(');
    @memset(deep[257 .. 2 * 257], ')');
    deep[2 * 257] = 0;
    try std.testing.expectEqual(@as(?*ZRegex, null), zregex_compile(deep[0 .. 2 * 257 :0], null));
    try std.testing.expectEqualStrings("NestingTooDeep", std.mem.span(zregex_last_error_name()));
    try std.testing.expectEqual(ZRegexError.ZREGEXP_ERROR_UNKNOWN, zregex_last_error());
}

test "zregex_version is the package version" {
    try std.testing.expectEqualStrings(regex.version, std.mem.span(zregex_version()));
}

test "zregex_compile_n / zregex_search_n handle embedded NUL" {
    const pattern = "a\x00b";
    const re = zregex_compile_n(pattern.ptr, pattern.len, null).?;
    defer zregex_free(re);

    const subject = "xxa\x00bxx";
    const m = zregex_search_n(re, subject.ptr, subject.len, 0).?;
    defer zregex_match_free(m);
    try std.testing.expectEqual(@as(usize, 2), zregex_match_start(m));
    try std.testing.expectEqual(@as(usize, 5), zregex_match_end(m));
}

test "zregex_search_n starts scanning at the given offset" {
    const pattern = "a";
    const re = zregex_compile_n(pattern.ptr, pattern.len, null).?;
    defer zregex_free(re);

    const subject = "abca";
    const m = zregex_search_n(re, subject.ptr, subject.len, 1).?;
    defer zregex_match_free(m);
    try std.testing.expectEqual(@as(usize, 3), zregex_match_start(m));
    try std.testing.expect(zregex_search_n(re, subject.ptr, subject.len, 4) == null);
}

test "zregex_match_at_n is anchored at the offset" {
    const pattern = "b";
    const re = zregex_compile_n(pattern.ptr, pattern.len, null).?;
    defer zregex_free(re);

    const subject = "abc";
    try std.testing.expect(zregex_match_at_n(re, subject.ptr, subject.len, 0) == null);
    const m = zregex_match_at_n(re, subject.ptr, subject.len, 1).?;
    defer zregex_match_free(m);
    try std.testing.expectEqual(@as(usize, 2), zregex_match_end(m));
}

test "zregex_group_count counts capturing groups only" {
    const pattern = "(a)(?:b)(?<n>c)";
    const re = zregex_compile_n(pattern.ptr, pattern.len, null).?;
    defer zregex_free(re);
    try std.testing.expectEqual(@as(usize, 2), zregex_group_count(re));
}

test "zregex_last_error_name reports the precise compile error" {
    const pattern = "(a";
    try std.testing.expect(zregex_compile_n(pattern.ptr, pattern.len, null) == null);
    try std.testing.expectEqualStrings("UnexpectedToken", std.mem.span(zregex_last_error_name()));

    const ok = "a";
    const re = zregex_compile_n(ok.ptr, ok.len, null).?;
    zregex_free(re);
    try std.testing.expectEqualStrings("", std.mem.span(zregex_last_error_name()));
}

test "zregex_compile / zregex_compile_n carry u and v to CompileResult.mode (F3c)" {
    const Mode = regex.internal.subject.Mode;
    const Case = struct { unicode: bool, v: bool, mode: Mode };
    const cases = [_]Case{
        .{ .unicode = false, .v = false, .mode = .code_unit },
        .{ .unicode = true, .v = false, .mode = .code_point },
        .{ .unicode = false, .v = true, .mode = .code_point },
    };
    // `u` and `v` together are a SyntaxError (F4a(4) prep).
    var both = zregex_default_options();
    both.unicode = true;
    both.v = true;
    try std.testing.expect(zregex_compile("a", &both) == null);
    try std.testing.expectEqual(ZRegexError.ZREGEXP_ERROR_SYNTAX, zregex_last_error());
    try std.testing.expect(zregex_compile_n("a", 1, &both) == null);
    try std.testing.expectEqualStrings("IncompatibleFlags", std.mem.span(zregex_last_error_name()));
    for (cases) |c| {
        var opts = zregex_default_options();
        opts.unicode = c.unicode;
        opts.v = c.v;
        const re = zregex_compile("a", &opts).?;
        defer zregex_free(re);
        try std.testing.expectEqual(c.mode, re.compiled.mode);
        const re_n = zregex_compile_n("a", 1, &opts).?;
        defer zregex_free(re_n);
        try std.testing.expectEqual(c.mode, re_n.compiled.mode);
    }
    const plain = zregex_compile("a", null).?;
    defer zregex_free(plain);
    try std.testing.expectEqual(Mode.code_unit, plain.compiled.mode);
}

/// The code and the name the last failure recorded.
fn expectLastError(code: ZRegexError, name: []const u8) !void {
    try std.testing.expectEqual(code, zregex_last_error());
    try std.testing.expectEqualStrings(name, std.mem.span(zregex_last_error_name()));
}

/// A regex whose every execution over `step_input` passes its step budget.
fn stepLimited() *ZRegex {
    var opts = zregex_default_options();
    opts.max_steps = 100;
    return zregex_compile("(a+)+\\1b", &opts).?;
}
const step_input = "aaaaaaaaaaaac";

test "error name: zregex_compile records a compile error's name" {
    try std.testing.expect(zregex_compile("(a", null) == null);
    try expectLastError(zigErrorToC(@as(anyerror, error.UnexpectedToken)), "UnexpectedToken");
    var opts = zregex_default_options();
    opts.unicode = true;
    try std.testing.expect(zregex_compile("\\q", &opts) == null);
    try expectLastError(.ZREGEXP_ERROR_SYNTAX, "InvalidEscape");
    const ok = zregex_compile("a", null).?;
    zregex_free(ok);
    try expectLastError(.ZREGEXP_OK, "");
}

test "error name: zregex_find, zregex_find_at, zregex_is_match record StepLimitExceeded" {
    const re = stepLimited();
    defer zregex_free(re);
    try std.testing.expect(zregex_find(re, step_input) == null);
    try expectLastError(.ZREGEXP_ERROR_STEP_LIMIT, "StepLimitExceeded");
    try std.testing.expect(zregex_find_at(re, step_input, 0) == null);
    try expectLastError(.ZREGEXP_ERROR_STEP_LIMIT, "StepLimitExceeded");
    try std.testing.expect(!zregex_is_match(re, step_input));
    try expectLastError(.ZREGEXP_ERROR_STEP_LIMIT, "StepLimitExceeded");
}

test "error name: zregex_find_all records StepLimitExceeded" {
    const re = stepLimited();
    defer zregex_free(re);
    try std.testing.expect(zregex_find_all(re, step_input) == null);
    try expectLastError(.ZREGEXP_ERROR_STEP_LIMIT, "StepLimitExceeded");
}

test "error name: zregex_replace and zregex_replace_all record StepLimitExceeded" {
    const re = stepLimited();
    defer zregex_free(re);
    try std.testing.expect(zregex_replace(re, step_input, "x") == null);
    try expectLastError(.ZREGEXP_ERROR_STEP_LIMIT, "StepLimitExceeded");
    try std.testing.expect(zregex_replace_all(re, step_input, "x") == null);
    try expectLastError(.ZREGEXP_ERROR_STEP_LIMIT, "StepLimitExceeded");
}

test "error name: zregex_escape records OutOfMemory" {
    test_alloc.fail = true;
    const r = zregex_escape("a.b");
    test_alloc.fail = false;
    try std.testing.expect(r == null);
    try expectLastError(.ZREGEXP_ERROR_OUT_OF_MEMORY, "OutOfMemory");
    const ok = zregex_escape("a.b").?;
    defer zregex_string_free(ok);
    try expectLastError(.ZREGEXP_OK, "");
}

test "error name: zregex_match_slice records OutOfMemory" {
    const re = zregex_compile("b+", null).?;
    defer zregex_free(re);
    const m = zregex_find(re, "abbc").?;
    defer zregex_match_free(m);
    test_alloc.fail = true;
    const r = zregex_match_slice(m);
    test_alloc.fail = false;
    try std.testing.expectEqualStrings("", std.mem.span(r)); // static, not freed
    try expectLastError(.ZREGEXP_ERROR_OUT_OF_MEMORY, "OutOfMemory");
}

test "error name: zregex_match_group records InvalidGroup and OutOfMemory" {
    const re = zregex_compile("(b)+", null).?;
    defer zregex_free(re);
    const m = zregex_find(re, "abbc").?;
    defer zregex_match_free(m);
    try std.testing.expect(zregex_match_group(m, 5) == null);
    try expectLastError(.ZREGEXP_ERROR_INVALID_GROUP, "InvalidGroup");
    test_alloc.fail = true;
    const r = zregex_match_group(m, 1);
    test_alloc.fail = false;
    try std.testing.expect(r == null);
    try expectLastError(.ZREGEXP_ERROR_OUT_OF_MEMORY, "OutOfMemory");
    const g = zregex_match_group(m, 1).?;
    zregex_string_free(g);
    try expectLastError(.ZREGEXP_OK, "");
}

test "error name: zregex_named_group_name records InvalidGroup and OutOfMemory" {
    const re = zregex_compile("(?<x>a)", null).?;
    defer zregex_free(re);
    try std.testing.expect(zregex_named_group_name(re, 1) == null);
    try expectLastError(.ZREGEXP_ERROR_INVALID_GROUP, "InvalidGroup");
    test_alloc.fail = true;
    const r = zregex_named_group_name(re, 0);
    test_alloc.fail = false;
    try std.testing.expect(r == null);
    try expectLastError(.ZREGEXP_ERROR_OUT_OF_MEMORY, "OutOfMemory");
}

test "error name: zregex_named_group_index records InvalidGroup" {
    const re = zregex_compile("(?<x>a)", null).?;
    defer zregex_free(re);
    try std.testing.expectEqual(@as(usize, 0), zregex_named_group_index(re, 3));
    try expectLastError(.ZREGEXP_ERROR_INVALID_GROUP, "InvalidGroup");
    try std.testing.expectEqual(@as(usize, 1), zregex_named_group_index(re, 0));
    try expectLastError(.ZREGEXP_OK, "");
}

test "a property of strings without data and RegExp modifiers are ZREGEXP_ERROR_UNSUPPORTED (E0)" {
    var opts = std.mem.zeroes(ZRegexOptions);
    opts.v = true;
    try std.testing.expect(zregex_compile("\\p{RGI_Emoji}", &opts) == null);
    try expectLastError(.ZREGEXP_ERROR_UNSUPPORTED, "UnsupportedFeature");
    try std.testing.expect(zregex_compile("(?i:a)", null) == null);
    try expectLastError(.ZREGEXP_ERROR_UNSUPPORTED, "UnsupportedFeature");
}

test "a lookaround inside a backward lookbehind is ZREGEXP_ERROR_UNSUPPORTED (F6b(3))" {
    try std.testing.expect(zregex_compile("(?<=(?=a)b+)c", null) == null);
    try expectLastError(.ZREGEXP_ERROR_UNSUPPORTED, "UnsupportedFeature");
    try std.testing.expect(zregex_compile_n("(?<=a+(?!b))c", 13, null) == null);
    try std.testing.expectEqual(ZRegexError.ZREGEXP_ERROR_UNSUPPORTED, zregex_last_error());
    try std.testing.expectEqualStrings("UnsupportedFeature", std.mem.span(zregex_last_error_name()));
    // Fixed length, no captures: runs.
    const re = zregex_compile("(?<=a)b", null).?;
    defer zregex_free(re);
    var slots: [2]usize = undefined;
    const s = "ab";
    try std.testing.expectEqual(@as(c_int, 1), zregex_exec_wtf8(re, s.ptr, s.len, 0, false, &slots, slots.len));
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, &slots);
}

test "ZRegexOptions.max_steps reaches every execution (F7b)" {
    // A backref keeps the pattern on the backtracker; the VM has no step
    // budget. 12 `a` and no `b`: exponential, but far under the default.
    const pattern = "(a+)+\\1b";
    const input = "aaaaaaaaaaaac";
    var small = zregex_default_options();
    small.max_steps = 100;
    var zero = zregex_default_options();
    zero.max_steps = 0;
    var slots: [4]usize = undefined;
    const limited = [_]*ZRegex{ zregex_compile(pattern, &small).?, zregex_compile_n(pattern, pattern.len, &small).? };
    defer for (limited) |re| zregex_free(re);
    for (limited) |re| {
        try std.testing.expectEqual(@as(usize, 100), re.limits.max_steps);
        try std.testing.expect(zregex_find(re, input) == null);
        try std.testing.expectEqual(ZRegexError.ZREGEXP_ERROR_STEP_LIMIT, zregex_last_error());
        try std.testing.expect(!zregex_is_match(re, input));
        try std.testing.expectEqual(ZRegexError.ZREGEXP_ERROR_STEP_LIMIT, zregex_last_error());
        try std.testing.expectEqual(@as(c_int, -1), zregex_exec_wtf8(re, input.ptr, input.len, 0, false, &slots, slots.len));
        try std.testing.expectEqualStrings("StepLimitExceeded", std.mem.span(zregex_last_error_name()));
    }
    // The defaults (and 0, which keeps them) answer: no match, no error.
    const plain = [_]*ZRegex{ zregex_compile(pattern, null).?, zregex_compile(pattern, &zero).? };
    defer for (plain) |re| zregex_free(re);
    for (plain) |re| {
        try std.testing.expectEqual(backtrack_default_steps, re.limits.max_steps);
        try std.testing.expect(zregex_find(re, input) == null);
        try std.testing.expectEqual(ZRegexError.ZREGEXP_OK, zregex_last_error());
        try std.testing.expectEqual(@as(c_int, 0), zregex_exec_wtf8(re, input.ptr, input.len, 0, false, &slots, slots.len));
    }
}

const backtrack_default_steps = (regex.ExecLimits{}).max_steps;

test "zregex_exec_wtf8 / zregex_exec_utf16 agree and report errors (F3c)" {
    const re = zregex_compile("(b)|x", null).?;
    defer zregex_free(re);
    var slots: [4]usize = undefined;
    const w = "a\u{1F600}b";
    try std.testing.expectEqual(@as(c_int, 1), zregex_exec_wtf8(re, w.ptr, w.len, 0, false, &slots, slots.len));
    try std.testing.expectEqualSlices(usize, &.{ 5, 6, 5, 6 }, &slots);
    const u = [_]u16{ 'a', 0xD83D, 0xDE00, 'b' };
    try std.testing.expectEqual(@as(c_int, 1), zregex_exec_utf16(re, &u, u.len, 0, false, &slots, slots.len));
    try std.testing.expectEqualSlices(usize, &.{ 3, 4, 3, 4 }, &slots);
    try std.testing.expectEqual(@as(c_int, 0), zregex_exec_utf16(re, &u, u.len, 0, true, &slots, slots.len));
    try std.testing.expectEqual(@as(c_int, -1), zregex_exec_wtf8(re, w.ptr, w.len, 2, false, &slots, slots.len));
    try std.testing.expectEqualStrings("InvalidIndex", std.mem.span(zregex_last_error_name()));
    try std.testing.expectEqual(@as(c_int, -1), zregex_exec_wtf8(re, w.ptr, w.len, 0, false, &slots, 3));
    try std.testing.expectEqualStrings("SlotsTooSmall", std.mem.span(zregex_last_error_name()));
    // Without `u` one code unit (b+2 in WTF-8, F3d); with `u` one code point.
    try std.testing.expectEqual(@as(usize, 3), zregex_advance_index_wtf8(re, w.ptr, w.len, 1));
    try std.testing.expectEqual(@as(usize, 2), zregex_advance_index_utf16(re, &u, u.len, 1));
    var uopts = zregex_default_options();
    uopts.unicode = true;
    const re_u = zregex_compile("(b)|x", &uopts).?;
    defer zregex_free(re_u);
    try std.testing.expectEqual(@as(usize, 5), zregex_advance_index_wtf8(re_u, w.ptr, w.len, 1));
    try std.testing.expectEqual(@as(usize, 3), zregex_advance_index_utf16(re_u, &u, u.len, 1));
    try std.testing.expectEqual(@as(c_int, 0), zregex_exec_utf16(re, &u, u.len, 5, false, &slots, slots.len));
    // No group taking part is NO_CAPTURE.
    const x = "x";
    try std.testing.expectEqual(@as(c_int, 1), zregex_exec_wtf8(re, x.ptr, x.len, 0, false, &slots, slots.len));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, NO_CAPTURE, NO_CAPTURE }, &slots);
}

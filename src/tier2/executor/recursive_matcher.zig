//! Recursive regex matcher with backtracking
//!
//! This module implements a recursive matching engine inspired by mvzr,
//! replacing the Pike VM approach to solve the SPLIT infinite loop bug.
//!
//! Key advantages:
//! - No visited set needed (recursion naturally bounds loops)
//! - Simple backtracking logic
//! - Greedy quantifiers work correctly
//! - Easy to debug (language stack traces)

const std = @import("std");
const Allocator = std.mem.Allocator;
const opcodes = @import("../bytecode/opcodes.zig");
const format = @import("../bytecode/format.zig");
const properties = @import("unicode").properties;
const CharSet = @import("ir").charset.CharSet;

const Opcode = opcodes.Opcode;
const Instruction = format.Instruction;

/// Capture slots kept inline in the matcher (no allocation); patterns with
/// more groups use a heap buffer sized to the pattern (D9: no fixed cap).
const INLINE_CAPTURES = 16;

/// Default maximum recursion depth (protects against stack overflow)
pub const DEFAULT_MAX_RECURSION_DEPTH: usize = 1000;

/// Default maximum execution steps (protects against ReDoS)
pub const DEFAULT_MAX_STEPS: usize = 1_000_000;

/// Execution options for ReDoS protection
pub const ExecOptions = struct {
    /// Maximum recursion depth (0 = unlimited, not recommended)
    max_recursion_depth: usize = DEFAULT_MAX_RECURSION_DEPTH,

    /// Maximum execution steps (0 = unlimited, not recommended)
    max_steps: usize = DEFAULT_MAX_STEPS,

    /// Create options with unlimited limits (dangerous!)
    pub fn unlimited() ExecOptions {
        return .{
            .max_recursion_depth = 0,
            .max_steps = 0,
        };
    }

    /// Create options with custom limits
    pub fn withLimits(max_recursion: usize, max_steps: usize) ExecOptions {
        return .{
            .max_recursion_depth = max_recursion,
            .max_steps = max_steps,
        };
    }
};

/// Match result. Captures are not part of it (F1c): they live in the matcher
/// (`RecursiveMatcher.captureSlice`), which holds the successful path's
/// values when the top-level `matchFrom` returns `matched`. Keeping this
/// small matters: every recursion level returns one by value.
pub const MatchResult = struct {
    matched: bool,
    end_pos: usize,
};

/// Capture group boundaries
pub const CaptureGroup = struct {
    start: ?usize = null,
    end: ?usize = null,

    pub fn isValid(self: CaptureGroup) bool {
        return self.start != null and self.end != null;
    }
};

/// A loop back-edge we are currently re-entering, identified by the loop
/// head's PC and the input position at which it was (re)entered. Used to
/// detect zero-progress iterations of a nullable quantifier (see
/// `matchBackEdge`).
const LoopState = struct {
    pc: usize,
    pos: usize,
};

/// Recursive matcher
pub const RecursiveMatcher = struct {
    allocator: Allocator,
    bytecode: []const u8,
    /// The program's CharSet table (`CompileResult.charsets`), which
    /// CHAR_SET/CHAR_SET_INV index into. Empty for bytecode built without
    /// one; a CHAR_SET then fails with `error.InvalidCharSet`.
    charsets: []const CharSet = &.{},
    input: []const u8,
    /// Capture slots in use: the pattern's group count + 1 (slot 0 unused).
    capture_slots: usize,
    inline_captures: [INLINE_CAPTURES]CaptureGroup,
    /// Used instead of `inline_captures` when `capture_slots` exceeds it;
    /// allocated on the first `matchFrom`.
    heap_captures: []CaptureGroup,
    /// Capture snapshots for lookarounds (LIFO; see `matchLookahead`), on the
    /// heap rather than in each recursion frame.
    snapshots: std.ArrayListUnmanaged(CaptureGroup),
    recursion_depth: usize,
    step_count: usize,
    exec_options: ExecOptions,
    /// Stack of loop heads currently being re-entered via a backward jump,
    /// in recursion order. Guards against infinite recursion on quantifiers
    /// whose body can match the empty string (e.g. `(a?b??)*`). Path-local:
    /// entries are pushed before recursing into a back-edge and popped on
    /// the way out, so only loops on the *active* recursion chain are seen.
    loop_guard: std.ArrayListUnmanaged(LoopState),

    const Self = @This();

    /// Error set for matching operations
    pub const MatchError = error{ OutOfMemory, UnknownOpcode, UnexpectedEndOfBytecode, RecursionLimitExceeded, StepLimitExceeded, InvalidCharSet };

    pub fn init(allocator: Allocator, bytecode: []const u8, input: []const u8) Self {
        return Self.initWithOptions(allocator, bytecode, input, ExecOptions{});
    }

    /// Sizes the captures by scanning `bytecode`; `initWithSlots` takes the
    /// count directly (the hot path: `Matcher` computes it once per pattern).
    pub fn initWithOptions(allocator: Allocator, bytecode: []const u8, input: []const u8, options: ExecOptions) Self {
        return Self.initWithSlots(allocator, bytecode, input, options, captureSlotsIn(bytecode));
    }

    pub fn initWithSlots(allocator: Allocator, bytecode: []const u8, input: []const u8, options: ExecOptions, capture_slots: usize) Self {
        return .{
            .allocator = allocator,
            .bytecode = bytecode,
            .input = input,
            .capture_slots = capture_slots,
            .inline_captures = [_]CaptureGroup{.{}} ** INLINE_CAPTURES,
            .heap_captures = &.{},
            .snapshots = .empty,
            .recursion_depth = 0,
            .step_count = 0,
            .exec_options = options,
            .loop_guard = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.loop_guard.deinit(self.allocator);
        self.snapshots.deinit(self.allocator);
        self.allocator.free(self.heap_captures);
    }

    /// Capture slots a bytecode program needs: its highest group index + 1
    /// (slot 0 is never written; group 0 is the match itself).
    pub fn captureSlotsIn(bytecode: []const u8) usize {
        var slots: usize = 1;
        var pc: usize = 0;
        while (pc < bytecode.len) {
            const inst = format.decodeInstruction(bytecode, pc) catch break;
            switch (inst.opcode) {
                .SAVE_START, .SAVE_END, .SAVE_START_NAMED, .SAVE_END_NAMED, .CLEAR_CAPTURE, .BACK_REF, .BACK_REF_I => {
                    slots = @max(slots, @as(usize, inst.operands[0]) + 1);
                },
                else => {},
            }
            pc += inst.size;
        }
        return slots;
    }

    /// The live capture slots (inline or heap, see `capture_slots`).
    fn caps(self: *Self) []CaptureGroup {
        if (self.capture_slots <= INLINE_CAPTURES) return self.inline_captures[0..self.capture_slots];
        return self.heap_captures;
    }

    /// The captures of the last successful top-level `matchFrom`.
    pub fn captureSlice(self: *Self) []const CaptureGroup {
        return self.caps();
    }

    /// Follow a backward control-flow edge (a loop back-edge) into a loop
    /// head, enforcing ECMA-262's rule that a `*`/`+`/`{n,}` iteration which
    /// matches the empty string is discarded rather than repeated. Without
    /// this, a nullable body (one that can match at the same position it
    /// started, e.g. `(a?b??)`) recurses forever and overflows the stack.
    ///
    /// If we are already re-entering this exact loop head (`target_pc`) at
    /// this exact input position, the previous iteration consumed nothing,
    /// so this iteration is refused (returns no match) and the caller's
    /// SPLIT falls through to the loop's exit branch.
    ///
    /// KNOWN LIMITATION (capture value only, not the match): ECMA-262 also
    /// says the discarded empty iteration's *capture writes* are thrown away,
    /// so a group that participated only in a trailing/sole empty iteration
    /// should read as its last non-empty value (or undefined). We refuse the
    /// iteration but don't roll those writes back, so e.g. `/(a?)+/.exec("aaa")`
    /// yields group1="" where V8 gives "a", and `/x(a?)*y/.exec("xy")` yields
    /// "" where V8 gives undefined. The overall match (`[0]`) is always
    /// correct; only these exotic capture values diverge. A faithful fix means
    /// restructuring the loop into a spec RepeatMatcher (snapshotting captures
    /// per iteration) -- tracked as a separate conformance item.
    fn matchBackEdge(self: *Self, target_pc: usize, pos: usize) MatchError!MatchResult {
        for (self.loop_guard.items) |g| {
            if (g.pc == target_pc and g.pos == pos) {
                return MatchResult{ .matched = false, .end_pos = pos };
            }
        }
        try self.loop_guard.append(self.allocator, .{ .pc = target_pc, .pos = pos });
        defer _ = self.loop_guard.pop();
        return self.matchFrom(target_pc, pos);
    }

    /// Match from specific PC and string position
    pub fn matchFrom(self: *Self, pc: usize, pos: usize) MatchError!MatchResult {
        // Check step limit (protects against ReDoS)
        if (self.exec_options.max_steps > 0) {
            self.step_count += 1;
            if (self.step_count >= self.exec_options.max_steps) {
                return error.StepLimitExceeded;
            }
        }

        // Check recursion depth limit (protects against stack overflow)
        if (self.exec_options.max_recursion_depth > 0) {
            if (self.recursion_depth >= self.exec_options.max_recursion_depth) {
                return error.RecursionLimitExceeded;
            }
        }

        if (self.capture_slots > INLINE_CAPTURES and self.heap_captures.len == 0) {
            self.heap_captures = try self.allocator.alloc(CaptureGroup, self.capture_slots);
            @memset(self.heap_captures, .{});
        }

        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        // Check bounds
        if (pc >= self.bytecode.len) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }

        const inst = try format.decodeInstruction(self.bytecode, pc);

        switch (inst.opcode) {
            .MATCH => {
                // Success!
                // The captures stay in `self` (see `captureSlice`).
                return MatchResult{ .matched = true, .end_pos = pos };
            },

            .CHAR32 => {
                // Match specific character
                const expected = @as(u8, @intCast(inst.operands[0]));
                return self.matchChar(pc, pos, expected, inst.size);
            },

            .CHAR => {
                // Match any Unicode scalar value except newline (dot without /s)
                return self.matchAnyChar(pc, pos, true, inst.size);
            },

            .CHAR_ANY => {
                // Match any Unicode scalar value, including newline (dot with /s)
                return self.matchAnyChar(pc, pos, false, inst.size);
            },

            .CHAR_RANGE => {
                // Match character in range [min, max]
                const min = @as(u8, @intCast(inst.operands[0]));
                const max = @as(u8, @intCast(inst.operands[1]));
                return self.matchCharRange(pc, pos, min, max, inst.size);
            },

            .CHAR_RANGE_INV => {
                // Match character NOT in range [^min-max]
                const min = @as(u8, @intCast(inst.operands[0]));
                const max = @as(u8, @intCast(inst.operands[1]));
                return self.matchCharRangeInv(pc, pos, min, max, inst.size);
            },

            .CHAR_CLASS => {
                // Match character in class (using bit table)
                // Table is stored inline: 32 bytes starting at pc + 1
                if (pc + 33 > self.bytecode.len) return error.UnexpectedEndOfBytecode;
                const table = self.bytecode[pc + 1 ..][0..32];
                return self.matchCharClass(pc, pos, table, inst.size);
            },

            .CHAR_CLASS_INV => {
                // Match character NOT in class (using bit table)
                // Table is stored inline: 32 bytes starting at pc + 1
                if (pc + 33 > self.bytecode.len) return error.UnexpectedEndOfBytecode;
                const table = self.bytecode[pc + 1 ..][0..32];
                return self.matchCharClassInv(pc, pos, table, inst.size);
            },

            .CHAR_SET, .CHAR_SET_INV => {
                const r = try self.checkCharSet(inst, pos);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .UNICODE_PROPERTY => {
                const r = try self.checkUnicodeProperty(pc, pos, false);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .UNICODE_PROPERTY_INV => {
                const r = try self.checkUnicodeProperty(pc, pos, true);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .UNICODE_SCRIPT => {
                const r = try self.checkUnicodeScript(pc, pos, false);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .UNICODE_SCRIPT_INV => {
                const r = try self.checkUnicodeScript(pc, pos, true);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .UNICODE_SCRIPT_EXTENSIONS => {
                const r = try self.checkUnicodeScriptExtensions(pc, pos, false);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .UNICODE_SCRIPT_EXTENSIONS_INV => {
                const r = try self.checkUnicodeScriptExtensions(pc, pos, true);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .GOTO => {
                // Unconditional jump. A backward jump closes a `*`/`{n,}`
                // loop (`generateStar`/`generateRepeat` emit `GOTO loop`);
                // route it through the zero-progress guard so a nullable
                // body can't recurse forever.
                const offset = @as(i32, @bitCast(inst.operands[0]));
                const new_pc: usize = @intCast(@as(i32, @intCast(pc)) + offset);
                if (new_pc < pc) return self.matchBackEdge(new_pc, pos);
                return self.matchFrom(new_pc, pos);
            },

            .SPLIT, .SPLIT_GREEDY, .SPLIT_LAZY, .SPLIT_POSSESSIVE => {
                // Fork execution (used for quantifiers and alternation)
                const offset1 = @as(i32, @bitCast(inst.operands[0]));
                const offset2 = @as(i32, @bitCast(inst.operands[1]));

                // Special handling: offset=0 means "fall through to next instruction"
                const pc1: usize = if (offset1 == 0)
                    pc + inst.size
                else
                    @intCast(@as(i32, @intCast(pc)) + offset1);

                const pc2: usize = if (offset2 == 0)
                    pc + inst.size
                else
                    @intCast(@as(i32, @intCast(pc)) + offset2);

                // Check if possessive (no backtracking)
                const is_possessive = (inst.opcode == .SPLIT_POSSESSIVE);

                // Detect pattern type by analyzing what follows
                const is_star = try self.isStarQuantifier(pc, pc1, pc2);

                if (is_star) {
                    // Determine which path is consume and which is skip
                    const pc1_is_consume = try self.isStarConsumePath(pc, pc1);
                    const pc_consume = if (pc1_is_consume) pc1 else pc2;
                    const pc_skip = if (pc1_is_consume) pc2 else pc1;

                    if (is_possessive) {
                        // Possessive: consume all without backtracking
                        return self.matchStarPossessive(pc_consume, pc_skip, pos);
                    } else {
                        // Determine greediness: greedy by default, lazy only if explicitly SPLIT_LAZY
                        const greedy = (inst.opcode != .SPLIT_LAZY);
                        // This is a star quantifier: try both paths with backtracking
                        return self.matchStar(pc_consume, pc_skip, pos, greedy);
                    }
                } else {
                    // Alternation (`a|b`) and `e?`/`e??` all reduce to the
                    // same priority-order backtracking here: try pc1, and
                    // only fall back to pc2 if pc1's entire continuation
                    // fails. This is correct for `|` (explicit priority
                    // order) and for `?`/`??` as long as codegen puts the
                    // preferred branch first -- `generateQuestion` emits
                    // SPLIT_GREEDY(consume, skip) and `generateLazyQuestion`
                    // emits SPLIT_LAZY(skip, consume), so "try pc1 first" is
                    // already greedy-correct or lazy-correct respectively,
                    // regardless of how complex the quantified atom is (a
                    // previous "try both and compare end_pos" approach here
                    // only worked for atoms simple enough for
                    // `isQuestionQuantifier` to recognize, silently fell
                    // back to being backwards for anything else, e.g. a
                    // capturing group, and separately corrupted the shared
                    // `self.captures` array by always evaluating the
                    // discarded branch too).
                    //
                    // Note this also covers `?+`/`*+`-shaped SPLIT_POSSESSIVE
                    // that reach here (not recognized as a star loop): the
                    // atom either matches (commit to pc1) or it didn't apply
                    // at all, in which case falling through to pc2 is still
                    // correct (there's nothing to "give back").
                    // A branch that jumps backward closes a `+`/`{n,}` loop
                    // whose body is too complex to be recognized as a simple
                    // star above (`generatePlus` emits `e; SPLIT loop, end`
                    // for e.g. a capturing group). Route backward branches
                    // through the zero-progress guard so a nullable body
                    // (`(a?)+`) can't recurse forever.
                    const result1 = if (pc1 < pc)
                        try self.matchBackEdge(pc1, pos)
                    else
                        try self.matchFrom(pc1, pos);
                    if (result1.matched) {
                        return result1;
                    }
                    if (pc2 < pc) return self.matchBackEdge(pc2, pos);
                    return self.matchFrom(pc2, pos);
                }
            },

            .SAVE_START => {
                // Save capture group start. If the continuation ultimately
                // fails (e.g. a quantified group backtracks off one more,
                // failed, attempted repetition), this mutation must not
                // leak: restore the pre-attempt value so the capture still
                // reflects the last *successful* repetition, not a
                // half-completed failed one. `self.captures` is shared,
                // mutable matcher state with no other snapshot/rollback
                // mechanism, so this has to happen at the point of mutation.
                const group = @as(usize, @intCast(inst.operands[0]));
                if (group < self.capture_slots) {
                    const prev = self.caps()[group];
                    self.caps()[group].start = pos;
                    const result = try self.matchFrom(pc + inst.size, pos);
                    if (!result.matched) self.caps()[group] = prev;
                    return result;
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            .SAVE_END => {
                // Save capture group end (see SAVE_START for why this must
                // roll back on failure too).
                const group = @as(usize, @intCast(inst.operands[0]));
                if (group < self.capture_slots) {
                    const prev = self.caps()[group];
                    self.caps()[group].end = pos;
                    const result = try self.matchFrom(pc + inst.size, pos);
                    if (!result.matched) self.caps()[group] = prev;
                    return result;
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            .CLEAR_CAPTURE => {
                // Reset a capture group to unset on the "skip" path of an
                // optional atom (see opcodes.zig for why), rolling back to
                // whatever it was before if the continuation fails --
                // consistent with SAVE_START/SAVE_END, so backtracking back
                // out of this skip choice restores the prior state.
                const group = @as(usize, @intCast(inst.operands[0]));
                if (group < self.capture_slots) {
                    const prev = self.caps()[group];
                    self.caps()[group] = .{};
                    const result = try self.matchFrom(pc + inst.size, pos);
                    if (!result.matched) self.caps()[group] = prev;
                    return result;
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            .BACK_REF => {
                // Match backreference to capture group (case-sensitive)
                const group = @as(usize, @intCast(inst.operands[0]));
                return self.matchBackRef(pc, pos, group, false, inst.size);
            },

            .BACK_REF_I => {
                // Match backreference to capture group (case-insensitive)
                const group = @as(usize, @intCast(inst.operands[0]));
                return self.matchBackRef(pc, pos, group, true, inst.size);
            },

            .LOOKAHEAD => {
                // Positive lookahead - assert pattern matches without consuming
                return self.matchLookahead(pc, pos, false, inst.size);
            },

            .NEGATIVE_LOOKAHEAD => {
                // Negative lookahead - assert pattern does NOT match
                return self.matchLookahead(pc, pos, true, inst.size);
            },

            .LOOKAHEAD_END => {
                // End of lookahead body - this is like MATCH but for lookahead patterns
                // We consider the lookahead pattern as successfully matched
                return MatchResult{ .matched = true, .end_pos = pos };
            },

            .LOOKBEHIND => {
                // Positive lookbehind - assert pattern matches behind current position
                return self.matchLookbehind(pc, pos, false, inst.size);
            },

            .NEGATIVE_LOOKBEHIND => {
                // Negative lookbehind - assert pattern does NOT match behind
                return self.matchLookbehind(pc, pos, true, inst.size);
            },

            .LOOKBEHIND_END => {
                // End of lookbehind body - this is like MATCH but for lookbehind patterns
                return MatchResult{ .matched = true, .end_pos = pos };
            },

            .STRING_START => {
                // Assert absolute start of input (used for ^ without multiline)
                if (pos != 0) {
                    return MatchResult{ .matched = false, .end_pos = pos };
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            .STRING_END => {
                // Assert absolute end of input (used for $ without multiline)
                if (pos != self.input.len) {
                    return MatchResult{ .matched = false, .end_pos = pos };
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            .LINE_START => {
                // Assert start of line (used for ^ with multiline): absolute
                // start of input, or right after a LineTerminator (D5)
                const at_line_start = pos == 0 or lineTerminatorEndsAt(self.input, pos);
                if (!at_line_start) {
                    return MatchResult{ .matched = false, .end_pos = pos };
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            .LINE_END => {
                // Assert end of line (used for $ with multiline): absolute
                // end of input, or right before a LineTerminator (D5)
                const at_line_end = pos == self.input.len or isLineTerminatorAt(self.input, pos);
                if (!at_line_end) {
                    return MatchResult{ .matched = false, .end_pos = pos };
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            .WORD_BOUNDARY => {
                // Assert word boundary
                if (!self.isWordBoundary(pos)) {
                    return MatchResult{ .matched = false, .end_pos = pos };
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            .NOT_WORD_BOUNDARY => {
                // Assert NOT word boundary
                if (self.isWordBoundary(pos)) {
                    return MatchResult{ .matched = false, .end_pos = pos };
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            else => {
                // Unsupported opcode
                return MatchResult{ .matched = false, .end_pos = pos };
            },
        }
    }

    /// Match specific character
    fn matchChar(self: *Self, pc: usize, pos: usize, expected: u8, inst_size: usize) MatchError!MatchResult {
        if (pos >= self.input.len) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        if (self.input[pos] != expected) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        // Continue with next instruction
        return self.matchFrom(pc + inst_size, pos + 1);
    }

    /// Decodes a WTF-8-encoded lone UTF-16 surrogate (U+D800-U+DFFF) --
    /// the 3-byte sequence z-string/z-lexer/z-interpreter/z-json use to
    /// represent an unpaired surrogate that plain UTF-8 can't express
    /// (std.unicode.utf8Decode rejects that codepoint range even though
    /// the bit layout is otherwise ordinary 3-byte UTF-8). Duplicated
    /// locally per this ecosystem's small-standalone-library convention
    /// (z-regex has no zstring dependency) -- see z-string-surrogate-charat.md.
    fn decodeSurrogateWtf8(bytes: []const u8) ?u21 {
        if (bytes.len != 3) return null;
        if (bytes[0] & 0xF0 != 0xE0) return null;
        if (bytes[1] & 0xC0 != 0x80 or bytes[2] & 0xC0 != 0x80) return null;
        const value: u21 = (@as(u21, bytes[0] & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F);
        if (value < 0xD800 or value > 0xDFFF) return null;
        return value;
    }

    /// Length in bytes of the UTF-8 sequence starting at `input[pos]` (1-4),
    /// or 1 if it isn't the start of a valid sequence, or the sequence would
    /// run past the end of input, or the bytes there don't decode validly.
    /// This keeps matching binary-safe: malformed/non-UTF-8 input degrades to
    /// byte-at-a-time matching instead of erroring. A WTF-8 lone surrogate
    /// (see decodeSurrogateWtf8) counts as a valid 3-byte sequence too, so a
    /// string built from e.g. String.fromCharCode(0xDC00) is matched as one
    /// character, not three raw bytes.
    /// Where the next search start after `pos` is: one whole UTF-8/WTF-8
    /// sequence later (one byte for malformed input), so a search never
    /// starts in the middle of a character (D12, start positions).
    pub fn nextSearchStart(input: []const u8, pos: usize) usize {
        return pos + utf8SeqLenAt(input, pos);
    }

    fn utf8SeqLenAt(input: []const u8, pos: usize) usize {
        if (pos >= input.len) return 1;
        const len = std.unicode.utf8ByteSequenceLength(input[pos]) catch return 1;
        if (pos + len > input.len) return 1;
        _ = std.unicode.utf8Decode(input[pos..][0..len]) catch {
            if (len == 3 and decodeSurrogateWtf8(input[pos..][0..3]) != null) return 3;
            return 1;
        };
        return len;
    }

    /// ECMA-262 LineTerminator: LF, CR, LS (U+2028) or PS (U+2029, both
    /// E2 80 A8/A9 in UTF-8). What `.` without /s excludes and what `^`/`$`
    /// with /m look for (D5).
    fn isLineTerminatorAt(input: []const u8, pos: usize) bool {
        if (pos >= input.len) return false;
        return switch (input[pos]) {
            '\n', '\r' => true,
            0xE2 => pos + 2 < input.len and input[pos + 1] == 0x80 and (input[pos + 2] == 0xA8 or input[pos + 2] == 0xA9),
            else => false,
        };
    }

    /// Whether a LineTerminator ends right before `pos`.
    fn lineTerminatorEndsAt(input: []const u8, pos: usize) bool {
        if (pos == 0) return false;
        if (input[pos - 1] == '\n' or input[pos - 1] == '\r') return true;
        return pos >= 3 and isLineTerminatorAt(input, pos - 3);
    }

    /// Match any Unicode scalar value (dot). `exclude_newline` is true for
    /// plain `.` (no /s flag), false for dot_all. Consumes the full UTF-8
    /// sequence at `pos`, not just one byte.
    fn matchAnyChar(self: *Self, pc: usize, pos: usize, exclude_newline: bool, inst_size: usize) MatchError!MatchResult {
        if (pos >= self.input.len) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        if (exclude_newline and isLineTerminatorAt(self.input, pos)) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        const seq_len = utf8SeqLenAt(self.input, pos);
        return self.matchFrom(pc + inst_size, pos + seq_len);
    }

    /// Match character in range
    fn matchCharRange(self: *Self, pc: usize, pos: usize, min: u8, max: u8, inst_size: usize) MatchError!MatchResult {
        if (pos >= self.input.len) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        const c = self.input[pos];
        if (c < min or c > max) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        return self.matchFrom(pc + inst_size, pos + 1);
    }

    /// Match character NOT in range (inverted). Since the range only covers
    /// byte values 0-255, a match here means "any Unicode scalar value other
    /// than this byte range" — so like `.`, it consumes the full UTF-8
    /// sequence at `pos`, not just one byte.
    fn matchCharRangeInv(self: *Self, pc: usize, pos: usize, min: u8, max: u8, inst_size: usize) MatchError!MatchResult {
        if (pos >= self.input.len) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        const c = self.input[pos];
        // Inverted logic: match if NOT in range
        if (c >= min and c <= max) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        const seq_len = utf8SeqLenAt(self.input, pos);
        return self.matchFrom(pc + inst_size, pos + seq_len);
    }

    /// Match character in class (using bit table)
    fn matchCharClass(self: *Self, pc: usize, pos: usize, table: *const [32]u8, inst_size: usize) MatchError!MatchResult {
        if (pos >= self.input.len) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        const c = self.input[pos];

        // Check if character is in the bit table
        const byte_idx = c / 8;
        const bit_idx = @as(u3, @intCast(c % 8));
        const is_in_class = (table[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;

        if (is_in_class) {
            return self.matchFrom(pc + inst_size, pos + 1);
        } else {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
    }

    /// Match character NOT in class (using bit table). Same UTF-8 sequence
    /// consumption as matchCharRangeInv, and for the same reason.
    fn matchCharClassInv(self: *Self, pc: usize, pos: usize, table: *const [32]u8, inst_size: usize) MatchError!MatchResult {
        if (pos >= self.input.len) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        const c = self.input[pos];

        // Check if character is in the bit table
        const byte_idx = c / 8;
        const bit_idx = @as(u3, @intCast(c % 8));
        const is_in_class = (table[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;

        // Inverted logic: match if NOT in class
        if (!is_in_class) {
            const seq_len = utf8SeqLenAt(self.input, pos);
            return self.matchFrom(pc + inst_size, pos + seq_len);
        } else {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
    }

    /// Decode the Unicode scalar value at `input[pos]` along with how many
    /// bytes it occupies (see utf8SeqLenAt for the binary-safe fallback
    /// policy this relies on).
    fn decodeCodepointAt(input: []const u8, pos: usize) struct { codepoint: u32, len: usize } {
        const len = utf8SeqLenAt(input, pos);
        if (len == 1) {
            return .{ .codepoint = input[pos], .len = 1 };
        }
        if (len == 3) {
            if (decodeSurrogateWtf8(input[pos..][0..3])) |surrogate| {
                return .{ .codepoint = surrogate, .len = 3 };
            }
        }
        // utf8SeqLenAt only returns >1 (and not a recognized WTF-8
        // surrogate) after already validating the decode.
        const cp = std.unicode.utf8Decode(input[pos..][0..len]) catch unreachable;
        return .{ .codepoint = cp, .len = len };
    }

    /// Shared matching logic for CHAR_SET(_INV), used by both the main
    /// recursive matcher and the star-loop fast path
    /// (matchSingleInstruction): decode the code point at `pos` and look it
    /// up in `charsets[idx]`. Decoded code points are always in
    /// [0, 0x10FFFF] (a lone invalid byte decodes as its value), so a set
    /// complemented at compile time agrees with a runtime negation.
    fn checkCharSet(self: *Self, inst: Instruction, pos: usize) MatchError!struct { matched: bool, end_pos: usize } {
        const idx = inst.operands[0];
        if (idx >= self.charsets.len) return error.InvalidCharSet;
        if (pos >= self.input.len) return .{ .matched = false, .end_pos = pos };
        const decoded = decodeCodepointAt(self.input, pos);
        const in_set = self.charsets[idx].contains(decoded.codepoint);
        const matched = if (inst.opcode == .CHAR_SET_INV) !in_set else in_set;
        return .{ .matched = matched, .end_pos = if (matched) pos + decoded.len else pos };
    }

    /// Shared matching logic for UNICODE_PROPERTY(_INV), used by both the
    /// main recursive matcher and the star-loop fast path
    /// (matchSingleInstruction). Decodes the code point at `pos` and checks
    /// it against the instruction's General_Category operand.
    fn checkUnicodeProperty(self: *Self, pc: usize, pos: usize, inverted: bool) MatchError!struct { matched: bool, end_pos: usize } {
        if (pos >= self.input.len) return .{ .matched = false, .end_pos = pos };
        if (pc + 2 > self.bytecode.len) return error.UnexpectedEndOfBytecode;

        const category: properties.UnicodeProperty = @enumFromInt(self.bytecode[pc + 1]);
        const decoded = decodeCodepointAt(self.input, pos);
        const in_category = properties.isInCategory(decoded.codepoint, category);

        const matched = if (inverted) !in_category else in_category;
        return .{ .matched = matched, .end_pos = if (matched) pos + decoded.len else pos };
    }

    /// Shared matching logic for UNICODE_SCRIPT(_INV), used by both the main
    /// recursive matcher and the star-loop fast path (matchSingleInstruction).
    /// Decodes the code point at `pos` and checks it against the
    /// instruction's script-index operand.
    fn checkUnicodeScript(self: *Self, pc: usize, pos: usize, inverted: bool) MatchError!struct { matched: bool, end_pos: usize } {
        if (pos >= self.input.len) return .{ .matched = false, .end_pos = pos };
        if (pc + 2 > self.bytecode.len) return error.UnexpectedEndOfBytecode;

        const script_index = self.bytecode[pc + 1];
        const decoded = decodeCodepointAt(self.input, pos);
        const in_script = properties.isInScript(decoded.codepoint, script_index);

        const matched = if (inverted) !in_script else in_script;
        return .{ .matched = matched, .end_pos = if (matched) pos + decoded.len else pos };
    }

    /// Shared matching logic for UNICODE_SCRIPT_EXTENSIONS(_INV), used by
    /// both the main recursive matcher and the star-loop fast path
    /// (matchSingleInstruction). Same shape as `checkUnicodeScript`, but
    /// checks `properties.isInScriptExtensions` instead of `isInScript`.
    fn checkUnicodeScriptExtensions(self: *Self, pc: usize, pos: usize, inverted: bool) MatchError!struct { matched: bool, end_pos: usize } {
        if (pos >= self.input.len) return .{ .matched = false, .end_pos = pos };
        if (pc + 2 > self.bytecode.len) return error.UnexpectedEndOfBytecode;

        const script_index = self.bytecode[pc + 1];
        const decoded = decodeCodepointAt(self.input, pos);
        const in_script = properties.isInScriptExtensions(decoded.codepoint, script_index);

        const matched = if (inverted) !in_script else in_script;
        return .{ .matched = matched, .end_pos = if (matched) pos + decoded.len else pos };
    }

    /// Detect if SPLIT is part of star quantifier pattern
    /// Pattern: SPLIT pc_consume, pc_skip OR SPLIT pc_skip, pc_consume
    /// where pc_consume points to: CHAR; GOTO back_to_split
    fn isStarQuantifier(self: *Self, split_pc: usize, pc1: usize, pc2: usize) MatchError!bool {
        // Try pc1 as the consume path
        if (try self.isStarConsumePath(split_pc, pc1)) return true;

        // Try pc2 as the consume path
        if (try self.isStarConsumePath(split_pc, pc2)) return true;

        return false;
    }

    /// Every opcode that can be the quantified atom of `e?`/`e*`/`e+` and
    /// consumes (or, for BACK_REF, potentially doesn't consume -- see
    /// checkBackRef) input on success. Used by isStarConsumePath so it can't
    /// silently drift out of sync with the set of opcodes the codegen
    /// actually quantifies: a quantifiable opcode missing from this list
    /// previously caused `\1+`-style patterns to fall through to plain
    /// recursive alternation with no zero-width-progress guard, crashing on
    /// a stack overflow instead of matching correctly or hitting the depth
    /// limit (found via test262-derived conformance testing).
    fn isQuantifiableAtomOpcode(opcode: Opcode) bool {
        return switch (opcode) {
            .CHAR, .CHAR_ANY, .CHAR32, .CHAR2, .CHAR_RANGE, .CHAR_RANGE_INV, .CHAR_CLASS, .CHAR_CLASS_INV, .CHAR_SET, .CHAR_SET_INV, .UNICODE_PROPERTY, .UNICODE_PROPERTY_INV, .UNICODE_SCRIPT, .UNICODE_SCRIPT_INV, .UNICODE_SCRIPT_EXTENSIONS, .UNICODE_SCRIPT_EXTENSIONS_INV, .BACK_REF, .BACK_REF_I => true,
            else => false,
        };
    }

    /// Check if a given PC is the consume path of a star quantifier
    fn isStarConsumePath(self: *Self, split_pc: usize, consume_pc: usize) MatchError!bool {
        // Check if consume_pc points to a character-consuming instruction
        if (consume_pc >= self.bytecode.len) return false;

        const inst1 = try format.decodeInstruction(self.bytecode, consume_pc);
        const consumes_char = isQuantifiableAtomOpcode(inst1.opcode);
        if (!consumes_char) return false;

        const next_pc = consume_pc + inst1.size;

        // Plus-shape loop (`generatePlus`): `consume_pc: X; SPLIT_GREEDY
        // consume_pc, end;` -- X directly precedes the split with no
        // intervening GOTO, and looping happens via the split branching
        // straight back to consume_pc (which is already known to be one of
        // its two targets, since isStarQuantifier calls this with pc1/pc2).
        if (next_pc == split_pc) return true;

        // Star-shape loop (`generateStar`/`generateRepeat`'s unbounded
        // case): `split_pc: SPLIT end, consume_pc; consume_pc: X; GOTO
        // split_pc; end: ...` -- X is followed by an explicit GOTO back.
        if (next_pc >= self.bytecode.len) return false;

        const inst2 = try format.decodeInstruction(self.bytecode, next_pc);
        if (inst2.opcode != .GOTO) return false;

        const goto_offset = @as(i32, @bitCast(inst2.operands[0]));
        const goto_target: i32 = @intCast(next_pc);
        const target_pc = goto_target + goto_offset;

        return target_pc == @as(i32, @intCast(split_pc));
    }

    /// Match star quantifier with backtracking
    /// pc_char: PC of the character-consuming instruction
    /// pc_rest: PC of the rest of the pattern
    /// greedy: if true, consume maximally first
    fn matchStar(self: *Self, pc_char: usize, pc_rest: usize, pos: usize, greedy: bool) MatchError!MatchResult {
        if (greedy) {
            return self.matchStarGreedy(pc_char, pc_rest, pos);
        } else {
            return self.matchStarLazy(pc_char, pc_rest, pos);
        }
    }

    /// Greedy star: consume maximum, then backtrack
    fn matchStarGreedy(self: *Self, pc_char: usize, pc_rest: usize, pos: usize) MatchError!MatchResult {
        var current_pos = pos;

        // PHASE 1: Greedy consumption - match as many as possible
        var positions: std.ArrayList(usize) = .empty;
        defer positions.deinit(self.allocator);

        try positions.append(self.allocator, current_pos); // Include zero matches

        // Get the character instruction to match
        const char_inst = try format.decodeInstruction(self.bytecode, pc_char);

        while (current_pos < self.input.len) {
            // Match just the character instruction, not the full pattern
            const matched = try self.matchSingleInstruction(char_inst, pc_char, current_pos);
            if (!matched.matched) break;

            // Prevent infinite loop if char didn't consume anything
            if (matched.end_pos == current_pos) break;

            current_pos = matched.end_pos;
            try positions.append(self.allocator, current_pos);
        }

        // PHASE 2: Try rest of pattern from each position (longest first)
        var i: usize = positions.items.len;
        while (i > 0) {
            i -= 1;
            const try_pos = positions.items[i];

            const rest_result = try self.matchFrom(pc_rest, try_pos);
            if (rest_result.matched) {
                return rest_result;
            }
        }

        // Failed to match
        return MatchResult{ .matched = false, .end_pos = pos };
    }

    /// Lazy star: try minimal match first, expand if needed
    fn matchStarLazy(self: *Self, pc_char: usize, pc_rest: usize, pos: usize) MatchError!MatchResult {
        var current_pos = pos;

        // Try matching rest first (zero matches of star)
        const rest_result = try self.matchFrom(pc_rest, current_pos);
        if (rest_result.matched) {
            return rest_result;
        }

        // Get the character instruction to match
        const char_inst = try format.decodeInstruction(self.bytecode, pc_char);

        // If that fails, try consuming one char at a time
        while (current_pos < self.input.len) {
            const matched = try self.matchSingleInstruction(char_inst, pc_char, current_pos);
            if (!matched.matched) break;

            // Prevent infinite loop if the atom matched but consumed no
            // input (e.g. a zero-width backreference). Must compare against
            // the pre-update position: comparing after `current_pos` is
            // already overwritten below is trivially always true, which
            // previously made this loop stop after exactly one iteration
            // regardless of whether real progress was made.
            if (matched.end_pos == current_pos) break;

            current_pos = matched.end_pos;

            // Try rest again
            const rest_result2 = try self.matchFrom(pc_rest, current_pos);
            if (rest_result2.matched) {
                return rest_result2;
            }
        }

        return MatchResult{ .matched = false, .end_pos = pos };
    }

    /// Possessive star: consume all without backtracking
    fn matchStarPossessive(self: *Self, pc_char: usize, pc_rest: usize, pos: usize) MatchError!MatchResult {
        var current_pos = pos;

        // Get the character instruction to match
        const char_inst = try format.decodeInstruction(self.bytecode, pc_char);

        // Consume ALL matching characters (possessive = no backtracking)
        while (current_pos < self.input.len) {
            const matched = try self.matchSingleInstruction(char_inst, pc_char, current_pos);
            if (!matched.matched) break;

            // Prevent infinite loop if char didn't consume anything
            if (matched.end_pos == current_pos) break;

            current_pos = matched.end_pos;
        }

        // Try rest ONCE from final position (no backtracking)
        return self.matchFrom(pc_rest, current_pos);
    }

    /// Match a single instruction without advancing PC
    /// Used by star quantifiers to match the repeated element
    fn matchSingleInstruction(self: *Self, inst: Instruction, pc: usize, pos: usize) MatchError!struct { matched: bool, end_pos: usize } {
        switch (inst.opcode) {
            .CHAR32 => {
                // Match specific character
                const expected = @as(u8, @intCast(inst.operands[0]));
                if (pos >= self.input.len) {
                    return .{ .matched = false, .end_pos = pos };
                }
                if (self.input[pos] != expected) {
                    return .{ .matched = false, .end_pos = pos };
                }
                return .{ .matched = true, .end_pos = pos + 1 };
            },

            .CHAR => {
                // Match any Unicode scalar value except a LineTerminator
                // (dot without /s)
                if (pos >= self.input.len or isLineTerminatorAt(self.input, pos)) {
                    return .{ .matched = false, .end_pos = pos };
                }
                return .{ .matched = true, .end_pos = pos + utf8SeqLenAt(self.input, pos) };
            },

            .CHAR_ANY => {
                // Match any Unicode scalar value, including newline (dot with /s)
                if (pos >= self.input.len) {
                    return .{ .matched = false, .end_pos = pos };
                }
                return .{ .matched = true, .end_pos = pos + utf8SeqLenAt(self.input, pos) };
            },

            .CHAR_RANGE => {
                // Match character in range
                const min = @as(u8, @intCast(inst.operands[0]));
                const max = @as(u8, @intCast(inst.operands[1]));
                if (pos >= self.input.len) {
                    return .{ .matched = false, .end_pos = pos };
                }
                const c = self.input[pos];
                if (c < min or c > max) {
                    return .{ .matched = false, .end_pos = pos };
                }
                return .{ .matched = true, .end_pos = pos + 1 };
            },

            .CHAR_RANGE_INV => {
                // Match character NOT in range (consumes a full UTF-8
                // sequence, like CHAR — see matchCharRangeInv)
                const min = @as(u8, @intCast(inst.operands[0]));
                const max = @as(u8, @intCast(inst.operands[1]));
                if (pos >= self.input.len) {
                    return .{ .matched = false, .end_pos = pos };
                }
                const c = self.input[pos];
                // Inverted: match if NOT in range
                if (c >= min and c <= max) {
                    return .{ .matched = false, .end_pos = pos };
                }
                return .{ .matched = true, .end_pos = pos + utf8SeqLenAt(self.input, pos) };
            },

            .CHAR_CLASS => {
                // Match character in class (bit table)
                if (pos >= self.input.len) {
                    return .{ .matched = false, .end_pos = pos };
                }
                if (pc + 33 > self.bytecode.len) {
                    return .{ .matched = false, .end_pos = pos };
                }
                const table = self.bytecode[pc + 1 ..][0..32];
                const c = self.input[pos];
                const byte_idx = c / 8;
                const bit_idx = @as(u3, @intCast(c % 8));
                const is_in_class = (table[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
                if (!is_in_class) {
                    return .{ .matched = false, .end_pos = pos };
                }
                return .{ .matched = true, .end_pos = pos + 1 };
            },

            .CHAR_CLASS_INV => {
                // Match character NOT in class (consumes a full UTF-8
                // sequence, like CHAR — see matchCharClassInv)
                if (pos >= self.input.len) {
                    return .{ .matched = false, .end_pos = pos };
                }
                if (pc + 33 > self.bytecode.len) {
                    return .{ .matched = false, .end_pos = pos };
                }
                const table = self.bytecode[pc + 1 ..][0..32];
                const c = self.input[pos];
                const byte_idx = c / 8;
                const bit_idx = @as(u3, @intCast(c % 8));
                const is_in_class = (table[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
                // Inverted: match if NOT in class
                if (is_in_class) {
                    return .{ .matched = false, .end_pos = pos };
                }
                return .{ .matched = true, .end_pos = pos + utf8SeqLenAt(self.input, pos) };
            },

            .CHAR_SET, .CHAR_SET_INV => {
                const r = try self.checkCharSet(inst, pos);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .UNICODE_PROPERTY => {
                const r = try self.checkUnicodeProperty(pc, pos, false);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .UNICODE_PROPERTY_INV => {
                const r = try self.checkUnicodeProperty(pc, pos, true);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .UNICODE_SCRIPT => {
                const r = try self.checkUnicodeScript(pc, pos, false);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .UNICODE_SCRIPT_INV => {
                const r = try self.checkUnicodeScript(pc, pos, true);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .UNICODE_SCRIPT_EXTENSIONS => {
                const r = try self.checkUnicodeScriptExtensions(pc, pos, false);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .UNICODE_SCRIPT_EXTENSIONS_INV => {
                const r = try self.checkUnicodeScriptExtensions(pc, pos, true);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .BACK_REF => {
                const group = @as(usize, @intCast(inst.operands[0]));
                const r = self.checkBackRef(pos, group, false);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .BACK_REF_I => {
                const group = @as(usize, @intCast(inst.operands[0]));
                const r = self.checkBackRef(pos, group, true);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            else => {
                // For other instructions (shouldn't happen in star loop)
                return .{ .matched = false, .end_pos = pos };
            },
        }
    }

    /// Match lookahead assertion (zero-width)
    fn matchLookahead(self: *Self, pc: usize, pos: usize, negative: bool, inst_size: usize) MatchError!MatchResult {
        // Find the end of the lookahead body (LOOKAHEAD_END opcode)
        const lookahead_end_pc = try self.findLookaheadEnd(pc + inst_size);

        // Snapshot captures before probing the lookahead body: per the
        // ECMAScript spec, a lookahead's inner match attempt only commits
        // its capture mutations to the surrounding match when it's a
        // *positive* lookahead that *succeeds* (that's the documented
        // "lookahead captures leak out" behavior, e.g.
        // `/(?=(a))/.exec("a")` capturing "a"). In every other outcome
        // (positive-fails, negative-succeeds, negative-fails) the inner
        // attempt's captures must not be observable afterward. Per-SAVE
        // rollback (see SAVE_START/SAVE_END) only undoes a mutation when
        // its own immediate continuation fails, which isn't enough here:
        // a negative lookahead's inner pattern can genuinely *succeed* as a
        // raw match (setting captures along the way) and it's this
        // function, not any SAVE instruction, that turns that success into
        // the assertion's failure -- so only a full snapshot/restore at
        // this boundary catches it.
        // On the heap, not in this frame: push the slots, restore from
        // them, and pop on the way out (nested lookarounds nest LIFO).
        const mark = self.snapshots.items.len;
        try self.snapshots.appendSlice(self.allocator, self.caps());
        defer self.snapshots.shrinkRetainingCapacity(mark);

        // Execute the lookahead pattern starting after the LOOKAHEAD opcode
        // This is a zero-width assertion, so we test at current position
        const result = try self.matchFrom(pc + inst_size, pos);

        if (negative) {
            // Negative lookahead: succeed if pattern did NOT match
            if (!result.matched) {
                // Pattern didn't match, so negative lookahead succeeds.
                // Discard any partial captures from the failed attempt,
                // then continue after LOOKAHEAD_END without consuming input.
                self.restoreSnapshot(mark);
                return self.matchFrom(lookahead_end_pc + 1, pos);
            } else {
                // Pattern matched, so negative lookahead fails. Discard its
                // captures too -- this whole path is being abandoned.
                self.restoreSnapshot(mark);
                return MatchResult{ .matched = false, .end_pos = pos };
            }
        } else {
            // Positive lookahead: succeed if pattern DID match
            if (result.matched) {
                // Pattern matched, so positive lookahead succeeds; its
                // captures are intentionally left in place (spec'd leak).
                // Continue after LOOKAHEAD_END without consuming input.
                return self.matchFrom(lookahead_end_pc + 1, pos);
            } else {
                // Pattern didn't match, so positive lookahead fails.
                self.restoreSnapshot(mark);
                return MatchResult{ .matched = false, .end_pos = pos };
            }
        }
    }

    fn restoreSnapshot(self: *Self, mark: usize) void {
        @memcpy(self.caps(), self.snapshots.items[mark..][0..self.capture_slots]);
    }

    /// Find the position of LOOKAHEAD_END opcode
    fn findLookaheadEnd(self: Self, start_pc: usize) MatchError!usize {
        var pc = start_pc;
        var depth: usize = 1; // Track nested lookaheads

        while (pc < self.bytecode.len) {
            const inst = try format.decodeInstruction(self.bytecode, pc);

            switch (inst.opcode) {
                .LOOKAHEAD, .NEGATIVE_LOOKAHEAD => {
                    // Nested lookahead, increase depth
                    depth += 1;
                    pc += inst.size;
                },
                .LOOKAHEAD_END => {
                    depth -= 1;
                    if (depth == 0) {
                        // Found matching end
                        return pc;
                    }
                    pc += inst.size;
                },
                else => {
                    pc += inst.size;
                },
            }
        }

        // Didn't find matching LOOKAHEAD_END
        return error.UnexpectedEndOfBytecode;
    }

    /// Match lookbehind assertion: (?<=...) or (?<!...)
    /// This matches a pattern BEFORE the current position (zero-width)
    fn matchLookbehind(self: *Self, pc: usize, pos: usize, negative: bool, inst_size: usize) MatchError!MatchResult {
        // Find the end of the lookbehind body
        const lookbehind_end_pc = try self.findLookbehindEnd(pc + inst_size);

        // Try different lookbehind lengths (starting positions)
        // We try from pos backwards up to a reasonable limit
        const max_lookbehind_len = @min(pos, 100); // Limit to 100 chars for performance

        var found_match = false;

        // DEBUG: uncomment to see what's happening
        // std.debug.print("matchLookbehind: pos={}, max_len={}\n", .{pos, max_lookbehind_len});

        // Try different starting positions, from closest to farthest
        var try_len: usize = 1;
        while (try_len <= max_lookbehind_len) : (try_len += 1) {
            const start_pos = pos - try_len;

            // Try to match the pattern from start_pos
            const result = try self.matchFrom(pc + inst_size, start_pos);

            // DEBUG: uncomment to see results
            // std.debug.print("  try_len={}, start_pos={}, matched={}, end_pos={}\n", .{try_len, start_pos, result.matched, result.end_pos});

            // Check if match ends exactly at current position (pos)
            if (result.matched and result.end_pos == pos) {
                found_match = true;
                break;
            }
        }

        // Also try empty match (zero-length lookbehind)
        if (!found_match) {
            const result = try self.matchFrom(pc + inst_size, pos);
            // DEBUG
            // std.debug.print("  empty match: matched={}, end_pos={}\n", .{result.matched, result.end_pos});
            if (result.matched and result.end_pos == pos) {
                found_match = true;
            }
        }

        if (negative) {
            // Negative lookbehind: succeed if pattern did NOT match
            if (!found_match) {
                // Pattern didn't match, so negative lookbehind succeeds
                // Continue after LOOKBEHIND_END without consuming input
                return self.matchFrom(lookbehind_end_pc + 1, pos);
            } else {
                // Pattern matched, so negative lookbehind fails
                return MatchResult{ .matched = false, .end_pos = pos };
            }
        } else {
            // Positive lookbehind: succeed if pattern DID match
            if (found_match) {
                // Pattern matched, so positive lookbehind succeeds
                // Continue after LOOKBEHIND_END without consuming input
                return self.matchFrom(lookbehind_end_pc + 1, pos);
            } else {
                // Pattern didn't match, so positive lookbehind fails
                return MatchResult{ .matched = false, .end_pos = pos };
            }
        }
    }

    /// Find the position of LOOKBEHIND_END opcode
    fn findLookbehindEnd(self: Self, start_pc: usize) MatchError!usize {
        var pc = start_pc;
        var depth: usize = 1; // Track nested lookbehinds

        while (pc < self.bytecode.len) {
            const inst = try format.decodeInstruction(self.bytecode, pc);

            switch (inst.opcode) {
                .LOOKBEHIND, .NEGATIVE_LOOKBEHIND => {
                    // Nested lookbehind, increase depth
                    depth += 1;
                    pc += inst.size;
                },
                .LOOKBEHIND_END => {
                    depth -= 1;
                    if (depth == 0) {
                        // Found matching end
                        return pc;
                    }
                    pc += inst.size;
                },
                else => {
                    pc += inst.size;
                },
            }
        }

        // Didn't find matching LOOKBEHIND_END
        return error.UnexpectedEndOfBytecode;
    }

    /// Match backreference to capture group
    fn matchBackRef(self: *Self, pc: usize, pos: usize, group: usize, case_insensitive: bool, inst_size: usize) MatchError!MatchResult {
        const r = self.checkBackRef(pos, group, case_insensitive);
        if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
        return self.matchFrom(pc + inst_size, r.end_pos);
    }

    /// Shared backreference-matching logic for BACK_REF(_I), used by both
    /// the main recursive matcher and the star-loop fast path
    /// (matchSingleInstruction). A backreference to a group that captured
    /// zero characters matches zero characters here too (`end_pos == pos`)
    /// -- callers that loop on this (e.g. `\1+`) must have their own
    /// zero-width-progress guard, same as any other quantified atom.
    fn checkBackRef(self: *Self, pos: usize, group: usize, case_insensitive: bool) struct { matched: bool, end_pos: usize } {
        if (group >= self.capture_slots) {
            return .{ .matched = false, .end_pos = pos };
        }

        const capture = self.caps()[group];
        if (!capture.isValid()) {
            // Per the ECMAScript spec, a backreference to a group that
            // hasn't participated in the match (e.g. an alternation branch
            // not taken, or a negative lookahead's own group -- see
            // matchLookahead) always succeeds, matching the empty string.
            // It must NOT fail outright: `/(a)?\1b/.exec("b")` matches in
            // JS with capture 1 left undefined.
            return .{ .matched = true, .end_pos = pos };
        }

        const cap_start = capture.start.?;
        const cap_end = capture.end.?;
        // A group re-entered but not closed yet in this iteration holds the
        // new start with the previous iteration's end (end < start): reached
        // from inside the group itself (`(a\1)*`, `(?<n>\k<n>x)`). The spec
        // clears the atom's captures at each iteration, so the group hasn't
        // participated yet: match empty. (Before F1c this subtraction
        // overflowed: a panic in safe builds; found by differential-v8.)
        if (cap_end < cap_start) return .{ .matched = true, .end_pos = pos };
        const cap_len = cap_end - cap_start;

        if (pos + cap_len > self.input.len) {
            return .{ .matched = false, .end_pos = pos };
        }

        const captured_text = self.input[cap_start..cap_end];
        const current_text = self.input[pos .. pos + cap_len];

        for (captured_text, 0..) |cap_char, i| {
            const cur_char = current_text[i];
            const eq = if (case_insensitive)
                std.ascii.toLower(cap_char) == std.ascii.toLower(cur_char)
            else
                cap_char == cur_char;
            if (!eq) return .{ .matched = false, .end_pos = pos };
        }

        return .{ .matched = true, .end_pos = pos + cap_len };
    }

    /// Check if position is at word boundary
    fn isWordBoundary(self: Self, pos: usize) bool {
        const before_is_word = if (pos > 0) isWordChar(self.input[pos - 1]) else false;
        const after_is_word = if (pos < self.input.len) isWordChar(self.input[pos]) else false;
        return before_is_word != after_is_word;
    }

    /// Check if character is word character
    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }
};

// =============================================================================
// Tests
// =============================================================================

test "RecursiveMatcher: ExecOptions - default values" {
    const options = ExecOptions{};
    try std.testing.expectEqual(@as(usize, DEFAULT_MAX_RECURSION_DEPTH), options.max_recursion_depth);
    try std.testing.expectEqual(@as(usize, DEFAULT_MAX_STEPS), options.max_steps);
}

test "RecursiveMatcher: ExecOptions - unlimited" {
    const options = ExecOptions.unlimited();
    try std.testing.expectEqual(@as(usize, 0), options.max_recursion_depth);
    try std.testing.expectEqual(@as(usize, 0), options.max_steps);
}

test "RecursiveMatcher: ExecOptions - custom limits" {
    const options = ExecOptions.withLimits(100, 5000);
    try std.testing.expectEqual(@as(usize, 100), options.max_recursion_depth);
    try std.testing.expectEqual(@as(usize, 5000), options.max_steps);
}

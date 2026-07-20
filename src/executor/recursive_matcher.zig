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
const properties = @import("../unicode/properties.zig");

const Opcode = opcodes.Opcode;
const Instruction = format.Instruction;

/// Maximum number of capture groups supported
const MAX_CAPTURE_GROUPS = 16;

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

/// Match result
pub const MatchResult = struct {
    matched: bool,
    end_pos: usize,

    /// Capture groups (index 0 = whole match)
    captures: [MAX_CAPTURE_GROUPS]CaptureGroup = [_]CaptureGroup{.{}} ** MAX_CAPTURE_GROUPS,

    /// Get capture group by index
    pub fn getCapture(self: MatchResult, group: usize, input: []const u8) ?[]const u8 {
        if (group >= MAX_CAPTURE_GROUPS) return null;
        const cap = self.captures[group];
        if (!cap.isValid()) return null;
        return input[cap.start.?..cap.end.?];
    }
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
    input: []const u8,
    captures: [MAX_CAPTURE_GROUPS]CaptureGroup,
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
    pub const MatchError = error{ OutOfMemory, UnknownOpcode, UnexpectedEndOfBytecode, RecursionLimitExceeded, StepLimitExceeded };

    pub fn init(allocator: Allocator, bytecode: []const u8, input: []const u8) Self {
        return Self.initWithOptions(allocator, bytecode, input, ExecOptions{});
    }

    pub fn initWithOptions(allocator: Allocator, bytecode: []const u8, input: []const u8, options: ExecOptions) Self {
        return .{
            .allocator = allocator,
            .bytecode = bytecode,
            .input = input,
            .captures = [_]CaptureGroup{.{}} ** MAX_CAPTURE_GROUPS,
            .recursion_depth = 0,
            .step_count = 0,
            .exec_options = options,
            .loop_guard = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.loop_guard.deinit(self.allocator);
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
    pub fn matchFrom(self: *Self, pc: usize, pos: usize) error{ OutOfMemory, UnknownOpcode, UnexpectedEndOfBytecode, RecursionLimitExceeded, StepLimitExceeded }!MatchResult {
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
                var result = MatchResult{
                    .matched = true,
                    .end_pos = pos,
                };
                result.captures = self.captures;
                return result;
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

            .CHAR_CLASS_RANGES => {
                const r = try self.checkCharClassRanges(pc, pos, false);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .CHAR_CLASS_RANGES_INV => {
                const r = try self.checkCharClassRanges(pc, pos, true);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .CHAR_CLASS_UNICODE => {
                const r = try self.checkCharClassUnicode(pc, pos, false);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .CHAR_CLASS_UNICODE_INV => {
                const r = try self.checkCharClassUnicode(pc, pos, true);
                if (!r.matched) return MatchResult{ .matched = false, .end_pos = pos };
                return self.matchFrom(pc + inst.size, r.end_pos);
            },

            .CHAR_CLASS_SET_OP => {
                const r = try self.checkCharClassSetOp(pc, pos);
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
                if (group < MAX_CAPTURE_GROUPS) {
                    const prev = self.captures[group];
                    self.captures[group].start = pos;
                    const result = try self.matchFrom(pc + inst.size, pos);
                    if (!result.matched) self.captures[group] = prev;
                    return result;
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            .SAVE_END => {
                // Save capture group end (see SAVE_START for why this must
                // roll back on failure too).
                const group = @as(usize, @intCast(inst.operands[0]));
                if (group < MAX_CAPTURE_GROUPS) {
                    const prev = self.captures[group];
                    self.captures[group].end = pos;
                    const result = try self.matchFrom(pc + inst.size, pos);
                    if (!result.matched) self.captures[group] = prev;
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
                if (group < MAX_CAPTURE_GROUPS) {
                    const prev = self.captures[group];
                    self.captures[group] = .{};
                    const result = try self.matchFrom(pc + inst.size, pos);
                    if (!result.matched) self.captures[group] = prev;
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
                return MatchResult{
                    .matched = true,
                    .end_pos = pos,
                    .captures = self.captures,
                };
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
                return MatchResult{
                    .matched = true,
                    .end_pos = pos,
                    .captures = self.captures,
                };
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
                // start of input, or immediately after a '\n'
                const at_line_start = pos == 0 or self.input[pos - 1] == '\n';
                if (!at_line_start) {
                    return MatchResult{ .matched = false, .end_pos = pos };
                }
                return self.matchFrom(pc + inst.size, pos);
            },

            .LINE_END => {
                // Assert end of line (used for $ with multiline): absolute
                // end of input, or immediately before a '\n'
                const at_line_end = pos == self.input.len or self.input[pos] == '\n';
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

    /// Length in bytes of the UTF-8 sequence starting at `input[pos]` (1-4),
    /// or 1 if it isn't the start of a valid sequence, or the sequence would
    /// run past the end of input, or the bytes there don't decode validly.
    /// This keeps matching binary-safe: malformed/non-UTF-8 input degrades to
    /// byte-at-a-time matching instead of erroring.
    fn utf8SeqLenAt(input: []const u8, pos: usize) usize {
        if (pos >= input.len) return 1;
        const len = std.unicode.utf8ByteSequenceLength(input[pos]) catch return 1;
        if (pos + len > input.len) return 1;
        _ = std.unicode.utf8Decode(input[pos..][0..len]) catch return 1;
        return len;
    }

    /// Match any Unicode scalar value (dot). `exclude_newline` is true for
    /// plain `.` (no /s flag), false for dot_all. Consumes the full UTF-8
    /// sequence at `pos`, not just one byte.
    fn matchAnyChar(self: *Self, pc: usize, pos: usize, exclude_newline: bool, inst_size: usize) MatchError!MatchResult {
        if (pos >= self.input.len) {
            return MatchResult{ .matched = false, .end_pos = pos };
        }
        if (exclude_newline and self.input[pos] == '\n') {
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
        // utf8SeqLenAt only returns >1 after already validating the decode.
        const cp = std.unicode.utf8Decode(input[pos..][0..len]) catch unreachable;
        return .{ .codepoint = cp, .len = len };
    }

    /// Shared range-matching logic for CHAR_CLASS_RANGES(_INV), used by both
    /// the main recursive matcher and the star-loop fast path
    /// (matchSingleInstruction). Decodes the code point at `pos` and checks
    /// it against the instruction's inline range table.
    fn checkCharClassRanges(self: *Self, pc: usize, pos: usize, inverted: bool) MatchError!struct { matched: bool, end_pos: usize } {
        if (pos >= self.input.len) return .{ .matched = false, .end_pos = pos };
        if (pc + 2 > self.bytecode.len) return error.UnexpectedEndOfBytecode;

        const count = self.bytecode[pc + 1];
        const ranges_start = pc + 2;
        if (ranges_start + @as(usize, count) * 8 > self.bytecode.len) return error.UnexpectedEndOfBytecode;

        const decoded = decodeCodepointAt(self.input, pos);

        var in_range = false;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const offset = ranges_start + i * 8;
            const start = std.mem.readInt(u32, self.bytecode[offset..][0..4], .little);
            const end = std.mem.readInt(u32, self.bytecode[offset + 4 ..][0..4], .little);
            if (decoded.codepoint >= start and decoded.codepoint <= end) {
                in_range = true;
                break;
            }
        }

        const matched = if (inverted) !in_range else in_range;
        return .{ .matched = matched, .end_pos = if (matched) pos + decoded.len else pos };
    }

    /// Shared matching logic for CHAR_CLASS_UNICODE(_INV), used by both the
    /// main recursive matcher and the star-loop fast path
    /// (matchSingleInstruction). Decodes the code point at `pos` and checks
    /// it against the instruction's inline range table (same layout as
    /// CHAR_CLASS_RANGES) OR any of its property/script/script-extensions
    /// tests (each with its own `negated` bit, independent of this
    /// function's `inverted` parameter -- which applies once, to the whole
    /// union, matching the opcode's _INV form -- see CHAR_CLASS_UNICODE's
    /// doc comment in opcodes.zig for why those are different things).
    fn checkCharClassUnicode(self: *Self, pc: usize, pos: usize, inverted: bool) MatchError!struct { matched: bool, end_pos: usize } {
        if (pos >= self.input.len) return .{ .matched = false, .end_pos = pos };

        const ranges_start = pc + 2;
        const props_count_offset = ranges_start + opcodes.MAX_CLASS_RANGES * 8;
        const props_start = props_count_offset + 1;
        const total_size = props_start + opcodes.MAX_CLASS_PROPERTIES * 3;
        if (pc + 2 > self.bytecode.len or total_size > self.bytecode.len) return error.UnexpectedEndOfBytecode;

        const range_count = self.bytecode[pc + 1];
        const prop_count = self.bytecode[props_count_offset];
        const decoded = decodeCodepointAt(self.input, pos);

        var matched_any = false;

        var i: usize = 0;
        while (i < range_count) : (i += 1) {
            const offset = ranges_start + i * 8;
            const start = std.mem.readInt(u32, self.bytecode[offset..][0..4], .little);
            const end = std.mem.readInt(u32, self.bytecode[offset + 4 ..][0..4], .little);
            if (decoded.codepoint >= start and decoded.codepoint <= end) {
                matched_any = true;
                break;
            }
        }

        if (!matched_any) {
            var j: usize = 0;
            while (j < prop_count) : (j += 1) {
                const offset = props_start + j * 3;
                const kind: opcodes.ClassPropertyKind = @enumFromInt(self.bytecode[offset]);
                const negated = self.bytecode[offset + 1] != 0;
                const value = self.bytecode[offset + 2];
                const in_prop = switch (kind) {
                    .unicode_property => properties.isInCategory(decoded.codepoint, @enumFromInt(value)),
                    .script => properties.isInScript(decoded.codepoint, value),
                    .script_extensions => properties.isInScriptExtensions(decoded.codepoint, value),
                };
                const prop_matched = if (negated) !in_prop else in_prop;
                if (prop_matched) {
                    matched_any = true;
                    break;
                }
            }
        }

        const matched = if (inverted) !matched_any else matched_any;
        return .{ .matched = matched, .end_pos = if (matched) pos + decoded.len else pos };
    }

    /// Evaluate one CHAR_CLASS_SET_OP operand block (see the opcode's doc
    /// comment for the byte layout -- identical range/property-table shape
    /// `checkCharClassUnicode` uses, prefixed with this operand's own
    /// `negated` byte) against an already-decoded code point. Shared by
    /// `checkCharClassSetOp`'s two operands.
    fn evalClassSetOperand(self: *Self, offset: usize, cp: u32) bool {
        const negated = self.bytecode[offset] != 0;
        const range_count = self.bytecode[offset + 1];
        const ranges_start = offset + 2;
        var matched = false;

        var i: usize = 0;
        while (i < range_count) : (i += 1) {
            const roff = ranges_start + i * 8;
            const start = std.mem.readInt(u32, self.bytecode[roff..][0..4], .little);
            const end = std.mem.readInt(u32, self.bytecode[roff + 4 ..][0..4], .little);
            if (cp >= start and cp <= end) {
                matched = true;
                break;
            }
        }

        if (!matched) {
            const props_count_offset = ranges_start + opcodes.MAX_CLASS_RANGES * 8;
            const props_start = props_count_offset + 1;
            const prop_count = self.bytecode[props_count_offset];
            var j: usize = 0;
            while (j < prop_count) : (j += 1) {
                const poff = props_start + j * 3;
                const kind: opcodes.ClassPropertyKind = @enumFromInt(self.bytecode[poff]);
                const pnegated = self.bytecode[poff + 1] != 0;
                const value = self.bytecode[poff + 2];
                const in_prop = switch (kind) {
                    .unicode_property => properties.isInCategory(cp, @enumFromInt(value)),
                    .script => properties.isInScript(cp, value),
                    .script_extensions => properties.isInScriptExtensions(cp, value),
                };
                const prop_matched = if (pnegated) !in_prop else in_prop;
                if (prop_matched) {
                    matched = true;
                    break;
                }
            }
        }

        return if (negated) !matched else matched;
    }

    /// Shared matching logic for CHAR_CLASS_SET_OP, used by both the main
    /// recursive matcher and the star-loop fast path (matchSingleInstruction).
    /// Decodes the code point at `pos` once and evaluates it against both
    /// operand blocks (see `evalClassSetOperand`), combining with AND
    /// (intersection, `op=1`) or AND-NOT (difference, `op=0`), then applies
    /// `result_negated` (the whole operation's own `[^...]`, a third,
    /// independent negation layer -- see CHAR_CLASS_SET_OP's doc comment in
    /// opcodes.zig).
    fn checkCharClassSetOp(self: *Self, pc: usize, pos: usize) MatchError!struct { matched: bool, end_pos: usize } {
        if (pos >= self.input.len) return .{ .matched = false, .end_pos = pos };

        const op = self.bytecode[pc + 1];
        const result_negated = self.bytecode[pc + 2] != 0;
        const left_offset = pc + 3;
        const right_offset = left_offset + opcodes.CLASS_SET_OPERAND_SIZE;
        const total_size = right_offset + opcodes.CLASS_SET_OPERAND_SIZE;
        if (total_size > self.bytecode.len) return error.UnexpectedEndOfBytecode;

        const decoded = decodeCodepointAt(self.input, pos);
        const left_matched = self.evalClassSetOperand(left_offset, decoded.codepoint);
        const right_matched = self.evalClassSetOperand(right_offset, decoded.codepoint);

        const combined = if (op == 1) (left_matched and right_matched) else (left_matched and !right_matched);
        const matched = if (result_negated) !combined else combined;

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
            .CHAR, .CHAR_ANY, .CHAR32, .CHAR2, .CHAR_RANGE, .CHAR_RANGE_INV, .CHAR_CLASS, .CHAR_CLASS_INV, .CHAR_CLASS_RANGES, .CHAR_CLASS_RANGES_INV, .CHAR_CLASS_UNICODE, .CHAR_CLASS_UNICODE_INV, .CHAR_CLASS_SET_OP, .UNICODE_PROPERTY, .UNICODE_PROPERTY_INV, .UNICODE_SCRIPT, .UNICODE_SCRIPT_INV, .UNICODE_SCRIPT_EXTENSIONS, .UNICODE_SCRIPT_EXTENSIONS_INV, .BACK_REF, .BACK_REF_I => true,
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
                // Match any Unicode scalar value except newline (dot without /s)
                if (pos >= self.input.len or self.input[pos] == '\n') {
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

            .CHAR_CLASS_RANGES => {
                const r = try self.checkCharClassRanges(pc, pos, false);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .CHAR_CLASS_RANGES_INV => {
                const r = try self.checkCharClassRanges(pc, pos, true);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .CHAR_CLASS_UNICODE => {
                const r = try self.checkCharClassUnicode(pc, pos, false);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .CHAR_CLASS_UNICODE_INV => {
                const r = try self.checkCharClassUnicode(pc, pos, true);
                return .{ .matched = r.matched, .end_pos = r.end_pos };
            },

            .CHAR_CLASS_SET_OP => {
                const r = try self.checkCharClassSetOp(pc, pos);
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
        const captures_snapshot = self.captures;

        // Execute the lookahead pattern starting after the LOOKAHEAD opcode
        // This is a zero-width assertion, so we test at current position
        const result = try self.matchFrom(pc + inst_size, pos);

        if (negative) {
            // Negative lookahead: succeed if pattern did NOT match
            if (!result.matched) {
                // Pattern didn't match, so negative lookahead succeeds.
                // Discard any partial captures from the failed attempt,
                // then continue after LOOKAHEAD_END without consuming input.
                self.captures = captures_snapshot;
                return self.matchFrom(lookahead_end_pc + 1, pos);
            } else {
                // Pattern matched, so negative lookahead fails. Discard its
                // captures too -- this whole path is being abandoned.
                self.captures = captures_snapshot;
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
                self.captures = captures_snapshot;
                return MatchResult{ .matched = false, .end_pos = pos };
            }
        }
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
        if (group >= MAX_CAPTURE_GROUPS) {
            return .{ .matched = false, .end_pos = pos };
        }

        const capture = self.captures[group];
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

test "RecursiveMatcher: question quantifier" {
    const compiler = @import("../codegen/compiler.zig");

    const result = try compiler.compileSimple(std.testing.allocator, "a?");
    defer result.deinit();

    // Test with empty string (should match)
    {
        var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, "");
        defer matcher.deinit();
        const exec_result = try matcher.matchFrom(0, 0);
        try std.testing.expect(exec_result.matched);
        try std.testing.expectEqual(@as(usize, 0), exec_result.end_pos);
    }

    // Test with "a" (should match and consume)
    {
        var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, "a");
        defer matcher.deinit();
        const exec_result = try matcher.matchFrom(0, 0);
        try std.testing.expect(exec_result.matched);
        try std.testing.expectEqual(@as(usize, 1), exec_result.end_pos);
    }
}

test "RecursiveMatcher: simple star quantifier" {
    const compiler = @import("../codegen/compiler.zig");

    const result = try compiler.compileSimple(std.testing.allocator, "a*");
    defer result.deinit();

    // Test with empty string (should match)
    {
        var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, "");
        defer matcher.deinit();
        const exec_result = try matcher.matchFrom(0, 0);
        try std.testing.expect(exec_result.matched);
        try std.testing.expectEqual(@as(usize, 0), exec_result.end_pos);
    }

    // Test with "aaa" (should match)
    {
        var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, "aaa");
        defer matcher.deinit();
        const exec_result = try matcher.matchFrom(0, 0);

        try std.testing.expect(exec_result.matched);
        try std.testing.expectEqual(@as(usize, 3), exec_result.end_pos);
    }
}

test "RecursiveMatcher: ReDoS protection - step limit" {
    const compiler = @import("../codegen/compiler.zig");

    // Patrón que causa backtracking exponencial: (a+)+b
    const result = try compiler.compileSimple(std.testing.allocator, "(a+)+b");
    defer result.deinit();

    // Input malicioso: muchas 'a's sin 'b' al final
    const malicious_input = "aaaaaaaaaaaaaaaaaaaaX"; // 20 'a's + 'X'

    var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, malicious_input);
    defer matcher.deinit();

    // Debería alcanzar el límite de pasos y lanzar error
    const exec_result = matcher.matchFrom(0, 0);
    try std.testing.expectError(error.StepLimitExceeded, exec_result);
}

test "RecursiveMatcher: quantified backreference to an empty capture doesn't crash" {
    // Regression test for a real crash found via test262-derived conformance
    // testing (see docs/ECMASCRIPT_COMPATIBILITY_PLAN.md Phase 6): `\1+`
    // where group 1 can capture zero characters used to segfault (stack
    // overflow) with the DEFAULT recursion limit, because isStarConsumePath
    // didn't recognize BACK_REF as a quantifiable atom, so the loop fell
    // through to plain recursive alternation with no zero-width-progress
    // guard. Uses the real default ExecOptions (matching what every public
    // Regex.find/test_ call actually uses) -- previous versions of this
    // exact call crashed the whole test binary, not just failed a `try`.
    const compiler = @import("../codegen/compiler.zig");
    const result = try compiler.compileSimple(std.testing.allocator, "(a*)b\\1+");
    defer result.deinit();

    var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, "baaac");
    defer matcher.deinit();
    const exec_result = try matcher.matchFrom(0, 0);
    try std.testing.expect(exec_result.matched);
    // Matches "b": group 1 captures "" (no leading 'a' at position 0), \1+
    // matches that empty capture once (satisfying "+") and stops repeating
    // since it makes no further progress. This matches real JS semantics --
    // this exact pattern/input is test262's S15.10.2.9_A1_T5.js, which
    // expects ["b", ""].
    try std.testing.expectEqual(@as(usize, 1), exec_result.end_pos);
}

test "RecursiveMatcher: ReDoS protection - recursion limit" {
    const compiler = @import("../codegen/compiler.zig");

    // NOTE: a bare `a+` no longer exercises this -- isStarConsumePath now
    // recognizes single-atom `+` loops (see the "quantified backref"
    // crash fix) and routes them through the iterative matchStarGreedy
    // path, which doesn't consume recursion depth per repetition. A
    // group-wrapped repetition `(a)+` isn't eligible for that
    // optimization (the repeated "atom" is a multi-instruction group, not
    // a single opcode), so it still recurses once per repetition and is a
    // faithful test of the recursion-limit mechanism itself.
    const result = try compiler.compileSimple(std.testing.allocator, "(a)+");
    defer result.deinit();

    // Crear matcher con límites muy bajos
    const options = ExecOptions.withLimits(5, 50);
    var matcher = RecursiveMatcher.initWithOptions(
        std.testing.allocator,
        result.bytecode,
        "aaaaaaaaaa", // 10 'a's
        options,
    );
    defer matcher.deinit();

    // Debería alcanzar el límite de recursión
    const exec_result = matcher.matchFrom(0, 0);
    try std.testing.expectError(error.RecursionLimitExceeded, exec_result);
}

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
